# 流水线 CPU 设计记录（v6.1 —— 4 级流水 + 旁路转发 + 条件跳转）

> 版本：2026-08-12  ·  在 v6.0 的 4 级结构流水基础上，补上**数据旁路转发**（EX 级 1 拍前送）和
> **条件跳转 LBEQ/RBEQ**（比较寄存器值）。指令集从 21 条扩到 **23 条**。
> v6.0 见 [single_cpu_design_v6.0.md](single_cpu_design_v6.0.md)，v5.0 见 [single_cpu_design_v5.0.md](single_cpu_design_v5.0.md)

## 0. 版本说明

架构仍是 v6.0 的 4 级结构流水（IF→ID→EX→WB），本次是在流水线能力上的两个大补强：

| 维度 | v6.0（无转发、无条件跳转） | v6.1（当前代码） |
|------|---------------------------|------------------|
| 数据冒险 | 写后读必须插 NOP 隔离（间隔 ≥2 槽） | **旁路转发**：紧邻上一条（EX 级）结果 1 拍前送，**紧邻写后读不再需要 NOP** |
| 条件跳转 | 无 zero 标志，做不了 `if` | **LBEQ / RBEQ**：比较 r1/r2 值，相等跳转（不需要标志寄存器） |
| 指令数 | 21 条（含 NOP） | **23 条**（+ LBEQ + RBEQ） |
| 跳转类型 | 仅无条件 JAL/JALR | 无条件 JAL/JALR + **条件 BEQ**（值相等才跳，不跳则顺序） |
| BEQ 跳转语义 | — | **不入栈**（条件跳转不是调用；JAL 才压栈） |

转发与条件跳转共用一套"紧邻写回值前送"机制，但实现上分两路：ALU 的 `rs_alt` 前送管普通指令；
BEQ 用第二读口 + rd_last1/rd_last2 两层前送管值比较（见 §5.4、§5.5）。

## 1. 总体架构（4 级结构流水线，v6.0 + 转发 + 条件跳转）

```
clk/rst ─▶ fsm ── stage（1-bit：EXE/IDLE）──▶ 广播到 if_reg / id_reg / wr_reg / pc

  ┌──────── IF ────────┬──────── ID ────────┬──────── EX ────────┬──── WB ────────┐
  │ pc ──▶ ins_rom     │ decoder（组合译码） │ reg_f 读（组合）   │ wr_reg          │
  │        │ 4B 窗口   │   opcode/rs1/rs2/  │   + alu（组合运算） │  ▾ 下一拍写回    │
  │        ▼           │   rd/imm/we/bytmov │   ▲                │  reg_f 写        │
  │      if_reg ──────▶│   rs_alt(前送位)   │   └─ result_last ──┘                 │
  │        （取指寄存器） │   r12_data_imm ◀──│     （EX 级前送：旁路）                │
  │                   id_reg ──────▶ reg_f 读/alu ──────▶ wr_reg ─┘                 │
  │        （译码寄存器）    （执行级寄存器）   （写回寄存器）                         │
  └──────────────────────────────────────────────────────────────────────────────┘
        pc ──▶ 控制流：JAL 跳转（入栈 ra）/ BEQ 条件跳（不入栈）/ JALR 返回（出栈）
        reg_f ─▶ 第二读口 r12_data_imm（按 decoder 译码当拍地址组合读，供 BEQ 值比较）
```

**新增三处结构**（相对 v6.0）：
1. **旁路**：`decoder 算 rs_alt（2-bit）→ id_reg 锁存 → alu 用 rs_alt 选 result_last（上一条结果）
   还是 ab_raw（寄存器堆读值）`。紧邻写后读直接拿到新值。
2. **BEQ 值比较通路**：decoder 译码 BEQ 当拍就要 r1/r2 的值 → reg_f 增加**第二读口**
   `addr_12_imm → r12_data_imm`（按译码指令的 r1/r2 地址组合读），配合两层前送得到"有效值"。
3. **rd_last1 / rd_last2**：上一条（EX 级 id_reg 输出 rd）与上上条（WB 级 wr_reg 输出 rd），
   分别携带各自的新值（`result_last_in` / `rd_data_imm`）供 BEQ 前送。

## 2. 运行控制：1-bit stage（EXE/IDLE）

与 v6.0 完全相同，未变：fsm 退化为运行/停机锁存，`rst → EXE`、`frz（HALT 译码）→ IDLE`、否则 EXE。
所有流水寄存器只在 `stage == EXE` 推进。HALT 的 frz 仍只持续 1 拍（写已全部提交，pc 漂移良性）。

## 3. 指令集（6-bit opcode，23 条）

在 v6.0 的 21 条基础上新增 **LBEQ / RBEQ**（加粗为新指令）：

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
| **01_0101** | **RBEQ** | **前向条件跳：`r1 == r2` 才跳（pc + bytmov），否则顺序；不入栈** | **控制流** | **4B** | **57** |
| **01_0110** | **LBEQ** | **后向条件跳：`r1 == r2` 才跳（pc − bytmov），否则顺序；不入栈** | **控制流** | **4B** | **5B** |

- 方向由 opcode[0] 决定：LBEQ（bit0=0）减，RBEQ（bit0=1）加，与 JAL 一致
- **BEQ 比较的是寄存器「值」**，不是寄存器编号；r1==r2（同寄存器号）必相等 → 恒跳
- BEQ 跳转**不压栈**（不是调用），也不置 `jmpflg[1]`；只有 JAL 压栈、JALR 出栈
- 条件跳转净代价与 JAL 相同：1 拍气泡（值相等才 flush）

## 4. 指令编码（v5.0 方案 + BEQ 4B 布局）

opcode 字节 = `opcode[5:0] << 2 | len[1:0]`，`len = 字节数 − 1`。新增 BEQ 与 ALU-R 同宽：

```
BEQ（4B，新增）：
  byte0 = opcode[5:0] | len=11        LBEQ=0x5B / RBEQ=0x57
  byte1 = bytmov[7:0]                  （值相等时作跳转偏移，值不等 decoder 输出 0）
  byte2 = r1[7:0]                      （比较操作数 1）
  byte3 = r2[7:0]                      （比较操作数 2）
```

其余类型（HALT/NOP 1B、JAL/JALR 2B、ALU-R/I 4B）编码与 v6.0 完全相同，见 v6.0 §4。

**bytmov 计算（BEQ，4B 绝对地址式）**：跳转目标 = 跳转指令地址 + 4 ± bytmov（方向同 opcode[0]），
所以 **bytmov = 目标 − (跳转指令地址 + 4)**（RBEQ）/ **bytmov = (指令地址 + 4) − 目标**（LBEQ）。
与 JAL 的 `目标 − (地址 + 2)` 同理（都是"pc_addr 已越过后"的基准，见 §5.5）。

## 5. 流水线机制（v6.1 核心：旁路转发 + 条件跳转）

基础时序（if_reg 在 posedge C 锁存 → C+1 id_reg + pc 控制流 → C+2 wr_reg → C+3 写回）与
v6.0 §5.1 相同，不重复。以下只讲新增机制。

### 5.1 旁路转发（数据冒险：紧邻写后读 0 气泡）

**原理**：上一条指令的结果在 EX 级（posedge C+1 后，其 result 已稳定且进入 id_reg 锁存的
`result_last2`），而紧邻下一条此时正在 ID→EX。若下一条的源操作数编号正好等于上一条的 rd，
直接拿 `result_last2` 当操作数，不必等写回。

**decoder 算 rs_alt**（译码当拍，组合）：

```verilog
// rs_alt 是 2-bit 位标志：rs_alt[0]=1 → a 前送；rs_alt[1]=1 → b 前送
if (we && addr_d12[23:16] != 8'b0) begin          // 上一条有写且 rd≠0（r0 恒 0 不送）
    rs_alt[1] = (r2 == rd_last1);                 // b 源 == 上一条 rd → 前送
    rs_alt[0] = (r1 == rd_last1);                 // a 源 == 上一条 rd → 前送
end
```

`rd_last1` = id_reg 输出的 rd（EX 级那条）。`rs_alt` 与 opcode/imm8 等一起由 id_reg 锁存（EX 级用）。

**alu 用 rs_alt 选源**：

```verilog
assign a = (rs_alt[0] == 1'b1) ? result_last2 : ab_raw[15:8];   // a = 前送值 或 reg_f 读值
assign b = (rs_alt[1] == 1'b1) ? result_last2 : ab_raw[7:0];
```

**覆盖范围**：
- **紧邻写后读**（上一条写、下一条读）→ 前送，**0 气泡**（v6.0 需 1 条 NOP）
- 间隔 ≥1 条独立指令 → 写已在 WB 提交，reg_f 自然读到新值，无需前送
- 双源都命中 → 两个操作数都前送（如 `ADD r27, r10, r10` 紧跟 `ADDI r10`，两源都取 result_last2）

### 5.2 条件跳转 BEQ：值比较需要"两层前送 + 第二读口"

**难点**：BEQ 在 ID 拍（posedge C..C+1 组合译码）就要决定跳不跳，但它要比较的 r1/r2 值，
一个在寄存器堆（可能还是旧值）、一个可能正在 EX/WB 还没落地。所以：

1. **第二读口** `addr_12_imm = decoder.addr_d12[15:0] = {r1, r2}`（译码当拍地址，组合直通），
   reg_f 组合读出 `r12_data_imm = {regs[r1], regs[r2]}`。
2. **两层前送**（decoder 组合，顺序由新到旧）：
   - `rd_last1`（EX 级上一条）→ 新值在 `result_last_in`（ALU 刚算的结果）
   - `rd_last2`（WB 级上上条）→ 新值在 `rd_data_imm`（wr_reg 写数据，posedge 才落 regs）

```verilog
// 先取 regs 常规读，若命中 WB 级用 rd_data_imm 顶替
wire [7:0] r1_data_imm = (r1 == rd_last2)? rd_data_imm : r12_data_imm[15:8];
wire [7:0] r2_data_imm = (r2 == rd_last2)? rd_data_imm : r12_data_imm[7:0];
// 再顶 EX 级（最新），带 rd_last1≠0 守卫（bubble 时 result_last_in 是垃圾）
wire [7:0] r1_data_final = (rd_last1 != 8'b0 && r1 == rd_last1)? result_last_in : r1_data_imm;
wire [7:0] r2_data_final = (rd_last1 != 8'b0 && r2 == rd_last1)? result_last_in : r2_data_imm;
```

3. **BEQ 判跳**（值相等才置 bytmov + flush1，否则 bytmov 保持 0 → 顺序执行）：

```verilog
LBEQ, RBEQ: begin
    addr_d12[15:0] = inst_raw[15:0];          // 喂第二读口
    if (r1_data_final == r2_data_final) begin
        bytmov = inst_raw[23:16];
        flush1 = 1'b1;
    end
end
```

- `rd_last2` 层无需 `≠0` 守卫：wr_reg 在 bubble 时把 `rd/rd_data` 都清 0，命中也只取 0（r0 恒 0），无害
- **r1==r2（同寄存器）**：两边取同一来源必然相等 → 恒跳，无需特判
- 值不等 → bytmov=0、flush1=0 → pc 顺序取指（见下）

### 5.3 条件跳转的执行（pc.v：bytmov≠0 才跳，且不入栈）

```verilog
LBEQ, RBEQ: begin
    if (bytmov != 8'b0) begin                 // 值相等时 decoder 才给非 0
        case (op_raw[0])
        1'b0: pc_addr <= pc_addr - bytmov;    // LBEQ 后向
        1'b1: pc_addr <= pc_addr + bytmov;    // RBEQ 前向
        endcase
    end
    else begin
        if (!frz) pc_addr <= pc_addr + inst_num + 1;   // 值不等 → 顺序
    end
end
```

- **跳转基准**：与 JAL 相同——pc 在 if_reg 锁存 BEQ 的**下一拍**执行，此时 `pc_addr` 已越过该
  4B 指令到 `addr + 4`，所以 `pc_addr ± bytmov` 实际 = `addr + 4 ± bytmov`（见 §4 汇编公式）
- **不入栈**：BEQ 分支不写 `ra`、不置 `jmpflg[1]`。若压栈，返回栈会被条件跳污染（历史上踩过，
  见 §8 调试记录 5）。条件跳不是调用，没有返回地址要保存

### 5.4 控制冒险：BEQ 值相等才 flush 1 拍

- 值相等：decoder 拉 flush1（同 JAL），if_reg 下一拍锁 NOP 气泡，净代价 1 拍
- 值不等：flush1=0，完全不打断流水，**0 代价**

### 5.5 返回栈（v6.1 明确：只有 JAL 压栈）

- 入栈：pc 执行 **LJAL/RJAL**（bytmov≠0）→ `ra <= pc_addr`、`jmpflg[1] <= 1`
- 出栈：pc 执行 **JALR** → `jmpflg[0] <= 1`、`pc_addr <= ra_in`（= reg_f 返回栈栈顶）
- **BEQ 既不压也不出**；调用/返回配平规则不变（每个 JAL 配一个 JALR）

## 6. 当前程序（ins_rom.hex，v6.1 长综合测试）

绝对地址分 5 段，覆盖：全部 16 条 ALU、条件跳转 4 种场景、有限循环、子程序调用×3、转发链：

```
main@0      : ADDI r1,r0,1 | ADDI r2,r0,2 | ADD r3,r1,r2 | SUB r4,r3,r1 | AND r5,r3,r2
              OR r6,r3,r2 | XOR r7,r3,r2 | RJAL →sub1(0x80) | ADDI r8,r0,1
              RBEQ 0x30,r8,r1        ; 1==1 相等跳（跳过 r9 陷阱 / HALT 陷阱）
              ADDI r9,r9,100(陷阱) | HALT(陷阱)
              LBEQ 0x2A,r8,r2        ; 1!=2 不等不跳（误跳落 HALT）
              ADDI r10,r10,5 | ADDI r11,r0,3(循环计数=3)
loop:         SUBI r11,r11,1 | RBEQ 0x50,r11,r0 ; r11 减到 0 跳出
              ADDI r7,r7,1 | LBEQ loop,r0,r0    ; r0==r0 恒跳回环
              HALT(陷阱) | RJAL →sub2(0xC0) | ADDI r13,r13,1
              RJAL →sub1(0x80) | ADDI r14,r14,1 | HALT
sub1@0x80    : ADDI r20,r0,8 | SUBI r21,r20,3 | ANDI r22,r20,12 | ORI r23,r20,48
              XORI r24,r20,255 | SLLI r25,r20,2 | SRLI r26,r20,1 | SLTIU r27,r20,10 | JALR
sub2@0xC0    : ADDI r30,r0,10 | ADDI r31,r0,2 | SLL r28,r30,r31 | SRL r29,r28,r31
              SLTU r28,r29,r30 | JALR
```

要点：
- **全部指令**：ALU-R 9 条 + ALU-I 8 条 = 16 条全覆盖；控制流 RJAL×3、JALR×3、RBEQ×2、LBEQ×2
- **条件跳转场景**：值相等跳（RBEQ r8,r1）、值不等不跳（LBEQ r8,r2）、同寄存器恒跳回环（LBEQ r0,r0）、
  紧邻写后读比较（RBEQ r8,r1 中 r8 紧跟 ADDI；RBEQ r11,r0 中 r11 紧跟 SUBI）
- **转发链**：ADD r3,r1,r2 读紧邻 r2；sub1 整链 8 条紧邻转发（r20→r21→…→r27）；sub2 的 SRL 读紧邻 r28
- **子程序可重复调用**：sub1 被调 2 次、sub2 调 1 次，验证返回栈 LIFO 与配平
- **陷阱**：3 个 HALT + 1 个 ADDI r9 陷阱，误跳/误判立刻冻结或留下 r9=100 的痕迹
- **停机复位重跑**：tb 检测第一次 HALT 冻结后拉高 rst 重跑一遍；自增指令 r10/r13/r14 翻倍，
  证明复位重启真正生效（r8 用绝对赋值，保证 RBEQ 条件两遍恒定，测试自洽）

## 7. 仿真验证

编译运行（iverilog，Windows）：

```
cd project_self-try.srcs
/d/iverilog/bin/iverilog -g2012 -o cpu_alu_sim sources_1/new/*.v sim_1/new/single_cpu_top_tb.v
/d/iverilog/bin/vvp cpu_alu_sim
```

**第一遍关键写事件**（stdout）：

```
r1=1 r2=2 r3=3 r4=2 r5=2 r6=3 r7=1          ; main ALU 链
r20=8 r21=5 r22=8 r23=56 r24=247 r25=32 r26=4 r27=1   ; sub1 ALU-I 链（全转发）
r8=1 r10=5                                       ; 条件跳：相等跳对、r10 落地
r11: 3→2→1→0,  r7: 1→2→3                        ; 有限循环 3 轮
r30=10 r31=2 r28=40→0 r29=10                     ; sub2：SLL=40、SRL=10、SLTU=0
r13=1 r14=1                                      ; sub2/sub1 返回后标记
```

**第二遍（复位重跑）**：`r10=10`、`r13=2`、`r14=2`（自增翻倍，证明重跑生效），
其余同第一遍；`r9` 两遍都不出现（陷阱未被踩），**全程零 X**。

对照检查点：

| 检查点 | 验证内容 | 结果 |
|--------|----------|------|
| r3=3 | ADD r3,r1,r2，紧邻 r2 转发 | ✓ |
| r21=5 | SUBI r21,r20,3 转发 r20 | ✓ |
| r24=247 | XORI r24,r20,255 = 8^255 | ✓ |
| r8=1 且 r9 不出现 | RBEQ 相等跳，跳过陷阱 | ✓ |
| r11 归 0、r7=3 | RBEQ 循环跳出 + LBEQ 恒跳回环 | ✓ |
| r28=40→0、r29=10 | SLL/SRL/SLTU | ✓ |
| r13/r14=1 | sub2、sub1 返回地址正确 | ✓ |
| 第二遍 r10/r13/r14 翻倍 | 停机复位重跑生效 | ✓ |

## 8. 调试记录

### 调试记录 1：id_reg 丢了 rs_alt 锁存（重构回归，转发全坏）

- **现象**：转发测试几乎所有消费指令 `alu=x`（r2=x、r3=x、r27=x…）；而前驱是气泡/跳转的指令正常
- **排查**：DEBUG_TRACE 显示 `rs_alt=xx`（恒 X）。静态推演 rs_alt 应为 00/11，仿真却是 X
- **根因**：id_reg 重构后 always 块里 `rs_alt <= rs_alt_in` 整行被删——`rs_alt_in` 端口还在、
  `rs_alt` 输出也在，但从不锁存，`rs_alt` 永远是未初始化 X
- **连锁反应**：alu 里 `(rs_alt[0]==1'b1)? result_last : ab_raw` 条件为 X 时返回**两路逐位混合**
  `merge(result_last, ab_raw)`。result_last 与 ab_raw 相同时碰巧对（如第二次复位后 r27=10 是假象），
  不同就出 X
- **修复**：非 flush 分支补 `rs_alt <= rs_alt_in`，flush 分支 `rs_alt <= 2'b00`
- **教训**：重构"直通"信号时，锁存赋值列表要与端口声明逐一核对

### 调试记录 2：reg_f 第二读口复制笔误（`addr_12` 应为 `addr_12_imm`）

- **现象**：无（BEQ 未启用时第二读口没被用到）
- **根因**：`r1_imm/r2_imm` 误写成 `addr_12[15:8]`/`addr_12[7:0]`（复制第一读口没改），
  第二读口永远读第一读口的地址，`r12_data_imm == r12_data`
- **修复**：改为 `addr_12_imm[15:8]`/`addr_12_imm[7:0]`

### 调试记录 3：BEQ 第一版比较逻辑错（比"旧值==新值"且忽略 r2）

- **现象**：紧邻写后读的 BEQ 判不跳
- **根因**：第一版
  ```verilog
  else if (r1 == rd_last1) begin
      if (r1_data_imm == result_last_in) ...   // r1_data_imm 是 regs 旧值，比的是"旧值==新值"
  ```
  r1 是 rd_last1 时 regs[r1] 还是旧值，`旧值 == 新值` 几乎恒假；且只比了 r1 一个操作数，r2 没出现
- **修复**：改成"先算两个操作数的有效值，再比较"（`r1_data_final == r2_data_final`），
  有效值按 rd_last1（EX）/ rd_last2（WB）两层前送取新值，否则读 regs

### 调试记录 4：BEQ 还要补 rd_last2（WB 级）一层前送

- **现象/根因**：只前送 rd_last1 时，上上条（WB 级）的值要 posedge 才落 regs，译码窗口内 regs
  仍是旧值——BEQ 读它也会错。`rd_last2/rd_data_imm`（wr_reg 输出）顶替这一层
- **时序**：BEQ 在 C..C+1 组合译码，上上条在 C+1 posedge 才写 regs，所以译码期间必须前送

### 调试记录 5：BEQ 跳转压栈污染返回栈（已去）

- **现象**：BEQ 跳转时 pc 与 JAL 同分支，把返回地址压栈
- **后果**：条件跳不是调用，无对应 JALR 出栈，返回栈残留垃圾；一旦与子程序混用，JALR 弹错地址
- **修复**：LBEQ/RBEQ 独立成分支，跳转只改 pc_addr，不写 ra、不置 jmpflg[1]；压栈只留 JAL

## 9. 相对 v6.0 的变化汇总

| # | 变化 | 状态 |
|---|------|------|
| 1 | 数据冒险：NOP 隔离 → **旁路转发**（EX 级 1 拍前送，`rs_alt` + `result_last`） | ✓ 已实现并验证 |
| 2 | 条件跳转：新增 **LBEQ / RBEQ**（比较 r1/r2 值，相等才跳） | ✓ 已实现并验证 |
| 3 | reg_f 增加**第二读口**（addr_12_imm → r12_data_imm）供 BEQ 值比较 | ✓ 已实现 |
| 4 | BEQ 用 **rd_last1 + rd_last2 两层前送**（result_last_in / rd_data_imm） | ✓ 已实现并验证 |
| 5 | BEQ 跳转**不入栈**（独立分支，只改 pc_addr） | ✓ 已实现并验证 |
| 6 | 指令集 21 → **23 条**（+RBEQ=57、+LBEQ=5B） | ✓ 已实现 |
| 7 | 修复 id_reg rs_alt 锁存丢失（重构回归） | ✓ 已修复 |
| 8 | 修复 reg_f 第二读口复制笔误 | ✓ 已修复 |
| 9 | 修复 BEQ 值比较逻辑（有效值比较替代旧值==新值） | ✓ 已修复 |
| 10 | 长综合测试：全部 16 条 ALU + 4 种条件跳场景 + 循环 + 3 次子程序调用 | ✓ 已通过 |
| 11 | 总线合并整理：相关位捆成宽总线（decoder/id_reg/reg_f/alu/pc），见 §9.1 | ✓ 已实现 |

### 9.1 总线整理（相对 v6.0，结构调整）

把上一版分散的 8-bit 一对一信号捆成宽总线：decoder 输出 `addr1/addr2/rd` → `addr_d12[23:0]`，
reg_f/alu 双操作数 → `r12` / `r12_data` / `ab_raw[15:0]`，pc 的 `jmpwe/jmpred` → `jmpflg[1:0]`。
**这是工程整理，不是综合优化**——综合器会把 wire 扁平化，FF 数量与 Fmax 与分散写法等价；
收益是可读性、减少一对一接线的漏接/错接笔误、reg_f 双端口 RAM 意图更清晰。
合并后长测试重跑两遍通过，无功能回归。

## 10. 已知限制

| 限制 | 说明 |
|------|------|
| 转发只覆盖**紧邻上一条** | `rs_alt` 只比较 rd_last1；间隔 ≥1 条靠写回，BEQ 有专门的两层前送 |
| 条件跳仍固定 1 拍气泡 | 值相等时 flush 1 拍；值不等 0 代价。无分支预测 |
| BEQ 8-bit bytmov | 前/后向跳转范围 ±255 字节 |
| HALT 只冻结 1 拍 | 冻结后 pc 漂到未定义区（X），靠 tb 收尾掩盖；写已提交无副作用 |
| reg_f 无复位 | 寄存器与返回栈指针复位后保留；配平程序可用，不配平会错位 |
| 空栈 JALR 未定义 | 空栈时 `ra = rad[j-1]` 越界，无栈空保护（尚未触发） |
| 连续 JALR 读同一栈顶 | 栈顶只写一次、连续弹两次会重复读同一地址（未触发） |
| 栈深固定 64 | 嵌套/递归超 64 层回绕，无溢出检测 |
| 3B 长度编码保留未用 | len=`10` 无指令占用 |
| 无算术右移 | SRA/SRAI 已删，需接 `$signed` 才有真算术右移 |
| 指令重叠但无性能统计 | 尚未统计 CPI/IPC，未测吞吐上限 |

## 11. 后续规划

- [x] 数据旁路转发（EX→ID 前送，去掉紧邻 NOP）
- [x] 条件分支（LBEQ/RBEQ：比较器 + 两层前送，不需要标志寄存器）
- [ ] 跳转预测（取指时提前算目标，减少/消除 1 拍气泡）
- [ ] 栈空/溢出保护（空栈 JALR、连续 JALR 重复读栈顶、栈深超限）
- [ ] 寄存器组复位与 DDR 接线（届时给 reg_f 加 rst/端口）
- [ ] 指令吞吐/CPI 统计（评估流水线收益）

---

*本文件随项目演进同步更新。*
