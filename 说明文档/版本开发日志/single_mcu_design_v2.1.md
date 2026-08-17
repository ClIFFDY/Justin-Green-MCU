# MCU 设计记录（v2.1 —— 中断栈/嵌套 + 软中断 IRQ_W + SBI 指令 + RAM 整机通路）

> 版本：2026-08-17（v2.0 归档后新增特性，仿真验证通过后归档）。
> 在 v2.0（词寻址 32bit 取指 + 压缩指令/自动打包 + cstall 冻结 pc）基础上的**功能升级**，非架构重构：流水线/编码/地址空间骨架不变。
> **指令与外设速查见 `指令集说明/mc_v2.1_ins.md`**；本日志只记设计、时序与调试。
> 核心变化：
> ① **中断栈 + 优先级嵌套**：irq_controller 内置 8 深返回地址栈 `pc_addr[0:7]` + 栈指针 `j`，`prio=irq_addr_in[5:3]`，高优先级可抢占低优先级 ISR，IRET 逐层恢复；
> ② **软中断 IRQ_W(0x5000)**：ISR 内 2 条连续 SB 改写栈顶返回地址（OPR 状态），IRET 落自定义目标；
> ③ **优先级编码重排**：timer=001(1) < uart=010(2) = gpio=010(2)（v2.0 为 timer=010/uart=001）；
> ④ **SBI 指令**（opcode 0x1E，byte0=0x78）：`SBI imm8, addr16` 立即数存储，asm.py 新增格式；
> ⑤ **ISR 向量迁移**：GPIO2=0x88→0x208 / GPIO1=0xA8→0x228 / TIMER=0xC8→0x248 / UART=0xE0→0x260（配合上板程序新布局）；
> ⑥ **ins_rom stall 修复**：RAM 访问（stall_bus）期间冻结取指，不再重读 mem[pc] 导致丢指令（本版关键调试）；
> ⑦ **RAM 4 分片读写整机验证**：SB/LBU + SBI 全通，首次覆盖 CPU↔RAM stall_bus 整机路径。

## 0. 版本说明

| 维度 | MCU v2.0 | MCU v2.1（当前） |
|------|----------|------------------|
| 取指/流水线 | 词寻址 32bit + ins_rom→if_reg→decoder | **相同**（骨架未动） |
| 压缩/打包/cstall | flag 压缩 + 自动打包 + cstall 冻结 pc | **相同** |
| 中断 | 三态机 IDLE/IRQ/BACK，**不可重入**，单断点 | **8 深返回地址栈 + 优先级嵌套**（可抢占），4 态 IDLE/IRQ/OPR/BACK |
| 中断优先级 | GPIO > UART > Timer | **UART = GPIO > Timer**（编码 timer=1 < uart=2 = gpio=2，`[5:3]` 比较） |
| ISR 向量 | 0x88/0xA8/0xC8/0xE0 | **0x208/0x228/0x248/0x260**（整体迁移，配合新程序布局） |
| 软中断 | 无 | **IRQ_W(0x5000)**：2 条连续 SB 改写 ISR 返回地址 |
| 指令集 | 31 真实 + 1 伪（MOV→ADDI） | **32 真实 + 1 伪（+SBI）** |
| RAM 通路 | 已知限制：整机未访 RAM | **SB/LBU/SBI 4 分片整机读写验证通过** |
| 取指 stall | 无（RAM stall 期间重读 mem[pc] 丢指令） | **ins_rom 新增 stall 输入，冻结取指** |

## 1. 中断栈与优先级嵌套（irq_controller.v 重写）

### 1.1 设计

- **8 深返回地址栈**：`reg [11:0] pc_addr [0:7]` + 4 位栈指针 `j`；`reg [2:0] prio` 记当前 ISR 优先级。
- **状态机扩展为 4 态**：`IDLE / IRQ / OPR / BACK`（v2.0 为 IDLE/IRQ/BACK）。
- **接受中断**（IDLE，或 IRQ 且 `irq_addr_in != 0 && bytmov == 0 && irq_addr_in[5:3] > prio && j <= 15`）：
  `prio <= irq_addr_in[5:3]; pc_addr[j] <= pc_addr_in; j <= j + 1; irq_addr <= irq_vex[irq_addr_in[5:3]+irq_addr_in[2:0]-1]; irq_flush <= 1'b1;`
- **IRET**（IRQ 态）：`j >= 1` 时 `j--; irq_addr <= pc_addr[j-1]`，stage→BACK；BACK 中 `j==0 → IDLE`，否则回 IRQ 继续跑外层 ISR——**嵌套逐层恢复**。
- **优先级**：`prio = irq_addr_in[5:3]`，单源 irq_bus 编码见 single_mcu_top（§3）。**仅高者抢占**：timer(1) 可被 uart/gpio(2) 抢占；uart 与 gpio 同级(2) 互不抢占。

### 1.2 验证（probe_nest_tb + nest_test.asm）

- **nest_test**：timer ISR（prio 1）延时循环（内层 255 × 外层 16 拍窗口）中，TB 注入 UART 收字节（prio 2）→ 抢占进入 uart ISR。
- 通过判据：timer 进入标记 r3=0x01 ✓、嵌套 uart ISR 执行标记 r4=0x5A ✓、内层 IRET 恢复 timer ISR 尾部 r5=0x03 ✓、外层 IRET 回主循环（guard 未命中 r5≠0xEE）✓。**5/0 全过**。

## 2. 软中断 IRQ_W（0x5000，OPR 状态）

- **动机**：让 ISR 能自定义返回目标（任务切换 / 跳板）。
- **机制**（IRQ 态内，`bus_sig_in && bus_addr_in == IRQ_W`）：
  - 第 1 条 SB：`pc_addr[0][11:8] <= data[3:0]`，stage→**OPR**；
  - OPR 态第 2 条 SB：`pc_addr[0][7:0] <= data`，stage→IRQ；
  - 之后 IRET 恢复的是**改写后的 pc_addr[0]**，而非原断点。
- **验证（probe_swirq_tb + swirq_test.asm）**：timer ISR 内 `SB r1,IRQ_W`（高 4 位 0x0）+ `SB r2,IRQ_W`（低 8 位 0x20）→ IRET 落到 sw_land=0x020（r2=0xAA 落点标记）而不是主循环断点。**2/0 全过**。

## 3. 优先级编码重排（single_mcu_top.v）

- irq_bus 编码对调（v2.0：timer=010、uart=001 → v2.1：timer=001、uart=010）：

| 源 | v2.0 irq_bus[5:3] | v2.1 irq_bus[5:3] | irq_bus 低 3 位 |
|----|-------------------|-------------------|-----------------|
| Timer | 010 | **001(1)** | 000 |
| UART RX | 001 | **010(2)** | 000 |
| GPIO1 | 010 | **010(2)** | 001 |
| GPIO2 | 010 | **010(2)** | 010 |

- irq_vex 索引 = `[5:3] + [2:0] − 1`：TIMER→0、UART→1、GPIO1→2、GPIO2→3，对应 `irq_vex[0..3]`（584/608/552/520）。
- 优先级即 `[5:3]`：**UART(2) = GPIO(2) > Timer(1)**；嵌套比较 `[5:3] > prio`。

## 4. ISR 向量迁移（配合上板程序新布局）

- irq_vex 整体上移，空出 ROM 前段给增长的主程序：

| 源 | v2.0 向量 | v2.1 向量 | 十进制 | 上板程序 .org |
|----|----------|----------|--------|---------------|
| GPIO2 | 0x88 | **0x208** | 520 | `.org 0x208` |
| GPIO1 | 0xA8 | **0x228** | 552 | `.org 0x228` |
| Timer | 0xC8 | **0x248** | 584 | `.org 0x248` |
| UART | 0xE0 | **0x260** | 608 | `.org 0x260` |

- `irq_vex[4..15] = 168` 兜底沿用（正常源索引恒 <4，兜底为防御）。
- 上板程序 board_test.asm 的 ISR 段 `.org 0x208/0x228/0x248/0x260` 与向量表一致。

## 5. SBI 指令（decoder.v + asm.py）

- **opcode 0x1E，byte0=0x78**（v2.0 释放未用，现分配给 SBI）。
- **编码** `SBI imm8, addr16`：byte1=立即数（`inst_raw[23:16]`）、byte2:3=16 位地址（`inst_raw[15:0]`），与 SB 布局一致、仅数据源由寄存器改为立即数。
- **decoder.v**：`SBI: begin bus_data_out = inst_raw[23:16]; bus_addr_out = inst_raw[15:0]; bus_sig_out[0] = 1'b1; end`——直通立即数字节上写数据总线（早期版本曾误读寄存器号 `addr_dr12[23:16]` 导致写 0，用户修复为直通）。
- **asm.py**：`SBI: ('sbi', 4)` + `operand_n=2` + 立即数/地址越界检查（imm 0-255、addr 0-0xFFFF）。
- **验证**：`SBI 0x11, 0x8004 → 0x78118004`，4 分片写后 LBU 读回全对（见 §6）。

## 6. ins_rom stall 修复 + RAM 整机通路（本版关键调试，2026-08-17）

### 6.1 现象：RAM 访问丢指令

- 首个 RAM 测试（SB 0x8000 后 LBU 读回）只写入 1 次就挂死；逐拍 trace 显示 decoder 从 SB 直接跳到 RBNE，**中间的 LBU 指令被跳过**，RBNE 在错误 pc 执行跳错。

### 6.2 根因：RAM stall 期间 ins_rom 重读 mem[pc] 覆盖在飞取指

- RAM 访问 2 拍（`stall_bus = access && !done`），stall 期间 pc 被冻结（pc.v/if_reg/id_reg/wr_reg 都受 stall_bus 挂起），**但 ins_rom 没有 stall 输入**——每拍仍 `inst_raw <= mem[addr]`，把 stall 前一拍已取出的、流水线在途的下一条指令覆盖掉；stall 解除后 if_reg 抓到的是重读后的错误词（偏离 1 拍），后续指令链整体错位。

### 6.3 修复（用户改 ins_rom.v + single_cpu_top.v）

- `ins_rom.v` 新增 `stall` 输入，`else if (stall) inst_raw <= inst_raw;`（stall 期间保持输出）；
- `single_cpu_top.v` 接线 `.stall(stall_bus)`。
- 效果：RAM 访问整机通路首次可用——SB/LBU/SBI 不再丢指令。

### 6.4 验证（probe_ram_tb + ram_test.asm）

- **ram_test.asm**：4 分片各 `ADDI r1,r0,imm → SB r1,addr`（AA/BB/CC/DD）+ `LBU r2,addr → RBNE r2,r1,fail`；再接 4 条 `SBI imm,addr+4`（11/22/33/44）+ LBU 读回比对。
- **结果（probe_ram_tb）**：总线写命中 **8/8**（4×SB + 4×SBI），r5=0x01（PASS），`ram_sec_1..4` 的 `mem[0]`/`mem[4]` 逐字节落位（AA/BB/CC/DD + 11/22/33/44）。**首次覆盖 CPU↔RAM stall_bus 整机路径**。

## 7. 仿真验证（2026-08-17）

### 7.1 整机回归（board_test_tb.v，iverilog）

- **结果：20 通过 / 0 失败，ALL TESTS PASSED**。
- 覆盖 Phase1 banner + Phase2 回环 + Phase3 回环关 + Phase4 回环开 + Phase5 LED（中断栈改动后回归通过）。

### 7.2 专项 TB（sim_1/new）

| TB / 程序 | 验证点 | 结果 |
|-----------|--------|------|
| probe_nest_tb / nest_test.asm | 中断栈嵌套：timer(prio1) 被 uart(prio2) 抢占、内层 IRET 恢复外层、外层 IRET 回主循环 | ✅ 5/0 |
| probe_swirq_tb / swirq_test.asm | 软中断 IRQ_W：2 条连续 SB 改写返回地址 → IRET 落自定义目标 | ✅ 2/0 |
| probe_ram_tb / ram_test.asm | RAM 4 分片 SB/LBU 读写 + SBI 立即数存储（含 ins_rom stall 修复验证） | ✅ 8/8 |

### 7.3 回归注意

- iverilog 文件表沿用 v2.0（core 10 文件 + mcu + peripherals，含 if_reg.v）；新增仅 asm.py 的 SBI 格式。
- 外设 gpio_group/timer/uart_*/ram_* **未动**；core 变更为 decoder/ins_rom/single_cpu_top/irq_controller。

## 8. 已知限制 / 后续

| 项 | 说明 |
|----|------|
| bytmov=0 目标不可编码 | `target=W+2` 时无可编码偏移（pc.v 判 0 为不跳）；向前最少 2 词 |
| 压缩字段上限 | ALU 压缩需 rd≤3、r1/r2≤7（imm≤7），超限自动退回原长 |
| 分支寄存器 r0–r15 | 6 条条件分支仅 4 位寄存器号 |
| 打包目标约束 | 跳转/分支目标必须词首指令 |
| 中断栈深度 | pc_addr 数组 8 深，但嵌套门限 `j ≤ 15` 放宽——超 8 深写越界（防御性收敛，当前程序远用不到） |
| irq_vex 兜底 | `irq_vex[4..15]=168` 沿用 v2.0 旧值（正常源索引恒 <4，仅防御；如扩源需同步更新） |
| RAM 连续多访 | RAM 每次访问 2 拍 stall；连续读写场景（如块拷贝）性能与正确性未专项压测 |
| 上板板测 | v2.1 仿真全过；**上板待用户实测**（中断栈/SBI/RAM 通路） |

---

*本文件随项目演进同步更新。*
