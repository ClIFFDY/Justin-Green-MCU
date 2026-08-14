# MCU 设计记录（v1.0 —— 总线化 MCU：RAM + UART 外设 + stall 流水 + HALT 停机）

> 版本：2026-08-14
> 这是 **MCU 系列的第 1 版**（CPU 系列见 `single_cpu_design_v6.5.md`）。
> 核心变化：把 v6.5 的"CPU 内部直连 RAM/UART"重构为**总线化 MCU**——
> CPU 只发 `{addr, wdata, sig}` 三组信号，data_ram / uart 作为**总线外设**挂在上面，
> 读数据经**顶层 mux 按地址段选择**回送；同步读写的等待由 **stall_bus 冻结流水线一拍**完成。
> 本次新增并验证：stall 架构、连续读写、运行中复位、HALT 真停机（含 stall/halt 优先级）。
> 注：文档与 RTL 术语已统一用 **MCU**：顶层模块已随文档改名 `single_soc_top` → `single_mcu_top`
> （端口 `rst_n/clk/tx/rx` 与层次不变，tb 层次引用无需改动）。

## 0. 版本说明

| 维度 | CPU v6.5（旧） | MCU v1.0（当前） |
|------|----------------|------------------|
| 互联结构 | CPU 内部直连 data_ram/uart，无统一总线 | **总线化**：CPU 发 `bus_addr[15:0]/bus_data[7:0]/bus_sig[3:0]`，外设回 `bus_data_b` |
| 读数据选择 | decoder/alu 里按地址硬分流 | **顶层 mux** 按 `addr[15:13]` 选外设（修多驱动） |
| RAM 地址 | ≤8191（0x2000 被 uart 占用） | **0x2000–0x3FFF 段**（addr[15:13]==001），0x2000 段完整归 RAM |
| UART 地址 | ==0x2000（8192） | **0x4000–0x5FFF 段**（addr[15:13]==010），移出 RAM 段 |
| RAM 访问时序 | 同步读无等待（组合直读） | **同步读写，stall_bus 冻结 1 拍**（2 拍握手） |
| HALT 行为 | 只停 1 拍（bug，见调试记录 5） | **永久停机**直到复位（fsm stage 锁存） |
| 指令集 | 29 条 | **29 条（不变）** |
| 验证 | 整机/栈/收发回归 | **连续读写 / 复位 / stall+halt 优先级 + 旧回归** 全绿 |

## 1. 总体架构

```
                    ┌────────────────── single_mcu_top ──────────────────┐
   clk/rst_n        │                                                    │
     │  rst=~rst_n  │  ┌─────────────── single_cpu_top ───────────────┐  │
     └──────────────┼─▶│ pc→ins_rom→if_reg→decoder→id_reg→alu→wr_reg  │  │
                    │  │     →reg_f（流水线，见 CPU 文档 v6.5）         │  │
                    │  │    bus_addr_out bus_data_out bus_sig_out       │  │
                    │  │       ▼              ▼            ▼            │  │
                    │  │   bus_addr_f[15:0] bus_data_f[7:0] bus_sig_f[3:0] │
                    │  └───────────────────────────────────────────────┘  │
                    │      │              │             │                 │
                    │      │              │             │  bus_sig[0]:     │
                    │      │              │             │   0=读(LBU)/1=写(SB)│
                    │      ▼              ▼             ▼                 │
                    │  ┌─ data_ram ─┐  ┌─ uart_top ─┐                    │
                    │  │ 0x2000段    │  │ 0x4000段    │                    │
                    │  │ bus_data_out│  │ bus_data_out│                   │
                    │  └─────┬──────┘  └─────┬──────┘                    │
                    │        │               │                            │
                    │        ▼               ▼                            │
                    │   bus_data_ram    bus_data_uart                     │
                    │        └──────┬ mux（addr[15:13]）──┐              │
                    │               ▼                     ▼              │
                    │           bus_data_b ──────────▶ CPU.bus_data_in   │
                    │   data_ram.stall_bus ──────────▶ CPU.stall_bus     │
                    │   uart.uart_sig_out ──────────▶ CPU.uart_sig_in    │
                    └────────────────────────────────────────────────────┘
```

**总线读通路（LBU）**：CPU 发 `bus_addr` + `bus_sig[0]=0` → 所有外设都看到地址并各自驱动自己的 `bus_data_out` →
顶层 mux 按 `addr[15:13]` 把对应外设的数据送上 `bus_data_b` → CPU 的 id_reg 在 EX 级锁存 `bus_data_in` → alu 写回。

**总线写通路（SB）**：CPU 发 `bus_addr` + `bus_data` + `bus_sig[0]=1` → 外设自己判断地址是否命中并锁存写入。
SB 无读回，不需要 mux。

## 2. 总线协议与地址空间

### 2.1 总线信号

| 信号 | 方向 | 含义 |
|------|------|------|
| `bus_addr[15:0]` | CPU→外设 | 访问地址（decoder 组合输出，= 指令的地址字段） |
| `bus_data[7:0]` | CPU→外设 | 写数据（= 源寄存器值，含前送） |
| `bus_sig[3:0]` | CPU→外设 | 访问标志；**`bus_sig[0]`：0=读(LBU)，1=写(SB)**，其余位保留 |
| `bus_data_b[7:0]` | 外设→CPU | 读数据（顶层 mux 选通，其他位驱动全 0） |
| `stall_bus` | data_ram→CPU | 高电平 = 冻结流水线 1 拍 |
| `uart_sig_out[1:0]` | uart→CPU | `{!busy, rx_done}` → regs[255]/regs[254] |

### 2.2 地址映射（按 `addr[15:13]` 段译码，mux 与外设必须一致）

| addr[15:13] | 段 | 外设 | 说明 |
|-------------|-----|------|------|
| `3'b001` | `0x2000–0x3FFF` | **data_ram** | 8192 字节，`addr[12:0]` → `mem[0..8191]`（0x2000 ↔ mem[0]） |
| `3'b010` | `0x4000–0x5FFF` | **uart** | LBU 读 rx_data / SB 触发发送 |
| 其他 | — | 黑洞 | mux 回 0，外设不响应（读=0x00，写丢弃） |

> ⚠️ **mux 判段必须用 `[15:13]`**——曾用 `[2:0]` 导致 0x2000/0x4000 的 `[2:0]` 全是 000、
> 恒走 default，读全 0（见调试记录 2）。

### 2.3 一次总线访问的时序（data_ram，2 拍握手）

```
拍1: CPU 发地址，access=1, done=0 → stall_bus=1 → 整条流水线冻结（pc/if_reg/id_reg/wr_reg 保持）
拍2: posedge 后 done=1 → stall_bus=0 → 释放；读数据/写数据在拍2 生效
```

## 3. 流水线与 stall 机制

### 3.1 流水线结构（继承 v6.5，LBU 走总线）

```
pc → ins_rom(4B 窗口) → if_reg(inst_raw2)
    → decoder（组合：译码 + 驱动总线 + 两级前送 r12_data）
    → id_reg（EX 级锁存 opcode/rd/imm8/ab_raw/we/**bus_data_in**）
    → alu → wr_reg → reg_f
```

LBU 特殊路径：id_reg 把 `bus_data_in`（mux 回来的读数据）一并锁存，alu 对 LBU 直接 `result = bus_data` 写回。

### 3.2 stall 冻结点（4 处，必须同时 hold）

| 冻结点 | 条件 | 作用 |
|--------|------|------|
| pc | `stage==EXE && !stall` 才推进 | 取指地址停在原地 |
| if_reg | `stall` 分支 `inst_raw <= inst_raw` | **保持当前指令**（曾漏掉，见调试记录 3） |
| id_reg | `stage==01 && !stall` 才锁存 | 不丢/不重抓 EX 级指令 |
| wr_reg | `!stall` 才动作 | 写回级也停住 |

**if_reg 的 hold 是关键**：stall 时 pc 已比正在执行的指令超前 1 条，若 if_reg 照常抓 `ROM[pc]`，
会把 LBU 这条指令本身挤掉（恢复后少执行一条）。

### 3.3 stall 极性

```verilog
assign stall_bus = access && !done;   // access = (addr[15:13]==001)
```
- **首个访问周期**就拉 stall（`access && !done`）——`done` 默认每拍清零，access 命中即 stall；
- 曾误写 `access && done`，要到第二个访问周期才 stall（pc 已推进，错位一拍）。

## 4. 外设

### 4.1 data_ram（0x2000 段，8192B，块 RAM）

```verilog
reg done;
wire access = (bus_addr_in[15:13] == 3'b001);
assign stall_bus = access && !done;
always @(posedge clk) begin
    done <= 1'b0;
    bus_data_out <= 8'b0;
    if (access) begin
        done <= ~done;
        if (bus_sig_in[0]) mem[bus_addr_in[12:0]] <= bus_data_in;  // SB 写
        else               bus_data_out[7:0] <= mem[bus_addr_in[12:0]]; // LBU 读
    end
end
```
无复位逻辑（复位口已清理）——内存只在 initial 清零，需程序先写后用。

### 4.2 uart_top（0x4000 段，组合控制 + uart_tx/uart_rx）

```verilog
always @(*) begin
    tx_en = 1'b0; rx_read = 1'b0; bus_data_out = 8'b0;
    uart_sig_out = {!busy, rx_done};          // regs[255]=!busy, regs[254]=rx_done
    if (addr[15:13]==3'b010) begin
        if (bus_sig_in[0]) tx_en = 1'b1;       // SB：触发发送（数据走 bus_data_in→tx_data）
        else if (!rx_done) uart_sig_out[1] = 1'b1;  // LBU 但无数据：置忙标志
        else begin bus_data_out = rx_data; rx_read = 1'b1; end // LBU 有数据：回数据 + 握手
    end
end
```

**地址迁移说明**：v6.5 CPU 里 UART 口在 `==0x2000`；MCU 中 RAM 独占 0x2000 段，
UART 移到 **0x4000 段**（`addr[15:13]==010`）。软件访问方式不变（LBU 读 / SB 发），仅地址变了。

## 5. 运行控制：HALT 停机（本次修复）

### 5.1 修复前（bug）

fsm 原逻辑 `if (frz) IDLE else EXE`——frz 是 decoder 对 if_reg=HALT 那一拍的组合输出，
HALT 后下一拍 if_reg 被换掉、frz 掉回 0，fsm 立刻回 EXE；而 HALT 那拍 pc 被 `if(!frz)` 冻住没推进，
于是回 EXE 后**重新抓取 HALT 后第一条指令并执行**——HALT 变成"停一拍 + 继续跑"（见调试记录 5）。

### 5.2 修复后（当前）

fsm 删掉 `else stage <= EXE`，stage **锁存**：

```verilog
always @(posedge clk or posedge rst) begin
    if (rst)      stage <= EXE;
    else if (frz) stage <= IDLE;   // HALT：进 IDLE 并永久锁存
end
```

- HALT 一拍后 frz 掉 0，但 stage 已锁在 IDLE，**回不去 EXE** → 直到复位 `rst` 才恢复。
- pc 只在 `stage==EXE && !stall` 推进 → 永久停在 HALT 后第一条指令的地址。
- if_reg 灌 NOP、id_reg 不锁存、wr_reg 清零 → 后续指令全部作废。
- 复位即重启：`rst` 把 stage 置回 EXE、pc 清零，程序从头跑。

### 5.3 stall 与 halt 的关系

两者互不冲突：stall 只由 SB/LBU 产生，HALT 不是总线指令，同一拍 if_reg 只有一个身份；
HALT 锁存后 stage=IDLE，`access` 也恒为 0，stall_bus 不会再拉。优先级无需特判。

## 6. 指令集与编码（29 条，未变）

| 指令 | byte0 | 布局 |
|------|-------|------|
| HALT | 0x00（1B） | 仅 byte0 |
| LBU | 0x73（4B） | byte1=rd，byte2:byte3=总线地址 |
| SB | 0x77（4B） | byte1=rs，byte2:byte3=总线地址 |
| ALU-R / ALU-I | —（4B） | byte1=rd，byte2=r1/rs1，byte3=r2/imm8 |
| 分支（LBEQ/RBEQ/LBNE/RBNE/LBLTU/RBLTU） | 0x5B..（4B） | byte1=bytmov，byte2=r1，byte3=r2 |
| LJAL/RJAL（2B）/ JALR（2B） | 0x21/0x25/0x4D | byte1=bytmov |

编码细节与分支/调用语义同 [single_cpu_design_v6.5.md](single_cpu_design_v6.5.md)。

## 7. 仿真验证

**整机 tb**：`sim_1/new/mcu_full_tb.v`（载入 `cpu_full_test.hex`：段1 算术自检 + 段2 调用返回 + 段3 UART 回环，
全绿）。术语统一时由 `soc_full_tb.v` 迁名而来（顶层改实例 `single_mcu_top`）；过时的
`cpu_full_tb / board_selftest_tb / single_cpu_top_tb / probe_tb`（旧 CPU 直连接口，已无法编译）删除，
`uart_tx_tb.v`（uart_tx 模块单元测试）保留。当前 `sim_1/new/` 只含这两个 tb。

### 7.1 总线 / stall 专项测试（`/e/tmp/` 测试套件）

| 测试 | hex/tb | 覆盖点 | 结果 |
|------|--------|--------|------|
| RAM 回写/读回 | ram_loopback / ram_test_tb | LBU 读回 SB 写的数据 | ✅ r1=5A r2=5A r3=5B |
| 连续两次读 | ram_2read | LBU;LBU 无写间隔，stall 连发 | ✅ r1=r2=r3=0x11 r4=0x12 |
| 连续读写 | ram_2rw | 写读→读读→写读→ADDI | ✅ r1..r4=0x5A r5=0x5B |
| 复位 | ram_rst | 运行中 3 次拉低 rst，重启计数 | ✅ r14=1→2→3，复位期 pc=0 |
| stall/halt 优先级 | ram_halt | SB(stall)→LBU(stall)→HALT | ✅ r1=5A r2=5A r3=0 r4=0，stage=IDLE，pc 锁 0x0D |

### 7.2 ram_halt 关键时序（修复后）

```
n=7  pc=0x0D if_reg=HALT    frz=1 stage=EXE   ← HALT 译码
n=8  pc=0x0D if_reg=ADDI r3 frz=0 stage=IDLE  ← 进 IDLE 并锁存
n=9+ pc=0x0D if_reg=NOP     frz=0 stage=IDLE  ← 永久冻结，r3/r4 永不执行
```

### 7.3 综合与时序（MCU v1.0，50MHz）

| 项 | CPU v6.5 | MCU v1.0（当前） |
|----|----------|------------------|
| WNS（setup） | 2.66ns | **3.409ns** |
| hold | 0.064ns | **0.056ns** |
| 脉宽 | 8.75ns | **8.75ns** |

三项全为正，50MHz（周期 20ns）**无违例**。setup 反比 v6.5 好转约 0.75ns（关键路径 ~16.6ns，理论最高 ~60MHz）：
总线化后 CPU 核不再内嵌 UART 端口译码/数据分流（v6.5 的 tx_en/rx_data 直连 decoder/alu），decoder 只发总线
三信号、读数据经 id_reg 锁存，核内组合路径变短；外设逻辑移到总线外，顶层 mux + stall 门控未进入关键路径。
hold 0.056ns 紧但为正（FF 直连最短路径，与频率无关）；脉宽不变。上板引脚约束仍待补。

## 8. 调试记录

### 调试记录 1：bus_data_b 多驱动（根因 A）
- 现象：LBU 读 RAM 回 x
- 根因：uart_top 和 data_ram 都把 `bus_data_b` 当输出，两处驱动同一根线
- 证据：隔离探针 iso_probe——外设内部 reg=5A 正常、总线共享 net=XX
- 修复：每个外设独立 `bus_data_out` 线，顶层 mux 按 `addr[15:13]` 选通

### 调试记录 2：mux 判段用错位
- 现象：mux 修好后读仍全 0
- 根因：mux 用 `bus_addr_f[2:0]` 判段，而外设译码用 `[15:13]`；0x2000/0x4000 的 `[2:0]` 都=000 → 恒 default
- 修复：mux 改用 `[15:13]`，与外设一致

### 调试记录 3：if_reg 的 stall 是死代码，LBU 丢失
- 现象：连续访问丢指令（pc 超前 1 条时 if_reg 抓到 ROM[pc]）
- 根因：原 `else if (stall)` 在 EXE 分支之后不可达；stall 时 if_reg 照常抓下一条，把 LBU 挤掉
- 修复：stall 分支提前 + `inst_raw <= inst_raw` 保持

### 调试记录 4：stall 极性反了
- 现象：stall 在第二个访问周期才拉（pc 已推进，错位一拍）
- 根因：`access && done` 等到握手完成才 stall
- 修复：`access && !done`，首个访问周期即冻结

### 调试记录 5：HALT 只停一拍（fsm 回弹）
- 现象：ram_halt 测试 r3=0x42（HALT 后第一条执行了）、r4=0x24 也执行，pc 落 LBEQ 自旋永不停止
- 根因：frz 是 decoder 组合输出只维持 1 拍，`else stage<=EXE` 让 fsm 立刻弹回；pc 被冻在 HALT 后一条的地址
- 修复：删 `else`，stage 锁存 IDLE，永久停机直到复位

## 9. 无用定义清理（本次）

| 文件 | 删除内容 | 原因 |
|------|----------|------|
| decoder.v | `stall` 输出 | 组合块从不赋值，顶层不连 |
| decoder.v | `bus_data_in` 输入 | 模块体从不引用 |
| data_ram.v | `rst` 输入 | 模块体从不引用（顶层同步删 `.rst` 连接） |
| single_cpu_top.v | `bus_addr_temp` / `bus_sig_temp` 死线 | 全项目只声明不连接 |
| alu.v | `bus_flag` | 保留（用户决定） |

清理后 iverilog 零警告零错误，全量回归 5 项全过。

## 10. 已知限制

| 限制 | 说明 |
|------|------|
| 总线访问 2 拍 | 每笔 RAM 访问 stall 1 拍，无突发/无 write-response 握手 |
| UART 无缓冲 | rx_data 单字节，读得慢会丢帧（无 FIFO） |
| r254/r255 被 IO 占用 | regs[254]=rx_done、regs[255]=!busy，用户程序不可用 |
| data_ram 无复位 | 上电需程序先写后用（BRAM，仅 initial 清零） |
| 条件分支 1 拍气泡 | 分支预测=不跳，跳转时 flush 1 拍 |
| 栈深 255 | j 满/空栈由 j_flag 保护 |
| 上板未验 | 50MHz 综合通过（setup 3.409ns / hold 0.056ns，见 7.3），引脚约束与板测待补 |

## 11. 后续规划

- [x] 总线化 MCU：顶层 mux + stall 流水 + 地址段译码 —— v1.0
- [x] 连续读写 / 复位 / stall+halt 优先级验证 —— v1.0
- [x] HALT 永久停机（fsm stage 锁存）—— v1.0
- [x] 无用定义清理 —— v1.0
- [ ] rx FIFO / 双缓冲（多字节连续收发不丢）
- [ ] 更多外设（GPIO / timer / 中断控制器）
- [ ] 上板：引脚约束 + 回环板验
- [ ] asm.py 汇编器（手拼字节改助记符）
- [ ] 中断/异常/CSR

---

*本文件随项目演进同步更新。*
