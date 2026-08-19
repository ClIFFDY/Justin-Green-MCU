# MCU 设计记录（v3.0.1 —— 俄罗斯方块集成 shell + 数据区化 + hex 分离）

> 版本：2026-08-20。**v3.0.1 是系统层 + 软件整合版**：在 v3.0（核心架构重构 + LIND/SIND + 俄罗斯方块 v2）基础上，把俄罗斯方块**集成进 RTOS shell 菜单**（GAME 独占模式，保留中断），引入**数据区**（0xB000 初始化 RAM，程序文本/数据外置）+ **hex 分离 2 个**（ins_rom.hex 程序 + data.hex 数据），shell 主菜单精简为 credits/status/game，并修复两个上板实测 bug（按 0 无法终止游戏、偶发消不掉行/方块丢失）。
> 指令集速查见 `指令集说明/mc_v3.0.1_ins.md`（**ISA 无改动**，与 v3.0 相同，指令总数 34；随版本重命名一份）。
> **核心架构、ISA、中断/RTOS 语义均与 v3.0 相同**；RTL 新增 1 个外设 `ram_sec_init.v`（数据区初始化 RAM），核心 6 文件无改动。

## 0. 版本说明

| 维度 | MCU v3.0 | MCU v3.0.1（当前） |
|------|----------|--------------------|
| 核心架构 | 同步读 reg_f + pre_decoder + ram_top 握手重做 | **相同**（核心无改动） |
| ISA | 34 条（含 LIND/SIND） | **34 条，无改动** |
| 系统程序 | rtos_tetris_v2（俄罗斯方块单任务演示） | **rtos_shell_game**（俄罗斯方块集成 shell 菜单） |
| RTOS | 不用（单任务） | **抢占调度器 + GAME 独占模式**（保留中断，只更新 TICK 不切任务） |
| 数据存储 | 文本/数据内联 ROM | **数据区 0xB000**（ram_sec_init 初始化 RAM，程序 LIND 读） |
| hex | 1 个（ins_rom.hex） | **2 个**（ins_rom.hex 程序 + data.hex 数据，v3.0 起归档规范） |
| shell 菜单 | 俄罗斯方块独立（无菜单） | **主菜单 1.credits 2.status 3.game 0.menu**；credits 无版本号 |
| 汇编器 | .puts/自动 jpad/LIND 编码 | **+ .data/.db 数据区 + .puts 长文本数据区化 + hex 分离输出** |
| 上板实测 | 待上板 | **稳定**（俄罗斯方块 + shell + 退出/重入） |

## 1. 俄罗斯方块集成 shell（GAME 独占模式）

`tools/rtos_shell_game.asm`（任务0=shell，俄罗斯方块核心嵌入）。此前俄罗斯方块是单任务独立程序；现改为**主菜单 3 → 进入游戏**：

- **GAME 独占模式**：`game_start` 置 `GAME_ACTIVE@0x9486=1`，调度器 `sched_body` 检测该标志 → **只更新 TICK、不切任务**（用户明确要求游戏运行时**不要关停 shell 中断**，保留中断、跳过任务切换）。恢复现场用 GAME_S1-3 槽保存 r12-r14。
- **俄罗斯方块按键**：`4` 左移 / `6` 右移 / `5` 旋转 / `7` 快落（落到底固化即停）/ `1` 暂停 / `0` 返回主菜单。
- **返回**：按 0 置 `G_OVER`，game_loop 检测后走 `game_exit`：清 GAME_ACTIVE/MENU → 打主菜单 → `JALR` 弹栈回 shell_parse（栈平衡，可重入）。
- **代码布局**：俄罗斯方块控制流（game_start/game_loop/game_over/game_exit）在 .org 0x100 段（0x160-0x170），子程序（input_handle/spawn/render/check_cell/set_cell/transform/move/drop_piece/drop_check/clear_lines）在 .org 0x940 段（0x940-0xCBD），菜单/命令区在 .org 0x540 段。真实程序 0x000-0xCBD（**3260 词**）。
- **菜单**：`--- MAIN MENU ---  1. CREDITS  2. STATUS  3. GAME  0. MENU`。status 保留 RAM bar。

## 2. 数据区（0xB000 初始化 RAM）

- **硬件**：新增外设 `ram_sec_init.v`（peripherals/，4KB RAM），`$readmemh(".../data.hex")` 初始化，挂 0xB000 段（ram_top 用 ram_sec_init 替换原 ram_sec_4）。
- **软件**：程序文本/长字符串从 ROM 内联移到数据区，程序用 **LIND** 读（`[r1:r2]=0xB000+偏移`）逐字节打印。
- **收益**：程序 ROM 只放指令，文本不再占取指空间（`.puts` 内联每字符 3 词 → 数据区每字节 1 词 + LIND 循环）。

## 3. hex 分离 2 个（归档规范更新）

- **ins_rom.hex**：程序 0x000-0xFFF（词，readmemh 加范围 0-4095）。
- **data.hex**：数据区 0-4095 字节（8 位值 %02X，ram_sec_init 载入到 0xB000）。
- **asm.py**：`write_hex` 只写程序词、`write_data_hex` 输出数据字节；同一汇编命令同时产出两个 hex。**归档规范从此为 hex = 2 个**。

## 4. shell 菜单 v3.0（credits/status/game）

- 主菜单精简为 3 项：**1. CREDITS  2. STATUS  3. GAME  0. MENU**。
- **credits**（替代 version）：`--- CREDITS ---` + `system: RTOS` + `Author: Justin (hardware) & Agent (software)` + `HW: Justin Green MCU (Zynq 7010)`。**设计原则：credits 不出现版本号一类每次改版都要改的东西**（版本号随版本演进自动失去意义）。

## 5. 上板实测 bug 修复（2026-08-20）

| # | 症状 | 根因 | 修法 |
|---|------|------|------|
| 1 | 按 0 显示主菜单但游戏无法终止 | `input_handle` 用 `RJAL game_exit` **嵌套调用**：game_exit 打菜单后 JALR 弹回 input_handle → 再弹回 game_loop 继续循环（菜单显示了但游戏还占着 task0） | 按 0 改为**设 G_OVER=1**；game_loop 在 `input_handle` 后**立即查 G_OVER**（放在 PAUSED 检查之前，暂停中也能退）→ 走 game_over → game_exit 清 GAME_ACTIVE/MENU → 打菜单 → JALR 弹栈回 shell_parse（栈平衡，可重入） |
| 2 | **偶发**一行消不掉、方块部分丢失 | `sched_body` 入口 `LBU r13, GAME_ACTIVE` 把**游戏 r13** 覆盖成 GAME_ACTIVE 值，`__sg_game` 保存/恢复的 r13 已是脏值 → 游戏 r13 每次 timer 中断后变 0/1。游戏 r13 是 **set_cell 的 FIELD 基址、rotate 的 new_rot** → 方块写错地址（丢失）、旋转错位 → 行填不满消不掉。**偶发**因中断时刻随机 | GAME_ACTIVE 检测改用 **r15**（游戏核心段 561-1397 行确认不用 r14/r15；r12/r13 由 `__sg_game` 正确保存恢复） |

> **调度器寄存器约定**（GAME 模式）：sched_body 入口只能碰游戏不用的寄存器（r15）；游戏核心段用 r1-r13，其中 r12（check_candidate 计数）/r13（set_cell 基址、rotate new_rot）由 `__sg_game` 保存/恢复；r14 备用。

## 6. 资源用量

| 资源 | 用量 |
|------|------|
| ROM 程序区 | 3260 词（0x000-0xCBD） |
| 数据区 | 295 字节 / 4096（data.hex） |
| 总 ROM 内容 | ~3260 词 / 4096（程序）+ 295B（数据） |

## 7. 仿真验证（2026-08-20）

- **shell_game_tb**（temp_shell_tb/）：boot 主菜单 → '3' 进游戏（GAME_ACTIVE=1，渲染 `@...####...@`）→ '4'/'6'/'5' 移动旋转正常 → **按 '0' 退出（GAME_ACTIVE=0、G_OVER=1、回主菜单）** → 再进（GAME_ACTIVE=1 可重入）→ 再退。全通过。
- 俄罗斯方块移动/旋转/下落/暂停/快落仿真路径此前已验证（v3.0 集成时）。

## 8. 上板实测

- **稳定**（用户确认）。俄罗斯方块游玩 + 按 0 退出/重入 + shell 菜单导航 + credits 显示均正常；偶发消行/丢块问题修复后未再出现。

## 9. 已知限制 / 后续

| 项 | 说明 |
|----|------|
| 数据区外置 | 文本改动只需重汇编 + 重灌两个 hex；数据区 4096 字节上限 |
| 快落中按 0 | 快落是忙循环，按键需快落结束后才处理（设计限制） |
| credits 无版本号 | 版本信息不显示在 credits（避免每次改版动 shell） |
| GAME 模式寄存器 | 调度器/游戏寄存器约定见 §5 表格；改动游戏核心时勿用 r15 |

---

*本文档随项目演进同步更新。*
