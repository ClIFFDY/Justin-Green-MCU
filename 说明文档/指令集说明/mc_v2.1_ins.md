# MCU 指令集与外设用法说明（v2.1）

> 配套版本：MCU v2.1（2026-08-17，中断栈/嵌套 + SBI + 向量迁移后归档）。在 v2.0（词寻址 32bit 取指 + 压缩指令/自动打包 + cstall 冻结 pc）基础上做**功能升级**：新增 **SBI 立即数存储**指令、中断控制器加入**8 深返回地址栈与优先级嵌套**、新增**软中断写返回地址端口 IRQ_W(0x5000)**、**ISR 向量整体迁移**（0x88/0xA8/0xC8/0xE0 → 0x208/0x228/0x248/0x260）、修复 **ins_rom 在 RAM stall 期间丢指令**的 bug、首次整机验证 **CPU↔RAM 读写通路**。
> 设计演进、时序与调试记录见 `版本开发日志/single_mcu_design_v2.1.md`。
> 编码来源：`decoder.v` / `pc.v` / `reg_f.v` / `if_reg.v` / `ins_rom.v` / `irq_controller.v` / `single_cpu_top.v` / `single_mcu_top.v` / 各外设 `.v` / `tools/asm.py`。

---

## 1. CPU 指令集

### 1.1 编码规则（词寻址 + flag 压缩）

- **词寻址**：PC 12 位【词地址】0x000–0xFFF（4096 词 × 32bit BRAM），32bit 定长取指。
- **流水线**：`ins_rom(1级) → if_reg(1级) → decoder`；**指令在词 W 执行时 pc_addr = W+2**（取指延迟 2 拍）。
- **词内字节序**：`byte0` 在**高位**（bits[31:24]）。`byte0 = opcode[5:0]<<2 | flag[1:0]`：

| flag | 含义 | 形式 |
|------|------|------|
| 00 | 原长指令 | 独占一个 32bit 词（不足 4 字节补 0） |
| 11 | ALU 类压缩 16bit | `[opcode\|11][rd(2)][r1(3)][r2/imm(3)]`，I 型末字段=imm[2:0] |
| 01 | 无操作数压缩 16bit | `[opcode\|01][0x00]`：仅 NOP / IRET |

- **自动压缩**（汇编器判定，无需手写 flag）：ALU-R/I 满足 `rd≤3、r1/r2≤7`（I 型 `imm≤7`）→ flag=11；`NOP/IRET` → flag=01；其余指令恒为原长。
- **自动打包**：相邻两条压缩指令共享一个 32bit 词（前=[31:16]、后=[15:0]）。**跳转/分支目标必须落在词首指令**；独个可压缩指令退回原长（保证压缩词两半都非空，if_reg 的 cstall 拆包才正确）。
- **解包**：if_reg 检测到词两半 flag 均≠00 时，用 `cstall` 冻结 pc，两半各输出 1 拍；解包后的 32bit 指令 opcode 仍在 [31:26]，压缩字段经 if_reg 原位展开（rd→byte1 低 2 位、r1→byte2 低 3 位、r2/imm→byte3 低 3 位），decoder 无需感知压缩。

### 1.2 指令总表

opcode[5:0] 见下表（byte0 列为 `flag=00` 时的值；原长指令均占 1 词）。

| 类别 | 助记符 | opcode | byte0(00) | 压缩 | 布局（原长，byte0 之后） | 功能 |
|------|--------|--------|-----------|------|--------------------------|------|
| 控制 | HALT | 0x00 | 0x00 | flag=01 | — | 停机（frz 停 PC） |
|      | NOP | 0x14 | 0x50 | flag=01 | — | 空操作（if_reg 冲刷时自动插入） |
|      | IRET | 0x15 | 0x54 | flag=01 | — | 中断返回：恢复断点 |
| 跳转 | LJAL | 0x08 | 0x20 | 否 | `bytmov16`（byte1:2） | 向后跳，压栈保存返回地址 |
|      | RJAL | 0x09 | 0x24 | 否 | `bytmov16`（byte1:2） | 向前跳，压栈保存返回地址 |
|      | JALR | 0x13 | 0x4C | 否 | — | 弹栈并跳转到 ra（调用返回） |
| 分支 | LBEQ | 0x16 | 0x58 | 否 | `bytmov16` + `{r1,r2}4b`（byte3） | r1==r2 则**向后**跳 |
|      | RBEQ | 0x17 | 0x5C | 否 | 同上 | r1==r2 则**向前**跳 |
|      | LBNE | 0x18 | 0x60 | 否 | 同上 | r1≠r2 则**向后**跳 |
|      | RBNE | 0x19 | 0x64 | 否 | 同上 | r1≠r2 则**向前**跳 |
|      | LBLTU | 0x1A | 0x68 | 否 | 同上 | r1<r2（无符号）则**向后**跳 |
|      | RBLTU | 0x1B | 0x6C | 否 | 同上 | r1<r2（无符号）则**向前**跳 |
| ALU-R | ADD | 0x02 | 0x08 | flag=11 | rd, r1, r2（各 8 位） | rd = r1 + r2 |
|      | SUB | 0x04 | 0x10 | flag=11 | rd, r1, r2 | rd = r1 − r2 |
|      | AND | 0x05 | 0x14 | flag=11 | rd, r1, r2 | rd = r1 & r2 |
|      | OR | 0x06 | 0x18 | flag=11 | rd, r1, r2 | rd = r1 \| r2 |
|      | XOR | 0x07 | 0x1C | flag=11 | rd, r1, r2 | rd = r1 ^ r2 |
|      | SLL | 0x0D | 0x34 | flag=11 | rd, r1, r2 | rd = r1 << r2[2:0] |
|      | SRL | 0x0E | 0x38 | flag=11 | rd, r1, r2 | rd = r1 >> r2[2:0]（逻辑右移） |
|      | SLTU | 0x11 | 0x44 | flag=11 | rd, r1, r2 | rd = (r1<r2)? 1 : 0（无符号） |
| ALU-I | ADDI | 0x01 | 0x04 | flag=11 | rd, rs1, imm8 | rd = rs1 + imm |
|      | SUBI | 0x03 | 0x0C | flag=11 | rd, rs1, imm8 | rd = rs1 − imm |
|      | ANDI | 0x0A | 0x28 | flag=11 | rd, rs1, imm8 | rd = rs1 & imm |
|      | ORI | 0x0B | 0x2C | flag=11 | rd, rs1, imm8 | rd = rs1 \| imm |
|      | XORI | 0x0C | 0x30 | flag=11 | rd, rs1, imm8 | rd = rs1 ^ imm |
|      | SLLI | 0x0F | 0x3C | flag=11 | rd, rs1, imm8 | rd = rs1 << imm[2:0] |
|      | SRLI | 0x10 | 0x40 | flag=11 | rd, rs1, imm8 | rd = rs1 >> imm[2:0]（逻辑右移） |
|      | SLTIU | 0x12 | 0x48 | flag=11 | rd, rs1, imm8 | rd = (rs1<imm)? 1 : 0（无符号） |
| 访存 | LBU | 0x1C | 0x70 | 否 | rd, 16 位地址（byte2:3） | 读 → rd（RAM 或外设） |
|      | SB | 0x1D | 0x74 | 否 | rs, 16 位地址（byte2:3） | rs 写入（RAM 或外设） |
|      | SBI | 0x1E | 0x78 | 否 | imm8（byte1）, 16 位地址（byte2:3） | **立即数**写入（RAM 或外设） |

共 **32 条真实指令** + 1 条伪指令（v2.0 31 条 + 新增 SBI）。指令语义与 v2.0 相同，仅新增 SBI；byte0/opcode 编码沿用 v2.0。

> **伪指令 MOV**：`MOV rd, rs` = 复制（rd ← rs）。RTL **不设 MOV opcode**，汇编器把它翻译为 `ADDI rd, rs, 0`（语义等价、自动继承 ADDI 压缩：rd≤3 且 rs≤7 时压成 16bit，否则原长 4 字节）。
> **SBI（v2.1 新增）**：`SBI imm8, addr16` —— byte1=立即数（inst_raw[23:16]）、byte2:3=16 位地址，与 SB 布局一致、仅**数据源改为立即数**（SB 数据源是寄存器）。可用于 RAM/外设写立即数，省去先 `ADDI rd,r0,imm` 再 `SB rd,addr` 两步。

> **分支寄存器 4 位**：6 条条件分支的 r1/r2 只编码低 4 位（byte3 = `r1[3:0]<<4 | r2[3:0]`，可用 r0–r15）。汇编器对超出 0x0F 的寄存器报错。
> **压缩字段上限**：ALU 压缩要求 `rd≤3、r1/r2≤7`（I 型 `imm≤7`），超限自动退回原长——对汇编器透明。

### 1.3 压缩编码详解（16bit，位于词的 [31:16] 或 [15:0]）

```
高 8 位 = byte0 = opcode[5:0]<<2 | flag
低 8 位 = {rd[1:0], r1[2:0], r2[2:0]}      （flag=11，ALU-R）
       = {rd[1:0], rs1[2:0], imm[2:0]}    （flag=11，ALU-I）
       = 0x00                             （flag=01，NOP/IRET）
```

### 1.4 跳转偏移 bytmov（16 位【词单位】，基准 W+2）

bytmov 是相对 **W+2**（指令在词 W 执行时的 pc 值）的**词数**偏移：

- **R 前缀（向前）**：`bytmov = target − (W+2)`
- **L 前缀（向后）**：`bytmov = (W+2) − target`

**覆盖极限**：

- bytmov 16 位 → 每一跳/分支最多 ±0xFFFF 词，**覆盖 0x000–0xFFF 全空间，一跳贯通，不再需要链条跳转**（v1.4 是 ±255 字节、需分段中转）。
- `target = W+2` 时 `bytmov = 0`，而 pc.v 判 0 为不跳 → **该目标不可编码**；向前最少跳 2 词（`bytmov=1` 向前 = W+3，向后最近 = W+1）。
- 汇编器自动算 bytmov，越界/目标非词首时报错并提示换方向或核对 listing。

### 1.5 寄存器与栈约定

| 项 | 约定 |
|----|------|
| r0 | 恒为 0（写无效，作零寄存器用） |
| r1–r254 | 通用寄存器（**分支比较只能用 r0–r15**） |
| r255 | 只读：UART tx_busy（bit0，轮询发完用） |
| 调用栈 | **硬件栈**（reg_f 内 `rad`，**16 位槽 × 深 255**），LJAL/RJAL 压栈、JALR 弹栈，满/空由 j_flag 保护 |
| PC | **12 位词地址 0x000–0xFFF**（4096 词，ROM/程序区独立于总线地址空间） |

---

## 2. 外设与地址空间

> 地址空间与 v1.4/v2.0 **相同**，仅新增 **IRQ_W(0x5000)** 软中断写返回地址端口（v2.1）。

### 2.1 地址空间总表

解码位 `[15:12]`（4 位）：

| 区间 | 设备 | LBU（读） | SB（写） |
|------|------|-----------|----------|
| 0x0000–0x1FFF | 未定义 | 黑洞（返回 0） | 黑洞（丢弃） |
| 0x2000–0x2FFF | UART | 弹 RX FIFO 队首 → rd | 触发 TX 发送 |
| 0x3000–0x3FFF | timer | 黑洞（返回 0） | 重装 / 模式 / ack |
| 0x4000–0x4FFF | GPIO | 读 IN 引脚电平 → rd | 推挽输出 / 单 pin 模式 |
| **0x5000–0x5FFF** | **IRQ_W（软中断）** | 黑洞 | **2 条连续 SB 改写 ISR 返回地址** |
| 0x8000–0xBFFF | ram_top（4×ram_sec） | 读 RAM → rd | 写 RAM |

> 总线访问均为 2 拍：**RAM 第 1 拍置 stall**；UART/timer/GPIO/IRQ_W 无 stall。
> 0x6000–0x7FFF / 0xC000–0xFFFF 未分配（黑洞）。

### 2.2 ram_top（0x8000–0xBFFF，16KB）

- `LBU rd, addr` / `SB rs, addr` / **`SBI imm8, addr`**；`ram_top.v` + 4×`ram_sec.v`，每片 4096B BRAM，**连续 4×4KB = 16KB**。
- **分片选择 = `addr[13:12]`（高位选片），片内偏移 = `addr[11:0]`**：

| 地址段 | 分片 |
|--------|------|
| 0x8000–0x8FFF | seg0（ram_sec_1） |
| 0x9000–0x9FFF | seg1（ram_sec_2） |
| 0xA000–0xAFFF | seg2（ram_sec_3） |
| 0xB000–0xBFFF | seg3（ram_sec_4） |

- 上电全 0；同步写 / 寄存器读，2 拍访问（`stall_bus = access && !done`）。**v2.1 首次整机验证 4 分片 SB/LBU + SBI 读写全通**（见 single_mcu_design_v2.1.md §6）。

### 2.3 UART（0x2000–0x2FFF，含 FIFO + 中断）

- `LBU rd`@0x2000 弹 RX FIFO 队首（空返 0）；`SB rs`@0x2000 触发发送；`LBNE r255,r0,自旋` 等 tx_busy 归 0。
- **RX FIFO**：64 深（有效 63），新帧不覆盖未读旧帧。
- **中断**：`rx_irq = FIFO 非空`（电平）→ 向量 **0x260**（词地址，v2.1 迁移）。ISR 每 `LBU r,0x2000` 弹一字节，读到空为止；可 `SB rs,0x2000` 回发。

### 2.4 timer（0x3000–0x3FFF，纯写，32 位）

- `SB rs`@0x3000/0x3001/0x3002/0x3003 设重装值字节 0/1/2/3；@0x3004 设 irq 模式（**数据值** bit0=0 脉冲 / bit0=1 电平锁存）；@0x3005 **ack** 清 timer_irq。
- 计数 0→重装值，**全 32 位相等**时 `timer_irq=1` 并清零，**周期 = 重装值 + 1 拍**。例：周期 65536 拍 → 重装值 0x0000FFFF。
- 关闭：重装值全 0 不计数。中断：向量 **0x248**（v2.1 迁移）。

### 2.5 GPIO（0x4000–0x4FFF，8 位）

- `LBU rd` 读引脚（仅 IN 模式回电平，其余位恒 0）；`SB rs`@偶数地址推挽输出；`SB rs`@奇数地址设单 pin 模式（`addr[3:1]` 选 pin、`data[3:0]` 选模式）。

| 值 | 模式 | 引脚行为 |
|----|------|----------|
| 0000 | UNUSE（默认） | **高阻不驱动** |
| 0001 | OUT | 驱动 `gpio_output` |
| 0010 | IN | 高阻，LBU 可读回 |
| 0011 | IRQ | 高阻，电平式中断 |
| 0101 | TX | 驱动跟随 uart_tx `tx` |
| 0110 | RX | 高阻，电平直送 uart_rx `rx` |

- **方向**：**仅 OUT/TX 驱动，其余全高阻**（v1.4 修复沿用）。
- **中断分组**：pins 1–3 → GPIO1（**0x228**）；pins 4–7 → GPIO2（**0x208**，v2.1 迁移）。电平式持续触发、无 ack；pin 保持高即反复进 ISR。
- pin0 保留；非 OR：同组多 IRQ pin 同时有效只有最后生效。

### 2.6 中断、向量与嵌套（v2.1 重写）

| 中断源 | irq_bus[5:3] | 子源 [2:0] | irq_vex 索引 | 向量 | ISR 区间 | 优先级 |
|--------|--------------|-----------|--------------|------|----------|--------|
| Timer | 001 | 000 | 0 | 0x248 | 0x248–0x25F | 低（1） |
| UART RX（FIFO 非空） | 010 | 000 | 1 | 0x260 | 0x260–0x27F | 高（2） |
| GPIO1（pins 1–3） | 010 | 001 | 2 | 0x228 | 0x228–0x247 | 高（2） |
| GPIO2（pins 4–7） | 010 | 010 | 3 | 0x208 | 0x208–0x227 | 高（2） |

- **向量 = 词地址**（irq_vex：TIMER=584=0x248 / UART_RX=608=0x260 / GPIO1=552=0x228 / GPIO2=520=0x208）。**v2.1 整体迁移**（v2.0 为 0x88/0xA8/0xC8/0xE0，配合新上板程序布局）。索引计算：`irq_vex[irq_addr_in[5:3] + irq_addr_in[2:0] − 1]`（irq_bus 编码见上表，single_mcu_top.v）。
- **优先级（v2.1 重排）**：irq_bus 编码 timer=001(1) < uart=010(2) = gpio=010(2)。irq_controller 用 `prio = irq_addr_in[5:3]`，**更高优先级（[5:3] 更大）可抢占当前 ISR**。
- **中断栈 / 嵌套（v2.1 新增）**：irq_controller 内置 **8 深返回地址栈 `pc_addr[0:7]` + 栈指针 `j`**：
  - 接受中断（IDLE 或 IRQ 且 `irq_addr_in[5:3] > prio && j ≤ 15`）→ `pc_addr[j] <= 断点; j++`，跳向量。
  - **IRET** → `j--`，恢复 `pc_addr[j]` 断点；`j==0` 回 IDLE（嵌套逐层返回）。
  - 中断不可重入限制取消：低优先级 ISR 期间可被高优先级抢占。
- **软中断 IRQ_W（v2.1 新增，0x5000）**：ISR 活动时，**连续 2 条 SB 到 0x5000–0x5FFF** 改写栈顶返回地址——第 1 条 `pc_addr[11:8] <= data[3:0]`（stage→OPR），第 2 条 `pc_addr[7:0] <= data`（stage→IRQ）。之后 IRET 跳**改写后的目标**而非原断点（可自定义 ISR 落点/任务切换）。
- **授权门控**：`bytmov == 0`（仅在干净指令边界）才响应——grant 时保存断点 `pc_addr`、跳向量并冲刷流水线。

---

*本文档随版本更新；新增外设/指令时同步追加对应表格。*
