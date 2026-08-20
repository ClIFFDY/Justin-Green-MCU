# MCU 指令集与外设用法说明（v3.2.0 —— DMA 渲染帧 / 双总线 / 向量表可配 / UART 双 FIFO，ISA 无改动）

> 配套版本：MCU v3.2.0（2026-08-21，外设功能扩展版）。**ISA 与 v3.0/v3.0.1/v3.1.0 完全相同（指令总数 34），无改动**；本文件随版本重命名一份（v3.0 起归档规范）。v3.2.0 变化集中在**外设与总线**：新增 **DMA 模块**（0x7000 区，16 深 FIFO、独立总线 bus_f2）、外设改**双端口**（bus_addr_in + bus_addr_dma）、**irq_controller 向量表总线可写** + **bus_controller 一次性 lock**、**uart_top RX/TX 双 FIFO**、俄罗斯方块**渲染帧 DMA 输出**（ram_ext 0xC000 → DMA → UART）。**指令编码/布局不变**。
> v3.1.0（2026-08-20）外设架构重构：ins_rom 8192 词 / PC 13 位、bus_controller 统一仲裁 + 可配中断优先级（0x6000，prio=0 关闭）、ram_ext 4 bank 选片、数据区 0xA000。
> v3.0（2026-08-19）核心架构重构 + ISA 扩展：新增 LIND/SIND（32→34），WNS 优化（reg_f 同步读 + 读后写转发 + stall 冻结）。
> v3.0.1（2026-08-20）系统层整合：俄罗斯方块集成 shell、hex 分离 2 个、汇编器 `.data`/`.puts`。
> **v3.2.0 外设变化**：① **DMA**（0x7000-0x7FFF）：ini/cnt/des/bank 可配、cnt 读回（0x7600/0x7700）、16 深 FIFO、独立总线 bus_f2；② **双端口外设**：`dma_oc` 仲裁 CPU/DMA 总线；③ **IRQ 向量表可写**（0x5000 区 [4:2]=槽位、[1:0]=1高/2低字节）+ 一次性 lock（0x6000 bit3=1 写 prio / bit3=0 解锁）；④ **中断优先级 5 槽**（新增 DMA dev=5，prio[4]）；⑤ **UART RX/TX 双 FIFO**；⑥ 汇编器/软件：FRAME_IDX 16 位、渲染帧 DMA。
> 设计演进、时序与调试记录见 `版本开发日志/single_mcu_design_v3.2.0.md`（DMA/双总线/向量表/UART FIFO）与 `版本开发日志/single_mcu_design_v3.1.0.md`（外设架构重构）等。
> 编码来源：`decoder.v` / `pc.v` / `reg_f.v` / `pre_decoder.v` / `ins_rom.v` / `irq_controller.v` / `single_cpu_top.v` / `single_mcu_top.v` / `bus_controller.v` / `dma.v` / `uart_top.v` / `ram_sec_init.v` / `ram_ext_top.v` / 各外设 `.v` / `tools/asm.py`。

---

## 1. CPU 指令集

### 1.1 编码规则（词寻址 + flag 压缩）

- **词寻址**：PC 13 位【词地址】0x000–0x1FFF（8192 词 × 32bit BRAM，v3.1.0 扩容），32bit 定长取指。
- **流水线**：`ins_rom(1级) → if_reg(1级) → decoder`；**指令在词 W 执行时 pc_addr = W+2**（取指延迟 2 拍）。
- **词内字节序**：`byte0` 在**高位**（bits[31:24]）。`byte0 = opcode[5:0]<<2 | flag[1:0]`：

| flag | 含义 | 形式 |
|------|------|------|
| 00 | 原长指令 | 独占一个 32bit 词（不足 4 字节补 0） |
| 11 | ALU 类压缩 16bit | `[opcode\|11][rd(2)][r1(3)][r2/imm(3)]`，I 型末字段=imm[2:0] |
| 01 | 无操作数压缩 16bit | `[opcode\|01][0x00]`：仅 NOP / IRET |

- **自动压缩**（汇编器判定，无需手写 flag）：ALU-R/I 满足 `rd≤3、r1/r2≤7`（I 型 `imm≤7`）→ flag=11；`NOP/IRET` → flag=01；其余指令恒为原长。
- **自动打包**：相邻两条压缩指令共享一个 32bit 词（前=[31:16]、后=[15:0]）。**跳转/分支目标必须落在词首指令**；独个可压缩指令退回原长（保证压缩词两半都非空，if_reg 的 cstall 拆包才正确）。
- **解包**：if_reg 检测到词两半 flag 均≠00 时，用 `cstall` 冻结 pc，两半各输出 1 拍；解包后的 32bit 指令 opcode 仍在 [31:26]，压缩字段经 if_reg 原位展开，decoder 无需感知压缩。cstall 前半拍 irq_en=0（中断被屏蔽），后半拍恢复放行。

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
|      | SBI | 0x1E | 0x78 | 否 | imm8（byte1）, 16 位地址（byte2:3） | 立即数写入（RAM 或外设） |
|      | **LIND** | **0x1F** | **0x7C** | 否 | rd, r1, r2（各 8 位寄存器号） | **寄存器间接读**：rd = 读 `[regs[r1]:regs[r2]]` |
|      | **SIND** | **0x20** | **0x80** | 否 | rs, r1, r2（各 8 位寄存器号） | **寄存器间接写**：写 `[regs[r1]:regs[r2]]` = rs |

共 **34 条真实指令** + 1 条伪指令。**v3.0 新增 LIND/SIND（寄存器间接访存），其余 32 条与 v2.3.1 完全一致**。


> **寄存器间接寻址（v3.0 新增，LIND/SIND）**：地址 = `regs[r1] 的内容 << 8 | regs[r2] 的内容`（16 位）。r1/r2 是**寄存器号**（byte2/byte3），其内容拼成访存地址；与 LBU/SB 走同一总线（RAM 或外设）。寄存器字段 8 位（0–255），任意寄存器可编（含 r254/r255），地址寄存器 r1/r2 可任选。LIND/SIND 恒原长 1 词（不压缩）。
> 例：`LIND r6, r10, r11`：r10 内容 = 0x94、r11 内容 = 0x04 → 读 0x9404 → r6（俄罗斯方块 v2 用 r10/r11 作地址，避让返回寄存器 r1）。
> **伪指令 MOV**：`MOV rd, rs` = 复制（rd ← rs）。RTL 不设 MOV opcode，汇编器翻译为 `ADDI rd, rs, 0`（语义等价、自动继承 ADDI 压缩）。
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

**覆盖极限**：bytmov 16 位 → 每一跳/分支最多 ±0xFFFF 词，**覆盖 0x000–0x1FFF 全空间，一跳贯通**。
**汇编器自动修复（v2.3）**：`tools/asm.py` 对 bytmov 死区自动补 NOP（AUTO_NOP）；对方向写反的 L/R 前缀自动翻转（AUTO_FLIP）；支持 `\b`/`\xNN` 转义。

### 1.5 寄存器与栈约定

| 项 | 约定 |
|----|------|
| r0 | 恒为 0（写无效，作零寄存器用） |
| r1–r253 | 通用寄存器（**分支比较只能用 r0–r15**；ALU/LBU/SB 可用任意寄存器） |
| **r254** | **返回栈指针 j（v2.3 起）**：LJAL/RJAL 压 `rad[regs[254]]` 且 regs[254]++，JALR 弹栈；**软件可直接读写** |
| r255 | 只读：UART tx_busy（bit0，轮询发完用） |
| 调用栈 | **硬件栈**（reg_f 内 `rad`，**16 位槽 × 深 255**），LJAL/RJAL 压栈、JALR 弹栈 |
| **调用栈分区（v2.3）** | rad[0:255] 按任务分区（任务0 0-63 / 任务1 64-127 / 任务2 128-191），调度器切任务时恢复各自 j |
| PC | **13 位词地址 0x000–0x1FFF**（8192 词，v3.1.0 扩容；ROM/程序区独立于总线地址空间） |

---

## 2. 外设与地址空间

> 地址空间 v3.2.0 变化（相对 v3.1.0 基线）：**0x7000 区新增 DMA 配置**、**0x5000 区新增向量表写**、**0x6000 中断优先级 5 槽 + 一次性 lock**、UART 改 RX/TX 双 FIFO。**UART/timer/GPIO/RAM/ram_ext 地址不变**。

### 2.1 地址空间总表

解码位 `[15:12]`（4 位）：

| 区间 | 设备 | LBU（读） | SB（写） |
|------|------|-----------|----------|
| 0x0000–0x1FFF | 未定义 | 黑洞（返回 0） | 黑洞（丢弃） |
| 0x2000–0x2FFF | UART | 弹 RX FIFO 队首 → rd | 写 TX FIFO（触发发送） |
| 0x3000–0x3FFF | timer | 黑洞（返回 0） | 重装 / 模式 / ack |
| 0x4000–0x4FFF | GPIO | 读 IN 引脚电平 → rd | 推挽输出 / 单 pin 模式 |
| 0x5000–0x5FFF | IRQ_W（软中断） | **读被抢占断点 slot（v2.3）** | **向量表写（v3.2.0）** / 2 条连续 SB 改写 ISR 返回地址 |
| 0x6000–0x6FFF | **BUS_CON** | 黑洞（返回 0） | **写中断优先级 / 一次性解锁（v3.2.0）** |
| 0x7000–0x7FFF | **DMA（v3.2.0）** | **读 cnt_wr（0x7600/0x7700）** | **配置 ini/cnt/des/bank + 触发** |
| 0x8000–0xAFFF | ram_top（3×ram_sec） | 读 RAM → rd | 写 RAM |
| 0xB000–0xBFFF | ram_ext 选片 | 黑洞（返回 0） | SB one-hot 选 bank |
| 0xC000–0xCFFF | ram_ext 数据 | 读当前选中 bank → rd | 写当前选中 bank |

> 总线访问均为 2 拍：**RAM 第 1 拍置 stall**（写不 stall）；UART/timer/GPIO/IRQ_W/BUS_CON/DMA 无 stall。LIND/SIND 与 LBU/SB 走同一总线，可访问 RAM 与外设。
> 0xD000–0xFFFF 未分配（黑洞）。

### 2.2 双端口外设（v3.2.0）

外设（ram_top/ram_ext/uart）改**双端口**：

```verilog
wire dma_oc = (bus_addr_dma[15:12] == 本外设段);
wire [15:0] bus_addr_final = dma_oc ? bus_addr_dma : bus_addr_in;
wire [7:0]  bus_data_final = dma_oc ? bus_data_dma  : bus_data_in;
wire [3:0]  bus_sig_final  = dma_oc ? bus_sig_dma   : bus_sig_in;
```

- **bus_addr_in**（CPU 总线，bus_f1）与 **bus_addr_dma**（DMA 总线，bus_f2）。
- `dma_oc`（DMA 正在访问本外设段）时用 DMA 总线，否则用 CPU 总线——**DMA 工作时切走 CPU 访问**。

### 2.3 bus_controller（统一仲裁 + 中断优先级 + 一次性 lock）

- **CPU 读仲裁** `bus_data_b`（`bus_addr_f_in[15:12]`）与 **DMA 读返回仲裁** `bus_data_to_dma`（`bus_addr_dma_in[15:12]`）双路。
- **中断优先级（5 槽）**：0=timer 1=rx 2=gpio0 3=gpio1 **4=dma**（v3.2.0 新增）。SB `0x6000+[2:0]`（**addr bit3=1**）写 prio（2bit，0=关闭）。默认复位 `irq_prio[i]=i+1`（**dma=5 最高，boot 必须 0x600C=0 关**）。
- **一次性 lock（v3.2.0）**：复位 `irq_lock=1`（irq_bus 全 0，锁中断）；`SB 0x6000-0x6007`（**addr bit3=0**）→ `irq_lock=0`（解锁，不可再锁）。boot 在锁内完成 prio + 向量配置。
- **irq_bus 编码** `{prio[2:0], dev[2:0], 000}`（prio 在 [8:6]、dev 在 [5:3]），dev timer=001/rx=010/gpio0=011/gpio1=100/**dma=101**。

### 2.4 DMA（0x7000–0x7FFF，v3.2.0 新增）

- **状态机**：IDLE → INI → HSH → LD ↔ WR（UART 模式超时终止）。
- **配置**（IDLE 态 SB 写）：

| 寄存器 | 地址 | 编码 |
|--------|------|------|
| ini_addr | 0x7000+[7:0] | `{addr[7:0], data}` 16 位源地址 |
| cnt | 0x7100+[7:0] | `{addr[7:0]=高字节, data=低字节}`，**一次写满 16 位** |
| cnt_due | 0x7200+[7:0] | UART 超时阈值 |
| des_addr | 0x7300+[7:0] | 目的地址 |
| ini_bank | 0x7400+[7:0] | ram_ext 选片 |
| 触发 | 0x7500 | → INI |
| 清 irq | 0x7600 | 写任意 |
| 读 cnt | 0x7600 / 0x7700 | `[11:8]==6`→cnt_wr[15:8] / `==7`→[7:0] |

- **工作**：INI 写 ram_ext 选片（0xB000）→ HSH 摆源地址 → LD 读 FIFO → WR 发目的（UART 等 tx_busy）。cnt_wr 归 0 → IDLE + dma_irq。
- **俄罗斯方块用法**：渲染帧写 ram_ext bank0（0xC000），`SB r0,0x7500` 触发，DMA 发 UART（0x2000），软件轮询 cnt（0x7600/0x7700）等完成。

### 2.5 ram_top（0x8000–0xAFFF，12KB）

- `LBU rd, addr` / `SB rs, addr` / `SBI imm8, addr`；`ram_top.v` + 3×`ram_sec`，每片 4096B BRAM，连续 3×4KB = 12KB。
- **分片选择 = `addr[13:12]`**：

| 地址段 | 分片 |
|--------|------|
| 0x8000–0x8FFF | seg0（ram_sec_1） |
| 0x9000–0x9FFF | seg1（ram_sec_2） |
| 0xA000–0xAFFF | seg2（**ram_sec_init**，readmemh data.hex = 数据区） |

- ram_sec_1/2 上电全 0；ram_sec_init 由 data.hex 初始化。同步写 / 寄存器读，2 拍访问（`stall_bus = access && !done`）。

### 2.5.1 ram_ext_top（0xB000 选片 + 0xC000 访问，4×4KB）

- **选片（SB 0xB000）**：`bank_num <= 4'b0001 << bus_data_in[1:0]`（one-hot 整体替换）+ `sec_num <= bus_data_in[1:0]`。
- **访问（0xC000）**：读写当前选中 bank，片内偏移 `addr[11:0]`，直到下次选片切换。
- 上电 bank_num 未选（需先 SB 选片）；访问 2 拍（done 握手）。

### 2.6 UART（0x2000–0x2FFF，RX/TX 双 FIFO，v3.2.0）

- `LBU rd`@0x2000 弹 RX FIFO 队首（空返 0）；`SB rs`@0x2000 写 TX FIFO；`LBNE r255,r0,自旋` 等 tx_busy 归 0。
- **RX FIFO**：64 深（有效 63），wr 从 1 起 / rd 从 0 起，**读出 `rx_buf[rd+1]`**（rd 落后一格），判空 `wr==rd+1`。
- **TX FIFO**：64 深，**只收 `bus_addr_final[15:12]==0x2` 的写**（否则 GPIO/RAM 写会灌入）；`tx_en/tx_data` **组合输出**（`!busy && rd!=wr-1`），时序块只推 rd。
- **tx_busy**：`rd != wr-1`（FIFO 非空）；r255 读回。
- **中断**：`rx_irq = FIFO 非空`（电平）→ 向量由 irq_vex 配置（boot 写 0x260）。ISR 每 `LBU r,0x2000` 弹一字节。

### 2.7 timer（0x3000–0x3FFF，纯写，32 位）

- `SB rs`@0x3000/0x3001/0x3002/0x3003 设重装值字节 0/1/2/3；@0x3004 设 irq 模式（数据值 bit0=0 脉冲 / bit0=1 电平锁存）；@0x3005 ack 清 timer_irq。
- 计数 0→重装值，**全 32 位相等**时 `timer_irq=1` 并清零，**周期 = 重装值 + 1 拍**。例：周期 65536 拍 → 重装值 0x0000FFFF。
- 关闭：重装值全 0 不计数。中断：向量由 irq_vex 配置（boot 写 0x248）。

### 2.8 GPIO（0x4000–0x4FFF，8 位）

- `LBU rd` 读引脚（仅 IN 模式回电平，其余位恒 0）；`SB rs`@偶数地址推挽输出；`SB rs`@奇数地址设单 pin 模式（`addr[3:1]` 选 pin、`data[3:0]` 选模式）。

| 值 | 模式 | 引脚行为 |
|----|------|----------|
| 0000 | UNUSE（默认） | **高阻不驱动** |
| 0001 | OUT | 驱动 `gpio_output` |
| 0010 | IN | 高阻，LBU 可读回 |
| 0011 | IRQ | 高阻，电平式中断 |
| 0101 | TX | 驱动跟随 uart_tx `tx` |
| 0110 | RX | 高阻，电平直送 uart_rx `rx` |

- **方向**：**仅 OUT/TX 驱动，其余全高阻**。
- **中断分组**：pins 1–3 → GPIO1；pins 4–7 → GPIO2。电平式持续触发、无 ack。
- pin0 保留；非 OR：同组多 IRQ pin 同时有效只有最后生效。

### 2.9 中断、向量与嵌套（v3.2.0 向量可配）

| 中断源 | irq_bus[5:3] | 子源 [2:0] | irq_vex 索引 | boot 配置向量 | 优先级 |
|--------|--------------|-----------|--------------|--------------|--------|
| Timer | 001 | 000 | 0 | 0x248 | 3（最高） |
| UART RX（FIFO 非空） | 010 | 000 | 1 | 0x260 | 2 |
| GPIO1（pins 1–3） | 010 | 001 | 2 | 0x208 | 1 |
| GPIO2（pins 4–7） | 010 | 010 | 3 | 0x228 | 0 |
| DMA 完成 | 101 | 000 | 4 | 0x208（防御，prio=0 关） | 0（关） |

- **向量表总线可写（v3.2.0）**：`SB` 0x5000 区，`bus_addr_in[4:2]`=槽位（0-4）、`[1:0]=1` 写高字节 / `=2` 写低字节。**默认 irq_vex**：GPIO2=0x400 / GPIO1=0x420 / TIMER=0x440 / UART=0x450 / DMA=0x470（v3.2.0 新布局）；**boot 必须 SB 写向量指针**覆盖默认（0x400-0x47F 与 task1 冲突）。
- **一次性 lock**：boot 在锁内（0x6000-0x6007 解锁前）写 prio + 向量；解锁后中断才放行。
- **优先级**：`prio = irq_bus[8:6]`，更高优先级可抢占当前 ISR。
- **中断栈 / 嵌套**：irq_controller 内置 8 深返回地址栈 `pc_addr[0:7]` + 栈指针 `j`。
- **软中断 IRQ_W（0x5000）— 写路径**：ISR 活动时，连续 2 条 SB 到 0x5000–0x5FFF 改写栈顶返回地址（`addr[1:0]==0` 走 pc_addr 写、`==1/2` 走向量表写）。之后 IRET 跳改写后的目标。
- **软中断 IRQ_W（0x5000）— 读路径**：`LBU` 0x5000 区读被抢占任务断点。slot = `bus_addr_in[4:1]`，byte = `bus_addr_in[0]`。**slot0 = 0x5000（低 8 位）/ 0x5001（高 4 位）**。

> **中断语义（v2.2 延续）**：

> **① 授权门控（irq_en）**：仅当 `irq_en == 2'b11` 才接受/抢占中断。控制转移（9 条）与 cstall 拆包前半拍强制屏蔽。

> **② 被中断指令写回不丢**：irq_flush 只冲刷取指级，decoder/id_reg/wr_reg 不冲刷。

> **③ IRET W+2 语义 + __jpad 垫层**：派发沿保存 `pc=W+2`，IRET 回 W+2；**每条控制转移之前必须垫 `LBNE r0,r0,__jpadN`**。

> **④ 抢占断点 pc-1**：IRQ 态被更高优先级抢占时保存 `pc-1`（=W+1），内层 IRET 回 W+1。

---

## 3. v2.3 相比 v2.2 的软件侧约定（RTOS 内核）

指令集文档范围之外、但写程序必须遵守的 v2.3 约定（细节见设计日志）：

| 项 | 约定 |
|----|------|
| 寄存器分块 | 任务0 低 r1/r2+高 r17-r21；任务1 低 r3/r4+高 r22-r25；任务2 低 r5/r6+高 r26-r29；调度器 r12-r15 临时；**共享子程序 r7-r11** |
| 抢占调度器 | timer ISR（5kHz）：读 slot0 → 存 PC+j+r7-r11 → CUR=(CUR+1)%3 → 载新任务 → 2×SB 改写 → IRET |
| TCB | 每任务 8 字节：PC_LO/PC_HI/J/R7/R8/R9/R10/R11 |
| 调度器切任务 | `LBU 0x5000`（低）+ `LBU 0x5001`（高）读断点 → 重建 resume_pc → 恢复 r254=j → 2×紧邻 SB 到 0x5000 改写 pc_addr[0] → IRET |
| 汇编器自动修复 | bytmov 死区自动补 NOP、L/R 自动翻转、`\b`/`\xNN` 转义 |

---

*本文档随版本更新；新增外设/指令/中断语义时同步追加对应表格。*
