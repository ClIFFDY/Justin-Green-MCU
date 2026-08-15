# MCU 设计记录（v1.2 —— GPIO 8 位模块 + 双 GPIO 中断源）

> 版本：2026-08-15
> MCU 系列第 3 版（v1.1 见 `single_mcu_design_v1.1.md`；CPU 系列见 `single_cpu_design_v6.5.md`）。
> **指令与外设速查见 `指令集说明/mc_v1.2_ins.md`**；本日志只记设计、时序与调试。
> 核心变化：
> ① 新增 **GPIO 8 位模块**（0x8000–0x9FFF，UNUSE/OUT/IN/IRQ 四种引脚模式）；
> ② 新增 **2 路 GPIO 中断源**（GPIO1/GPIO2），优先级提至最高；
> ③ **ISR 统一 24 字节**：向量重排为 0xA0/0xB8/0xD0/0xE8，ROM 末尾 0xA0–0xFF 全为中断区。
> ④ 新增 **timer 外设**（0x6000–0x7FFF，16 位计数 + 中断，向量 0xD0）。

## 0. 版本说明

| 维度 | MCU v1.1（旧） | MCU v1.2（当前） |
|------|----------------|------------------|
| 外设 | UART | **+ timer（0x6000–0x7FFF）+ GPIO（0x8000–0x9FFF，8 位 4 模式）** |
| 中断源 | UART（1） | **+ timer + GPIO1/GPIO2（共 4）** |
| 优先级 | 仅 UART 一路 | **GPIO > timer > UART**（top 后判定覆盖） |
| ISR 布局 | 单向量 0xE8 | **四向量 0xA0/0xB8/0xD0/0xE8，各 24 字节** |
| 源码结构 | core/ + peripherals/ | **+ mcu/（single_mcu_top.v 迁入）** |
| 指令集 | 30 条 | 30 条（不变；timer/GPIO 只用既有 LBU/SB） |

## 1. GPIO 模块（本次核心）

### 1.1 接线与地址

- 新区域 `bus_addr[15:13] = 3'b100` → **0x8000–0x9FFF**；single_mcu_top 实例化 `u_gpio`，
  8 位三态 `gpio_pin_bus` 引出到顶层 `inout wire [7:0] gpio_pin_bus`。
- 读（LBU）组合回、写（SB）同步落 FF、无 stall；与 UART/timer/RAM 区域不冲突。

### 1.2 三种总线操作 + 模式编码

| 指令 | 地址 | 行为 |
|------|------|------|
| LBU rd | 0x8000–0x9FFF | 轮询读：仅 IN 模式引脚回电平，bit↔pin 一一对应，其余位 0 |
| SB rs | 偶数地址（bit0=0） | 推挽输出：data[i]→pin i，8 位统一，仅 OUT 模式引脚生效 |
| SB rs | 奇数地址（bit0=1） | 单引脚模式：`gpio_mode[addr[3:1]] <= data[3:0]` |

模式编码（data[3:0]）：0000=UNUSE（上电默认，驱动 0）、0001=OUT（推挽输出）、0010=IN（轮询输入，高阻）、0011=IRQ（中断输入，高阻）、0101=TX（跟随 uart_tx 的 `tx`，驱动）、0110=RX（引脚直送 uart_rx 的 `rx`，高阻）。

- **方向位** `gpio_set = mode[1]`：mode[1]=0（UNUSE/OUT/TX）驱动、mode[1]=1（IN/IRQ/RX）高阻读入。
  复位块把 `gpio_set` 置 `8'b1`（上电默认全部输入高阻，避免引脚被 x 驱动）。

### 1.3 中断分组

- pins 1–3 → `gpio_irq[0]` → 源 GPIO1（向量 **0xB8**）。
- pins 4–7 → `gpio_irq[1]` → 源 GPIO2（向量 **0xA0**）。
- **电平式持续触发、无 ack**：pin 保持高电平即反复进 ISR（配合 `bytmov==0` 门控在每个指令边界触发）。
- top 里 `irq_bus = {4'b010, gpio_irq}` 拼装，经索引 `irq_addr_in[5:3]+irq_addr_in[2:0]-1` 选向量。

## 2. UART 外设（0x4000–0x5FFF，含 64 字节 RX 缓冲）

> UART 为 v1.1 既有外设，v1.2 沿用；此处补记其 **RX 环形缓冲（FIFO）** 实现细节。指令侧速查见 `mc_v1.2_ins.md` §2.3。

### 2.1 总线行为

| 操作 | 地址 | 行为 |
|------|------|------|
| LBU rd | 0x4000 | 组合回 `rx_buf[rd_ptr]` 并拉 `rx_read`；下一拍 `rd_ptr+1`（弹出一个字节） |
| SB rs | 0x4000 | 置 `tx_en`，下一拍 uart_tx 发送 rs |
| 轮询等发完 | r255 | `tx_busy = uart_tx.busy`（组合镜像），`LBNE r255, r0` 自旋 |

### 2.2 RX 缓冲（FIFO）

- `rx_buf[0:63]` **64 深环形 FIFO**，6 位 `wr_ptr` / `rd_ptr`。
- **入队**：uart_rx 一帧收完（`rx_done`）且未满（`wr_ptr + 1 != rd_ptr`）→ `rx_buf[wr_ptr] <= rx_data; wr_ptr+1`，同时 `rx_irq <= 1`。
- **判满留一格**：`wr_ptr + 1 != rd_ptr` 区分空/满 → **有效容量 63 字节**；新帧不会覆盖未读旧帧。
- **出队**：LBU 读队首、下一拍 `rd_ptr+1`；弹到最后一字节（`rd_ptr+1 == wr_ptr` 且无并发新帧）→ `rx_irq <= 0`（自动清）。
- **空时读**：`rd_ptr == wr_ptr` 则 rd_ptr 不前进，读回 `rx_buf[rd_ptr]`（上电 0 / 上次旧值）；正常流程靠 `rx_irq` 判非空再弹。
- **中断**：`rx_irq = FIFO 非空`（电平），源 0，向量 **0xE8**（布局见 §3）。

## 3. ISR 24 字节布局

| 中断源 | 向量 | ISR 区间（24B） | 优先级 |
|--------|------|----------------|--------|
| GPIO2（pins 4–7） | 0xA0 | 0xA0–0xB7 | 高 |
| GPIO1（pins 1–3） | 0xB8 | 0xB8–0xCF | 高 |
| Timer | 0xD0 | 0xD0–0xE7 | 中 |
| UART RX | 0xE8 | 0xE8–0xFF | 低 |

- 四向量各 24 字节、互不重叠；**主程序须布置在 0xA0 之前**（v1.1 的 0xA0–0xE7 HALT 填充区让位）。
- 授权门控 `bytmov==0`、断点保存/恢复、irq_busy 不可重入——机制沿用 v1.1，仅向量与优先级变化。

## 4. 设计取舍（用户确认）

- **非 OR 中断**：同组多个 IRQ pin 同时有效时只有**最后一个**生效（NBA 覆盖）。因 ins_rom 有限，
  规划**最多 2 个有效 IRQ pin**（每组 1 个）——每路向量语义唯一。
- **电平触发无 ack**：适合"按钮按住持续响应"类用法；ISR 内自行处理或由外部拉低。
- **限制——两组同时触发**：`gpio_irq = 2'b11` → `irq_bus[2:0] = 11` → 向量索引 4（`irq_vex[4]` 未初始化）→
  行为未定义。与"最多 2 有效 pin"配套：**避免两路 GPIO 同时为高**。
- **pin0 保留**：可写配置但内部逻辑未接线，不参与输出/读回/中断。

## 5. 仿真验证

- `gpio_group.v` 修复后纳入编译（`peripherals/*.v` 全通配），整机回归 `mcu_loop_tb`
  （上电 banner + UART 中断回环）**20/20 通过**。
- GPIO 专用验证（`gpio_test_tb` + `gpio_test.hex`）：Phase1 推挽输出（pin2=1）、
  Phase2 轮询输入（LBU 读 pin1→r6=0x02）、Phase3 电平触发中断（GPIO1 ISR 发 'X'），
  **13/13 通过**（r10==X 计数、ISR 内读回 r11==0x02）。

## 6. 调试记录（v1.2 修复项）

| # | 问题 | 修复 |
|---|------|------|
| 1 | 两组中断都写 `gpio_irq[0]`，GPIO2 永不触发 | 第二组改 `gpio_irq[1]` |
| 2 | `gpio_set[i] <= gpio_mode[1]`（索引错 + 2 位赋 1 位截断，方向全反） | 改 `gpio_mode[i][1]` |
| 3 | 轮询读条件 `mode==OUT`，OUT 引脚读回恒 0 | 改 `mode==IN` |
| 4 | `gpio_set` 未复位（上电 x，引脚驱动未知） | 复位块补 `gpio_set <= 8'b1`（默认输入高阻） |
| 5 | pin0 未接线 | 保留设计（generate 已含 j=0，功能逻辑仍从 1 起） |
| 6 | single_mcu_top 拼装 `irq_bus = {4'b010, gpio_irq}`：4'b010 实为 4 位 `0010`，拼出 `001001` → 向量索引落 Timer(0xD0) 而非 GPIO1(0xB8)，中断进错 ISR 区 | 改 `{4'b010_0, gpio_irq}`（= `0100`），拼出 `010001`/`010010`，GPIO1→0xB8、GPIO2→0xA0 正确 |
| 7 | gpio_group 的 `gpio_irq` 阻塞清零 `=2'b0` + 非阻塞置位混用，边沿采样存在竞争（irq_controller 可能采到 0） | 清零改非阻塞 `gpio_irq <= 2'b0`，全部 NBA，采样稳定 |
| 8 | 按键复位 `rst_n` 直接进 uart_tx（异步复位），松开瞬间机械抖动再次拉低 → 正在发的 UART 帧被拦腰截断（banner 乱码/重发） | 新增 `mcu/rst_buf.v`：2 级同步 + IDLE/PUSH 两态机，rst_n **释放边沿**开始计时、连续高 `2^22` 拍（≈83.9ms@50MHz）才释放内部复位；按下边沿立即复位。独立 tb + 整机 tb 验证通过 |
| 9 | irq_controller 用 `irq_busy` 标志锁存，IRET 后无缓冲，返回地址回写与同源中断重入判定可能竞争 | 改 **IDLE/IRQ/BACK 三态机**：IRET 在 IRQ 态捕获 → BACK 态回写返回地址、缓冲一拍 → 回 IDLE 才接受新中断 |
| 10 | reg_f 无复位（上电 x）；timer 复位用阻塞赋值；uart_top 复位未清 rx_read | reg_f 补异步复位清 256 寄存器+rad+j；timer 复位改非阻塞 `<=`；uart_top 补 `rx_read <= 0` |

## 7. 已知限制 / 后续

| 项 | 说明 |
|----|------|
| GPIO 板测 | **已上板测试**（`board_test_nokey.asm`，KEY2 禁用版；rst_n 改接 T12 复位键）：能收到 banner 但开头被污染（`\0` + 乱码后 `ready` 尾缀正常），复位键按下发 0x00 流（见下行） |
| 复位期间 TX 引脚被拉低 | 上板实测小瑕疵：**按下复位键时串口收到一串 0x00**（UART break），释放后 banner 开头有乱码。原因：`gpio_group` 复位时 `gpio_output=0`、mode 全 UNUSE（bit1=0 驱动）→ TX 引脚被驱动为低；**非 uart_tx 问题**（其复位态 `tx=1` 空闲）。可选修复：UNUSE 引脚改高阻 `z`（聚焦验证已通过，且能顺带让 banner 变干净），或板端上拉 P18 |
| GPIO 测试程序 | 已写（`gpio_test.hex` + `gpio_test_tb`），13/13 通过 |
| 双 GPIO 同触发 | 向量索引越界，勿用（见 §4） |
| 中断不可重入 | 沿用 v1.1（irq_busy 锁存，ISR 内不响应新中断） |

---

*本文件随项目演进同步更新。*
