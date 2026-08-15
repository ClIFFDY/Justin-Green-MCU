# ============================================================
# MCU v1.2 上板程序（MicroPhase Z-7 Lite，PL 引脚）
#   从 ins_rom.hex（21/21 仿真通过）逐条转写，用于验证汇编器
#   UART 走 GPIO：pin0=RX(N17)  pin1=TX(P18)  pin6=LED(P15,低电平点亮)  pin7=KEY2(T12,按下低电平)
#   Phase0 配置：pin0=RX / pin1=TX / pin6=OUT / pin7=IRQ（KEY2 低电平触发）
#   Phase1 上电输出 "cpu ready\r\n"（send_char 子程序，LJAL 调用 / JALR 返回）
#   Phase2 KEY2 按下→GPIO2 中断(0xA0)→翻转 r2（uart tx 回环开关）
#   Phase3 timer 中断(0xD0)每 1.31ms：r4 递减 LED 计数，~153 tick ≈ 0.2s 亮/灭
#   Phase4 UART 中断(0xE8)：弹 FIFO，XORI 0x20 翻转大小写，r2=1 时回发
# 寄存器：r0=0  r1=发字符  r2=回环开关(1开)  r3=UART ISR 收/回显  r4=LED 计数  r5=GPIO2 ISR 暂存  r7=LED灭常量
# 运行：python tools/asm.py tools/board_test.asm -o <临时.hex>（勿直接覆盖 srcs/ins_rom.hex）
# ============================================================

.equ UART        0x4000
.equ TIMER       0x6000
.equ TIMER_CNT_H 0x6001
.equ TIMER_CNT_L 0x6000
.equ TIMER_IRQ   0x6002
.equ TIMER_ACK   0x6003
.equ GPIO        0x8000
.equ GPIO_PIN0   0x8001
.equ GPIO_PIN1   0x8003
.equ GPIO_PIN6   0x800D
.equ GPIO_PIN7   0x800F

# 引脚模式
.equ MODE_OUT 1
.equ MODE_IN  2
.equ MODE_IRQ 3
.equ MODE_TX  5
.equ MODE_RX  6

.org 0x00
    ADDI  r1, r0, MODE_RX     # 0x00 pin0=RX（N17，UART 收）
    SB    r1, GPIO_PIN0       # 0x04
    ADDI  r1, r0, MODE_TX     # 0x08 pin1=TX（P18，UART 发）
    SB    r1, GPIO_PIN1       # 0x0C
    ADDI  r1, r0, MODE_OUT    # 0x10 pin6=OUT（P15，LED，低电平点亮）
    SB    r1, GPIO_PIN6       # 0x14
    ADDI  r1, r0, MODE_IRQ    # 0x18 pin7=IRQ（T12，KEY2，低电平触发）
    SB    r1, GPIO_PIN7       # 0x1C
    ADDI  r2, r0, 1           # 0x20 r2=1：回环开（默认）
    ADDI  r7, r0, 0x40        # 0x24 r7=LED 熄灭常量（写 bit6=1 → pin6 高）
    ADDI  r1, r0, 0xFF        # 0x28
    SB    r1, TIMER_CNT_H     # 0x2C timer cnt_set_h=0xFF
    SB    r1, TIMER_CNT_L     # 0x30 timer cnt_set_l=0xFF（周期 0xFFFF≈65536 拍≈1.31ms@50M）
    ADDI  r1, r0, 1           # 0x34
    SB    r1, TIMER_IRQ       # 0x38 irq_mode=1（timer 中断使能）

.org 0x3C
    RBEQ  r0, r0, 0x4E        # 0x3C 跳过 send_char（bytmov=0x4E-(0x3C+4)=0x0E）

.org 0x40
    ADDI  r4, r0, 0x99        # 0x40 send_char: LED 亮 153 tick≈0.2s
    LBNE  r255, r0, 0x44      # 0x44 回跳自身，等 tx busy 归零
    SB    r1, UART            # 0x48 发字符（r1）
    JALR                      # 0x4C 返回

.org 0x4E
    ADDI  r1, r0, 'c'         # 0x4E
    LJAL  0x40                # 0x52 send_char('c')
    ADDI  r1, r0, 'p'         # 0x54
    LJAL  0x40                # 0x58
    ADDI  r1, r0, 'u'         # 0x5A
    LJAL  0x40                # 0x5E
    ADDI  r1, r0, ' '         # 0x60
    LJAL  0x40                # 0x64
    ADDI  r1, r0, 'r'         # 0x66
    LJAL  0x40                # 0x6A
    ADDI  r1, r0, 'e'         # 0x6C
    LJAL  0x40                # 0x70
    ADDI  r1, r0, 'a'         # 0x72
    LJAL  0x40                # 0x76
    ADDI  r1, r0, 'd'         # 0x78
    LJAL  0x40                # 0x7C
    ADDI  r1, r0, 'y'         # 0x7E
    LJAL  0x40                # 0x82
    ADDI  r1, r0, '\r'        # 0x84
    LJAL  0x40                # 0x88
    ADDI  r1, r0, '\n'        # 0x8A
    LJAL  0x40                # 0x8E

.org 0x90
    NOP                       # 0x90 中断授权点
    NOP                       # 0x91
    LBEQ  r0, r0, 0x90        # 0x92 回跳 0x90 等中断（bytmov=(0x96-0x90)=6）

.org 0xA0
    XORI  r2, r2, 1           # 0xA0 GPIO2 ISR(KEY2 按下): 翻转回环开关
    ADDI  r5, r0, MODE_IN     # 0xA4 → IN 模式
    SB    r5, GPIO_PIN7       # 0xA8 pin7=IN（停 IRQ，防电平持续重触发）
    LBU   r5, GPIO            # 0xAC 读引脚（IN：bit7=KEY2）
    LBEQ  r5, r0, 0xAC        # 0xB0 r5==0(仍按住)→回 0xAC 轮询等松手（去抖）
    ADDI  r5, r0, MODE_IRQ    # 0xB4 → IRQ 模式
    SB    r5, GPIO_PIN7       # 0xB8 pin7=IRQ（恢复；松手高电平不触发）
    IRET                      # 0xBC

.org 0xD0
    SB    r0, TIMER_ACK       # 0xD0 Timer ISR: ack timer（清 timer_irq）
    RBEQ  r4, r0, 0xE1        # 0xD4 r4==0→LED 灭分支（bytmov=0xE1-0xD8=9）
    SUBI  r4, r4, 1           # 0xD8 r4--（LED 计数递减）
    SB    r0, GPIO            # 0xDC LED 亮（写 bit6=0 → pin6 低）
    IRET                      # 0xE0
    SB    r7, GPIO            # 0xE1 LED 灭（写 bit6=1 → pin6 高）
    IRET                      # 0xE5

.org 0xE8
    LBU   r3, UART            # 0xE8 UART ISR: 弹 FIFO（读同时 rx_read 出队）
    XORI  r3, r3, 0x20        # 0xEC 翻转大小写
    RBEQ  r2, r0, 0xFA        # 0xF0 回环关(r2==0)→跳过回发
    ADDI  r1, r3, 0           # 0xF4 r1=收到的字符
    LJAL  0x40                # 0xF8 send_char 回发（bytmov=(0xFA-0x40)=0xBA）
    IRET                      # 0xFA
