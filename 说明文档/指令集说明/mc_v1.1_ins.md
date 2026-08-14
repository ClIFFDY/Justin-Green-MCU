# MCU 指令集与外设用法说明（v1.1）

> 配套版本：MCU v1.1（2026-08-14）。本文从版本开发日志中拆出的**指令与外设速查**；
> 设计演进、时序与调试记录见 `版本开发日志/single_mcu_design_v1.1.md`。
> 编码来源：`decoder.v` / `pc.v` / `reg_f.v` / `single_mcu_top.v` / 各外设 `.v`。

---

## 1. CPU 指令集

### 1.1 编码规则

- 指令字节 = `opcode[5:0] << 2 | len[1:0]`，其中 `len = 字节数 − 1`（即 byte0 低 2 位定指令长度）。
- 指令空间 8 位（PC 0x00–0xFF）；寄存器号、立即数、bytmov 均 8 位（0–255）。
- 4 字节指令布局：`byte0 | byte1 | byte2 | byte3`（固定字段，无字节序问题）。

### 1.2 指令总表

| 类别 | 助记符 | byte0 | 长度 | byte1 | byte2 | byte3 | 功能 |
|------|--------|-------|------|-------|-------|-------|------|
| 控制 | HALT | 0x00 | 1B | — | — | — | 停机（frz 停 PC） |
|      | NOP | 0x50 | 1B | — | — | — | 空操作（if_reg 冲刷时自动插入） |
|      | IRET | 0x54 | 1B | — | — | — | 中断返回：清 irq_busy、恢复断点 |
| 跳转 | LJAL | 0x21 | 2B | bytmov | — | — | 向后跳，压栈保存返回地址 |
|      | RJAL | 0x25 | 2B | bytmov | — | — | 向前跳，压栈保存返回地址 |
|      | JALR | 0x4D | 2B | 0（预留） | — | — | 弹栈并跳转到 ra（调用返回） |
| 分支 | LBEQ | 0x5B | 4B | bytmov | r1 | r2 | r1==r2 则**向后**跳 |
|      | RBEQ | 0x5F | 4B | bytmov | r1 | r2 | r1==r2 则**向前**跳 |
|      | LBNE | 0x63 | 4B | bytmov | r1 | r2 | r1≠r2 则**向后**跳 |
|      | RBNE | 0x67 | 4B | bytmov | r1 | r2 | r1≠r2 则**向前**跳 |
|      | LBLTU | 0x6B | 4B | bytmov | r1 | r2 | r1<r2（无符号）则**向后**跳 |
|      | RBLTU | 0x6F | 4B | bytmov | r1 | r2 | r1<r2（无符号）则**向前**跳 |
| ALU-R | ADD | 0x0B | 4B | rd | r1 | r2 | rd = r1 + r2 |
|      | SUB | 0x13 | 4B | rd | r1 | r2 | rd = r1 − r2 |
|      | AND | 0x17 | 4B | rd | r1 | r2 | rd = r1 & r2 |
|      | OR | 0x1B | 4B | rd | r1 | r2 | rd = r1 \| r2 |
|      | XOR | 0x1F | 4B | rd | r1 | r2 | rd = r1 ^ r2 |
|      | SLL | 0x37 | 4B | rd | r1 | r2 | rd = r1 << r2[2:0] |
|      | SRL | 0x3B | 4B | rd | r1 | r2 | rd = r1 >> r2[2:0]（逻辑右移） |
|      | SLTU | 0x47 | 4B | rd | r1 | r2 | rd = (r1<r2)? 1 : 0（无符号） |
| ALU-I | ADDI | 0x07 | 4B | rd | rs1 | imm8 | rd = rs1 + imm |
|      | SUBI | 0x0F | 4B | rd | rs1 | imm8 | rd = rs1 − imm |
|      | ANDI | 0x2B | 4B | rd | rs1 | imm8 | rd = rs1 & imm |
|      | ORI | 0x2F | 4B | rd | rs1 | imm8 | rd = rs1 \| imm |
|      | XORI | 0x33 | 4B | rd | rs1 | imm8 | rd = rs1 ^ imm |
|      | SLLI | 0x3F | 4B | rd | rs1 | imm8 | rd = rs1 << imm[2:0] |
|      | SRLI | 0x43 | 4B | rd | rs1 | imm8 | rd = rs1 >> imm[2:0]（逻辑右移） |
|      | SLTIU | 0x4B | 4B | rd | rs1 | imm8 | rd = (rs1<imm)? 1 : 0（无符号） |
| 访存 | LBU | 0x73 | 4B | rd | 地址（byte2:byte3） | — | 读 16 位地址 → rd（RAM 或外设） |
|      | SB | 0x77 | 4B | rs | 地址（byte2:byte3） | — | rs 写入 16 位地址（RAM 或外设） |

> **SBI（0x7B，已声明）**：decoder 未译码，属保留位，当前等于多字节 NOP，勿用。

### 1.3 跳转偏移 bytmov

bytmov 是相对**指令末尾**（`指令地址 + 指令长度`）的 8 位无符号偏移：

- **R 前缀（向前）**：`bytmov = 目标 − (指令地址 + 长度)`
- **L 前缀（向后）**：`bytmov = (指令地址 + 长度) − 目标`

实例（真实程序）：`0xB0 LBEQ r0,r0` 回跳 0x9C，指令 4B → `bytmov = 0xB4 − 0x9C = 0x18`，编码 `5B 18 00 00`。

### 1.4 寄存器与栈约定

| 项 | 约定 |
|----|------|
| r0 | 恒为 0（写无效，作零寄存器用） |
| r1–r253 | 通用寄存器 |
| r254 | 空闲可用（v1.1 起不再被 rx_done 占用） |
| r255 | 只读：UART tx_busy（bit0，轮询发完用） |
| 调用栈 | **硬件栈**（reg_f 内 `rad`），深 255；满/空由 j_flag 保护——LJAL/RJAL 压栈、JALR 弹栈 |
| PC | 8 位 0x00–0xFF（ROM/程序区独立于总线地址空间） |

---

## 2. 外设与地址空间

### 2.1 地址空间总表

| 区间 | 设备 | LBU（读） | SB（写） |
|------|------|-----------|----------|
| 0x0000–0x1FFF | 未定义 | 黑洞（返回 0） | 黑洞（丢弃） |
| 0x2000–0x3FFF | data_ram | 读 RAM → rd | 写 RAM |
| 0x4000–0x5FFF | UART | 弹 RX FIFO 队首 → rd | 触发 TX 发送 |
| 0x6000–0x7FFF | 未分配（黑洞） | 黑洞（返回 0） | 黑洞（丢弃） |

> 总线访问均为 2 拍（RAM 存 stall 1 拍；UART 无 stall）。
> **0x6000–0x7FFF 在 v1.1 未分配**；v1.2 起划归 timer 外设（见 `mc_v1.2_ins.md` §2.4）。

### 2.2 data_ram（0x2000–0x3FFF）

| 指令 | 示例 | 行为 |
|------|------|------|
| LBU rd, addr | `LBU r2, 0x2000` | 读 RAM[addr[12:0]] → rd |
| SB rs, addr | `SB r2, 0x2000` | RAM[addr[12:0]] = rs |

- 容量 8KB（13 位地址），上电全 0，无复位；BRAM 风格，2 拍访问。

### 2.3 UART（0x4000–0x5FFF，含 FIFO + 中断）

| 指令 | 地址 | 行为 |
|------|------|------|
| LBU rd | 0x4000 | 弹 RX FIFO 队首 → rd（FIFO 空时返回 0） |
| SB rs | 0x4000 | 触发 uart_tx 发送 rs 字节（电平使能，下拍撤除） |
| 轮询等发完 | r255 | `LBNE r255, r0, 自旋` 直到 tx_busy 归 0 |

- **RX FIFO**：64 深（有效 63 字节），新帧不会覆盖未读旧帧。
- **中断**：`rx_irq = FIFO 非空`（电平）→ 中断源 0，向量 **0xE8**。ISR 每 `LBU r,0x4000` 弹一个字节，读到 FIFO 空为止。
- 发方向仍可中断内做：ISR 里 `SB rs,0x4000` 回发（irq_test 已覆盖）。

### 2.4 中断与向量

| 中断源           | irq_bus[5:3] | 向量  | 优先级  |
| ---------------- | ----------- | ---- | ---- |
| UART RX（FIFO 非空） | 001         | 0xE8  | 仅此一路 |

- **授权门控**：`bytmov == 0`（仅在干净指令边界）才响应——grant 时保存断点 `pc_addr`、跳向量并冲刷流水线。
- **不可重入**：irq_busy 锁存期间不响应新中断；IRET 清锁存并灌回断点后重新开放。
- 单中断源、无抢占：v1.1 只有 UART 一路，ISR 尽快完成或先清源（`LBU` 弹空 FIFO）即可。

---

*本文档随版本更新；新增外设/指令时同步追加对应表格。*
