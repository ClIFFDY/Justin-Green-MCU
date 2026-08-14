# 多周期 CPU 设计记录（v4.2 —— 控制流重构：LJAL/RJAL/JALR + 返回地址栈 + 3 状态 FSM）

> 版本：2026-08-11  ·  在 v4.1 基础上重构控制流与状态机（跳转机制、FSM 状态数、写回路径均有改动）
> v4.1 见 [single_cpu_design_v4.1.md](single_cpu_design_v4.1.md)，v4.0 见 [single_cpu_design_v4.0.md](single_cpu_design_v4.0.md)
> v4.2 之后编码方案重构（opcode 低 2 位声明长度 + 无填充 + 4 状态 FSM）→ [single_cpu_design_v5.0.md](single_cpu_design_v5.0.md)

## 0. 版本说明

沿用 v3.0 第 0 节定下的标准——架构变则大版本。本次改动在"跳转/调用/返回"这一控制流主线上：

| 维度 | v4.1 | v4.2（当前代码） |
|------|------|------------------|
| FSM | 4 状态 IDLE→FET→OPR→WRT | **3 状态 IDLE→FET→NEX**（OPR/WRT 合并，写回改由 wreg 完成） |
| 跳转指令 | LJMP/RJMP（4 字节，bytnum 计数返回） | **LJAL/RJAL（3 字节）+ JALR（3 字节，返回栈出栈）** |
| 返回机制 | bytnum 延迟计数 | **返回地址栈 rad[0:15] + 栈指针 j** |
| 写回路径 | reg_f 直接接收 ALU 结果 | **新增 wreg 模块**（写回级寄存器，NEX 拍锁存） |
| 指令集 | 19 条（16 ALU + LJMP/RJMP） | **20 条**（新增 JALR=01_0011） |

状态机、返回机制、写回路径三处都动了，按规则可算大版本；但 6-bit opcode 框架、
变长标签编码思路不变，仍记 **v4.2** 作为 v4.x 内部的一次控制流演进。

## 1. 总体架构

```
clk/rst
   │
   ├─▶ fsm ────── stage[1:0]（IDLE/FET/NEX）广播到 pc / decoder / ir / wreg
   ├─▶ pc ──────▶ ins_rom ─▶ inst ─▶ decoder（逐字节译码）──▶ ir（NEX 锁存）
   │    │  jmpwe / jmpred / ra        │ addr1/addr2/rd/opcode/imm/we
   │    └─◀────── reg_f.ra（组合栈顶） │
   │                │                  ▼
   │              reg_f  ◀──── alu ◀── ir 输出的操作数 / opcode
   │              ▲  写回数据 rd_data/rd/we 来自 wreg（NEX 锁存 ALU 结果）
   └─ reg_f 内返回栈 rad[0:15]：jmpwe 入栈、jmpred 出栈
```

一条指令流程：**FET 拍变长取指（逐字节）→ NEX 拍 ir 锁存 + ALU 运算 + wreg 锁存结果 →
下一拍 reg_f 写回**。跳转在 NEX 拍由 pc 完成，入/出栈在下一拍由 reg_f 完成。

## 2. FSM（3 状态 + 变长取指 + frz 冻结）

```
IDLE(00) → FET(01) → NEX(10) → FET …
    ↑
    └──── HALT 时 frz=1，NEX 拍回 IDLE 并关写（we=0）────
```

| 状态 | 动作 |
|------|------|
| IDLE | `!frz` 时进 FET（HALT 后停在这里） |
| FET | 取当前字节；`inst_raw[1:0] != 2'b11` 就留在 FET 继续取下一字节；读到标签 11 → 进 NEX |
| NEX | ir 锁存译码结果、wreg 锁存 ALU 结果；pc 依 opcode 执行跳转；遇 frz → 回 IDLE |

变长取指：ALU 指令 4 拍、JAL 类 3 拍、HALT 2 拍，均以标签 11 的字节收尾。

## 3. 指令集（6-bit opcode，20 条）

| 编码 | 助记符 | 行为 | 归属 | 长度 |
|------|--------|------|------|------|
| 00_0000 | HALT | 冻结整机（frz=1） | 控制 | 2B |
| 00_0001 | ADDI | rd = rs1 + imm8 | ALU | 4B |
| 00_0010 | ADD  | rd = rs1 + rs2 | ALU | 4B |
| 00_0011 | SUBI | rd = rs1 - imm8 | ALU | 4B |
| 00_0100 | SUB  | rd = rs1 - rs2 | ALU | 4B |
| 00_0101 | AND  | rd = rs1 & rs2 | ALU | 4B |
| 00_0110 | OR   | rd = rs1 \| rs2 | ALU | 4B |
| 00_0111 | XOR  | rd = rs1 ^ rs2 | ALU | 4B |
| 00_1000 | LJAL | 后向跳转（addr − bytmov）且入栈返回地址 | 控制流 | 3B |
| 00_1001 | RJAL | 前向跳转（addr + bytmov）且入栈返回地址 | 控制流 | 3B |
| 00_1010 | ANDI | rd = rs1 & imm8 | ALU | 4B |
| 00_1011 | ORI  | rd = rs1 \| imm8 | ALU | 4B |
| 00_1100 | XORI | rd = rs1 ^ imm8 | ALU | 4B |
| 00_1101 | SLL  | rd = rs1 << rs2 | ALU | 4B |
| 00_1110 | SRL  | rd = rs1 >> rs2 | ALU | 4B |
| 00_1111 | SLLI | rd = rs1 << imm8 | ALU | 4B |
| 01_0000 | SRLI | rd = rs1 >> imm8 | ALU | 4B |
| 01_0001 | SLTU | rd = (rs1 < rs2) ? 1 : 0 | ALU | 4B |
| 01_0010 | SLTIU | rd = (rs1 < imm8) ? 1 : 0 | ALU | 4B |
| 01_0011 | JALR | rd = 无；pc ← 返回栈栈顶（出栈） | 控制流 | 3B |

- 编码 00_0000–01_0011 连续无空位；寄存器 6-bit 地址 → 64 个，r0 恒读 0、写入跳过
- 跳转三指令语义：**LJAL/RJAL = 跳转 + 入栈**（保存返回地址），**JALR = 出栈返回**，
  合起来构成"调用/返回"（call/ret），可嵌套

## 4. 指令编码

每字节 `[1:0]` 是标签，指示该字节装什么：

| 标签 | ALU 指令 | LJAL / RJAL | JALR |
|------|----------|-------------|------|
| 00 | opcode = [7:2] | opcode = [7:2] | opcode = [7:2] |
| 01 | rd = [7:2] | bytmov_h = [7:2] | 任意（tag 01） |
| 10 | addr1 = [7:2] | — | — |
| 11 | 依 opcode：RR 型 addr2 / 立即数型 imm8 | bytmov = {bytmov_h, [7:6]} | tag 11 收尾 |

LJAL 前跳 22 字节（bytmov = {000101, 10} = 22）示例：
```
byte0  001001_00   opcode = 00_1001（RJAL）
byte1  000101_01   bytmov_h = 000101
byte2  100000_11   bytmov 低 2 位 = 10，tag 11
```
方向由 opcode[0] 决定：LJAL（0）减、RJAL（1）加。JALR 不携带操作数，byte1 任意。

## 5. JAL 执行机制

### pc.v（NEX 拍触发跳转）

```
FET 拍：jmpwe<=0; jmpred<=0; pc_addr<=pc_addr+1
NEX 拍：
  LJAL/RJAL：ra<=pc_addr; jmpwe<=1; pc_addr <= pc_addr ± bytmov（opcode[0]=0 减 / =1 加）
  JALR    ：jmpred<=1; pc_addr <= ra_in（来自 reg_f.ra）
```

- `ra` 是 pc 内部暂存"返回地址"（= 跳转指令取完后的 PC），随 jmpwe 一起交给 reg_f 入栈
- `ra_in` 是 reg_f 组合输出的栈顶，JALR 一拍读到

### reg_f.v（返回地址栈 + 入/出栈）

```verilog
assign ra = rad[j - 1];                 // ra = 栈顶，组合输出（不被时钟清零）

always @(posedge clk) begin
    if (we && rd != 0) regs[rd] <= rd_data;
    if (jmpwe && ra_in != 0) begin      // 入栈：有返回地址才压
        rad[j] <= ra_in;  j <= j + 1;
    end
    else if (jmpred && j != 4'b0) begin // 出栈：栈非空才弹
        rad[j - 1] <= 6'b0;  j <= j - 1;
    end
end
```

- 栈深 16（`rad[0:15]`），栈指针 `j` 初始 0
- `rad[j-1]` 在 j=0 时空栈越界到 rad[15]（已初始化 0）→ 空栈时 ra=0，空栈 JALR 会跳回 0

### wreg.v（新增写回级寄存器）

```
NEX 拍：rd_data<=result_in; rd<=rd_in; we<=we_in
其他拍：全部清零（rd_data<=0, rd<=0, we<=0）
```

配合 ir 在 NEX 拍锁存，形成"取指级 / 执行写回级"两拍级结构，故 v4.2 写回较 v4.1 晚一拍。

### HALT（frz 冻结，与 v4.1 相同）

decoder 读到标签 00 且 opcode==HALT → `frz<=1`；FSM 在 NEX 拍读到 frz → 回 IDLE、we=0，
之后停在那里：PC 不动、不取指、不写寄存器，整机冻结。

## 6. 当前程序（ins_rom.v，两层嵌套调用/返回测试）

```
主程序  mem[0..2]   RJAL → 32         入栈{3}，跳过 mem[3..14]
        mem[3..14]  ADDI r1/r2/r3      （返回后执行）
        mem[15..16] HALT
sub1    mem[32..35] ADDI r4
        mem[36..38] RJAL → 48         入栈{39}
        mem[39..41] JALR              出栈{39} → 返 39
sub2    mem[48..51] ADDI r5
        mem[52..54] JALR              出栈{3} → 返 3
```

目的：验证返回栈 **LIFO 顺序**——sub2 最后入栈、最先出栈（返 39），sub1 后出栈（返 3）。

## 7. 仿真验证

| 时刻 | 事件 | 结果 |
|------|------|------|
| T= 55000 | RJAL（主程序）NEX | pc 3→32，入栈{3} ✓ |
| T=105000 | sub1 ADDI r4 执行 | alu=4 ✓（mem[3..14] 第一轮被跳过） |
| T=145000 | sub1 的 RJAL NEX | pc 39→48，入栈{39} ✓ |
| T=195000 | sub2 ADDI r5 执行 | alu=5 ✓ |
| T=235000 | **sub2 JALR NEX** | 出栈{39}，pc→39 ✓（最后入的先出） |
| T=275000 | **sub1 JALR NEX** | 出栈{3}，pc→3 ✓（先入的后出） |
| T=285000 | 返回后 ADDI r1/r2/r3 | r1=1 r2=2 r3=3 ✓ |
| T=465000 | HALT | stage=00 冻结 ✓ |

最终寄存器 **r1=1 r2=2 r3=3 r4=4 r5=5**，返回顺序与入栈顺序完全相反——LIFO 成立。

### 调试记录：JALR 死循环（本次修复）

- **现象**：JAL 单层测试时 pc 在 3↔25 之间无限循环，r1 恒 0（mem[3..22] 的 ADDI 从不执行）
- **根因**：reg_f.ra 原本是时序寄存器，非跳转拍被 `else ra<=0` 清零；JALR 的 NEX 拍
  pc 读 `ra_in` 时读到的是 0 → `pc_addr<=0` 跳回 0，反复触发 RJAL→JALR 死循环
- **修复（方案 A）**：
  1. `ra` 改组合输出栈顶 `assign ra = rad[j-1]`，不被时钟清零
  2. 入栈条件 `ra != 0` → `ra_in != 0`（`ra` 组合栈顶空栈恒 0，原判断永远失败、栈推不进东西；`ra_in` 才是真正的返回地址）
  3. initial 补 `rad[]` 清零 + `j = 0`（原 `j` 未初始化）

## 8. 相对 v4.1 的变化汇总

| # | 变化 | 状态 |
|---|------|------|
| 1 | FSM 4 状态 → **3 状态**（OPR/WRT 合并为 NEX） | ✓ 已实现 |
| 2 | LJMP/RJMP（4B）→ **LJAL/RJAL（3B）**，新增 **JALR（3B）** | ✓ 已实现并验证 |
| 3 | 返回机制：bytnum 计数 → **返回地址栈 rad[0:15] + 栈指针 j** | ✓ 已实现并验证 |
| 4 | 新增 **wreg 模块**（写回级寄存器，NEX 锁存） | ✓ 已实现 |
| 5 | reg_f.ra 改组合输出栈顶；修复 JALR 死循环 | ✓ 已修复并验证 |
| 6 | 指令集 19 → 20 条（新增 JALR=01_0011） | ✓ 已实现 |
| 7 | 两层嵌套调用/返回（LIFO）验证通过 | ✓ 已验证 |

## 9. 已知限制

| 限制 | 说明 |
|------|------|
| 空栈 JALR 行为未定义 | 空栈时 ra=0，JALR 会跳回 0；未做栈空标志保护 |
| 栈深固定 16 | 嵌套/递归超过 16 层会回绕，无溢出检测 |
| 无条件跳转 | LJAL/RJAL/JALR 均为无条件，无 zero 标志，做不了 `if` |
| 算术右移 | SRA/SRAI 已删，需接 `$signed` 才有真算术右移 |
| 非流水线 | 3 状态仍为多周期串行；ir/wreg 已有两拍级结构，但无指令重叠 |

## 10. 后续规划

- [ ] 条件跳转（zero 标志：比较器 + 标志寄存器）
- [ ] LJAL 后向跳转单独覆盖测试（本轮只测了 RJAL 前跳 + JALR 返回）
- [ ] 寄存器组接 DDR（届时再给 reg_f 加复位/端口）
- [ ] 若做真流水线：处理数据冒险（旁路转发/气泡）与控制冒险（跳转预测/flush）

---

*本文件随项目演进同步更新。*
