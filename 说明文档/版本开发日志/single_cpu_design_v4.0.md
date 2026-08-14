# 多周期 CPU 设计记录（v4.0 —— 架构重写：4 状态机 + 6-bit 指令集 + 4 字节变长标签编码 + LJMP/RJMP）

> 版本：2026-08-10  ·  在 v3.0 基础上**再次重写核心架构**（状态机 / opcode 宽度 / 寄存器宽度 / 指令编码全换）
> v3.0 见 [single_cpu_design_v3.0.md](single_cpu_design_v3.0.md)，v2.1 见 [single_cpu_design_v2.1.md](single_cpu_design_v2.1.md)，v2.0 见 [single_cpu_design_v2.0.md](single_cpu_design_v2.0.md)，v1.0 见 [single_cpu_design_v1.0.md](single_cpu_design_v1.0.md)

## 0. 版本说明

沿用 v3.0 第 0 节标准——架构变则大版本。v4.0 相对 v3.0 是一次架构重写：

| 维度 | v3.0 | v4.0 |
|------|------|------|
| FSM | 5 状态 IDLE→FET1→FET2→OPR→WRT | 4 状态 IDLE→FET→OPR→WRT（FET1/FET2 合并为变长取指） |
| opcode | 4-bit（10 条） | 6-bit（10 条） |
| 寄存器 | 4-bit（16 个） | 6-bit（64 个） |
| 指令格式 | 2 字节定长 | 4 字节变长（每字节 `[1:0]` 标签，读到标签 11 结束取指） |
| JMP 计数 | insnum（按指令条数） | bytnum（按字节数，FET 递减） |
| JMP 字段 | j_insnum + jmp_mes（偏移 ×2） | bytins + bytmov（直接字节偏移）+ jmpret |

编码与 v3.0 完全不兼容，程序码互不通用，属于重写而非增量，故记 **v4.0**。

> 说明：v3.0 文档发布后代码又重构过（FET1/FET2 合并、opcode 扩到 6-bit、寄存器扩到 64 个、
> 指令改 4 字节变长标签），一直未补文档，v4.0 即为该版代码的正式文档。

## 1. FSM（4 状态 + 变长取指 + frz 冻结）

```
IDLE(000) → FET(001) → OPR(010) → WRT(011) → FET …
    ↑
    └──────── HALT 时 frz=1，OPR 拍回 IDLE 并关写（we=0）────────
```

| 状态 | 动作 |
|------|------|
| IDLE | `!frz` 时 we=1、进 FET（HALT 后停在这里，we=0） |
| FET | 取当前字节；**`inst_raw[1:0]!=2'b11` 就留在 FET 继续取下一字节**；读到标签 11 → 进 OPR |
| OPR | IR 快照译码结果；遇 frz → 回 IDLE、we=0；否则进 WRT |
| WRT | 寄存器写回；JMP 的延迟返回在这里触发 |

**变长取指**：4 字节指令要走 4 拍 FET（opcode / rd / addr1 / imm 各一字节），
PC 每拍 +1；指令以标签 11 的字节收尾。FSM 在 FET 拍看 `inst_raw[1:0]`，
不为 11 就一直取，所以理论上 1~4 字节都能取，但当前指令集除 HALT 外都是 4 字节。

> 调试记录：曾出现"每条指令只取 1 字节"——fsm 的 `inst_raw` 输入在顶层没连接，
> 悬空 X 使 `X != 2'b11` 恒假，FET 直接进 OPR。修复：顶层 u_fsm 补 `.inst_raw(inst)`。

## 2. 指令集（6-bit opcode，10 条）

| 编码 | 助记符 | 行为 | 归属 |
|------|--------|------|------|
| 00_0000 | HALT | 冻结整机（frz=1） | 控制 |
| 00_0001 | ADDI | rd = rs1 + imm8 | ALU |
| 00_0010 | ADD  | rd = rs1 + rs2 | ALU |
| 00_0011 | SUBI | rd = rs1 - imm8 | ALU |
| 00_0100 | SUB  | rd = rs1 - rs2 | ALU |
| 00_0101 | AND  | rd = rs1 & rs2 | ALU |
| 00_0110 | OR   | rd = rs1 \| rs2 | ALU |
| 00_0111 | XOR  | rd = rs1 ^ rs2 | ALU |
| 00_1000 | LJMP | 后向跳转（opcode[0]=0 → addr − bytmov） | 控制流 |
| 00_1001 | RJMP | 前向跳转（opcode[0]=1 → addr + bytmov） | 控制流 |

- 寄存器 6-bit 地址 → 64 个寄存器；r0 恒读 0、写入被跳过
- ADDI/SUBI 的 imm8 取字节 `inst_raw[7:2]`（6-bit 值），零扩展成 8-bit，范围 0~63

## 3. 指令编码：4 字节变长标签格式

每个字节的 `[1:0]` 是标签，指示这个字节装什么：

| 标签 | ALU 指令 | JMP 指令 |
|------|----------|----------|
| 00 | opcode = [7:2] | opcode = [7:2] |
| 01 | rd = [7:2] | bytins_h = [7:2] |
| 10 | addr1 = [7:2] | bytins = {bytins_h, [7:6]}；bytmov_h = [5:2] |
| 11 | ADDI/SUBI：imm8 = [7:2]；其余 ALU：addr2 = [7:2] | bytmov = {bytmov_h, [7:4]}；jmpret = [3:2] |

一个 ALU 指令的例子（`ADDI r1 = r1 + 1`）：
```
byte0  000001_00   opcode = 00_0001（ADDI）
byte1  000001_01   rd     = 000001（r1）
byte2  000001_10   addr1  = 000001（r1）
byte3  000001_11   imm8   = 000001（= 1）
```

## 4. LJMP / RJMP 执行机制（pc.v：bytnum / nextadd / jmped）

编码（4 字节）：
```
byte0 = opcode[7:2] _ 00              // 00_1000 = LJMP 后向 / 00_1001 = RJMP 前向
byte1 = bytins_h[7:2] _ 01
byte2 = bytins[7:6] _ bytmov_h[5:2] _ 10
byte3 = bytmov[7:4] _ jmpret[3:2] _ 11
```

| 字段 | 位 | 含义 |
|------|-----|------|
| opcode | byte0[7:2] | 00_1000=LJMP（后向减）、00_1001=RJMP（前向加） |
| bytins | byte1[7:2] 拼 byte2[7:6]（8-bit） | 参与 `bytnum = bytins + 1` 计数 |
| bytmov | byte2[5:2] 拼 byte3[7:4]（8-bit） | **直接字节偏移**（不是 ×2） |
| jmpret | byte3[3:2]（2-bit） | **01=跳完目标指令后返回 nextadd；00=永久跳转不返回** |

执行时序（pc.v）：
```
FET 拍：addr <= addr + 1；if (bytnum != 0) bytnum <= bytnum - 1
OPR 拍（遇 LJMP/RJMP）：
    bytnum  <= bytins + 1       // 计数初值
    nextadd <= addr             // 记返回地址（= 跳转指令取完后的 PC）
    jmped   <= 1
    addr    <= addr −/+ bytmov  // opcode[0]=0 后向减，=1 前向加
WRT 拍：if (bytnum==0 && jmpret==2'b01 && jmped) begin
            addr <= nextadd; jmped <= 0;   // 触发跳回，且只触发一次
        end
```

**核心语义**：`bytnum` 在取目标指令时每取一字节减 1；当它归零、且 `jmpret==01`
（要返回）、`jmped`（跳转已发生且未返回过）时，目标指令的 WRT 拍把 PC 拉回
`nextadd`。当前指令集目标都是 4 字节，`bytnum = bytins + 1` 正好在目标第一条指令的
WRT 拍触发返回。

> 调试记录（本次会话）：
> 1. **bytnum 不递减**——初版 WRT 拍只有 `if (bytnum==0)` 判断跳回，没有任何地方递减，
>    归零永不发生 → 带 jmpret=01 的 LJMP 跳过去就回不来（死循环）。补在 FET 拍：
>    `if (bytnum != 8'b0) bytnum <= bytnum - 1;`。
> 2. **JMP 误写寄存器**——OPR 拍 ir 对 JMP 锁存的 rd/addr1/addr2/imm8 是上一条指令的
>    残留，JMP 的 WRT 拍 reg_f 就把残留 waddr 写成 `alu(op=JMP)=0`（会把 r1 清 0）。
>    修复：ir 对 LJMP/RJMP 强制 `waddr <= 0`，借 reg_f 自带的 `waddr!=0` 判断挡掉写入。

## 5. HALT（frz 冻结）

- decoder 在 FET 拍读到标签 00 且 `opcode==HALT` → `frz <= 1`
- FSM 在 OPR 拍读到 frz → `stage <= IDLE, we <= 0`
- 之后停在 IDLE：PC 不动、不取指、不写寄存器，整机冻结

## 6. 当前程序（ins_rom.v，JMP 验证程序）

```verilog
// mem[0..3]   ADDI r1 = r1 + 1
mem[0]  = 8'b000001_00;   // opcode = ADDI
mem[1]  = 8'b000001_01;   // rd  = r1
mem[2]  = 8'b000001_10;   // addr1 = r1
mem[3]  = 8'b000001_11;   // imm8 = 1

// mem[4..7]   RJMP 前跳 4 字节到 mem[12]（jmpret=00 永久跳）
mem[4]  = 8'b001001_00;   // opcode = RJMP
mem[5]  = 8'b000000_01;   // bytins_h = 0
mem[6]  = 8'b000000_10;   // bytins = 0, bytmov_h = 0
mem[7]  = 8'b010000_11;   // bytmov = 4, jmpret = 00

// mem[8..11]  ADDI r4 = r4 + 9（应被 RJMP 跳过）
mem[8]  = 8'b000001_00;   // opcode = ADDI
mem[9]  = 8'b000100_01;   // rd  = r4
mem[10] = 8'b000100_10;   // addr1 = r4
mem[11] = 8'b001001_11;   // imm8 = 9

// mem[12..15] LJMP 回跳 16 字节到 mem[0]（jmpret=01 返回）
mem[12] = 8'b001000_00;   // opcode = LJMP
mem[13] = 8'b000000_01;   // bytins_h = 0
mem[14] = 8'b010001_10;   // bytins = 1, bytmov_h = 1
mem[15] = 8'b000001_11;   // bytmov = 16, jmpret = 01

// mem[16..19] HALT 停机
mem[16] = 8'b000000_00;   // opcode = HALT
mem[17] = 8'b000000_01;
mem[18] = 8'b000000_10;
mem[19] = 8'b000000_11;
```

程序流：r1 = 1 → RJMP 跳过 mem[8]（r4 保持 0）→ LJMP 回 mem[0] 再执行 ADDI
（r1 = 2）→ 延迟返回命中 mem[16] HALT。

## 7. 仿真验证（iverilog，tb 在 #560 处有第二次复位测试重启）

| 轮次 | 时刻 | 事件 | 结果 |
|------|------|------|------|
| 第一轮 | T=75000 | ADDI @mem[0] 写回 | r1: 0+1=1 ✓ |
| 第一轮 | T=135000 | RJMP @mem[4] 的 WRT | pc 8→12，`w=000000` 不再误写，r1 保持 1 ✓ |
| 第一轮 | — | mem[8] ADDI r4 被跳过 | r4 全程 0 ✓ |
| 第一轮 | T=195000 | LJMP @mem[12] | pc 16→0 回跳成功 ✓ |
| 第一轮 | T=255000 | 重新执行 ADDI @mem[0] | r1: 1+1=2 ✓ |
| 第一轮 | T=265000 | 延迟返回 | pc→16（nextadd），取 HALT 冻结，stage=000、we=0 ✓ |
| 第二轮 | T=585000 | **第二次复位（rst 拉高）** | pc→0，r1 保留 2（reg_f 无复位） |
| 第二轮 | T=845000 | 跑完 | r1: 2→3→4，再次冻结 ✓ |

**验证结论**：RJMP 前跳、LJMP 回跳、延迟返回、HALT 冻结全链路正确；复位重启正常。
JMP 指令的 WRT 拍不再误写寄存器（ir waddr 清零生效）。

> 注意：reg_f（寄存器组）**刻意没有复位逻辑**，复位后 r1/r2 值保留
> （第二轮 r1 从 2 起步）。这是有意为之——寄存器后续要接 DDR，到时候一并改。

## 8. v3.0 已知限制的解决情况

| v3.0 限制 | v4.0 状态 |
|-----------|-----------|
| 1. 不是真 HALT | 已解决（frz 冻结） |
| 2. JMP 只跳一条 | 已解决（bytnum 计数 + 延迟返回） |
| 3. 无条件跳转 | 仍存在（无 zero 标志/比较器） |
| 4. opcode 编码空间 | 已扩展（6-bit 共 64 个编码，用 10 个） |
| 5. we 不区分指令类型 | 部分解决（JMP 借 ir 置 waddr=0 避开写入；we 仍未按指令类型区分） |
| 6. 指令格式定长 | 已改为 4 字节变长标签格式 |

## 9. 后续规划

- [ ] 条件跳转（zero 标志：比较器 + 标志寄存器）
- [ ] 寄存器组接 DDR（届时给 reg_f 加复位/端口）
- [ ] 子程序调用/返回（call/ret，需栈或链接寄存器）
- [ ] 更多 JMP 测试覆盖（不同 bytins/bytmov 组合、连续跳转）

---

*本文件随项目演进同步更新。*
