# 流水线 CPU 设计记录（v6.0 —— 4 级流水线 IF→ID→EX→WB，v5.0 指令集不变）

> 版本：2026-08-12  ·  在 v5.0 基础上把**多周期串行**改成**4 级结构流水线**（指令重叠执行，无转发）
> v5.0 见 [single_cpu_design_v5.0.md](single_cpu_design_v5.0.md)，v4.2 见 [single_cpu_design_v4.2.md](single_cpu_design_v4.2.md)

## 0. 版本说明

沿用 v3.0 第 0 节定下的标准——**架构变则大版本**。本次把 CPU 从"多周期 FSM 串行执行"改为
"结构流水线重叠执行"，是执行模型级的架构变化，记 **v6.0**。指令集编码沿用 v5.0 不变。

| 维度 | v5.0（多周期） | v6.0（当前代码，流水线） |
|------|----------------|--------------------------|
| 执行模型 | 4 状态 FSM（IDLE/IF/OPR/WRT）**串行**，同一时刻只有一条指令在流中 | **4 级结构流水**（IF→ID→EX→WB），指令重叠执行 |
| 状态控制 | stage[2:0] 逐拍切状态 | **1-bit stage**（EXE=1 / IDLE=0），只做运行/停机控制，流水由结构推进 |
| 流水寄存器 | ir + wreg（两级写回） | **if_reg / id_reg / wr_reg** 三个级间寄存器 |
| 取指 | OPR 拍锁存译码 | pc 连续流式取指，if_reg 每拍锁存 4 字节窗口 |
| 跳转 | OPR 拍跳转 | JAL 在 if_reg 锁存的**下一拍**执行（pc_addr 已越过后），返回地址/基准 = pc_addr |
| 控制冒险 | 无重叠，无冒险 | 跳转 **flush 1 拍气泡**（if_reg 锁 NOP + id_reg/wr_reg 冲洗） |
| 数据冒险 | 无重叠，无冒险 | **无转发**，写后读需插 1 条 NOP/独立指令隔离 |
| HALT | frz → IDLE 冻结 | frz → IDLE，只冻结 1 拍（写已全部提交，pc 漂到未定义区，良性） |
| 指令集 | v5.0 20 条 | v5.0 指令集不变，**NOP（0x50）明确列为第 21 条指令** |

## 1. 总体架构（4 级结构流水线）

```
clk/rst ─▶ fsm ── stage（1-bit：EXE/IDLE）──▶ 广播到 if_reg / id_reg / wr_reg / pc

  ┌──────── IF ────────┬──────── ID ────────┬──────── EX ────────┬──── WB ────────┐
  │ pc ──▶ ins_rom     │ decoder（组合译码） │ reg_f 读（组合）   │ wr_reg          │
  │        │ 4B 窗口   │   opcode/rs1/rs2/  │   + alu（组合运算） │  ▾ 下一拍写回    │
  │        ▼           │   rd/imm/we/bytmov │                    │  reg_f 写        │
  │      if_reg ──────▶│  flush1/frz        │                    │                 │
  │        （取指寄存器） │      ▼            │                    │                 │
  │                   id_reg ──────▶ reg_f 读/alu ──────▶ wr_reg ─┘                 │
  │        （译码寄存器）    （执行级寄存器）   （写回寄存器）                         │
  └──────────────────────────────────────────────────────────────────────────────┘
        pc ──▶ 控制流：JAL 跳转（入栈 ra）/ JALR 返回（出栈）→ reg_f 内返回栈 rad[0:63]
```

一条指令流经：**IF 取指（if_reg 锁存）→ ID 译码（decoder 组合 + id_reg 锁存）→ EX 读寄存器 +
ALU 运算 → WB 锁存（wr_reg）→ 下一拍 reg_f 写回**。同一时刻 4 条不同指令分处 4 级，重叠执行。

3 个级间寄存器把组合逻辑切开：
- **if_reg**：IF/ID 边界，锁存 ins_rom 的 4 字节窗口 inst_raw
- **id_reg**：ID/EX 边界，锁存 decoder 译码出的 opcode/addr1/addr2/imm8/rd/we
- **wr_reg**：EX/WB 边界，锁存 ALU 结果 result/rd/we

## 2. 运行控制：1-bit stage（EXE/IDLE）

FSM 不再是逐拍切状态的串行机，退化成**运行/停机锁存**：

```
always @(posedge clk or posedge rst)
    if (rst)       stage <= EXE;
    else if (frz)  stage <= IDLE;
    else           stage <= EXE;
```

- **rst**：异步复位 → EXE（开始运行）
- **frz**：HALT 指令译码时 decoder 拉高 → IDLE（停机）
- 否则恒为 EXE（流水照跑，不做逐拍状态切换）

所有流水寄存器只在 `stage == EXE` 时推进；IDLE 期间流水冻结。**HALT 的 frz 只持续 1 拍**
（decoder 只在 if_reg 持有 HALT 的那一拍拉 frz，下一拍 if_reg 锁存到程序尾部之后的垃圾字节、
frz 掉电）——所以 HALT 之后 stage 会回到 EXE、pc 继续漂到未定义地址（X），但此前所有写
已经提交完毕，无副作用。测试平台（tb）在 HALT 冻结那拍主动收尾/触发复位，掩盖了这个尾巴。

## 3. 指令集（6-bit opcode，21 条）

v5.0 指令集原样保留，共 **21 条**（v5.0 文档表格漏列了 NOP，此处补全为第 21 条）：

| 编码 | 助记符 | 行为 | 归属 | 长度 | byte0 |
|------|--------|------|------|------|-------|
| 00_0000 | HALT | 冻结整机（frz=1） | 控制 | 1B | 00 |
| 00_0001 | ADDI | rd = rs1 + imm8 | ALU-I | 4B | 07 |
| 00_0010 | ADD  | rd = rs1 + rs2 | ALU-R | 4B | 0B |
| 00_0011 | SUBI | rd = rs1 − imm8 | ALU-I | 4B | 0F |
| 00_0100 | SUB  | rd = rs1 − rs2 | ALU-R | 4B | 13 |
| 00_0101 | AND  | rd = rs1 & rs2 | ALU-R | 4B | 17 |
| 00_0110 | OR   | rd = rs1 \| rs2 | ALU-R | 4B | 1B |
| 00_0111 | XOR  | rd = rs1 ^ rs2 | ALU-R | 4B | 1F |
| 00_1000 | LJAL | 后向跳转（pc − bytmov）且入栈返回地址 | 控制流 | 2B | 21 |
| 00_1001 | RJAL | 前向跳转（pc + bytmov）且入栈返回地址 | 控制流 | 2B | 25 |
| 00_1010 | ANDI | rd = rs1 & imm8 | ALU-I | 4B | 2B |
| 00_1011 | ORI  | rd = rs1 \| imm8 | ALU-I | 4B | 2F |
| 00_1100 | XORI | rd = rs1 ^ imm8 | ALU-I | 4B | 33 |
| 00_1101 | SLL  | rd = rs1 << rs2 | ALU-R | 4B | 37 |
| 00_1110 | SRL  | rd = rs1 >> rs2 | ALU-R | 4B | 3B |
| 00_1111 | SLLI | rd = rs1 << imm8 | ALU-I | 4B | 3F |
| 01_0000 | SRLI | rd = rs1 >> imm8 | ALU-I | 4B | 43 |
| 01_0001 | SLTU | rd = (rs1 < rs2) ? 1 : 0 | ALU-R | 4B | 47 |
| 01_0010 | SLTIU | rd = (rs1 < imm8) ? 1 : 0 | ALU-I | 4B | 4B |
| 01_0011 | JALR | pc ← 返回栈栈顶（出栈），无写回 | 控制流 | 2B | 4D |
| 01_0100 | NOP  | 空操作（1 拍流水气泡，用于冒险隔离） | 控制 | 1B | 50 |

- 编码 00_0000–01_0100 连续无空位；寄存器 8-bit 地址 → 256 个，r0 恒读 0、写入跳过
- **NOP 在 v6.0 是"一等公民"**：跳转 flush 产生的气泡、写后读冒险隔离都靠它
- 方向由 opcode[0] 决定：LJAL（bit0=0）减，RJAL（bit0=1）加

## 4. 指令编码（v5.0 方案，未变）

opcode 字节 = `opcode[5:0] << 2 | len[1:0]`，`len = 字节数 − 1`，只有 opcode 字节带长度位。
各类型字节布局（byte0 为最高字节）：

```
HALT / NOP（1B）：
  byte0 = opcode[5:0] | len=00

LJAL / RJAL / JALR（2B）：
  byte0 = opcode[5:0] | len=01
  byte1 = bytmov[7:0]          （JALR 的 byte1 是预留操作数槽，留 0）

ALU-R（4B）：
  byte0 = opcode[5:0] | len=11
  byte1 = rd    byte2 = rs1    byte3 = rs2

ALU-I（4B）：
  byte0 = opcode[5:0] | len=11
  byte1 = rd    byte2 = rs1    byte3 = imm8
```

ins_rom 以 pc 为地址一次打出 4 字节窗口：`inst_raw = {mem[addr..addr+3]}`，
`inst_num = mem[addr][1:0]` = len。PC 步进量 = `len + 1` = 当前指令字节数。
各 byte0 值见 §3 末列（如 ADDI=07、RJAL=25、JALR=4D、NOP=50），手写 hex 时直接查表。

**bytmov 计算**（RJAL 例，绝对地址式）：bytmov = 目标 − (跳转指令地址 + 2)。
如主程序 `RJAL → 64`@15：bytmov = 64 − 17 = 47 = 0x2F。

## 5. 流水线机制（v6.0 核心）

### 5.1 一条指令的完整时序（无依赖、无跳转）

设 if_reg 在 posedge C 锁存指令 I：

| 拍 | 事件 |
|----|------|
| posedge C | if_reg 锁存 I 的 4 字节窗口；pc 同时按 I 的长度步进 `pc_addr + inst_num + 1`（**流式取指**） |
| 周期 C..C+1 | decoder 组合译码 I |
| posedge C+1 | **id_reg 锁存译码字段**；**pc 在此拍执行 I 的控制流**（JAL 跳转 / JALR 返回 / 其余默认步进） |
| 周期 C+1..C+2 | reg_f 按 id_reg 的 rs1/rs2 组合读，alu 组合算出 result |
| posedge C+2 | **wr_reg 锁存 result/rd/we** |
| posedge C+3 | reg_f 写 `regs[rd]`（写后对读可见） |

所以写事件在 log 里比它对应指令的 `op` 列晚 2 拍出现，实际写寄存器再晚 1 拍。

### 5.2 跳转与 flush（控制冒险）

- **流式取指**：pc 每拍按取指处指令长度自增，取指指针永远超前。
- **JAL 执行时机**：if_reg 在 posedge C 锁存 JAL，posedge C+1 pc 看到 op_raw=JAL 时
  `pc_addr` **已经越过该 JAL**（上一拍步进了 `len+1`）。于是：
  - 返回地址 = `pc_addr`（= 该 JAL 的下一条）→ `ra <= pc_addr` 入栈
  - 跳转目标 = `pc_addr ± bytmov`（RJAL 加 / LJAL 减）
- **flush 气泡**：decoder 在译出 JAL/JALR 的那一拍拉高 `flush1`：
  - posedge C+1：if_reg 看到 flush1 → **锁存 NOP 气泡**（跳转后的错误路径指令永不取指）
  - 同一拍 id_reg 也 bubble（操作数清零、we=0、置 flush2=1），下一拍 wr_reg 看到 flush2 → 清空
  - 每个跳转净代价 = 1 拍气泡

### 5.3 数据冒险：无转发，靠 NOP 隔离

**没有旁路转发**。写后读（RAW）依赖：生产者的值要到 posedge C+3 才写进寄存器，而消费者的
reg_f 读发生在它的 EX 级。若中间不隔离，消费者会读到旧值。规则：

> **生产者与消费者之间必须隔 ≥2 个槽（中间插 1 条 NOP 或独立指令）。**

```
例（子程序里常见的模式）：
  XORI r20, r20, 15      ; 生产者
  NOP                    ; 隔离气泡（1 条）
  ORI  r21, r20, 48      ; 消费者，读到新 r20=15 ✓
```

### 5.4 复位行为（v6.0 显式处理 rst）

流水寄存器**自己处理复位**（不像多周期 FSM 天然挡复位窗口）：

- **if_reg**：`rst` 时锁存 NOP（不取指）。**必须如此**——否则复位窗口会锁存到第一条指令，
  等 rst 掉电后 pc 处理它时 `pc_addr=0`（复位期间没步进），跳转指令基准算错（见 §8 调试记录 1）
- **id_reg / wr_reg**：无显式复位端口，但复位窗口内 decoder 输出被 `if(rst)` 清零（→ NOP），
  两个寄存器自然锁成干净气泡，等效复位
- **pc / fsm**：异步复位（pc→0、fsm→EXE）

### 5.5 返回栈与调用/返回

- reg_f 内返回栈 `rad[0:63]`，栈指针 `j[6:0]`，`ra = rad[j-1]` 组合栈顶
- **入栈**：pc 执行 JAL 时 `jmpwe` 脉冲 1 拍，reg_f `if (jmpwe && ra_in != 0)` 压栈
- **出栈**：pc 执行 JALR 时 `jmpred` 脉冲 1 拍，reg_f `if (jmpred && j != 0)` 弹栈（j−1）
- 调用/返回可任意嵌套；程序配平（每个 JAL 对应一个 JALR）时跑完 j 回到 0
- **reg_f 无复位端口**：复位后寄存器数据与栈指针都保留（见 §8 调试记录 4）

## 6. 当前程序（ins_rom.hex，长测试：3 层嵌套 + 停机复位重跑）

程序按绝对地址分 4 段（`@0000` / `@0040` / `@0080` / `@00C0`），子程序用 RJAL 定位、JALR 返回：

```
main@0   : ADDI r1,r0,1 | NOP | ADDI r2,r0,2 | NOP | ADDI r3,r0,3 | NOP
           RJAL →64（入栈{17}）| NOP | ADDI r4,r4,10 | NOP
           RJAL →128（入栈{25}）| NOP | HALT
sub1@64  : ADDI r10,r0,5 | NOP | ADDI r11,r0,3 | NOP
           RJAL →128（入栈{76}）| NOP | ADD r12,r10,r11 | NOP
           SUB r13,r10,r11 | NOP | AND r14 | NOP | OR r15 | NOP | XOR r16 | NOP | JALR
sub2@128 : SLL r17,r10,r11 | NOP | SRL r18,r11,r10 | NOP | SLTU r19,r11,r10 | NOP
           RJAL →192（入栈{145}）| NOP | ADDI r17,r17,1 | NOP | JALR
sub3@192 : XORI r20,r0,15 | NOP | ORI r21,r20,48 | NOP | SLLI r22,r21,2 | NOP
           SRLI r23,r22,1 | NOP | ANDI r24,r23,85 | NOP | SUBI r25,r24,4 | NOP
           SLTIU r26,r25,96 | NOP | JALR
```

要点：
- **3 层嵌套**：main→sub1→sub2→sub3（深度 3），外加 main→sub2（深度 2），验证返回栈 LIFO
- **链首读 r0、链身读前驱**：子程序每个链只有第一条指令读 r0，其余读刚写的前驱（用 NOP 隔离），
  因此每次重跑所有子程序写**相同值**
- **停机复位**：程序以 HALT 收尾；tb 检测到第一次 HALT 冻结后拉高 rst ~25ns 重跑一遍，
  第二次 HALT 才收尾。reg_f 无复位 → 寄存器保留，**只有自增的 r4 翻倍（10→20）**，恰好证明
  复位重启真正生效

第一遍期望写事件：r1=1 r2=2 r3=3 r10=5 r11=3 r17=40 r18=0 r19=1
r20=15 r21=63 r22=252 r23=126 r24=84 r25=80 r26=1 r17=41 r12=8 r13=2 r14=1 r15=7 r16=6
r4=10 …（第二次调用同值 + r4=20）

## 7. 仿真验证

编译运行（Windows，iverilog 在 D 盘）：

```
cd project_self-try.srcs
/d/iverilog/bin/iverilog -g2012 -o cpu_alu_sim sources_1/new/*.v sim_1/new/single_cpu_top_tb.v
/d/iverilog/bin/vvp cpu_alu_sim
```

**tb 自动生成 `cpu_alu_sim.log`**（每周期一行）：

```
T=  75ns | stage=1 | pc=41 | op=010100  r10 = 5
```

- 列含义：`T`=时刻、`stage`=运行/停机（1=EXE，0=HALT 冻结）、`pc`=取指指针、
  `op`=EX 级（id_reg）那条指令的 6-bit opcode、行尾 `rN = v`=该拍提交的寄存器写
- **读法**：某指令的 `op` 出现在 T，它的写事件在 T+20ns 出现（写回再晚 1 拍进寄存器）
- **收尾**：第一次 HALT 冻结（`stage=0`）触发停机复位重跑；第二次 HALT 冻结停止打印、关日志、
  退出（`$finish(0)`）。若程序没有 HALT，4us 兜底强制收尾
- stdout 只打印 20 个寄存器写事件行（快速核对结果用）

关键验证帧（第一遍）：

| 时刻 | 事件 | 结果 |
|------|------|------|
| T≈55-105 | main 初始化 | r1=1 r2=2 r3=3 ✓ |
| T≈135 | sub1 入口 | r10=5 ✓ |
| T≈275-395 | sub3 链 | r20..r26=15/63/252/126/84/80/1 ✓ |
| T≈445 | sub2 返回后 | r17=41（40+1）✓ |
| T≈495-575 | sub1 返回前 | r12..r16=8/2/1/7/6 ✓ |
| T=955 | **第一次 HALT 冻结** | stage=0 → tb 复位重跑 ✓ |
| T≈1015-… | 第二遍从头执行 | 各寄存器同值，**r4=20**（10→20）✓ |
| T=1915 | 第二次 HALT 冻结 | 收尾，日志 188 行 ✓ |

## 8. 调试记录

### 调试记录 1：复位窗口锁存首条指令 → 跳转基准算错

- **现象**：复位后首条指令若为 JAL，跳转目标偏小（如 RJAL→32 跳到 30）
- **根因**：if_reg 无 rst 时会在复位窗口（rst=1）锁存第一条指令；rst 掉电后 pc 处理它时
  `pc_addr=0`（复位期间未步进），跳转基准少算了 2
- **修复**：if_reg 复位时锁存 NOP（`if (rst) inst_raw <= {NOP, 26'b0}`），复位窗口不取指
- **原理**：v5.0 多周期 FSM 逐拍切状态天然挡复位；v6.0 只剩 1-bit EXE/IDLE，
  **流水寄存器必须自己处理 rst**

### 调试记录 2：decoder 的 ALU-R addr2 丢 bit0（v5.0 遗留限制，已修）

- **现象**：奇数编号的 rs2（如 r11）读成相邻偶数寄存器，ALU-R 结果错
- **根因**：`addr2 = inst_raw[7:1]` 只取 7 位，丢掉 byte3 的 bit0
- **修复**：改为 `addr2 = inst_raw[7:0]`。v5.0 文档曾把此列为已知限制，v6.0 已修

### 调试记录 3：HALT 冻结只持续 1 拍（已知良性，未修）

- **现象**：HALT 后 stage 掉 0 只 1 拍，随后回 EXE、pc 漂到未定义地址（X）
- **根因**：frz 只在 if_reg 持有 HALT 的那一拍拉高；下一拍 if_reg 锁存程序尾部之外的垃圾字节
- **结论**：所有写已提交，无副作用；tb 在 HALT 冻结拍主动收尾/复位，掩盖尾巴

### 调试记录 4：reg_f 无复位 → 寄存器/栈指针保留（设计选择，留意）

- reg_f 只有 `initial` 清零，无 rst 端口。复位重跑时寄存器数据与返回栈指针 j 都保留
- 当前程序调用/返回**配平**（跑完 j 回 0），栈内容被下一轮覆盖复用，正确工作
- **隐患**：若写不配平的程序（少一个 JALR），第二次复位后 j 错位，返回会乱——届时需给 reg_f 加 rst

## 9. 相对 v5.0 的变化汇总

| # | 变化 | 状态 |
|---|------|------|
| 1 | 执行模型：多周期 FSM 串行 → **4 级结构流水线**（IF→ID→EX→WB 重叠执行） | ✓ 已实现 |
| 2 | stage：4 状态 → **1-bit EXE/IDLE**（只做运行/停机控制） | ✓ 已实现 |
| 3 | 流水寄存器：ir/wreg → **if_reg/id_reg/wr_reg** 三个级间寄存器 | ✓ 已实现 |
| 4 | 跳转：OPR 拍 → **JAL 在 if_reg 锁存下一拍执行**（流式取指，基准=pc_addr） | ✓ 已实现并验证 |
| 5 | 控制冒险：无 → **跳转 flush 1 拍气泡**（if_reg 锁 NOP + id_reg/wr_reg 冲洗） | ✓ 已实现 |
| 6 | 数据冒险：无 → **无转发，写后读插 NOP 隔离** | ✓ 规则化（用户程序遵守） |
| 7 | 复位：流水寄存器显式处理 rst（if_reg 复位锁 NOP） | ✓ 已实现并验证 |
| 8 | 修复 decoder addr2 丢 bit0（v5.0 已知限制） | ✓ 已修复 |
| 9 | NOP 明确列为第 21 条指令（气泡 + 冒险隔离） | ✓ 已文档化 |
| 10 | tb 生成 log 文件（T/stage/pc/op + 写事件）、停机复位重跑测试 | ✓ 已实现 |

## 10. 已知限制

| 限制 | 说明 |
|------|------|
| 无数据转发 | 写后读必须插 NOP 隔离（间隔 ≥2 槽）；编译器/汇编器需要知道这条 |
| 跳转固定 1 拍气泡 | 无条件跳转，无预测；每条 JAL/JALR 净代价 1 拍 |
| HALT 只冻结 1 拍 | 冻结后 pc 漂到未定义区（X），靠 tb 收尾掩盖；写已全部提交无副作用 |
| reg_f 无复位 | 寄存器与返回栈指针复位后保留；配平程序可用，不配平会错位 |
| 空栈 JALR 未定义 | 空栈时 `ra = rad[j-1]` 越界（rad[63] 初值 0 或 X），无栈空保护 |
| 栈深固定 64 | 嵌套/递归超 64 层回绕，无溢出检测 |
| 3B 长度编码保留未用 | len=`10` 无指令占用 |
| 无条件跳转 | 无 zero 标志，做不了 `if`（分支） |
| 无算术右移 | SRA/SRAI 已删，需接 `$signed` 才有真算术右移 |
| 指令重叠但无性能统计 | 尚未统计 CPI/IPC，未测吞吐上限 |

## 11. 后续规划

- [ ] 数据旁路转发（bypass：EX→ID / WB→ID 前送，去掉大部分 NOP 隔离）
- [ ] 条件分支（zero 标志：比较器 + 标志寄存器 + 分支预测）
- [ ] 跳转预测（取指时提前算目标，减少/消除 1 拍气泡）
- [ ] 栈空/溢出保护（空栈 JALR、栈深超限显式行为）
- [ ] 寄存器组复位与 DDR 接线（届时给 reg_f 加 rst/端口）
- [ ] 指令吞吐/CPI 统计（评估流水线收益）

---

*本文件随项目演进同步更新。*
