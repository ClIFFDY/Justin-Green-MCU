# 多周期 CPU 设计记录（v3.0 —— 架构重写：5 状态机 + 4-bit 指令集 + LJMP/RJMP）

> 版本：2026-08-10  ·  在 v2.1 基础上**重写核心架构**（状态机 / 编码宽度 / 寄存器宽度全换）
> v2.1 见 [single_cpu_design_v2.1.md](single_cpu_design_v2.1.md)，v2.0 见 [single_cpu_design_v2.0.md](single_cpu_design_v2.0.md)，v1.0 见 [single_cpu_design_v1.0.md](single_cpu_design_v1.0.md)

## 0. 版本说明

沿用 v2.1 第 0 节标准——架构变则大版本。v3.0 架构变化：

| 维度 | v2.1 | v3.0 |
|------|------|------|
| FSM | 4 状态 FET1→FET2→OPR→WRT | 5 状态：新增 IDLE + frz 冻结机制 |
| opcode | 3-bit（7 条） | 4-bit（10 条） |
| 寄存器寻址 | 3-bit（8 个） | 4-bit（16 个） |
| 控制流 | JMP：跳过去跑 1 条就回 | LJMP/RJMP：跳过去跑 N 条再回（insnum 计数） |
| 停机 | 无 | 真 HALT（frz 冻结） |

编码不兼容 v2.1（opcode 3-bit→4-bit，字段布局全变），程序码互不通用，属于重写而非增量，故记 **v3.0**。

## 1. FSM（5 状态 + frz 冻结）

```
IDLE(000) → FET1(001) → FET2(010) → OPR(011) → WRT(100) → FET1 …
    ↑
    └────────────── HALT 时 frz=1，OPR 拍回 IDLE 并关写 ──────
```

| 状态 | 动作 |
|------|------|
| IDLE | `!frz` 时 we=1、进 FET1（HALT 后停在这里，we=0） |
| FET1 | 取指令第 1 字节（opcode），PC 进 1 |
| FET2 | 取指令第 2 字节（operand），PC 进 1，decoder 依 opcode 准备各字段 |
| OPR | IR 快照译码结果；遇 frz → 回 IDLE、we=0；否则进 WRT |
| WRT | 寄存器写回；递减 insnum |

frz 数据通路：decoder 在 FET2 遇 HALT 置 `frz=1` → FSM 在 OPR 拍读到 frz → 回 IDLE 冻结。
（v2.1 的 IR 快照思想保留，IR 仍在 OPR 拍锁存。）

## 2. 指令集（4-bit opcode，10 条）

| 编码 | 助记符 | 行为 | 归属 |
|------|--------|------|------|
| 0000 | HALT | 冻结整机（frz=1） | 控制 |
| 0001 | ADDI | r3 = r1 + imm8 | ALU |
| 0010 | ADD  | r3 = r1 + r2 | ALU |
| 0011 | SUBI | r3 = r1 - imm8 | ALU |
| 0100 | SUB  | r3 = r1 - r2 | ALU |
| 0101 | AND  | r3 = r1 & r2 | ALU |
| 0110 | OR   | r3 = r1 \| r2 | ALU |
| 0111 | XOR  | r3 = r1 ^ r2 | ALU |
| 1000 | LJMP | 后向跳转（跳过去跑 N 条再回） | 控制流 |
| 1001 | RJMP | 前向跳转（同上） | 控制流 |

- 运算指令 2 字节格式：byte0 = `opcode[7:4]_r1[3:0]`，byte1 = `r2/imm[7:4]_r3[3:0]`
- ADDI/SUBI：imm8 = {4'b0, byte1[7:4]}（只用了 8-bit imm 的低 4 位）
- 寄存器 4-bit 地址 → 16 个寄存器；r0 恒读 0、写入被跳过

## 3. LJMP / RJMP 编码（2 字节）

```
byte0 = 1000/1001 [7:4]  _  j_insnum [3:0]   // 跳过去要执行的指令条数
byte1 = jmp_mes [7:0]
```

| 字段 | 位 | 含义 |
|------|-----|------|
| opcode | byte0[7:4] | 1000=LJMP（后向）、1001=RJMP（前向） |
| j_insnum | byte0[3:0] | 跳过去后要执行的指令条数（0~15） |
| jmp_mes[0] | byte1[0] | **返回使能：1=跳完后跳回 nextadd，0=永久跳转不回来** |
| jmp_mes[7:1] | byte1[7:1] | 偏移量（×2 换算成字节） |

- 偏移 `2 × jmp_mes[7:1]`：每条指令 2 字节，所以偏移以"指令条数"为单位
- 方向：LJMP（opcode[0]=0）往回减，RJMP（opcode[0]=1）往前加
- 例：`LJMP j_insnum=2, jmp_mes=0000101_1` → 往回跳 `2×5=10` 字节，跑 2 条后返回

## 4. LJMP/RJMP 的执行机制（pc.v：insnum / nextadd / jmped）

```
OPR 拍（遇 LJMP/RJMP）：
    insnum  <= j_insnum + 1        // 要执行的指令数
    nextadd <= addr                 // 记返回地址（= 跳转指令取完后的 PC）
    jmped   <= 1
    addr    <= addr ∓ 2×jmp_mes[7:1]   // 真正跳过去

每条指令的 WRT 拍：
    case insnum
        0: if (jmp_mes[0] && jmped) begin addr <= nextadd; jmped <= 0; end   // 计数归零 → 跳回
        default: insnum <= insnum - 1                                         // 每执行一条减 1
```

**核心语义**：`insnum = j_insnum + 1`，跳过去的指令每完成一条（WRT 拍）减 1，
减到 0 的 WRT 拍跳回 `nextadd`。

> 调试记录：初版没有 `jmped`，`insnum==0 && jmp_mes[0]==1` 在**每一次** WRT 拍都触发
> `addr<=nextadd`——因为 insnum 归零后不再变化、jmp_mes 也没清，CPU 陷入
> "跳回→执行→又跳回"的死循环（r1 一路递增停不下来）。
> **加 `jmped` 后跳回只触发一次**（跳回时置 0），其余 WRT 拍即使 insnum==0 也不再动 PC。
>

## 5. HALT（frz 冻结）

- decoder 在 FET2 遇 opcode==HALT → `frz <= 1`
- FSM 在 OPR 拍读到 frz → `stage<=IDLE, we<=0`
- 之后停在 IDLE：PC 不动、不取指、不写寄存器，整机冻结

## 6. 当前程序（ins_rom.v）

```verilog
mem[0]  = 8'b0001_0001;   // ADDI r1 = r1 + 2
mem[1]  = 8'b0010_0001;
mem[2]  = 8'b0001_0010;   // ADDI r2 = r2 + 3
mem[3]  = 8'b0011_0010;
mem[4]  = 8'b0010_0001;   // ADD  r2 = r1 + r2
mem[5]  = 8'b0010_0010;
mem[6]  = 8'b0001_0001;   // ADDI r1 = r1 + 2
mem[7]  = 8'b0010_0001;
mem[8]  = 8'b0001_0010;   // ADDI r2 = r2 + 3
mem[9]  = 8'b0011_0010;
mem[10] = 8'b0010_0001;   // ADD  r2 = r1 + r2
mem[11] = 8'b0010_0010;
mem[12] = 8'b1000_0010;   // LJMP j_insnum=2（往回跳 2×5=10 字节 → 目标 4）
mem[13] = 8'b0000101_1;   // jmp_mes: [0]=1 返回使能, [7:1]=5
mem[14] = 8'b0001_0001;   // 跳回后 ADDI r1 = r1 + 1
mem[15] = 8'b0001_0001;
mem[16] = 8'b0000_0000;   // HALT
mem[17] = 8'b0000_0000;
```

（mem[18-19] 的 ADD 目前不会被执行——HALT 在 16 就冻结了，可留作后续程序段。）

## 7. 仿真验证（iverilog，tb 里 #560 处有第二次复位测试重启）

| 时刻 | 事件 | 结果 |
|------|------|------|
| T=265000 | ADD r2 = r1+r2 | r2: 8+4=12 ✓ |
| T=295000 | LJMP 触发（OPR） | insnum=3，addr 14→4 ✓ |
| T=345000 | 跳转后 ADD @4 | r2: 4+12=16 ✓ |
| T=385000 | 跳转后 ADDI @6 | r1: 4+2=6 ✓ |
| T=425000 | 跳转后 ADDI @8，insnum 归零 | r2: 16+3=19 ✓，跳回 nextadd=14 |
| T=465000 | 跳回后 ADDI @14 | r1: 6+1=7 ✓ |
| T=495000 | HALT @16 | stage=000（IDLE），we=0 冻结 |
| T=585000 | **第二次复位（rst 拉高）** | pc→0，重新从 mem[0] 取指 |
| T=1075000 | 第二次跑完 HALT | 再次冻结，r1=14 r2=59 |

**重启验证结论**：FSM/PC/decoder（含 frz）都能被 rst 正确复位，停机后再拉 rst
能重新从 pc=0 跑全程并再次正常停机。

> 注意：reg_f（寄存器组）**刻意没有复位逻辑**，复位后 r1/r2 值保留
> （第二次重启 r1 从 7 起步）。这是有意为之——寄存器后续要接 DDR，到时候一并改，
> 现阶段不加复位端口。

## 8. v2.1 已知限制的解决情况

| v2.1 限制 | v3.0 状态 |
|-----------|-----------|
| 1. 不是真 HALT | 已解决（frz 冻结） |
| 2. JMP 只跳一条 | 已解决（insnum 可跑 N 条再回） |
| 3. 无条件跳转 | 仍存在（无 zero 标志/比较器） |
| 4. opcode 只剩 1 个编码 | 已解决（4-bit 共 16 个编码，用 10 个） |
| 5. we 硬编码 1 | 部分解决（we 已由 fsm 控制：reset/IDLE 置 1，HALT 置 0）；但 we 仍不区分指令类型，LJMP/RJMP 靠 decoder 置 addr3=0 避开写入 |

## 9. 后续规划

- [ ] 条件跳转（zero 标志：比较器 + 标志寄存器）
- [ ] 寄存器组接 DDR（届时给 reg_f 加复位/端口）
- [ ] 子程序调用/返回（call/ret，需栈或链接寄存器）

---

*本文件随项目演进同步更新。*
