# 流水线 CPU 设计记录（v6.2 —— 6 条件分支 + 栈保护）

> 版本：2026-08-12  ·  在 v6.1 的 4 级流水 + 旁路转发 + 条件跳转基础上，
> **条件分支从 2 条扩到 6 条**（EQ / NE / LTU × 前向/后向，统一编码），并加上**返回栈满/空保护**。
> 指令集从 23 条扩到 **27 条**。
> v6.1 见 [single_cpu_design_v6.1.md](single_cpu_design_v6.1.md)，v6.0 见 [single_cpu_design_v6.0.md](single_cpu_design_v6.0.md)

## 0. 版本说明

架构仍是 v6.1 的 4 级结构流水 + EX 级旁路转发，本次两件事：

| 维度 | v6.1 | v6.2（当前代码） |
|------|------|------------------|
| 条件分支 | 仅 LBEQ / RBEQ（值相等跳） | **6 条**：EQ / NE / LTU × L/R，连续编码，方向靠 opcode[0] |
| 比较方式 | `r1 == r2` | EQ 用 `==`、NE 用 `!=`、LTU 用 `<`（无符号），共用两层前送的有效值 |
| 返回栈 | 无保护（空栈 JALR 越界读、满栈静默回绕） | **栈保护**：满栈挡 JAL 压栈、空栈挡 JALR 弹栈，挡跳走顺序路径 |
| 栈深 | 固定 64（rad[0:63]） | **256**（rad[0:255]，j 满 255 触发保护） |
| 指令数 | 23 条 | **27 条** |

栈保护不是加几条判断那么简单：它让 JAL/JALR 多出"**保护后走顺序路径**"这条支路，而流水冲刷
（flush1）原本对 JAL/JALR 是无条件发的——顺序路径会把紧跟的指令冲掉。所以 flush 也必须按保护条件
条件化（decoder 拿到 j_flag，见 §5.3）。本轮为此踩的坑见 §8 调试记录。

## 1. 总体架构（v6.1 + 条件分支统一 + 栈保护通路）

```
clk/rst ─▶ fsm ── stage（1-bit：EXE/IDLE）──▶ 广播到 if_reg / id_reg / wr_reg / pc

  ┌──────── IF ────────┬──────── ID ────────┬──────── EX ────────┬──── WB ────────┐
  │ pc ──▶ ins_rom     │ decoder（组合译码） │ reg_f 读（组合）   │ wr_reg          │
  │        │ 4B 窗口   │   6 条件分支译码   │   + alu（组合运算） │  ▾ 下一拍写回    │
  │        ▼           │   rs_alt/两层前送  │   ▲                │  reg_f 写        │
  │      if_reg ──────▶│   j_flag（栈满/空）│   └─ result_last ──┘                 │
  │        （取指寄存器） │   flush1 条件化   │     （EX 级前送：旁路）                │
  └──────────────────────────────────────────────────────────────────────────────┘
        pc ──▶ 控制流：JAL 压栈跳（满栈挡）/ 条件分支跳（不入栈）/ JALR 弹栈跳（空栈挡）
        reg_f ─▶ j_flag[1]=满(j==255)、j_flag[0]=空(j==0) ──▶ 广播到 pc 和 decoder
```

**相对 v6.1 新增的两处结构**：
1. **栈保护通路**：reg_f 输出 `j_flag[1:0]`（满/空），同时接 **pc**（挡跳转）和 **decoder**（条件化
   flush1，防止顺序路径被冲刷）。
2. **6 条条件分支**：`LBEQ/RBEQ/LBNE/RBNE/LBLTU/RBLTU` 连续编码，译码用同一套"两层前送有效值 +
   比较"模板，只是比较算子不同（== / != / <）。

## 2. 运行控制：1-bit stage（EXE/IDLE）

与 v6.1 完全相同，未变：fsm 退化为运行/停机锁存，`rst → EXE`、`frz（HALT 译码）→ IDLE`、否则 EXE。
所有流水寄存器只在 `stage == EXE` 推进。

## 3. 指令集（6-bit opcode，27 条）

在 v6.1 的 23 条基础上：新增 **LBNE/RBNE/LBLTU/RBLTU** 4 条，**LBEQ/RBEQ 重编码**为连续段
（RBEQ 从 01_0101 改到 01_0111）。加粗为相对 v6.1 有变/新增：

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
| 00_1000 | LJAL | 后向跳（pc − bytmov）且入栈返回地址（满栈挡） | 控制流 | 2B | 21 |
| 00_1001 | RJAL | 前向跳（pc + bytmov）且入栈返回地址（满栈挡） | 控制流 | 2B | 25 |
| 00_1010 | ANDI | rd = rs1 & imm8 | ALU-I | 4B | 2B |
| 00_1011 | ORI  | rd = rs1 \| imm8 | ALU-I | 4B | 2F |
| 00_1100 | XORI | rd = rs1 ^ imm8 | ALU-I | 4B | 33 |
| 00_1101 | SLL  | rd = rs1 << rs2 | ALU-R | 4B | 37 |
| 00_1110 | SRL  | rd = rs1 >> rs2 | ALU-R | 4B | 3B |
| 00_1111 | SLLI | rd = rs1 << imm8 | ALU-I | 4B | 3F |
| 01_0000 | SRLI | rd = rs1 >> imm8 | ALU-I | 4B | 43 |
| 01_0001 | SLTU | rd = (rs1 < rs2) ? 1 : 0 | ALU-R | 4B | 47 |
| 01_0010 | SLTIU | rd = (rs1 < imm8) ? 1 : 0 | ALU-I | 4B | 4B |
| 01_0011 | JALR | pc ← 栈顶（出栈），无写回（空栈挡） | 控制流 | 2B | 4D |
| 01_0100 | NOP  | 空操作（1 拍流水气泡） | 控制 | 1B | 50 |
| **01_0110** | **LBEQ** | **后向条件跳：`r1 == r2` 才跳，否则顺序；不入栈** | **控制流** | **4B** | **5B** |
| **01_0111** | **RBEQ** | **前向条件跳：`r1 == r2` 才跳，否则顺序；不入栈** | **控制流** | **4B** | **5F** |
| **01_1000** | **LBNE** | **后向条件跳：`r1 != r2` 才跳，否则顺序；不入栈** | **控制流** | **4B** | **63** |
| **01_1001** | **RBNE** | **前向条件跳：`r1 != r2` 才跳，否则顺序；不入栈** | **控制流** | **4B** | **67** |
| **01_1010** | **LBLTU** | **后向条件跳：`r1 < r2`（无符号）才跳，否则顺序；不入栈** | **控制流** | **4B** | **6B** |
| **01_1011** | **RBLTU** | **前向条件跳：`r1 < r2`（无符号）才跳，否则顺序；不入栈** | **控制流** | **4B** | **6F** |

**6 条条件分支统一规则**：
- **连续编码** `01_0110 … 01_1011`：L 偶（bit0=0）、R 奇（bit0=1），**方向一律看 opcode[0]**（同 JAL）
- 条件字段 `[5:2]`：`0110`=EQ、`1000`=NE、`1010`=LTU（L/R 只是 bit0 不同）
- 比较的是寄存器**值**（两层前送后的有效值），不是编号；r1==r2 同号在 EQ 下恒跳
- **条件分支不入栈**：不写 ra、不置 `jmpflg[1]`；只有 JAL 压栈、JALR 出栈（沿用 v6.1 结论）

## 4. 指令编码（6 条件分支统一 4B 布局）

opcode 字节 = `opcode[5:0] << 2 | len[1:0]`，`len = 字节数 − 1`。条件分支与 ALU-R 同宽 4B：

```
条件分支（4B，LBEQ=0x5B / RBEQ=0x5F / LBNE=0x63 / RBNE=0x67 / LBLTU=0x6B / RBLTU=0x6F）：
  byte0 = opcode[5:0] | len=11
  byte1 = bytmov[7:0]                  （条件成立时作跳转偏移，不成立 decoder 输出 0）
  byte2 = r1[7:0]                      （比较操作数 1）
  byte3 = r2[7:0]                      （比较操作数 2）
```

**bytmov 计算（4B 绝对地址式）**：跳转目标 = 跳转指令地址 + 4 ± bytmov（方向同 opcode[0]），
所以 **bytmov = 目标 − (指令地址 + 4)**（R 系）/ **bytmov = (指令地址 + 4) − 目标**（L 系）。
与 JAL 的 `目标 − (地址 + 2)` 同理（基准都是"pc_addr 已越过该指令"，见 §5.2）。

其余类型编码与 v6.1 相同（HALT/NOP 1B、JAL/JALR 2B、ALU-R/I 4B），见 v6.1 §4。

## 5. 流水线机制（v6.2 核心：6 条件分支统一 + 栈保护）

基础时序（if_reg posedge C 锁存 → C+1 id_reg + pc 控制流 → C+2 wr_reg → C+3 写回）与
v6.0/v6.1 相同。旁路转发（rs_alt + result_last）与 BEQ 的两层前送（rd_last1/rd_last2 +
第二读口）在 v6.1 已实现，本版全部沿用，不重复（见 v6.1 §5.1、§5.2）。

### 5.1 6 条条件分支的统一译码（decoder.v）

v6.1 只有 EQ 一条，v6.2 把比较算子参数化，三条分支共用同一套"先算两个操作数的有效值，再比较"：

```verilog
// r1_data_final / r2_data_final：rd_last1（EX 级）+ rd_last2（WB 级）两层前送后的有效值
LBEQ, RBEQ: begin
    addr_d12[15:0] = inst_raw[15:0];
    if (r1_data_final == r2_data_final) begin   // EQ：==
        bytmov = inst_raw[23:16];
        flush1 = 1'b1;
    end
end
LBNE, RBNE: begin
    addr_d12[15:0] = inst_raw[15:0];
    if (r1_data_final != r2_data_final) begin   // NE：!=
        bytmov = inst_raw[23:16];
        flush1 = 1'b1;
    end
end
LBLTU, RBLTU: begin
    addr_d12[15:0] = inst_raw[15:0];
    if (r1_data_final < r2_data_final) begin    // LTU：无符号 <
        bytmov = inst_raw[23:16];
        flush1 = 1'b1;
    end
end
```

- 条件成立：置 `bytmov`（非 0）+ `flush1`（冲刷 1 拍气泡），pc 在下一拍据此跳转
- 条件不成立：bytmov 保持 0、flush1=0 → pc 顺序取指，0 代价
- **LTU 是无符号比较**（`<`），r1/r2 按 8-bit 无符号看待；SLTU 的语义与此一致

### 5.2 条件分支的执行（pc.v：方向靠 opcode[0]，不入栈）

```verilog
LBEQ, RBEQ, LBNE, RBNE, LBLTU, RBLTU: begin
    if (bytmov != 8'b0) begin
        case (op_raw[0])
        1'b0: pc_addr <= pc_addr - bytmov;   // L 系（偶）：后向
        1'b1: pc_addr <= pc_addr + bytmov;   // R 系（奇）：前向
        endcase
    end
    else begin
        if(!frz) pc_addr <= pc_addr + inst_num + 1;   // 条件不成立 → 顺序
    end
end
```

- 跳转基准 `addr + 4`：pc 在 if_reg 锁存条件分支的下一拍执行，此时 `pc_addr` 已越过该 4B 指令
- 6 条共用同一个 case，只靠 `op_raw[0]` 分方向；比较结果已经体现在 `bytmov` 是否为 0 上

### 5.3 返回栈保护（v6.2 核心：满挡压、空挡弹）

**reg_f.v 输出栈满/空标志**：

```verilog
assign j_flag[1] = (j == 8'd255) ? 1'b1 : 1'b0;   // 满：栈指针到 255（已存 255 个返回地址）
assign j_flag[0] = (j == 8'b0)  ? 1'b1 : 1'b0;    // 空：栈指针 0

always @(posedge clk) begin
    if (we && rd != 0) regs[rd] <= rd_data;
    if (jmpflg[1] && ra_in != 0) begin rad[j] <= ra_in; j <= j + 1; end   // JAL 压栈
    else if (jmpflg[0] && j != 8'b0) begin rad[j-1] <= 8'b0; j <= j - 1; end // JALR 弹栈
end
```

**pc.v 挡跳（挡时走顺序路径）**：

```verilog
LJAL, RJAL: begin
    if (bytmov != 8'b0 && !j_flag[1]) begin          // 满栈保护：不压不跳 → 顺序
        ra <= pc_addr;  jmpflg[1] <= 1'b1;
        case (op_raw[0]) 1'b0: pc-bytmov; 1'b1: pc+bytmov; endcase
    end
    else begin if(!frz) pc_addr <= pc_addr + inst_num + 1; end
end
JALR: begin
    jmpflg[0] <= 1'b1;                                // 弹栈请求无条件发（reg_f 用 j!=0 守卫）
    if (!j_flag[0]) begin pc_addr <= ra_in; end        // 空栈保护：不弹不跳 → 顺序
    else begin if (!frz) pc_addr <= pc_addr + inst_num + 1; end
end
```

**decoder.v 的 flush 条件化（关键，顺序路径不能被冲刷）**：

```verilog
LJAL, RJAL: begin
    bytmov = inst_raw[23:16];
    if (!j_flag[1]) flush1 = 1'b1;   // 满栈保护顺序路径不冲刷 → 下一条指令保留
end
JALR: begin
    if (!j_flag[0]) flush1 = 1'b1;   // 空栈保护顺序路径不冲刷
end
```

**为什么必须条件化**：跳转时冲刷是"清掉跳转后不该执行的紧跟指令、造 1 拍气泡"；但保护挡跳时走的是
**顺序路径**，紧跟指令是**本该执行**的——若 flush 无条件发，下一条正确指令被冲成 NOP 丢失。
本轮实测：空栈 JALR 保护后 0x02 的 `ADDI r1` 被冲掉、r1 永不写入（见 §8 调试记录 2）。

**时序一致性**：decoder 的 flush1 在 C..C+1 组合输出、if_reg 在 C+1 采样、pc 在 C+1 也读 j_flag
决定跳不跳——三者读的是同一时刻的 j_flag（j 只在 posedge 更新），不会错位。

### 5.4 控制冒险汇总

| 场景 | flush1 | 净代价 |
|------|--------|--------|
| JAL 正常跳（未满栈） | 1（冲刷气泡） | 1 拍 |
| JAL 满栈保护（顺序） | 0（不冲刷） | 0 |
| JALR 正常跳（非空栈） | 1 | 1 拍 |
| JALR 空栈保护（顺序） | 0 | 0 |
| 条件分支成立（跳） | 1 | 1 拍 |
| 条件分支不成立（顺序） | 0 | 0 |

## 6. 当前程序（测试）

v6.2 用两个专门的测试程序（备份在 `project_self-try.srcs/`）：

**（1）6 条件分支全覆盖测试**（`ins_rom_condbr_backup.hex`）
- 0x00–0x3B：6 条 R 系指令各两场景——条件成立跳转（跳过失败标记 ADDI r9 + HALT）；
  条件不成立顺序执行（误跳则落陷阱区 0x64/0x69/0x6E）
- 0x3C–0x5F：6 条 L 系指令 + SUBI 递减循环——第 1 轮条件成立跳回，第 2 轮不成立跳出
- 0x60：HALT 正常收尾
- 陷阱：r9 一旦被写即说明某条分支跳错了地方

**（2）栈保护测试**（`ins_rom_stack_backup.hex`，当前 `ins_rom.hex`）
```
0x00 JALR        空栈保护：j=0 不跳 → 顺序 0x02
0x06 RJAL 0x18   正常配对：压 ra=0x08 → sub JALR 弹栈返回 0x08
0x10 LJAL 自跳   满栈保护：压栈到 j=255（j_flag[1]）→ 不再压，顺序 0x12
0x12 JALR        深弹栈：255 层弹到 j=0（j_flag[0]）→ 顺序 0x14
0x14 ADDI r4    弹空 + 空栈保护退出后继续
0x18 JALR       sub 主体；0x1A HALT 正常结束
```
预期每遍 `r1=1 r2=2 r3=3 r4=4`；任何一层保护失效 → pc 失控、寄存器不全。

## 7. 仿真验证

编译运行（iverilog，Windows）：

```
cd project_self-try.srcs
/d/iverilog/bin/iverilog -g2012 -o cpu_alu_sim sources_1/new/*.v sim_1/new/single_cpu_top_tb.v
/d/iverilog/bin/vvp cpu_alu_sim
```

> tb 兜底已调到 **30us**：栈测试每遍压栈 255 层 + 深弹栈 255 层各约 5us，两遍共需 ~21us，
> v6.1 的 4us 和初版 20us 都会把第二遍弹栈循环截断（见 §8 调试记录 4）。

**（1）6 条件分支测试**（两遍）：

```
第一遍：r8=1 r1=1 r2=2 | r10: 2→1→0(LBNE) r11: 1→0→255(LBEQ) r12: 2→1→0(LBLTU)
第二遍：同上，r9 两遍都不出现（陷阱未被踩），全程零 X
```

| 检查点 | 验证内容 | 结果 |
|--------|----------|------|
| r9 恒不出现 | 6 条分支"成立跳、不成立顺序"两场景都落对位置，未踩陷阱 | ✓ |
| r10 2→1→0 | LBNE 循环递减跳出（≠ 条件） | ✓ |
| r11 1→0→255 | LBEQ 循环到 0 后回绕 255（== 条件） | ✓ |
| r12 2→1→0 | LBLTU 无符号 < 循环 | ✓ |
| 两遍一致 | 停机复位重跑无回归 | ✓ |

**（2）栈保护测试**（两遍）：

```
第一遍：r1=1(65ns) r2=2(115) r3=3(125) r4=4(10355) → HALT
第二遍：r1=1(10435) r2=2(10485) r3=3(10495) r4=4(20725) → HALT（$finish 正常收尾）
```

| 检查点 | 验证内容 | 结果 |
|--------|----------|------|
| r1=1 | 空栈 JALR 保护生效，顺序到 0x02 且指令未被冲刷 | ✓ |
| r2=2 r3=3 | 正常 JAL/JALR 配对压栈/弹栈 | ✓ |
| r4=4（每遍只一次） | 满栈 LJAL 保护 + 0x12 JALR 深弹栈弹空 + 空栈保护退出，全链路 | ✓ |
| 两次 HALT | 深弹栈后正常走到 0x1A | ✓ |

## 8. 调试记录

### 调试记录 1：pc.v 的 j_flag 误声明成 output（读自己的恒 X）

- **现象**：加栈保护后 JAL 顺序不跳、JALR 不跳但弹栈；`!j_flag` 恒假
- **根因**：pc.v 里 `output reg [1:0] j_flag`——pc 读自己的输出 reg（未初始化恒 X），
  `!j_flag[1]` 恒 0/0、`!j_flag[0]` 恒假；且 top 里 j_flag 同时被 pc 驱动又连到 reg_f 输出，双驱动 wire 恒 X
- **修复**：改为 `input wire [1:0] j_flag`，由 reg_f 单点输出
- **教训**：新增通路的端口方向先对着数据流想一遍：j_flag 是"reg_f 产、pc/decoder 消费"

### 调试记录 2：JAL/JALR 无条件 flush1 → 栈保护顺序路径丢下一条指令

- **现象**：栈测试空栈 JALR 保护顺序到 0x02，但 `ADDI r1` 不写；DEBUG_TRACE 显示 0x02 处译码成
  NOP（气泡）而非 ADDI
- **根因**：decoder 对 JAL/JALR 无条件 `flush1=1`。保护挡跳时 pc 走顺序路径，紧跟指令是**本该执行**
  的，但 flush 把它冲成 NOP 永久丢失（r1 永不写入）。满栈 JAL 保护顺序路径同理会丢下一条
- **修复**：decoder 增加 `j_flag` 输入，flush 条件化——JAL 仅 `!j_flag[1]`、JALR 仅 `!j_flag[0]`
  时发；保护（顺序路径）时不冲刷
- **验证**：修复后栈测试每遍 r4 只写一次（0x12 JALR 深弹栈正常启动），不再有"满栈保护后 + 弹空后
  各执行一次 0x14 ADDI r4"的冗余

### 调试记录 3：LBEQ/RBEQ 的 flush1 被误加 `j_flag[1]` 条件

- **现象**：修调试记录 2 时误把 `if (j_flag[1]) flush1 = 1'b1;` 抄进 LBEQ/RBEQ 分支
- **后果**：EQ 条件成立跳转时，正常（未满栈）flush1=0 → 不冲刷 → 跳转后紧跟指令被错误执行，
  6 条件分支测试第一遍 `r9=1`（陷阱被踩）
- **修复**：回退为条件成立就 `flush1 = 1'b1;`（与 NE/LTU 一致）
- **验证**：6 条件分支测试 r9 两遍都不出现

### 调试记录 4：栈测试满栈需要 5100ns，4us 兜底不够

- **现象**：满栈测试只写 r2/r3，r4 不出现；仿真停在 4us 兜底
- **根因**：LJAL 自跳每 2 拍压 1 层栈（跳转 1 拍气泡），j 从 0 到 255 需 ~5100ns；加上深弹栈
  255 层再 ~5100ns，第一遍 ~10.3us，第二遍复位后 ~21us。4us 兜底远不够（初版调 20us 仍把
  第二遍弹栈循环截断，日志尾部看着像死循环）
- **修复**：tb 兜底 `#4000` → `#30000`；DEBUG_TRACE 增加 j/ra/j_flag 打印便于观察栈指针

## 9. 相对 v6.1 的变化汇总

| # | 变化 | 状态 |
|---|------|------|
| 1 | 条件分支 2 → **6 条**：+LBNE/RBNE/LBLTU/RBLTU，RBEQ 重编码到 01_0111 | ✓ 已实现并验证 |
| 2 | 条件分支**统一编码**：连续段 01_0110–01_1011，方向靠 opcode[0]，L 偶/R 奇 | ✓ 已实现 |
| 3 | 条件分支统一译码模板：EQ `==` / NE `!=` / LTU `<`（无符号），共用两层前送 | ✓ 已实现并验证 |
| 4 | **返回栈满/空保护**：j_flag[1]=满(j==255)、j_flag[0]=空(j==0) | ✓ 已实现并验证 |
| 5 | pc 挡跳：JAL 满栈不压栈跳、JALR 空栈不弹栈跳，挡时走顺序路径 | ✓ 已实现并验证 |
| 6 | **decoder flush 条件化**：JAL 仅 `!j_flag[1]`、JALR 仅 `!j_flag[0]` 才冲刷 | ✓ 已实现并验证 |
| 7 | 栈深 64 → **256**（rad[0:255]） | ✓ 已实现 |
| 8 | 指令集 23 → **27 条**（+4 条件分支、RBEQ 改码） | ✓ 已实现 |
| 9 | 修复 pc.v j_flag 误声明 output（读恒 X） | ✓ 已修复 |
| 10 | 修复无条件 flush1 冲掉栈保护顺序路径指令 | ✓ 已修复 |
| 11 | 6 条件分支全覆盖测试 + 栈保护测试（空栈/满栈/深弹栈）两套 | ✓ 已通过 |

## 10. 已知限制

| 限制 | 说明 |
|------|------|
| 转发只覆盖**紧邻上一条** | `rs_alt` 只比较 rd_last1；间隔 ≥1 条靠写回；条件分支有专门两层前送 |
| 条件分支仍固定 1 拍气泡 | 条件成立时 flush 1 拍；不成立 0 代价。无分支预测 |
| 条件分支 8-bit bytmov | 前/后向跳转范围 ±255 字节 |
| 栈深固定 255 | j 满 255 挡压栈，不会回绕；但递归超过 255 层会"假满"停在原地 |
| 连续 JALR 读同一栈顶 | 栈顶只写一次、连续弹两次会重复读同一地址（未触发） |
| 空栈 JALR 保护后的语义 | 空栈 JALR 顺序执行（不再越界读），但程序需自行保证配平，保护不修正逻辑错误 |
| HALT 只冻结 1 拍 | 冻结后 pc 漂到未定义区（X），靠 tb 收尾掩盖；写已提交无副作用 |
| reg_f 无复位 | 寄存器与返回栈指针复位后保留；配平程序可用，不配平会错位 |
| 3B 长度编码保留未用 | len=`10` 无指令占用 |
| 无算术右移 | SRA/SRAI 已删，需接 `$signed` 才有真算术右移 |
| 无性能统计 | 尚未统计 CPI/IPC，未测吞吐上限 |

## 11. 后续规划

- [x] 数据旁路转发（EX→ID 前送，去掉紧邻 NOP）—— v6.1
- [x] 条件分支（LBEQ/RBEQ）—— v6.1
- [x] 条件分支扩展到 6 条（EQ/NE/LTU × L/R，统一编码）—— v6.2
- [x] 返回栈满/空保护（满挡压、空挡弹、flush 条件化）—— v6.2
- [ ] 跳转预测（取指时提前算目标，减少/消除 1 拍气泡）
- [ ] 连续 JALR 读同一栈顶的处理
- [ ] 寄存器组复位与 DDR 接线（届时给 reg_f 加 rst/端口）
- [ ] 指令吞吐/CPI 统计（评估流水线收益）

---

*本文件随项目演进同步更新。*
