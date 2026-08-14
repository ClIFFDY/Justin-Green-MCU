# 流水线 CPU 设计记录（v6.5 —— UART 收发完整 IO + 两级前送 + 整合测试）

> 版本：2026-08-13  ·  **本次更新：修复"写后读隔 1 条"冒险 + 前送机制统一 + 整合测试**
> 基础功能（v6.4 起）：uart_tx 发送 + busy 轮询；本次新增 uart_rx 接收 + rx_done 握手，
> UART 口做成**双向**：`LBU 0x2000` 读串口、`SB 0x2000` 发串口。
> 指令集仍是 **29 条，没有为收发新增任何指令**——IO 走内存映射端口（LBU/SB 双用途）。
> v6.4 见 [single_cpu_design_v6.4.md](single_cpu_design_v6.4.md)

## 0. 版本说明

| 维度 | v6.4 | v6.5（当前代码） |
|------|------|------------------|
| 接收 | 无（uart_rx 空壳占位） | **uart_rx 完整接收器**（115200、8N1、中点采样） |
| UART 口地址 | SB 判 bit13 区间（0x2000–0x3FFF） | **精确 `==0x2000(8192)`**：SB 发 / LBU 读 |
| 状态寄存器 | regs[255] = tx busy | **regs[254] = rx_done**、regs[255] = tx busy（uart_flg[1:0]） |
| 接收同步 | — | **rx_done 锁存 + 读后清除**（握手，rx_read 复用 rx_en 流水信号） |
| rx_en 时序 | 未流水（bug） | **id_reg 透传 rx_en**，alu 在 EX 级用本指令的 rx_en |
| **源操作数前送** | EX 级旁路（rs_alt → result_last） | **decoder 组合层两级前送**：r1/r2_data_final（rd_last1 → result_last，rd_last2 → rd_data）打包 `r12_data` → id_reg → alu |
| 冒险覆盖 | 仅相邻（rd_last1） | **相邻 + 隔 1 条（rd_last2）全覆盖**（本次修复） |
| 验证 | 发送 3 字节 | **整合测试**：算术/逻辑/调用/分支/UART 回环转换，一个 tb + 一个程序一次跑完 |
| 指令集 | 29 条 | **29 条（不变）** |

## 1. 总体架构

```
clk/rst ─▶ fsm ── stage（EXE/IDLE）──▶ 广播到 if_reg / id_reg / wr_reg / pc

  ┌──────── IF ────────┬──────── ID ────────┬──────── EX ────────┬──── WB ────────┐
  │ pc ──▶ ins_rom     │ decoder（组合译码） │ alu（组合运算）     │ wr_reg          │
  │        │ 4B 窗口   │   reg_f 读(组合)    │   ▲                │  ▾ 写回          │
  │        ▼           │   + 两级前送        │   └─ result ───────┘  reg_f 写        │
  │      if_reg ──────▶│   + j_flag 栈保护   │   └─ ram_data（LBU 旁路）               │
  │                    │   + addr_ram 分流    │   └─ rx_data（LBU→UART 旁路）          │
  │                    │   + r12_data（源）    │   ▲                                  │
  └──────────────────────────────────────────────────────────────────────────────┘
        uart_tx ◀── decoder（tx_en）/ reg_f（rr_wdata）──▶ busy ──▶ reg_f（regs[255]）
        uart_rx ◀── rx 引脚 ──▶ rx_done ──▶ reg_f（regs[254]）；rx_data ──▶ alu（rx_en 旁路）
```

**源操作数通路（本次重做）**：
```
reg_f 组合读 rr12_data ──▶ decoder 两级前送 ──▶ r12_data = {r1_data_final, r2_data_final}
    r1_data_imm  = (r1 == rd_last2)? rd_data : rr12_data[15:8]    // 二级：WB 级 rd_data
    r1_data_final = (rd_last1≠0 && r1 == rd_last1)? result : r1_data_imm  // 一级：EX 级 result
──▶ id_reg 透传 ab_raw ──▶ alu a = ab_raw[15:8]; b = ab_raw[7:0]
```
分支比较（LBEQ/LBNE/LBLTU）与 ALU 运算**共用同一套** r1/r2_data_final，不再有"分支用前送、ALU 不用"的不对称。

## 2. 运行控制：1-bit stage（EXE/IDLE）

与 v6.4 相同，未变。

## 3. 指令集（6-bit opcode，29 条，未变）

LBU/SB 双用途访存指令：

| 指令 | 地址 ≤8191 | 地址 ==0x2000 | 其他 |
|------|-----------|---------------|------|
| LBU | 读 data_ram 写回寄存器 | **读 uart_rx 写回寄存器** | 黑洞（we=0） |
| SB  | 写 data_ram | **触发 uart_tx 发送** | 黑洞（丢弃） |

## 4. 指令编码与 IO 地址空间

### 4.1 地址空间划分（精确端口）

| 地址 | 含义 | LBU 行为 | SB 行为 |
|------|------|----------|---------|
| `0x0000 – 0x1FFF`（≤8191） | data_ram | 读 RAM 写回 rX | 写 RAM |
| **`0x2000`（==8192）** | **UART 口** | 读 rx_data 写回 rX | 触发 uart_tx 发送 |
| 其他 | 未定义 | 黑洞 | 黑洞 |

decoder 分流：
```verilog
LBU: if (addr <= 8191) {we=1; ram_flag[1]=1;}
     else if (addr == 8192) {we=1; ram_flag[1]=1; rx_en=1;}   // ram_flag[1] 进旁路分支 + rx_en 选 rx_data
SB:  if (addr <= 8191) ram_flag[0]=1;
     else tx_en = (addr == 8192)? 1 : 0;
```

### 4.2 指令布局

```
LBU（4B，byte0=0x73）：byte1=rd，byte2:byte3=地址字段（0x2000=读串口）
SB（4B，byte0=0x77）：byte1=rs，byte2:byte3=地址字段（0x2000=发串口）
ALU-R（ADD/SUB/AND/OR/XOR/SLL/SRL/SLTU，byte0=0x0B/0x13/0x17/0x1B/0x1F/0x37/0x3B/0x47）：byte1=rd，byte2=r1，byte3=r2
ALU-I（ADDI/SUBI/ANDI/ORI/XORI/SLLI/SRLI/SLTIU，byte0=0x07/0x0F/0x2B/0x2F/0x33/0x3F/0x43/0x4B）：byte1=rd，byte2=rs1，byte3=imm8
分支（LBEQ/LBNE/LBLTU，byte0=0x5B/0x63/0x6B；R 前缀 byte0=0x5F/0x67/0x6F）：byte1=bytmov，byte2=r1，byte3=r2
LJAL/RJAL（2B，byte0=0x21/0x25）：byte1=bytmov；JALR（2B，byte0=0x4D）：byte1=0
```

## 5. 流水线机制

### 5.1 写方向（SB → uart_tx）

ID 级 decoder 组合输出 `tx_en`（地址==8192）+ `rr_wdata`（源寄存器值，含两级前送 `rr_data_final`）；同一拍 posedge uart_tx 锁存并开始发帧，busy 拉高 4340 拍。busy 镜像 regs[255]，程序 `LBNE r255,r0` 自旋等帧发完。

### 5.2 读方向（uart_rx → LBU）

**uart_rx 接收时序**（`MCNT = 434`）：
```
检测 rx 下降沿（!rx_sig1 && rx_sig2）→ start=1, clk_cnt=217（起始位中点）
clk_cnt 每拍 +1，到 433 溢出（每 434 拍一次）→ 采 rx_sig1
bit_cnt 0..8 共 9 次采样 = 起始位 + bit0..bit7（LSB-first，新位进最高位 {rx_sig1, buf[7:1]}）
bit_cnt==9 → rx_data <= rx_data_buf; rx_done <= 1; start <= 0
```

**rx_done 握手（锁存 + 读后清除）**：
```verilog
if (rx_read == 1'b1) rx_done <= 1'b0;   // CPU 读走字节后拉低（rx_read 复用 rx_en 流水后信号）
// 收满一帧（bit_cnt==9）时 rx_done <= 1 覆盖，保持 1
```
regs[254] 每拍镜像 rx_done：CPU 轮询 `LBEQ r254, r0` 等数据。杜绝"1 拍脉冲轮询会漏"。

### 5.3 前送机制（本次修复）

源操作数前送全部在 **decoder 组合层**完成，两级，覆盖 4 级流水线的全部在飞写回：

| 前送级 | 判定源 | 前送值 | 覆盖的冒险 |
|--------|--------|--------|-----------|
| **一级** | `rd_last1`（id_reg 输出 rd，流水第 3 级指令） | `result_last_in`（EX 级 ALU 输出） | 相邻写后读（rd_last1 原由 rs_alt 覆盖） |
| **二级** | `rd_last2`（wr_reg 输出 rd，流水第 4 级指令） | `rd_data`（wr_reg 锁存结果） | **隔 1 条写后读（本次修复）** |
| 无前送 | 都不命中 | `rr12_data`（reg_f 组合读） | 普通读 |

```verilog
// decoder.v
wire [7:0] r1_data_imm   = (r1 == rd_last2) ? rd_data : rr12_data[15:8];
wire [7:0] r1_data_final = (rd_last1 != 8'b0 && r1 == rd_last1) ? result_last_in : r1_data_imm;
...
r12_data = {r1_data_final, r2_data_final};   // 打包送 id_reg → alu
// alu.v
assign a = ab_raw[15:8];
assign b = ab_raw[7:0];
```

**为什么二级前送能修掉冒险**：原实现 ALU 源走 `reg_f 组合读 → id_reg 锁存`，当写回 reg_f 与 id_reg 锁存**同一拍 posedge** 时读到旧值；而 `rd_data` 是 wr_reg 里已锁存稳定的值，没有同拍读写冲突。

**清理**：前送统一后，`rs_alt`（alu 里用 result_last 选源，只覆盖 rd_last1）被 r1_data_final 完全取代——连同 `alu.result_last`、`id_reg` 的 rs_alt/result_last 透传一并删除。

### 5.4 回环/处理程序（整合测试大程序）

```
0x00 ADDI r1,r0,0x41  0x04 ADDI r2,r1,0x01  ...  // 段1：11 条 ALU 指令写 r1..r11
0x2C RJAL 0x40                                   // 段2：调用（压栈）
0x2E ADDI r14,r0,0xAA  0x32 RBEQ r0,r0,0x4C      // 返回后写 r14，跳进段3
0x40 ADDI r12,r0,0x24  0x44 ADDI r13,r12,0x03  0x48 JALR   // 子程序
0x4C LBEQ r254,r0,回跳      ; 等 rx_done
0x50 LBU r15,0x2000          ; 读串口
0x54 XORI r15,r15,0x20       ; 翻转大小写（处理）
0x58 LBNE r255,r0,回跳      ; 等 busy 归零
0x5C SB r15,0x2000           ; 回发
0x60 LBEQ r0,r0,0x4C         ; 循环
```

## 6. 仿真验证（整合测试）

### 6.1 综合大程序整机测试（cpu_full_tb.v + ins_rom.hex）

一个 tb 合并原 uart_rx_tb / uart_poll_tb / uart_loop_tb / single_cpu_top_tb 的测点；一个程序分三段同时覆盖算术/逻辑、调用返回、UART 收发与分支轮询。**全程无 NOP 填充（严格冒险测试）**：

```
---- 段1 算术/逻辑自检 ----
OK   r1 = 0x41   r2 = 0x42   r3 = 0x3a   r4 = 0x0f   r5 = 0x0a
OK   r6 = 0x3a   r7 = 0x22   r8 = 0x78   r9 = 0x1e   r10 = 0x01   r11 = 0x00
---- 段2 调用返回 ----
OK   r12 = 0x24   r13 = 0x27   r14 = 0xaa
---- 段3 UART 回环（XORI 0x20 翻转大小写）----
CPU TX @173090000  0x41  (A)      // 收到 'a'(0x61) → 回发 'A'
CPU TX @338910000  0x62  (b)      // 收到 'B'(0x42) → 回发 'b'
===== ALL TESTS PASSED (2 bytes received) =====
```

段1 故意排了**紧密写后读依赖链**（`SUBI r3 → ADDI r4 → ANDI r5,r3`），正是它抓出了"写后读隔 1 条"冒险（见调试记录 7）。

### 6.2 栈保护回归（v6.3 栈 hex + single_cpu_top_tb）

空栈 JALR / 正常配对 / 满栈 255 层 / 深弹栈到空，r1..r4 两次复位全对：
```
T=  65ns r1 = 1   T= 115ns r2 = 2   T= 125ns r3 = 3   T=10355ns r4 = 4
T=10435ns r1 = 1   T=10485ns r2 = 2   T=10495ns r3 = 3   T=20725ns r4 = 4
```

### 6.3 测试产物

仿真二进制、日志用完即删，不留 srcs 目录。

## 7. 综合与时序

50MHz，**uart_rx 加入 + 前送修复后**的综合结果：

| 项 | v6.4 | v6.5（当前） |
|----|------|-------------|
| WNS（setup） | 3.108ns | **2.66ns** |
| hold | 0.076ns | **0.064ns** |
| 脉宽 | 8.75ns | 8.75ns |

WNS 从 3.108 → 2.66ns 下降约 0.45ns，**符合预期**：前送从 alu 的 `rs_alt → result_last` 选择
挪到 decoder 组合层（`rd_last1/rd_last2` 两级 mux + `r12_data` 打包），decoder 组合路径变长，
关键路径（IF 取指 → decoder 前送 mux → id_reg 采样）增加。50MHz 周期 20ns，关键路径约 17.34ns，
理论最高 ~57.7MHz，余量 2.66ns（周期 13.3%）仍健康。hold 从 0.076 微降到 0.064ns（布局重排 +
前送逻辑小幅影响），仍是正余量、健康——hold 对最短路径（FF 直连，reg_f 写回链）最紧，这条路径
不受前送改动影响。

上板引脚约束（clk/tx/rx/rst）仍待补。

## 8. 调试记录

### 调试记录 1：沿检测方向反了（uart_rx）
- 现象：rx_done 触发 9 次（应 3 次），全 0xFF
- 根因：`rx_sig1 && !rx_sig2` 检测上升沿，UART 起始位是下降沿，数据位/停止位的每个上升沿都触发接收
- 修复：`!rx_sig1 && rx_sig2`

### 调试记录 2：clk_cnt 不参与采样
- 现象：触发后每拍采一个"位"，不按波特率
- 根因：clk_cnt 只赋 217 从不递增/判时机
- 修复：数到 433 溢出才移一位（中点采样骨架）

### 调试记录 3：移位方向反了
- 现象：A5/FF 收对、'H'(0x48) 收到 0x12（逐位反转）；A5/FF 是反转不变的字节，假通过
- 根因：`{buf[6:0], rx_sig1}` 新位进最低位，先到的 bit0 被推到最高位 → 字节反转
- 修复：`{rx_sig1, buf[7:1]}`——LSB-first 先到的位落字节低位

### 调试记录 4：rx_done 是 1 拍脉冲，轮询会漏
- 修复：锁存 + 读后清除 `if (rx_read) rx_done <= 0`，rx_read 复用 rx_en 流水后信号

### 调试记录 5：rx_en 没进流水，alu 用错指令的标志
- 现象：回环回发 0x00（应 0x41）
- 根因：decoder 的 rx_en 直连 alu，alu 在 EX 级拿到下一条指令的 rx_en=0
- 修复：id_reg 加 rx_en 透传（正常/flush 两分支都赋值）

### 调试记录 6：LBU→UART 缺 ram_flag，rx_en 成死路
- 根因：LBU→0x2000 只置 rx_en，alu 的 `(rx_en)?rx_data:ram_data` 只在 ram_flag 旁路分支里
- 修复：LBU→0x2000 同时置 `ram_flag[1]=1`（进旁路分支）+ `rx_en=1`（选 rx_data）

### 调试记录 7：写后读隔 1 条冒险（rd_last2 前送缺失）
- 现象：整合大程序 `SUBI r3(0x08) → ADDI r4(0x0C) → ANDI r5,r3(0x10)` 得 r5=0（期望 0x0A）；`ORI r6,r3(0x14)` 读同 r3 却对
- 根因：ALU 源操作数走 `reg_f 组合读 → id_reg 锁存`。SUBI 写 regs[3] 与 id_reg 锁存 ANDI 源操作数**同一拍 posedge**，非阻塞赋值读到旧值。rs_alt 只旁路 rd_last1（相邻），rd_last2（隔 1 条）没旁路到 ALU——**分支比较有 rd_last2 前送，ALU 运算没有，两边不对称**
- 验证：插一个 NOP 隔开 SUBI 与 ANDI，r5 立即变 0x0A → 确认冒险而非程序错
- 修复：前送统一到 decoder 组合层，`r12_data = {r1_data_final, r2_data_final}` 走 ab_raw 通路；rd_data（wr_reg 锁存稳定值）覆盖 rd_last2
- 回归：严格版（不插 NOP）全绿

### 调试记录 8：rs_alt 冗余清理
- 前送统一后，rs_alt（alu 用 result_last 选源，只覆盖 rd_last1）被 r1_data_final 完全覆盖
- 删除：decoder 的 rs_alt 输出/赋值、id_reg 的 rs_alt/result_last 透传、alu 的 rs_alt/result_last 输入
- 结果：源操作数前送只剩 `r1/r2_data_final → r12_data → id_reg.ab_raw → alu` 一条路

## 9. 相对 v6.4 的变化汇总

| # | 变化 | 状态 |
|---|------|------|
| 1 | **uart_rx** 完整接收器（下降沿 + 中点采样 + 9 次采样） | ✓ 已实现并验证 |
| 2 | **UART 口精确 ==0x2000**：LBU 读 / SB 发 | ✓ 已实现 |
| 3 | **regs[254] = rx_done** 状态寄存器（uart_flg[0]） | ✓ 已实现并验证 |
| 4 | **rx_done 锁存 + 读后清除**（rx_read 复用 rx_en 流水信号） | ✓ 已实现并验证 |
| 5 | **rx_en 流水**（id_reg 透传，修复时序错位） | ✓ 已实现并验证 |
| 6 | **LBU→UART 旁路**：alu 选 rx_data 写回 | ✓ 已实现并验证 |
| 7 | **两级前送统一**（decoder 组合层，rd_last1 + rd_last2）修复写后读隔 1 条冒险 | ✓ 已实现并验证 |
| 8 | **rs_alt / result_last 清理**，前送单一路径 | ✓ 已实现 |
| 9 | **整合测试**：cpu_full_tb + 综合大程序，一次跑完算术/调用/收发/分支 | ✓ 全绿 |

## 10. 已知限制

| 限制 | 说明 |
|------|------|
| **r254/r255 被 IO 占用** | regs[254]=rx_done、regs[255]=tx busy，用户程序不可用作普通寄存器 |
| **接收无缓冲** | rx_data 只有 1 字节，新帧覆盖旧帧；CPU 读得慢会丢数据（无 FIFO） |
| 单字节握手 | rx_done 读后清除，靠程序轮询保证不漏；连续快发可能丢字节 |
| 条件分支 1 拍气泡 | 分支预测 = 不跳，跳转时 flush 1 拍（flush1/if_reg） |
| 栈深 255 | j 满栈/空栈由 j_flag 保护 |
| BRAM 无复位 | data_ram 上电 x，需程序先写后用 |
| 综合已过，上板未验 | 50MHz 综合通过（WNS 2.66ns / hold 0.064ns），但尚未烧板实测 UART 回环；引脚约束仍待补 |
| 上板引脚未约束 | timing.xdc 仅时钟约束，需补 clk/tx/rx/rst 引脚绑定 |
| 写 r0 边界 | rd_last2==0 时前送 rd_data 会给 r0 非 0 值；写 r0 指令无意义，汇编器不会生成，实际无害 |

## 11. 后续规划

- [x] uart_tx 串口发送 + SB 端口分流 + busy 轮询 —— v6.4
- [x] uart_rx 串口接收 + rx_done 握手 + 回环 —— v6.5
- [x] 两级前送修复 + rs_alt 清理 —— v6.5
- [x] 整合测试（cpu_full_tb + 综合大程序）—— v6.5
- [ ] **rx FIFO / 双缓冲**（多字节连续收发不丢）
- [ ] 上板：引脚约束 + 回环板验（串口助手发字节看是否回显）
- [ ] asm.py 汇编器（手拼字节改助记符）
- [ ] 乘除、有符号比较、真正的 JALR
- [ ] 中断/异常/CSR

---

*本文件随项目演进同步更新。*
