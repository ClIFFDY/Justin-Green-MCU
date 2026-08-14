# MCU 设计记录（v1.1 —— 中断控制器 IRQ + 复位同步器 + UART 收发改中断）

> 版本：2026-08-14
> MCU 系列第 2 版（v1.0 见 `single_mcu_design_v1.0.md`；CPU 系列见 `single_cpu_design_v6.5.md`）。
> **指令与外设速查见 `指令集说明/mc_v1.1_ins.md`**；本日志只记设计、时序与调试，不再重复指令表。
> 核心变化三件套：
> ① **中断控制器**（新模块 `irq_controller.v`）：uart_rx → rx_irq → irq_bus → CPU，ISR 向量 0xE8，IRET 恢复断点；
> ② **UART 收发改中断**：`regs[254]=rx_done` 的轮询映射废弃，轮询段3（死代码）从 hex/tb 移除；
> ③ **两级复位同步器**：根治 Vivado `[Place 30-99] IO Clock Placer failed`。
> 另：时序复核 setup 2.977ns / hold 0.043ns / 脉宽 8.75ns，hold 最薄 43ps 已分析并接受（见调试记录 4）。

## 0. 版本说明

| 维度 | MCU v1.0（旧） | MCU v1.1（当前） |
|------|----------------|------------------|
| UART 收发 | 轮询：uart_sig_out → `regs[254]=rx_done`、`regs[255]=!busy` | **中断**：rx_done→rx_irq→IRQ→ISR 回显；`regs[254]` 废弃、`regs[255]=tx_busy` 保留 |
| 中断 | 无 | **irq_controller**：`irq_bus` 授权门控 `bytmov==0`、grant 保存断点、IRET 灌回恢复 |
| IRET 指令 | 死代码（decoder 恒 `iret=0`） | **生效**：irq_busy 清 0 + 恢复断点地址 |
| 复位 | `rst=~rst_n` 直接高扇出（→BUFG，触发 [Place 30-99]） | **两级复位同步器**（rst_n_s1/s2 + 反相），释放沿对齐 clk |
| 测试 | mcu_full_tb 含段3 UART 轮询回环 | 段3 移除；新增 irq_test_tb 中断全链路回归 |
| 时序（50MHz） | setup 3.409 / hold 0.056 / 脉宽 8.75 | setup 2.977 / hold 0.043 / 脉宽 8.75（hold 最薄，已接受） |
| 指令集 | 29 条 | **30 条（+IRET 生效）**（速查见 `指令集说明/mc_v1.1_ins.md`） |

## 1. IRQ 中断机制（本次核心）

### 1.1 中断通路

```text
uart_rx.rx_done ──▶ uart_top.rx_irq ──▶ single_mcu_top 组装 irq_bus[5:3]=3'b001
                                        │（其余位恒 0）
                                        ▼
                        single_cpu_top.irq_bus[5:0]
                                        │
                                        ▼
                     ┌─────────────────────────────────┐
                     │          irq_controller          │
                     │  irq_addr_in[5:0]  ← irq_bus     │
                     │  pc_addr_in[7:0]  ← pc（取指指针）│
                     │  bytmov[7:0]      ← decoder      │
                     │  iret[1:0]        ← decoder      │
                     │  ──────────────                  │
                     │  irq_addr[7:0]   → pc 跳转目标    │
                     │  irq_flush       → pc/if_reg/decoder 冲刷 │
                     └─────────────────────────────────┘
```

- 中断源：目前**只有 uart_rx**。`rx_done` 不再进寄存器堆，直接走中断路径。
- `irq_bus[5:0]` 布局：`[5:3]`=源号（001=UART），`[2:0]`=子源（暂恒 0）。
- 向量表 `irq_vex[0:15]`：`irq_vex[0] = 232`（0xE8，ISR 入口）；索引
  `irq_vex[irq_addr_in[5:3] + irq_addr_in[2:0] - 1]` → UART 即 `irq_vex[0]`。

### 1.2 irq_controller 状态机（3 态）

```verilog
always @(posedge clk) begin
    irq_flush <= 1'b0;  irq_addr <= 8'b0;          // 默认无动作
    if (rst)                   irq_busy <= 0;
    else if (!irq_busy) begin                      // 空闲：可授权
        if (irq_addr_in != 0 && bytmov == 8'b0) begin
            irq_busy <= 1'b1;                      // 进中断态
            irq_flush <= 1'b1;                     // 冲刷流水线 + pc 跳向量
            pc_addr  <= pc_addr_in;                // ★ 保存断点
            irq_addr <= irq_vex[irq_addr_in[5:3]+irq_addr_in[2:0]-1];
        end
    end
    else begin                                     // 中断态：等 IRET
        if (iret == 1'b1) begin
            irq_busy  <= 1'b0;                     // 出中断态
            irq_flush <= 1'b1;                     // 再冲刷一次
            irq_addr  <= pc_addr;                  // ★ 恢复断点
        end
    end
end
```

- `irq_flush` 只拉一拍：`pc.v` 里 `if (irq_flag) pc_addr <= irq_addr` 完成跳转，
  if_reg/decoder 同步冲刷（flush1），中断指令不被流水线挤出。
- **不可重入**：`irq_busy` 锁存期间不响应新中断，直到 IRET。

### 1.3 断点保存/恢复与 bytmov 延迟授权（★ 用户的 offset-race 修复）

**问题**：grant 时机若落在分支/跳转指令译码那一拍，`bytmov != 0`——此时保存的
`pc_addr_in` 是"分支后的抓取指针"，IRET 恢复回去会落到偏移后的地址（甚至落进程序空洞），
表现为"恢复点错开"（r1/r4 错开、偶发进 0x24 空洞）。

**修复**：授权条件加 `bytmov == 8'b0`——bytmov 是 decoder 对**当前正在译码指令**的输出，
只有非分支/跳转指令才为 0。等 bytmov 归 0 再授权，保证保存的 `pc_addr_in` 一定是
**干净指令边界**（如 0x14 = 主循环 ADDI r1,r1,1）。

**验证**：`irq_test.hex` 特意把 0x24-0xE7 留空（空洞版）——若偏移未根除，IRET 会恢复进
空洞跑 x 垃圾 → 超时。实测 [FLUSH] 打印 `saved_resume` 落在主循环内非分支指令上
（本次采样 0x1C，随中断命中时机在 0x14/0x18/0x1C 间变化），3 次中断恢复点全对，空洞从未进入。

### 1.4 IRET 指令（新接入中断链路）

- 作用：decoder 译出 `iret=1'b1` → irq_controller 收到后清 `irq_busy`、把保存的断点
  灌回 `irq_addr`、再冲刷一拍 → pc 回到中断前下一条。（编码见 `指令集说明/mc_v1.1_ins.md`）
- v1.0 里 IRET 就存在但恒 `iret=0`（死代码），本版随中断链路启用。

## 2. UART 收发方案：轮询 → 中断

### 2.1 为什么弃轮询

v1.0 把 `rx_done` 经 `uart_sig_out` 写进 `regs[254]`，程序用 `LBEQ r254,r0` 自旋等待。
但 **regs[254] 在 reg_f 里从未被写入**（reg_f 只更新 `regs[255] <= {tx_busy}`）——
`regs[254]` 是死寄存器，轮询程序永远等不到 → 段3 超时（见调试记录 2）。
既然中断方案（`rx_done → rx_irq`）已打通，轮询段3 整段删除。

### 2.2 当前接口（uart_top）

```verilog
output reg tx_busy, rx_irq;     // 取代 v1.0 的 uart_sig_out[1:0]
...
tx_busy = busy;                 // → reg_f regs[255]（保留，供主程序轮询发送忙）
rx_irq  = rx_done;              // → 中断路径（不再进寄存器堆）
```

- `regs[254]` 空出，用户程序可用。
- 中断上下文里总线访问有效：ISR 内 LBU/SB 正常读写（`LBU rd,0x4000` 读 rx、
  `SB rs,0x4000` 发送、`SB rs,0x2000` 写 data_ram；irq_test 已覆盖）。
  各外设地址与用法见 `指令集说明/mc_v1.1_ins.md` §2。

## 3. 两级复位同步器（[Place 30-99] 根治）

### 3.1 问题

`rst = ~rst_n` 直接接到 CPU+UART **所有触发器的异步复位脚**，扇出极大。综合会把
`rst_n` 送 BUFG 全局分发；但 IO 引脚 → BUFG **无专用时钟通路**，布局报死：

```text
[Place 30-574] Poor placement for routing between an IO pin and BUFG
  rst_n_IBUF_inst (IBUF.O) locked to IOB_X0Y1
  rst_n_IBUF_BUFG_inst (BUFG.I) provisionally placed by clockplacer on BUFGCTRL_X0Y0
[Place 30-99] Placer failed with error: 'IO Clock Placer failed'
```

### 3.2 修复（single_mcu_top 内）

```verilog
reg rst_n_s1 = 1'b1;
reg rst_n_s2 = 1'b1;
always @(posedge clk) begin
    rst_n_s1 <= rst_n;
    rst_n_s2 <= rst_n_s1;
end
wire rst = ~rst_n_s2;
```

- `rst_n` 现在只接**两个同步器触发器**，扇出降为 2，不再触发 BUFG 全局分发。
- 复位源变成触发器输出：**释放沿与 clk 对齐**，并消除跨时钟域亚稳态。
- 复位无时序要求，两拍延迟无害；上电默认 `1'b1` → 不复位，正常。
- 顺带清理：v1.0 阶段加的临时约束 `CLOCK_DEDICATED_ROUTE FALSE [get_nets rst_n_IBUF]`
  在同步器接入后 net 不再存在，`get_nets` 返回空 → 报 `set_property expects at least one object`，
  已从 timing.xdc 删除（保留说明注释）。

## 4. 时序复核（50MHz，周期 20ns）

| 项 | MCU v1.0 | MCU v1.1 | 说明 |
|----|----------|----------|------|
| Setup（WNS） | 3.409ns | **2.977ns** | 满足（余量 ~3ns）。中断/复位逻辑并入后关键路径略变长 |
| Hold（WHS） | 0.056ns | **0.043ns** | 满足但最薄，见调试记录 4 |
| Pulse Width | 8.75ns | **8.75ns** | 满足 |

三项全正，无违例。**重点看 hold 0.043ns**——全设计最短路径（`wr_reg.rd_data → reg_f.regs`
写口，FF 直连、零组合逻辑）的物理极限附近。已试 ExtraNetDelay_low/high 布局指令无改善
（整片布局被重排，短路径未吃到额外延迟），结论：hold 为正即满足时序，**接受该余量**，
不为 43ps 改动流水架构。

## 5. 仿真验证

### 5.1 IRQ 全链路回归

程序：主循环 0x14-0x20（r1/r4 每圈 +1，r5 +2，LBEQ 回跳）→ 留空 0x24-0xE7 →
ISR 0xE8（r2++、LBU rx、SB 回发、SB 写 data_ram、IRET）。

| 检查项 | 覆盖点 | 结果 |
|--------|--------|------|
| 连发 'A'/'B'/'C' | 3 次中断，ISR 回发同字节 | ✅ 全回显正确 |
| r2 == 3 | 3 次中断全部处理 | ✅ |
| r3 == 0x7A | 主程序常量不被 ISR 破坏 | ✅ |
| r4==r1 多拍采样 | 中断无丢增量（单点采样有写回竞态，改 20 拍扫相等） | ✅ |
| data_ram[0]=0x43 | ISR 内总线写有效 | ✅ |
| [FLUSH] saved_resume=0x14 | 恢复点正确、空洞 0x24-0xE7 从未进入 | ✅ |

### 5.2 整机 tb（mcu_full_tb，清理后）

载入 `cpu_full_test.hex`：段1 算术/逻辑自检（r1..r11）→ 段2 调用返回（r12..r14）→ HALT。
段3 轮询 UART 已从 hex 与 tb 中**整段移除**（原 UART 收发捕获 always 块、sbit/sbyte 任务、
MCNT、段3 检查块全删）。现在是纯 CPU 整机测试，14 项寄存器检查全绿。

### 5.3 运行方式

```bash
# 整机（mcu_full_tb，纯 CPU 整机测试；源码拆 core/ + peripherals/ + mcu/ 子目录）
cd project_self-try.srcs && /d/iverilog/bin/iverilog -g2012 -o /tmp/mcu_sim \
    sources_1/new/mcu/single_mcu_top.v sources_1/new/core/*.v sources_1/new/peripherals/*.v \
    sim_1/new/mcu_full_tb.v && /d/iverilog/bin/vvp /tmp/mcu_sim
# 注：peripherals/ 下编辑中的文件（如 gpio_group.v）会挡编译，单独列出其余源码跳过即可。
```

IRQ 回归 tb（`/e/tmp/irq_test_tb.v`）已清理，需要时按 §5.1 的测点复刻即可。

## 6. 调试记录

### 记录 1：r1/r4 错开 = 写回错拍（不是 bug）

- 现象：IRQ 测试里 r1 常比 r4 大 1。
- 排查：先怀疑中断丢增量，后用探针证明——`ADDI r1`(0x14) 与 `ADDI r4`(0x18) 是相邻指令，
  写回天然错 1 拍，**r1 永远领先 r4 一个周期的窗口**；且每 25.6us 回绕（0xFF→0x00，8bit）。
- 结论：正常流水线行为（rd_last1/rd_last2 前送已处理真实冒险），非 CPU 缺陷。
- 修法：tb 单点采样改**多拍采样**（20 拍内扫到 r1==r4 即判一致）。

### 记录 2：段3 超时根因 = regs[254] 永不更新

- 现象：mcu_full_tb 段3（`LBEQ r254,r0` 自旋等 rx）超时。
- 证明：交换复位同步器 vs 直连复位做 revert 测试，段3 依旧超时 → **与本版改动无关，是既有 bug**。
- 根因：`rx_done` 只接 `rx_irq`（中断路径）；reg_f **从不写 regs[254]**（只写 regs[255]）。
  轮询程序等的寄存器永远不变 → 死循环。
- 修复：放弃轮询，收发改走中断（段3 删除）。这就是"我有中断了还用轮询吗，不要了吧"。

### 记录 3：[Place 30-99] IO Clock Placer failed

- 现象：布局阶段硬错误，IO 引脚到 BUFG 无专用时钟通路（见 §3.1）。
- 两步修复：先 `CLOCK_DEDICATED_ROUTE FALSE` 临时降级放行 → 再上两级复位同步器根治
  （复位源变触发器输出，不再走 BUFG）。
- 注意：临时约束在根治后变死约束（net 消失报错），已删，文档留档以免误加回。

### 记录 4：hold 43ps 最短路径（wr_reg.rd_data → reg_f.regs 写口）

- 现象：时序报告 Hold 列 0.043ns，薄如发丝，其余全部宽裕。
- 定位：`report_timing -hold -slack_lesser_than 0.2 -max_paths 20` → 路径为
  `wr_reg.rd_data → reg_f.regs[rd]` 写口。
- 原理：Setup 怕长路径、**Hold 怕短路径**。这条路径 FF 直连写口、**零组合逻辑**，
  是全设计最短路径——新数据一拍内瞬间到写口，hold 窗口只剩布线延迟那点余量。
- 处理：试 ExtraNetDelay_low / _high 布局指令，均无改善（placer 整体重排但短路径没吃到
  额外延迟）。hold 为正即满足时序、比特流有效；**加流水寄存器根治的代价（改写回时序、
  tb 全重验）换 43ps 不值，接受**。

## 7. 已知限制

| 限制 | 说明 |
|------|------|
| 单中断源 | 只有 uart_rx（irq_bus[5:3]=001）；向量表 15 槽仅用了 0 号 |
| 不可重入 | irq_busy 锁存，ISR 内不响应新中断，直到 IRET |
| 无中断优先级/嵌套 | 多源未来需扩展仲裁 |
| UART FIFO 深 63 | RX 已加 64 深 FIFO（有效 63 字节）；超深突发仍取决于软件消费速度 |
| regs[255]=tx_busy | 仅此一个 IO 寄存器（regs[254] 已空出） |
| 总线访问 2 拍 | 每笔 RAM 访问 stall 1 拍（v1.0 继承） |
| 条件分支 1 拍气泡 | 分支预测=不跳（v1.0 继承） |
| 栈深 255 | j 满/空栈由 j_flag 保护（v1.0 继承） |
| 上板未实测 | 引脚已约束（N18/L17/L16/P16，LVCMOS33），板测待补 |

## 8. 后续规划

- [x] 中断控制器 + bytmov 延迟授权断点修复 —— v1.1
- [x] UART 收发改中断（弃轮询，段3 移除）—— v1.1
- [x] 两级复位同步器根治 [Place 30-99] —— v1.1
- [x] hold 最短路径定位与结论（接受 43ps）—— v1.1
- [ ] 上板：引脚约束已备，回环板验
- [x] rx FIFO / 双缓冲（多字节连续收发不丢）—— v1.1 收尾
- [ ] 更多外设 / 更多中断源（GPIO、timer）
- [ ] 中断优先级与嵌套
- [ ] asm.py 汇编器（手拼字节改助记符）

---

*本文件随项目演进同步更新。*
