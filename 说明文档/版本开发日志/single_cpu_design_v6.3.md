# 流水线 CPU 设计记录（v6.3 —— 访存指令 + 寄存器堆读路径重构）

> 版本：2026-08-12  ·  在 v6.2 的 6 条件分支 + 返回栈保护基础上，
> **新增数据存储器 data_ram 与 LBU/SB 两条访存指令**（指令集 27 → **29 条**），
> 并把**寄存器堆读路径集中到 decoder 内部**（reg_f 只做存储，译码/前送全在 decoder）。
> v6.2 见 [single_cpu_design_v6.2.md](single_cpu_design_v6.2.md)

## 0. 版本说明

架构仍是 v6.2 的 4 级流水（IF/ID/EX/WB 每拍推进）+ EX 级旁路转发 + 栈保护。本次三件事：

| 维度 | v6.2 | v6.3（当前代码） |
|------|------|------------------|
| 访存 | 无（纯寄存器运算 + 控制流） | **data_ram（8192×8）** + **LBU / SB** 两条访存指令 |
| 指令数 | 27 条 | **29 条**（+LBU=01_1100、+SB=01_1101） |
| reg_f 读路径 | reg_f 内部译码 r1/r2 读，decoder 另取 | **读路径集中到 decoder**：reg_f 只按 decoder 给的 24-bit 读地址组合读出，decoder 做全部前送 |
| load-use | 无 load | **数据旁路进 ALU**：LBU 结果在 EX 级即可用，紧跟指令经 `result_last` 前送链零气泡拿到 |
| data_ram 写 | — | SB 用 decoder 组合写使能，**ID 级拍沿直接落盘**（不过 id_reg） |

## 1. 总体架构（v6.2 + data_ram + 读路径集中）

```
clk/rst ─▶ fsm ── stage（1-bit：EXE/IDLE）──▶ 广播到 if_reg / id_reg / wr_reg / pc

  ┌──────── IF ────────┬──────── ID ────────┬──────── EX ────────┬──── WB ────────┐
  │ pc ──▶ ins_rom     │ decoder（组合译码） │ alu（组合运算）     │ wr_reg          │
  │        │ 4B 窗口   │   reg_f 读(组合)    │   ▲                │  ▾ 下一拍写回    │
  │        ▼           │   + 两层前送        │   └─ result_last ──┘  reg_f 写        │
  │      if_reg ──────▶│   + j_flag 栈保护   │   └─ ram_data（LBU 旁路）               │
  │        （取指寄存器） │   + addr_ram/ram_flag│                                        │
  └──────────────────────────────────────────────────────────────────────────────┘
        data_ram ◀── decoder（addr_ram / wdata / ram_flag[0]=SB 写使能，ID 级落盘）
        data_ram ──▶ alu（ram_data，LBU 同步读出后 EX 级可用）
        reg_f ◀── decoder（addr_r12 24-bit 读地址）──▶ decoder（rr12_data 组合读回）
```

**相对 v6.2 新增/改动的结构**：
1. **data_ram**：8192×8 同步读 RAM，端口 `clk / we_ram / addr_ram[12:0] / wdata / rdata`。
   - **读**：`rdata <= mem[addr_ram]`（ID 级 posedge 锁存），下一拍（EX 级）数据稳定，正好被 alu 的
     LBU 旁路用到——与 wr_reg 在 WB 级采样的道理同理，天然对齐，不额外插气泡。
   - **写**：`we_ram = ram_flag1[0]`（decoder **组合**输出，不过 id_reg），SB 在 ID 级 posedge
     就写进内存，比读落地更早一拍。
2. **寄存器堆读路径集中**：decoder 输出 24-bit 读地址 `addr_dr12 = {r_ram, r1, r2}`（指令 byte1/2/3），
   reg_f 按地址**组合读出** `rr12_data`，回喂 decoder；decoder 内部完成 rd_last1（EX）/rd_last2（WB）
   两层前送 + rs_alt 生成。id_reg 不再参与操作数读取，只透传译码结果（opcode/rd/imm/ab_raw/rs_alt/ram_flag）。
3. **load-use 数据旁路**：alu 增加 `ram_flag_in`、`ram_data` 端口，`if (ram_flag_in[1]) result = ram_data;`
   ——LBU 在 EX 级直接把内存数据当结果输出，紧跟指令通过 `result_last` 前送链拿到，**零气泡**。
   （相比教科书常用的 load-use stall，用旁路省掉 1 拍空泡。）

## 2. 运行控制：1-bit stage（EXE/IDLE）

与 v6.2 相同，未变：fsm 退化为运行/停机锁存，`rst → EXE`、`frz（HALT 译码）→ IDLE`、否则 EXE。
所有流水寄存器只在 `stage == EXE` 推进。

## 3. 指令集（6-bit opcode，29 条）

在 v6.2 的 27 条基础上：新增 **LBU**（01_1100）、**SB**（01_1101）。加粗为相对 v6.2 有变/新增：

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
| 01_0110 | LBEQ | 后向条件跳：`r1 == r2` 才跳；不入栈 | 控制流 | 4B | 5B |
| 01_0111 | RBEQ | 前向条件跳：`r1 == r2` 才跳；不入栈 | 控制流 | 4B | 5F |
| 01_1000 | LBNE | 后向条件跳：`r1 != r2` 才跳；不入栈 | 控制流 | 4B | 63 |
| 01_1001 | RBNE | 前向条件跳：`r1 != r2` 才跳；不入栈 | 控制流 | 4B | 67 |
| 01_1010 | LBLTU | 后向条件跳：`r1 < r2`（无符号）才跳；不入栈 | 控制流 | 4B | 6B |
| 01_1011 | RBLTU | 前向条件跳：`r1 < r2`（无符号）才跳；不入栈 | 控制流 | 4B | 6F |
| **01_1100** | **LBU** | **rd = mem[13-bit 地址]**（内存读） | **访存** | **4B** | **73** |
| **01_1101** | **SB** | **mem[13-bit 地址] = 寄存器值**（内存写） | **访存** | **4B** | **77** |

LBU/SB 与其他指令一样按 4B 连续取指（inst_num=3）。数据存储器与指令 ROM 物理独立
（ins_rom 是只读指令区，data_ram 是读写数据区），地址空间各自独立、互不重叠。

## 4. 指令编码（访存指令 4B 布局）

LBU/SB 同为 4B，地址字段复用 byte2:byte3 的 **低 13 位**（`addr_ram = inst_raw[15:3]`）：

```
LBU（4B，byte0=0x73）：
  byte0 = opcode[5:0] | len=11
  byte1 = rd[7:0]                 （写回目标寄存器）
  byte2:byte3[15:3] = 13-bit 地址  （inst_raw[15:3]，即 {byte2, byte3[7:3]}）

SB（4B，byte0=0x77）：
  byte0 = opcode[5:0] | len=11
  byte1 = rs[7:0]                 （数据源寄存器：把 rs 的值写进内存）
  byte2:byte3[15:3] = 13-bit 地址  （inst_raw[15:3]，即 {byte2, byte3[7:3]}）
```

**地址 13 位编码**：`addr_ram = inst_raw[15:3]` = `{byte2[7:0], byte3[7:3]}`，
等价 `地址 = byte2 << 5 | byte3[7:3]`（byte2 是高 8 位、byte3 高 5 位是低 5 位）。
**byte3 的低 3 位丢弃**（13 位只用到 bit15..3，见 §10 已知限制）。

例如写地址 5：`byte2=0x00, byte3=0x28`（0x28>>3 = 5）；读地址 100：`byte2=0x03, byte3=0x20`（3<<5+4=100）。

## 5. 流水线机制（v6.3 核心：访存数据通路 + 读路径集中）

基础时序（if_reg posedge C 锁存 → C+1 id_reg + pc 控制流 → C+2 wr_reg → C+3 写回）与
v6.2 相同；条件分支统一译码、栈保护、flush 条件化均未变（见 v6.2 §5.1–§5.4），不重复。

### 5.1 寄存器堆读路径集中（decoder.v + reg_f.v 重构）

v6.2 里 reg_f 自己按 inst_raw 切 r1/r2 去读，decoder 另做前送判断。v6.3 改为：

```verilog
// decoder：把 byte1/2/3 拼成 24-bit 读地址交给 reg_f
output reg [23:0] addr_dr12;              // = {r_ram, r1, r2}（指令 byte1/byte2/byte3）
// reg_f：纯存储，按地址组合读
wire [7:0] r_ram = addr_r12[23:16], r1 = addr_r12[15:8], r2 = addr_r12[7:0];
assign rr12_data[23:16] = (r_ram == 8'b0) ? 0 : regs[r_ram];
assign rr12_data[15:8]  = (r1    == 8'b0) ? 0 : regs[r1];
assign rr12_data[7:0]   = (r2    == 8'b0) ? 0 : regs[r2];
// decoder：读回 rr12_data 后做两层前送（rd_last1=EX、rd_last2=WB）
wire [7:0] r1_data_final = (rd_last1 != 0 && r1 == rd_last1) ? result_last_in : r1_data_imm;
wire [7:0] r2_data_final = (rd_last1 != 0 && r2 == rd_last1) ? result_last_in : r2_data_imm;
wire [7:0] rr_data_final = (rd_last1 != 0 && r_ram == rd_last1)? result_last_in : rr_data_imm;
```

- **新增的 `r_ram`**（byte1 字段）是 LBU/SB 用的第三个读口：LBU 不需要、SB 用它当写数据源。
  前送逻辑与 r1/r2 完全同构（`rd_last1`/`rd_last2` 两层），所以 SB 存紧跟 ALU 刚算出的寄存器时
  也能拿到正确值（实测验证，见 §7）。
- reg_f 的三个读口都是**组合读**（`assign`），不推 BRAM；data_ram 才是同步读（§5.2）。
- 该重构消除了 id_reg 与 reg_f 之间的操作数搬运，读地址/前送统一在 decoder 一处。

### 5.2 访存数据通路（data_ram.v）

```verilog
module data_ram(clk, we_ram, addr_ram[12:0], wdata, rdata);
    reg [7:0] mem [0:8191];                       // 8192 × 8
    always @(posedge clk) begin
        if (we_ram) mem[addr_ram] <= wdata;        // 写：ID 级 posedge 落盘
        rdata <= mem[addr_ram];                    // 读：同步读，下一拍出数据
    end
```

**读（LBU）时序**：
- ID 级：decoder 输出 `addr_ram` + `ram_flag[1]=1`（读标志）
- ID 级 posedge：data_ram 同步锁存 `rdata <= mem[addr_ram]`
- EX 级：rdata 稳定 → alu `if (ram_flag_in[1]) result = ram_data` → wr_reg WB 级锁存 → 写回

**写（SB）时序**：
- ID 级：decoder 输出 `addr_ram`、`wdata`（= rr_data_final，含两层前送）、`ram_flag[0]=1`（写标志）
- **同一拍 ID 级 posedge**：data_ram `if (we_ram) mem[addr_ram] <= wdata` 直接写入
  （`we_ram = ram_flag1[0]` 是 decoder 组合输出，不过 id_reg，所以 SB 比 LBU 早一拍落地）

**ram_flag 传递链路**（decoder → id_reg → wr_reg/alu）：
```verilog
// id_reg 需透传 ram_flag（否则恒 X，见 §8 调试记录 1）
if (!flush_in) ram_flag <= ram_flag_in;   else ram_flag <= 2'b0;
// wr_reg：LBU 时 rd_data 选内存数据
rd_data <= (ram_flag_in[1] == 1'b1) ? ram_data_in : result_in;
```

### 5.3 load-use 数据旁路（alu.v）

教科书方案是检测 load 后紧跟使用 → 插入 1 拍气泡（stall）。这里用**旁路**替代，零气泡：

```verilog
module alu(..., input wire [1:0] ram_flag_in, input wire [7:0] ram_data, ...);
always @(*) begin
    if (ram_flag_in[1]) result = ram_data;   // LBU：直接透传内存数据
    else case (opcode) ... 原有 ALU 运算 ... endcase
end
```

- LBU 在 EX 级就把 `ram_data` 当 result 输出；紧跟指令在 EX 级读 `result_last`（前送）即拿到 load 数据。
- 条件：`ram_data` 必须在 EX 级稳定——data_ram 是同步读，ID 级 posedge 锁存、EX 级稳定，恰好满足。
- 代价：alu 的 case 被套了一层 `if (ram_flag_in[1])`，LBU 独占 EX 级一个周期（不影响，本来就有流水槽）。

### 5.4 访存指令对 flush/栈保护的兼容

- LBU/SB **不置 flush1、不置 frz、不触发跳转**（decoder 的 case 里只有访存字段赋值），对 pc/栈零影响。
- SB 不需要写回寄存器（we=0），LBU 需要（we=1，见 §8 调试记录 2）。
- 访存地址来自指令内立即数字段（byte2:byte3），不经过寄存器堆，**无地址前送问题**；
  SB 的**数据**（wdata）走 `rr_data_final` 前送链，与 ALU 操作数同套机制。

## 6. 当前程序（测试）

**（1）load/store 全场景测试**（v6.3 新增，手工拼字节）：

```
@0000
07 01 00 55 77 01 00 28 73 02 00 28 07 04 02 01
73 03 00 28 00
```

| 地址 | 指令 | 作用 |
|------|------|------|
| 0x00 | ADDI r1,r0,0x55 | 准备写数据 0x55 |
| 0x04 | SB [5] = r1 | **紧跟** ADDI，r1 尚未写回 → 验证 SB 数据前送 |
| 0x08 | LBU r2,[5] | 读回 → 应为 0x55 |
| 0x0C | ADDI r4,r2,1 | **紧跟** LBU 使用 r2 → 验证 load-use 旁路（应 0x56） |
| 0x10 | LBU r3,[5] | 再读（正常路径） |
| 0x14 | HALT | 收尾 |

预期每遍 `r1=0x55 r2=0x55 r4=0x56 r3=0x55`；`r3=0` 校验读未初始化区。

**（2）栈保护回归测试**（`ins_rom.hex` 当前内容，v6.2 同款）：
空栈 JALR 保护 → 正常配对 → 满栈 LJAL 自跳（j=255）→ 深弹栈 255 层 → 空栈退出。
预期每遍 `r1=1 r2=2 r3=3 r4=4`。备份在 `Justin_CPU_v6.2_resv/ins_rom.hex`。

## 7. 仿真验证

编译运行（iverilog，Windows）同 v6.2（tb 兜底 30us 未变）。

**（1）load/store 测试**（两遍）：

```
第一遍：r1=85(55ns) r2=85(75ns) r4=86(85ns) r3=85(95ns) → HALT
第二遍：同值（r1=85 r2=85 r4=86 r3=85）→ $finish 正常收尾
```

| 检查点 | 验证内容 | 结果 |
|--------|----------|------|
| r1=85 | ADDI 正常 | ✓ |
| r2=85 | **SB 写 → LBU 读回** 0x55，数据通路打通 | ✓ |
| r2=85（而非 0） | **SB 紧跟 ADDI 前送**：r1 未写回也能存对值 | ✓ |
| r4=86 | **load-use 数据旁路**：LBU 紧跟使用 = 0x55+1 | ✓ |
| r3=85 | 二次 LBU 正常 | ✓ |
| 两遍一致 | 复位重启无回归 | ✓ |

**（2）栈保护回归**（两遍）：

```
第一遍：r1=1(65ns) r2=2(115) r3=3(125) r4=4(10355) → HALT
第二遍：r1=1(10435) r2=2(10485) r3=3(10495) r4=4(20725) → $finish
```

读路径重构 + data_ram 接入后，栈保护全链路（空/满/深弹栈 + flush 条件化）无回归。

### 7.1 综合与时序（Vivado 2019.1，xc7z010clg400-1）

50MHz（period 20ns）下 **WNS = 6.24ns**（关键路径 ≈13.76ns，理论最高 ~72MHz），时序收敛无需优化。
综合前做了三件事保证结果有效：顶层加 8 个调试输出端口、ins_rom 内置 `$readmemh` 初始化（否则
空 ROM 让 opcode 恒 HALT、整机被常量传播优化掉）、`constrs_1/new/timing.xdc` 加时钟约束
（否则时序路径全 0ns）。

## 8. 调试记录

### 调试记录 1：id_reg 声明了 ram_flag 但从不赋值 → 全 X

- **现象**：重构后**所有**寄存器写回都变 X（r1=r2=r3=r4 全 X），原测试全崩
- **根因**：id_reg 端口有 `output reg [1:0] ram_flag`，但 `always` 的两个分支（if/else）都**没给
  ram_flag 赋值** → 恒 X → wr_reg 的 `(ram_flag_in[1]==1) ? ram_data_in : result_in` 三目遇 X 返回 X
  → rd_data=X → regs 全 X
- **修复**：if 分支补 `ram_flag <= ram_flag_in;`、flush 分支补 `ram_flag <= 2'b0;`
- **教训**：新增输出口先确认 always 里每一分支都驱动到；声明了 `output reg` 却无赋值是最隐蔽的 X 源

### 调试记录 2：LBU 缺 `we=1`，load 结果写不进寄存器堆

- **现象**：修好 ram_flag 后 LBU 数据到 wr_reg 了，但 reg_f 不写
- **根因**：decoder 的 LBU 分支只置了 addr_ram/ram_flag，没置 we；wr_reg 的 `we<=we_in` 传 0
- **修复**：LBU 分支加 `we = 1'b1;`（SB 不需要，we 保持 0）

### 调试记录 3：store 写使能 we_ram 全链路缺失

- **现象**：SB 编译能过但 store 永不写内存
- **根因**：data_ram 有 `we_ram` 端口，但 top 例化时 `.we_ram()` 没接（悬空）；整个设计没有任何
  store 写使能信号传到 data_ram。悬空 = X → `if (we_ram)` 永假
- **修复**：top 里 `we_ram(ram_flag1[0])`——decoder 组合输出 SB 写标志，ID 级 posedge 直接落盘
- **设计决策**：we_ram 特意**不过 id_reg**（SB 在 ID 级就写，比读早一拍；若走 id_reg 会晚一拍，
  LBU 紧跟 SB 读时会读到旧值）

### 调试记录 4：alu 笔误 `result = ram_flag_in`（应为 ram_data）

- **现象**：load-use 旁路实现后，LBU 结果 = 2 而非内存值（r2=2、r4=3）
- **根因**：alu 的 `else result = ram_flag_in;` ——把 2-bit 标志量当 8-bit 数据塞进 result
  （LBU 时 ram_flag=2'b10 → result=2）
- **修复**：改一行 `result = ram_data;`
- **验证**：r2=85 r4=86 恢复

## 9. 相对 v6.2 的变化汇总

| # | 变化 | 状态 |
|---|------|------|
| 1 | **data_ram**：8192×8 同步读 RAM，13-bit 地址，`clk/we_ram/addr_ram/wdata/rdata` | ✓ 已实现并验证 |
| 2 | **LBU / SB** 两条访存指令（01_1100 / 01_1101），指令集 27 → **29** | ✓ 已实现并验证 |
| 3 | 访存 4B 布局：byte1=rd(LBU)/源寄存器(SB)，byte2:byte3[15:3]=13-bit 地址 | ✓ 已实现 |
| 4 | **寄存器堆读路径集中到 decoder**：reg_f 只存不译，addr_r12 24-bit 读地址 + rr12_data 组合回读 | ✓ 已实现并验证 |
| 5 | **第三个读口 r_ram**（byte1 字段）+ rr_data_final 前送，供 SB 数据源 | ✓ 已实现并验证 |
| 6 | **SB 写使能组合直连**：we_ram=ram_flag1[0]，ID 级 posedge 落盘 | ✓ 已实现并验证 |
| 7 | **ram_flag 链路**：decoder→id_reg→wr_reg（选 rd_data）/alu（旁路） | ✓ 已实现 |
| 8 | **load-use 数据旁路**：alu 透传 ram_data，紧跟指令零气泡拿到 load 结果 | ✓ 已实现并验证 |
| 9 | 修复 id_reg ram_flag 恒 X、LBU 缺 we、we_ram 悬空、alu 笔误（调试记录 1–4） | ✓ 已修复 |
| 10 | load/store 全场景测试 + 栈保护回归测试 | ✓ 已通过 |

## 10. 已知限制

| 限制 | 说明 |
|------|------|
| 访存地址只 **13 位** | `addr_ram = inst_raw[15:3]`，**byte3 低 3 位丢弃**（地址 = byte2<<5 \| byte3[7:3]），4B 指令里只用了 16 个地址位的高 13 位 |
| data_ram 同步读 + SB 组合写使能 | 读写**不对称**：SB 在 ID 级 posedge 落盘，LBU 数据 EX 级才稳定；同地址"写后紧跟读"在 LBU 相对 SB 间隔 ≥1 拍时正确，同拍读写未定义 |
| load-use 靠旁路而非 stall | 依赖 `ram_data` 在 EX 级稳定（当前满足）；若日后 data_ram 改更深流水（多级读延迟），旁路会失效，需改 stall |
| data_ram **无复位** | 复位重启后内存内容保留（栈保护/load-store 测试正好利用），程序需自行保证 |
| SB 数据前送只覆盖 rd_last1 | 间隔 ≥1 条靠写回（与 ALU 操作数同套机制） |
| 读未初始化区 = x | data_ram 未写单元仿真中是 0（初始化循环已全清 0..8191），但综合后 BRAM 上电为 x，程序应避免读未初始化单元 |
| 其余 v6.2 限制沿用 | 条件分支 1 拍气泡、栈深 255 假满、无分支预测等，见 v6.2 §10 |

## 11. 后续规划

- [x] 数据旁路转发（EX→ID 前送）—— v6.1
- [x] 条件分支 6 条统一编码 —— v6.2
- [x] 返回栈满/空保护 —— v6.2
- [x] 访存指令 LBU/SB + data_ram —— v6.3
- [x] 寄存器堆读路径集中到 decoder —— v6.3
- [x] load-use 数据旁路（零气泡） —— v6.3
- [ ] 访存地址扩展（byte3 低 3 位用起来，或改寄存器基址寻址）
- [ ] data_ram 换 BRAM IP / 同步读推 BRAM（当前手写同步读模板，综合可推断）
- [ ] 跳转预测（消除 1 拍气泡）
- [ ] 寄存器组复位与 DDR 接线

---

*本文件随项目演进同步更新。*
