# MCU 设计记录（v3.1.0 —— 外设架构重构：统一总线仲裁 / 可配中断优先级 / ROM 扩容 / 扩展 RAM）

> 版本：2026-08-20。**v3.1.0 是外设架构重构版**：ins_rom 扩容 **8192 词（PC 12→13 位）**、新增 **bus_controller 统一总线仲裁 + SB 可配中断优先级**（prio=0 关闭中断）、ram_top 缩为 3 片 + 新增 **ram_ext_top 4 bank 扩展二级 RAM**（选片机制）、数据区 **0xB000→0xA000**。**ISA 无改动**（指令总数 34，无新指令；仅 PC 位宽扩大影响跳转编码范围）。
> 指令集速查见 `指令集说明/mc_v3.1.0_ins.md`（ISA 不变，重命名一份并标注地址/外设变化）。
> 核心架构（流水线/reg_f 同步读/irq 读路径/regs[254]=j/抢占调度器/shell）**接口不变**；本轮全部是外设层 + 系统软件适配。

## 0. 版本说明

| 维度 | MCU v3.0.1 | MCU v3.1.0（当前） |
|------|------------|--------------------|
| 指令 ROM | 4096 词（PC 12 位） | **8192 词（PC 13 位）** |
| 总线仲裁 | 各外设并行输出、CPU 侧归并 | **bus_controller 统一仲裁**（case 选一路） |
| 中断优先级 | 固定（irq_controller 内部） | **bus_controller 可配**：SB 0x6000+槽 写 prio，**prio=0 关闭该中断** |
| 中断派发编码 | — | **irq_bus = {prio[2:0], dev[2:0], 000}**（prio 在 [8:6]、dev 在 [5:3]） |
| RAM | 4 片（0x8000-0xB000） | **3 片**（0x8000/0x9000/**0xA000**）+ **ram_ext 4 bank**（选片 0xB000 + 访问 0xC000） |
| 数据区 | 0xB000（ram_sec_init） | **0xA000**（前移；0xB000 被 ram_ext 选片占用） |
| 汇编器 | ROM_TOP=0xFFF, DATA_BASE=0xB000 | **ROM_TOP=0x1FFF, DATA_BASE=0xA000, DATA_ROM_START=8192** |
| 系统程序 | 无优先级配置 | **boot SB 0x6000 配置 timer=3/rx=2/gpio0=1/gpio1=0（关）** |
| ISA | 34 条 | **34 条，无改动** |

## 1. ins_rom 扩容 8192 词（PC 13 位）

- `ins_rom.v`：mem [0:8191]，addr [12:0]（13 位）。
- `pc.v` / `irq_controller.v`：pc_addr / ra / irq_addr / irq_vex / pc_addr[0:7] 全部 13 位。
- **汇编器 asm.py**：`ROM_TOP=0x1FFF`（跳转目标 0x000-0x1FFF）、write_hex 写满 8192 词。
- 外设总线 bus_addr 仍 16 位（RAM/外设地址空间不变）。

## 2. bus_controller（统一仲裁 + 可配中断优先级）

新增 `peripherals/bus_controller.v`，single_mcu_top 里 CPU 的 `bus_data_in` 只接 bus_controller 输出。

### 2.1 输出仲裁

```verilog
case (bus_addr_in[15:12])
RAM_1, RAM_2, RAM_3: bus_data_b = bus_data_ram1;   // ram_top
RAM_EXT:            bus_data_b = bus_data_ram2;    // ram_ext_top
UART:               bus_data_b = bus_data_uart;
GPIO:               bus_data_b = bus_data_gpio;
IRQ:                bus_data_b = bus_data_irq;      // irq_controller（0x5000 读路径）
default:            bus_data_b = 8'b0;
```
0xB000（BANK_SEL 选片寄存器）读回 0（软件自管理选片，无需读回）。

### 2.2 中断优先级配置（SB 0x6000+slot）

- **BUS_CON = 0x6**：SB 写 `0x6000+[1:0]` → `irq_prio[slot] = bus_data_in_cpu[1:0]`（2bit，0-3）。
- 槽：0=timer、1=rx、2=gpio0、3=gpio1。
- **默认（复位）irq_prio = i+1 = [1,2,3,4]**（避开 prio=0 误关）。
- **prio=0 = 关闭该中断**（仲裁时不参与、不派发）。

### 2.3 ⚠️ irq_bus 编码（与 irq_controller 解析严格对齐）

```
irq_bus[8:6] = 优先级（irq_controller IDLE/抢占比较用）
irq_bus[5:3] = 设备号（dev：timer=001 / rx=010 / gpio0=011 / gpio1=100）
irq_bus[2:0] = 0（irq_vex 索引 = dev-1）
```
```verilog
if (timer_irq && irq_prio[0] != 3'b0) irq_bus = {irq_prio[0], 3'b001, 3'b000};
if (rx_irq && (irq_bus==9'b0 || irq_prio[1] > irq_bus[8:6]) && irq_prio[1] != 3'b0)
    irq_bus = {irq_prio[1], 3'b010, 3'b000};
// gpio0 / gpio1 同理（dev 011/100，prio 判定 + prio!=0）
```
- **仲裁算法**：触发源中选优先级最高者（非静态组选择），平级先者（timer>rx>gpio0>gpio1）。
- **⚠️ 曾踩坑（中断风暴）**：早期误用 `{1'b0,prio,dev,00}` 布局（prio 落 [7:5]、dev 落 [4:2]），timer 派发到 `irq_vex[3]=0x208`（GPIO2 防御 IRET）→ **每 2 拍中断风暴**、调度器 ack 不到 timer、任务0 卡 putc。修复为 `{prio, dev, 000}` 后正常。**教训：模块微测只校验自身输出，编码与 irq_controller 的对齐必须整机联调。**

## 3. RAM 布局（3 片 + 数据区前移）

- ram_top 缩为 **3 片**：0x8000 ram_sec_1、0x9000 ram_sec_2、**0xA000 ram_sec_init**（数据区，readmemh data.hex）。
- 原 0xB000（ram_sec_4）删除，ram_sec_init 前移到 0xA000。**0xB000 不再被 ram_top access**。

## 4. ram_ext_top（4 bank 扩展二级 RAM）

`peripherals/ram_ext_top.v`（单端口 ram_sec × 4，4KB/bank）：

- **选片**：SB 写 `0xB000`，`bank_num[bus_data_in[1:0]]<=1`（**one-hot**）且 `sec_num<=bus_data_in[1:0]`。切换选片整体替换（清旧位）。
- **访问**：`0xC000`（access 段）读写当前选中 bank，`bus_data_out=sec_out[sec_num]`，直到下次选片切换。
- **两个必修 bug**：
  1. 选片位选置位不清旧位 → 多 bank 叠加使能写冲突（改 one-hot 整体替换 `4'b0001 << data[1:0]`）。
  2. 选片 SB 写时 ram_sec 的 `mode=bus_sig_in[0]` 直接把 bank 号写进当前 bank mem（改 `.ram_sec(bank_num[x] & access)` 门控，选片不碰 mem）。
- **stall**：access 段读握手（done 翻转），stall_bus 接到 single_mcu_top 的 stall_bus_2（bus_controller 汇总）。

## 5. 汇编器适配（asm.py）

| 项 | v3.0.1 | v3.1.0 |
|----|--------|--------|
| ROM_TOP | 0xFFF | **0x1FFF** |
| DATA_BASE | 0xB000 | **0xA000** |
| DATA_ROM_START | 4096 | **8192** |
| 跳转目标检查 | 0x000-0xFFF | 0x000-0x1FFF |
| write_hex | 0-4095 | **0-8191** |

datalabel 汇编器生成 0xA000+偏移（源码无需手改）。hex 仍分离 2 个（ins_rom.hex 8192 词 + data.hex）。

## 6. 系统程序适配（rtos_shell_game.asm）

- **boot 加中断优先级配置**（利用新外设）：SB 0x6000-0x6003 → **timer=3 / rx=2 / gpio0=1 / gpio1=0**。timer 最高保证俄罗斯方块 tick 及时，且 rx 不打断调度器；gpio1=0 关闭（未用）。
- **irq_controller 抢占比较统一 `irq_bus_in[8:6] > prio`**（时序块 + 组合块；曾漏改组合块）。
- 数据区 datalabel 汇编器自动 0xA000。
- 程序范围：**0x000-0xCBD（3260 词）**，数据区 295 字节。

## 7. 验证（2026-08-20）

| 验证 | 结果 |
|------|------|
| bus_controller 微测（temp_bus_tb/） | **21/21**：仲裁（含 RAM_EXT/BANK_SEL）+ 优先级配置 + irq 仲裁（含 prio=0 关闭）×组合 + stall |
| ram_top 微测 | **6/6**：3 片读写、0xB000 不再 access |
| ram_ext 微测 | **8/8**：选片切换、4 bank 独立、切换不污染 |
| **整机**（shell_game_tb） | **全过**：主菜单 / 进游戏 / 移动旋转 / 按 0 退出 / 重入；中断风暴修复后 timer 调度正常 |

## 8. 已知限制 / 后续

| 项 | 说明 |
|----|------|
| prio=0 关闭 | 关闭的中断源即使触发也不派发（需软件确认预期） |
| 优先级配置 | 只存 2bit（0-3），配置值 >3 被截断 |
| 选片寄存器 0xB000 | 只写不读回（软件自管理选片） |
| ram_ext bank | bank_num 4bit one-hot；选片值只取 [1:0]（4 bank） |
| RTOS 优化 | next preview / ghost / 等级加速等**暂缓**（用户决定，程序空间充足） |

---

*本文档随项目演进同步更新。*
