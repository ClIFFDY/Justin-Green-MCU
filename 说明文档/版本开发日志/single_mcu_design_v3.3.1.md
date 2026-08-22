# MCU 设计记录（v3.3.1 —— 纯软件层：扫雷 + GAME 子菜单 + 开机动画 + 打字机 + 垫层移除）

> 版本：2026-08-22。**v3.3.1 是纯软件层更新**（在真 v3.3.0 基础上）：**RTL/ISA/外设/地址空间全部不变**（指令总数 34，编码不变）。改动集中在 **tools/rtos_shell_game_mpu.asm**（RTOS shell 程序）与 **tools/asm.py**（汇编器）：
> ① 新增 **8x8 扫雷**（LIND/SIND 棋盘渲染，复用俄罗斯方块帧 DMA）；② 主菜单 3 → **GAME 子菜单**（俄罗斯方块/扫雷同层）；③ **打字机效果**（putc 逐字延迟 ~5ms）；④ **开机动画**（7 阶段大写英文 + 加载条 0→100，解锁中断前）；⑤ **IRET 垫层移除**（微测确认 irq_controller 存 W+1，垫层冗余，程序瘦 19%）；⑥ **flush_rx**（打印期间积压按键丢弃）；⑦ 汇编器 **.puts 跨 256 页对齐修复**。
> 指令集速查见 `指令集说明/mc_v3.3.1_ins.md`（ISA 不变，重命名一份并标注软件层改动）。

## 0. 版本说明

| 维度 | 真 v3.3.0 | v3.3.1（当前） |
|------|-----------|----------------|
| RTL/ISA | I2C + RPU 映射，34 条 | **完全不变**（纯软件） |
| 游戏 | 俄罗斯方块 | **+ 扫雷**（GAME 子菜单 1.TETRIS 2.MINESWEEP） |
| 菜单 | 主菜单 3 直接进俄罗斯方块 | **主菜单 3 → GAME 子菜单** |
| 输出 | putc 立即发送 | **打字机效果**（逐字 ~5ms） |
| 开机 | 直接进 shell | **开机动画**（7 阶段加载条，解锁中断前） |
| __jpad 垫层 | 手写 91 + 自动 355 | **全移除**（微测确认 W+1 语义） |
| 程序词数 | 2327 词 | **1979 词**（省 348，含新功能） |
| 汇编器 | — | **.puts 跨 256 页对齐修复** + flush_rx |

## 1. 扫雷（8x8，v3.3.1 新增）

- **入口**：GAME 子菜单选 2 → `minesweeper_start`（GAME 独占模式，调度器只更新 TICK 不切任务）。
- **玩法**：连续输入 3 个数字 = 横坐标(1-8) 纵坐标(1-8) 操作(1=探雷 2=插旗)；按 0 随时返回 GAME 子菜单。
- **数据**（RAM 0x9500 区）：MS_MINE[64]（bit7=雷 + 低4位=邻雷数）/ MS_VIEW[64]（0=未探 1=旗 2=已探 3=踩雷）/ MS_COL/MS_ROW/MS_OP/MS_INN 输入态 / MS_OPEN 已探开 / MS_QUEUE 洪水队列。
- **布雷**：10 颗 LCG 随机（`seed=seed*13+7`，种子=TICK，重复雷重抽）；邻雷数对每颗雷 8 邻非雷格 +1（坐标越界检查，`SLTIU rX,8` 天然排除负/超界）。
- **探雷**：0 雷格 DFS 洪水展开（4 邻，MS_QUEUE 栈）；踩雷 → 标所有雷 VIEW=3 + GAME OVER；54 格全探开 → CLEARED。
- **渲染**：复用俄罗斯方块 fputc（写 0xC000 帧缓冲）+ dma_frame_send（DMA 发 UART）。`[ ]` 未探 / `[n]` 数字 / `[F]` 旗 / `[*]` 雷。
- **GAME OVER 混排修复**：踩雷后 ms_over_msg **先 wait_dma** 等棋盘帧发完再 putc，避免 DMA 帧未发完文本插进来。
- **状态残留修复**：minesweeper_start 清零 MS_OVER/MS_OPEN/MS_INN 等 7 个状态字节（残留会导致"没踩雷也 game over"）。

## 2. GAME 子菜单（v3.3.1）

- 主菜单 **3 → MENU=1 + game_menu**（GAME 子菜单），`shell_parse` 按 MENU 状态分派。
- GAME 子菜单：**1=TETRIS 2=MINESWEEP 0=MAIN MENU**。
- 俄罗斯方块退出 `game_exit` 回 GAME 子菜单（非主菜单）。

## 3. 打字机效果（putc 逐字延迟）

- putc 发送后加 `250×255` 双层延迟循环 ≈ **5ms/字符**。菜单/文本逐字打印，有"一个字一个字打出"效果。
- 俄罗斯方块/扫雷渲染走 fputc（DMA 帧），**不受影响**。
- 调速：`ADDI r9, r0, 250` 那行的值（250→更大更慢，更小更快）。

## 4. 开机动画（v3.3.1，解锁中断前）

- **7 阶段**：GPIO / KERNEL / BUFFER / STACK / IRQPRIO / VECTOR / READY，插在各 init 段后、`SB r0, 0x6000` 解锁中断**之前**（boot 期间无抢占，动画流畅）。
- 每阶段：`.puts " BOOT: XXX  "`（大写英文，补空格到 15 字符对齐）+ `anim_bar`（加载条 0→10 个 `#`，每帧 30ms，`[` → `##########` → `]`）。
- `fast_putc`：动画专用快速发送（不走打字机延迟）；`anim_bar`：加载条子程序（每帧只加一个 `#`）。

## 5. IRET 垫层移除（v3.3.1，省 19%）

- **微测确认**（`temp_bus_tb/iret_w1_tb.v`）：irq_controller 派发沿存 `pc_addr_in - 1`（[irq_controller.v:93](:/project_self-try.srcs/sources_1/new/core/irq_controller.v#L93)），IRET 回 **W+1**（授权点下一条），控制转移不会被跳过 → **垫层冗余**。
- 汇编器 asm.py：**移除 auto_jpad**（不再自动补）；asm 源删除全部手写 `__jpad` 垫层 + 悬空标签。
- 程序词数 2327 → 1979（省 348 词，含新功能净效果），压缩指令重新配对打包。

## 6. flush_rx（打印期间忽略输入）

- `flush_rx`：清空 RX 环形缓冲（RX_WR=RX_RD=0）。
- 菜单/长文本打印函数（menu_main/game_menu/cmd_credits/cmd_status）末尾调用 → **打印期间积压的按键丢弃**，打印完才接受新输入。

## 7. 汇编器修复：.puts 跨 256 页对齐

- **根因**：`.puts` 长文本用 LIND 循环读（地址 `{r1,r2}`，只有 r2 低字节自增），跨 256 字节边界时 r2 回绕、高字节不递增 → 读到数据区开头。
- **修复**：asm.py 数据区收集时，文本跨 256 页则在前插 `0` 填充对齐到页起始，保证每个文本完整落在单一页内。datalabel 偏移同步回填。
- 开机动画加了 boot 文本后数据区前移，主菜单 ` 0. MENU` 恰好跨页触发此 bug（"0 后面显示 boot 内容"），已修复。

## 8. 其他

- CREDITS "system: RTOS" → "**System: RTOS**"（首字母大写）。
- 汇编开发手册已存记忆库（asm-dev-handbook.md），后续开发软件直接查。

## 9. 上板验证（v3.3.1 全通过）

- 开机动画 7 阶段加载条依次增长 → 进主菜单。
- 主菜单 3 → GAME 子菜单（俄罗斯方块/扫雷），1/2/0 切换正常。
- 扫雷：布雷/探雷/插旗/洪水/踩雷标雷/GAME OVER/CLEARED 全正常。
- 打字机逐字打印；打印期间按键被丢弃（flush_rx）。
- 垫层移除后 RTOS 抢占/任务切换/俄罗斯方块正常。
- CREDITS "System: RTOS"。

## 10. 归档

- 纯软件：`tools/rtos_shell_game_mpu.asm`（源）+ `ins_rom.hex`（1979 词）+ `data.hex`。
- RTL/ISA 不变（同 v3.3.0）。
- 文档：本设计记录 + `mc_v3.3.1_ins.md`（ISA 重命名标注）。
