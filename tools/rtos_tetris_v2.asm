# ============================================================
# rtos_tetris.asm — 俄罗斯方块 v2（LIND/SIND 间接访存优化）
#   生成: python tools/gen_tetris_v2.py > tools/rtos_tetris.asm
#   汇编: python tools/asm.py tools/rtos_tetris.asm -o tools/rtos_tetris.hex
#   v2: 字段 20 行 × 16bit 掩码；LIND/SIND 寄存器寻址去掉 20 路分发；渲染循环化
#   玩法: 4=左移 6=右移 5=旋转 0=退出；1Hz 下落；#=方块 0=背景 @=边框
# ============================================================
.equ UART 0x2000
.equ TIMER_CNT0 0x3000
.equ TIMER_CNT1 0x3001
.equ TIMER_CNT2 0x3002
.equ TIMER_CNT3 0x3003
.equ TIMER_MODE 0x3004
.equ TIMER_ACK 0x3005
.equ GPIO_PIN0 0x4001
.equ GPIO_PIN1 0x4003
.equ MODE_RX 6
.equ MODE_TX 5
.equ TICK_LO 0x9000
.equ TICK_HI 0x9001
.equ UART_S1 0x9002
.equ UART_S2 0x9003
.equ UART_S3 0x9004
.equ TIMER_S1 0x9005
.equ RX_RING0 0x9100
.equ RX_RING1 0x9101
.equ RX_RING2 0x9102
.equ RX_RING3 0x9103
.equ RX_RING4 0x9104
.equ RX_RING5 0x9105
.equ RX_RING6 0x9106
.equ RX_RING7 0x9107
.equ RX_WR 0x9108
.equ RX_RD 0x9109
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

.org 0x000
reset:
    ADDI  r254, r0, 0
    ADDI  r1, r0, MODE_RX
    SB    r1, GPIO_PIN0
    ADDI  r1, r0, MODE_TX
    SB    r1, GPIO_PIN1
    SB    r0, RX_WR
    SB    r0, RX_RD
    SB    r0, TICK_LO
    SB    r0, TICK_HI
    SB    r0, G_SCORE
    SB    r0, G_LAST_TICK
    SB    r0, G_ACC_LO
    SB    r0, G_ACC_HI
    SB    r0, G_OVER
    # 清空字段（SIND 循环 40 字节）
    ADDI  r1, r0, 0x94
    ADDI  r2, r0, 0x00
    ADDI  r3, r0, 40
__clr_fld:
    SIND  r0, r1, r2
    ADDI  r2, r2, 1
    ADDI  r3, r3, 0xFF
    RBNE  r3, r0, __clr_fld
    # timer 0x270F -> 0.2ms
    ADDI  r1, r0, 0x0F
    SB    r1, TIMER_CNT0
    ADDI  r1, r0, 0x27
    SB    r1, TIMER_CNT1
    SB    r0, TIMER_CNT2
    SB    r0, TIMER_CNT3
    ADDI  r1, r0, 1
    SB    r1, TIMER_MODE
    RJAL  spawn
    RJAL  render
game_loop:
    RJAL  input_handle
    RJAL  drop_check
    LBU   r1, G_OVER
    RBNE  r1, r0, game_over
    LBEQ  r0, r0, game_loop
game_over:
    .puts "GAME OVER\r\nSCORE: "
    LBU   r7, G_SCORE
    RJAL  print_hex
    RJAL  put_crlf
    HALT

.org 0x100
putc:
putc_wait:
    ADDI  r8, r255, 0
    LBNE  r8, r0, putc_wait
    SB    r7, UART
    JALR
put_crlf:
    ADDI  r7, r0, '\r'
    RJAL  putc
    ADDI  r7, r0, '\n'
    RJAL  putc
    JALR
print_hexdigit:
    ADDI  r8, r0, 9
    RBLTU r8, r7, __phx_af
    ADDI  r7, r7, '0'
    RJAL  putc
    JALR
__phx_af:
    ADDI  r7, r7, 55
    RJAL  putc
    JALR
print_hex:
    ADDI  r9, r7, 0
    SRLI  r7, r9, 4
    RJAL  print_hexdigit
    ANDI  r7, r9, 0x0F
    RJAL  print_hexdigit
    JALR

.org 0x208
    IRET
.org 0x228
    IRET
.org 0x248
timer_isr:
    SB    r1, TIMER_S1
    LBU   r1, TICK_LO
    ADDI  r1, r1, 1
    SB    r1, TICK_LO
    RBNE  r1, r0, __tick_nc
    LBU   r1, TICK_HI
    ADDI  r1, r1, 1
    SB    r1, TICK_HI
__tick_nc:
    SB    r0, TIMER_ACK
    LBU   r1, TIMER_S1
    IRET
.org 0x260
uart_isr:
    SB    r1, UART_S1
    SB    r2, UART_S2
    SB    r3, UART_S3
    LBU   r1, UART
    LBU   r2, RX_WR
    LBU   r3, RX_RD
    ADDI  r2, r2, 1
    ANDI  r2, r2, 7
    RBNE  r2, r3, __ur_room
    RBEQ  r0, r0, __ur_restore
__ur_room:
    LBU   r2, RX_WR
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
    NOP
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

.org 0x300
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
__ih_0:
    ADDI  r8, r0, '0'
    RBNE  r7, r8, __ih_other
    .puts "QUIT\r\n"
    HALT
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

render:
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
    # 顶边框
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    RJAL  put_crlf
    # 20 行循环
    ADDI  r17, r0, 0            # r17 = 行
__r_loop:
    ADDI  r7, r0, '@'
    RJAL  putc
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
    RJAL  putc
    RJAL  put_crlf
    ADDI  r17, r17, 1
    ADDI  r1, r17, 0
    ADDI  r2, r0, 20
    RBLTU r1, r2, __r_loop
    # 底边框
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    ADDI  r7, r0, '@'
    RJAL  putc
    RJAL  put_crlf
    .puts "SCORE: "
    LBU   r7, G_SCORE
    RJAL  print_hex
    RJAL  put_crlf
    JALR

print_cells:               # r1=lo(8格) r2=hi(2格) -> 打印 10 格
    ADDI  r6, r0, 8
__pc_loop:
    ANDI  r3, r1, 1
    RBNE  r3, r0, __pc_hash
    ADDI  r7, r0, '.'
    RJAL  putc
    RBEQ  r0, r0, __pc_next
__pc_hash:
    ADDI  r7, r0, '#'
    RJAL  putc
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
    RJAL  putc
    RBEQ  r0, r0, __pc_hnext
__pc_hhash:
    ADDI  r7, r0, '#'
    RJAL  putc
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
