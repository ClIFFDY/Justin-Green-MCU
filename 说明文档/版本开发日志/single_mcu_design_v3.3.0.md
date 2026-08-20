# MCU 设计记录（v3.3.0 —— I2C 只输出外设 / 应答报错中断 / 接入 DMA）

> 版本：2026-08-21。**v3.3.0 是 I2C 外设新增版**：新增 **i2c_out.v**（只输出 I2C 主机，0x1000 段）：可配**应答开关**（ack_mode）、**ACK 报错中断**（i2c_err_irq）、**16 深 FIFO 缓冲**、SCL/SDA 经 **gpio_group 可配引脚**输出、接入 **DMA**（busy2 流控，RAM→I2C 搬运）。**ISA 无改动**（指令总数 34），**软件层零改动**（hex/asm.py/rtos_shell_game.asm 与 v3.2.0 完全相同——I2C 硬件已验证，软件未接入）。
> 指令集速查见 `指令集说明/mc_v3.3.0_ins.md`（ISA 不变，重命名一份并标注地址/外设变化）。
> 核心架构（流水线/reg_f 同步读/irq 读路径/regs[254]=j/抢占调度器/shell）**接口不变**；本轮全部是外设层新增 + RTL 排错（微测暴露）。

## 0. 版本说明

| 维度 | MCU v3.2.0 | MCU v3.3.0（当前） |
|------|------------|--------------------|
| I2C | 无 | **新增 i2c_out.v**（0x1000 段，只输出主机） |
| I2C 缓冲 | — | **16 深 FIFO**（wr 从 1 / rd 从 0，数据 `[rd+1, wr-1]`，容量 15 预留 1 槽） |
| 应答 | — | **ack_mode 开关**（0x1200 bit0）；开启时每字节 ACK 采样，NACK → i2c_err_irq |
| 频率 | — | **3 档**：100kHz / 400kHz / 1MHz（0x1200 bit[2:1]），40%/60% 占空比 |
| SCL 时序 | — | **每 bit 双相**（低相摆数据 / 高相采样），满足三档 t_HIGH/t_LOW 最小值 |
| DMA | busy1（UART） | **busy1 + busy2（I2C）**，RAM→I2C 流控 |
| 中断 | 5 槽（dev timer1/rx2/gpio0-3/gpio1-4/dma5） | **6 槽**：0=timer 1=dma 2=rx 3=i2c 4=gpio0 5=gpio1 |
| ISA | 34 条 | **34 条，无改动** |
| 软件 | 俄罗斯方块渲染帧 DMA | **零改动**（hex 与 v3.2.0 相同） |

## 1. I2C 输出模块（v3.3.0 新增，`peripherals/i2c_out.v`）

### 1.1 功能与寄存器

只输出（master → slave）I2C 主机。寄存器（CPU/DMA 双端口，`bus_addr_final[15:12]==0x1`，`[11:9]` 选择）：

| 寄存器 | 地址 | 编码 |
|--------|------|------|
| 数据 FIFO 写 | 0x1000–0x11FF（[11:9]=0） | 写 `data_buf[wr_ptr]`，wr 从 1 起，满守卫 `wr!=rd`（容量 15） |
| 配置 | 0x1200–0x13FF（[11:9]=1） | `data[2:1]`=frq（0/1/2 → 100k/400k/1M），`data[0]`=ack_mode |
| start | 0x1400–0x15FF（[11:9]=2） | 置 1 触发起始（IDLE 检查 `rd!=wr-1 && start`） |
| stop | 0x1600–0x17FF（[11:9]=3） | 置 1 发完当前字节后 STOP |
| 清 err | 0x1800–0x19FF（[11:9]=4） | 写任意清 i2c_err_irq |

- **双端口**：`dma_oc = (bus_addr_dma[15:12]==0x1)` 时用 DMA 总线，否则 CPU 总线（同 v3.2.0 外设模式）。
- **busy**：`wr != rd+1`（FIFO 非空即忙）→ 供 DMA busy2 流控。

### 1.2 SCL 双相时钟 + 40/60 占空比（微测确认满足规范）

- **每 bit 两相**：`phase_h=0`（SCL 高，数据采样窗）时长 `cnt_l` 拍；`phase_h=1`（SCL 低）时长 `cnt_h` 拍。数据在 SCL 低相摆好，高相被从机采样。
- **占空比 40%/60%**（高=2/5 周期、低=3/5 周期）：`cnt_l = CLK*2/(FREQ*5)`、`cnt_h = CLK*3/(FREQ*5)`。

| 模式 | t_HIGH min | t_LOW min | 本实现高/低 | 达标 |
|------|-----------|-----------|------------|------|
| 100kHz | 4.0us | 4.7us | 4.0us / 6.0us | ✓ |
| 400kHz | 0.6us | 1.3us | 1.0us / 1.5us | ✓ |
| 1MHz | 0.26us | 0.5us | 0.4us / 0.6us | ✓ |

- 微测实测 SCL 占空比 40%（纯数据期，ack=0）。

### 1.3 状态机

`IDLE → START → SEND ↔ ACK1/ACK2 → STOP → BACK`。每字节 8 位 MSB-first。

- **ack=1**：每字节后释放 SDA（ACK1 态）→ ACK2 采样；**sda==1（NACK）→ i2c_err_irq + STOP**。一次 start 发一字节（发完回 IDLE 需再 start）。
- **ack=0**：不查 ACK，FIFO 有数据则**连续发**（一次 start 发完 FIFO 全部）；置 stop 则发完当前字节 STOP。
- **START 条件**：SCL 高时 SDA 1→0；**STOP 条件**：SCL 高时 SDA 0→1。

## 2. DMA 接入 I2C（v3.3.0）

- dma 增 `busy2` 输入：`busy = (des_addr[15:12]==UART) ? busy1 : (des_addr[15:12]==I2C) ? busy2 : 0`。
- **RAM → I2C 流控**：DMA 配 `des_addr=0x1000`（I2C 数据段）触发；I2C FIFO 空（busy2=0）时 DMA 写 1 字节，I2C 发送排空后 DMA 再写 → **逐字节流控，40 字节不丢**。
- 软件若用：写数据到源 RAM → 配 DMA（ini/cnt/des）→ 触发 → `SB r0,0x1400` 置 I2C start → 轮询 cnt_wr 归 0。
- 微测 `temp_bus_tb/i2c_dma_tb.v`：8 字节 / 40 字节流控 / NACK→err_irq，3/3 PASS。

## 3. 中断路径（v3.3.0）

- **i2c_err_irq** → bus_controller `irq_prio[3]`（槽 3，复位默认 4）→ `irq_bus={prio, dev=110, 000}` → irq_controller `irq_vex[dev+vec-1] = irq_vex[5]` = **0x490**（I2C 默认向量）。
- **6 槽**：0=timer 1=dma 2=rx 3=i2c 4=gpio0 5=gpio1。boot 写 `0x6008-0x600C`（slot0-4）配 prio（当前 boot：slot0-2 开、slot3 i2c=0 关、slot4 gpio0=0 关；slot5 gpio1 未配）。
- 微测 `temp_bus_tb/i2c_irq_tb.v`：NACK → irq_bus dev=6 → irq_addr=0x490，2/2 PASS。

## 4. RTL 修复清单（微测暴露，本轮全部排掉）

### i2c_out.v
1. **SCL 时钟化 + 双相**：原 8 位期间 SCL 恒低（无每 bit 上升沿，真实从机收不到）→ 每 bit 低相摆数据 / 高相采样。
2. **`rd_ptr + 1'b1` 4 位回绕**：SEND 读下一字节用裸 `1`（32 位），`rd=15` 读 `data_buf[16]` 越界 → **每第 16 个字节丢**（40 字节测出字节 15/31）。IDLE 用 `1'b1` 是对的，SEND 漏了。
3. **FIFO 读写错位**：写 `data_buf[wr_ptr-1]`（首字节 buf[0]）vs 读 `data_buf[rd_ptr+1]`（首字节 buf[1]）→ 首字节丢。改**写 `data_buf[wr_ptr]`**（对齐 uart 约定）。
4. **满守卫 32 位坑**：`wr_ptr + 1 != rd_ptr` 的 `1` 是 32 位 → `15+1=16` 不回绕 → 永不判满，16 字节写完指针回绕到"空"状态数据全丢。改 **`wr_ptr != rd_ptr`**（预留 1 槽，容量 15）。
5. **busy 恒 0**：`busy = (wr==rd)` 基本永远 0 → DMA 握手失效。改 **`wr != rd+1`**（FIFO 非空即忙）。
6. **bit0 采样竞争**：字节结束的 SDA 释放和 bit0 的 SCL 上升沿撞同拍 → 100kHz 下 bit0 采到 ACK 低电平（A5→A4）。释放移到 **ACK1 态**（bit0 采完后）。

### dma.v
7. **busy 按目的选**：原按 `ini_addr`（源）选 busy1/busy2，RAM→I2C 时源是 RAM → busy 恒 0 流控失效。改按 **`des_addr[15:12]`** 选。
8. **INI 态卡死**：原 INI 只处理 RAM_EXT/UART/I2C 源，普通 RAM 源（RAM_1/2/3）无转移 → 触发后卡 INI。补 **默认 `→ HSH`**。

### bus_controller.v
9. **i2c dev 字段**：原 `3'b101`（与 DMA 重复）→ i2c 中断撞进 DMA 槽（irq_vex[4]=0x470）。改 **`3'b110`**（dev=6 → irq_vex[5]=0x490）。

### irq_controller.v
10. **初始化循环覆盖**：`for(i=4;i<16;) irq_vex[i]=168` 把 **DMA(4)/I2C(5) 槽覆盖成默认值**（I2C 向量变 0xA8）。改 **`for(i=6;...)`**。

> **教训**：① 4 位指针 + 32 位字面量（`+1`/`-1`）是反复出现的坑（dma `ld_ptr-4'd1`、i2c `rd_ptr+1`、i2c 满守卫）——**4 位指针运算必须带 `4'd1`/`1'b1`**。② 微测要打满 FIFO（>15 字节）+ 触发回绕，纸面推理难发现。

## 5. 微测验证（本轮新增 3 套 TB + 回归）

| TB | 覆盖 | 结果 |
|----|------|------|
| `temp_bus_tb/i2c_out_tb.v` | 黑盒 SCL 上升沿采样：ack=1 多字节 / NACK 中断+清 / ack=0 连续 / stop / FIFO 15 容量 / 100k·400k·1M 三频率 | 6/6 PASS |
| `temp_bus_tb/i2c_dma_tb.v` | DMA(RAM→I2C) 8 字节 / 40 字节 busy2 流控 / NACK→err_irq | 3/3 PASS |
| `temp_bus_tb/i2c_irq_tb.v` | i2c_err→bus_controller 仲裁→irq_controller 向量 0x490 | 2/2 PASS |
| 回归 | `ramuart_dma_tb`（v3.2.0）/ `dma_tb` / `uart_top_tb` | 全过 |

- 从机模型：黑盒按 **SCL 上升沿** 采样 sda（非白盒看 bit_cnt），ACK 窗口驱动 sda——真实 I2C 协议验证。

## 6. 已知事项

- **软件未接入 I2C**：hex/asm.py/rtos_shell_game.asm 与 v3.2.0 相同，boot 把 i2c prio（0x600B, slot3）置 0（关）。I2C 用法待软件层接入（如外接传感器输出）。
- **I2C 单次 start 语义**：ack=1 一字节一 start；ack=0 一次 start 连续发完 FIFO。DMA→I2C 用 ack=0。
- **gpio 引脚**：SCL/SDA 经 gpio_group 输出（single_mcu_top 里 i2c 的 scl/sda 连 gpio_group 的 scl/sda 端口），pin 可配。
- **regs[254] 复位未清零**：v2.2 遗留，待 RTL 补。
- **uart_dma_tb** 引用已删 `dma_oc` 端口（旧 TB）已清理。
