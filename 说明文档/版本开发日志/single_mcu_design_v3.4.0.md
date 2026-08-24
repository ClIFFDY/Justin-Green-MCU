# MCU 设计记录（v3.4.0 —— RTL 时序优化：rpu 时序中继 / flush 分离 / bytmov 提前锁存，66.67MHz）

> 版本：2026-08-22。**v3.4.0 是 RTL 时序优化版**（针对 66.67MHz（15ns 周期））：在 v3.3.1（软件层 + 扫雷）基础上，重构取指链路关键路径。**指令集 34 条**；2026-08-23 **NOP/HALT 编码对调**（NOP 0x00 / HALT 0x14，见 §6.5），软件 hex 重新汇编。
> 核心改动：① **rpu 时序化中继**（原组合映射 → 流水线一级，baseline SBI 提前生效）；② **flush 机制重做**——跳转 `jmp_flush` 无条件冲刷（避免预取残留跑飞）/ 中断 `irq_flush` 精确冲刷（减少空窗）；③ **bytmov_to_pc 提前锁存**（去 decoder 译码延迟）；⑤ **pc default 修正**（取指延迟 3 级 → +1，原手误 +2）；⑥ 汇编器 **bytmov 基准 W+2→W+3**（适配 3 级取指延迟）。
> 指令集速查见 `指令集说明/mc_v3.4.0_ins.md`（ISA 不变，重命名一份标注时序优化）。

## 0. 版本说明

| 维度 | v3.3.1 | v3.4.0（当前） |
|------|--------|----------------|
| RTL 架构 | 组合映射 + 统一 flush | **rpu 时序中继 + flush 分离** |
| 取指延迟 | 3 级（unzipper+rpu） | **3 级（不变）**，pc default 修正 +1 |
| 跳转冲刷 | 统一（jmp_flush \|\| irq_flush）&& flush_en | **jmp_flush 无条件 / irq_flush 精确** 分离 |
| bytmov | decoder 组合译码 | **rpu 提前锁存**（bytmov_to_pc） |
| pc 跳转判断 | case(opcode) + jmp_flush 使能 | **bytmov 提前锁存** |
| 汇编器 | bytmov 基准 W+2 | **W+3** |
| 目标频率 | 50MHz（达标） | **66.67MHz 冲高（余量 0.157ns）** |
| ISA/软件 | 34 条 + 扫雷 | **不变**（重新汇编） |

## 1. rpu 时序化中继（v3.4.0）

- **rpu 从组合映射改为流水线一级**：`opcode/inst_raw_cont/bytmov_to_pc` 全部时序锁存（stage==2'b01）。
- **baseline SBI 提前生效**：rpu 检测 `opcode_in==SBI && inst_raw_cont_in[15:12]==0xD` 时，**下一拍直接锁存新 baseline** + 映射用新 baseline（不用等总线 2 拍 stall）。配合原有 `LBU 0xD000` 读 baseline。
- 流水线：ins_rom → **unzipper（级1，拆包）** → **rpu（级2，中继+映射）** → decoder（组合）→ id_reg → alu → wr_reg → reg_f。

## 2. flush 机制分离（v3.4.0）

| flush | 语义 | 冲刷 |
|-------|------|------|
| `jmp_flush`（跳转） | 跳转指令触发 | **无条件**冲刷 unzipper+rpu（预取残留会流到 decoder 跑飞，必须清空） |
| `irq_flush`（中断） | 中断派发触发 | **精确**冲刷（`flush_en` 参与，只冲缓存跳转指令的级，减少空窗） |

- **为什么跳转必须无条件冲刷**：跳转指令后的预取指令（普通指令，flush_en=0）若保留，会在跳转后流到 decoder 执行 → 跑飞。实测确认。
- **为什么中断可精确**：中断断点由 irq_controller 存 `pc_addr - (flushed1+flushed2)`，IRET 恢复时重新取指，保留的预取指令不构成跑飞。
- `flushed1/2`（unzipper/rpu 报告被冲刷）：jmp_flush 时**无条件记 1**（跳转必须清空），irq_flush && flush_en 时记 1。

## 3. 关键路径优化（66.67MHz 达标）

**原关键路径**：`rpu.opcode_reg → decoder(bytmov 译码 + 分支条件) → pc case(6bit) → pc_addr ± bytmov(16bit 进位) → pc_addr_reg`，优化前 72MHz 目标下 -2.2ns 违例（关键路径 ~16.1ns）。

**优化后路径**：
```
rpu.opcode_to_pc(6bit) + rpu.bytmov_to_pc(16bit) → pc case(opcode) + jmp_flush 使能 + op_raw[0] 方向 → pc_addr ± bytmov → pc_addr_reg
```
- **bytmov_to_pc**：rpu 锁存 `inst_raw_cont_in[23:8]`（跳转偏移），pc 直接用——去掉 decoder 的 bytmov 组合译码。
- **bytmov_to_pc 提前锁存**：跳转偏移在 rpu 锁存，pc 直接用（去 decoder 组合译码）。
- WNS：**66.67MHz 达标（余量 0.157ns）**；72MHz 违例 -0.1ns（几乎达标，差 0.1ns）——但总线侧仍有多条违例路径进不了 14ns（13.89ns），决定止步 66.67MHz。

## 4. pc default 修正（手误）

- 原新版 pc default 误写 `pc_addr + 2` → 导致 pc 超前 6 词（3 级×2），指令译码错位、返回地址错。**改回 `+1`**（指令 1 词连续，取指延迟 3 → pc=W+3）。

## 5. 汇编器适配（v3.4.0）

- **bytmov 基准 W+2 → W+3**：取指延迟 3 级，跳转偏移 = target - (W+3)。（asm.py `bytmov_for` + 死区检测同步 W+3）
- 死区补 NOP：`target == word+3` 时补 `word+4-target` 个 NOP 拉开。
- **RTL 改动不影响 hex 语义**：重新汇编后程序结构等价（分支/调用目标按新基准对齐）。

## 6. RTL 改动清单

| 文件 | 改动 |
|------|------|
| `unzipper.v`（原 pre_decoder 改名） | 拆包逻辑；flush 分离（jmp_flush 无条件 / irq_flush && flush_en 精确）；flushed1 按新逻辑 |
| `rpu.v` | 时序中继；baseline SBI 提前；bytmov_to_pc 提前锁存；flush 分离；flushed2 |
| `pc.v` | default +1；jmp_flush 使能（替代 bytmov!=0 判断） |
| `decoder.v` | 跳转合并（删 bytmov 输出，只留 jmp_flush 条件） |
| `single_cpu_top.v` | 接线（unzipper/rpu/pc/decoder 新端口） |
| `tools/asm.py` | bytmov 基准 W+3 + 死区检测 |

## 6.5 NOP/HALT 编码对调（2026-08-23）

- **编码对调**：`NOP` 0x14→**0x00**，`HALT` 0x00→**0x14**。这样寄存器/时序中继的**复位默认值 0 天然是 NOP**（空操作），从根上消除"复位/init 时 opcode=0 被误判 HALT → frz 毛刺 → fsm stage 卡 IDLE → CPU 死锁"的隐患。
- **原因**：v3.4.0 rpu 时序化后，rst 分支曾把 opcode 初始化为 `6'b0`（旧 HALT），decoder 对 HALT 输出 frz=1 毛刺 → fsm `else if(frz) stage<=IDLE` 把 stage 打进 IDLE（无恢复机制）→ pc 只在 EXE 推进 → **CPU 上电不跑**（ILA 定位：pc 恒 0、frz init 1ns 毛刺、stage 卡 IDLE）。
- **改动文件**：decoder.v（HALT/NOP localparam）、ins_rom.v / rpu.v / unzipper.v（NOP localparam）、asm.py（OPCODE 字典）。**软件 hex 需重新汇编**（NOP/HALT 编码变化）。
- **压缩编码**：NOP 压缩 byte0=`0x00<<2|0x01`=0x01（flag=01），HALT 原长 byte0=`0x14<<2|0x00`=0x50（flag=00）。与 ADDI(0x01) 原长 byte0=0x04 无冲突（flag 位区分）。

## 7. 验证

- **隔离取指链路**：pc→ins_rom→unzipper→rpu→decoder 逐 PC 译码对应，cstall 拆包正常。
- **跳转/调用链**：LJAL/RJAL 压栈 ra=调用点下一条（0x002），JALR 弹栈返回正确，j 栈 0→1→0。
- **跳转无条件冲刷**：flushed1+flushed2=2，ra = pc_addr - 2 正确（修复精确冲刷下 ra 错位）。
- **综合**：优化后 **66.67MHz 达标（余量 0.273ns）**；72MHz 违例 -0.1ns，总线侧另有违例路径，决定止步 66.67MHz。

## 8. 已知事项

- 软件层（扫雷/GAME 子菜单/打字机/开机动画）同 v3.3.1，本版只动 RTL + 汇编器。
- 开机动画打字机慢（putc 每字符 ~5ms）——boot 到主菜单需 ~0.5s 仿真，上板正常。

## 9. v3.4.0 刷屏修复 + RX 使能（2026-08-24，v3.4.0 继续，上板全通）

### 9.1 现象
上板菜单/界面正常后出现 **'2' 字符洪泛**（shell 空闲后连续发 '2'，每 ~600µs 一个，一直刷屏），按键无响应。

### 9.2 根因（irq resume=pcIn-2 在分支 refill 窗口偏 2 词）
- **irq_controller 保存 `resume = pcIn - 2`**。稳态下 `pcIn = 执行中指令 + 3`（取指延迟 3 级），故 `resume = 执行中 + 1 = 下一条指令`，正确。
- 但**分支/跳转（LJAL/RJAL/条件分支/JALR/IRET）后的 refill NOP bubble**（unzipper/rpu 在 `jmp_flush`/`irq_flush` 插 opc=0）时：`pcIn` 已被 bytmov 推到**跳转目标**，rpu/decoder 还在空槽 → IRQ 在此拍触发（refill bubble 是 opc=0，decoder NOP 不拉低 irq_en）→ `resume = 目标 - 2`，**落在目标前 2 词**。
- 具体撞点：`tick_bookkeeping@0x5F3` 紧邻 print_bar 尾部 `RJAL putc`@0x5F1。resume 落 0x5F1 → 跳过 `ADDI r7,']'`，r7 还是 shell 空闲阈值 50（0x32 = '2'）→ putc 发 '2'；TCB0_PC 每次存回 0x5F1 → 自持洪泛。
- **irq_en 只挡分支那一拍**（decoder RJAL/branch → irq_en=0），refill bubble(opc=0) 不拉低，下一拍即触发 → 无法用 irq_en 钳位挡住。

### 9.3 RTL 修复（bubble 补偿，用户设计）
- **irq_controller**：`resume = pcIn - ((cstalled)?1:2) + bubble`。
- **pc.v**：新增 `bubble[1:0]` 输出；跳转（LJAL/RJAL/条件分支）/IRQ 派发/IRET 时 `bubble <= 2'd2`，每拍递减。refill 期 `pcIn-2+bubble` 稳定落回跳转目标（bubble 递减抵消 fetch 前进：pcIn=目标/目标+1/目标+2 时 bubble=2/1/0 → resume 恒 = 目标）。**JALR 也补 `bubble<=2`**（原漏——弹栈返回同样有 refill 窗口）。
- 稳态 bubble=0，`resume=pcIn-2` 不变，既有功能无损。
- 改动文件：`irq_controller.v`（+bubble 输入与加法）、`pc.v`（+bubble 计数/输出）、`single_cpu_top.v`（接线）。

### 9.4 RX 中断使能
- 刷屏根因是 bubble bug 而非 RX 悬空误判 → 固件 `SB r0,0x600A`（RX prio=0，原为挡刷屏的 workaround）撤销，改 `ADDI r1,r0,2; SB r1,0x600A`（RX prio=2）。
- RX 通路要点：RAM `RX_WR/RX_RD/RX_RING`（0x9100-0x9109）无硬件桥直连 uart_top 的 rx_buf，全靠 `uart_isr@0x260` 搬（读 UART→写 RING→WR++）→ **RX 中断必须使能**。
- 交互 sim 验证（注入 '2'+CR）：RX ISR → RX_RING → shell 回显 '2' → STATUS 子菜单。

### 9.5 验证与归档
- 200ms 整机 sim：无 '2' 洪泛、2cnt=1、corrupt=0。
- 上板：菜单正常不刷屏、按键响应正常、所有功能正常。
- 归档（v3.4.0 继续）：Github_Repository + `Justin_MCU_v3.4.0_resv` 同步；hex md5 `1598fd49`；tools 换 `asm.py + rtos_shell_game_mpu.asm`（debug 变体 rtos_shell_game.asm 移除）。
