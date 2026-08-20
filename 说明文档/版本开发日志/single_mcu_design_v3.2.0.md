# MCU 设计记录（v3.2.0 —— DMA 渲染帧输出 / 双总线 / 向量表可配 / UART 双 FIFO）

> 版本：2026-08-21。**v3.2.0 是外设功能扩展版**：新增 **DMA 模块**（16 深 FIFO、5 态状态机、独立总线 bus_f2）驱动**俄罗斯方块渲染帧输出**（fputc 写 ram_ext 帧缓冲 → DMA 发 UART）；外设改**双端口**（CPU 总线 bus_addr_in + DMA 总线 bus_addr_dma）；**irq_controller 向量表改为总线可写**（boot 配置）+ **bus_controller 一次性 lock**；**uart_top 改 RX/TX 双 FIFO 缓冲**。**ISA 无改动**（指令总数 34，无新指令）。
> 指令集速查见 `指令集说明/mc_v3.2.0_ins.md`（ISA 不变，重命名一份并标注地址/外设变化）。
> 核心架构（流水线/reg_f 同步读/irq 读路径/regs[254]=j/抢占调度器/shell）**接口不变**；本轮全部是外设层 + 系统软件适配。

## 0. 版本说明

| 维度 | MCU v3.1.0 | MCU v3.2.0（当前） |
|------|------------|--------------------|
| DMA | 无 | **新增 dma.v**（16 深 FIFO、5 态：IDLE/INI/HSH/LD/WR、独立总线 bus_f2） |
| 外设总线 | 单端口（bus_addr_in） | **双端口**：bus_addr_in(CPU) + bus_addr_dma(DMA)，外设级 `dma_oc` 仲裁 |
| 总线仲裁 | bus_controller 单路 | **bus_controller 双路**：bus_data_b(CPU) + bus_data_to_dma(DMA 读返回) |
| IRQ 向量表 | 固定（irq_vex 硬编码） | **总线可写**（0x5000 区 [4:2]=槽位、[1:0]=1高/2低字节），boot 配置 |
| 中断优先级 | 4 槽（0-3） | **5 槽**（0-4，新增 DMA dev=5），**一次性 lock**（bit3=1 写 prio / bit3=0 解锁） |
| UART | 单字节收发 | **RX/TX 双 FIFO（64 深）缓冲** + tx_busy 按 FIFO 状态 |
| 俄罗斯方块输出 | 逐字符 putc | **帧缓冲 DMA 输出**（ram_ext 0xC000 渲染帧 → DMA → UART） |
| ISA | 34 条 | **34 条，无改动** |

## 1. DMA 模块（v3.2.0 新增，`peripherals/dma.v`）

### 1.1 功能与状态机

- **5 态**：`IDLE → INI → HSH → LD ↔ WR`（+UART 模式超时终止）。
- **FIFO 16 深**：`data_buf[0:15]` + `ld_ptr`（写）/`wr_ptr`（读）指针。
- **可配寄存器**（IDLE 态 CPU SB 写，地址 `0x70xx`）：

| 寄存器 | 地址 | 编码 |
|--------|------|------|
| ini_addr | 0x7000+[7:0] | `{addr[7:0], data}` 拼 16 位源地址 |
| cnt（帧长） | 0x7100+[7:0] | `{addr[7:0], data}` 拼 16 位（**高字节=addr[7:0]，一次写满**） |
| cnt_due（UART 超时） | 0x7200+[7:0] | 超时阈值 |
| des_addr | 0x7300+[7:0] | 目的地址（UART=0x2000） |
| ini_bank | 0x7400+[7:0] | ram_ext 选片数据 |
| 触发 | 0x7500 | stage → INI |
| 清 dma_irq | 0x7600 | 写任意清中断 |
| **读 cnt** | 0x7600 / 0x7700 | `bus_addr[11:8]==6`→cnt_wr 高字节，`==7`→低字节 |

- **cnt 读回**：`bus_data_dma = cnt_wr[15:8]`（0x7600）或 `[7:0]`（0x7700）——软件 wait_dma 轮询。

### 1.2 双总线

- DMA 用**独立总线 bus_f2**（`bus_addr_out/bus_data_out/bus_sig_out`）。
- 外设双端口：`dma_oc = (bus_addr_dma[15:12] == 本外设段)`，`bus_addr_final = dma_oc ? bus_addr_dma : bus_addr_in`。
- bus_controller 增加 `bus_data_to_dma` 仲裁（`bus_addr_dma_in[15:12]` 选 RAM/RAM_EXT/UART）。

### 1.3 三个必修 RTL bug（>16 字节路径才暴露）

1. **`ld_ptr - 1` 32 位下溢**：字面量 `1` 是 32 位，`ld_ptr(0) - 1 = 0xFFFFFFFF`（非回绕 15）→ `wr_ptr == ld_ptr-1` 永不成立（WR 不转重读）+ `data_buf[-1]` 越界（data_buf[15] 永不写）。修复：**`ld_ptr - 4'd1`**（强制 4 位减法回绕）。
2. **WR→LD 缺 HSH**：FIFO 空需重读时 WR 直接进 LD，**同拍摆地址又采样 → 采到过期数据**。修复：**`WR → HSH`**（先摆地址再 LD 采样）。
3. **WR UART 分支缺终止**：无 `cnt_wr>0` 守卫 + 无 `cnt_wr==0 → IDLE` → 发完 cnt 回绕、DMA 停不下来（runaway）、后续触发被忽略。修复：**对齐非 UART 分支**（`cnt_wr>0` 守卫 + `cnt_wr==0 → IDLE+dma_irq`）。

> **教训**：dma_tb 微测只用 3 字节（<16）没触发 WR→LD 重读路径；**>16 字节（FIFO 打满再重读）必须单独微测**。新增 `temp_bus_tb/ramuart_dma_tb.v`（RAM_EXT→UART，40 字节）覆盖。

## 2. 俄罗斯方块渲染帧 DMA（v3.2.0 软件适配）

- **帧缓冲**：ram_ext bank0 @0xC000，`fputc` 逐字符写（替代原 putc 直发 UART）。
- **FRAME_IDX 16 位**（0x948B 低 / 0x948C 高）：原 8 位计数器在 319 字节帧回绕到 63（319&0xFF），**帧尾覆盖帧头** + cnt 变 63。修复：16 位自增 + fputc 算地址 `{0xC0+HI, LO}`。
- **DMA cnt 16 位**：`SIND {0x71, HI}, LO` 一次写满（`{addr[7:0]=HI, data=LO}`）。
- **wait_dma**：轮询 cnt_wr（0x7600/0x7700）归 0。
- **boot 关 DMA 中断**：BUS_CON 0x600C=0（复位默认 prio[4]=5 最高，DMA 完成会打断进 0x280 uart_isr 中间）。

## 3. IRQ 向量表可配 + 一次性 lock（v3.2.0）

### 3.1 irq_controller 向量写接口（0x5000 区）

```verilog
if (bus_sig_in && bus_addr_in[15:12] == IRQ_W) begin
    if (bus_addr_in[1:0] == 2'd1) irq_vex[bus_addr_in[4:2]][12:8] = bus_data_in;
    else if (bus_addr_in[1:0] == 2'd2) irq_vex[bus_addr_in[4:2]][7:0] = bus_data_in;
end
```

- 槽位 `bus_addr_in[4:2]`（0=timer 1=uart 2=gpio0 3=gpio1 4=dma），`[1:0]=1` 高字节 / `=2` 低字节。
- **默认向量**：GPIO2=0x400 / GPIO1=0x420 / TIMER=0x440 / UART=0x450 / DMA=0x470（新布局，避免撞 task1@0x400）。**boot 必须写向量指针**覆盖默认（0x400-0x47F 与 task1 冲突）。

### 3.2 bus_controller 一次性 lock

- 复位 `irq_lock=1`（锁中断，irq_bus 全 0）。
- `SB 0x6008-0x600C`（`addr[3]=1`）写 prio；`SB 0x6000-0x6007`（`addr[3]=0`）**一次性解锁**（irq_lock=0，不可再锁）。
- **目的**：boot 的多条指令初始化（写 prio + 写向量）期间无中断，保证原子性。

### 3.3 boot 配置（rtos_shell_game.asm）

```asm
SB r1, 0x6008   # timer prio=3
SB r1, 0x6009   # rx prio=2
SB r1, 0x600A   # gpio0 prio=1
SB r0, 0x600B   # gpio1 prio=0
SB r0, 0x600C   # dma prio=0（关；复位默认 5 最高必须关）
# 写向量指针：timer→0x248 uart→0x260 gpio0→0x208 gpio1→0x228 dma→0x208
SB r1, 0x5001 / 0x5002 / ...（[4:2]=槽位，高/低字节）
SB r0, 0x6000  # 解锁
```

## 4. uart_top RX/TX 双 FIFO（v3.2.0）

- **RX/TX 各 64 深 FIFO**（wr 从 1 起、rd 从 0 起，数据在 `[rd+1, wr-1)`，判空 `wr==rd+1`）。
- **读指针 `rd+1`**：写入 `buf[wr]`（wr 从 1 起），读出必须 `buf[rd+1]`（rd 落后一格），否则第一个字节读到空槽。
- **TX 组合输出**：`tx_en/tx_data` 在 `always @(*)` 生成（`!busy && rd != wr-1`），时序块只推 rd——阻塞赋值写时序块会跟 uart_tx 采样竞争（首字节读到旧值）。
- **TX 地址段检查**：只收 `bus_addr_final[15:12]==0x2` 的写——否则 boot 期间 GPIO/RAM/timer 写全灌进 TX FIFO（boot 卡死、菜单丢失）。
- **RX 读写分离**：combinational 只在 `!bus_sig_final[0]`（读）时弹 RX，写（sig=1）不碰 RX 指针。
- 微测 `temp_bus_tb/uart_top_tb.v`：TX 单字节 / TX 3 字节 FIFO / DMA 写 TX / RX 读回，4/4 PASS。

## 5. 其他验证与修复

- **DMA 中断优先级复位=5**（bus_controller reset `irq_prio[i]=i+1`）→ boot 必须 `0x600C=0` 关掉，否则 DMA 完成打断进 0x280（uart_isr 中间）。
- **整机验证**（shell_game_tb）：boot 菜单 → 进游戏（GAME_ACTIVE=1）→ 帧完整（FRAME_IDX=319、顶边框+方块+底边框+SCORE）→ 移动/旋转（方块位置变化）→ 按 0 退出（GAME_ACTIVE=0）→ 重进 → 再退。全过。
- **rst_buf**：复位后数 2^21 拍（~40ms）才释放——TB 用 `force rst_stable=0` 绕过；若上板无 force，需注意 40ms 复位期。

## 6. 已知事项

- uart DMA 微测 `uart_dma_tb.v` 引用了已删除的 `dma_oc` 端口（旧 TB），逻辑仍过；下次清理。
- 诊断代码：渲染完成标记 0x948D、TB 探针（DMA读/WE）待清理。
