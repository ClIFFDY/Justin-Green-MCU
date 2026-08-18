# ============================================================
# rtos_shell.asm — 抢占式 RTOS + 命令行 shell（基于 rtos_preempt v1.3）
#   内核: 时间片轮转 3 任务；任务0=shell(前台)，任务1/2=后台计数。
#   硬件依赖:
#     · irq 读 slot0:    LBU 0x5000/0x5001（被抢占任务断点）
#     · IRQ_W 改写:      2×紧邻 SB 0x5000 改写 pc_addr[0] → IRET
#     · regs[254]=返回栈指针 j（LJAL/RJAL 压、JALR 弹；指令可读写）
#   v1.3 寄存器分块 + 调用栈分区 + 共享子程序(r7-r11)。
#   shell 输入: RAM 环形缓冲 RX_RING(8字节) + WR/RD 指针。
#     · 生产者 = uart_isr(prio2)：每字符压入 RING{WR}，WR=(WR+1)&7
#     · 消费者 = shell：RING{RD} 弹出，RD=(RD+1)&7
#     · WR 只被 ISR 写、RD 只被 shell 写 → 无数据竞争（满/空误判自愈）
#     · ISA 无索引寻址 → ring 访问按 WR/RD 展开(8路分支)
#     8 槽够撑 "help\r\n"(6 字符)突发；4 槽会因回显 TX 阻塞 + 抢占挤掉后缀。
#   行结束: '\r' 和 '\n' 都执行；'\n' 紧跟 '\r'(CRLF) 时跳过防双执行。
#   命令: help / cnt / led。行缓冲 LINE_BUF(8字节)+CURSOR。
#   寄存器分块:
#     任务0(shell): 低 r1/r2 + 高 r17-r21（r17-21 本次未用，保留分区）
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
    # 横幅 "mc-shell\r\n"
    ADDI  r7, r0, 'm'
    LBNE  r0, r0, __jpadB0
__jpadB0:
    RJAL  putc
    ADDI  r7, r0, 'c'
    LBNE  r0, r0, __jpadB1
__jpadB1:
    RJAL  putc
    ADDI  r7, r0, '-'
    LBNE  r0, r0, __jpadB2
__jpadB2:
    RJAL  putc
    ADDI  r7, r0, 's'
    LBNE  r0, r0, __jpadB3
__jpadB3:
    RJAL  putc
    ADDI  r7, r0, 'h'
    LBNE  r0, r0, __jpadB4
__jpadB4:
    RJAL  putc
    ADDI  r7, r0, 'e'
    LBNE  r0, r0, __jpadB5
__jpadB5:
    RJAL  putc
    ADDI  r7, r0, 'l'
    LBNE  r0, r0, __jpadB6
__jpadB6:
    RJAL  putc
    ADDI  r7, r0, 'l'
    LBNE  r0, r0, __jpadB7
__jpadB7:
    RJAL  putc
    RJAL  put_crlf
    # 提示符 "> "
    ADDI  r7, r0, '>'
    LBNE  r0, r0, __jpadB8
__jpadB8:
    RJAL  putc
    ADDI  r7, r0, ' '
    LBNE  r0, r0, __jpadB9
__jpadB9:
    RJAL  putc
shell_loop:
    # ---- 等字符: WR != RD ? ----
    LBU   r1, RX_WR
    LBU   r2, RX_RD
    LBNE  r0, r0, __jpadS1a
__jpadS1a:
    RBNE  r1, r2, __sh_have
    # ---- 无新字符: 空闲超时（串口无回车时也执行）----
    LBU   r1, TICK_LO
    LBU   r2, LAST_TICK
    LBNE  r0, r0, __jpadS1c
__jpadS1c:
    RBNE  r1, r2, __idle_tick
    LBNE  r0, r0, __jpadS1b
__jpadS1b:
    LBEQ  r0, r0, shell_loop
__idle_tick:
    SUB   r7, r1, r2          # r7 = 距上次检查经过的 tick 数（任务0 每 3 tick 才跑，须累加差值）
    SB    r1, LAST_TICK
    LBU   r1, IDLE_CNT
    ADD   r1, r1, r7          # IDLE_CNT += elapsed
    SB    r1, IDLE_CNT
    ADDI  r7, r0, 50
    LBNE  r0, r0, __jpadS1d
__jpadS1d:
    RBLTU r1, r7, __idle_ok   # <50 tick(≈10ms) 未到超时
    # 超时: 若行非空则执行
    LBU   r2, CURSOR
    LBNE  r0, r0, __jpadS1e
__jpadS1e:
    RBNE  r2, r0, __sh_exec
__idle_ok:
    LBNE  r0, r0, __jpadS1f
__jpadS1f:
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
    # 执行: 换行 → 解析 → 重置 → 提示符
    ADDI  r7, r0, '\n'
    LBNE  r0, r0, __jpadS3b
__jpadS3b:
    RJAL  putc
    LBNE  r0, r0, __jpadS3c
__jpadS3c:
    RJAL  shell_parse
    SB    r0, CURSOR
    ADDI  r7, r0, '>'
    LBNE  r0, r0, __jpadS3d
__jpadS3d:
    RJAL  putc
    ADDI  r7, r0, ' '
    LBNE  r0, r0, __jpadS3e
__jpadS3e:
    RJAL  putc
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
# shell 解析 + 命令处理（0x100 区，任务0 独用，返回栈走任务0 区域）
# ============================================================
shell_parse:                    # 解析 LINE_BUF[0..CURSOR-1]
    LBU   r7, CURSOR
    # 空行 → 直接返回（只重新提示）
    LBNE  r0, r0, __jpadV0a
__jpadV0a:
    RBNE  r7, r0, __sp_have
    JALR
__sp_have:
    ADDI  r8, r0, 4
    LBNE  r0, r0, __jpadV0
__jpadV0:
    RBNE  r7, r8, __sp_len3      # len != 4
    # len==4 → "help"
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, 'h'
    LBNE  r0, r0, __jpadV1
__jpadV1:
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF1
    ADDI  r8, r0, 'e'
    LBNE  r0, r0, __jpadV2
__jpadV2:
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF2
    ADDI  r8, r0, 'l'
    LBNE  r0, r0, __jpadV3
__jpadV3:
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF3
    ADDI  r8, r0, 'p'
    LBNE  r0, r0, __jpadV4
__jpadV4:
    RBNE  r7, r8, __sp_unknown
    LBNE  r0, r0, __jpadV5
__jpadV5:
    RJAL  cmd_help
    JALR
__sp_len3:
    ADDI  r8, r0, 3
    LBNE  r0, r0, __jpadV6
__jpadV6:
    RBNE  r7, r8, __sp_unknown   # len != 3
    # len==3 → "cnt"
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, 'c'
    LBNE  r0, r0, __jpadV7
__jpadV7:
    RBNE  r7, r8, __sp_led
    LBU   r7, LINE_BUF1
    ADDI  r8, r0, 'n'
    LBNE  r0, r0, __jpadV8
__jpadV8:
    RBNE  r7, r8, __sp_led
    LBU   r7, LINE_BUF2
    ADDI  r8, r0, 't'
    LBNE  r0, r0, __jpadV9
__jpadV9:
    RBNE  r7, r8, __sp_led
    LBNE  r0, r0, __jpadV10
__jpadV10:
    RJAL  cmd_cnt
    JALR
__sp_led:
    # "led"
    LBU   r7, LINE_BUF0
    ADDI  r8, r0, 'l'
    LBNE  r0, r0, __jpadV11
__jpadV11:
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF1
    ADDI  r8, r0, 'e'
    LBNE  r0, r0, __jpadV12
__jpadV12:
    RBNE  r7, r8, __sp_unknown
    LBU   r7, LINE_BUF2
    ADDI  r8, r0, 'd'
    LBNE  r0, r0, __jpadV13
__jpadV13:
    RBNE  r7, r8, __sp_unknown
    LBNE  r0, r0, __jpadV14
__jpadV14:
    RJAL  cmd_led
    JALR
__sp_unknown:
    ADDI  r7, r0, '?'
    LBNE  r0, r0, __jpadV15
__jpadV15:
    LJAL  putc
    LBNE  r0, r0, __jpadV16
__jpadV16:
    LJAL  put_crlf
    JALR

cmd_help:                       # "help cnt led\r\n"
    ADDI  r7, r0, 'h'
    LBNE  r0, r0, __jpadH0
__jpadH0:
    LJAL  putc
    ADDI  r7, r0, 'e'
    LBNE  r0, r0, __jpadH1
__jpadH1:
    LJAL  putc
    ADDI  r7, r0, 'l'
    LBNE  r0, r0, __jpadH2
__jpadH2:
    LJAL  putc
    ADDI  r7, r0, 'p'
    LBNE  r0, r0, __jpadH3
__jpadH3:
    LJAL  putc
    ADDI  r7, r0, ' '
    LBNE  r0, r0, __jpadH4
__jpadH4:
    LJAL  putc
    ADDI  r7, r0, 'c'
    LBNE  r0, r0, __jpadH5
__jpadH5:
    LJAL  putc
    ADDI  r7, r0, 'n'
    LBNE  r0, r0, __jpadH6
__jpadH6:
    LJAL  putc
    ADDI  r7, r0, 't'
    LBNE  r0, r0, __jpadH7
__jpadH7:
    LJAL  putc
    ADDI  r7, r0, ' '
    LBNE  r0, r0, __jpadH8
__jpadH8:
    LJAL  putc
    ADDI  r7, r0, 'l'
    LBNE  r0, r0, __jpadH9
__jpadH9:
    LJAL  putc
    ADDI  r7, r0, 'e'
    LBNE  r0, r0, __jpadH10
__jpadH10:
    LJAL  putc
    ADDI  r7, r0, 'd'
    LBNE  r0, r0, __jpadH11
__jpadH11:
    LJAL  putc
    LJAL  put_crlf
    JALR

cmd_cnt:                        # "t=xxxx c1=xx c2=xx\r\n"
    ADDI  r7, r0, 't'
    LBNE  r0, r0, __jpadC0
__jpadC0:
    LJAL  putc
    ADDI  r7, r0, '='
    LBNE  r0, r0, __jpadC1
__jpadC1:
    LJAL  putc
    LBU   r7, TICK_HI
    LBNE  r0, r0, __jpadC2
__jpadC2:
    LJAL  print_hex
    LBU   r7, TICK_LO
    LBNE  r0, r0, __jpadC3
__jpadC3:
    LJAL  print_hex
    ADDI  r7, r0, ' '
    LBNE  r0, r0, __jpadC4
__jpadC4:
    LJAL  putc
    ADDI  r7, r0, 'c'
    LBNE  r0, r0, __jpadC5
__jpadC5:
    LJAL  putc
    ADDI  r7, r0, '1'
    LBNE  r0, r0, __jpadC6
__jpadC6:
    LJAL  putc
    ADDI  r7, r0, '='
    LBNE  r0, r0, __jpadC7
__jpadC7:
    LJAL  putc
    LBU   r7, CNT1
    LBNE  r0, r0, __jpadC8
__jpadC8:
    LJAL  print_hex
    ADDI  r7, r0, ' '
    LBNE  r0, r0, __jpadC9
__jpadC9:
    LJAL  putc
    ADDI  r7, r0, 'c'
    LBNE  r0, r0, __jpadC10
__jpadC10:
    LJAL  putc
    ADDI  r7, r0, '2'
    LBNE  r0, r0, __jpadC11
__jpadC11:
    LJAL  putc
    ADDI  r7, r0, '='
    LBNE  r0, r0, __jpadC12
__jpadC12:
    LJAL  putc
    LBU   r7, CNT2
    LBNE  r0, r0, __jpadC13
__jpadC13:
    LJAL  print_hex
    LJAL  put_crlf
    JALR

cmd_led:                        # 翻转 LED
    LBU   r7, LED_STATE
    XORI  r7, r7, 0x40
    SB    r7, GPIO
    SB    r7, LED_STATE
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
