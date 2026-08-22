# MCU 设计记录（真 v3.3.0 —— I2C 只输出外设 + RPU 寄存器映射 / baseline 窗口）

> 版本：2026-08-22 定稿。**v3.3.0 由两段构成**：
> ① **I2C 只输出外设**（2026-08-21）：i2c_out.v（0x1000 段）、应答开关、ACK 报错中断、16 深 FIFO、SCL 双相 40/60、DMA busy2 流控、6 槽中断。**ISA 无改动，软件零改动**。
> ② **RPU 寄存器映射**（2026-08-22）：rpu.v，所有寄存器访问（rd/rs/分支/LIND/SIND）统一映射 `regs[raw+baseline]`；baseline 经 0xD000 写、0xD000 读；每任务独立窗口，调度器切任务时 `SBI <base>,0xD000` 切换。**ISA 编码无改动**。
> 指令集速查见 `指令集说明/mc_v3.3.0_ins.md`（ISA 不变，重命名一份并标注 RPU 寄存器语义 + 0xD000）。
>
> **⚠️ 定位**：RPU 段的**压缩率收益小**（任务计数器 imm 全 >7 硬性不可压，shell 早期已压缩优化，净省约 0.4%）。**核心价值是"寄存器窗口"机制**——每个任务独立 base 窗口，寄存器物理空间互不重叠，解决"r1-r16 已分完、加不了新程序"的寄存器稀缺痛点。以后任务多了，各自在 r0-r7 直接用条件跳转和压缩指令，不用再为躲共享子程序扰动而死抠高位寄存器。

## 0. 版本说明

| 维度 | v3.2.0 | 真 v3.3.0（当前） |
|------|--------|-------------------|
| I2C | 无 | **i2c_out.v**（0x1000 段，只输出主机，v3.3.0 段①） |
| 寄存器访问 | 物理直取 `regs[raw]` | **统一映射 `regs[raw+baseline]`**（`<253` 豁免，v3.3.0 段②） |
| baseline 寄存器 | — | **0xD000 写设定 / 0xD000 读回** |
| 窗口 | 无（靠人工分块） | **每任务独立 base 窗口**（调度器切 baseline） |
| 栈指针 j | r254（分区未真正生效的隐性 bug） | **r253**（= 硬件栈指针 regs[253]，已修正） |
| ISA | 34 条 | **34 条，编码无改动** |
| DMA | busy1（UART） | **busy1 + busy2**（UART/I2C） |

---

# 第一部分：I2C 只输出外设（v3.3.0 段①）

## 1. i2c_out.v（0x1000 段，只输出主机）

CPU/DMA 双端口（`dma_oc = bus_addr_dma[15:12]==0x1`）。寄存器（`[11:9]` 选择）：

| 寄存器 | 地址（[11:9]） | 编码 |
|--------|---------------|------|
| 数据 FIFO 写 | 0x1000（0） | 写 `data_buf[wr_ptr]`（wr 从 1 起，满守卫 `wr!=rd`，容量 15） |
| 配置 | 0x1200（1） | `data[2:1]`=frq（0/1/2→100k/400k/1M），`data[0]`=ack_mode |
| start | 0x1400（2） | 置 1 触发起始 |
| stop | 0x1600（3） | 置 1 发完当前字节后 STOP |
| 清 err | 0x1800（4） | 写任意清 i2c_err_irq |

- **SCL 双相 + 40%/60% 占空比**：每 bit `phase_h=0`（SCL 高，数据采样窗）时长 `cnt_l=CLK*2/(FREQ*5)`、`phase_h=1`（SCL 低）时长 `cnt_h=CLK*3/(FREQ*5)`。实测占空比 40%，100k/400k/1M 三档满足 t_HIGH/t_LOW 最小值。
- **状态机**：`IDLE→START→SEND↔ACK1/ACK2→STOP→BACK`，8 位 MSB-first。
- **ack=1**：每字节后 ACK1 释放 SDA → ACK2 采样；**NACK（sda=1）→ i2c_err_irq + STOP**。一次 start 发一字节。
- **ack=0**：不查 ACK，FIFO 有数据则**连续发**（一次 start 发完）；置 stop 则发完当前字节 STOP。
- **busy**：`wr != rd+1`（FIFO 非空即忙）→ DMA busy2 流控。

## 2. DMA 接入 I2C

- dma 增 busy2：`busy = (des_addr[15:12]==UART)?busy1 : (==I2C)?busy2 : 0`。
- **RAM → I2C 流控**：配 `des_addr=0x1000` 触发；I2C FIFO 空（busy2=0）时 DMA 写 1 字节，I2C 发送排空后再写 → 逐字节流控，40 字节不丢。**I2C 用 ack=0**。

## 3. 中断路径

- `i2c_err_irq`（电平）→ bus_controller 槽3（prio，默认4，boot 置 0 关）→ `irq_bus={prio, dev=110, 000}` → irq_controller `irq_vex[5]=0x490`（默认向量）。
- **6 槽**：0=timer 1=dma 2=rx 3=i2c 4=gpio0 5=gpio1。boot 写 0x6008-0x600C。

## 4. I2C 段 RTL 修复清单（微测暴露，全排）

① SCL 时钟化+双相（原 8 位期间 SCL 恒低，从机收不到）；② `rd_ptr+1'b1` 4 位回绕（每 16 字节丢 1）；③ FIFO 读写错位（首字节丢，改写 `data_buf[wr_ptr]`）；④ 满守卫 32 位坑（`wr+1!=rd` 用 32 位 `1` 永不判满，改 `wr!=rd`）；⑤ busy 恒 0（`wr==rd` 基本永远 0，改 `wr!=rd+1`）；⑥ bit0 采样竞争（释放移到 ACK1 态）；⑦ dma busy 按 des_addr（原按 ini_addr，RAM 源流控失效）；⑧ dma INI 态卡死（普通 RAM 源无转移，补默认 `→ HSH`）；⑨ bus_controller i2c dev 字段（原 3'b101 与 DMA 重复，改 110）；⑩ irq_controller 初始化循环覆盖 DMA/I2C 槽（`for(i=6;...)`）。

> **教训**：① 4 位指针 + 32 位字面量（`+1`/`-1`）是反复坑——4 位指针运算须带 `4'd1`/`1'b1`。② 微测要打满 FIFO（>15 字节）+ 触发回绕。

## 5. I2C 段微测验证

| TB | 覆盖 | 结果 |
|----|------|------|
| i2c_out_tb | 黑盒 SCL 上升沿采样：ack=1 / NACK 中断+清 / ack=0 连续 / stop / FIFO 15 容量 / 三频率 | 6/6 PASS |
| i2c_dma_tb | DMA(RAM→I2C) 8 字节 / 40 字节 busy2 流控 / NACK→err_irq | 3/3 PASS |
| i2c_irq_tb | i2c_err→bus_controller 仲裁→irq 向量 0x490 | 2/2 PASS |
| 回归 | ramuart_dma_tb / dma_tb / uart_top_tb | 全过 |

---

# 第二部分：RPU 寄存器映射（v3.3.0 段②）

## 6. rpu.v（新增，`core/rpu.v`）

```verilog
module rpu(
    input  wire clk, rst,
    input  wire [23:0] addr_r12_raw,   // pre_decoder 的 rd:r1:r2 原始 3×8 位拼接
    output reg  [23:0] addr_r12_mov,   // 逐字节 +baseline 后的地址（供 reg_f 读映射寄存器）
    output reg  [7:0]  baseline,       // 当前窗口基址（8 位）
    input  wire [15:0] bus_addr_in,
    input  wire [7:0]  bus_data_in,
    input  wire [3:0]  bus_sig_in,
    output reg  [7:0]  bus_data_out
);
localparam [3:0] BASEL = 4'b1101;      // [15:12]==0xD
```

- **baseline 写**（时钟沿锁存）：`bus_addr_in[15:12]==0xD && bus_sig_in[0]` → `baseline <= bus_data_in`；复位 0。
- **0xD000 读**（组合）：同区间 `!bus_sig_in[0]` → `bus_data_out = baseline`（软件 LBU 0xD000 读回）。

## 7. 寄存器映射（核心公式）

**所有**寄存器操作数（ALU rd/rs1/rs2、分支 r1/r2、LIND/SIND r1/r2、写回 rd）映射：

```
映射值 = raw + ((raw < 8'd253) ? baseline : 8'd0)
```

- **豁免段 ≥253**：r253（j 栈指针）/ r254（i2c_busy）/ r255（tx_busy）恒绝对，不被 baseline 平移。
- **逐字节加**（LIND/SIND 24 位 `{rd,r1,r2}`）：`addr_r12_mov = {raw[23:16]+(...), raw[15:8]+(...), raw[7:0]+(...)}`，每段独立判 `<253`。
- **写回对称**：id_reg `.rd_in(inst_raw[23:16] + ((...<253)?baseline:0))`，与读路径一致。

### RTL 集成点

| 模块 | 改动 |
|------|------|
| `rpu.v` | 新增；baseline 锁存 + 映射 + 0xD000 读写 |
| `decoder.v` | `r_bus = r_bus_raw + ((r_bus_raw<253)?baseline:0)`（3 路）；新增 `rd_out` 端口（写回 rd = raw + ((raw<253)?baseline:0)） |
| `single_cpu_top.v` | 接线 rpu（`addr_r12_raw→rd12`、baseline→decoder）；`id_reg .rd_in(rd_out)` |
| `reg_f.v` | 读 `regs[addr_r12]`（已映射）；写回 `regs[rd]`（rd 已映射），`r0` 写守卫仅物理 regs[0] |

> **⚠️ r0 注意事项**：写守卫 `if (we && rd != 0)` 只保护物理 regs[0]。**base>0 时"相对 r0"实际是 regs[base]**，程序写 r0 会污染 regs[base]。**映射窗口下必须保持 r0 恒 0（绝不写 r0）**。

## 8. RPU 段 RTL 排错（加法映射的 `+?:` 优先级坑）

一轮 `raw + (cond) ? X : 0` 被解析成 `(raw+cond) ? X : 0`——`?:` 优先级最低，**`+` 比 `?:` 高**，条件分支整体（含 `+`）必须挂括号：

① decoder `r_bus/r1/r2` 自引用 + 优先级（判断用了等号左边 `r_bus`，组合环）；② decoder `rd_out` 同优先级；③ rpu `addr_r12_mov` 同优先级。均改 `raw + ((raw<253)?X:0)`。

## 9. 汇编器增强（`tools/asm.py`）

- **`.base N`**：声明当前代码块窗口基准（0–0xF0，留窗口+豁免段）。供汇编器换算 `rK.base`。
- **`rK`**（相对/窗口）：编码 raw=K，硬件自动 +baseline → 物理 `regs[base+K]`。
- **`rK.base`**（物理绝对）：编码 raw=K−base；**K≥253 豁免**（raw 保持 K）；K−base 越界报错。
- **默认 base 0**：`rK.base` ≡ `rK`，对既有程序**逐字节兼容**（回归验证 v3.3.0 原 shell hex 一字不变）。

> `.base` 只需在引用绝对号（`rK.base`）时标注；纯相对 `rK` 无需标注（硬件自动加 baseline）。

## 10. RTOS shell 改造（窗口化 + 栈指针修正）

### 10.1 窗口分配（物理空间零重叠）

| 任务 | baseline | 实际寄存器 |
|------|----------|-----------|
| 任务0(shell) | 0x00 | 低 r1-r11 + 高 r17-r21（**游戏区沿用，不改**） |
| 任务1 | 0x16（22） | r3=内 r4=中 r5=外 r6=CNT1 |
| 任务2 | 0x26（38） | r3=内 r4=中 r5=外 r6=CNT2 |
| 调度器 | 动态（当前任务 base） | r12-r15 临时 + r253=j |

### 10.2 调度器 baseline 切换 + j 修正

- **保存段**（旧任务 base 下）：读 slot0 → 存 PC+j+r7-r11 → CUR=(CUR+1)%3。r7-r11/PC/j 在**当前 base** 下即被抢占任务的窗口寄存器。
- **载入段**（3 处 `SBI <base>,0xD000`）：载任务0→`SBI 0,0xD000`、任务1→`SBI 0x16,0xD000`、任务2→`SBI 0x26,0xD000`。
- **j 修正（r254→r253）**：硬件栈指针 = regs[253]（reg_f `rad[regs[253]]`）；原用 r254 当 j 是**既有 bug**（r254=i2c_busy 每拍被覆写，栈分区从未真正生效）。已改为**调度器保存/恢复/boot 初值全用 r253**，栈分区（0-63/64-127/128-191）真正生效。

### 10.3 任务1/2 窗口化示例

原"高区计数器 + 拷贝到 r3 再分支"改为**窗口直取 + 直接条件跳转**：

```asm
task1_loop:
    LBU   r6, CNT1
    ADDI  r6, r6, 1
    SB    r6, CNT1
    ADDI  r5, r0, 0x10        # 外层 16
dl1_o:
    ADDI  r4, r0, 0xFF
dl1_m:
    ADDI  r3, r0, 0xFF
dl1_i:
    ADDI  r3, r3, 0xFF
    LBNE  r3, r0, dl1_i
    ADDI  r4, r4, 0xFF
    LBNE  r4, r0, dl1_m
    ADDI  r5, r5, 0xFF
    LBNE  r5, r0, dl1_o
    LBEQ  r0, r0, task1_loop
```

去掉"高区拷贝到低区供分支"，r3/r4/r5 直接条件跳转——"以后任务直接在 r0-r7 用条件跳转"的落地样例。

### 10.4 任务0 保持 base 0 恒等

任务0 base=0x00 物理恒等，**r17-r21 游戏区寄存器逐字节不变**（diff 验证任务0 区域为空白），上板已调通的游戏不被扰动。

## 11. 汇编验证（RPU 段）

- 原始 v3.3.0（base 0）：1819 词；RPU 版：**1812 词**（净省 7，含 3 条 SBI 4 字节开销）。净压缩 ≈0.4%。
- **任务0 区域 diff 为空白**（base 0 恒等，游戏未动）。
- 改动干净限定在任务1/2（窗口化）+ 调度器（3×SBI + j 改 r253）。

## 12. 上板验证点

- ① 任务0 shell 主菜单照常（base 0 恒等，游戏不受影响）
- ② 后台 CNT1/CNT2 持续增长（窗口切换后计数不丢）
- ③ 切任务后 timer 持续抢占（prompt 每轮 tick 累计在跳）→ baseline 锁存时序
- ④ 任务切栈（r253 分区）后调用/返回栈不垮

## 13. 已知事项

- **压缩率本程序 ≈0.4%**（任务计数器 imm 全 >7 硬性不可压；shell 早期已优化）。价值在**寄存器窗口机制**。
- **baseline 锁存时序**：`SBI→LBU` 的 1 拍对齐纸面推演大概率正确，上板为最终确认。
- **r0 窗口下不可写**：base>0 时相对 r0 = regs[base]，程序须保持 r0 恒 0。
- **regs[253] 复位清零**：reg_f `if (rst) regs[253] <= 0` → 已清（旧 regs[254]=j 时代"未清零"遗留已随 j 迁移解决）。
