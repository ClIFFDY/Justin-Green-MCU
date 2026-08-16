# MCU 设计记录（v1.4 —— 总线 4 位解码 + RAM 分片 16KB + 外设同步复位）

> 版本：2026-08-16（2026-08-17 上板修复补记归档，见 §7；版本号保持 v1.4）。
> MCU 系列第 5 版（v1.2 见 `single_mcu_design_v1.2.md`、v1.3 见 `single_mcu_design_v1.3.md`；CPU 系列见 `single_cpu_design_v6.5.md`）。
> **指令与外设速查见 `指令集说明/mc_v1.4_ins.md`**；本日志只记设计、时序与调试。
> 核心变化：
> ① **总线解码位 [15:13]→[15:12]**，地址空间整体重排；
> ② **RAM 从 data_ram.v 换成 ram_top.v + 4×ram_sec.v，扩容到 16KB**（4×4KB BRAM）；
> ③ **外设改同步复位**（gpio_group / timer / uart_top / uart_rx / uart_tx；CPU 核仍异步复位）；
> ④ **指令集与 v1.3 完全相同**（30 条编码、ISR 向量布局 0x88/0xA8/0xC8/0xE0 不变）；归档后 core 仅做过 bug 修复（irq_controller 向量表、decoder iret 复位默认、gpio_group 输出驱动），均不改指令语义，详见 §7。

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
| ~~irq_vex 依赖截断~~ | **已修复（2026-08-16 深夜）**：改为 8 位字面量 224/200/168/136，不再依赖截断（见 §7.4） |
| 跳转覆盖 ±255 | 沿用 v1.3：跨全 ROM 需链条跳转 |
| 双 GPIO 同触发 | 已兜底（2026-08-16 深夜）：`irq_vex[4..15]=0xA8` 不再 X；仍勿主动同触发（语义为 GPIO1 占位 IRET，见 §7.4） |
| 中断不可重入 | 沿用 v1.1（irq_busy 锁存） |

## 7. 上板调试补记（2026-08-16 深夜 ~ 2026-08-17，版本号保持 v1.4）

> 归档（2026-08-16）后上板板测发现并修复了 5 处问题。**指令集与地址表均未变**，仅 RTL/约束/程序修正，故不升版本。本轮最终修复经用户上板确认回显恢复，本 v1.4 快照已按补记刷新。

### 7.1 UART「有时不回传」→ uart_rx 起始位毛刺校验

- 现象：回传通路偶发失败。排查：rx→FIFO→ISR→send_char→tx 通路在 clean 帧下仿真全过，**RTL 无偶发丢回传 bug**；最强嫌疑是回传开关 r2 被随机关掉（见 7.2/7.5）。
- 修复：`uart_rx.v` 加起始位校验——下降沿后 1/4 位时间（`clk_cnt == MCNT/2 + MCNT/4 - 1`）在 `bit_cnt == 0` 守卫下采样，若起始位已回高则**弃帧**（毛刺不产生 FIFO 写入）。
- 验证：rx_glitch_tb 4/4 + 背靠背 rx_bb_tb + 快速连发 rapid_echo_tb 3/3 回归全过。

### 7.2 GPIO2 中断卡死与「V13 非按钮」澄清

- 现象：回环失败时 rx 也不亮 → 排查为 **V13(gpio[7]) 浮空漂低 → GPIO2 ISR 去抖轮询 `LBEQ r5,r0,0x94` 永久卡死 → UART ISR 被饿死**（v13_stuck_tb 复现 PASS=3/3）。
- 修复：`timing.xdc` 重新给 gpio[7] 加 `PULLUP TRUE`（恢复设计本意，注释本就写「PULLUP 防悬空」）。**V13 是跳线引脚、不是按钮**（T12 实为复位 rst_n）。
- 注意：早前「上拉后完全不回环」是被同期 uart_rx 改动/V13 跳线接地干扰的误判；真机制见 §7.5。

### 7.3 board_test 程序：LED 改为「接收时亮」

- 用户指示：LED 在**接收到数据**时亮，而非发送时。仅改 `tools/board_test.asm`：
  - UART ISR(0xE0) 在 LBU 弹 FIFO 后加 `ADDI r4,r0,0x99`（收到数据→LED 亮 153 tick≈0.2s）；
  - send_char(0x100) 删除原 LED 触发（banner 不再闪灯）；
  - init 区重排加 `SB r7,GPIO`@0x20 初始灭灯；banner→0x40、主循环→0x82，ISR `.org` 向量不变。
- ins_rom.hex 重生成 221 字节（0x00-0x109）；整机回归 20/20、led_check_tb 3/3（banner 期间 LED 不亮、接收后亮、~0.2s 后灭）。

### 7.4 irq_controller 向量表修复（用户指「向量表越界」）

- 旧：`irq_vex[0..3]` 存 10 位字面量 `10'd992/968/936/904`（=0x3E0/0x3C8/0x3A8/0x388，**超 ROM 顶 0x1FF**），仅靠 8 位数组截断才得到 0xE0/0xC8/0xA8/0x88；且 `irq_vex[4..15]` 未初始化（双 GPIO 同触发 `gpio_irq=2'b11`→索引 4→X）。
- 修复：`irq_vex[UART_RX]=8'd224; [TIMER]=8'd200; [GPIO1]=8'd168; [GPIO2]=8'd136;` + `for (i=4;i<16;i++) irq_vex[i]=8'd168;`（兜底 0xA8=GPIO1 占位 IRET，无副作用）。
- 验证：irq_ctrl_tb 确认 224/200/168/136、irq_vex[4]=0xA8 不再 X；全系统回环 3/3、UART IRQ 正常跳 0xE0。
- 附带：`decoder.v` 组合块 reset 分支补 `iret=1'b0` 默认（原仅 else 分支有默认，属复位卫生）。

### 7.5 **「banner 正常 + LED 响应 + TX 完全不回显」真根因：UNUSE=4'bz 综合成驱动低（核心修复）**

- 现象链：先「rx 不亮」（无 PULLUP，V13 浮低卡死 ISR，§7.2）→ 加 PULLUP 后「LED 响应但不回显」。用户补充 **V13 没连任何东西**，排除按键/噪声假设。
- **根因**（`gpio_group.v`）：原 `assign gpio_pin_bus[j] = (!gpio_mode[j][1])? gpio_output[j] : 8'bz;`。`UNUSE=4'bz` 在**综合里被 Vivado 映射为 0000**（寄存器存不了 z）→ `!mode[1]=1` → **所有未配置引脚在复位期间被 FPGA 驱动输出 gpio_output（复位值 0）→ V13 上电被驱动为低**。程序 0x28 配 IRQ 模式 → 引脚释放为高阻 → PULLUP 使其 RC 上升（~µs），上升期间 `gpio_mode[7]==IRQ` 且引脚仍低 → **GPIO2 IRQ 每次上电必触发 → r2 翻 1→0 → 回环永久关**。
- **仿真为何漏**：`4'bz` 在 iverilog 里是真高阻（行为 = 修复后），只有 Vivado 综合把它变成驱动低——纯综合差异。boot_irq_tb 建模该行为（复位驱动低 + 释放后 RC 上升 RISE_CYCLES=50）PASS=3/3 精确复现「banner 后 r2=0 → 发 'A' → LED 亮无回显」。
- **修复（一行，用户选定，不加注释）**：`assign gpio_pin_bus[j] = (gpio_mode[j]==OUT || gpio_mode[j]==TX)? gpio_output[j] : 8'bz;`——**仅 OUT/TX 驱动，UNUSE/IN/IRQ/RX 全高阻**。
- 附带收益：pin6 LED 上电不再闪、pin0 RX 无假起始位、pin1 TX 复位即空闲高。
- 验证：echo_tb 回归 PASS=2/2（回显通、r2=1、无多余帧）；用户上板确认回显恢复。**本 v1.4 归档即为此状态。**

---

*本文件随项目演进同步更新。*
