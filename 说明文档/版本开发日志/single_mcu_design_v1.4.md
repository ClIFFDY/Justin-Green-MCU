# MCU 设计记录（v1.4 —— 总线 4 位解码 + RAM 分片 16KB + 外设同步复位）

> 版本：2026-08-16。
> MCU 系列第 5 版（v1.2 见 `single_mcu_design_v1.2.md`、v1.3 见 `single_mcu_design_v1.3.md`；CPU 系列见 `single_cpu_design_v6.5.md`）。
> **指令与外设速查见 `指令集说明/mc_v1.4_ins.md`**；本日志只记设计、时序与调试。
> 核心变化：
> ① **总线解码位 [15:13]→[15:12]**，地址空间整体重排；
> ② **RAM 从 data_ram.v 换成 ram_top.v + 4×ram_sec.v，扩容到 16KB**（4×4KB BRAM）；
> ③ **外设改同步复位**（gpio_group / timer / uart_top / uart_rx / uart_tx；CPU 核仍异步复位）；
> ④ **指令集与 v1.3 完全相同**（core 文件逐字节不变），未改任何编码/向量。

## 0. 版本说明

| 维度 | MCU v1.3（旧） | MCU v1.4（当前） |
|------|----------------|------------------|
| 总线解码 | `[15:13]`（3 位） | **`[15:12]`（4 位）** |
| 地址空间 | RAM=0x2000 / UART=0x4000 / TIMER=0x6000 / GPIO=0x8000 | **UART=0x2000 / TIMER=0x3000 / GPIO=0x4000 / RAM=0x8000–0xBFFF** |
| RAM | data_ram.v 单块 8KB（0x2000，13 位地址） | **ram_top.v + 4×ram_sec.v 共 16KB（0x8000–0xBFFF，seg=addr[13:12] + offset=addr[11:0]）** |
| 外设复位 | 异步（`posedge clk or posedge rst`） | **同步（`posedge clk`）** |
| 指令集 | 30 条 | 30 条（不变） |
| ISR 向量 | 0x88/0xA8/0xC8/0xE0 | 0x88/0xA8/0xC8/0xE0（不变） |
| 上板程序 | .equ 旧地址 | **.equ 更新为新地址**（布局不变） |

## 1. 总线解码 [15:13]→[15:12] 与地址空间

- `single_mcu_top.v` 解码改为 `case (bus_addr_f[15:12])`：

| 高位 [15:12] | 设备 | 区间 |
|--------------|------|------|
| 0x8 / 0x9 / 0xA / 0xB | RAM（ram_top） | 0x8000–0xBFFF |
| 0x2 | UART | 0x2000–0x2FFF |
| 0x3 | timer | 0x3000–0x3FFF |
| 0x4 | GPIO | 0x4000–0x4FFF |

- 其余区间（0x0/0x1、0x5–0x7、0xC–0xF）读回 0、写丢弃（黑洞）。
- **每个外设各自按 `[15:12]` 判基址**，`addr[11:0]`（timer）或 `addr[0]`（GPIO 奇偶）等做片内区分——地址位扩宽后所有比较随之同步改。
- 上板程序 `.equ` 全部更新（见 §4）；CPU 侧 `LBU/SB` 的 16 位绝对地址语义不变。

## 2. RAM 分片 16KB（ram_top + 4×ram_sec）

- 原 `data_ram.v`（单块 8KB）删除，换成 `ram_top.v` + 4×`ram_sec.v`：
  - `ram_sec.v`：`(* ram_style = "block" *) reg [7:0] mem [0:4095]`，initial 清零；`mode=bus_sig_in[0]` 时同步写 `mem[addr]<=data`，寄存器读 `sec_data_out<=mem[addr]`。
  - `ram_top.v`：`sec[3:0]` 片选（互斥 1-of-4），`bus_data_out = sec_out[选中片]`。
- **分片选择 = `addr[13:12]`（高位），片内偏移 = `addr[11:0]`** → **连续 4×4KB=16KB，无别名**：

| 地址段 | 分片 |
|--------|------|
| 0x8000–0x8FFF | seg0（ram_sec_1） |
| 0x9000–0x9FFF | seg1（ram_sec_2） |
| 0xA000–0xAFFF | seg2（ram_sec_3） |
| 0xB000–0xBFFF | seg3（ram_sec_4） |

- **访问时序（2 拍）**：`access = addr[15:12]∈0x8–0xB`；`stall_bus = access && !done`；`done` 每次访问翻转一次——第 1 拍置 stall、第 2 拍释放。写数据在首拍被捕获，读数据经 ram_sec 寄存器读在第 2 拍组合选出。
- **改选片的历史（值得留档）**：初版用 `addr[1:0]` 选片——有效 RAM 只有 4096B，且 0x8000/0x9000/0xA000/0xB000 象限互相**别名**（同一字节）。改为高位 `addr[13:12]` 选片后，4 片连成完整 16KB、无别名（独立 RAM 测试验证，见 §5）。

## 3. 外设同步复位

- gpio_group / timer / uart_top / uart_rx / uart_tx 的复位分支从 `always @(posedge clk or posedge rst)` 改为 `always @(posedge clk)` 内的 `if (rst)`——**与 CPU 核（异步复位）不同**。
- 影响：外设只在 `rst` 为高的时钟沿复位；纯仿真里 `rst_buf` 的 2M 拍上电脉冲（≈42ms）对外设仍是有效复位窗口（见 §5 的 tb 处理）。

## 4. 上板程序地址更新（tools/board_test.asm）

程序结构、ISR `.org`、寄存器约定**全部不变**，只改 `.equ` 块并重新生成 ins_rom.hex：

```asm
.equ UART        0x2000
.equ TIMER       0x3000
.equ TIMER_CNT0  0x3000
.equ TIMER_CNT1  0x3001
.equ TIMER_MODE  0x3004
.equ TIMER_ACK   0x3005
.equ GPIO        0x4000
.equ GPIO_PIN0   0x4001
.equ GPIO_PIN1   0x4003
.equ GPIO_PIN6   0x400D
.equ GPIO_PIN7   0x400F
```

- 主程序 0x00–0x87（init + banner + 主循环自旋）、ISR 0x88/0xA8/0xC8/0xE0、send_char 高区 0x100——布局与 v1.3 完全一致，仅总线目标地址变了。
- **汇编器未改**（`asm.py` 与 v1.3 归档逐字节相同，ROM_TOP=0x1FF）。

## 5. 仿真验证（2026-08-16）

### 5.1 整机回归（board_test_tb.v，iverilog）

- **结果：20 通过 / 0 失败**（Phase1 banner 11 字节 + Phase2 回环 3 字节 + Phase3 回环关 + Phase4 回环开 + Phase5 LED 亮）。
- 仿真 ~1.9ms 自然结束（未触发 100ms 兜底超时）。
- 测试内容与 v1.3 相比**只减了 Phase5 的 LED 灭检查**（0.2s 慢等；timer 触发路径已被 v1.3 21/21 覆盖，v1.4 不涉及 timer RTL 改动）。

### 5.2 tb 加速手段（重要）

- **短路 rst_buf 长脉冲**：`rst_buf.v` 上电复位脉冲长达 2^21 拍 ≈ 42ms（`rst_cnt[21]`），是纯仿真的唯一耗时大头。tb 让真实复位跑 ~15 拍给同步复位外设清零，然后 `force u_top.u_rst_buf.rst_stable = 1'b0;` 短路内部复位释放信号。**这是 tb 技巧，不是 RTL 改动**。
- 超时 `#100000000`（100ms）：释放复位后程序 ~5ms 跑完，留 ~2 倍余量。
- iverilog 文件表补上 `rst_buf.v`，并用 `ram_top.v ram_sec.v` 替换 `data_ram.v`、`gpio_group.v` 替换补丁版。

### 5.3 RAM 独立测试（ram_top_tb.v，4 分片往返）

- **结果：14 通过 / 0 失败，ALL RAM TESTS PASSED**。
- 覆盖：4 片各自基址/边界往返写读（0x8000/0x8001/0x8FFF/0x9000/0x9FFF/0xA000/0xA5A5/0xB000/0xBFFF）、**象限隔离**（0x8000/0x9000/0xB000 写入互不影响）、**no-alias**（写 0x9000 后 0x8000 不变）。
- 改高位选片后，16KB 全映射有效、象限不再别名（初版 addr[1:0] 选片仅 4KB 有效，见 §2）。

## 6. 已知限制 / 后续

| 项 | 说明 |
|----|------|
| **CPU↔RAM 整机交互未覆盖** | board_test 程序**不访 RAM**，`stall_bus` 与 CPU 流水线的整机交互路径只有独立 RAM 测试、没有整机回归覆盖；建议下一版程序加 RAM 读写段或专门写一条 LBU/SB 命中 RAM 的用例 |
| 外设同步复位 | CPU 核仍异步复位；两者复位语义不同，移植时注意 `rst` 撤除沿与时钟沿的相对关系 |
| irq_vex 依赖截断 | 沿用 v1.3：10 位字面量截断出 0x88/0xA8/0xC8/0xE0，脆弱易读错（v1.3 已建议，未改） |
| 跳转覆盖 ±255 | 沿用 v1.3：跨全 ROM 需链条跳转 |
| 双 GPIO 同触发 | 沿用 v1.2：`gpio_irq=2'b11` 向量索引越界，勿用 |
| 中断不可重入 | 沿用 v1.1（irq_busy 锁存） |

---

*本文件随项目演进同步更新。*
