# ============================================================
# MCU RTOS v1.0 —— 协作式微内核 + CLI shell（MCU v2.1）
#
# 结构：
#   kernel : SysTick（timer ISR @0x248，1ms 滴答，16 位 k_tick）
#            k_delay（16 位延时）+ UART 控制台（putc/getc/flush）
#   shell  : 打印程序目录 → 单字符命令 → 协作式派发任务
#   apps   : hello（打印 + 显示当前 tick）/ led（任意键翻转 LED，b=闪烁，0=退出）
#
# 硬件前提（v2.1）：
#   ISR 向量（词地址）：GPIO2=0x208 GPIO1=0x228 TIMER=0x248 UART=0x260
#   中断栈 8 深可嵌套；授权门控 bytmov==0（顺序指令即授权点）
#   UART RX 由硬件 FIFO(64) 缓冲，FIFO 非空产生电平型 RX 中断（空则无）
#   0x260 uart_isr：锁存语义——RX_BUF 空才存入（保持首字节），多余弹入丢弃；getc 只轮询 RX_BUF，ISR 外绝不直读 FIFO
#   2026-08-18 硬件更新：irq_flush 只冲刷取指级（ins_rom/if_reg），被中断指令正常完成、写不丢；
#   IRET 回 W+2（派发沿保存 pc=W+2；W+1 在派发沿提前执行一次且控制被屏蔽）
#   → 派发点(W)后紧跟的控制转移(W+1)会被跳过 → 程序统一用跳转类 NOP（LBNE r0,r0）垫在
#     每条控制转移之前（__jpadN），保证控制转移永不出现在派发点后的 W+1
#   字符串打印：无寄存器间址、ROM 数据不可读 → 逐字符 ADDI r1,'c'+调用（board_test 套路）
#
# 寄存器约定：
#   r0=0（恒零）  r255=tx_busy（只读）
#   r1=参数/返回值（跨调用可破坏）  r2-r254=临时（跨调用可破坏）
#   跨调用长活状态一律放 RAM 单元；timer ISR 保存 r1,r2（ISR_S1/S2），uart ISR 保存 r1,r2（UART_S1/S2）
#
# 引脚：pin0=RX(N17) pin1=TX(P18) pin6=LED(P15,低电平点亮)
# 汇编：python tools/asm.py tools/rtos.asm -o <临时.hex>
# ============================================================

.equ UART        0x2000
.equ TIMER       0x3000
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

.equ MODE_OUT 1
.equ MODE_RX  6
.equ MODE_TX  5

# RAM 单元（seg1 0x9000 区）
.equ TICK_LO    0x9000
.equ TICK_HI    0x9001
.equ ISR_S1     0x9002
.equ ISR_S2     0x9003
.equ LED_STATE  0x9004
.equ CMD        0x9005
.equ RX_BUF     0x9006
.equ UART_S1    0x9007
.equ UART_S2    0x9008

# ============================================================
# 启动：配置外设 → 逐外设打印 init → 进入 shell
# ============================================================
.org 0x00
reset:
    # ---- GPIO：UART 引脚（打印前必须配好 TX）----
    ADDI  r1, r0, MODE_RX      # pin0=RX（UART 收）
    SB    r1, GPIO_PIN0
    ADDI  r1, r0, MODE_TX      # pin1=TX（UART 发）
    SB    r1, GPIO_PIN1
    # ---- CPU / UART 就绪 ----
    LBNE  r0, r0, __jpad0
__jpad0:
    RJAL  print_cpu_init       # "cpu init"
    RJAL  print_uart_init      # "uart init"
    # ---- timer：1ms 滴答（重装值 49999 = 0x0000C34F，周期 50000 拍 @50M）----
    ADDI  r1, r0, 0x4F
    SB    r1, TIMER_CNT0
    ADDI  r1, r0, 0xC3
    SB    r1, TIMER_CNT1
    SB    r0, TIMER_CNT2
    SB    r0, TIMER_CNT3
    ADDI  r1, r0, 1
    SB    r1, TIMER_MODE       # irq_mode=1（电平锁存，SysTick 使能）
    LBNE  r0, r0, __jpad1
__jpad1:
    RJAL  print_timer_init     # "timer init"
    # ---- GPIO：LED ----
    ADDI  r1, r0, MODE_OUT     # pin6=OUT（P15，低电平点亮）
    SB    r1, GPIO_PIN6
    ADDI  r1, r0, 0x40         # 写 bit6=1 → pin6 高 → LED 灭
    SB    r1, GPIO
    SB    r1, LED_STATE        # 记录初始状态
    LBNE  r0, r0, __jpad2
__jpad2:
    RJAL  print_gpio_init      # "gpio init"
    RJAL  print_sys_init       # "system init"
    RJAL  flush                # 进 shell 前清空 RX_BUF（丢弃复位残留字节）
    # ---- 进入 shell（不返回）----
    RJAL  shell
    HALT                       # 安全兜底

# ============================================================
# kernel：UART 控制台 + 延时
# ============================================================
putc:                          # 入参 r1=字符；轮询 tx_busy 后发送（破坏 r1,r6）
putc_wait:
    ADDI  r6, r255, 0          # r6 = tx_busy（复制到低寄存器供分支用）
    LBNE  r0, r0, __jpad3
__jpad3:
    LBNE  r6, r0, putc_wait    # busy 则回跳重新读（bytmov≠0，非授权点，安全）
    SB    r1, UART
    LBNE  r0, r0, __jpad4
__jpad4:
    JALR

getc:                          # 返回 r1=第一个命令字节；轮询等 ISR 锁存 + 弹空 FIFO（破坏 r1）
    # 锁存语义配合：ISR 只在 RX_BUF 空时存入（首字节），多余弹入丢弃。
    # getc 的每个普通词在 FIFO 非空时都是派发点（弹 1 字节被锁存丢弃），
    # FIFO 弹空后此处 LBU r1 读到锁存的首字节。
    ADDI  r1, r0, 0            # 预置 0 保险
    LBNE  r0, r0, __jpad4b     # 屏蔽（ADDI+LBNE）
__jpad4b:
getc_wait:
    NOP                        # W：FIFO 非空 → 派发弹 1 字节（ISR 锁存/丢弃）
    LBU   r1, RX_BUF           # 读锁存（FIFO 非空时此 LBU 作 W+1 被派发吞掉无害）
    LBNE  r0, r0, __jpad5b     # 屏蔽（LBU r1 右侧）
__jpad5b:
    LBEQ  r1, r0, getc_wait    # 空 → 回跳等待（getc_wait 在上方，后向 L）
    SB    r0, RX_BUF           # 取走并清锁存，防下条命令残留
    LBNE  r0, r0, __jpad6b     # 屏蔽
__jpad6b:
    JALR

flush:                         # 丢弃 FIFO 残留字节（破坏 r1）
    NOP                        # W：弹 1 字节
    LBU   r0, RX_BUF           # W+1 被吞无害 → IRET 回下一条
    LBU   r1, RX_BUF           # IRET 回这里读弹入字节（紧邻 LBU r0，无 pad 阻隔）
    LBNE  r0, r0, __jpad7      # 屏蔽
__jpad7:
    RBEQ  r1, r0, flush_done   # 空（FIFO 弹空）→ 完（前向 R）
    SB    r0, RX_BUF           # 清该字节（FIFO 非空时被吞无害）
    LBNE  r0, r0, __jpad8      # 屏蔽
__jpad8:
    LBEQ  r0, r0, flush        # 再弹下一字节（后向 L）
flush_done:
    JALR

delay:                         # 入参 r1=滴答数(0-255)；16 位精确等待（破坏 r1,r2,r3,r5,r6）
    LBU   r5, TICK_LO
    LBNE  r0, r0, __jpad9      # 拆双授权：LBU+ADD 相邻会被主派发吞 ADD → 目标错
__jpad9:
    ADD   r5, r5, r1           # 目标低字节 = now_lo + ticks
    LBNE  r0, r0, __jpad9b
__jpad9b:
    RBLTU r5, r1, delay_c1     # 溢出进位？
    LBU   r6, TICK_HI          # 无进位：目标高字节 = now_hi
    LBNE  r0, r0, __jpad10
__jpad10:
    RBEQ  r0, r0, delay_c2
delay_c1:
    LBU   r6, TICK_HI
    LBNE  r0, r0, __jpad10b    # 拆双授权：LBU+ADDI 相邻吞 ADDI → 目标高字节错
__jpad10b:
    ADDI  r6, r6, 1            # 有进位：now_hi + 1
delay_c2:
    NOP                        # tick 前进靠下方 LBNE 分支空档派发（timer ISR）
    LBNE  r0, r0, __jpad11     # 拆双授权：NOP+LBU 相邻吞 LBU → r2 不更新 → 死循环
__jpad11:
    LBU   r2, TICK_LO
    LBNE  r0, r0, __jpad11b
__jpad11b:
    LBNE  r2, r5, delay_c2     # 低字节未到目标 → 继续（分支空档派发 tick 前进）
    LBU   r3, TICK_HI
    LBNE  r0, r0, __jpad12
__jpad12:
    LBNE  r3, r6, delay_c2     # 高字节未到目标 → 继续
    JALR

put_crlf:                      # 打印 "\r\n"（破坏 r1）
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad13
__jpad13:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad14
__jpad14:
    LJAL  putc
    JALR

print_hexdigit:                # 入参 r1=0-15 → 输出 1 个十六进制字符（破坏 r1,r2）
    ADDI  r2, r0, 9
    LBNE  r0, r0, __jpad15
__jpad15:
    RBLTU r2, r1, hex_af       # 9 < 值 → 'A'-'F'
    ADDI  r1, r1, '0'
    LBNE  r0, r0, __jpad16
__jpad16:
    LJAL  putc
    JALR
hex_af:
    ADDI  r1, r1, 55           # 'A'-10 = 55
    LBNE  r0, r0, __jpad17
__jpad17:
    LJAL  putc
    JALR

print_hex:                     # 入参 r1=字节 → 输出 2 位十六进制（破坏 r1,r2,r4）
    ADDI  r4, r1, 0            # 保存字节（r4 不被 putc/hexdigit 破坏）
    LBNE  r0, r0, __jpad17b    # 拆双授权：ADDI+SRLI 相邻吞 SRLI → 高半字节错
__jpad17b:
    SRLI  r1, r4, 4            # 高半字节
    LBNE  r0, r0, __jpad18
__jpad18:
    LJAL  print_hexdigit
    ANDI  r1, r4, 0x0F         # 低半字节
    LBNE  r0, r0, __jpad19
__jpad19:
    LJAL  print_hexdigit
    JALR

# ============================================================
# shell：菜单 + 命令派发（协作式）
# ============================================================
shell:
    RJAL  print_menu           # 程序目录
shell_loop:
    RJAL  print_prompt         # "cmd> "
    LJAL  getc                 # r1 = 命令字符
    SB    r1, CMD              # 存命令（新 flush：被中断指令正常完成，写必落）
    LBNE  r0, r0, __jpad20
__jpad20:
    LJAL  putc                 # 回显
    LJAL  flush                # 丢弃行内剩余字节（如 \r）
    LJAL  put_crlf
    LBU   r2, CMD              # r2 = 命令
    LBNE  r0, r0, __jpad20b    # 拆双授权：LBU+ADDI 相邻吞 ADDI → 命令比较错
__jpad20b:
    ADDI  r3, r0, '1'
    LBNE  r0, r0, __jpad21
__jpad21:
    RBEQ  r2, r3, do_hello     # 1 → hello world
    ADDI  r3, r0, '2'
    LBNE  r0, r0, __jpad22
__jpad22:
    RBEQ  r2, r3, do_led       # 2 → toggle led
    ADDI  r3, r0, '0'
    LBNE  r0, r0, __jpad23
__jpad23:
    RBEQ  r2, r3, do_menu      # 0 → 重打目录
    ADDI  r3, r0, '\r'
    LBNE  r0, r0, __jpad24
__jpad24:
    LBEQ  r2, r3, shell_loop   # 空输入（回车）→ 重新提示
    RJAL  print_invalid        # 未知命令
    LBEQ  r0, r0, shell_loop
do_hello:
    RJAL  app_hello
    LBEQ  r0, r0, shell_loop
do_led:
    RJAL  app_led
    LBEQ  r0, r0, shell_loop
do_menu:
    RJAL  print_menu
    LBEQ  r0, r0, shell_loop

# ============================================================
# 用户程序（任务）
# ============================================================
app_hello:                     # 打印 "Hello World!" + 当前 tick
    RJAL  print_hello
    RJAL  print_t_label        # "t="
    LBU   r1, TICK_HI
    LBNE  r0, r0, __jpad25
__jpad25:
    LJAL  print_hex
    LBU   r1, TICK_LO
    LBNE  r0, r0, __jpad26
__jpad26:
    LJAL  print_hex
    LJAL  put_crlf
    JALR

app_led:                       # 任意键翻转 LED；b=闪烁 5 次；0/q=返回菜单
    RJAL  print_led_prompt
led_loop:
    LJAL  getc                 # r1 = 键
    SB    r1, CMD              # 存命令（新 flush：写必落）
    LBNE  r0, r0, __jpad27
__jpad27:
    LJAL  putc                 # 回显
    LJAL  flush
    LBU   r2, CMD
    LBNE  r0, r0, __jpad27b    # 拆双授权：LBU+ADDI 相邻吞 ADDI → 命令比较错
__jpad27b:
    ADDI  r3, r0, '0'
    LBNE  r0, r0, __jpad28
__jpad28:
    RBEQ  r2, r3, led_done     # 0 → 退出
    ADDI  r3, r0, 'q'
    LBNE  r0, r0, __jpad29
__jpad29:
    RBEQ  r2, r3, led_done     # q → 退出
    ADDI  r3, r0, 'b'
    LBNE  r0, r0, __jpad30
__jpad30:
    RBEQ  r2, r3, led_blink    # b → 闪烁
    # 任意键：翻转 LED
    LBU   r2, LED_STATE
    LBNE  r0, r0, __jpad30b    # 拆双授权：LBU+XORI 相邻吞 XORI → LED 不翻转
__jpad30b:
    XORI  r2, r2, 0x40         # 翻转 bit6
    LBNE  r0, r0, __jpad30c    # 拆双授权：XORI+SB 相邻吞 SB GPIO → 写丢
__jpad30c:
    SB    r2, GPIO
    LBNE  r0, r0, __jpad30d    # 拆双授权：SB+SB 相邻吞 SB LED_STATE → 记录丢
__jpad30d:
    SB    r2, LED_STATE
    LBNE  r0, r0, __jpad31
__jpad31:
    RBEQ  r2, r0, led_on_msg   # 新状态==0 → 亮
    RJAL  print_led_off        # 否则灭
    LBEQ  r0, r0, led_loop
led_on_msg:
    RJAL  print_led_on
    LBEQ  r0, r0, led_loop
led_blink:                     # 闪烁 5 次，间隔 100ms
    ADDI  r4, r0, 5
    LBNE  r0, r0, __jpad31a    # 拆双授权：ADDI+LBU 相邻吞 LBU → LED_STATE 旧值
__jpad31a:
led_blink_loop:
    LBU   r2, LED_STATE
    LBNE  r0, r0, __jpad31b    # 拆双授权：LBU+XORI 相邻吞 XORI → 不翻转
__jpad31b:
    XORI  r2, r2, 0x40
    LBNE  r0, r0, __jpad31c    # 拆双授权：XORI+SB 相邻吞 SB GPIO → 写丢
__jpad31c:
    SB    r2, GPIO
    LBNE  r0, r0, __jpad31d    # 拆双授权：SB+SB 相邻吞 SB LED_STATE → 记录丢
__jpad31d:
    SB    r2, LED_STATE
    LBNE  r0, r0, __jpad31e    # 拆双授权：SB+ADDI 相邻吞 ADDI r1 → delay 参数错
__jpad31e:
    ADDI  r1, r0, 100
    LBNE  r0, r0, __jpad32
__jpad32:
    LJAL  delay
    SUBI  r4, r4, 1
    LBNE  r0, r0, __jpad33
__jpad33:
    LBNE  r4, r0, led_blink_loop
    LBEQ  r0, r0, led_loop
led_done:
    LJAL  put_crlf
    JALR

# ============================================================
# ISR 向量（v2.1：GPIO2=0x208 GPIO1=0x228 TIMER=0x248 UART=0x260）
# ============================================================
.org 0x208
    IRET                       # GPIO2 ISR（本系统未用，防御）

.org 0x228
    IRET                       # GPIO1 ISR（本系统未用，防御）

.org 0x248
timer_isr:                     # SysTick：1ms 滴答，16 位 k_tick
    SB    r0, TIMER_ACK        # ack timer
    SB    r1, ISR_S1           # 保存现场（ISR 与任务共享寄存器）
    SB    r2, ISR_S2
    LBU   r1, TICK_LO
    ADDI  r1, r1, 1
    SB    r1, TICK_LO
    LBNE  r0, r0, __jpad34
__jpad34:
    RBNE  r1, r0, tick_done    # 低字节非 0 → 无进位
    LBU   r1, TICK_HI
    ADDI  r1, r1, 1
    SB    r1, TICK_HI
tick_done:
    LBU   r1, ISR_S1           # 恢复现场
    LBU   r2, ISR_S2
    LBNE  r0, r0, __jpad35
__jpad35:
    IRET

.org 0x260
uart_isr:                      # UART RX：FIFO 非空派发 → 弹 1 字节；RX_BUF 空则锁存首字节、否则丢弃
    # 2026-08-18 锁存语义：RX_BUF 保持"第一个"收到的字节；FIFO 多字节时后续弹入一律丢弃，
    # 否则 getc 只能读到最后弹入的字节（命令首字符丢失）。
    # ISR 内无派发：嵌套需新 prio > 当前 prio（RX=2/Timer=1 均不满足，GPIO 未用）→ 直写安全。
    SB    r1, UART_S1          # 保存 r1（UART prio2 可嵌 timer prio1，须独立槽）
    SB    r2, UART_S2          # 保存 r2
    LBU   r1, UART             # 弹 FIFO 队首（派发即 FIFO 非空，此读必得有效字节）
    LBU   r2, RX_BUF           # 读当前锁存
    RBNE  r2, r0, __udone      # 锁存非空 → 丢弃该字节（前向，跳距=1 可编码）
    NOP                        # pad：让 __udone 距 RBNE 为 W+3（bytmov=1）
    SB    r1, RX_BUF           # 锁存空 → 存第一个字节
__udone:
    LBU   r1, UART_S1          # 恢复 r1
    LBU   r2, UART_S2          # 恢复 r2
    IRET

# ============================================================
# 打印子程序（逐字符，board_test 套路；调用 putc 均向后 LJAL）
# ============================================================
.org 0x280
print_cpu_init:                # "cpu init\r\n"
    ADDI  r1, r0, 'c'
    LBNE  r0, r0, __jpad37
__jpad37:
    LJAL  putc
    ADDI  r1, r0, 'p'
    LBNE  r0, r0, __jpad38
__jpad38:
    LJAL  putc
    ADDI  r1, r0, 'u'
    LBNE  r0, r0, __jpad39
__jpad39:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad40
__jpad40:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad41
__jpad41:
    LJAL  putc
    ADDI  r1, r0, 'n'
    LBNE  r0, r0, __jpad42
__jpad42:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad43
__jpad43:
    LJAL  putc
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad44
__jpad44:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad45
__jpad45:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad46
__jpad46:
    LJAL  putc
    JALR

print_uart_init:               # "uart init\r\n"
    ADDI  r1, r0, 'u'
    LBNE  r0, r0, __jpad47
__jpad47:
    LJAL  putc
    ADDI  r1, r0, 'a'
    LBNE  r0, r0, __jpad48
__jpad48:
    LJAL  putc
    ADDI  r1, r0, 'r'
    LBNE  r0, r0, __jpad49
__jpad49:
    LJAL  putc
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad50
__jpad50:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad51
__jpad51:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad52
__jpad52:
    LJAL  putc
    ADDI  r1, r0, 'n'
    LBNE  r0, r0, __jpad53
__jpad53:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad54
__jpad54:
    LJAL  putc
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad55
__jpad55:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad56
__jpad56:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad57
__jpad57:
    LJAL  putc
    JALR

print_timer_init:              # "timer init\r\n"
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad58
__jpad58:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad59
__jpad59:
    LJAL  putc
    ADDI  r1, r0, 'm'
    LBNE  r0, r0, __jpad60
__jpad60:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad61
__jpad61:
    LJAL  putc
    ADDI  r1, r0, 'r'
    LBNE  r0, r0, __jpad62
__jpad62:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad63
__jpad63:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad64
__jpad64:
    LJAL  putc
    ADDI  r1, r0, 'n'
    LBNE  r0, r0, __jpad65
__jpad65:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad66
__jpad66:
    LJAL  putc
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad67
__jpad67:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad68
__jpad68:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad69
__jpad69:
    LJAL  putc
    JALR

print_gpio_init:               # "gpio init\r\n"
    ADDI  r1, r0, 'g'
    LBNE  r0, r0, __jpad70
__jpad70:
    LJAL  putc
    ADDI  r1, r0, 'p'
    LBNE  r0, r0, __jpad71
__jpad71:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad72
__jpad72:
    LJAL  putc
    ADDI  r1, r0, 'o'
    LBNE  r0, r0, __jpad73
__jpad73:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad74
__jpad74:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad75
__jpad75:
    LJAL  putc
    ADDI  r1, r0, 'n'
    LBNE  r0, r0, __jpad76
__jpad76:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad77
__jpad77:
    LJAL  putc
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad78
__jpad78:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad79
__jpad79:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad80
__jpad80:
    LJAL  putc
    JALR

print_sys_init:                # "system init\r\n"
    ADDI  r1, r0, 's'
    LBNE  r0, r0, __jpad81
__jpad81:
    LJAL  putc
    ADDI  r1, r0, 'y'
    LBNE  r0, r0, __jpad82
__jpad82:
    LJAL  putc
    ADDI  r1, r0, 's'
    LBNE  r0, r0, __jpad83
__jpad83:
    LJAL  putc
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad84
__jpad84:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad85
__jpad85:
    LJAL  putc
    ADDI  r1, r0, 'm'
    LBNE  r0, r0, __jpad86
__jpad86:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad87
__jpad87:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad88
__jpad88:
    LJAL  putc
    ADDI  r1, r0, 'n'
    LBNE  r0, r0, __jpad89
__jpad89:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad90
__jpad90:
    LJAL  putc
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad91
__jpad91:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad92
__jpad92:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad93
__jpad93:
    LJAL  putc
    JALR

print_menu:                    # "\r\n== MCU RTOS v1.0 ==\r\n  1 hello world\r\n  2 toggle led\r\n  0 refresh\r\n"
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad94
__jpad94:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad95
__jpad95:
    LJAL  putc
    ADDI  r1, r0, '='
    LBNE  r0, r0, __jpad96
__jpad96:
    LJAL  putc
    ADDI  r1, r0, '='
    LBNE  r0, r0, __jpad97
__jpad97:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad98
__jpad98:
    LJAL  putc
    ADDI  r1, r0, 'M'
    LBNE  r0, r0, __jpad99
__jpad99:
    LJAL  putc
    ADDI  r1, r0, 'C'
    LBNE  r0, r0, __jpad100
__jpad100:
    LJAL  putc
    ADDI  r1, r0, 'U'
    LBNE  r0, r0, __jpad101
__jpad101:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad102
__jpad102:
    LJAL  putc
    ADDI  r1, r0, 'R'
    LBNE  r0, r0, __jpad103
__jpad103:
    LJAL  putc
    ADDI  r1, r0, 'T'
    LBNE  r0, r0, __jpad104
__jpad104:
    LJAL  putc
    ADDI  r1, r0, 'O'
    LBNE  r0, r0, __jpad105
__jpad105:
    LJAL  putc
    ADDI  r1, r0, 'S'
    LBNE  r0, r0, __jpad106
__jpad106:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad107
__jpad107:
    LJAL  putc
    ADDI  r1, r0, 'v'
    LBNE  r0, r0, __jpad108
__jpad108:
    LJAL  putc
    ADDI  r1, r0, '1'
    LBNE  r0, r0, __jpad109
__jpad109:
    LJAL  putc
    ADDI  r1, r0, '.'
    LBNE  r0, r0, __jpad110
__jpad110:
    LJAL  putc
    ADDI  r1, r0, '0'
    LBNE  r0, r0, __jpad111
__jpad111:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad112
__jpad112:
    LJAL  putc
    ADDI  r1, r0, '='
    LBNE  r0, r0, __jpad113
__jpad113:
    LJAL  putc
    ADDI  r1, r0, '='
    LBNE  r0, r0, __jpad114
__jpad114:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad115
__jpad115:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad116
__jpad116:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad117
__jpad117:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad118
__jpad118:
    LJAL  putc
    ADDI  r1, r0, '1'
    LBNE  r0, r0, __jpad119
__jpad119:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad120
__jpad120:
    LJAL  putc
    ADDI  r1, r0, 'h'
    LBNE  r0, r0, __jpad121
__jpad121:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad122
__jpad122:
    LJAL  putc
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad123
__jpad123:
    LJAL  putc
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad124
__jpad124:
    LJAL  putc
    ADDI  r1, r0, 'o'
    LBNE  r0, r0, __jpad125
__jpad125:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad126
__jpad126:
    LJAL  putc
    ADDI  r1, r0, 'w'
    LBNE  r0, r0, __jpad127
__jpad127:
    LJAL  putc
    ADDI  r1, r0, 'o'
    LBNE  r0, r0, __jpad128
__jpad128:
    LJAL  putc
    ADDI  r1, r0, 'r'
    LBNE  r0, r0, __jpad129
__jpad129:
    LJAL  putc
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad130
__jpad130:
    LJAL  putc
    ADDI  r1, r0, 'd'
    LBNE  r0, r0, __jpad131
__jpad131:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad132
__jpad132:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad133
__jpad133:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad134
__jpad134:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad135
__jpad135:
    LJAL  putc
    ADDI  r1, r0, '2'
    LBNE  r0, r0, __jpad136
__jpad136:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad137
__jpad137:
    LJAL  putc
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad138
__jpad138:
    LJAL  putc
    ADDI  r1, r0, 'o'
    LBNE  r0, r0, __jpad139
__jpad139:
    LJAL  putc
    ADDI  r1, r0, 'g'
    LBNE  r0, r0, __jpad140
__jpad140:
    LJAL  putc
    ADDI  r1, r0, 'g'
    LBNE  r0, r0, __jpad141
__jpad141:
    LJAL  putc
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad142
__jpad142:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad143
__jpad143:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad144
__jpad144:
    LJAL  putc
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad145
__jpad145:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad146
__jpad146:
    LJAL  putc
    ADDI  r1, r0, 'd'
    LBNE  r0, r0, __jpad147
__jpad147:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad148
__jpad148:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad149
__jpad149:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad150
__jpad150:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad151
__jpad151:
    LJAL  putc
    ADDI  r1, r0, '0'
    LBNE  r0, r0, __jpad152
__jpad152:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad153
__jpad153:
    LJAL  putc
    ADDI  r1, r0, 'r'
    LBNE  r0, r0, __jpad154
__jpad154:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad155
__jpad155:
    LJAL  putc
    ADDI  r1, r0, 'f'
    LBNE  r0, r0, __jpad156
__jpad156:
    LJAL  putc
    ADDI  r1, r0, 'r'
    LBNE  r0, r0, __jpad157
__jpad157:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad158
__jpad158:
    LJAL  putc
    ADDI  r1, r0, 's'
    LBNE  r0, r0, __jpad159
__jpad159:
    LJAL  putc
    ADDI  r1, r0, 'h'
    LBNE  r0, r0, __jpad160
__jpad160:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad161
__jpad161:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad162
__jpad162:
    LJAL  putc
    JALR

print_prompt:                  # "cmd> "
    ADDI  r1, r0, 'c'
    LBNE  r0, r0, __jpad163
__jpad163:
    LJAL  putc
    ADDI  r1, r0, 'm'
    LBNE  r0, r0, __jpad164
__jpad164:
    LJAL  putc
    ADDI  r1, r0, 'd'
    LBNE  r0, r0, __jpad165
__jpad165:
    LJAL  putc
    ADDI  r1, r0, '>'
    LBNE  r0, r0, __jpad166
__jpad166:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad167
__jpad167:
    LJAL  putc
    JALR

print_invalid:                 # 调试："inv=" + hex(CMD) + "\r\n"
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad168
__jpad168:
    LJAL  putc
    ADDI  r1, r0, 'n'
    LBNE  r0, r0, __jpad169
__jpad169:
    LJAL  putc
    ADDI  r1, r0, 'v'
    LBNE  r0, r0, __jpad170
__jpad170:
    LJAL  putc
    ADDI  r1, r0, '='
    LBNE  r0, r0, __jpad171
__jpad171:
    LJAL  putc
    LBU   r1, CMD
    LBNE  r0, r0, __jpad172
__jpad172:
    LJAL  print_hex
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad173
__jpad173:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad174
__jpad174:
    LJAL  putc
    JALR

print_hello:                   # "\r\nHello World!\r\n"
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad175
__jpad175:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad176
__jpad176:
    LJAL  putc
    ADDI  r1, r0, 'H'
    LBNE  r0, r0, __jpad177
__jpad177:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad178
__jpad178:
    LJAL  putc
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad179
__jpad179:
    LJAL  putc
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad180
__jpad180:
    LJAL  putc
    ADDI  r1, r0, 'o'
    LBNE  r0, r0, __jpad181
__jpad181:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad182
__jpad182:
    LJAL  putc
    ADDI  r1, r0, 'W'
    LBNE  r0, r0, __jpad183
__jpad183:
    LJAL  putc
    ADDI  r1, r0, 'o'
    LBNE  r0, r0, __jpad184
__jpad184:
    LJAL  putc
    ADDI  r1, r0, 'r'
    LBNE  r0, r0, __jpad185
__jpad185:
    LJAL  putc
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad186
__jpad186:
    LJAL  putc
    ADDI  r1, r0, 'd'
    LBNE  r0, r0, __jpad187
__jpad187:
    LJAL  putc
    ADDI  r1, r0, '!'
    LBNE  r0, r0, __jpad188
__jpad188:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad189
__jpad189:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad190
__jpad190:
    LJAL  putc
    JALR

print_t_label:                 # "t="
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad191
__jpad191:
    LJAL  putc
    ADDI  r1, r0, '='
    LBNE  r0, r0, __jpad192
__jpad192:
    LJAL  putc
    JALR

print_led_prompt:              # "\r\nLED: key=toggle b=blink 0=quit\r\n"
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad193
__jpad193:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad194
__jpad194:
    LJAL  putc
    ADDI  r1, r0, 'L'
    LBNE  r0, r0, __jpad195
__jpad195:
    LJAL  putc
    ADDI  r1, r0, 'E'
    LBNE  r0, r0, __jpad196
__jpad196:
    LJAL  putc
    ADDI  r1, r0, 'D'
    LBNE  r0, r0, __jpad197
__jpad197:
    LJAL  putc
    ADDI  r1, r0, ':'
    LBNE  r0, r0, __jpad198
__jpad198:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad199
__jpad199:
    LJAL  putc
    ADDI  r1, r0, 'k'
    LBNE  r0, r0, __jpad200
__jpad200:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad201
__jpad201:
    LJAL  putc
    ADDI  r1, r0, 'y'
    LBNE  r0, r0, __jpad202
__jpad202:
    LJAL  putc
    ADDI  r1, r0, '='
    LBNE  r0, r0, __jpad203
__jpad203:
    LJAL  putc
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad204
__jpad204:
    LJAL  putc
    ADDI  r1, r0, 'o'
    LBNE  r0, r0, __jpad205
__jpad205:
    LJAL  putc
    ADDI  r1, r0, 'g'
    LBNE  r0, r0, __jpad206
__jpad206:
    LJAL  putc
    ADDI  r1, r0, 'g'
    LBNE  r0, r0, __jpad207
__jpad207:
    LJAL  putc
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad208
__jpad208:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad209
__jpad209:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad210
__jpad210:
    LJAL  putc
    ADDI  r1, r0, 'b'
    LBNE  r0, r0, __jpad211
__jpad211:
    LJAL  putc
    ADDI  r1, r0, '='
    LBNE  r0, r0, __jpad212
__jpad212:
    LJAL  putc
    ADDI  r1, r0, 'b'
    LBNE  r0, r0, __jpad213
__jpad213:
    LJAL  putc
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad214
__jpad214:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad215
__jpad215:
    LJAL  putc
    ADDI  r1, r0, 'n'
    LBNE  r0, r0, __jpad216
__jpad216:
    LJAL  putc
    ADDI  r1, r0, 'k'
    LBNE  r0, r0, __jpad217
__jpad217:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad218
__jpad218:
    LJAL  putc
    ADDI  r1, r0, '0'
    LBNE  r0, r0, __jpad219
__jpad219:
    LJAL  putc
    ADDI  r1, r0, '='
    LBNE  r0, r0, __jpad220
__jpad220:
    LJAL  putc
    ADDI  r1, r0, 'q'
    LBNE  r0, r0, __jpad221
__jpad221:
    LJAL  putc
    ADDI  r1, r0, 'u'
    LBNE  r0, r0, __jpad222
__jpad222:
    LJAL  putc
    ADDI  r1, r0, 'i'
    LBNE  r0, r0, __jpad223
__jpad223:
    LJAL  putc
    ADDI  r1, r0, 't'
    LBNE  r0, r0, __jpad224
__jpad224:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad225
__jpad225:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad226
__jpad226:
    LJAL  putc
    JALR

print_led_on:                  # "led on\r\n"
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad227
__jpad227:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad228
__jpad228:
    LJAL  putc
    ADDI  r1, r0, 'd'
    LBNE  r0, r0, __jpad229
__jpad229:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad230
__jpad230:
    LJAL  putc
    ADDI  r1, r0, 'o'
    LBNE  r0, r0, __jpad231
__jpad231:
    LJAL  putc
    ADDI  r1, r0, 'n'
    LBNE  r0, r0, __jpad232
__jpad232:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad233
__jpad233:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad234
__jpad234:
    LJAL  putc
    JALR

print_led_off:                 # "led off\r\n"
    ADDI  r1, r0, 'l'
    LBNE  r0, r0, __jpad235
__jpad235:
    LJAL  putc
    ADDI  r1, r0, 'e'
    LBNE  r0, r0, __jpad236
__jpad236:
    LJAL  putc
    ADDI  r1, r0, 'd'
    LBNE  r0, r0, __jpad237
__jpad237:
    LJAL  putc
    ADDI  r1, r0, ' '
    LBNE  r0, r0, __jpad238
__jpad238:
    LJAL  putc
    ADDI  r1, r0, 'o'
    LBNE  r0, r0, __jpad239
__jpad239:
    LJAL  putc
    ADDI  r1, r0, 'f'
    LBNE  r0, r0, __jpad240
__jpad240:
    LJAL  putc
    ADDI  r1, r0, 'f'
    LBNE  r0, r0, __jpad241
__jpad241:
    LJAL  putc
    ADDI  r1, r0, '\r'
    LBNE  r0, r0, __jpad242
__jpad242:
    LJAL  putc
    ADDI  r1, r0, '\n'
    LBNE  r0, r0, __jpad243
__jpad243:
    LJAL  putc
    JALR
