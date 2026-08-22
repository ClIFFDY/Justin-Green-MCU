# ============================================================
# rtos_shell.asm — 抢占式 RTOS + 菜单式 shell（基于 rtos_preempt v1.3）
#   内核: 时间片轮转 3 任务；任务0=shell(前台)，任务1/2=后台计数。
#   硬件依赖:
#     · irq 读 slot0:    LBU 0x5000/0x5001（被抢占任务断点）
#     · IRQ_W 改写:      2×紧邻 SB 0x5000 改写 pc_addr[0] → IRET
#     · regs[254]=返回栈指针 j（LJAL/RJAL 压、JALR 弹；指令可读写）
#   shell v3.0 菜单式界面（全英文）:
#     · init 横幅(模块大写) + 主菜单(每项一行)
#     · 命令: 主菜单 1.credits 2.status 3.game 0.menu
#            game 子菜单: 4左 6右 5旋转 7快落 1暂停 0返回菜单
#     · credits 无版本号（不随版本更新改）；status 带 RAM 用量 # 进度条(print_bar)
#     · 单字符命令 + 空闲超时执行（串口无回车也能用）
#     · tick 驱动: 1s=5000 tick(0.2ms/格), blink 每 0.25s(1250 tick)翻转
#   汇编器增强: .puts "..." 宏(逐字符 putc) + .base/rX.base。
#   __jpad 垫层已废弃（irq_controller 存 W+1，IRET 回授权点下一条，控制转移不被跳过，微测确认）。
#   MPU 寄存器窗口（硬件: 每个 rd/rs = raw + baseline, ≥253 豁免; SB 0xD000 写 baseline）:
#     任务0(shell): base 0x00（恒等）→ 低 r1-r11 + 高 r17-r21（游戏区沿用, 不改）
#     任务1:        base 0x16 → 窗口 r3-r6（r3=内 r4=中 r5=外 r6=CNT1）, 直接条件跳转
#     任务2:        base 0x26 → 窗口 r3-r6（r3=内 r4=中 r5=外 r6=CNT2）
#     调度器:       每次切任务在载入段 SBI <base>, 0xD000 切窗口；r12-r15={base}+12..15 被调度器占用
#     r253=j(调用栈指针,豁免) r0=0 r254=i2c_busy r255=tx_busy 只读
#   .base 只在源码用 rK.base(物理绝对号K) 时标注；纯相对 rK 无需标（硬件自动加 baseline）
#   汇编: python tools/asm.py tools/rtos_shell_game_mpu.asm -o tools/rtos_shell_game_mpu.hex
# ============================================================

# ---- 外设 ----
.equ UART        0x2000
.equ TIMER_CNT0  0x3000
.equ TIMER_CNT1  0x3001
.equ TIMER_CNT2  0x3002
.equ TIMER_CNT3  0x3003
.equ TIMER_MODE  0x3004
.equ TIMER_ACK   0x3005
.equ GPIO        0x4000
.equ GPIO_PIN0   0x4001
.equ GPIO_PIN1   0x4003
.equ GPIO_PIN6   0x400D
.equ IRQW        0x5000
.equ SLOT0_LO    0x5000
.equ SLOT0_HI    0x5001
.equ MODE_OUT 1
.equ MODE_RX  6
.equ MODE_TX  5

# ---- RAM（seg1 0x9000）----
.equ TICK_LO     0x9000
.equ TICK_HI     0x9001
.equ UART_S1     0x9002
.equ UART_S2     0x9003
.equ UART_S3     0x9004
.equ CUR_TASK    0x9005
.equ CNT1        0x9041
.equ CNT2        0x9042
.equ LED_STATE   0x9044
.equ TCB0_PC_LO  0x9008
.equ TCB0_PC_HI  0x9009
.equ TCB0_J      0x900A
.equ TCB0_R7     0x900B
.equ TCB0_R8     0x900C
.equ TCB0_R9     0x900D
.equ TCB0_R10    0x900E
.equ TCB0_R11    0x900F
.equ TCB1_PC_LO  0x9010
.equ TCB1_PC_HI  0x9011
.equ TCB1_J      0x9012
.equ TCB1_R7     0x9013
.equ TCB1_R8     0x9014
.equ TCB1_R9     0x9015
.equ TCB1_R10    0x9016
.equ TCB1_R11    0x9017
.equ TCB2_PC_LO  0x9018
.equ TCB2_PC_HI  0x9019
.equ TCB2_J      0x901A
.equ TCB2_R7     0x901B
.equ TCB2_R8     0x901C
.equ TCB2_R9     0x901D
.equ TCB2_R10    0x901E
.equ TCB2_R11    0x901F
# ---- MPU baseline（各任务寄存器窗口基址；0xD000 写 baseline，LBU 0xD000 读）----
.equ BASELINE    0xD000
.equ BASE_MAIN   0x00   # 任务0(shell)：物理恒等，高区 r17-21 直接用
.equ BASE_TASK1  0x16   # 任务1：窗口 r0-r15 → 物理 0x16-0x25
.equ BASE_TASK2  0x26   # 任务2：窗口 r0-r15 → 物理 0x26-0x35
# ---- UART RX 环形缓冲（0x9100 区，8 槽）----
.equ RX_RING0    0x9100
.equ RX_RING1    0x9101
.equ RX_RING2    0x9102
.equ RX_RING3    0x9103
.equ RX_RING4    0x9104
.equ RX_RING5    0x9105
.equ RX_RING6    0x9106
.equ RX_RING7    0x9107
.equ RX_WR       0x9108
.equ RX_RD       0x9109
# ---- shell 行缓冲 + 状态（0x9110 区）----
.equ LINE_BUF0   0x9110
.equ LINE_BUF1   0x9111
.equ LINE_BUF2   0x9112
.equ LINE_BUF3   0x9113
.equ LINE_BUF4   0x9114
.equ LINE_BUF5   0x9115
.equ LINE_BUF6   0x9116
.equ LINE_BUF7   0x9117
.equ CURSOR      0x9118
.equ LAST_CR     0x9119
.equ IDLE_CNT    0x911A
.equ LAST_TICK   0x911B
# ---- 菜单/倒计时/闪烁 状态（0x911C 区）----
.equ MENU        0x911C    # 0=主菜单 1=倒计时 2=LED
.equ CD_SEC      0x911D    # 倒计时剩余秒数
.equ WAIT_TH_LO  0x911E    # wait_ticks 阈值(16bit)
.equ WAIT_TH_HI  0x911F
.equ CD_LAST     0x9120    # wait_ticks 上次见到的 TICK_LO
.equ CD_ACC_LO   0x9121    # wait_ticks 累计(16bit)
.equ CD_ACC_HI   0x9122
.equ FLASH_CNT   0x9123    # 频闪剩余 0.25s 次数(5s=20)
.equ LED_MODE    0x9124    # 0=翻转(手动) 1=闪烁(自动)
.equ BLINK_ACC_LO 0x9125   # 闪烁累计(16bit, 1250=0.25s)
.equ BLINK_ACC_HI 0x9126
# ============================================================
# 复位 → boot（也是任务 0 shell 的首次执行）
# ============================================================
.equ FIELD_BASE 0x9400
.equ RENDER_BASE 0x9450
.equ P_ROW1 0x9430
.equ P_COL1 0x9431
.equ P_ROW2 0x9432
.equ P_COL2 0x9433
.equ P_ROW3 0x9434
.equ P_COL3 0x9435
.equ P_ROW4 0x9436
.equ P_COL4 0x9437
.equ P_SHAPE 0x9438
.equ P_ROT 0x9439
.equ P_ANCHOR_R 0x943A
.equ P_ANCHOR_C 0x943B
.equ C_ROW1 0x943C
.equ C_COL1 0x943D
.equ C_ROW2 0x943E
.equ C_COL2 0x943F
.equ C_ROW3 0x9440
.equ C_COL3 0x9441
.equ C_ROW4 0x9442
.equ C_COL4 0x9443
.equ G_SCORE 0x9480
.equ G_LAST_TICK 0x9481
.equ G_ACC_LO 0x9482
.equ G_ACC_HI 0x9483
.equ G_OVER 0x9484
.equ PAUSED 0x9485   # 俄罗斯方块暂停标志
.equ GAME_ACTIVE 0x9486   # 俄罗斯方块独占模式标志
.equ GAME_S1 0x9487
.equ GAME_S2 0x9488
.equ GAME_S3 0x9489
.equ DROP_SOLID 0x948A   # 快落检测：drop_piece 固化时置位
# ---- 扫雷（8x8，0x9500 区）----
.equ MS_MINE  0x9500   # 64B：bit7=雷，低4位=邻雷数
.equ MS_VIEW  0x9540   # 64B：0=未探 1=旗 2=已探 3=踩雷
.equ MS_COL   0x9580   # 输入：横坐标(1-8)
.equ MS_ROW   0x9581   # 输入：纵坐标(1-8)
.equ MS_OP    0x9582   # 输入：1=探雷 2=插旗
.equ MS_INN   0x9583   # 已收数字数(0/1/2)
.equ MS_OPEN  0x9584   # 已探开格数
.equ MS_FLG   0x9585   # 插旗数
.equ MS_SEED  0x9586   # 随机种子
.equ MS_OVER  0x9587   # 扫雷结束标志(1=踩雷死 2=全探开胜)
.equ MS_QUEUE 0x9588   # 洪水展开队列(64B, 0x9588-0x95C7)
# ---- 渲染帧 DMA（v3.1 优化）----
.equ FRAME_BUF  0xC000   # 渲染帧缓冲（ram_ext bank0，DMA 源）
.equ FRAME_IDX_LO 0x948B # 帧写指针 16bit 低字节（fputc 用；帧 319 字节 >255 必须 16 位）
.equ FRAME_IDX_HI 0x948C # 帧写指针 16bit 高字节
.equ DMA_INI    0x70C0   # 写 DMA ini 高字节（{addr[7:0]=0xC0, data=低字节}）→ 0xC000
.equ DMA_CNT    0x7100   # 写 DMA cnt（data=帧长）
.equ DMA_DES    0x7320   # 写 DMA des 高字节（{addr[7:0]=0x20, data=0}）→ 0x2000 UART
.equ DMA_BANK   0x7400   # 写 DMA bank（data=0）
.equ DMA_TRIG   0x7500   # 触发 DMA
.equ DMA_CNT_HI 0x7600   # 读 DMA cnt 高字节（dma 用 bus_addr_in[11:8]==6 返回 cnt[15:8]）
.equ DMA_CNT_LO 0x7700   # 读 DMA cnt 低字节（==7 返回 cnt[7:0]）

.org 0x000
reset:
    ADDI  r253, r0, 0        # j=0：任务0 调用栈基址
    # ---- GPIO：UART 引脚 + LED ----
    ADDI  r1, r0, MODE_RX
    SB    r1, GPIO_PIN0
    ADDI  r1, r0, MODE_TX
    SB    r1, GPIO_PIN1
    ADDI  r1, r0, MODE_OUT
    SB    r1, GPIO_PIN6
    ADDI  r1, r0, 0x40
    SB    r1, GPIO
    SB    r1, LED_STATE
    # ---- 开机动画：GPIO ----
    .puts " BOOT: GPIO    "
    RJAL  anim_bar
    # ---- 内核初值 ----
    SB    r0, CUR_TASK
    SB    r0, TICK_LO
    SB    r0, TICK_HI
    # ---- 开机动画：KERNEL ----
    .puts " BOOT: KERNEL  "
    RJAL  anim_bar
    # ---- 环形缓冲 + shell 状态初值 ----
    SB    r0, RX_WR
    SB    r0, RX_RD
    SB    r0, CURSOR
    SB    r0, LAST_CR
    SB    r0, IDLE_CNT
    SB    r0, LAST_TICK
    # ---- 菜单/倒计时/闪烁 状态初值 ----
    SB    r0, MENU
    # ---- 开机动画：BUFFER ----
    .puts " BOOT: BUFFER  "
    RJAL  anim_bar
    # ---- 调用栈分区 + 共享子程序暂存组 ----
    SB    r0, TCB0_J
    SB    r0, TCB0_R7
    SB    r0, TCB0_R8
    SB    r0, TCB0_R9
    SB    r0, TCB0_R10
    SB    r0, TCB0_R11
    SB    r0, TCB1_PC_LO
    ADDI  r1, r0, 0x04
    SB    r1, TCB1_PC_HI
    ADDI  r1, r0, 64
    SB    r1, TCB1_J
    SB    r0, TCB1_R7
    SB    r0, TCB1_R8
    SB    r0, TCB1_R9
    SB    r0, TCB1_R10
    SB    r0, TCB1_R11
    SB    r0, TCB2_PC_LO
    ADDI  r1, r0, 0x05
    SB    r1, TCB2_PC_HI
    ADDI  r1, r0, 128
    SB    r1, TCB2_J
    SB    r0, TCB2_R7
    SB    r0, TCB2_R8
    SB    r0, TCB2_R9
    SB    r0, TCB2_R10
    SB    r0, TCB2_R11
    # ---- 开机动画：STACK ----
    .puts " BOOT: STACK   "
    RJAL  anim_bar
    # ---- 中断优先级（BUS_CON 0x6000：addr bit3=1 写 prio；bit3=0 解锁一次性 lock）----
    # timer=3 最高 rx=2 gpio0=1 gpio1=0 dma=0（关；复位默认 dma=5 最高必须关）
    ADDI  r1, r0, 3
    SB    r1, 0x6008
    SB    r0, 0x6009
    ADDI  r1, r0, 2
    SB    r1, 0x600A
    SB    r0, 0x600B
    SB    r0, 0x600C
    SB    r0, 0x600D
    # ---- 开机动画：IRQ PRIO ----
    .puts " BOOT: IRQPRIO "
    RJAL  anim_bar
    # ---- 写向量表指针（IRQW 0x5xxx：[4:2]=槽位，[1:0]=1 高字节/2 低字节）----
    # 槽位: timer=0 uart=1 gpio0=2 gpio1=3 dma=4
    # 目标: timer→0x248(跳板→sched_body) uart→0x260 gpio0→0x208 gpio1→0x228 dma→0x208(防御IRET)
    ADDI  r1, r0, 0x02
    SB    r1, 0x5001            # timer 高
    ADDI  r1, r0, 0x48
    SB    r1, 0x5002            # timer 低 → 0x248
    ADDI  r1, r0, 0x02
    SB    r1, 0x5005            # uart 高
    ADDI  r1, r0, 0x60
    SB    r1, 0x5006            # uart 低 → 0x260
    ADDI  r1, r0, 0x02
    SB    r1, 0x5009            # gpio0 高
    ADDI  r1, r0, 0x08
    SB    r1, 0x500A            # gpio0 低 → 0x208
    ADDI  r1, r0, 0x02
    SB    r1, 0x500D            # gpio1 高
    ADDI  r1, r0, 0x28
    SB    r1, 0x500E            # gpio1 低 → 0x228
    ADDI  r1, r0, 0x02
    SB    r1, 0x5011            # dma 高
    ADDI  r1, r0, 0x08
    SB    r1, 0x5012            # dma 低 → 0x208
    # ---- 开机动画：VECTOR ----
    .puts " BOOT: VECTOR  "
    RJAL  anim_bar
    # ---- timer: 0x270F → 周期 10000 拍 = 0.2ms（5kHz 抢占）----
    ADDI  r1, r0, 0x0F
    SB    r1, TIMER_CNT0
    ADDI  r1, r0, 0x27
    SB    r1, TIMER_CNT1
    SB    r0, TIMER_CNT2
    SB    r0, TIMER_CNT3
    ADDI  r1, r0, 1
    SB    r1, TIMER_MODE
    # ---- 开机动画：READY ----
    .puts " BOOT: READY   "
    RJAL  anim_bar
    # ---- 解锁一次性 irq lock（写 BUS_CON bit3=0 即 0x6000-0x6007）→ 允许中断 ----
    SB    r0, 0x6000
    # ---- 进入任务 0（shell）----
task0_entry:
    RJAL  menu_main           # 主菜单
    RJAL  print_prompt
shell_loop:
    RJAL  tick_bookkeeping    # 每轮: 累加 IDLE_CNT + blink
    # ---- 等字符: WR != RD ? ----
    LBU   r1, RX_WR
    LBU   r2, RX_RD
    RBNE  r1, r2, __sh_have
    # ---- 空闲超时: IDLE_CNT>=50(10ms) 且行非空 → 执行 ----
    LBU   r1, IDLE_CNT
    ADDI  r7, r0, 50
    RBLTU r1, r7, shell_loop
    LBU   r2, CURSOR
    RBNE  r2, r0, __sh_exec
    LBEQ  r0, r0, shell_loop
__sh_have:
    # ---- 弹字符: 按 RD(0-7) 读 RING{RD}，RD=(RD+1)&7 ----
    ADDI  r8, r0, 7
    RBNE  r2, r8, __sh_r6
    LBU   r7, RX_RING7
    RBEQ  r0, r0, __sh_rdinc
__sh_r6:
    ADDI  r8, r0, 6
    RBNE  r2, r8, __sh_r5
    LBU   r7, RX_RING6
    RBEQ  r0, r0, __sh_rdinc
__sh_r5:
    ADDI  r8, r0, 5
    RBNE  r2, r8, __sh_r4
    LBU   r7, RX_RING5
    RBEQ  r0, r0, __sh_rdinc
__sh_r4:
    ADDI  r8, r0, 4
    RBNE  r2, r8, __sh_r3
    LBU   r7, RX_RING4
    RBEQ  r0, r0, __sh_rdinc
__sh_r3:
    ADDI  r8, r0, 3
    RBNE  r2, r8, __sh_r2
    LBU   r7, RX_RING3
    RBEQ  r0, r0, __sh_rdinc
__sh_r2:
    ADDI  r8, r0, 2
    RBNE  r2, r8, __sh_r1
    LBU   r7, RX_RING2
    RBEQ  r0, r0, __sh_rdinc
__sh_r1:
    ADDI  r8, r0, 1
    RBNE  r2, r8, __sh_r0
    LBU   r7, RX_RING1
    RBEQ  r0, r0, __sh_rdinc
__sh_r0:
    LBU   r7, RX_RING0
    NOP                        # 拉开 __sh_rdinc 距离到 +3（bytmov=0 不可编码）
__sh_rdinc:
    LBU   r2, RX_RD
    ADDI  r2, r2, 1
    ANDI  r2, r2, 7
    SB    r2, RX_RD
    # ---- r7 = 字符。回车 '\r'? ----
    ADDI  r8, r0, '\r'
    RBNE  r7, r8, __sh_lf
    # \r → 执行（记录 LAST_CR 防 CRLF 双执行）
    ADDI  r1, r0, 1
    SB    r1, LAST_CR
    RBEQ  r0, r0, __sh_exec
__sh_lf:
    # 换行 '\n'? 串口助手常用 \n 或 \r\n
    ADDI  r8, r0, '\n'
    RBNE  r7, r8, __sh_bs
    LBU   r1, LAST_CR
    RBNE  r1, r0, __lf_skip
    RBEQ  r0, r0, __sh_exec
__lf_skip:
    SB    r0, LAST_CR
    LBEQ  r0, r0, shell_loop
__sh_exec:
    # 执行: 换行 → 解析 → 重置 → 提示符（按 MENU）
    ADDI  r7, r0, '\n'
    RJAL  putc
    RJAL  shell_parse
    SB    r0, CURSOR
    RJAL  print_prompt
    LBEQ  r0, r0, shell_loop
__sh_bs:
    # 退格(0x7F 或 0x08)?
    ADDI  r8, r0, 0x7F
    RBNE  r7, r8, __sh_bs2
    RBEQ  r0, r0, __bs_do
__sh_bs2:
    ADDI  r8, r0, 0x08
    RBNE  r7, r8, __sh_char
    # 退格: 若 CURSOR>0，cursor--，echo "\x08 \x08"
    LBU   r1, CURSOR
    RBNE  r1, r0, __bs_do
    SB    r0, LAST_CR
    LBEQ  r0, r0, shell_loop
__bs_do:
    ADDI  r1, r1, 0xFF
    SB    r1, CURSOR
    SB    r0, LAST_CR
    ADDI  r7, r0, 0x08
    RJAL  putc
    ADDI  r7, r0, ' '
    RJAL  putc
    ADDI  r7, r0, 0x08
    RJAL  putc
    LBEQ  r0, r0, shell_loop
__sh_char:
    # 普通字符: 若 CURSOR<8，调 shell_append 存行 + echo（append 在 0x2A0 区）
    LBU   r1, CURSOR
    ADDI  r8, r0, 8
    RBLTU r1, r8, __ap_call
    SB    r0, LAST_CR
    LBEQ  r0, r0, shell_loop     # 缓冲满，忽略
__ap_call:
    RJAL  shell_append
    LBEQ  r0, r0, shell_loop

# ============================================================
# 共享子程序（0x100 区，寄存器中立：只用 r7-r11，参数走 r7）
# ============================================================
.org 0x100
putc:                           # 入参 r7=字符；轮询 tx_busy（r255）后发送（破坏 r7,r8,r9）
putc_wait:
    ADDI  r8, r255, 0
    LBNE  r8, r0, putc_wait
    SB    r7, UART
    # 打字机效果：逐字延迟（r9 外层计数 × r8 内层）
    ADDI  r9, r0, 250           # 外层 250 次 ≈ 5ms/字符
__typing_o:
    ADDI  r8, r0, 0xFF          # 内层 255 次
__typing_i:
    ADDI  r8, r8, 0xFF
    LBNE  r8, r0, __typing_i
    ADDI  r9, r9, 0xFF
    LBNE  r9, r0, __typing_o
    JALR

# flush_rx: 清空 UART RX 环形缓冲（丢弃打印期间积压的按键）→ 打印完成后才接受新输入
flush_rx:
    SB    r0, RX_WR
    SB    r0, RX_RD
    JALR

# fast_putc: 快速发送（开机动画用，不走打字机延迟）；破坏 r7,r8
fast_putc:
__fp_w:
    ADDI  r8, r255, 0            # tx_busy
    LBNE  r8, r0, __fp_w
    SB    r7, UART
    JALR

# anim_bar: 加载条动画（每帧只加一个 '#'）；破坏 r7-r11
#   打 '[' → 逐段加 '#'（每段延迟）→ 打 ']' 换行
anim_bar:
    ADDI  r7, r0, '['
    RJAL  fast_putc
    ADDI  r10, r0, 10            # 10 段
__ab_loop:
    ADDI  r7, r0, '#'
    RJAL  fast_putc
    # 延迟（每段 ~30ms）
    ADDI  r11, r0, 0x06          # 外层外层
__ab_dly_oo:
    ADDI  r9, r0, 0xFF           # 外层
__ab_dly_o:
    ADDI  r8, r0, 0xFF           # 内层
__ab_dly_i:
    ADDI  r8, r8, 0xFF
    LBNE  r8, r0, __ab_dly_i
    ADDI  r9, r9, 0xFF
    LBNE  r9, r0, __ab_dly_o
    ADDI  r11, r11, 0xFF
    LBNE  r11, r0, __ab_dly_oo
    ADDI  r10, r10, 0xFF
    RBNE  r10, r0, __ab_loop
    ADDI  r7, r0, ']'
    RJAL  fast_putc
    ADDI  r7, r0, '\n'
    RJAL  fast_putc
    JALR

put_crlf:                       # "\r\n"（破坏 r7）
    ADDI  r7, r0, '\r'
    LJAL  putc
    ADDI  r7, r0, '\n'
    LJAL  putc
    JALR

print_hexdigit:                 # 入参 r7=0-15 → 1 个 hex 字符（破坏 r7,r8）
    ADDI  r8, r0, 9
    RBLTU r8, r7, __phx_af     # 前向
    ADDI  r7, r7, '0'
    LJAL  putc
    JALR
__phx_af:
    ADDI  r7, r7, 55            # 'A'-10 = 55
    LJAL  putc
    JALR

print_hex:                      # 入参 r7=字节 → 2 位 hex（破坏 r7,r8,r9）
    ADDI  r9, r7, 0             # r9 暂存输入（调度器保 r7-r11）
    SRLI  r7, r9, 4
    LJAL  print_hexdigit
    ANDI  r7, r9, 0x0F
    LJAL  print_hexdigit
    JALR

# ============================================================
# shell 解析（0x100 区，任务0 独用，返回栈走任务0 区域）
#   按 MENU 状态分派：主菜单 / 倒计时子菜单 / LED 子菜单
# ============================================================
shell_parse:                    # 解析 LINE_BUF[0..CURSOR-1]（主菜单：1/2/3/0）
    LBU   r7, CURSOR
    RBNE  r7, r0, __sp_have
    JALR                        # 空行 → 直接返回
__sp_have:
    ADDI  r8, r0, 1
    RBNE  r7, r8, __sp_unknown  # 只接受单字符命令
    LBU   r7, LINE_BUF0
    LBU   r1, MENU
    RBNE  r1, r0, game_menu_dispatch   # MENU!=0 → game 子菜单分派
    ADDI  r8, r0, '1'
    ADDI  r8, r0, '1'
    RBNE  r7, r8, __sp_m2
    RJAL  cmd_credits
    JALR
__sp_m2:
    ADDI  r8, r0, '2'
    RBNE  r7, r8, __sp_m3
    RJAL  cmd_status
    JALR
__sp_m3:
    ADDI  r8, r0, '3'
    RBNE  r7, r8, __sp_m0
    ADDI  r1, r0, 1
    SB    r1, MENU
    RJAL  game_menu             # 进 game 子菜单（俄罗斯方块/扫雷）
    JALR
__sp_m0:
    ADDI  r8, r0, '0'
    RBNE  r7, r8, __sp_unknown
    RJAL  menu_main
    JALR
__sp_unknown:
    ADDI  r7, r0, '?'
    LJAL  putc
    LJAL  put_crlf
    RJAL  menu_main
    JALR

# ---- game 子菜单分派（MENU==1）：1=俄罗斯方块 2=扫雷 0=回主菜单 ----
game_menu_dispatch:
    LBU   r1, MENU
    ADDI  r8, r0, 1
    RBNE  r1, r8, __gmd_main    # MENU != 1 → 主菜单逻辑
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, '1'
    RBNE  r7, r8, __gmd_2
    RJAL  game_start             # 俄罗斯方块
    JALR
__gmd_2:
    ADDI  r8, r0, '2'
    RBNE  r7, r8, __gmd_0
    RJAL  minesweeper_start      # 扫雷
    JALR
__gmd_0:
    ADDI  r8, r0, '0'
    RBNE  r7, r8, __gmd_unknown
    SB    r0, MENU
    RJAL  menu_main
    JALR
__gmd_unknown:
    ADDI  r7, r0, '?'
    LJAL  putc
    RJAL  game_menu
    JALR
__gmd_main:
    # MENU==0：回主菜单 shell_parse 正常路径
    RJAL  menu_main
    JALR

# ---- game 子菜单显示 ----
game_menu:
    .puts "--- GAME MENU ---"
    RJAL  put_crlf
    .puts " 1. TETRIS"
    RJAL  put_crlf
    .puts " 2. MINESWEEP"
    RJAL  put_crlf
    .puts " 0. MAIN MENU"
    RJAL  put_crlf
    RJAL  flush_rx             # 打印完成 → 丢弃积压按键
    JALR

# ============================================================
# 俄罗斯方块（GAME 模式：关 RTOS timer 独占 CPU）
# ============================================================
game_start:                     # shell_parse 3 → 进入（GAME 独占模式）
    ADDI  r1, r0, 1
    SB    r1, GAME_ACTIVE       # 调度器检测：只更新 TICK 不切任务
    # 选片 ram_ext bank0（渲染帧缓冲 FRAME_BUF@0xC000）
    SB    r0, 0xB000
    # 清 FIELD（0x9400-0x9427）
    ADDI  r1, r0, 0x94
    ADDI  r2, r0, 0x00
    ADDI  r3, r0, 40
__gf_fld:
    SIND  r0, r1, r2
    ADDI  r2, r2, 1
    ADDI  r3, r3, 0xFF
    RBNE  r3, r0, __gf_fld
    # 清 RENDER_BASE（0x9450-0x9477）
    ADDI  r2, r0, 0x50
    ADDI  r3, r0, 40
__gf_ren:
    SIND  r0, r1, r2
    ADDI  r2, r2, 1
    ADDI  r3, r3, 0xFF
    RBNE  r3, r0, __gf_ren
    # 清游戏状态
    SB    r0, G_SCORE
    SB    r0, G_LAST_TICK
    SB    r0, G_ACC_LO
    SB    r0, G_ACC_HI
    SB    r0, G_OVER
    SB    r0, PAUSED
    RJAL  spawn
    RJAL  render
game_loop:
    RJAL  input_handle
    LBU   r1, G_OVER
    RBNE  r1, r0, game_over     # 按 0 设 G_OVER → 立即退出（暂停中也能退）
    LBU   r1, PAUSED
    RBNE  r1, r0, game_loop     # 暂停 → 不下落
    RJAL  drop_check
    LBU   r1, G_OVER
    RBNE  r1, r0, game_over
    LBEQ  r0, r0, game_loop
game_over:
game_exit:                      # 退出 GAME 独占 → 回 game 子菜单
    SB    r0, GAME_ACTIVE
    ADDI  r1, r0, 1
    SB    r1, MENU
    RJAL  game_menu
    JALR

# ---- 俄罗斯方块核心（LIND/SIND 版）----
.org 0x940
input_handle:
    LBU   r1, RX_WR
    LBU   r2, RX_RD
    RBNE  r1, r2, __ih_have
    JALR
__ih_have:
    ADDI  r8, r0, 7
    RBNE  r2, r8, __ih_r6
    LBU   r7, RX_RING7
    RBEQ  r0, r0, __ih_rdinc
__ih_r6:
    ADDI  r8, r0, 6
    RBNE  r2, r8, __ih_r5
    LBU   r7, RX_RING6
    RBEQ  r0, r0, __ih_rdinc
__ih_r5:
    ADDI  r8, r0, 5
    RBNE  r2, r8, __ih_r4
    LBU   r7, RX_RING5
    RBEQ  r0, r0, __ih_rdinc
__ih_r4:
    ADDI  r8, r0, 4
    RBNE  r2, r8, __ih_r3
    LBU   r7, RX_RING4
    RBEQ  r0, r0, __ih_rdinc
__ih_r3:
    ADDI  r8, r0, 3
    RBNE  r2, r8, __ih_r2
    LBU   r7, RX_RING3
    RBEQ  r0, r0, __ih_rdinc
__ih_r2:
    ADDI  r8, r0, 2
    RBNE  r2, r8, __ih_r1
    LBU   r7, RX_RING2
    RBEQ  r0, r0, __ih_rdinc
__ih_r1:
    ADDI  r8, r0, 1
    RBNE  r2, r8, __ih_r0
    LBU   r7, RX_RING1
    RBEQ  r0, r0, __ih_rdinc
__ih_r0:
    LBU   r7, RX_RING0
    NOP
__ih_rdinc:
    LBU   r2, RX_RD
    ADDI  r2, r2, 1
    ANDI  r2, r2, 7
    SB    r2, RX_RD
    ADDI  r8, r0, '4'
    RBNE  r7, r8, __ih_6
    RJAL  move_left
    RJAL  render
    JALR
__ih_6:
    ADDI  r8, r0, '6'
    RBNE  r7, r8, __ih_5
    RJAL  move_right
    RJAL  render
    JALR
__ih_5:
    ADDI  r8, r0, '5'
    RBNE  r7, r8, __ih_0
    RJAL  rotate
    RJAL  render
    JALR
__ih_0:                     # '0' → 返回主菜单（设 G_OVER，game_loop 检测退出 → game_exit）
    ADDI  r8, r0, '0'
    RBNE  r7, r8, __ih_1
    ADDI  r1, r0, 1
    SB    r1, G_OVER
    JALR
__ih_1:                     # '1' → 暂停/恢复
    ADDI  r8, r0, '1'
    RBNE  r7, r8, __ih_7
    LBU   r1, PAUSED
    XORI  r1, r1, 1
    SB    r1, PAUSED
    JALR
__ih_7:                     # '7' → 快速下落（当前块落到底固化即停）
    ADDI  r8, r0, '7'
    RBNE  r7, r8, __ih_other
    SB    r0, DROP_SOLID
__hard_loop:
    RJAL  drop_piece
    LBU   r1, DROP_SOLID
    RBNE  r1, r0, __hd_done
    LBEQ  r0, r0, __hard_loop
__hd_done:
    RJAL  render
    JALR
__ih_other:
    JALR
move_left:
    ADDI  r1, r0, 0x94
    ADDI  r2, r0, 0x30
    ADDI  r5, r0, 0x3C
    ADDI  r6, r0, 4
__ml_loop:
    LIND  r3, r1, r2
    ADDI  r2, r2, 1
    LIND  r4, r1, r2
    ADDI  r4, r4, 0xFF
    SIND  r3, r1, r5
    ADDI  r5, r5, 1
    SIND  r4, r1, r5
    ADDI  r2, r2, 1
    ADDI  r5, r5, 1
    ADDI  r6, r6, 0xFF
    RBNE  r6, r0, __ml_loop
    RJAL  check_candidate
    RBNE  r1, r0, __ml_end
    RJAL  apply_candidate
    LBU   r1, P_ANCHOR_C
    ADDI  r1, r1, 0xFF
    SB    r1, P_ANCHOR_C
__ml_end:
    JALR
move_right:
    ADDI  r1, r0, 0x94
    ADDI  r2, r0, 0x30
    ADDI  r5, r0, 0x3C
    ADDI  r6, r0, 4
__mr_loop:
    LIND  r3, r1, r2
    ADDI  r2, r2, 1
    LIND  r4, r1, r2
    ADDI  r4, r4, 1
    SIND  r3, r1, r5
    ADDI  r5, r5, 1
    SIND  r4, r1, r5
    ADDI  r2, r2, 1
    ADDI  r5, r5, 1
    ADDI  r6, r6, 0xFF
    RBNE  r6, r0, __mr_loop
    RJAL  check_candidate
    RBNE  r1, r0, __mr_end
    RJAL  apply_candidate
    LBU   r1, P_ANCHOR_C
    ADDI  r1, r1, 1
    SB    r1, P_ANCHOR_C
__mr_end:
    JALR
rotate:
    LBU   r1, P_ROT
    ADDI  r1, r1, 1
    ANDI  r1, r1, 3
    ADDI  r13, r1, 0
    ADDI  r9, r1, 0
    LBU   r8, P_SHAPE
    RJAL  compute_cells
    RJAL  check_candidate
    RBNE  r1, r0, __rt_end
    RJAL  apply_candidate
    SB    r13, P_ROT
__rt_end:
    JALR
spawn:
    LBU   r1, TICK_LO
    SRLI  r1, r1, 1
    ANDI  r1, r1, 7
    ADDI  r2, r0, 7
    RBNE  r1, r2, __sp_ok
    ADDI  r1, r0, 0
__sp_ok:
    SB    r1, P_SHAPE
    ADDI  r8, r1, 0
    SB    r0, P_ROT
    ADDI  r1, r0, 0
    SB    r1, P_ANCHOR_R
    ADDI  r1, r0, 4
    SB    r1, P_ANCHOR_C
    ADDI  r9, r0, 0
    RJAL  compute_cells
    RJAL  check_candidate
    RBNE  r1, r0, __sp_over
    RJAL  apply_candidate
    JALR
__sp_over:
    ADDI  r1, r0, 1
    SB    r1, G_OVER
    JALR

compute_cells:                 # 入参 r8=shape r9=rot → 写候选 C_ROW1..C_COL4
    LBU   r17, P_ANCHOR_R
    LBU   r18, P_ANCHOR_C
    ADDI  r1, r0, 0
    RBEQ  r8, r1, __cs_0
    ADDI  r1, r0, 1
    RBEQ  r8, r1, __cs_1
    ADDI  r1, r0, 2
    RBEQ  r8, r1, __cs_2
    ADDI  r1, r0, 3
    RBEQ  r8, r1, __cs_3
    ADDI  r1, r0, 4
    RBEQ  r8, r1, __cs_4
    ADDI  r1, r0, 5
    RBEQ  r8, r1, __cs_5
__cs_6:
__cs_0:
    ADDI  r1, r0, 0x00   # I 格1 dr
    ADDI  r2, r0, 0xFF   # I 格1 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW1
    SB    r2, C_COL1
    ADDI  r1, r0, 0x00   # I 格2 dr
    ADDI  r2, r0, 0x00   # I 格2 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW2
    SB    r2, C_COL2
    ADDI  r1, r0, 0x00   # I 格3 dr
    ADDI  r2, r0, 0x01   # I 格3 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW3
    SB    r2, C_COL3
    ADDI  r1, r0, 0x00   # I 格4 dr
    ADDI  r2, r0, 0x02   # I 格4 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW4
    SB    r2, C_COL4
    JALR
__cs_1:
    ADDI  r1, r0, 0x00   # O 格1 dr
    ADDI  r2, r0, 0x00   # O 格1 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW1
    SB    r2, C_COL1
    ADDI  r1, r0, 0x00   # O 格2 dr
    ADDI  r2, r0, 0x01   # O 格2 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW2
    SB    r2, C_COL2
    ADDI  r1, r0, 0x01   # O 格3 dr
    ADDI  r2, r0, 0x00   # O 格3 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW3
    SB    r2, C_COL3
    ADDI  r1, r0, 0x01   # O 格4 dr
    ADDI  r2, r0, 0x01   # O 格4 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW4
    SB    r2, C_COL4
    JALR
__cs_2:
    ADDI  r1, r0, 0x00   # T 格1 dr
    ADDI  r2, r0, 0xFF   # T 格1 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW1
    SB    r2, C_COL1
    ADDI  r1, r0, 0x00   # T 格2 dr
    ADDI  r2, r0, 0x00   # T 格2 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW2
    SB    r2, C_COL2
    ADDI  r1, r0, 0x00   # T 格3 dr
    ADDI  r2, r0, 0x01   # T 格3 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW3
    SB    r2, C_COL3
    ADDI  r1, r0, 0x01   # T 格4 dr
    ADDI  r2, r0, 0x00   # T 格4 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW4
    SB    r2, C_COL4
    JALR
__cs_3:
    ADDI  r1, r0, 0x00   # S 格1 dr
    ADDI  r2, r0, 0xFF   # S 格1 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW1
    SB    r2, C_COL1
    ADDI  r1, r0, 0x00   # S 格2 dr
    ADDI  r2, r0, 0x00   # S 格2 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW2
    SB    r2, C_COL2
    ADDI  r1, r0, 0x01   # S 格3 dr
    ADDI  r2, r0, 0x00   # S 格3 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW3
    SB    r2, C_COL3
    ADDI  r1, r0, 0x01   # S 格4 dr
    ADDI  r2, r0, 0x01   # S 格4 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW4
    SB    r2, C_COL4
    JALR
__cs_4:
    ADDI  r1, r0, 0x00   # Z 格1 dr
    ADDI  r2, r0, 0x00   # Z 格1 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW1
    SB    r2, C_COL1
    ADDI  r1, r0, 0x00   # Z 格2 dr
    ADDI  r2, r0, 0x01   # Z 格2 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW2
    SB    r2, C_COL2
    ADDI  r1, r0, 0x01   # Z 格3 dr
    ADDI  r2, r0, 0xFF   # Z 格3 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW3
    SB    r2, C_COL3
    ADDI  r1, r0, 0x01   # Z 格4 dr
    ADDI  r2, r0, 0x00   # Z 格4 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW4
    SB    r2, C_COL4
    JALR
__cs_5:
    ADDI  r1, r0, 0x00   # J 格1 dr
    ADDI  r2, r0, 0xFF   # J 格1 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW1
    SB    r2, C_COL1
    ADDI  r1, r0, 0x00   # J 格2 dr
    ADDI  r2, r0, 0x00   # J 格2 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW2
    SB    r2, C_COL2
    ADDI  r1, r0, 0x00   # J 格3 dr
    ADDI  r2, r0, 0x01   # J 格3 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW3
    SB    r2, C_COL3
    ADDI  r1, r0, 0x01   # J 格4 dr
    ADDI  r2, r0, 0xFF   # J 格4 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW4
    SB    r2, C_COL4
    JALR
    ADDI  r1, r0, 0x00   # L 格1 dr
    ADDI  r2, r0, 0xFF   # L 格1 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW1
    SB    r2, C_COL1
    ADDI  r1, r0, 0x00   # L 格2 dr
    ADDI  r2, r0, 0x00   # L 格2 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW2
    SB    r2, C_COL2
    ADDI  r1, r0, 0x00   # L 格3 dr
    ADDI  r2, r0, 0x01   # L 格3 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW3
    SB    r2, C_COL3
    ADDI  r1, r0, 0x01   # L 格4 dr
    ADDI  r2, r0, 0x01   # L 格4 dc
    RJAL  transform
    ADD   r1, r17, r1
    ADD   r2, r18, r2
    SB    r1, C_ROW4
    SB    r2, C_COL4
    JALR
transform:               # r1=dr r2=dc r9=rot -> r1=dr' r2=dc'
    ADDI  r3, r0, 1
    RBEQ  r9, r3, __tf_1
    ADDI  r3, r0, 2
    RBEQ  r9, r3, __tf_2
    ADDI  r3, r0, 3
    RBEQ  r9, r3, __tf_3
    JALR
__tf_1:                 # (dr,dc)->(dc,-dr)
    ADDI  r3, r1, 0
    ADDI  r1, r2, 0
    SUB   r2, r0, r3
    JALR
__tf_2:                 # (-dr,-dc)
    ADDI  r3, r1, 0
    ADDI  r4, r2, 0
    SUB   r1, r0, r3
    SUB   r2, r0, r4
    JALR
__tf_3:                 # (-dc,dr)
    ADDI  r3, r2, 0
    ADDI  r4, r1, 0
    SUB   r1, r0, r3
    ADDI  r2, r4, 0
    JALR

check_candidate:
    ADDI  r1, r0, 0x94
    ADDI  r2, r0, 0x3C
    ADDI  r12, r0, 4
__cc_loop:
    LIND  r3, r1, r2
    ADDI  r2, r2, 1
    LIND  r4, r1, r2
    ADDI  r2, r2, 1
    RJAL  check_cell
    RBNE  r5, r0, __cc_blocked
    ADDI  r12, r12, 0xFF
    RBNE  r12, r0, __cc_loop
    ADDI  r1, r0, 0
    JALR
__cc_blocked:
    ADDI  r1, r0, 1
    JALR

check_cell:                # r3=row r4=col -> r5=0 free / 1 blocked（LIND 读字段格）
    ADDI  r6, r0, 0x80
    RBLTU r6, r3, __ce_free
    ADDI  r6, r0, 20
    RBLTU r3, r6, __ce_rowok
    RBEQ  r0, r0, __ce_blocked
__ce_rowok:
    ADDI  r6, r0, 0x80
    RBLTU r6, r4, __ce_blocked
    ADDI  r6, r0, 9
    RBLTU r6, r4, __ce_blocked
    # 读字段格: 先按行读掩码再测位（掩码位 c = 列 c）
    # 用 r10/r11 作地址基址/偏移（不碰 r1：check_candidate 靠 r1 返回）
    SLLI  r11, r3, 1           # addr_lo = row*2
    ADDI  r10, r0, 0x94        # addr_hi = FIELD_BASE>>8
    ADDI  r5, r11, 0
    LIND  r6, r10, r11         # r6 = field[row] lo
    ADDI  r11, r5, 1
    LIND  r7, r10, r11         # r7 = field[row] hi
    # 8 位寄存器不能左移 8（溢出成 0）：col<8 测 lo、col>=8 测 hi
    ADDI  r8, r4, 0            # r8 = col
    ADDI  r9, r0, 8
    RBLTU r8, r9, __ce_lobit
    ADDI  r8, r8, 0xF8
    ADDI  r6, r7, 0
    RBEQ  r0, r0, __ce_bt
__ce_lobit:
__ce_bt:
    RBNE  r8, r0, __ce_shift
    RBEQ  r0, r0, __ce_test
__ce_shift:
    SRLI  r6, r6, 1
    ADDI  r8, r8, 0xFF
    RBEQ  r0, r0, __ce_bt
__ce_test:
    ANDI  r6, r6, 1
    RBNE  r6, r0, __ce_blocked
__ce_free:
    ADDI  r5, r0, 0
    JALR
__ce_blocked:
    ADDI  r5, r0, 1
    JALR

set_bit:                   # r1=lo r2=hi r4=col -> r1|bit / r2|bit
    ADDI  r5, r0, 1
    ADDI  r6, r4, 0
__sb_loop:
    RBNE  r6, r0, __sb_shift
    RBEQ  r0, r0, __sb_or
__sb_shift:
    SLLI  r5, r5, 1
    ADDI  r6, r6, 0xFF
    RBEQ  r0, r0, __sb_loop
__sb_or:
    ADDI  r6, r0, 8
    RBLTU r4, r6, __sb_lo
    # col 8/9：r5 已溢出（1<<8 在 8 位寄存器=0），特判 hi 位
    ADDI  r6, r0, 8
    RBEQ  r4, r6, __sb_hi1
    ADDI  r5, r0, 2
    OR    r2, r2, r5
    JALR
__sb_hi1:
    ADDI  r5, r0, 1
    OR    r2, r2, r5
    JALR
__sb_lo:
    OR    r1, r1, r5
    JALR

set_cell:                  # r3=row r4=col r13=基址低8位(0x00/0x50) -> 掩码|=1<<col
    ADDI  r6, r0, 0x80
    RBLTU r6, r4, __sc_out
    ADDI  r6, r0, 9
    RBLTU r6, r4, __sc_out
    ADDI  r6, r0, 0x80
    RBLTU r6, r3, __sc_out
    ADDI  r6, r0, 20
    RBLTU r3, r6, __sc_rowo
    RBEQ  r0, r0, __sc_out
__sc_rowo:
    SLLI  r2, r3, 1
    ADD   r2, r2, r13         # addr_lo = 基址低 + row*2
    ADDI  r1, r0, 0x94
    ADDI  r5, r2, 0
    LIND  r6, r1, r2          # lo
    ADDI  r2, r5, 1
    LIND  r7, r1, r2          # hi
    ADDI  r1, r6, 0
    ADDI  r2, r7, 0
    RJAL  set_bit
    ADDI  r8, r1, 0
    ADDI  r9, r2, 0
    SLLI  r2, r3, 1
    ADD   r2, r2, r13
    ADDI  r1, r0, 0x94
    SIND  r8, r1, r2          # 写回 lo'
    ADDI  r2, r2, 1
    SIND  r9, r1, r2          # 写回 hi'
__sc_out:
    JALR

apply_candidate:
    ADDI  r1, r0, 0x94
    ADDI  r2, r0, 0x3C
    ADDI  r5, r0, 0x30
    ADDI  r6, r0, 8
__ac_loop:
    LIND  r3, r1, r2
    SIND  r3, r1, r5
    ADDI  r2, r2, 1
    ADDI  r5, r5, 1
    ADDI  r6, r6, 0xFF
    RBNE  r6, r0, __ac_loop
    JALR
drop_piece:
    ADDI  r1, r0, 0x94
    ADDI  r2, r0, 0x30
    ADDI  r5, r0, 0x3C
    ADDI  r6, r0, 4
__dp_loop:
    LIND  r3, r1, r2
    ADDI  r3, r3, 1
    ADDI  r2, r2, 1
    LIND  r4, r1, r2
    SIND  r3, r1, r5
    ADDI  r5, r5, 1
    SIND  r4, r1, r5
    ADDI  r2, r2, 1
    ADDI  r5, r5, 1
    ADDI  r6, r6, 0xFF
    RBNE  r6, r0, __dp_loop
    RJAL  check_candidate
    RBNE  r1, r0, __dp_solidify
    RJAL  apply_candidate
    LBU   r1, P_ANCHOR_R
    ADDI  r1, r1, 1
    SB    r1, P_ANCHOR_R
    JALR
__dp_solidify:
    ADDI  r1, r0, 1
    SB    r1, DROP_SOLID
    RJAL  solidify
    RJAL  clear_lines
    RJAL  spawn
    JALR
solidify:
    ADDI  r13, r0, 0x00       # 基址低 = 0（FIELD_BASE=0x9400）
    LBU   r3, P_ROW1
    LBU   r4, P_COL1
    RJAL  set_cell
    LBU   r3, P_ROW2
    LBU   r4, P_COL2
    RJAL  set_cell
    LBU   r3, P_ROW3
    LBU   r4, P_COL3
    RJAL  set_cell
    LBU   r3, P_ROW4
    LBU   r4, P_COL4
    RJAL  set_cell
    JALR

clear_lines:               # 扫 19→0 找满行，清行下沉（LIND/SIND 拷贝）
cl_loop:
    ADDI  r6, r0, 19
__cl_scan:
    ADDI  r1, r0, 0x80
    RBLTU r1, r6, __cl_done
    # 检查行 r6 满: 掩码 == 0x3FF
    SLLI  r2, r6, 1
    ADDI  r1, r0, 0x94
    ADDI  r5, r2, 0
    LIND  r3, r1, r2
    ADDI  r2, r5, 1
    LIND  r4, r1, r2
    ADDI  r5, r0, 0xFF
    RBNE  r3, r5, __cl_next
    ADDI  r5, r0, 0x03
    RBNE  r4, r5, __cl_next
    RJAL  clear_row
    LBU   r1, G_SCORE
    ADDI  r1, r1, 1
    SB    r1, G_SCORE
    RBEQ  r0, r0, cl_loop
__cl_next:
    ADDI  r6, r6, 0xFF
    RBEQ  r0, r0, __cl_scan
__cl_done:
    JALR

clear_row:                 # r6=行 k：行 r=k..1 拷贝行 r-1 → r；行 0 清 0（LIND/SIND）
    ADDI  r5, r6, 0            # r5 = 目标行（从 k 往下到 1）
__cr_next:
    RBNE  r5, r0, __cr_copy    # r5 != 0 → 拷贝
    RBEQ  r0, r0, __cr_zero
__cr_copy:
    ADDI  r4, r5, 0xFF         # 源行 = r5-1
    SLLI  r2, r4, 1
    ADDI  r1, r0, 0x94
    ADDI  r3, r2, 0
    LIND  r6, r1, r2           # 源 lo
    ADDI  r2, r3, 1
    LIND  r7, r1, r2           # 源 hi
    SLLI  r3, r5, 1
    ADDI  r2, r3, 0
    SIND  r6, r1, r2           # 目标 lo
    ADDI  r2, r3, 1
    SIND  r7, r1, r2           # 目标 hi
    ADDI  r5, r5, 0xFF
    RBEQ  r0, r0, __cr_next
__cr_zero:
    SB    r0, FIELD_BASE       # 行 0 = 0
    SB    r0, FIELD_BASE+1
    JALR

# ---- 渲染帧 DMA 输出（v3.1）：fputc 写 ram_ext 缓冲，render 末尾 DMA 发 UART ----
# fputc 用 r14/r15（俄罗斯方块段不用这两个寄存器，安全）；DMA 用轮询 cnt 等完成
fputc:                       # 入参 r7=字符；写 FRAME_BUF+FRAME_IDX(16bit)
    # 调度器 GAME 模式保存 r12-r14（GAME_S1-3），r15 会被调度器覆盖，勿用
    LBU   r13, FRAME_IDX_LO
    LBU   r14, FRAME_IDX_HI
    ADDI  r14, r14, 0xC0     # 高字节 = 0xC0 + HI（帧 >255 时地址到 0xC100）
    SIND  r7, r14, r13
    ADDI  r13, r13, 1        # 16 位自增（LO 回绕时进位 HI）
    ANDI  r12, r13, 0xFF
    SB    r13, FRAME_IDX_LO
    RBNE  r12, r0, __fputc_done
    LBU   r12, FRAME_IDX_HI
    ADDI  r12, r12, 1
    SB    r12, FRAME_IDX_HI
__fputc_done:
    JALR

fput_crlf:
    ADDI  r7, r0, '\r'
    RJAL  fputc
    ADDI  r7, r0, '\n'
    RJAL  fputc
    JALR

fprint_hex:                   # 入参 r7=字节 → 2 位 hex（帧版；r10 备份原字节，fprint_hexdigit 破坏 r7/r8/r9）
    ADDI  r8, r7, 0
    ADDI  r10, r7, 0
    SRLI  r8, r8, 4
    ANDI  r8, r8, 0xF
    RJAL  fprint_hexdigit
    ANDI  r8, r10, 0xF
    RJAL  fprint_hexdigit
    JALR

fprint_hexdigit:              # 入参 r8=0-15 → 1 个 hex 字符（帧版）
    ADDI  r9, r8, 0
    ADDI  r8, r0, 10
    RBLTU r9, r8, __fhd_num
    ADDI  r7, r9, 0x37
    RJAL  fputc
    JALR
__fhd_num:
    ADDI  r7, r9, '0'
    RJAL  fputc
    JALR

wait_dma:                     # 等 DMA 完成（cnt==0；首帧 cnt=0 直接过）
    LBU   r1, DMA_CNT_HI
    RBNE  r1, r0, wait_dma
    LBU   r1, DMA_CNT_LO
    RBNE  r1, r0, wait_dma
    JALR

dma_frame_send:               # 配置 DMA：ini=0xC000(bank0) → des=UART + 触发
    SB    r0, DMA_INI
    LBU   r1, FRAME_IDX_LO
    LBU   r2, FRAME_IDX_HI
    ADDI  r3, r0, 0x71         # cnt 寄存器基址 0x7100（地址字节=高字节）
    SIND  r1, r3, r2           # cnt={地址[7:0]=HI, 数据=LO} → 16 位帧长（319=0x13F）
    SB    r0, DMA_DES
    SB    r0, DMA_BANK
    SB    r0, DMA_TRIG
    JALR

render:
    SB    r0, FRAME_IDX_LO      # 帧指针清零（16bit）
    SB    r0, FRAME_IDX_HI
    RJAL  wait_dma               # 等上一帧 DMA 完成（首帧 cnt=0 直接过）
    # 清 render_mask（SIND 循环 40 字节）
    ADDI  r1, r0, 0x94
    ADDI  r2, r0, 0x50
    ADDI  r3, r0, 40
__clr_ren:
    SIND  r0, r1, r2
    ADDI  r2, r2, 1
    ADDI  r3, r3, 0xFF
    RBNE  r3, r0, __clr_ren
    # 叠方块 4 格（render_cell = set_cell + 基址 0x50）
    ADDI  r13, r0, 0x50
    LBU   r3, P_ROW1
    LBU   r4, P_COL1
    RJAL  set_cell
    LBU   r3, P_ROW2
    LBU   r4, P_COL2
    RJAL  set_cell
    LBU   r3, P_ROW3
    LBU   r4, P_COL3
    RJAL  set_cell
    LBU   r3, P_ROW4
    LBU   r4, P_COL4
    RJAL  set_cell
    # 顶边框（帧缓冲）
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    RJAL  fput_crlf
    # 20 行循环
    ADDI  r17, r0, 0            # r17 = 行
__r_loop:
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r3, r17, 0
    SLLI  r2, r3, 1
    ADDI  r1, r0, 0x94
    ADDI  r5, r2, 0
    LIND  r6, r1, r2           # field lo
    ADDI  r2, r5, 1
    LIND  r7, r1, r2           # field hi
    ADDI  r2, r5, 0x50         # render lo 地址
    LIND  r4, r1, r2
    ADDI  r2, r5, 0x51         # render hi 地址
    LIND  r8, r1, r2
    OR    r6, r6, r4
    OR    r7, r7, r8
    ADDI  r1, r6, 0
    ADDI  r2, r7, 0
    RJAL  print_cells
    ADDI  r7, r0, '@'
    RJAL  fputc
    RJAL  fput_crlf
    ADDI  r17, r17, 1
    ADDI  r1, r17, 0
    ADDI  r2, r0, 20
    RBLTU r1, r2, __r_loop
    # 底边框（帧缓冲）
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    ADDI  r7, r0, '@'
    RJAL  fputc
    RJAL  fput_crlf
    # SCORE 行（帧版）
    ADDI  r7, r0, 'S'
    RJAL  fputc
    ADDI  r7, r0, 'C'
    RJAL  fputc
    ADDI  r7, r0, 'O'
    RJAL  fputc
    ADDI  r7, r0, 'R'
    RJAL  fputc
    ADDI  r7, r0, 'E'
    RJAL  fputc
    ADDI  r7, r0, ':'
    RJAL  fputc
    ADDI  r7, r0, ' '
    RJAL  fputc
    LBU   r7, G_SCORE
    RJAL  fprint_hex
    RJAL  fput_crlf
    # 诊断：render 完成标记
    ADDI  r1, r0, 0x55
    SB    r1, 0x948D
    # 发送 DMA（帧缓冲 0xC000 → UART）
    RJAL  dma_frame_send
    JALR

print_cells:               # r1=lo(8格) r2=hi(2格) -> 打印 10 格（帧版，fputc）
    ADDI  r6, r0, 8
__pc_loop:
    ANDI  r3, r1, 1
    RBNE  r3, r0, __pc_hash
    ADDI  r7, r0, '.'
    RJAL  fputc
    RBEQ  r0, r0, __pc_next
__pc_hash:
    ADDI  r7, r0, '#'
    RJAL  fputc
__pc_next:
    SRLI  r1, r1, 1
    ADDI  r6, r6, 0xFF
    RBNE  r6, r0, __pc_loop
    # hi 2 格（col 8/9）
    ADDI  r6, r0, 2
__pc_hi:
    ANDI  r3, r2, 1
    RBNE  r3, r0, __pc_hhash
    ADDI  r7, r0, '.'
    RJAL  fputc
    RBEQ  r0, r0, __pc_hnext
__pc_hhash:
    ADDI  r7, r0, '#'
    RJAL  fputc
__pc_hnext:
    SRLI  r2, r2, 1
    ADDI  r6, r6, 0xFF
    RBNE  r6, r0, __pc_hi
    JALR

drop_check:
    LBU   r1, TICK_LO
    LBU   r2, G_LAST_TICK
    RBNE  r1, r2, __dc_changed
    JALR
__dc_changed:
    SUB   r3, r1, r2
    SB    r1, G_LAST_TICK
    LBU   r1, G_ACC_LO
    ADD   r1, r1, r3
    SB    r1, G_ACC_LO
    SLTU  r4, r1, r3
    LBU   r2, G_ACC_HI
    ADD   r2, r2, r4
    SB    r2, G_ACC_HI
    ADDI  r6, r0, 0x13
    RBLTU r2, r6, __dc_done
    LBNE  r2, r6, __dc_drop
    LBU   r1, G_ACC_LO
    ADDI  r6, r0, 0x88
    RBLTU r1, r6, __dc_done
__dc_drop:
    SB    r0, G_ACC_LO
    SB    r0, G_ACC_HI
    RJAL  drop_piece
    RJAL  render
__dc_done:
    JALR

# ============================================================
# 扫雷（8x8）：连续输入 3 数字 = 横坐标 纵坐标 操作(1探雷 2插旗)
#   渲染复用俄罗斯方块 fputc（写 0xC000 帧缓冲）+ dma_frame_send（DMA 发 UART）
#   避让 fputc 破坏的 r12-r15；寄存器：r1/r2=地址 r3-r6=临时 r7=字符 r8-r11=状态
# ============================================================
.org 0x1000
minesweeper_start:
    ADDI  r1, r0, 1
    SB    r1, GAME_ACTIVE       # 独占 CPU（调度器只更新 TICK）
    SB    r0, 0xB000            # 选片 ram_ext bank0（渲染帧缓冲）
    # ---- 清 MS_MINE（64B）+ MS_VIEW（64B）----
    ADDI  r1, r0, 0x95
    ADDI  r2, r0, 0x00
    ADDI  r3, r0, 64
ms_clr_mine:
    SIND  r0, r1, r2
    ADDI  r2, r2, 1
    ADDI  r3, r3, 0xFF
    RBNE  r3, r0, ms_clr_mine
    ADDI  r2, r0, 0x40
    ADDI  r3, r0, 64
ms_clr_view:
    SIND  r0, r1, r2
    ADDI  r2, r2, 1
    ADDI  r3, r3, 0xFF
    RBNE  r3, r0, ms_clr_view
    # ---- 清游戏状态（防上次残留：MS_OVER 残留会误判 game over）----
    SB    r0, MS_OVER
    SB    r0, MS_OPEN
    SB    r0, MS_FLG
    SB    r0, MS_INN
    SB    r0, MS_COL
    SB    r0, MS_ROW
    SB    r0, MS_OP
    # ---- 布雷 10 颗（LCG 随机种子=TICK；重复雷重抽）----
    LBU   r5, TICK_LO
    ADDI  r5, r5, 0x13
    SB    r5, MS_SEED
    ADDI  r6, r0, 10            # 布雷计数
    ADDI  r1, r0, 0x95          # MINE 基址高字节
ms_place:
    LBU   r4, MS_SEED
    SLLI  r5, r4, 3             # s*8
    ADD   r5, r5, r4            # s*9
    SLLI  r3, r4, 2             # s*4
    ADD   r4, r5, r3            # s*13
    ADDI  r4, r4, 7             # s*13+7
    ANDI  r4, r4, 0xFF
    SB    r4, MS_SEED
    ANDI  r4, r4, 0x3F          # pos = 0-63
    ADD   r2, r0, r4            # 低字节 = pos
    LIND  r3, r1, r2            # 查重
    ANDI  r5, r3, 0x80
    RBNE  r5, r0, ms_place      # 已布雷，重抽
    ORI   r3, r3, 0x80          # 布雷
    SIND  r3, r1, r2
    ADDI  r6, r6, 0xFF
    RBNE  r6, r0, ms_place
    # ---- 邻雷数：布雷完成后，对每颗雷把 8 邻非雷格 count+1 ----
    #   布雷时 MINE 低 4 位已清零（clr），此处对雷格 8 邻 +1
    #   （MINE 用 r1=0x95 高字节，低字节=index）
    ADDI  r1, r0, 0x95
    ADDI  r2, r0, 0x00          # i = 0（扫 64 格）
ms_cnt_outer:
    LIND  r3, r1, r2            # MINE[i]
    ANDI  r4, r3, 0x80
    RBNE  r4, r0, ms_cnt_isMine # 是雷 → 处理它的 8 邻
    ADDI  r2, r2, 1             # 非雷跳过
    ADDI  r4, r0, 64
    RBLTU r2, r4, ms_cnt_outer
    RBEQ  r0, r0, ms_after_cnt
ms_cnt_isMine:
    SRLI  r6, r2, 3             # row = i>>3
    ANDI  r7, r2, 7             # col = i&7
    ADDI  r3, r0, 0xFF          # dr = -1
ms_cnt_dr:
    ADDI  r4, r0, 0xFF          # dc = -1
ms_cnt_dc:
    ADD   r8, r6, r3            # nr = row+dr
    ADD   r9, r7, r4            # nc = col+dc
    SLTIU r10, r8, 8            # nr<8（负数=255 也 >=8，天然越界）
    RBEQ  r10, r0, ms_cnt_nxt   # nr>=8 越界
    SLTIU r11, r9, 8            # nc<8
    RBEQ  r11, r0, ms_cnt_nxt   # nc>=8 越界
    # nr,nc 都在 0-7 → 邻格 index = nr*8+nc
    SLLI  r8, r8, 3             # nr*8
    ADD   r10, r8, r9           # nidx（0-63）
    ADDI  r11, r0, 0x95         # 基址高字节
    LIND  r13, r11, r10         # 读邻居 MINE
    ANDI  r14, r13, 0x80
    RBNE  r14, r0, ms_cnt_nxt   # 邻格是雷，跳过（雷格不累加）
    ADDI  r13, r13, 1           # 非雷邻格 count+1
    ANDI  r13, r13, 0x0F
    SIND  r13, r11, r10
ms_cnt_nxt:
    ADDI  r4, r4, 1
    ADDI  r5, r0, 2
    RBLTU r4, r5, ms_cnt_dc    # dc: -1,0,1
    ADDI  r3, r3, 1
    ADDI  r5, r0, 2
    RBLTU r3, r5, ms_cnt_dr    # dr: -1,0,1
    ADDI  r2, r2, 1
    ADDI  r5, r0, 64
    RBLTU r2, r5, ms_cnt_outer
ms_after_cnt:
    # ---- 渲染棋盘 ----
    RJAL  ms_render
ms_loop:
    # 输入：连续 3 数字（col,row,op）；'0' 退出
    RJAL  ms_getchar
    RBEQ  r7, r0, ms_loop       # 无字符 → 继续等
    ADDI  r8, r0, '0'
    RBEQ  r7, r8, __ms_done     # '0' → 退出
    # 数字? '1'-'8'
    ADDI  r8, r0, '1'
    RBLTU r7, r8, ms_loop       # <'1' 忽略
    ADDI  r8, r0, '9'
    RBLTU r7, r8, __ms_digit    # <='8' 是数字
    RBEQ  r0, r0, ms_loop
__ms_digit:
    SUBI  r7, r7, '0'           # 数字 1-8
    LBU   r8, MS_INN
    RBNE  r8, r0, __ms_d2
    SB    r7, MS_COL            # 第1数：横坐标
    ADDI  r8, r0, 1
    SB    r8, MS_INN
    RBEQ  r0, r0, ms_loop
__ms_d2:
    ADDI  r9, r0, 1
    RBNE  r8, r9, __ms_d3
    SB    r7, MS_ROW            # 第2数：纵坐标
    ADDI  r8, r0, 2
    SB    r8, MS_INN
    RBEQ  r0, r0, ms_loop
__ms_d3:
    SB    r7, MS_OP             # 第3数：操作(1探 2旗)
    SB    r0, MS_INN
    # ---- 执行 ----
    RJAL  ms_do
    RJAL  ms_render
    LBU   r1, MS_OVER
    RBNE  r1, r0, __ms_gameover
    RBEQ  r0, r0, ms_loop
__ms_gameover:
    # 显示结果 + 退出回 game 子菜单
    RJAL  ms_over_msg
    SB    r0, GAME_ACTIVE
    ADDI  r1, r0, 1
    SB    r1, MENU
    RJAL  game_menu
    JALR
__ms_done:
    SB    r0, GAME_ACTIVE
    ADDI  r1, r0, 1
    SB    r1, MENU
    RJAL  game_menu
    JALR

# ---- 扫雷子程序 ----
# ms_getchar: 从 RING 弹 1 字符 → r7（无字符则返回 0）；破坏 r1/r2/r3/r8
ms_getchar:
    LBU   r1, RX_WR
    LBU   r2, RX_RD
    RBNE  r1, r2, __mgc_have
    ADDI  r7, r0, 0             # 空
    JALR
__mgc_have:
    # 弹字符：按 RD 0-7 读 RING{RD}，RD++
    ADDI  r3, r0, 7
    RBNE  r2, r3, __mgc_6
    LBU   r7, RX_RING7
    RBEQ  r0, r0, __mgc_inc
__mgc_6:
    ADDI  r3, r0, 6
    RBNE  r2, r3, __mgc_5
    LBU   r7, RX_RING6
    RBEQ  r0, r0, __mgc_inc
__mgc_5:
    ADDI  r3, r0, 5
    RBNE  r2, r3, __mgc_4
    LBU   r7, RX_RING5
    RBEQ  r0, r0, __mgc_inc
__mgc_4:
    ADDI  r3, r0, 4
    RBNE  r2, r3, __mgc_3
    LBU   r7, RX_RING4
    RBEQ  r0, r0, __mgc_inc
__mgc_3:
    ADDI  r3, r0, 3
    RBNE  r2, r3, __mgc_2
    LBU   r7, RX_RING3
    RBEQ  r0, r0, __mgc_inc
__mgc_2:
    ADDI  r3, r0, 2
    RBNE  r2, r3, __mgc_1
    LBU   r7, RX_RING2
    RBEQ  r0, r0, __mgc_inc
__mgc_1:
    ADDI  r3, r0, 1
    RBNE  r2, r3, __mgc_0
    LBU   r7, RX_RING1
    RBEQ  r0, r0, __mgc_inc
__mgc_0:
    LBU   r7, RX_RING0
__mgc_inc:
    ADDI  r2, r2, 1
    ANDI  r2, r2, 7
    SB    r2, RX_RD
    JALR

# ms_do: 执行 MS_COL/MS_ROW/MS_OP 操作；op=1 探雷 op=2 插旗
#   index = (row-1)*8 + (col-1)；破坏 r1-r6 r8-r11
ms_do:
    LBU   r3, MS_ROW
    ADDI  r3, r3, 0xFF          # row-1
    SLLI  r3, r3, 3             # (row-1)*8
    LBU   r4, MS_COL
    ADDI  r4, r4, 0xFF          # col-1
    ADD   r3, r3, r4            # index
    LBU   r5, MS_OP
    ADDI  r6, r0, 1
    RBNE  r5, r6, __msdo_flag
    RJAL  ms_probe              # 探雷
    # 胜利判定：探开后 MS_OPEN==54 → 全探开
    LBU   r6, MS_OPEN
    ADDI  r8, r0, 54
    RBNE  r6, r8, __msdo_done
    ADDI  r8, r0, 2
    SB    r8, MS_OVER
__msdo_done:
    JALR
__msdo_flag:
    RJAL  ms_flag               # 插旗
    JALR

# ms_flag: 插旗/拔旗（MS_VIEW[index] 0↔1）；index=r3
ms_flag:
    ADDI  r1, r0, 0x95
    ADDI  r2, r3, 0x40          # VIEW 基址 0x9540 + index
    LIND  r4, r1, r2
    ADDI  r5, r0, 1
    RBNE  r4, r5, __msf_set     # !=1 → 设为旗
    SIND  r0, r1, r2            # 拔旗
    LBU   r4, MS_FLG
    ADDI  r4, r4, 0xFF
    SB    r4, MS_FLG
    JALR
__msf_set:
    SIND  r5, r1, r2            # 插旗
    LBU   r4, MS_FLG
    ADDI  r4, r4, 1
    SB    r4, MS_FLG
    JALR

# ms_probe: 探雷（index=r3）；雷→死(MS_OVER=1) 非雷→探开
ms_probe:
    ADDI  r1, r0, 0x95
    ADDI  r2, r3, 0x00          # MINE 基址 0x9500 + index
    LIND  r4, r1, r2            # MINE[index]
    ANDI  r5, r4, 0x80
    RBNE  r5, r0, __msp_mine    # 是雷
    # 非雷：VIEW[index] 已探? 若未探则探开
    ADDI  r2, r3, 0x40
    LIND  r5, r1, r2            # VIEW[index]
    RBNE  r5, r0, __msp_skip    # 已探/旗 → 不动
    ADDI  r5, r0, 2             # VIEW=2 已探
    SIND  r5, r1, r2
    LBU   r5, MS_OPEN
    ADDI  r5, r5, 1
    SB    r5, MS_OPEN
    # 若 MINE[index] 邻雷数=0 → 洪水展开
    ANDI  r6, r4, 0x0F
    RBNE  r6, r0, __msp_skip
    RJAL  ms_flood              # 洪水展开
__msp_skip:
    JALR
__msp_mine:
    ADDI  r5, r0, 1
    SB    r5, MS_OVER           # 踩雷死
    # 标出所有雷（VIEW=3，渲染显示 *）
    ADDI  r6, r0, 0             # i = 0
__msp_reveal:
    ADDI  r2, r6, 0x00
    LIND  r4, r1, r2            # MINE[i]
    ANDI  r5, r4, 0x80
    RBEQ  r5, r0, __msp_rv_next # 非雷跳过
    ADDI  r2, r6, 0x40
    ADDI  r5, r0, 3             # VIEW=3 标雷
    SIND  r5, r1, r2
__msp_rv_next:
    ADDI  r6, r6, 1
    ADDI  r5, r0, 64
    RBLTU r6, r5, __msp_reveal
    JALR

# ms_flood: 从 index(r3) 开始 DFS 洪水展开（4 邻；0 雷区扩散）
#   MS_QUEUE[64] 作栈：push QUEUE[sp++]=x，pop QUEUE[--sp]；sp=0 空
#   破坏 r1-r6 r8-r12
ms_flood:
    ADDI  r1, r0, 0x95
    ADDI  r4, r0, 0             # sp = 0
    # push 起点
    ADDI  r2, r3, 0x88          # QUEUE 基址低字节 0x88
    SIND  r3, r1, r2
    ADDI  r4, r4, 1             # sp = 1
msf_loop:
    RBNE  r4, r0, __msf_pop     # sp>0 继续
    JALR                        # 空栈 → 完成
__msf_pop:
    ADDI  r4, r4, 0xFF          # sp-1
    ANDI  r4, r4, 0x3F
    ADDI  r2, r4, 0x88
    LIND  r3, r1, r2            # pop → r3 = idx
    # row = idx>>3, col = idx&7
    SRLI  r8, r3, 3
    ANDI  r9, r3, 7
    # ---- 上 (row-1,col) ----
    ADDI  r10, r8, 0xFF
    ADDI  r11, r9, 0
    RJAL  msf_adj
    # ---- 下 (row+1,col) ----
    ADDI  r10, r8, 1
    ADDI  r11, r9, 0
    RJAL  msf_adj
    # ---- 左 (row,col-1) ----
    ADDI  r10, r8, 0
    ADDI  r11, r9, 0xFF
    RJAL  msf_adj
    # ---- 右 (row,col+1) ----
    ADDI  r10, r8, 0
    ADDI  r11, r9, 1
    RJAL  msf_adj
    RBEQ  r0, r0, msf_loop
# msf_adj: 探开 4 邻 (r10=row, r11=col)；越界/已探/雷跳过；0 雷 push
msf_adj:
    SLTIU r6, r10, 8
    RBEQ  r6, r0, __msfa_out
    SLTIU r6, r11, 8
    RBEQ  r6, r0, __msfa_out
    SLLI  r6, r10, 3
    ADD   r6, r6, r11           # nidx
    # VIEW[nidx] 已探?
    ADDI  r2, r6, 0x40
    LIND  r12, r1, r2
    RBNE  r12, r0, __msfa_out
    # MINE[nidx] 非雷?
    ADDI  r2, r6, 0x00
    LIND  r12, r1, r2
    ANDI  r12, r12, 0x80
    RBNE  r12, r0, __msfa_out
    # 探开：VIEW=2
    ADDI  r2, r6, 0x40
    ADDI  r12, r0, 2
    SIND  r12, r1, r2
    LBU   r12, MS_OPEN
    ADDI  r12, r12, 1
    SB    r12, MS_OPEN
    # 0 雷 → push
    ADDI  r2, r6, 0x00
    LIND  r12, r1, r2
    ANDI  r12, r12, 0x0F
    RBNE  r12, r0, __msfa_out
    ADDI  r2, r6, 0x88
    SIND  r6, r1, r2
    ADDI  r4, r4, 1
    ANDI  r4, r4, 0x3F
__msfa_out:
    JALR

# ms_render: 清帧指针 → 画 8x8 棋盘 → DMA 发送；破坏 r1-r11
ms_render:
    SB    r0, FRAME_IDX_LO
    SB    r0, FRAME_IDX_HI
    RJAL  wait_dma              # 等上一帧
    ADDI  r9, r0, 0             # row
__msr_row:
    ADDI  r10, r0, 0            # col
__msr_col:
    # 画 "["
    ADDI  r7, r0, '['
    RJAL  fputc
    # index = row*8+col；读 VIEW
    SLLI  r3, r9, 3
    ADD   r3, r3, r10
    ADDI  r1, r0, 0x95
    ADDI  r2, r3, 0x40
    LIND  r4, r1, r2            # VIEW[index]
    ADDI  r5, r0, 2
    RBNE  r4, r5, __msr_f       # VIEW==2 → 数字
    # 已探：显示 MINE 邻雷数
    ADDI  r2, r3, 0x00
    LIND  r6, r1, r2
    ANDI  r6, r6, 0x0F
    ADDI  r7, r6, '0'
    RJAL  fputc
    RBEQ  r0, r0, __msr_close
__msr_f:
    ADDI  r5, r0, 1
    RBNE  r4, r5, __msr_un      # VIEW==1 → 旗
    ADDI  r7, r0, 'F'
    RJAL  fputc
    RBEQ  r0, r0, __msr_close
__msr_un:
    # VIEW==3 → 踩雷（*）；VIEW==0 → 空格
    ADDI  r5, r0, 3
    RBNE  r4, r5, __msr_blank
    ADDI  r7, r0, '*'
    RJAL  fputc
    RBEQ  r0, r0, __msr_close
__msr_blank:
    ADDI  r7, r0, ' '
    RJAL  fputc
__msr_close:
    ADDI  r7, r0, ']'
    RJAL  fputc
    ADDI  r10, r10, 1
    ADDI  r8, r0, 8
    RBLTU r10, r8, __msr_col
    RJAL  fput_crlf             # 行尾换行
    ADDI  r9, r9, 1
    RBLTU r9, r8, __msr_row
    RJAL  dma_frame_send        # 发帧
    JALR

# ms_over_msg: 显示踩雷/胜利消息（先等棋盘 DMA 发完，避免混排）
ms_over_msg:
    RJAL  wait_dma              # 等棋盘帧发完（GAME OVER 才能安全直发）
    LBU   r1, MS_OVER
    ADDI  r2, r0, 1
    RBNE  r1, r2, __mso_win
    .puts "\r\n GAME OVER\r\n"
    JALR
__mso_win:
    .puts "\r\n CLEARED!\r\n"
    JALR

.org 0x208
    IRET                       # GPIO2 ISR（未用，防御）

.org 0x228
    IRET                       # GPIO1 ISR（未用，防御）

.org 0x248
    RBEQ  r0, r0, sched_body    # timer 向量 → 调度器主体（不链接，保返回栈）

.org 0x260
uart_isr:                      # UART RX：压入环形缓冲（8 槽，prio2 最高，ISR 内无派发）
    SB    r1, UART_S1          # 保存 r1,r2,r3（ISR 最高优先级，无嵌套，固定槽安全）
    SB    r2, UART_S2
    SB    r3, UART_S3
    LBU   r1, UART             # 字符
    LBU   r2, RX_WR
    LBU   r3, RX_RD
    # 满? (WR+1)&7 == RD → 丢弃
    ADDI  r2, r2, 1
    ANDI  r2, r2, 7
    RBNE  r2, r3, __ur_room
    RBEQ  r0, r0, __ur_restore
__ur_room:
    LBU   r2, RX_WR
    # 按 WR(0-7) 写 RING{WR}
    ADDI  r3, r0, 7
    RBNE  r2, r3, __ur_w6
    SB    r1, RX_RING7
    RBEQ  r0, r0, __ur_winc
__ur_w6:
    ADDI  r3, r0, 6
    RBNE  r2, r3, __ur_w5
    SB    r1, RX_RING6
    RBEQ  r0, r0, __ur_winc
__ur_w5:
    ADDI  r3, r0, 5
    RBNE  r2, r3, __ur_w4
    SB    r1, RX_RING5
    RBEQ  r0, r0, __ur_winc
__ur_w4:
    ADDI  r3, r0, 4
    RBNE  r2, r3, __ur_w3
    SB    r1, RX_RING4
    RBEQ  r0, r0, __ur_winc
__ur_w3:
    ADDI  r3, r0, 3
    RBNE  r2, r3, __ur_w2
    SB    r1, RX_RING3
    RBEQ  r0, r0, __ur_winc
__ur_w2:
    ADDI  r3, r0, 2
    RBNE  r2, r3, __ur_w1
    SB    r1, RX_RING2
    RBEQ  r0, r0, __ur_winc
__ur_w1:
    ADDI  r3, r0, 1
    RBNE  r2, r3, __ur_w0
    SB    r1, RX_RING1
    RBEQ  r0, r0, __ur_winc
__ur_w0:
    SB    r1, RX_RING0
    NOP                        # 拉开 __ur_winc 距离到 +3（bytmov=0 不可编码）
__ur_winc:
    LBU   r2, RX_WR
    ADDI  r2, r2, 1
    ANDI  r2, r2, 7
    SB    r2, RX_WR
__ur_restore:
    LBU   r1, UART_S1
    LBU   r2, UART_S2
    LBU   r3, UART_S3
    IRET

# ============================================================
# shell_append（@0x2A0，ISR 与调度器之间的空闲区）
#   入参 r7=字符: 存 LINE_BUF[CURSOR]，cursor++，重置空闲超时，echo
#   仅任务0 调用（返回栈走任务0 区域；寄存器用任务0 分区 + r7-r11）
# ============================================================
.org 0x2A0
shell_append:
    LBU   r1, CURSOR
    # 存 r7 到 LINE_BUF[cursor]，按 cursor(0-7) 展开
    ADDI  r8, r0, 7
    RBNE  r1, r8, __ap6
    SB    r7, LINE_BUF7
    RBEQ  r0, r0, __ap_done
__ap6:
    ADDI  r8, r0, 6
    RBNE  r1, r8, __ap5
    SB    r7, LINE_BUF6
    RBEQ  r0, r0, __ap_done
__ap5:
    ADDI  r8, r0, 5
    RBNE  r1, r8, __ap4
    SB    r7, LINE_BUF5
    RBEQ  r0, r0, __ap_done
__ap4:
    ADDI  r8, r0, 4
    RBNE  r1, r8, __ap3
    SB    r7, LINE_BUF4
    RBEQ  r0, r0, __ap_done
__ap3:
    ADDI  r8, r0, 3
    RBNE  r1, r8, __ap2
    SB    r7, LINE_BUF3
    RBEQ  r0, r0, __ap_done
__ap2:
    ADDI  r8, r0, 2
    RBNE  r1, r8, __ap1
    SB    r7, LINE_BUF2
    RBEQ  r0, r0, __ap_done
__ap1:
    ADDI  r8, r0, 1
    RBNE  r1, r8, __ap0
    SB    r7, LINE_BUF1
    RBEQ  r0, r0, __ap_done
__ap0:
    SB    r7, LINE_BUF0
    NOP                        # 拉开 __ap_done 距离到 +3（bytmov=0 不可编码）
__ap_done:
    LBU   r1, CURSOR
    ADDI  r1, r1, 1
    SB    r1, CURSOR
    SB    r0, LAST_CR
    SB    r0, IDLE_CNT           # 重置空闲累计（有新字符）
    LJAL  putc                  # 后向（putc@0x100）: echo
    JALR

# ============================================================
# 任务 1（@0x400）: CNT1++ + 内联延迟（后台）
# ============================================================
.org 0x400
task1_entry:
task1_loop:
    LBU   r6, CNT1
    ADDI  r6, r6, 1
    SB    r6, CNT1
    ADDI  r5, r0, 0x10        # 外层 16 次 ≈ 80ms
dl1_o:
    ADDI  r4, r0, 0xFF
dl1_m:
    ADDI  r3, r0, 0xFF
dl1_i:
    ADDI  r3, r3, 0xFF
    LBNE  r3, r0, dl1_i
    ADDI  r4, r4, 0xFF
    LBNE  r4, r0, dl1_m
    ADDI  r5, r5, 0xFF
    LBNE  r5, r0, dl1_o
    LBEQ  r0, r0, task1_loop

# ============================================================
# 任务 2（@0x500）: CNT2++ + 内联延迟（后台）
# ============================================================
.org 0x500
task2_entry:
task2_loop:
    LBU   r6, CNT2
    ADDI  r6, r6, 1
    SB    r6, CNT2
    ADDI  r5, r0, 0x40        # 外层 64 次 ≈ 320ms
dl2_o:
    ADDI  r4, r0, 0xFF
dl2_m:
    ADDI  r3, r0, 0xFF
dl2_i:
    ADDI  r3, r3, 0xFF
    LBNE  r3, r0, dl2_i
    ADDI  r4, r4, 0xFF
    LBNE  r4, r0, dl2_m
    ADDI  r5, r5, 0xFF
    LBNE  r5, r0, dl2_o
    LBEQ  r0, r0, task2_loop

# ============================================================
# 调度器主体（@0x300）
#   寄存器: r12-r15 临时；r7-r11 共享子程序暂存组（按任务存/取）。
#   切换: 读 slot0 → 存 PC+j+r7-r11 → CUR=(CUR+1)%3 → 载新任务
#         PC+j+r7-r11 → 2×紧邻 SB 改写 pc_addr[0] → IRET。
# ============================================================
.org 0x300
sched_body:
    SB    r0, TIMER_ACK        # ack timer（电平锁存，必清）
    LBU   r15, GAME_ACTIVE
    RBNE  r15, r0, __sg_game   # GAME 模式 → 只更新 TICK，不切任务（用 r15：游戏核心用 r12/r13，勿碰）
    LBU   r13, SLOT0_LO
    LBU   r14, SLOT0_HI
    LBU   r15, CUR_TASK
    # ---- 存旧任务 PC + j + r7-r11 ----
    RBNE  r15, r0, __sv_t1     # 前向
    ADDI  r12, r253, 0         # r12 = j
    SB    r13, TCB0_PC_LO
    SB    r14, TCB0_PC_HI
    SB    r12, TCB0_J
    SB    r7, TCB0_R7
    SB    r8, TCB0_R8
    SB    r9, TCB0_R9
    SB    r10, TCB0_R10
    SB    r11, TCB0_R11
    RBEQ  r0, r0, __pick        # 前向
__sv_t1:
    ADDI  r12, r0, 1
    RBNE  r15, r12, __sv_t2     # 前向
    ADDI  r12, r253, 0
    SB    r13, TCB1_PC_LO
    SB    r14, TCB1_PC_HI
    SB    r12, TCB1_J
    SB    r7, TCB1_R7
    SB    r8, TCB1_R8
    SB    r9, TCB1_R9
    SB    r10, TCB1_R10
    SB    r11, TCB1_R11
    RBEQ  r0, r0, __pick        # 前向
__sv_t2:
    ADDI  r12, r253, 0
    SB    r13, TCB2_PC_LO
    SB    r14, TCB2_PC_HI
    SB    r12, TCB2_J
    SB    r7, TCB2_R7
    SB    r8, TCB2_R8
    SB    r9, TCB2_R9
    SB    r10, TCB2_R10
    SB    r11, TCB2_R11
__pick:
    # ---- TICK 计数 ----
    LBU   r12, TICK_LO
    ADDI  r12, r12, 1
    SB    r12, TICK_LO
    RBNE  r12, r0, __nowrap     # 前向
    LBU   r12, TICK_HI
    ADDI  r12, r12, 1
    SB    r12, TICK_HI
__nowrap:
    # ---- CUR = (CUR+1) % 3 ----
    ADDI  r15, r15, 1
    ADDI  r12, r0, 3
    RBNE  r15, r12, __nw2       # 前向
    ADDI  r15, r0, 0
    NOP                        # 拉开 __nw2 距离到 +3（bytmov=0 不可编码）
__nw2:
    SB    r15, CUR_TASK
    # ---- 载新任务 PC + j + r7-r11 ----
    RBNE  r15, r0, __ld_t1      # 前向
    SBI   BASE_MAIN, BASELINE   # 切 baseline → 任务0 窗口（0 恒等）
    LBU   r13, TCB0_PC_HI
    LBU   r14, TCB0_PC_LO
    LBU   r12, TCB0_J
    ADDI  r253, r12, 0          # 恢复任务0 调用栈指针
    LBU   r7, TCB0_R7
    LBU   r8, TCB0_R8
    LBU   r9, TCB0_R9
    LBU   r10, TCB0_R10
    LBU   r11, TCB0_R11
    RBEQ  r0, r0, __redirect    # 前向
__ld_t1:
    ADDI  r12, r0, 1
    RBNE  r15, r12, __ld_t2     # 前向
    SBI   BASE_TASK1, BASELINE  # 切 baseline → 任务1 窗口（0x16）
    LBU   r13, TCB1_PC_HI
    LBU   r14, TCB1_PC_LO
    LBU   r12, TCB1_J
    ADDI  r253, r12, 0          # 恢复任务1 调用栈指针
    LBU   r7, TCB1_R7
    LBU   r8, TCB1_R8
    LBU   r9, TCB1_R9
    LBU   r10, TCB1_R10
    LBU   r11, TCB1_R11
    RBEQ  r0, r0, __redirect    # 前向
__ld_t2:
    SBI   BASE_TASK2, BASELINE  # 切 baseline → 任务2 窗口（0x26）
    LBU   r13, TCB2_PC_HI
    LBU   r14, TCB2_PC_LO
    LBU   r12, TCB2_J
    ADDI  r253, r12, 0          # 恢复任务2 调用栈指针
    LBU   r7, TCB2_R7
    LBU   r8, TCB2_R8
    LBU   r9, TCB2_R9
    LBU   r10, TCB2_R10
    LBU   r11, TCB2_R11
__redirect:
    # ---- 改写 pc_addr[0] = 新任务断点（2 条紧邻 SB，原子）----
    SB    r13, IRQW             # [11:8]
    SB    r14, IRQW             # [7:0]
    IRET                       # → 新任务断点

__sg_game:                     # GAME 模式：更新 TICK + 恢复 + IRET（不切任务）
    SB    r12, GAME_S1
    SB    r13, GAME_S2
    SB    r14, GAME_S3
    LBU   r12, TICK_LO
    ADDI  r12, r12, 1
    SB    r12, TICK_LO
    RBNE  r12, r0, __sg_done
    LBU   r12, TICK_HI
    ADDI  r12, r12, 1
    SB    r12, TICK_HI
__sg_done:
    LBU   r12, GAME_S1
    LBU   r13, GAME_S2
    LBU   r14, GAME_S3
    IRET

# ============================================================
# 菜单/命令区（@0x540，任务0 独用；.puts 逐字符调 putc）
# ============================================================
.org 0x540

# ---- init 横幅（模块大写）----
menu_main:
    .puts "--- MAIN MENU ---"
    RJAL  put_crlf
    .puts " 1. CREDITS    CREDITS"
    RJAL  put_crlf
    .puts " 2. STATUS     STATUS"
    RJAL  put_crlf
    .puts " 3. GAME       TETRIS/MINE"
    RJAL  put_crlf
    .puts " 0. MENU       SHOW MENU"
    RJAL  put_crlf
    RJAL  flush_rx             # 打印完成 → 丢弃积压按键
    JALR

print_prompt:
    .puts "> "
    JALR

cmd_credits:
    .puts "--- CREDITS ---"
    RJAL  put_crlf
    .puts " System: RTOS"
    RJAL  put_crlf
    .puts " Author: Justin (hardware) & Agent (software)"
    RJAL  put_crlf
    .puts " HW: Justin Green MCU (Zynq 7010)"
    RJAL  put_crlf
    RJAL  flush_rx             # 打印完成 → 丢弃积压按键
    JALR

cmd_status:
    .puts "--- STATUS ---\r\n"
    .puts " CPU: 50 MHz\r\n"
    .puts " TASKS: 3\r\n"
    .puts " RAM: "
    ADDI  r7, r0, 1             # fill = 1（RAM_USED 296B/16KB ≈ 2%，20 段里 1 段）
    ADDI  r8, r0, 20            # width = 20
    RJAL  print_bar
    .puts " 2% (296B/16KB)\r\n"
    .puts " 0. BACK TO MENU\r\n"
    RJAL  flush_rx             # 打印完成 → 丢弃积压按键
    ADDI  r1, r0, 3
    SB    r1, MENU
    ADDI  r1, r0, 2
    JALR

# ---- 进度条: 打印 [####....]，入参 r7=填充段数 r8=总段数 ----
#    用 r17-r19(任务0高区，跨 putc 不破坏) + r1/r2(低区供分支比较)
print_bar:
    ADDI  r17, r0, 0            # cnt = 0
    ADDI  r18, r7, 0            # fill
    ADDI  r19, r8, 0            # width
    ADDI  r7, r0, '['
    RJAL  putc
pb_loop:
    ADDI  r1, r17, 0
    ADDI  r2, r18, 0
    RBLTU r1, r2, pb_hash       # cnt < fill → '#'
    ADDI  r7, r0, '.'
    RJAL  putc
    RBEQ  r0, r0, pb_next
pb_hash:
    ADDI  r7, r0, '#'
    RJAL  putc
pb_next:
    ADDI  r17, r17, 1           # cnt++
    ADDI  r1, r17, 0
    ADDI  r2, r19, 0
    LBLTU r1, r2, pb_loop       # cnt < width → 继续
    ADDI  r7, r0, ']'
    RJAL  putc
    JALR

# ---- 命令: LED 翻转（一次）----
tick_bookkeeping:
    LBU   r1, TICK_LO
    LBU   r2, LAST_TICK
    RBNE  r1, r2, __tb_ch
    JALR                        # tick 未变 → 直接返回
__tb_ch:
    SUB   r7, r1, r2
    SB    r1, LAST_TICK
    LBU   r1, IDLE_CNT
    ADD   r1, r1, r7
    SB    r1, IDLE_CNT
    JALR

__tb_ch:
    SUB   r7, r1, r2
    SB    r1, LAST_TICK
    LBU   r1, IDLE_CNT
    ADD   r1, r1, r7
    SB    r1, IDLE_CNT
    LBU   r8, LED_MODE
    RBNE  r8, r0, __tb_blink
    JALR                        # 非闪烁模式 → 返回
__tb_blink:
    LBU   r8, BLINK_ACC_LO
    ADD   r8, r8, r7
    SLTU  r9, r8, r7            # carry = new_lo < diff
    LBU   r8, BLINK_ACC_HI
    ADD   r8, r8, r9
    ADDI  r9, r0, 0x04
    RBLTU r8, r9, __tb_done     # hi < 4 → 未到 0.25s
    LBNE  r8, r9, __tb_toggle
    LBU   r8, BLINK_ACC_LO
    ADDI  r9, r0, 0xE2
    RBLTU r8, r9, __tb_done     # hi==4 且 lo<0xE2 → 未到
__tb_toggle:
    LBU   r8, LED_STATE
    XORI  r8, r8, 0x40
    SB    r8, GPIO
    SB    r8, LED_STATE
__tb_done:
    JALR

# ---- 阻塞等 tick（wait_ticks）----
#   阈值 WAIT_TH_LO/HI(16bit)，用 CD_LAST + CD_ACC(16bit) 累计 TICK_LO 差值。
#   任务0 每 3 tick 才跑，须累加差值而非递减。返回时 CD_ACC 已 ≥ 阈值。
