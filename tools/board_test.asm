# ============================================================
# MCU v1.3 上板程序（MicroPhase Z-7 Lite，PL 引脚）
#   v1.3 变化：ROM 512 字节（PC 9 位）；timer 32 位；ISR 向量重排
#   ISR 向量（irq_controller.v，8 位数组截断后有效值）：
#     GPIO2=0x88  GPIO1=0xA8  TIMER=0xC8  UART=0xE0
#   主程序：0x00-0x87（init+banner+主循环）+ 0x100（send_char 子程序）
#   UART 走 GPIO：pin0=RX(N17)  pin1=TX(P18)  pin6=LED(P15,低电平点亮)  pin7=KEY2(T12,按下低电平)
#   Phase0 配置：pin0=RX / pin1=TX / pin6=OUT / pin7=IRQ（KEY2 低电平触发）
#   Phase1 上电输出 "cpu ready\r\n"（send_char 子程序，RJAL 调用 / JALR 返回）
#   Phase2 KEY2 按下→GPIO2 中断(0x88)→翻转 r2（uart tx 回环开关）
#   Phase3 timer 中断(0xC8)每 1.31ms：r4 递减 LED 计数，~153 tick ≈ 0.2s 亮/灭
#   Phase4 UART 中断(0xE0)：弹 FIFO，XORI 0x20 翻转大小写，r2=1 时回发
# 寄存器：r0=0  r1=发字符  r2=回环开关(1开)  r3=UART ISR 收/回显  r4=LED 计数  r5=GPIO2 ISR 暂存  r7=LED灭常量
# 运行：python tools/asm.py tools/board_test.asm -o <临时.hex>（勿直接覆盖 srcs/ins_rom.hex）
# ============================================================

.equ UART        0x4000
.equ TIMER       0x6000
.equ TIMER_CNT0  0x6000
.equ TIMER_CNT1  0x6001
.equ TIMER_MODE  0x6004
.equ TIMER_ACK   0x6005
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
    SB    r1, TIMER_CNT1      # 0x2C timer cnt_set[1]=0xFF
    SB    r1, TIMER_CNT0      # 0x30 timer cnt_set[0]=0xFF（周期 0x0000FFFF≈65536 拍≈1.31ms@50M）
    ADDI  r1, r0, 1           # 0x34
    SB    r1, TIMER_MODE      # 0x38 irq_mode=1（timer 中断使能）

.org 0x3C
    ADDI  r1, r0, 'c'         # 0x3C banner "cpu ready\r\n"
    RJAL  0x100               # 0x40 send_char('c')
    ADDI  r1, r0, 'p'         # 0x42
    RJAL  0x100               # 0x46
    ADDI  r1, r0, 'u'         # 0x48
    RJAL  0x100               # 0x4C
    ADDI  r1, r0, ' '         # 0x4E
    RJAL  0x100               # 0x52
    ADDI  r1, r0, 'r'         # 0x54
    RJAL  0x100               # 0x58
    ADDI  r1, r0, 'e'         # 0x5A
    RJAL  0x100               # 0x5E
    ADDI  r1, r0, 'a'         # 0x60
    RJAL  0x100               # 0x64
    ADDI  r1, r0, 'd'         # 0x66
    RJAL  0x100               # 0x6A
    ADDI  r1, r0, 'y'         # 0x6C
    RJAL  0x100               # 0x70
    ADDI  r1, r0, '\r'        # 0x72
    RJAL  0x100               # 0x76
    ADDI  r1, r0, '\n'        # 0x78
    RJAL  0x100               # 0x7C

.org 0x7E
    NOP                       # 0x7E 中断授权点
    NOP                       # 0x7F
    LBEQ  r0, r0, 0x7E        # 0x80 回跳 0x7E 等中断（bytmov=(0x84-0x7E)=6）

.org 0x88
    XORI  r2, r2, 1           # 0x88 GPIO2 ISR(KEY2 按下): 翻转回环开关
    ADDI  r5, r0, MODE_IN     # 0x8C → IN 模式
    SB    r5, GPIO_PIN7       # 0x90 pin7=IN（停 IRQ，防电平持续重触发）
    LBU   r5, GPIO            # 0x94 读引脚（IN：bit7=KEY2）
    LBEQ  r5, r0, 0x94        # 0x98 r5==0(仍按住)→回 0x94 轮询等松手（去抖）
    ADDI  r5, r0, MODE_IRQ    # 0x9C → IRQ 模式
    SB    r5, GPIO_PIN7       # 0xA0 pin7=IRQ（恢复；松手高电平不触发）
    IRET                      # 0xA4

.org 0xA8
    IRET                      # 0xA8 GPIO1 ISR 占位（本程序未用，防误触发挂死）

.org 0xC8
    SB    r0, TIMER_ACK       # 0xC8 Timer ISR: ack timer（清 timer_irq）
    RBEQ  r4, r0, 0xD9        # 0xCC r4==0→LED 灭分支（bytmov=0xD9-0xD0=9）
    SUBI  r4, r4, 1           # 0xD0 r4--（LED 计数递减）
    SB    r0, GPIO            # 0xD4 LED 亮（写 bit6=0 → pin6 低）
    IRET                      # 0xD8
    SB    r7, GPIO            # 0xD9 LED 灭（写 bit6=1 → pin6 高）
    IRET                      # 0xDD

.org 0xE0
    LBU   r3, UART            # 0xE0 UART ISR: 弹 FIFO（读同时 rx_read 出队）
    XORI  r3, r3, 0x20        # 0xE4 翻转大小写
    RBEQ  r2, r0, 0xF2        # 0xE8 回环关(r2==0)→跳过回发
    ADDI  r1, r3, 0           # 0xEC r1=收到的字符
    RJAL  0x100               # 0xF0 send_char 回发（bytmov=0x100-0xF2=14）
    IRET                      # 0xF2

.org 0x100
    ADDI  r4, r0, 0x99        # 0x100 send_char: LED 亮 153 tick≈0.2s
    LBNE  r255, r0, 0x104     # 0x104 回跳自身，等 tx busy 归零
    SB    r1, UART            # 0x108 发字符（r1）
    JALR                      # 0x10C 返回
