# MCU 设计记录（v2.0 —— 词寻址 32bit 取指 + 压缩指令/自动打包 + cstall 冻结 pc）

> 版本：2026-08-17（上板板测通过后归档）。
> MCU 系列第 6 版（v1.2/v1.3/v1.4 见 `single_mcu_design_v1.2/1.3/1.4.md`；开发期曾称「v1.5」，**归档定版为 v2.0**）。
> **指令与外设速查见 `指令集说明/mc_v2.0_ins.md`**；本日志只记设计、时序与调试。
> 核心变化（**架构级重构**）：
> ① **词寻址 32bit 定长取指**：PC 12 位词地址，ROM 4096 词×32bit BRAM，流水线 ins_rom→if_reg→decoder；
> ② **压缩指令 + 自动打包**：flag 位、16bit 压缩、2 条/词，汇编器自动；
> ③ **cstall 冻结 pc**：解包两拍共用同一 pc，消灭「幻影 pc」导致的 IRET 重复回显 bug（本版关键调试）；
> ④ **bytmov 8→16 位【词单位】**，跳转/分支覆盖全 0x000–0xFFF 空间，一跳贯通；
> ⑤ **分支寄存器 8→4 位**（r0–r15，byte3={r1,r2}）；
> ⑥ **MOV 为汇编器伪指令**（RTL 不设 MOV opcode：`MOV rd, rs` 由 asm.py 翻译为 `ADDI rd, rs, 0`）；
> ⑦ **中断优先级改 GPIO > UART > Timer**（v1.4 为 GPIO > Timer > UART）；
> ⑧ **ISR 向量由字节地址语义改【词地址】**（数值不变：GPIO2=0x88/GPIO1=0xA8/TIMER=0xC8/UART=0xE0）；
> ⑨ **外设与地址空间与 v1.4 完全相同**（未动）；CPU 核新增 if_reg.v。

## 0. 版本说明

| 维度 | MCU v1.4（旧） | MCU v2.0（当前） |
|------|----------------|------------------|
| 取指 | 字节地址，ROM 0x000–0x1FF（512B，8bit×512） | **词寻址，ROM 0x000–0xFFF（4096 词×32bit BRAM）** |
| PC | 12 位字节地址 | **12 位【词】地址** |
| 流水线 | pc → ins_rom(1级) → decoder | **pc → ins_rom(1级) → if_reg(1级,解包) → decoder** |
| 指令编码 | byte0=opcode[7:0]，无 flag | **byte0=opcode[5:0]<<2\|flag[1:0]，flag 标识压缩/原长** |
| 指令宽度 | 全部 1–4 字节 | **原长独占 1 词；可压指令 16bit，2 条/词** |
| bytmov | 8 位字节单位，基准 W+2，±255B 需链条 | **16 位【词单位】，基准 W+2，±0xFFFF 全空间一跳贯通** |
| 分支寄存器 | 8 位（byte2/byte3 各 1） | **4 位（byte3={r1[3:0],r2[3:0]}，r0–r15）** |
| 指令条数 | 30 条 | **31 条（MOV 为汇编器伪指令 → ADDI rd,rs,0，RTL 不设 opcode；NOP/IRET 新增 flag=01 压缩）** |
| 中断优先级 | GPIO > Timer > UART | **GPIO > UART > Timer**（rx 优先 timer） |
| ISR 向量 | 字节地址 0x88/0xA8/0xC8/0xE0 | **词地址 0x88/0xA8/0xC8/0xE0（数值不变，语义变）** |
| 地址空间/外设 | UART=0x2000/TIMER=0x3000/GPIO=0x4000/RAM=0x8000–0xBFFF | **与 v1.4 完全相同（未动）** |
| 编码来源 | 手写/查表 | **asm.py 自动压缩+自动打包+算 bytmov** |

## 1. 词寻址 32bit 定长取指（架构级重构）

- **PC 12 位词地址** 0x000–0xFFF（4096 词）；`ins_rom.v`：`(* ram_style="block" *) reg [31:0] mem [0:4095]`，$readmemh 载入，`inst_raw <= mem[addr]` 1 级。
- **流水线**：`pc → ins_rom(inst_raw_zip) → if_reg(inst_raw + cstall) → decoder`。取指延迟 2 拍：**指令在词 W 执行时 `pc_addr = W+2`**——bytmov、ra 保存、分支判等全部以 W+2 为基准（见 §4）。
- **词内字节序**：`byte0` 在**高位**（bits[31:24]）；`byte0 = opcode[5:0]<<2 | flag[1:0]`。解码后 opcode 仍在 [31:26]。
- **hex 格式**：8 位十六进制词/行（byte0 高位），未用词填 `0x00000000`（=HALT 原长），`@0000` 起始，$readmemh 载入。

## 2. 压缩指令与自动打包（asm.py）

- **flag 分配**（byte0 低 2 位）：
  - `00` 原长：独占 1 词（不足 4 字节补 0）。
  - `11` ALU 类压缩 16bit：`[opcode<<2|3, {rd[1:0], r1[2:0], r2[2:0]}]`（I 型末字段=imm[2:0]）。
  - `01` 无操作数压缩 16bit：`[opcode<<2|1, 0x00]`——仅 NOP/IRET。
- **自动压缩规则**：ALU-R/I 满足 `rd≤3、r1/r2≤7`（I 型 `imm≤7`）→ flag=11；NOP/IRET → flag=01；其余（跳转/分支/访存/HALT）恒原长。
- **自动打包**：相邻两条压缩指令共享 1 个 32bit 词（前=[31:16]、后=[15:0]）。约束：
  - **跳转/分支目标必须落在词首指令**（汇编器布局保证）；
  - 独个可压缩指令退回原长——保证打包词两半都非空，if_reg 的 cstall 拆包才正确。
- **解包（if_reg.v）**：
  - `cstall`（组合）：`inst_raw_in[25:24] != 2'b0 && inst_raw_in[9:8] != 2'b0 && !cstalled` → 两半都压缩，冻结 pc 一拍。
  - 打包展开：`if (inst_raw_in[25])`（上半）`inst_raw = {inst_raw_in[31:24], 6'b0, inst_raw_in[23:22], 5'b0, inst_raw_in[21:19], 5'b0, inst_raw_in[18:16]}`（高位 → 下半个 → `inst_raw_l`）。
  - 效果：解包后 32bit 指令 opcode 仍在 [31:26]，rd→byte1 低 2 位、r1→byte2 低 3 位、r2/imm→byte3 低 3 位——**decoder 无需感知压缩**，只需原本的 opcode/rd/r1/r2/bytmov 解码。

## 3. **cstall 冻结 pc —— 消灭「幻影 pc」（本版关键调试，2026-08-17）**

### 3.1 现象：timer IRQ 后 IRET 重复回显

- echo 通路回显字节正确（0x61）；但 **timer IRQ 触发后出现重复回显**。~1311µs timer IRQ 落在主循环打包对 `mem[0x026]=[NOP|NOP]` 的第二个 NOP 上：该处 pc_addr=0x029（bytmov=0，是合法授权点），irq_controller 保存 pc=0x029；IRET 恢复 pc=0x029 时 ROM 直接取 `mem[0x029]=send_char(ADDI r6)` → 重发 0x61。

### 3.2 根因：打包对第二半的 pc=W+3 是「幻影」

- 打包对两半共用 ROM 词 **W**：正常顺序执行时，第一半 pc=W+1、第二半 pc=W+2（**非 W 的幻影 pc**），取指被 if_reg 的 cstall 丢弃——与 ROM 词**非一一对应**。
- 但 IRQ 授权恰落在第二半（pc=W+2=0x029）时，irq_controller 存下这个幻影 pc；IRET 恢复 pc=0x029 → `mem[0x029]` 是**另一条无关词**（send_char）→ 复活执行 → 重复回显。
- **本质**：pc 与 ROM 词地址不再一一对应（一 ROM 词 = 一/二条指令），凡「存 pc → 恢复跳回」的路径（IRQ/IRET）都会被幻影 pc 击中。

### 3.3 修复（用户改 pc.v）：cstall 冻结 pc

- `pc.v` 各 case 分支内的顺序 `pc+1` 路径全部加 `if(!frz && !cstall) pc_addr <= pc_addr + 1;`——**cstall=1 时冻结 pc**。
- if_reg 检测打包对（两半 flag 均≠00）→ cstall=1 → pc 不动，打包对两半用 `cstalled` 状态**分两拍输出**（共享同一 pc）。
- 效果：**打包对两半共用同一 pc，幻影 pc 消灭**；IRQ 授权点保存的 pc 是真实 ROM 词地址（0x026/0x027/0x028），IRET 恢复回到真实词、ROM 词一一对应。

### 3.4 验证（四探针，均通过）

1. **probe2**：banner 11/11 全过（含 '\n' 不再卡死）。
2. **probe_edge**：`== 全程盯完，共 1 个 busy 边沿 ==`——重复回显消失（修改前 2 个）。
3. **probe_wave**：uart_tx 内部分位中点采样，echo 线上 = 0x61（probe2 读 0xd8 是探针伪迹闭环）。
4. **probe_iret4**（新）：3 次 timer IRQ 全部接受，保存 pc 依次 **0x026/0x027/0x028**（全在主循环安全区，非 send_char 0x029），r4 递减/LED 翻转（ISR 主体执行），IRET 恢复后主循环继续——**LED 闪烁功能未丢**。

### 3.5 附：当前主循环布局（词寻址，供排错对照）

```
mem[0x26] = 0x51005100   [NOP|NOP] 打包对（授权点，bytmov=0）
mem[0x27] = 0x58000300   LBEQ#1  bm=3（回跳）
mem[0x28] = 0x58000400   LBEQ#2  bm=4（IRET 落点）
mem[0x29] = 0x0406FF00   send_char（ADDI r6,r255,0）
```

## 4. bytmov 16 位【词单位】（跳转/分支覆盖全空间）

- **bytmov = 16 位，词单位，基准 W+2**（指令在词 W 执行时的 pc 值）：
  - R 前缀（向前）：`bytmov = target − (W+2)`；
  - L 前缀（向后）：`bytmov = (W+2) − target`。
- **覆盖极限**：±0xFFFF 词 > 4096 词全 ROM → **一跳贯通，不再需要 v1.4 的链条跳转**。
- **编码限制**：`target = W+2` 时 `bytmov = 0`，pc.v 判 0 为不跳 → 该目标不可编码；向前最近目标 W+3（bytmov=1）、向后最近 W+1。汇编器自动算，越界/目标非词首报错。
- **解码**：`decoder.v` `bytmov = inst_raw[23:8]`；分支 r1/r2 4 位 `inst_raw[7:4]/[3:0]`，`addr_dr12 = {4'b0,r1,4'b0,r2}`。
- **分支寄存器 4 位**：byte3 = `r1[3:0]<<4 | r2[3:0]`，可用 r0–r15；超 0x0F 汇编器报错。
- **pc.v 保存 ra**：LJAL/RJAL `ra <= pc_addr − 1`（返回 W+1）。

## 5. 指令集与中断

- **MOV = 汇编器伪指令**（RTL 放弃独立 MOV opcode）：`MOV rd, rs` 复制，asm.py 翻译为 `ADDI rd, rs, 0`（`rd = rs + 0 = rs`，语义等价）。自动继承 ADDI 压缩：rd≤3 且 rs≤7 时压成 16bit，否则原长 4 字节。**opcode 0x1E 未分配**（decoder/alu 不含 MOV，hex 永不出现 MOV 编码）。上板程序用 `ADDI r6, r255, 0` 拷 tx_busy 不受影响。
- **NOP/IRET 新增 flag=01 压缩**：NOP 亦用于 if_reg 冲刷时自动插入。
- **优先级改 GPIO > UART > Timer**（single_mcu_top.v）：`if(timer_irq) irq_bus=010; if(rx_irq) irq_bus=001; if(gpio_irq!=0) irq_bus={010_0,gpio_irq};`——rx 后判覆盖 timer，gpio 最后判覆盖全部。该改动与幻影 pc bug 无关（用户改，保留）。
- **IRQ 授权门控**：`irq_addr_in != 0 && bytmov == 0`（仅干净指令边界）才响应；grant 保存断点 pc_addr、跳向量、冲刷流水线；irq_flush 仅接受/恢复瞬间各 1 拍；不可重入（三态机 IDLE/IRQ/BACK）。
- **向量 = 词地址**：irq_vex UART=224(0xE0)/TIMER=200(0xC8)/GPIO1=168(0xA8)/GPIO2=136(0x88)，`irq_vex[4..15]=168` 兜底（沿用 v1.4 修复）。上板程序 `.org 0x88/0xA8/0xC8/0xE0` 对应。

## 6. 仿真验证（2026-08-17）

### 6.1 整机回归（board_test_tb.v，iverilog）

- **结果：20 通过 / 0 失败，ALL TESTS PASSED**（~1.87ms 自然结束）。
- 覆盖 Phase1 banner 11 字节 + Phase2 回环 + Phase3 回环关 + Phase4 回环开 + Phase5 LED。

### 6.2 专项探针 TB（sim_1/new）

| TB | 验证点 | 结果 |
|----|--------|------|
| probe_iret4_tb | timer IRQ 接受/ISR 主体/IRET 恢复点安全（保存 pc 0x026/0x027/0x028） | ✅ 3/3 |
| probe_edge_tb | busy 边沿数 =1（重复回显消失） | ✅ |
| probe_wave_tb | uart_tx 内部分位中点采样 echo=0x61 | ✅ |
| probe_iret2/3_tb | IRET 恢复主循环、主循环 trace | ✅ |
| probe_cstall_tb | cstall 冻结/打包对与跳转交互 | ✅ |

### 6.3 回归注意

- iverilog 文件表需补 `if_reg.v`；`pc.v`/`decoder.v`/`reg_f.v`/`ins_rom.v`/`single_cpu_top.v`/`single_mcu_top.v`/`alu.v`/`irq_controller.v` 均为 v2.0 版（10 文件）。
- 外设 gpio_group/timer/uart_*/ram_* **未动**。

## 7. 上板板测（2026-08-17）

- 用户上板确认：**结果令人满意**（banner、回环、LED 闪烁、timer 中断路径均正常，重复回显消失）。
- 板测通过后按用户指示：补文档（本日志 + mc_v2.0_ins.md）→ resv 重命名 v2.0 → 归档（镜像同步 + 快照刷新 + 字节校验）。

## 8. 已知限制 / 后续

| 项 | 说明 |
|----|------|
| bytmov=0 目标不可编码 | `target=W+2` 时无可编码偏移（pc.v 判 0 为不跳）；汇编器会报错，需就近跳。向前最少 2 词 |
| 压缩字段上限 | ALU 压缩需 rd≤3、r1/r2≤7（imm≤7），超限自动退回原长（对汇编器透明，仅浪费 1 词） |
| 分支寄存器 r0–r15 | 6 条条件分支仅 4 位寄存器号；汇编器超界报错 |
| 打包目标约束 | 跳转/分支目标必须词首指令；汇编器保证，手写 hex 时注意 |
| 中断不可重入 | 沿用 v1.4（irq_controller 三态机） |
| CPU↔RAM 整机交互 | 沿用 v1.4 未覆盖项：board_test 不访 RAM；建议后续程序加 RAM 读写段 |

---

*本文件随项目演进同步更新。*
