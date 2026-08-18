# ============================================================
# rtos_shell.asm — 抢占式 RTOS + 菜单式 shell（基于 rtos_preempt v1.3）
#   内核: 时间片轮转 3 任务；任务0=shell(前台)，任务1/2=后台计数。
#   硬件依赖:
#     · irq 读 slot0:    LBU 0x5000/0x5001（被抢占任务断点）
#     · IRQ_W 改写:      2×紧邻 SB 0x5000 改写 pc_addr[0] → IRET
#     · regs[254]=返回栈指针 j（LJAL/RJAL 压、JALR 弹；指令可读写）
#   shell v2.3 菜单式界面（全英文）:
#     · init 横幅(模块大写) + 主菜单(每项一行) + 可进入/回退子菜单(倒计时/LED)
#     · 命令: 主菜单 1.init 2.count 3.led 4.version 5.status 0.menu
#            倒计时子菜单 1-9 设秒数(结束后 LED 频闪 5s)、0 返回
#            LED 子菜单 1.翻转 2.闪烁 0.返回
#     · 信息视图(MENU=3): version/status/init 打印 + "0. BACK TO MENU"，只认 0
#       返回 → 屏蔽主菜单指令；status 带 RAM 用量 # 进度条(print_bar)
#     · 单字符命令 + 空闲超时执行（串口无回车也能用）
#     · tick 驱动: 1s=5000 tick(0.2ms/格), blink 每 0.25s(1250 tick)翻转
#   汇编器增强: .puts "..." 宏(逐字符 putc) + 自动 jpad(IRET W+2 垫层)。
#   新代码不手写 __jpad（汇编器自动补）；保留的旧代码仍带手写垫层。
#   寄存器分块:
#     任务0(shell): 低 r1/r2 + 高 r17-r21
#     任务1:         低 r3/r4 + 高 r22-r25（r22/23/24=延迟, r25=CNT1）
#     任务2:         低 r5/r6 + 高 r26-r29（r26/27/28=延迟, r29=CNT2）
#     调度器:       r12-r15 临时；共享子程序 r7-r11（调度器按任务保存/恢复）
#     r254=j 保留；r0=0, r255=tx_busy 只读
#   汇编: python tools/asm.py tools/rtos_shell.asm -o tools/rtos_shell.hex
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
.equ VIEW_TYPE   0x9127    # 信息视图类型: 0=init 1=version 2=status（MENU==3 时重显用）

# ============================================================
# 复位 → boot（也是任务 0 shell 的首次执行）
# ============================================================
.org 0x000
reset:
    ADDI  r254, r0, 0        # j=0：任务0 调用栈基址
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
    # ---- 内核初值 ----
    SB    r0, CUR_TASK
    SB    r0, TICK_LO
    SB    r0, TICK_HI
    # ---- 环形缓冲 + shell 状态初值 ----
    SB    r0, RX_WR
    SB    r0, RX_RD
    SB    r0, CURSOR
    SB    r0, LAST_CR
    SB    r0, IDLE_CNT
    SB    r0, LAST_TICK
    # ---- 菜单/倒计时/闪烁 状态初值 ----
    SB    r0, MENU
    SB    r0, CD_SEC
    SB    r0, LED_MODE
    SB    r0, VIEW_TYPE
    SB    r0, FLASH_CNT
    SB    r0, CD_LAST
    SB    r0, CD_ACC_LO
    SB    r0, CD_ACC_HI
    SB    r0, BLINK_ACC_LO
    SB    r0, BLINK_ACC_HI
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
    # ---- timer: 0x270F → 周期 10000 拍 = 0.2ms（5kHz 抢占）----
    ADDI  r1, r0, 0x0F
    SB    r1, TIMER_CNT0
    ADDI  r1, r0, 0x27
    SB    r1, TIMER_CNT1
    SB    r0, TIMER_CNT2
    SB    r0, TIMER_CNT3
    ADDI  r1, r0, 1
    SB    r1, TIMER_MODE
    # ---- 进入任务 0（shell）----
task0_entry:
    RJAL  menu_init           # init 横幅（模块大写）
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
    LBNE  r0, r0, __jpadS2a
__jpadS2a:
    RBNE  r2, r8, __sh_r6
    LBU   r7, RX_RING7
    LBNE  r0, r0, __jpadS2b
__jpadS2b:
    RBEQ  r0, r0, __sh_rdinc
__sh_r6:
    ADDI  r8, r0, 6
    LBNE  r0, r0, __jpadS2c
__jpadS2c:
    RBNE  r2, r8, __sh_r5
    LBU   r7, RX_RING6
    LBNE  r0, r0, __jpadS2d
__jpadS2d:
    RBEQ  r0, r0, __sh_rdinc
__sh_r5:
    ADDI  r8, r0, 5
    LBNE  r0, r0, __jpadS2e
__jpadS2e:
    RBNE  r2, r8, __sh_r4
    LBU   r7, RX_RING5
    LBNE  r0, r0, __jpadS2f
__jpadS2f:
    RBEQ  r0, r0, __sh_rdinc
__sh_r4:
    ADDI  r8, r0, 4
    LBNE  r0, r0, __jpadS2g
__jpadS2g:
    RBNE  r2, r8, __sh_r3
    LBU   r7, RX_RING4
    LBNE  r0, r0, __jpadS2h
__jpadS2h:
    RBEQ  r0, r0, __sh_rdinc
__sh_r3:
    ADDI  r8, r0, 3
    LBNE  r0, r0, __jpadS2i
__jpadS2i:
    RBNE  r2, r8, __sh_r2
    LBU   r7, RX_RING3
    LBNE  r0, r0, __jpadS2j
__jpadS2j:
    RBEQ  r0, r0, __sh_rdinc
__sh_r2:
    ADDI  r8, r0, 2
    LBNE  r0, r0, __jpadS2k
__jpadS2k:
    RBNE  r2, r8, __sh_r1
    LBU   r7, RX_RING2
    LBNE  r0, r0, __jpadS2l
__jpadS2l:
    RBEQ  r0, r0, __sh_rdinc
__sh_r1:
    ADDI  r8, r0, 1
    LBNE  r0, r0, __jpadS2m
__jpadS2m:
    RBNE  r2, r8, __sh_r0
    LBU   r7, RX_RING1
    LBNE  r0, r0, __jpadS2n
__jpadS2n:
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
    LBNE  r0, r0, __jpadS3a
__jpadS3a:
    RBNE  r7, r8, __sh_lf
    # \r → 执行（记录 LAST_CR 防 CRLF 双执行）
    ADDI  r1, r0, 1
    SB    r1, LAST_CR
    LBNE  r0, r0, __jpadS3g
__jpadS3g:
    RBEQ  r0, r0, __sh_exec
__sh_lf:
    # 换行 '\n'? 串口助手常用 \n 或 \r\n
    ADDI  r8, r0, '\n'
    LBNE  r0, r0, __jpadS3h
__jpadS3h:
    RBNE  r7, r8, __sh_bs
    LBU   r1, LAST_CR
    LBNE  r0, r0, __jpadS3i
__jpadS3i:
    RBNE  r1, r0, __lf_skip
    LBNE  r0, r0, __jpadS3j
__jpadS3j:
    RBEQ  r0, r0, __sh_exec
__lf_skip:
    SB    r0, LAST_CR
    LBNE  r0, r0, __jpadS3k
__jpadS3k:
    LBEQ  r0, r0, shell_loop
__sh_exec:
    # 执行: 换行 → 解析 → 重置 → 提示符（按 MENU）
    ADDI  r7, r0, '\n'
    LBNE  r0, r0, __jpadS3b
__jpadS3b:
    RJAL  putc
    LBNE  r0, r0, __jpadS3c
__jpadS3c:
    RJAL  shell_parse
    SB    r0, CURSOR
    LBNE  r0, r0, __jpadS3d
__jpadS3d:
    RJAL  print_prompt
    LBNE  r0, r0, __jpadS3f
__jpadS3f:
    LBEQ  r0, r0, shell_loop
__sh_bs:
    # 退格(0x7F 或 0x08)?
    ADDI  r8, r0, 0x7F
    LBNE  r0, r0, __jpadS4a
__jpadS4a:
    RBNE  r7, r8, __sh_bs2
    LBNE  r0, r0, __jpadS4h
__jpadS4h:
    RBEQ  r0, r0, __bs_do
__sh_bs2:
    ADDI  r8, r0, 0x08
    LBNE  r0, r0, __jpadS4i
__jpadS4i:
    RBNE  r7, r8, __sh_char
    # 退格: 若 CURSOR>0，cursor--，echo "\x08 \x08"
    LBU   r1, CURSOR
    LBNE  r0, r0, __jpadS4b
__jpadS4b:
    RBNE  r1, r0, __bs_do
    SB    r0, LAST_CR
    LBNE  r0, r0, __jpadS4c
__jpadS4c:
    LBEQ  r0, r0, shell_loop
__bs_do:
    ADDI  r1, r1, 0xFF
    SB    r1, CURSOR
    SB    r0, LAST_CR
    ADDI  r7, r0, 0x08
    LBNE  r0, r0, __jpadS4d
__jpadS4d:
    RJAL  putc
    ADDI  r7, r0, ' '
    LBNE  r0, r0, __jpadS4e
__jpadS4e:
    RJAL  putc
    ADDI  r7, r0, 0x08
    LBNE  r0, r0, __jpadS4f
__jpadS4f:
    RJAL  putc
    LBNE  r0, r0, __jpadS4g
__jpadS4g:
    LBEQ  r0, r0, shell_loop
__sh_char:
    # 普通字符: 若 CURSOR<8，调 shell_append 存行 + echo（append 在 0x2A0 区）
    LBU   r1, CURSOR
    ADDI  r8, r0, 8
    LBNE  r0, r0, __jpadS5a
__jpadS5a:
    RBLTU r1, r8, __ap_call
    SB    r0, LAST_CR
    LBNE  r0, r0, __jpadS5b
__jpadS5b:
    LBEQ  r0, r0, shell_loop     # 缓冲满，忽略
__ap_call:
    LBNE  r0, r0, __jpadS5c
__jpadS5c:
    RJAL  shell_append
    LBNE  r0, r0, __jpadS5d
__jpadS5d:
    LBEQ  r0, r0, shell_loop

# ============================================================
# 共享子程序（0x100 区，寄存器中立：只用 r7-r11，参数走 r7）
# ============================================================
.org 0x100
putc:                           # 入参 r7=字符；轮询 tx_busy（r255）后发送（破坏 r7,r8）
putc_wait:
    ADDI  r8, r255, 0
    LBNE  r0, r0, __jpadP9
__jpadP9:
    LBNE  r8, r0, putc_wait
    SB    r7, UART
    LBNE  r0, r0, __jpadP10
__jpadP10:
    JALR

put_crlf:                       # "\r\n"（破坏 r7）
    ADDI  r7, r0, '\r'
    LBNE  r0, r0, __jpadP11
__jpadP11:
    LJAL  putc
    ADDI  r7, r0, '\n'
    LBNE  r0, r0, __jpadP12
__jpadP12:
    LJAL  putc
    JALR

print_hexdigit:                 # 入参 r7=0-15 → 1 个 hex 字符（破坏 r7,r8）
    ADDI  r8, r0, 9
    LBNE  r0, r0, __jpadP13
__jpadP13:
    RBLTU r8, r7, __phx_af     # 前向
    ADDI  r7, r7, '0'
    LBNE  r0, r0, __jpadP14
__jpadP14:
    LJAL  putc
    JALR
__phx_af:
    ADDI  r7, r7, 55            # 'A'-10 = 55
    LBNE  r0, r0, __jpadP15
__jpadP15:
    LJAL  putc
    JALR

print_hex:                      # 入参 r7=字节 → 2 位 hex（破坏 r7,r8,r9）
    ADDI  r9, r7, 0             # r9 暂存输入（调度器保 r7-r11）
    LBNE  r0, r0, __jpadP16
__jpadP16:
    SRLI  r7, r9, 4
    LBNE  r0, r0, __jpadP17
__jpadP17:
    LJAL  print_hexdigit
    ANDI  r7, r9, 0x0F
    LBNE  r0, r0, __jpadP18
__jpadP18:
    LJAL  print_hexdigit
    JALR

# ============================================================
# shell 解析（0x100 区，任务0 独用，返回栈走任务0 区域）
#   按 MENU 状态分派：主菜单 / 倒计时子菜单 / LED 子菜单
# ============================================================
shell_parse:                    # 解析 LINE_BUF[0..CURSOR-1]
    LBU   r7, CURSOR
    RBNE  r7, r0, __sp_have
    JALR                        # 空行 → 直接返回（只重新提示）
__sp_have:
    LBU   r1, MENU
    RBNE  r1, r0, __sp_sub      # MENU != 0 → 子菜单
    # ===== 主菜单 =====
    ADDI  r8, r0, 1
    RBNE  r7, r8, __sp_m_word   # len != 1 → 试试单词别名
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, '1'
    RBNE  r7, r8, __sp_m2
    RJAL  cmd_init
    JALR
__sp_m2:
    ADDI  r8, r0, '2'
    RBNE  r7, r8, __sp_m3
    ADDI  r1, r0, 1
    SB    r1, MENU
    RJAL  menu_countdown
    JALR
__sp_m3:
    ADDI  r8, r0, '3'
    RBNE  r7, r8, __sp_m4
    ADDI  r1, r0, 2
    SB    r1, MENU
    RJAL  menu_led
    JALR
__sp_m4:
    ADDI  r8, r0, '4'
    RBNE  r7, r8, __sp_m5
    RJAL  cmd_version
    JALR
__sp_m5:
    ADDI  r8, r0, '5'
    RBNE  r7, r8, __sp_m0
    RJAL  cmd_status
    JALR
__sp_m0:
    ADDI  r8, r0, '0'
    RBNE  r7, r8, __sp_unknown
    RJAL  menu_main
    JALR
__sp_m_word:
    # 单词别名: help(4)/init(4)/stat(4), led(3)/ver(3)/cnt(3)
    ADDI  r8, r0, 4
    RBNE  r7, r8, __sp_w3
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, 'h'
    RBNE  r7, r8, __sp_w_init
    LBU   r7, LINE_BUF1
    ADDI  r8, r0, 'e'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF2
    ADDI  r8, r0, 'l'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF3
    ADDI  r8, r0, 'p'
    RBNE  r7, r8, __sp_unknown
    RJAL  menu_main
    JALR
__sp_w_init:
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, 'i'
    RBNE  r7, r8, __sp_w_stat
    LBU   r7, LINE_BUF1
    ADDI  r8, r0, 'n'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF2
    ADDI  r8, r0, 'i'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF3
    ADDI  r8, r0, 't'
    RBNE  r7, r8, __sp_unknown
    RJAL  cmd_init
    JALR
__sp_w_stat:
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, 's'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF1
    ADDI  r8, r0, 't'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF2
    ADDI  r8, r0, 'a'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF3
    ADDI  r8, r0, 't'
    RBNE  r7, r8, __sp_unknown
    RJAL  cmd_status
    JALR
__sp_w3:
    ADDI  r8, r0, 3
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, 'l'
    RBNE  r7, r8, __sp_w_ver
    LBU   r7, LINE_BUF1
    ADDI  r8, r0, 'e'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF2
    ADDI  r8, r0, 'd'
    RBNE  r7, r8, __sp_unknown
    ADDI  r1, r0, 2
    SB    r1, MENU
    RJAL  menu_led
    JALR
__sp_w_ver:
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, 'v'
    RBNE  r7, r8, __sp_w_cnt
    LBU   r7, LINE_BUF1
    ADDI  r8, r0, 'e'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF2
    ADDI  r8, r0, 'r'
    RBNE  r7, r8, __sp_unknown
    RJAL  cmd_version
    JALR
__sp_w_cnt:
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, 'c'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF1
    ADDI  r8, r0, 'n'
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF2
    ADDI  r8, r0, 't'
    RBNE  r7, r8, __sp_unknown
    ADDI  r1, r0, 1
    SB    r1, MENU
    RJAL  menu_countdown
    JALR
__sp_sub:
    # ===== 子菜单/视图（屏蔽主菜单指令：只认本层命令 + 0）=====
    ADDI  r8, r0, 1
    RBNE  r1, r8, __sp_v3       # MENU==1 → 倒计时子菜单
    ADDI  r8, r0, 1
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, '1'
    RBLTU r7, r8, __sp_cd_zero   # digit < '1' → 只可能是 '0'
    ADDI  r8, r0, '9'
    RBLTU r8, r7, __sp_unknown   # digit > '9' → 未知
    RJAL  cmd_countdown
    JALR
__sp_cd_zero:
    ADDI  r8, r0, '0'
    RBNE  r7, r8, __sp_unknown
    SB    r0, MENU
    RJAL  menu_main
    JALR
__sp_v3:
    ADDI  r8, r0, 3
    RBNE  r1, r8, __sp_led       # MENU==3 → 信息视图（version/status/init）
    ADDI  r8, r0, 1
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, '0'
    RBNE  r7, r8, __sp_unknown   # 视图只认 '0' 返回
    SB    r0, MENU
    RJAL  menu_main
    JALR
__sp_led:
    ADDI  r8, r0, 2
    RBNE  r1, r8, __sp_unknown   # MENU==2 → LED 子菜单
    ADDI  r8, r0, 1
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, '1'
    RBNE  r7, r8, __sp_led2
    RJAL  cmd_led_toggle
    JALR
__sp_led2:
    ADDI  r8, r0, '2'
    RBNE  r7, r8, __sp_led0
    RJAL  cmd_led_blink
    JALR
__sp_led0:
    ADDI  r8, r0, '0'
    RBNE  r7, r8, __sp_unknown
    SB    r0, MENU
    RJAL  menu_main
    JALR
__sp_unknown:
    # 未知字符: "?" + 重新显示当前页面（含返回菜单提示）
    ADDI  r7, r0, '?'
    LBNE  r0, r0, __jpadV15
__jpadV15:
    LJAL  putc
    LBNE  r0, r0, __jpadV16
__jpadV16:
    LJAL  put_crlf
    LBU   r1, MENU
    ADDI  r8, r0, 1
    RBNE  r1, r8, __spu_v3
    RJAL  menu_countdown        # MENU==1 → 倒计时子菜单
    JALR
__spu_v3:
    ADDI  r8, r0, 3
    RBNE  r1, r8, __spu_led
    LBU   r1, VIEW_TYPE
    RBNE  r1, r0, __spu_ver
    RJAL  cmd_init              # VIEW_TYPE=0 → init
    JALR
__spu_ver:
    ADDI  r8, r0, 1
    RBNE  r1, r8, __spu_stat
    RJAL  cmd_version           # VIEW_TYPE=1 → version
    JALR
__spu_stat:
    RJAL  cmd_status            # VIEW_TYPE=2 → status
    JALR
__spu_led:
    ADDI  r8, r0, 2
    RBNE  r1, r8, __spu_main
    RJAL  menu_led              # MENU==2 → LED 子菜单
    JALR
__spu_main:
    RJAL  menu_main             # MENU==0 → 主菜单
    JALR

# ============================================================
# ISR 向量
# ============================================================
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
    LBNE  r0, r0, __jpadU0
__jpadU0:
    RBNE  r2, r3, __ur_room
    LBNE  r0, r0, __jpadU1
__jpadU1:
    RBEQ  r0, r0, __ur_restore
__ur_room:
    LBU   r2, RX_WR
    # 按 WR(0-7) 写 RING{WR}
    ADDI  r3, r0, 7
    LBNE  r0, r0, __jpadU2
__jpadU2:
    RBNE  r2, r3, __ur_w6
    SB    r1, RX_RING7
    LBNE  r0, r0, __jpadU3
__jpadU3:
    RBEQ  r0, r0, __ur_winc
__ur_w6:
    ADDI  r3, r0, 6
    LBNE  r0, r0, __jpadU4
__jpadU4:
    RBNE  r2, r3, __ur_w5
    SB    r1, RX_RING6
    LBNE  r0, r0, __jpadU5
__jpadU5:
    RBEQ  r0, r0, __ur_winc
__ur_w5:
    ADDI  r3, r0, 5
    LBNE  r0, r0, __jpadU6
__jpadU6:
    RBNE  r2, r3, __ur_w4
    SB    r1, RX_RING5
    LBNE  r0, r0, __jpadU7
__jpadU7:
    RBEQ  r0, r0, __ur_winc
__ur_w4:
    ADDI  r3, r0, 4
    LBNE  r0, r0, __jpadU8
__jpadU8:
    RBNE  r2, r3, __ur_w3
    SB    r1, RX_RING4
    LBNE  r0, r0, __jpadU9
__jpadU9:
    RBEQ  r0, r0, __ur_winc
__ur_w3:
    ADDI  r3, r0, 3
    LBNE  r0, r0, __jpadU10
__jpadU10:
    RBNE  r2, r3, __ur_w2
    SB    r1, RX_RING3
    LBNE  r0, r0, __jpadU11
__jpadU11:
    RBEQ  r0, r0, __ur_winc
__ur_w2:
    ADDI  r3, r0, 2
    LBNE  r0, r0, __jpadU12
__jpadU12:
    RBNE  r2, r3, __ur_w1
    SB    r1, RX_RING2
    LBNE  r0, r0, __jpadU13
__jpadU13:
    RBEQ  r0, r0, __ur_winc
__ur_w1:
    ADDI  r3, r0, 1
    LBNE  r0, r0, __jpadU14
__jpadU14:
    RBNE  r2, r3, __ur_w0
    SB    r1, RX_RING1
    LBNE  r0, r0, __jpadU15
__jpadU15:
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
    LBNE  r0, r0, __jpadA0
__jpadA0:
    RBNE  r1, r8, __ap6
    SB    r7, LINE_BUF7
    LBNE  r0, r0, __jpadA1
__jpadA1:
    RBEQ  r0, r0, __ap_done
__ap6:
    ADDI  r8, r0, 6
    LBNE  r0, r0, __jpadA2
__jpadA2:
    RBNE  r1, r8, __ap5
    SB    r7, LINE_BUF6
    LBNE  r0, r0, __jpadA3
__jpadA3:
    RBEQ  r0, r0, __ap_done
__ap5:
    ADDI  r8, r0, 5
    LBNE  r0, r0, __jpadA4
__jpadA4:
    RBNE  r1, r8, __ap4
    SB    r7, LINE_BUF5
    LBNE  r0, r0, __jpadA5
__jpadA5:
    RBEQ  r0, r0, __ap_done
__ap4:
    ADDI  r8, r0, 4
    LBNE  r0, r0, __jpadA6
__jpadA6:
    RBNE  r1, r8, __ap3
    SB    r7, LINE_BUF4
    LBNE  r0, r0, __jpadA7
__jpadA7:
    RBEQ  r0, r0, __ap_done
__ap3:
    ADDI  r8, r0, 3
    LBNE  r0, r0, __jpadA8
__jpadA8:
    RBNE  r1, r8, __ap2
    SB    r7, LINE_BUF3
    LBNE  r0, r0, __jpadA9
__jpadA9:
    RBEQ  r0, r0, __ap_done
__ap2:
    ADDI  r8, r0, 2
    LBNE  r0, r0, __jpadA10
__jpadA10:
    RBNE  r1, r8, __ap1
    SB    r7, LINE_BUF2
    LBNE  r0, r0, __jpadA11
__jpadA11:
    RBEQ  r0, r0, __ap_done
__ap1:
    ADDI  r8, r0, 1
    LBNE  r0, r0, __jpadA12
__jpadA12:
    RBNE  r1, r8, __ap0
    SB    r7, LINE_BUF1
    LBNE  r0, r0, __jpadA13
__jpadA13:
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
    LBNE  r0, r0, __jpadA14
__jpadA14:
    LJAL  putc                  # 后向（putc@0x100）: echo
    JALR

# ============================================================
# 任务 1（@0x400）: CNT1++ + 内联延迟（后台）
# ============================================================
.org 0x400
task1_entry:
task1_loop:
    LBU   r25, CNT1
    ADDI  r25, r25, 1
    SB    r25, CNT1
    ADDI  r22, r0, 0x10        # 外层 16 次 ≈ 80ms
    LBNE  r0, r0, __jpadD1
__jpadD1:
dl1_o:
    ADDI  r23, r0, 0xFF
dl1_m:
    ADDI  r24, r0, 0xFF
dl1_i:
    ADDI  r24, r24, 0xFF
    ADDI  r3, r24, 0           # 高区 → 低区拷贝供分支
    LBNE  r0, r0, __jpadD3
__jpadD3:
    LBNE  r3, r0, dl1_i
    ADDI  r23, r23, 0xFF
    ADDI  r3, r23, 0
    LBNE  r0, r0, __jpadD4
__jpadD4:
    LBNE  r3, r0, dl1_m
    ADDI  r22, r22, 0xFF
    ADDI  r3, r22, 0
    LBNE  r0, r0, __jpadD5
__jpadD5:
    LBNE  r3, r0, dl1_o
    LBNE  r0, r0, __jpadD2
__jpadD2:
    LBEQ  r0, r0, task1_loop

# ============================================================
# 任务 2（@0x500）: CNT2++ + 内联延迟（后台）
# ============================================================
.org 0x500
task2_entry:
task2_loop:
    LBU   r29, CNT2
    ADDI  r29, r29, 1
    SB    r29, CNT2
    ADDI  r26, r0, 0x40        # 外层 64 次 ≈ 320ms
    LBNE  r0, r0, __jpadE1
__jpadE1:
dl2_o:
    ADDI  r27, r0, 0xFF
dl2_m:
    ADDI  r28, r0, 0xFF
dl2_i:
    ADDI  r28, r28, 0xFF
    ADDI  r5, r28, 0           # 高区 → 低区拷贝供分支
    LBNE  r0, r0, __jpadE3
__jpadE3:
    LBNE  r5, r0, dl2_i
    ADDI  r27, r27, 0xFF
    ADDI  r5, r27, 0
    LBNE  r0, r0, __jpadE4
__jpadE4:
    LBNE  r5, r0, dl2_m
    ADDI  r26, r26, 0xFF
    ADDI  r5, r26, 0
    LBNE  r0, r0, __jpadE5
__jpadE5:
    LBNE  r5, r0, dl2_o
    LBNE  r0, r0, __jpadE2
__jpadE2:
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
    LBU   r13, SLOT0_LO
    LBU   r14, SLOT0_HI
    LBU   r15, CUR_TASK
    # ---- 存旧任务 PC + j + r7-r11 ----
    LBNE  r0, r0, __jpadS0
__jpadS0:
    RBNE  r15, r0, __sv_t1     # 前向
    ADDI  r12, r254, 0         # r12 = j
    SB    r13, TCB0_PC_LO
    SB    r14, TCB0_PC_HI
    SB    r12, TCB0_J
    SB    r7, TCB0_R7
    SB    r8, TCB0_R8
    SB    r9, TCB0_R9
    SB    r10, TCB0_R10
    SB    r11, TCB0_R11
    LBNE  r0, r0, __jpadS1
__jpadS1:
    RBEQ  r0, r0, __pick        # 前向
__sv_t1:
    ADDI  r12, r0, 1
    LBNE  r0, r0, __jpadS2
__jpadS2:
    RBNE  r15, r12, __sv_t2     # 前向
    ADDI  r12, r254, 0
    SB    r13, TCB1_PC_LO
    SB    r14, TCB1_PC_HI
    SB    r12, TCB1_J
    SB    r7, TCB1_R7
    SB    r8, TCB1_R8
    SB    r9, TCB1_R9
    SB    r10, TCB1_R10
    SB    r11, TCB1_R11
    LBNE  r0, r0, __jpadS3
__jpadS3:
    RBEQ  r0, r0, __pick        # 前向
__sv_t2:
    ADDI  r12, r254, 0
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
    LBNE  r0, r0, __jpadS4
__jpadS4:
    RBNE  r12, r0, __nowrap     # 前向
    LBU   r12, TICK_HI
    ADDI  r12, r12, 1
    SB    r12, TICK_HI
__nowrap:
    # ---- CUR = (CUR+1) % 3 ----
    ADDI  r15, r15, 1
    ADDI  r12, r0, 3
    LBNE  r0, r0, __jpadS5
__jpadS5:
    RBNE  r15, r12, __nw2       # 前向
    ADDI  r15, r0, 0
    NOP                        # 拉开 __nw2 距离到 +3（bytmov=0 不可编码）
__nw2:
    SB    r15, CUR_TASK
    # ---- 载新任务 PC + j + r7-r11 ----
    LBNE  r0, r0, __jpadS6
__jpadS6:
    RBNE  r15, r0, __ld_t1      # 前向
    LBU   r13, TCB0_PC_HI
    LBU   r14, TCB0_PC_LO
    LBU   r12, TCB0_J
    ADDI  r254, r12, 0          # 恢复任务0 调用栈指针
    LBU   r7, TCB0_R7
    LBU   r8, TCB0_R8
    LBU   r9, TCB0_R9
    LBU   r10, TCB0_R10
    LBU   r11, TCB0_R11
    LBNE  r0, r0, __jpadS7
__jpadS7:
    RBEQ  r0, r0, __redirect    # 前向
__ld_t1:
    ADDI  r12, r0, 1
    LBNE  r0, r0, __jpadS8
__jpadS8:
    RBNE  r15, r12, __ld_t2     # 前向
    LBU   r13, TCB1_PC_HI
    LBU   r14, TCB1_PC_LO
    LBU   r12, TCB1_J
    ADDI  r254, r12, 0          # 恢复任务1 调用栈指针
    LBU   r7, TCB1_R7
    LBU   r8, TCB1_R8
    LBU   r9, TCB1_R9
    LBU   r10, TCB1_R10
    LBU   r11, TCB1_R11
    LBNE  r0, r0, __jpadS9
__jpadS9:
    RBEQ  r0, r0, __redirect    # 前向
__ld_t2:
    LBU   r13, TCB2_PC_HI
    LBU   r14, TCB2_PC_LO
    LBU   r12, TCB2_J
    ADDI  r254, r12, 0          # 恢复任务2 调用栈指针
    LBU   r7, TCB2_R7
    LBU   r8, TCB2_R8
    LBU   r9, TCB2_R9
    LBU   r10, TCB2_R10
    LBU   r11, TCB2_R11
__redirect:
    # ---- 改写 pc_addr[0] = 新任务断点（2 条紧邻 SB，原子）----
    SB    r13, IRQW             # [11:8]
    SB    r14, IRQW             # [7:0]
    LBNE  r0, r0, __jpadS10
__jpadS10:
    IRET                       # → 新任务断点

# ============================================================
# 菜单/命令区（@0x540，任务0 独用；.puts 逐字符调 putc）
# ============================================================
.org 0x540

# ---- init 横幅（模块大写）----
menu_init:
    .puts "=== JUSTIN GREEN MCU ===\r\n"
    .puts "RTOS SHELL v2.3\r\n"
    .puts "MODULES: UART TIMER GPIO RAM OK\r\n\r\n"
    JALR

# ---- 主菜单（每项一行）----
menu_main:
    .puts "--- MAIN MENU ---\r\n"
    .puts " 1. INIT       BOOT INFO\r\n"
    .puts " 2. COUNTDOWN  COUNTDOWN\r\n"
    .puts " 3. LED        LED SETTINGS\r\n"
    .puts " 4. VERSION    VERSION\r\n"
    .puts " 5. STATUS     STATUS\r\n"
    .puts " 0. MENU       SHOW MENU\r\n"
    JALR

# ---- 倒计时子菜单 ----
menu_countdown:
    .puts "--- COUNTDOWN ---\r\n"
    .puts " 1-9: SET SECONDS (FLASH LED 5s AFTER)\r\n"
    .puts " 0. BACK TO MENU\r\n"
    JALR

# ---- LED 子菜单 ----
menu_led:
    .puts "--- LED SETTINGS ---\r\n"
    .puts " 1. TOGGLE MODE\r\n"
    .puts " 2. BLINK MODE\r\n"
    .puts " 0. BACK TO MENU\r\n"
    JALR

# ---- 提示符（按 MENU: 0=主 1=倒计时 2=LED 3=信息视图）----
print_prompt:
    LBU   r7, MENU
    ADDI  r8, r0, 3
    RBLTU r7, r8, __pp_normal   # MENU < 3 → 正常菜单提示符
    .puts "0> "
    JALR
__pp_normal:
    ADDI  r8, r0, 1
    RBNE  r7, r8, __pp_led
    .puts "CD> "
    JALR
__pp_led:
    ADDI  r8, r0, 2
    RBNE  r7, r8, __pp_main
    .puts "LED> "
    JALR
__pp_main:
    .puts "> "
    JALR

# ---- 命令: init（信息视图）----
cmd_init:
    RJAL  menu_init
    .puts " 0. BACK TO MENU\r\n"
    ADDI  r1, r0, 3
    SB    r1, MENU
    SB    r0, VIEW_TYPE         # 视图类型 0=init
    JALR

# ---- 命令: version（信息视图）----
cmd_version:
    .puts "--- VERSION ---\r\n"
    .puts " RTOS SHELL v2.3\r\n"
    .puts " Author: Justin (hardware) & Agent (software)\r\n"
    .puts " HW: Justin Green MCU (Zynq 7010)\r\n"
    .puts " 0. BACK TO MENU\r\n"
    ADDI  r1, r0, 3
    SB    r1, MENU
    ADDI  r1, r0, 1
    SB    r1, VIEW_TYPE         # 视图类型 1=version
    JALR

# ---- 命令: status（信息视图 + RAM bar）----
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
    ADDI  r1, r0, 3
    SB    r1, MENU
    ADDI  r1, r0, 2
    SB    r1, VIEW_TYPE         # 视图类型 2=status
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
cmd_led_toggle:
    LBU   r8, LED_STATE
    XORI  r8, r8, 0x40
    SB    r8, GPIO
    SB    r8, LED_STATE
    SB    r0, LED_MODE         # 停止闪烁
    .puts "TOGGLE OK\r\n 0. BACK TO MENU\r\n"
    JALR

# ---- 命令: LED 闪烁（持续，tick 驱动）----
cmd_led_blink:
    ADDI  r8, r0, 1
    SB    r8, LED_MODE
    SB    r0, BLINK_ACC_LO
    SB    r0, BLINK_ACC_HI
    .puts "BLINK ON\r\n 0. BACK TO MENU\r\n"
    JALR

# ---- tick 记账（每轮 shell_loop 调）----
#   累加 IDLE_CNT（空闲超时用）；LED_MODE==1 时按 0.25s(1250 tick) 翻转 LED
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
    LBU   r8, LED_MODE
    RBNE  r8, r0, __tb_blink
    JALR                        # 非闪烁模式 → 返回
__tb_blink:
    LBU   r8, BLINK_ACC_LO
    ADD   r8, r8, r7
    SB    r8, BLINK_ACC_LO
    SLTU  r9, r8, r7            # carry = new_lo < diff
    LBU   r8, BLINK_ACC_HI
    ADD   r8, r8, r9
    SB    r8, BLINK_ACC_HI
    ADDI  r9, r0, 0x04
    RBLTU r8, r9, __tb_done     # hi < 4 → 未到 0.25s
    LBNE  r8, r9, __tb_toggle
    LBU   r8, BLINK_ACC_LO
    ADDI  r9, r0, 0xE2
    RBLTU r8, r9, __tb_done     # hi==4 且 lo<0xE2 → 未到
__tb_toggle:
    SB    r0, BLINK_ACC_LO
    SB    r0, BLINK_ACC_HI
    LBU   r8, LED_STATE
    XORI  r8, r8, 0x40
    SB    r8, GPIO
    SB    r8, LED_STATE
__tb_done:
    JALR

# ---- 阻塞等 tick（wait_ticks）----
#   阈值 WAIT_TH_LO/HI(16bit)，用 CD_LAST + CD_ACC(16bit) 累计 TICK_LO 差值。
#   任务0 每 3 tick 才跑，须累加差值而非递减。返回时 CD_ACC 已 ≥ 阈值。
wait_ticks:
    LBU   r1, TICK_LO
    SB    r1, CD_LAST
    SB    r0, CD_ACC_LO
    SB    r0, CD_ACC_HI
__wt_loop:
    LBU   r1, TICK_LO
    LBU   r2, CD_LAST
    RBNE  r1, r2, __wt_ch
    LBEQ  r0, r0, __wt_loop
__wt_ch:
    SUB   r7, r1, r2
    SB    r1, CD_LAST
    LBU   r1, CD_ACC_LO
    ADD   r1, r1, r7
    SB    r1, CD_ACC_LO
    SLTU  r8, r1, r7            # carry = new_lo < diff
    LBU   r2, CD_ACC_HI
    ADD   r2, r2, r8
    SB    r2, CD_ACC_HI
    # CD_ACC >= WAIT_TH ?
    LBU   r1, CD_ACC_HI
    LBU   r2, WAIT_TH_HI
    RBLTU r1, r2, __wt_loop
    LBNE  r1, r2, __wt_done
    LBU   r1, CD_ACC_LO
    LBU   r2, WAIT_TH_LO
    RBLTU r1, r2, __wt_loop
__wt_done:
    JALR

# ---- 命令: 倒计时（阻塞，结束后 LED 频闪 5s）----
#   入参 r7 = '1'-'9' 数字字符
cmd_countdown:
    SUBI  r7, r7, '0'
    SB    r7, CD_SEC            # CD_SEC = 1-9 秒
    .puts "CD "
    LBU   r7, CD_SEC
    ADDI  r7, r7, '0'
    RJAL  putc
    .puts "s ["
    # 阈值 5000 = 0x1388（1s）
    ADDI  r8, r0, 0x88
    SB    r8, WAIT_TH_LO
    ADDI  r8, r0, 0x13
    SB    r8, WAIT_TH_HI
    # 重置 shell 空闲基准（防止结束后误超时执行空行）
    LBU   r8, TICK_LO
    SB    r8, LAST_TICK
    SB    r0, IDLE_CNT
__cd_sec_loop:
    RJAL  wait_ticks
    LBU   r8, CD_SEC
    ADDI  r8, r8, 0xFF
    SB    r8, CD_SEC
    ADDI  r7, r0, '#'
    RJAL  putc
    LBU   r8, CD_SEC          # putc 破坏 r8 → 从 RAM 重载后再判断
    LBNE  r8, r0, __cd_sec_loop
    # 倒计时结束 → 换行 → 频闪 5s
    RJAL  put_crlf
    .puts "[FLASH 5s]\r\n"
    # 阈值 1250 = 0x04E2（0.25s），20 次 × 0.25s = 5s
    ADDI  r8, r0, 0xE2
    SB    r8, WAIT_TH_LO
    ADDI  r8, r0, 0x04
    SB    r8, WAIT_TH_HI
    ADDI  r8, r0, 20
    SB    r8, FLASH_CNT
__cd_flash_loop:
    RJAL  wait_ticks
    LBU   r8, LED_STATE
    XORI  r8, r8, 0x40
    SB    r8, GPIO
    SB    r8, LED_STATE
    LBU   r8, FLASH_CNT
    ADDI  r8, r8, 0xFF
    SB    r8, FLASH_CNT
    LBNE  r8, r0, __cd_flash_loop
    # 关闭 LED
    SB    r0, GPIO
    SB    r0, LED_STATE
    .puts "\r\nDONE\r\n"
    # 回主菜单
    SB    r0, MENU
    RJAL  menu_main
    JALR
