# 多周期 CPU 设计记录（v5.0 —— 指令编码重构：opcode 低 2 位声明长度 + 无填充 + 4 状态 FSM）

> 版本：2026-08-11  ·  在 v4.2 基础上重构指令编码与状态机（编码方案、FSM 状态数、PC 步进时机均有改动）
> v4.2 见 [single_cpu_design_v4.2.md](single_cpu_design_v4.2.md)，v4.1 见 [single_cpu_design_v4.1.md](single_cpu_design_v4.1.md)

## 0. 版本说明

沿用 v3.0 第 0 节定下的标准——架构变则大版本。本次改动触及指令编码的**根本方案**：

| 维度 | v4.2 | v5.0（当前代码） |
|------|------|------------------|
| 指令编码 | 逐字节 tag（每字节 `[1:0]` 标类型，opcode/操作数分装到多个字节） | **只 opcode 字节低 2 位声明长度**，其余字节为纯数据、无 tag、无填充 |
| 指令长度 | HALT 2B / JAL·JALR 3B / ALU 4B | **HALT 1B / JAL·JALR 2B / ALU 4B**（3B 编码保留未用） |
| FSM | 3 状态 IDLE→FET→NEX | **4 状态 IDLE→IF→OPR→WRT**（IF/OPR/WRT 各司一职） |
| PC 步进时机 | NEX 拍 | **WRT 拍**（`pc + len + 1`，跳转落地拍不步进） |
| 返回栈 | rad[0:15]，栈指针 4-bit | **rad[0:63]，栈指针 j[6:0]** |
| 控制流 | LJAL/RJAL/JALR | LJAL/RJAL/JALR（语义不变，长度改为 2B） |

编码方案是 ISA 的根，这次等于重画了指令格式；加上 FSM 与 PC 步进机制同步重做，
按"架构变则大版本"记 **v5.0**。

## 1. 总体架构

```
clk/rst
   │
   ├─▶ fsm ──── stage[2:0]（IDLE/IF/OPR/WRT）广播到 pc / ir / wreg
   ├─▶ pc ──▶ ins_rom ─▶ inst_raw(4B 窗口) ─▶ decoder（组合译码）──▶ ir（OPR 拍锁存）
   │   │      ▲  inst_num = byte0[1:0]           │
   │   │      └──────── pc_addr ───────────────┘  │ addr1/addr2/rd/opcode/imm/we/bytmov/frz
   │   │ jmpwe / jmpred / ra                       ▼
   │   └──◀────── reg_f.ra（组合栈顶）        alu（组合运算）
   │                     ▲                          │
   │                 reg_f ◀── rd_data/rd/we ── wreg（WRT 拍锁存 ALU 结果）
   │                 （写回 + 返回地址栈）
   └─ reg_f 内返回栈 rad[0:63]：jmpwe 入栈（WRT 拍）、jmpred 出栈（IF 拍）
```

一条指令流程：**IF 拍取指 → OPR 拍 ir 锁存译码字段、JAL 在此跳转 → WRT 拍 wreg 锁存
ALU 结果、普通指令在此步进 PC、JALR 在此返回 → 下一拍 reg_f 写回**。

两级写回路径（ir 是执行级寄存器、wreg 是写回级寄存器），跳转与写回互不冲突。

## 2. FSM（4 状态 + frz 冻结）

```
IDLE(000) → IF(001) → OPR(011) → WRT(100) → IF → …
    ↑
    └──────── HALT 时 frz=1，OPR 拍回 IDLE 并关写（we=0）────────
```

| 状态 | 编码 | 动作 |
|------|------|------|
| IDLE | 000 | `!frz` 时进 IF（HALT 后停在这里） |
| IF   | 001 | 取指：ins_rom 按 pc 输出 inst_raw/inst_num |
| OPR  | 011 | ir 锁存译码结果；pc 执行 LJAL/RJAL 跳转；ALU 组合运算；遇 frz → 回 IDLE |
| WRT  | 100 | wreg 锁存 ALU 结果；pc 依指令步进/返回 |

FSM 是**全局单状态机**，四条指令间没有重叠（多周期串行）。

## 3. 指令集（6-bit opcode，20 条）

| 编码 | 助记符 | 行为 | 归属 | 长度 |
|------|--------|------|------|------|
| 00_0000 | HALT | 冻结整机（frz=1） | 控制 | 1B |
| 00_0001 | ADDI | rd = rs1 + imm8 | ALU-I | 4B |
| 00_0010 | ADD  | rd = rs1 + rs2 | ALU-R | 4B |
| 00_0011 | SUBI | rd = rs1 − imm8 | ALU-I | 4B |
| 00_0100 | SUB  | rd = rs1 − rs2 | ALU-R | 4B |
| 00_0101 | AND  | rd = rs1 & rs2 | ALU-R | 4B |
| 00_0110 | OR   | rd = rs1 \| rs2 | ALU-R | 4B |
| 00_0111 | XOR  | rd = rs1 ^ rs2 | ALU-R | 4B |
| 00_1000 | LJAL | 后向跳转（pc − bytmov）且入栈返回地址 | 控制流 | 2B |
| 00_1001 | RJAL | 前向跳转（pc + bytmov）且入栈返回地址 | 控制流 | 2B |
| 00_1010 | ANDI | rd = rs1 & imm8 | ALU-I | 4B |
| 00_1011 | ORI  | rd = rs1 \| imm8 | ALU-I | 4B |
| 00_1100 | XORI | rd = rs1 ^ imm8 | ALU-I | 4B |
| 00_1101 | SLL  | rd = rs1 << rs2 | ALU-R | 4B |
| 00_1110 | SRL  | rd = rs1 >> rs2 | ALU-R | 4B |
| 00_1111 | SLLI | rd = rs1 << imm8 | ALU-I | 4B |
| 01_0000 | SRLI | rd = rs1 >> imm8 | ALU-I | 4B |
| 01_0001 | SLTU | rd = (rs1 < rs2) ? 1 : 0 | ALU-R | 4B |
| 01_0010 | SLTIU | rd = (rs1 < imm8) ? 1 : 0 | ALU-I | 4B |
| 01_0011 | JALR | rd = 无；pc ← 返回栈栈顶（出栈） | 控制流 | 2B |

- 编码 00_0000–01_0011 连续无空位；寄存器 8-bit 地址 → 256 个，r0 恒读 0、写入跳过
- 跳转三指令语义不变：**LJAL/RJAL = 跳转 + 入栈**（保存返回地址），**JALR = 出栈返回**，
  构成"调用/返回"（call/ret），可嵌套
- 方向由 opcode[0] 决定：LJAL（`00_1000`，bit0=0）减，RJAL（`00_1001`，bit0=1）加

## 4. 指令编码（详细）

### 4.1 长度字段：opcode 字节低 2 位

**只有 opcode 字节带长度位**，其余字节是整字节操作数——没有 tag、没有 flag、没有填充字节。
`len[1:0]` 与字节数的关系：

```
       字节数 = len + 1          （2-bit 装不下 4 字节 ALU，故存"字节数 − 1"）
```

| len[1:0] | 字节数 | 用途 |
|----------|--------|------|
| 00 | 1B | HALT |
| 01 | 2B | LJAL / RJAL / JALR |
| 10 | 3B | （保留，暂无指令使用） |
| 11 | 4B | 全部 ALU（R 型和立即数型） |

PC 步进量 = `len + 1` = 当前指令字节数。JAL 的"返回地址" = `pc + len + 1`（跳过本指令后
的下一条），同时作为跳转基准。

### 4.2 各类型字节布局

```
HALT（1B）：
  byte0  = opcode[5:0] | len=00

JAL 类（2B）：
  byte0  = opcode[5:0] | len=01
  byte1  = bytmov[7:0]          偏移（纯数据，无 tag）

ALU-R（4B）：
  byte0  = opcode[5:0] | len=11
  byte1  = rd                  目标寄存器
  byte2  = addr1               源寄存器 rs1
  byte3  = addr2               源寄存器 rs2

ALU-I（4B）：
  byte0  = opcode[5:0] | len=11
  byte1  = rd
  byte2  = addr1               源寄存器 rs1
  byte3  = imm8                立即数
```

JALR 虽为 2B，但 byte1 是**预留操作数槽**（JALR 不使用操作数），留 0 即可。

### 4.3 取指窗口 inst_raw 与字段提取

ins_rom 以 pc 为地址，**一次打出 4 字节窗口**：

```verilog
assign inst_raw = {mem[addr], mem[addr+1], mem[addr+2], mem[addr+3]};
assign inst_num = mem[addr][1:0];   // = byte0 低 2 位 = len
```

短指令（1B/2B）会连同后续指令字节一起打进窗口，decoder 只取自己需要的位，多余字节不影响译码：

| 字段 | 位 | 对应字节 |
|------|----|----------|
| opcode | inst_raw[31:26] | byte0[7:2] |
| len（inst_num） | inst_raw[25:24] | byte0[1:0] |
| bytmov（JAL） | inst_raw[23:16] | byte1 |
| rd（ALU） | inst_raw[23:16] | byte1 |
| addr1（ALU） | inst_raw[15:8] | byte2 |
| addr2（ALU-R） | inst_raw[7:1] | byte3[7:1]（**bit0 被丢弃，见 §9 已知限制**） |
| imm8（ALU-I） | inst_raw[7:0] | byte3 |

### 4.4 编码示例（ins_rom.v 当前程序）

**RJAL → 32**（主程序首条，2B）：

```
byte0  001001_01     opcode=00_1001(RJAL)  len=01 → 2 字节
byte1  00011110      bytmov = 30
```

推导：pc_after = pc + len + 1 = 0 + 2 = 2；bytmov = 目标 − pc_after = 32 − 2 = **30**。

**ADDI r1 = r1 + 1**（4B）：

```
byte0  000001_11     opcode=00_0001(ADDI)  len=11 → 4 字节
byte1  00000001      rd = 1（r1）
byte2  00000001      addr1 = 1（r1）
byte3  00000001      imm8 = 1
```

**JALR**（sub1 末尾，2B）：

```
byte0  010011_01     opcode=01_0011(JALR)  len=01 → 2 字节
byte1  00000000      预留操作数槽（未使用）
```

## 5. 各模块机制

| 模块 | 职责 | 关键点 |
|------|------|--------|
| fsm | 4 状态 IDLE→IF→OPR→WRT 串行推进 | HALT 置 frz 时 OPR 拍回 IDLE 并关写 |
| pc | 取指地址 + 控制流 | OPR 拍 JAL 跳转（`ra=pc+len+1` 入栈、±bytmov）；WRT 拍 JALR 出栈返回 / 普通指令步进 `pc+len+1` |
| ins_rom | 指令存储器 | 4 字节窗口 `inst_raw`；`inst_num = byte0[1:0]` = len；指令由 tb `$readmemh("ins_rom.hex")` 载入 |
| decoder | 组合译码 | opcode=byte0[7:2]；HALT 置 frz；JAL 取 bytmov；ALU 取 rd/addr1/imm8 |
| ir | OPR 拍锁存译码结果 | 供 WRT 拍 alu/wreg/pc 使用 |
| alu | 组合运算 15 条 | OPR 后结果稳定，供 wreg 锁存 |
| wreg | 写回级寄存器 | WRT 拍锁存 result/rd/we，非 WRT 清零 |
| reg_f | 寄存器组 + 返回栈 | `we` 写 regs；`jmpwe` 入栈、`jmpred` 出栈；`ra=rad[j-1]` 组合栈顶 |

关键时序（写回两拍级）：

- **入栈**：jmpwe 在 OPR 拍置位 → 下一拍（WRT）reg_f 入栈；WRT 拍即清零，每个 JAL 只压一次
- **出栈**：jmpred 在 WRT 拍置位 → 下一拍（IF）reg_f 出栈
- **写回**：WRT 拍 wreg 锁存 ALU 结果 → 下一拍 reg_f 写 `regs[rd]`
- **PC 步进**：普通指令在 WRT 拍 `pc+len+1`；JAL 落地拍因 `!jmpwe` 不步进，落地指令保留完整周期

## 6. 当前程序（ins_rom.v，两层嵌套调用/返回测试）

```
主程序  mem[0..1]   RJAL → 32         入栈{2}，跳过 mem[2..13]
        mem[2..13]  ADDI r1/r2/r3     （返回后执行）
        mem[14]     HALT
sub1    mem[32..35] ADDI r4
        mem[36..37] RJAL → 48        入栈{38}
        mem[38..39] JALR             出栈{38} → 返 38（回到 sub1 剩余代码）
sub2    mem[48..51] ADDI r5
        mem[52..53] JALR             出栈{2} → 返 2（回主程序）
```

目的：验证返回栈 **LIFO 顺序**——sub2 最后入栈、最先出栈（返 38），sub1 后出栈（返 2）。
2B 指令自然紧凑排列，无填充字节；返回地址 `pc + len + 1` 也随编码变为 +2。

## 7. 仿真验证

| 时刻 | 事件 | 结果 |
|------|------|------|
| T= 35000 | 主程序 RJAL NEX/OPR | pc 0→32，入栈{2} ✓ |
| T= 95000 | sub1 ADDI r4 执行 | r4=4 ✓（mem[2..13] 第一轮被跳过） |
| T= 95000 | sub1 RJAL OPR | pc 36→48，入栈{38} ✓ |
| T=155000 | sub2 ADDI r5 执行 | r5=5 ✓ |
| T=165000 | **sub2 JALR WRT** | 出栈{38}，pc→38 ✓（最后入的先出） |
| T=195000 | **sub1 JALR WRT** | 出栈{2}，pc→2 ✓（先入的后出） |
| T=245000 | 返回后 ADDI r1/r2/r3 | r1=1 r2=2 r3=3 ✓ |
| T=305000 | HALT（1B） | frz → IDLE 冻结 ✓ |

最终寄存器 **r1=1 r2=2 r3=3 r4=4 r5=5**；二次复位后程序重跑一遍，寄存器翻倍
（r1→2 … r5→10），返回栈在第一遍执行后已弹空、无残留——LIFO 与复位重启均验证通过。

### 调试记录 1：jmpwe 双入栈（每个 JAL 压栈两次）

- **现象**：JALR@39（旧编码）首次执行读到栈顶 39（跳回自身），需执行两次才真正返回 3
- **根因**：jmpwe 在 OPR 拍置位，但 pc 只在 **IF** 拍才清零。reg_f 在 WRT 拍（入栈一次）
  和随后的 IF 拍（jmpwe 仍为 1）各入栈一次 → 栈变成 `[3,3,39,39]`，出栈时先弹出重复项
- **修复**：`jmpwe` 在 **WRT 拍消费后立即清零**（`jmpwe <= 0` 放在 WRT 分支开头），
  保证每个 JAL 只脉冲一拍、只入栈一次

### 调试记录 2：跳转落地指令被跳过（r4/r5 从没执行）

- **现象**：仿真通过但 r4=0、r5=0——两个子程序里的 ADDI 从不执行
- **根因**：pc 在 WRT 拍用 `op_temp`（**当前 pc 的组合译码**）决定步进。RJAL 在 OPR 拍已跳到
  目标 32，下一拍 WRT 时 pc 已是 32，`op_temp` 译出的是**落地指令** ADDI（不是正在执行的
  RJAL），于是又步进 32→36，把落地指令直接跨过
- **修复**：WRT 步进条件加 `!jmpwe`——jmpwe 恰好在跳转落地后的那一拍为 1，此时不步进，
  落地指令获得完整 IF/OPR/WRT 周期

## 8. 相对 v4.2 的变化汇总

| # | 变化 | 状态 |
|---|------|------|
| 1 | 编码：逐字节 tag → **opcode 低 2 位声明长度**，其余字节纯数据、无 tag | ✓ 已实现 |
| 2 | 长度：HALT 2B→**1B**、JAL·JALR 3B→**2B**、ALU 4B（`len = 字节数−1`） | ✓ 已实现并验证 |
| 3 | 去除全部填充字节，指令紧凑排列 | ✓ 已实现 |
| 4 | FSM：3 状态 FET/NEX → **4 状态 IF/OPR/WRT** | ✓ 已实现 |
| 5 | PC 步进改到 WRT 拍（`pc + len + 1`），跳转在 OPR、返回在 WRT | ✓ 已实现并验证 |
| 6 | 修复 jmpwe 双入栈 bug | ✓ 已修复并验证 |
| 7 | 修复跳转落地指令被跳过 bug（`!jmpwe` 守卫） | ✓ 已修复并验证 |
| 8 | 返回栈 rad[0:63]，栈指针 j[6:0] | ✓ 已实现 |

## 9. 已知限制

| 限制 | 说明 |
|------|------|
| 空栈 JALR 行为未定义 | 空栈时 `ra = rad[j-1]` 越界到 rad[63]（初值 0），JALR 会跳回 0；无栈空保护 |
| 栈深固定 64 | 嵌套/递归超过 64 层会回绕，无溢出检测 |
| ALU-R 的 addr2 丢 bit0 | decoder `addr2 = inst_raw[7:1]` 取 7 位，奇数寄存器地址取不到；当前程序全是 ADDI 未触发 |
| 3B 长度编码保留未用 | len=`10` 无指令占用 |
| 无条件跳转 | LJAL/RJAL/JALR 均无条件，无 zero 标志，做不了 `if` |
| 算术右移 | SRA/SRAI 已删，需接 `$signed` 才有真算术右移 |
| 非流水线 | 4 状态多周期串行；ir/wreg 已构成两拍级写回结构，但无指令重叠 |

## 10. 后续规划

- [ ] 条件跳转（zero 标志：比较器 + 标志寄存器）
- [ ] LJAL 后向跳转单独覆盖测试（本轮只测了 RJAL 前跳 + JALR 返回）
- [ ] 栈空/溢出保护（空栈 JALR、栈深超限的显式行为）
- [ ] 寄存器组接 DDR（届时再给 reg_f 加复位/端口）
- [ ] 若做真流水线：处理数据冒险（旁路转发/气泡）与控制冒险（跳转预测/flush）

---

*本文件随项目演进同步更新。*
