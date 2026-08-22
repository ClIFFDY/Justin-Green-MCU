# MCU 指令集与外设用法说明（v3.3.1 —— 纯软件层：扫雷 / GAME 子菜单 / 开机动画 / 打字机 / 垫层移除；ISA 编码无改动）

> 配套版本：MCU **v3.3.1**（2026-08-22，纯软件层更新）。**ISA 编码与 v3.0/v3.1.0/v3.2.0/v3.3.0 完全相同（指令总数 34），指令表/opcode/压缩布局均不变**；本文件随版本重命名一份（v3.0 起归档规范）。**v3.3.1 变化在软件层**（RTL/ISA/外设/地址空间全部不变，同 v3.3.0）：
> ① 新增 **8x8 扫雷**（LIND/SIND 棋盘 + 复用帧 DMA）；② 主菜单 3 → **GAME 子菜单**（俄罗斯方块/扫雷）；③ **打字机效果**（putc 逐字 ~5ms）；④ **开机动画**（7 阶段加载条，解锁中断前）；⑤ **IRET 垫层移除**（微测确认 irq_controller 存 W+1，垫层冗余，程序瘦 19%）；⑥ **flush_rx**（打印期间忽略输入）；⑦ 汇编器 **.puts 跨 256 页对齐修复**。
> v3.3.0（2026-08-22 真版）由两段构成：① I2C 只输出外设（i2c_out.v/应答/ACK 报错/16 深 FIFO/SCL 双相 40%/DMA busy2/6 槽中断）；② RPU 寄存器映射（rpu.v/baseline 窗口，所有 rd/rs/分支/LIND/SIND = `raw + ((raw<253)?baseline:0)`；0xD000 写读；任务0 base0/1=0x16/2=0x26 + 调度器 3×SBI 切；汇编器 `.base`/`rK.base`；栈指针 j=r253 修正）。
> v3.2.0（2026-08-21）外设功能扩展：DMA（0x7000）、外设双端口、IRQ 向量表可写+一次性 lock、UART RX/TX 双 FIFO、俄罗斯方块渲染帧 DMA。
> v3.1.0（2026-08-20）外设架构重构：ins_rom 8192 词 / PC 13 位、bus_controller 统一仲裁+可配中断优先级、ram_ext 4 bank 选片、数据区 0xA000。
> v3.0（2026-08-19）核心架构重构 + ISA 扩展：新增 LIND/SIND（32→34），WNS 优化。
> **v3.3.1 软件层细节**：① 扫雷 8x8（连续 3 数字=横纵坐标+操作；布雷 LCG/洪水展开/踩雷标雷/胜负）；② GAME 子菜单（shell_parse 按 MENU 分派，game_exit 回子菜单）；③ putc 打字机 5ms/字符（`ADDI r9,r0,250` 调速）；④ 开机动画（fast_putc 快速发送 + anim_bar 逐 # 加载条，7 阶段大写英文，解锁中断前）；⑤ **__jpad 垫层全移除**（asm.py 关 auto_jpad + 删手写，程序 2327→1979 词）；⑥ flush_rx（打印后清 RX）；⑦ asm.py 数据区跨 256 页自动填充对齐。
> 设计演进、时序与调试记录见 `版本开发日志/single_mcu_design_v3.3.1.md`（软件层更新）。
> 编码来源：`decoder.v` / `pc.v` / `reg_f.v` / `pre_decoder.v` / `rpu.v` / `ins_rom.v` / `irq_controller.v` / `single_cpu_top.v` / `single_mcu_top.v` / `bus_controller.v` / `dma.v` / `i2c_out.v` / `uart_top.v` / `ram_sec_init.v` / `ram_ext_top.v` / 各外设 `.v` / `tools/asm.py`。

---

## 1. CPU 指令集

### 1.1 编码规则（词寻址 + flag 压缩）

- **词寻址**：PC 13 位【词地址】0x000–0x1FFF（8192 词 × 32bit BRAM），32bit 定长取指。
- **流水线**：`ins_rom(1级) → if_reg(1级) → decoder`；**指令在词 W 执行时 pc_addr = W+2**（取指延迟 2 拍）。
- **词内字节序**：`byte0` 在**高位**（bits[31:24]）。`byte0 = opcode[5:0]<<2 | flag[1:0]`：

| flag | 含义 | 形式 |
|------|------|------|
| 00 | 原长指令 | 独占一个 32bit 词（不足 4 字节补 0） |
| 11 | ALU 类压缩 16bit | `[opcode\|11][rd(2)][r1(3)][r2/imm(3)]`，I 型末字段=imm[2:0] |
| 01 | 无操作数压缩 16bit | `[opcode\|01][0x00]`：仅 NOP / IRET |

- **自动压缩**（汇编器判定，无需手写 flag）：ALU-R/I 满足 `rd≤3、r1/r2≤7`（I 型 `imm≤7`）→ flag=11；`NOP/IRET` → flag=01；其余指令恒为原长。
- **自动打包**：相邻两条压缩指令共享一个 32bit 词（前=[31:16]、后=[15:0]）。**跳转/分支目标必须落在词首指令**；独个可压缩指令退回原长。
- **解包**：if_reg 检测到词两半 flag 均≠00 时，用 `cstall` 冻结 pc，两半各输出 1 拍；解包后的 32bit 指令 opcode 仍在 [31:26]，压缩字段经 if_reg 原位展开，decoder 无需感知压缩。

### 1.2 指令总表（ISA 编码与 v3.3.0 完全相同）

opcode[5:0] 见下表（byte0 列为 `flag=00` 时的值；原长指令均占 1 词）。**表内编码不变**；仅"寄存器操作数 → 物理寄存器"的语义由 RPU 映射（见 §1.5）。

| 类别 | 助记符 | opcode | byte0(00) | 压缩 | 布局（原长，byte0 之后） | 功能 |
|------|--------|--------|-----------|------|--------------------------|------|
| 控制 | HALT | 0x00 | 0x00 | flag=01 | — | 停机（frz 停 PC） |
|      | NOP | 0x14 | 0x50 | flag=01 | — | 空操作 |
|      | IRET | 0x15 | 0x54 | flag=01 | — | 中断返回：恢复断点 |
| 跳转 | LJAL | 0x08 | 0x20 | 否 | `bytmov16`（byte1:2） | 向后跳，压栈保存返回地址 |
|      | RJAL | 0x09 | 0x24 | 否 | `bytmov16`（byte1:2） | 向前跳，压栈保存返回地址 |
|      | JALR | 0x13 | 0x4C | 否 | — | 弹栈并跳转到 ra（调用返回） |
| 分支 | LBEQ | 0x16 | 0x58 | 否 | `bytmov16` + `{r1,r2}4b`（byte3） | r1==r2 则**向后**跳 |
|      | RBEQ | 0x17 | 0x5C | 否 | 同上 | r1==r2 则**向前**跳 |
|      | LBNE | 0x18 | 0x60 | 否 | 同上 | r1≠r2 则**向后**跳 |
|      | RBNE | 0x19 | 0x64 | 否 | 同上 | r1≠r2 则**向前**跳 |
|      | LBLTU | 0x1A | 0x68 | 否 | 同上 | r1<r2（无符号）则**向后**跳 |
|      | RBLTU | 0x1B | 0x6C | 否 | 同上 | r1<r2（无符号）则**向前**跳 |
| ALU-R | ADD | 0x02 | 0x08 | flag=11 | rd, r1, r2（各 8 位） | rd = r1 + r2 |
|      | SUB | 0x04 | 0x10 | flag=11 | rd, r1, r2 | rd = r1 − r2 |
|      | AND | 0x05 | 0x14 | flag=11 | rd, r1, r2 | rd = r1 & r2 |
|      | OR | 0x06 | 0x18 | flag=11 | rd, r1, r2 | rd = r1 \| r2 |
|      | XOR | 0x07 | 0x1C | flag=11 | rd, r1, r2 | rd = r1 ^ r2 |
|      | SLL | 0x0D | 0x34 | flag=11 | rd, r1, r2 | rd = r1 << r2[2:0] |
|      | SRL | 0x0E | 0x38 | flag=11 | rd, r1, r2 | rd = r1 >> r2[2:0]（逻辑右移） |
|      | SLTU | 0x11 | 0x44 | flag=11 | rd, r1, r2 | rd = (r1<r2)? 1 : 0（无符号） |
| ALU-I | ADDI | 0x01 | 0x04 | flag=11 | rd, rs1, imm8 | rd = rs1 + imm |
|      | SUBI | 0x03 | 0x0C | flag=11 | rd, rs1, imm8 | rd = rs1 − imm |
|      | ANDI | 0x0A | 0x28 | flag=11 | rd, rs1, imm8 | rd = rs1 & imm |
|      | ORI | 0x0B | 0x2C | flag=11 | rd, rs1, imm8 | rd = rs1 \| imm |
|      | XORI | 0x0C | 0x30 | flag=11 | rd, rs1, imm8 | rd = rs1 ^ imm |
|      | SLLI | 0x0F | 0x3C | flag=11 | rd, rs1, imm8 | rd = rs1 << imm[2:0] |
|      | SRLI | 0x10 | 0x40 | flag=11 | rd, rs1, imm8 | rd = rs1 >> imm[2:0]（逻辑右移） |
|      | SLTIU | 0x12 | 0x48 | flag=11 | rd, rs1, imm8 | rd = (rs1<imm)? 1 : 0（无符号） |
| 访存 | LBU | 0x1C | 0x70 | 否 | rd, 16 位地址（byte2:3） | 读 → rd（RAM 或外设） |
|      | SB | 0x1D | 0x74 | 否 | rs, 16 位地址（byte2:3） | rs 写入（RAM 或外设） |
|      | SBI | 0x1E | 0x78 | 否 | imm8（byte1）, 16 位地址（byte2:3） | 立即数写入（RAM 或外设） |
|      | **LIND** | **0x1F** | **0x7C** | 否 | rd, r1, r2（各 8 位寄存器号） | **寄存器间接读**：rd = 读 `[regs[r1]:regs[r2]]` |
|      | **SIND** | **0x20** | **0x80** | 否 | rs, r1, r2（各 8 位寄存器号） | **寄存器间接写**：写 `[regs[r1]:regs[r2]]` = rs |

共 **34 条真实指令** + 1 条伪指令。

> **寄存器间接寻址（LIND/SIND）**：地址 = `regs[r1] 的内容 << 8 | regs[r2] 的内容`（16 位）。r1/r2 是寄存器号（byte2/byte3），其内容拼成访存地址；与 LBU/SB 走同一总线。LIND/SIND 恒原长 1 词（不压缩）。**v3.5.0 下 r1/r2 也走 baseline 映射**（见 §1.5）。
> **伪指令 MOV**：`MOV rd, rs` = 复制（rd ← rs）。RTL 不设 MOV opcode，汇编器翻译为 `ADDI rd, rs, 0`。
> **分支寄存器 4 位**：6 条条件分支的 r1/r2 只编码低 4 位（可用 r0–r15）。汇编器对超出 0x0F 的寄存器报错。
> **压缩字段上限**：ALU 压缩要求 `rd≤3、r1/r2≤7`（I 型 `imm≤7`），超限自动退回原长——对汇编器透明。

### 1.3 压缩编码详解（16bit，位于词的 [31:16] 或 [15:0]）

```
高 8 位 = byte0 = opcode[5:0]<<2 | flag
低 8 位 = {rd[1:0], r1[2:0], r2[2:0]}      （flag=11，ALU-R）
       = {rd[1:0], rs1[2:0], imm[2:0]}    （flag=11，ALU-I）
       = 0x00                             （flag=01，NOP/IRET）
```

### 1.4 跳转偏移 bytmov（16 位【词单位】，基准 W+2）

- **R 前缀（向前）**：`bytmov = target − (W+2)`；**L 前缀（向后）**：`bytmov = (W+2) − target`。
- **覆盖极限**：bytmov 16 位 → 每跳/分支最多 ±0xFFFF 词，覆盖 0x000–0x1FFF 全空间。
- **汇编器自动修复**：bytmov 死区自动补 NOP（AUTO_NOP）、L/R 方向自动翻转（AUTO_FLIP）、jpad 自动垫层（AUTO_JPAD）。

### 1.5 寄存器映射（v3.5.0 新增，baseline 窗口）

> **这是 v3.5.0 与之前版本最大的语义差异**。指令编码不变，但**寄存器操作数所指的物理寄存器**由 RPU 统一平移。

**核心公式**：所有寄存器操作数（ALU rd/rs1/rs2、分支 r1/r2、LIND/SIND r1/r2、写回 rd）映射为：

```
物理寄存器号 = raw + ((raw < 8'd253) ? baseline : 8'd0)
```

- **baseline**：由总线写 **0xD000**（`bus_addr[15:12]==0xD` 且写）设定；`LBU 0xD000` 读回（组合）。复位 baseline=0。
- **相对操作数**：源码写 `rK` → 编码 raw=K → 物理 `regs[base+K]`。**各任务在自身 base 窗口内，r0-r7 等低编号可直接用条件跳转/压缩**。
- **绝对操作数**：源码写 `rK.base`（汇编器标注）→ 编码 raw=K−base → 物理 `regs[K]`。用于跨任务/全局访问固定物理寄存器。**K≥253 豁免**（raw 保持 K；r253/r254/r255 恒绝对）。
- **豁免段 ≥253**：r253（j 相关）/ r254（i2c_busy）/ r255（tx_busy）不被 baseline 平移，恒绝对。

| 项 | 约定 |
|----|------|
| r0 | 恒为 0。**⚠️ v3.5.0 窗口下"相对 r0"= regs[base]**，写守卫 `rd≠0` 只保护物理 regs[0]；**base>0 时程序必须保持 r0 恒 0（绝不写 r0）** |
| r1–r252 | 窗口相对：物理 = raw+baseline（按当前任务窗口平移） |
| **r253** | **调用栈指针 j**（全局豁免，恒绝对）；LJAL/RJAL 压栈、JALR 弹栈，reg_f 内 `rad[regs[253]]` |
| **r254** | **i2c_busy**（每次覆写 `{7'b0,i2c_busy}`，恒绝对；软件写会被硬件覆写） |
| **r255** | **tx_busy**（每次覆写 `{7'b0,tx_busy}`，恒绝对；软件写会被硬件覆写） |
| 调用栈 | 硬件栈（reg_f 内 `rad`，16 位槽×深 255），指针=regs[253]（分区：任务0 0-63/任务1 64-127/任务2 128-191） |
| PC | 13 位词地址 0x000–0x1FFF |

> **RPU 窗口布局**：每个任务独立 base，物理空间互不重叠。任务0=0x00（恒等，shell/游戏沿用高 r17-r21）、任务1=0x16、任务2=0x26；调度器切任务时 `SBI <base>,0xD000` 切换。新的任务可 base=0x36 起，直接用 r0-r7 压缩位+条件跳转，不再与既有任务抢物理寄存器。

### 1.6 汇编器 `.base` / `rX.base`（v3.5.0 新增）

- **`.base N`**：声明当前代码块的寄存器窗口基准（范围 0–0xF0）。仅供汇编器换算 `rK.base`。
- **`rK`**（相对/窗口）：原样编码 raw=K（硬件自动 +baseline）。
- **`rK.base`**（物理绝对）：编码 raw=K−base；**K≥253 → raw=K**；K−base 越界报错。
- **默认 base 0**：`rK.base` ≡ `rK`，对既有程序**逐字节兼容**（回归验证：v3.3.0 shell hex 一字不变）。

---

## 2. 外设与地址空间

> 地址空间 v3.5.0 变化（相对 v3.3.0 基线）：**0xD000 区间由"未分配黑洞"变为 baseline 系统寄存器**。其余外设地址不变。

### 2.1 地址空间总表

解码位 `[15:12]`（4 位）：

| 区间 | 设备 | LBU（读） | SB（写） |
|------|------|-----------|----------|
| 0x0000–0x1FFF | I2C | 黑洞（返回 0） | 数据 FIFO（0x1000）/ 配置（0x1200）/ start（0x1400）/ stop（0x1600）/ 清 err（0x1800） |
| 0x2000–0x2FFF | UART | 弹 RX FIFO 队首 → rd | 写 TX FIFO（触发发送） |
| 0x3000–0x3FFF | timer | 黑洞（返回 0） | 重装 / 模式 / ack |
| 0x4000–0x4FFF | GPIO | 读 IN 引脚电平 → rd | 推挽输出 / 单 pin 模式 |
| 0x5000–0x5FFF | IRQ_W（软中断） | 读被抢占断点 slot | 向量表写 / 2 条连续 SB 改写 ISR 返回地址 |
| 0x6000–0x6FFF | BUS_CON | 黑洞（返回 0） | 写中断优先级 / 一次性解锁 |
| 0x7000–0x7FFF | DMA | 读 cnt_wr（0x7600/0x7700） | 配置 ini/cnt/des/bank + 触发 |
| 0x8000–0xAFFF | ram_top（3×ram_sec） | 读 RAM → rd | 写 RAM |
| 0xB000–0xBFFF | ram_ext 选片 | 黑洞（返回 0） | SB one-hot 选 bank |
| 0xC000–0xCFFF | ram_ext 数据 | 读当前选中 bank → rd | 写当前选中 bank |
| **0xD000–0xDFFF** | **RPU baseline（v3.5.0）** | **LBU 读当前 baseline** | **SB/SBI 写 baseline（设窗口基址）** |
| 0xE000–0xFFFF | 未分配 | 黑洞 | 黑洞 |

> 总线访问均为 2 拍（RAM 第 1 拍置 stall；外设无 stall）。LIND/SIND 与 LBU/SB 走同一总线。
> **0xD000 baseline 写**：`bus_addr[15:12]==0xD` 且写信号 → `baseline <= bus_data_in`；**0xD000 读**：同区间且非写 → `bus_data_out = baseline`。

### 2.2 双端口外设（v3.2.0）

外设（ram_top/ram_ext/uart）双端口：`dma_oc = (bus_addr_dma[15:12]==本外设段)` 时用 DMA 总线，否则 CPU 总线。

### 2.3 bus_controller（统一仲裁 + 中断优先级 + 一次性 lock）

- **CPU 读仲裁** 与 **DMA 读返回仲裁** 双路。
- **中断优先级（6 槽）**：0=timer 1=dma 2=rx 3=i2c 4=gpio0 5=gpio1。SB `0x6000+[2:0]`（addr bit3=1）写 prio（2bit，0=关闭）。当前 boot 写 slot0-4（`0x6008-0x600C`）。
- **一次性 lock**：复位 `irq_lock=1`；`SB 0x6000-0x6007`（addr bit3=0）→ 解锁（不可再锁）。
- **irq_bus 编码** `{prio[2:0], dev[2:0], 000}`，dev timer=001/dma=101/rx=010/i2c=110/gpio0=011/gpio1=100。

### 2.4 DMA（0x7000–0x7FFF，v3.2.0）

- **状态机**：IDLE → INI → HSH → LD ↔ WR。
- **配置**：ini_addr(0x7000)/cnt(0x7100)/cnt_due(0x7200)/des_addr(0x7300)/ini_bank(0x7400)/触发(0x7500)/清 irq(0x7600)/读 cnt(0x7600,0x7700)。
- **busy 按目的选**：`busy = (des_addr[15:12]==UART)?busy1 : (==I2C)?busy2 : 0`。
- **俄罗斯方块用法**：渲染帧写 ram_ext bank0（0xC000），`SB r0,0x7500` 触发，DMA 发 UART，轮询 cnt。

### 2.4.1 I2C 输出模块（0x1000–0x1FFF，v3.3.0）

只输出 I2C 主机。寄存器（`[11:9]`）：数据 FIFO 写（0x1000）/ 配置 frq+ack（0x1200）/ start（0x1400）/ stop（0x1600）/ 清 err（0x1800）。SCL 双相 40/60 占空比三档；ack=1 一字节一 start（NACK→i2c_err_irq+STOP），ack=0 一次 start 连续发完。busy=`wr!=rd+1`（供 DMA busy2）。

### 2.5 ram_top（0x8000–0xAFFF，12KB）

分片 `addr[13:12]`：0x8000-0x8FFF/0x9000-0x9FFF/0xA000-0xAFFF（ram_sec_init，readmemh data.hex）。ram_sec_1/2 上电全 0；ram_sec_init 由 data.hex 初始化。同步写/寄存器读，2 拍访问。

### 2.5.1 ram_ext_top（0xB000 选片 + 0xC000 访问，4×4KB）

选片 SB 0xB000 one-hot + sec_num；访问 0xC000 读写当前 bank，片内偏移 `addr[11:0]`。

### 2.6 UART（0x2000–0x2FFF，RX/TX 双 FIFO）

`LBU rd`@0x2000 弹 RX FIFO 队首（空返 0）；`SB rs`@0x2000 写 TX FIFO；`LBNE r255,r0,自旋` 等 tx_busy。RX 64 深（读出 `rx_buf[rd+1]`），TX 64 深（只收 `[15:12]==0x2`）。tx_busy=`rd!=wr-1`。rx_irq=FIFO 非空。

### 2.7 timer（0x3000–0x3FFF，纯写，32 位）

`SB`@0x3000-0x3003 设重装字节；@0x3004 设 irq 模式（bit0=0 脉冲/1 电平锁存）；@0x3005 ack。计数 0→重装值，全 32 位相等时 timer_irq=1 并清零，周期=重装值+1 拍。

### 2.8 GPIO（0x4000–0x4FFF，8 位）

`LBU` 读引脚（仅 IN 回电平）；`SB`@偶数地址推挽输出、@奇数地址设单 pin 模式。方向：仅 OUT/TX 驱动，其余高阻。中断分组 pins 1-3→GPIO1、pins 4-7→GPIO2，电平式无 ack。

### 2.9 中断、向量与嵌套

| 中断源 | irq_bus[5:3] | irq_vex 索引 | boot 配置向量 | 优先级 |
|--------|--------------|--------------|--------------|--------|
| Timer | 001 | 0 | 0x248 | 3（最高） |
| UART RX | 010 | 1 | 0x260 | 2 |
| GPIO1 | 011 | 2 | 0x208 | 1 |
| GPIO2 | 100 | 3 | 0x228 | 0 |
| DMA 完成 | 101 | 4 | 0x208（防御） | 0（关） |
| I2C 应答错误 | 110 | 5 | 0x490（默认） | 4（boot 0x600B=0 关） |

- **向量表总线可写**：`SB` 0x5000 区，`bus_addr_in[4:2]`=槽位、`[1:0]=1`写高字节/`=2`写低字节。**boot 必须写向量指针**覆盖默认。
- **一次性 lock**：boot 在锁内写 prio + 向量，解锁后中断才放行。
- **优先级**：更高优先级可抢占当前 ISR。**中断栈/嵌套**：irq_controller 内置 8 深返回地址栈。
- **软中断 IRQ_W（0x5000）写路径**：连续 2 条 SB 改写栈顶返回地址；读路径：`LBU` 读被抢占任务断点（slot0=0x5000 低/0x5001 高）。

> **中断语义（v2.2 延续）**：① 授权门控 irq_en==11；② 被中断指令写回不丢；③ IRET W+2 + `__jpad` 垫层；④ 抢占断点 pc-1。

---

## 3. v3.5.0 软件侧约定（RTOS 内核，RPU 窗口）

指令集文档范围之外、写程序必须遵守的 v3.5.0 约定（细节见设计日志）：

| 项 | 约定 |
|----|------|
| **窗口分配** | 任务0(base 0x00, shell/游戏, 高 r17-r21 沿用)、任务1(base 0x16)、任务2(base 0x26)。**新增任务 base 0x36 起** |
| **寄存器分块** | 任务内用**窗口相对号** rK；跨任务/全局用 **rK.base** 绝对号；**r0 恒 0 不写**；调度器 r12-r15 临时（=当前 base+12..15） |
| **调度器切 baseline** | 载任务段 3 处 `SBI <base>,0xD000`；保存段在旧任务 base 下存 PC+j+r7-r11 |
| **共享子程序** | r7-r11（各任务窗口内 r7-r11，调度器按任务保存/恢复） |
| **调用栈分区** | 任务0 0-63 / 任务1 64-127 / 任务2 128-191；调度器恢复各自 j（豁免绝对号） |
| **汇编器** | `.base` 声明窗口；`rK.base` 绝对号；相对号 `rK` 自动适配硬件 |

---

*本文档随版本更新；新增外设/指令/寄存器语义时同步追加对应表格。*
