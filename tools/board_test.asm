# ============================================================
# MCU 上板程序（词寻址版，配合新架构）
#   ROM 4096 词（PC 12 位词地址），32bit 定长取指，流水线 +1 级
#   ISR 向量（irq_controller.v irq_vex，现为【词地址】）：
#     GPIO2=0x208  GPIO1=0x228  TIMER=0x248  UART=0x260
#   bytmov 16 位【词单位】，基准 W+2（指令在词 W 执行时 pc_addr=W+2）
#   分支寄存器 4 位（r0-r15）；r255 只读 = tx_busy
#   汇编器自动压缩（flag=11 ALU / flag=01 NOP,IRET）+ 自动打包（2 压缩指令/词）
#   UART 走 GPIO：pin0=RX(N17)  pin1=TX(P18)  pin6=LED(P15,低电平点亮)  pin7=V13(IRQ_IN 跳线,低电平触发)
#   Phase0 配置：pin0=RX / pin1=TX / pin6=OUT / pin7=IRQ（V13 跳线短接地触发）
#   Phase1 上电输出 "cpu ready\r\n"（send_char 子程序，RJAL 调用 / JALR 返回）
#   Phase2 V13 短接地→GPIO2 中断(0x208)→翻转 r2（uart tx 回环开关）
#   Phase3 timer 中断(0x248)：r4 递减 LED 计数（UART 收到数据置 r4=0x99≈153 tick≈0.2s 亮）
#   Phase4 UART 中断(0x260)：弹 FIFO，XORI 0x20 翻转大小写，r2=1 时回发
# 寄存器：r0=0  r1=发字符  r2=回环开关(1开)  r3=UART ISR 收/回显
#         r4=LED 计数  r5=GPIO2 ISR 暂存  r6=send_char busy 暂存  r7=LED灭常量
#         r255=tx_busy(只读)
# 运行：python tools/asm.py tools/board_test.asm -o <临时.hex>（勿直接覆盖 srcs/ins_rom.hex）
# ============================================================

.equ UART        0x2000
.equ TIMER       0x3000
.equ TIMER_CNT0  0x3000
.equ TIMER_CNT1  0x3001
.equ TIMER_MODE  0x3004
.equ TIMER_ACK   0x3005
.equ GPIO        0x4000
.equ GPIO_PIN0   0x4001
.equ GPIO_PIN1   0x4003
.equ GPIO_PIN6   0x400D
.equ GPIO_PIN7   0x400F

# 引脚模式
.equ MODE_OUT 1
.equ MODE_IN  2
.equ MODE_IRQ 3
.equ MODE_TX  5
.equ MODE_RX  6

.org 0x00
    # ---- 压缩打包自检：词 0 打包 [ADDI r2,r0,1 | ADDI r3,r0,2]（flag=11）----
    ADDI  r2, r0, 1            # 词 0 上：r2=1 回环开（默认）
    ADDI  r3, r0, 2            # 词 0 下：r3=2（仅作压缩测试，随后会被 UART ISR 覆盖）
    # ---- 引脚配置 ----
    ADDI  r7, r0, 0x40         # r7=LED 熄灭常量（写 bit6=1 → pin6 高）
    ADDI  r1, r0, MODE_RX      # pin0=RX（N17，UART 收）
    SB    r1, GPIO_PIN0
    ADDI  r1, r0, MODE_TX      # pin1=TX（P18，UART 发）
    SB    r1, GPIO_PIN1
    ADDI  r1, r0, MODE_OUT     # pin6=OUT（P15，LED，低电平点亮）
    SB    r1, GPIO_PIN6
    SB    r7, GPIO             # 初始 LED 灭
    ADDI  r1, r0, MODE_IRQ     # pin7=IRQ（V13，低电平触发）
    SB    r1, GPIO_PIN7
    ADDI  r1, r0, 0xFF         # timer cnt_set[1]=0xFF
    SB    r1, TIMER_CNT1
    SB    r1, TIMER_CNT0       # timer cnt_set[0]=0xFF（周期≈65536 拍≈1.31ms@50M）
    ADDI  r1, r0, 1
    SB    r1, TIMER_MODE       # irq_mode=1（timer 中断使能）

    # ---- banner "cpu ready\r\n"（RJAL send_char，向前调用）----
    ADDI  r1, r0, 'c'
    RJAL  send_char
    ADDI  r1, r0, 'p'
    RJAL  send_char
    ADDI  r1, r0, 'u'
    RJAL  send_char
    ADDI  r1, r0, ' '
    RJAL  send_char
    ADDI  r1, r0, 'r'
    RJAL  send_char
    ADDI  r1, r0, 'e'
    RJAL  send_char
    ADDI  r1, r0, 'a'
    RJAL  send_char
    ADDI  r1, r0, 'd'
    RJAL  send_char
    ADDI  r1, r0, 'y'
    RJAL  send_char
    ADDI  r1, r0, '\r'
    RJAL  send_char
    ADDI  r1, r0, '\n'
    RJAL  send_char

    # ---- 主循环 / 中断授权点 ----
    # 词 N = [NOP | NOP]（打包，flag=01 自检）。授权时 pc_addr=N+2，
    # IRET 返回 N+2 → 第二个 LBEQ 回跳，循环不断。
main_loop:
    NOP                        # 词 N：授权点（bytmov=0，两拍）
    NOP
    LBEQ  r0, r0, main_loop    # 词 N+1：回跳（bytmov≠0，不授权）
    LBEQ  r0, r0, main_loop    # 词 N+2：IRET 落点，回跳

    # ---- send_char 子程序：r1 → UART，等 tx_busy 归零 ----
send_char:
    ADDI  r6, r255, 0          # 复制 tx_busy 到低寄存器（分支寄存器限 4 位）
    LBNE  r6, r0, send_char    # busy 则回跳自身（向后 3 词）
    SB    r1, UART             # 发字符
    JALR                       # 返回

.org 0x208
    # ---- GPIO2 ISR（V13 短接地触发）：翻转回环开关 ----
    XORI  r2, r2, 1            # 翻转 r2
    ADDI  r5, r0, MODE_IN      # → IN 模式
    SB    r5, GPIO_PIN7        # pin7=IN（停 IRQ，防电平持续重触发）
gpio2_poll:
    LBU   r5, GPIO             # 读引脚（IN：bit7=V13）
    LBEQ  r5, r0, gpio2_poll   # r5==0(仍按住)→回读轮询等松手（去抖）
    ADDI  r5, r0, MODE_IRQ     # → IRQ 模式
    SB    r5, GPIO_PIN7        # pin7=IRQ（恢复；松手高电平不触发）
    IRET

.org 0x228
    # ---- GPIO1 ISR 占位（本程序未用，防误触发挂死）----
    IRET

.org 0x248
    # ---- Timer ISR：r4 递减 LED 计数，r4==0 则 LED 灭 ----
timer_isr:
    SB    r0, TIMER_ACK        # ack timer（清 timer_irq）
    RBEQ  r4, r0, led_off      # r4==0 → LED 灭分支（向前）
    SUBI  r4, r4, 1            # r4--（LED 计数递减）
    SB    r0, GPIO             # LED 亮（写 bit6=0 → pin6 低）
    IRET
led_off:
    SB    r7, GPIO             # LED 灭（写 bit6=1 → pin6 高）
    IRET

.org 0x260
    # ---- UART ISR：弹 FIFO，翻转大小写，r2=1 时回发 ----
uart_isr:
    LBU   r3, UART             # 弹 FIFO（读同时 rx_read 出队）
    ADDI  r4, r0, 0x99         # 收到数据→LED 亮 153 tick≈0.2s
    XORI  r3, r3, 0x20         # 翻转大小写
    RBEQ  r2, r0, uart_done    # 回环关(r2==0)→跳过回发（向前）
    ADDI  r1, r3, 0            # r1=收到的字符
    LJAL  send_char            # send_char 回发（向后调用）
uart_done:
    IRET
