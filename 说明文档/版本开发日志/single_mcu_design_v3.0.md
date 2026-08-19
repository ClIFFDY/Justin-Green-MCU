# MCU 设计记录（v3.0 —— 核心架构重构 + LIND/SIND 指令 + 俄罗斯方块 v2）

> 版本：2026-08-19。**v3.0 是核心架构 + ISA 扩展版**：在 v2.3.1（RTOS shell）基础上做 WNS 时序优化架构重构（**reg_f 同步读**、**流水线 if_reg→pre_decoder**、**ram_top 读握手重做**），并新增 **LIND/SIND 寄存器间接访存指令**，以此为硬件基础实现**俄罗斯方块 v2**。
> 指令集速查见 `指令集说明/mc_v3.0_ins.md`（新增 LIND/SIND，指令总数 32→34）。
> v2.3/v2.3.1 的中断/RTOS 语义（irq 读路径、IRQ_W else-if 写在前、regs[254]=j 调用栈分区、抢占调度器、菜单式 shell）**接口不变**，但 reg_f/ram_top 实现重写；俄罗斯方块是**单任务演示程序**（不用 RTOS）。
> 核心变化（2026-08-19）：
> ① **核心架构重构（WNS 优化）**：reg_f **异步读→同步读**（posedge 采样 + 读后写转发 + stall 冻结）；流水线 `if_reg`→`pre_decoder`（拆包/cstall/irq_en/addr_dr12 职责迁移 + **addr_dr12 补全所有指令类型**）；ram_top **读握手重做**（写不 stall、done 读相位翻转、空闲清零）；id_reg **rd 写回修复**（rd_in=inst_raw[23:16]）；
> ② **LIND/SIND 指令**（ISA 新增 2 条）：`LIND rd,r1,r2` 读 `[regs[r1]:regs[r2]]`、`SIND rs,r1,r2` 写 `[regs[r1]:regs[r2]]`，寄存器间接 16 位寻址；**LIND 地址锁存硬件修复**（组合地址只维持 1 拍 → 连续读第 2 个读到 0）；
> ③ **俄罗斯方块 v2**：LIND/SIND 循环化渲染/碰撞/清行，字段 20 行 × 16bit 行掩码，ROM 优化（形状表 28 态→7 基础形状+旋转公式、清内存/4 格操作循环化）**2044→1653 词**；
> ④ **修 6 类程序 bug**：check_cell 破坏 r1（初始 game over）、set_cell 破坏 r5（渲染错位/字段污染）、col 8/9 四重 8 位溢出（块到最右两列被吞）、旋转 anchor 不跟随（旋转回顶端）、spawn anchor（顶层生成）、旋转 new_rot 存 r9 被 check_cell 破坏（旋转只能生效一次）。

## 0. 版本说明

| 维度 | MCU v2.3.1 | MCU v3.0（当前） |
|------|------------|------------------|
| 寄存器读 | **异步读**（assign 组合，r0 特判） | **同步读**（posedge 采样 + 读后写转发 + stall 冻结）—— WNS 优化 |
| 流水线 | ins_rom → if_reg → decoder | ins_rom → **pre_decoder** → decoder（if_reg 重构迁移） |
| RAM 握手 | stall 含写；done 无空闲清零 | 写不 stall；done 读相位翻转 + 空闲清零 |
| 指令集 | 32 条真实指令 | **34 条：+ LIND / SIND（寄存器间接访存）** |
| 中断/irq 读/IRQ_W/regs[254] | v2.3 定版 | **接口相同**（实现重写 reg_f，语义不变） |
| RTOS/shell | 抢占调度器 + 菜单式 shell | **保留**（俄罗斯方块为单任务演示，不用 RTOS） |
| 系统程序 | rtos_shell（菜单式） | rtos_tetris_v2（俄罗斯方块，LIND/SIND 演示） |
| 汇编器 | .puts / 自动 jpad / 转义 | **+ LIND/SIND 编码支持** |
| 上板实测 | v2.3.1 待上板 | **v3.0 待上板**（微测 + 仿真全过） |

## 1. 核心架构重构（WNS 优化，本轮硬件重点）

> 目标：缩短关键组合路径（异步读 + 转发 mux 链）换时序裕量，指令集/汇编接口尽量不变。

### 1.1 reg_f 同步读（异步 → 同步）

**v2.3.1（异步读）**：
```verilog
assign rd12_data[15:8] = (r1 == 8'b0) ? 0 : regs[r1];   // 组合读，在关键路径
assign rd12_data[7:0]  = (r2 == 8'b0) ? 0 : regs[r2];
```
**v3.0（同步读）**：
```verilog
always @(posedge clk) begin
    if (!stall) begin
        rd12_data[23:16] <= (addr_r12[23:16] == rd && we) ? rd_data : regs[addr_r12[23:16]];
        rd12_data[15:8]  <= (addr_r12[15:8]  == rd && we) ? rd_data : regs[addr_r12[15:8]];
        rd12_data[7:0]   <= (addr_r12[7:0]   == rd && we) ? rd_data : regs[addr_r12[7:0]];
    end
    else rd12_data <= rd12_data;
end
```
- **posedge 采样**替代组合读（读时序与写同沿 → 引入读后写转发）；**stall 冻结** rd12_data。
- **同沿同步读写问题**：`regs[rd] <= rd_data`（写）与 `rd12_data <= regs[addr]`（读）同一时钟沿 → 读到旧值。**读后写转发** `(addr_r12==rd && we) ? rd_data : regs[addr]` 解决。
- 分支寄存器 4 位（r0-r15）限制 + 汇编器 bytmov 死区自动补 NOP 等既有约定不变。

### 1.2 流水线 if_reg → pre_decoder

- `if_reg.v` 重构为 `pre_decoder.v`（拆包 cstall、irq_en 门控、addr_dr12 读端口、inst_raw 寄存职责迁移，接口在 single_cpu_top 对接）。
- **Bug A 修复（pre_decoder.addr_dr12）**：addr_dr12 补全对所有指令类型输出（此前普通指令地址恒 0 → 寄存器读端口全打 r0 → 白屏）。修复后 `addr_dr12 = inst_raw_in[23:0]`（r1/r2/r3 字段）。
- **id_reg rd 写回修复**：`rd_in(inst_raw[23:16])` 替代此前 `rd12_2`（寄存晚一拍 → 写回 rd 错位）。

### 1.3 ram_top 读握手重做

**v2.3.1**：`stall_bus = access && !done`；`if (access) done <= ~done`（写也参与翻转）。
**v3.0**：
```verilog
assign stall_bus = access && !done && !bus_sig_in[0];      // 写不 stall
always @(posedge clk) begin
    done <= 1'b0;
    if (access && !bus_sig_in[0]) done <= ~done;           // 读相位翻转
    else done <= 1'b0;                                     // 空闲清零
end
```
- **写不 stall**：SB/SIND 单拍完成，不再占 done。
- **空闲清零**：修复背靠背 LBU→LBU（第 2 个 LBU 读到第 1 个地址数据）——此前 done 无空闲复位，连续读错位。

### 1.4 调试遗留说明

- 此轮核心架构调试走"微测 + 探针逐拍"：reg_f 转发（同沿读写）、ram_top done 时序、pre_decoder addr_dr12、LIND 地址锁存——全部用非零数据微测验证（空数据会假通过）。
- 相关微测：`temp_tetris_tb/isr_test/`（bb/bb2/lindbb/lindlbu/sindlind/sblind/lind2-4/setcell89/checkcell89/printcells89 等）。

## 2. LIND/SIND 指令设计

### 2.1 编码（原长，flag=00）

| 指令 | opcode | byte0 | 布局 | 语义 |
|------|--------|-------|------|------|
| LIND rd, r1, r2 | 0x1F | 0x7C | byte1=rd, byte2=r1, byte3=r2 | rd = 读 `[regs[r1] : regs[r2]]` |
| SIND rs, r1, r2 | 0x20 | 0x80 | byte1=rs, byte2=r1, byte3=r2 | 写 `[regs[r1] : regs[r2]]` = rs |

- **寄存器字段 8 位**（0–255），任意寄存器可编；地址寄存器 r1/r2 可任选（俄罗斯方块 v2 用 r10/r11 避让返回寄存器 r1）。
- **地址 = regs[r1] 内容 << 8 | regs[r2] 内容**（16 位），与 LBU/SB 走同一总线（RAM/外设）。
- LIND/SIND 不压缩（恒原长 1 词）。

### 2.2 数据通路

- LIND：`bus_addr_out = {r1_data_final, r2_data_final}`（decoder 组合），读返回经 id_reg/alu 写回 rd（alu 对 LIND 同 LBU 处理 `result = bus_data`）。
- SIND：`bus_addr_out = {r1_data_final, r2_data_final}`，`bus_data_out = regs[rs]`（写不 stall）。

### 2.3 ⚠️ LIND 地址锁存硬件修复

**现象**：背靠背/连续 LIND 读，第 1 个正常、第 2 个读到 0（lindbb/lindlbu/sindlind/sblind 微测复现）。SIND 写正常，LBU 读正常。

**根因**（探针逐拍定位）：LIND 地址是组合路径（`{r1_data_final,r2_data_final}`），仅维持 1 拍；ram_top done 握手第 2 拍（done=1 采数据）时地址已失效：
```
LIND cyc25 | bus_addr=9000 access=1 done=0 stall=1   ← 第1拍地址有效
LIND cyc26 | bus_addr=0000 access=0 done=1 stall=0   ← 第2拍 done=1 采数据时地址已消失
```
对比 LBU（地址 = inst_raw 立即数，stall 冻结稳定 2 拍）读到数据正常。

**修复**：LIND/SIND 地址锁存维持到 done 拍。修复后 lindbb/lindbb2/sindlind/sindlind2/sblind/lindlbu **6 微测全过**。

## 3. 俄罗斯方块 v2（LIND/SIND 优化版）

`tools/rtos_tetris_v2.asm/.hex`（`gen_tetris_v2.py` 生成）。

### 3.1 字段与数据布局

| 区 | 地址 | 大小 | 说明 |
|----|------|------|------|
| FIELD | 0x9400-0x9427 | 40B | 20 行 × 2B 行掩码（16bit，bit c = 列 c） |
| RENDER_BASE | 0x9450-0x9477 | 40B | 渲染叠加掩码 |
| 方块状态 | 0x9430-0x9443 | 20B | P_* 4 格 / P_SHAPE/ROT/ANCHOR / C_* 4 格 |
| 游戏状态 | 0x9480-0x9484 | 5B | G_SCORE/LAST_TICK/ACC/OVER |
| RX 环形缓冲 | 0x9100-0x9109 | 10B | 8 槽 + WR/RD |
| 系统状态 | 0x9000-0x9005 | 6B | TICK/UART_S/TIMER_S |

**RAM 总量 121B / 16KB（0.7%）**。

### 3.2 LIND/SIND 应用

- **check_cell / set_cell / render / clear_lines** 全部用 LIND 读行掩码（lo+hi 两字节）+ SIND 写回，替代 v1 的逐地址 20 路分发。
- 行掩码位操作：set_bit（写位）、位移测位（碰撞）、print_cells（渲染）共用 16bit 行掩码语义。

### 3.3 ROM 优化（2044 → 1653 词，省 19%）

1. **形状表压缩**：compute_cells 28 态内联 → **7 基础形状 + transform 旋转公式**（`(dr,dc)→rot1(dc,-dr)/rot2(-dr,-dc)/rot3(-dc,dr)`），每格 RJAL transform。**LIND/LBU 读 ROM 得 0（bus default 分支）→ 形状表不能查 ROM 数据，只能内联/公式**。
2. **清内存循环化**：boot 清 FIELD + render 清 RENDER_BASE（80 词固定 SB）→ SIND 变址循环各 ~8 词。
3. **4 格操作循环化**：move_left/right/drop_piece、apply_candidate、check_candidate（**计数用 r12**——check_cell 破坏 r5-r11）。

## 4. 程序 bug 修复记录（俄罗斯方块 v2）

| # | 症状 | 根因 | 修法 |
|---|------|------|------|
| 1 | 立即 game over | check_cell 用 r1 作 LIND 地址基址，破坏 check_candidate 返回寄存器 r1 | check_cell 改 r10/r11 作地址（不碰 r1）；check_candidate 的 r1=0 移到返回点双保险 |
| 2 | 渲染错位/字段污染 | set_cell 用 r5 存 addr_lo 跨 `RJAL set_bit`，set_bit 把 r5 覆盖成位掩码 → SIND 写错地址 | set_bit 后从 r3/r13 重算 addr_lo |
| 3 | 块到最右两列被吞 | **col 8/9 四重 8 位溢出**：set_bit `1<<8` 溢出；check_cell/渲染 `SLLI r7,r7,8` 组合 16bit mask 溢出；print_cells 只打 lo 8 格 | set_bit col8/9 特判 hi 位；check_cell col<8 测 lo / col≥8 测 hi；渲染分开传 lo/hi；print_cells 打 8+2 格 |
| 4 | 旋转回顶端 | move/drop 只更新 4 格不更新 P_ANCHOR，rotate 用初始 anchor | move/drop 成功时同步更新 P_ANCHOR |
| 5 | 方块不在顶层生成 | spawn anchor row 2 | spawn anchor row 0（I 竖出顶 1 格为正常） |
| 6 | 旋转只能生效一次 | rotate 用 r9 存 new_rot，`check_cell` 里 `ADDI r9,r0,8` 破坏 r9 → SB r9 写错值 | new_rot 存 r13（check_cell 破坏 r5-r11、check_candidate 计数占 r12，r13 安全） |

> **寄存器破坏约定**（v3.0，俄罗斯方块用）：check_cell 破坏 r5-r11（返回 r5）；set_cell 破坏 r1/r2/r5-r9/r13；transform 破坏 r3/r4；check_candidate 用 r12 计数。跨这些子程序的活寄存器只能用 r1-r4/r13-r15。

## 5. 汇编器支持（asm.py）

- `lind`/`sind` 两种格式：`LIND rd,r1,r2` / `SIND rs,r1,r2` → `[b0, rd/rs, r1, r2]`，寄存器号任意（8 位）。
- 俄罗斯方块 v2 回归字节一致（含 .puts/自动 jpad/方向翻转）。

## 6. 仿真验证

- **LIND/SIND 微测 6/6 过**（修复后）：lindbb（背靠背 LIND→LIND）、lindbb2（8NOP 间隔）、sindlind（SIND→LIND）、sindlind2、sblind（SB→LIND）、lindlbu（LIND→LBU→LIND）。
- **set_bit col8/9**：setcell89 微测 RENDER_BASE row2 hi=0x03 ✓；checkcell89 碰撞检测 col8 blocked ✓；printcells89 渲染 `........##` ✓。
- **俄罗斯方块 v2 完整仿真**（UART 注入按键，抓帧比对）：BOOT `@...####...@`（I 横顶层）✓；右移 `@....####..@` ✓；旋转 `@.....#....@`（绕当前 anchor）✓；旋转 3 次全生效（rot0→1→2→3）✓；方块到 col 5-8 渲染 `@.....####.@`（col 8 正常）✓。
- 形状表 transform 公式 Python 验证 28 态 == rot_cw^R 全对。

## 7. 上板实测

- **待上板**（微测 + 仿真已覆盖全部指令路径与游戏操作）。

## 8. 已知限制 / 后续

| 项 | 说明 |
|----|------|
| LIND/SIND 地址锁存 | 依赖修复后 RTL（用户已改），板测需用新 bitstream |
| 同步读 reg_f | 读后写转发覆盖当前写拍；跨拍写读靠 regs 提交值（stall 冻结 rd12_data） |
| 形状表不能查 ROM | LIND/LBU 读 ROM 得 0（bus default），形状数据只能内联/公式 |
| 俄罗斯方块 | 消行/得分逻辑板测待验；下落/碰撞依赖 1Hz tick |
| 寄存器破坏约定 | 跨 check_cell/set_cell/transform 的活寄存器受限（见 §4 表格） |

---

*本文档随项目演进同步更新。*
