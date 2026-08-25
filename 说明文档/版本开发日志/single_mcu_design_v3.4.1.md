# MCU 设计记录（v3.4.1 —— 俄罗斯方块 game over 修复 / Dhrystone 风格 MIPS 基准 / status 界面 / 开机动画恢复）

> 版本：2026-08-25。**v3.4.1 是软件+固件版**：在 v3.4.0（RTL 时序优化 / 66.67MHz）基础上，修复俄罗斯方块触顶乱码、重写 MIPS 基准为 Dhrystone 风格混合负载、status 界面加 UPTIME/删 TASKS/MIPS 变选项、恢复开机打字机动画。**指令集 34 条不变**；唯一 RTL 改动：**timer.v 读路径时序→组合**（CPU LBU 才能读到正确计数，MIPS 计时前提）。
> 指令集速查见 `指令集说明/mc_v3.4.1_ins.md`（ISA 编码不变，重命名一份）。

## 0. 版本说明

| 维度 | v3.4.0 | v3.4.1（当前） |
|------|--------|----------------|
| RTL | rpu 时序中继 + flush 分离，66.67MHz | **同 v3.4.0** + timer.v 读改组合 |
| 俄罗斯方块 | 触顶乱码（check_cell 顶上方误判 free） | **修复**：row≥0x80 判 blocked + game_over wait_dma + 首行换行 |
| MIPS 基准 | 无（status 显示 RAM 进度条） | **Dhrystone 风格**混合负载，K≈72.8M，MIPS≈34(50MHz) |
| status 界面 | " TASKS: 3" + RAM 进度条 | **UPTIME 已运行时长 + MIPS 选项 + 删 TASKS** |
| 开机动画 | 打字机 + 加载条 | **恢复原速**（之前 sim 测试临时值调太快） |
| ISA | 34 条 | **不变** |

## 1. 俄罗斯方块 game over 修复（v3.4.1）

**① check_cell 顶上方判定**（根因）：
- 原：`RBLTU r6, r3, __ce_free`（0x80 < row → free）。触顶时新块 cell 落在 row-1（0xFF），0x80 < 0xFF → 误判 **free** → 游戏不判失败，继续把塞不下的块放进去（越界 cell 被 set_cell 静默丢弃）→ 场地越堆越乱 = "爆炸/字母"视觉 + "触顶还在刷新"。
- 修复：`RBLTU r6, r3, __ce_blocked`（row≥0x80 含 0xFF=-1 一律 **blocked**）→ 触顶正确判 game over。
- 聚焦测试 `test_gameover.asm` 验证：row-1 用例从 free(0) → blocked(1)。

**② game_over 切菜单前等 DMA**：
- 根因：失败时最后一帧 DMA（319 字节 ≈ 28ms）还在串口流，CPU 立刻切 game_menu 用 putc 写 UART → 菜单字节与 DMA 帧字节**交错** = 棋盘里散落 G/A/M/E 等字母。
- 修复：`game_over:` 入口加 `RJAL wait_dma`（等 cnt==0 再切菜单）。
- 上板验证：爆炸效果消失，失败后干净切到 GAME MENU。

**③ render 首行换行**：棋盘第一行前加 `RJAL fput_crlf`（每帧空一行，与扫雷一致）。

## 2. MIPS 基准（Dhrystone 风格，v3.4.1）

- **为什么仿 Dhrystone**：标准基准（Dhrystone/CoreMark）需 C 编译器 + 32/64 位通用寄存器，本 CPU（8 位寄存器、词寻址、自制 ISA）无编译器，故**同构复刻负载结构**。
- **混合负载**（每迭代 32 条 = 22 循环体 + 10 函数体）：
  - 记录 RMW（DH_REC0）、字符字段写（DH_REC1）、数组 RMW（DH_ARR0）
  - 函数调用 `dh_func`：`(a<<1)+(b>>1)-(a&0x0F)+b+1`
  - 混合 ALU（SLL/AND/XOR/ADD）、等长条件分支（RBLTU）
- **计时**：中断全关、timer 周期最大（防回绕）、S/E 读 timer → 全寄存器（无 RAM 回读，规避 LBU→ALU 时序边界）。
- **公式**：K = 32×255×255×35 ≈ 72.8M；MIPS = K×50/elapsed = 50×IPC；分子 N = K×50>>16 = **0xD90A**（50MHz 参考归一化）。
- **结果**：sim 实测 IPC ≈ 0.68 → MIPS ≈ **34**（50MHz）/ **45**（66.67MHz）。
- 详细见 `tools/mips_bench.md`（已随 v3.4.1 同步；若归档后目录变动可补）。

## 3. status 界面（v3.4.1）

- 删 " TASKS: 3" 栏。
- **UPTIME 已运行时长**：调度器新增 `uptime_tick` 子程序（__pick 与 __sg_game 均调用，只用 r12），TICK++ 同时累计秒计数（5000 tick = 1s），32 位 UPTIME_S 存 RAM 0x9134-0x9137；status 显示 `UPTIME: Xm Ys`（`print_dec` 3 位十进制，固定不刷屏）。
- **MIPS 变选项**：cmd_status 显示 `1. MIPS BENCH`；__sp_status 分派 `'1'` → 跑基准 → 重显 status；`'0'` → 回主菜单。不再点进 status 就自动跑。

## 4. 开机动画恢复（v3.4.1）

- 原因：此前为 sim 测试把 `putc` 打字机外层设为 4、`anim_bar` 延迟调成 0x01/0x20/0x20，导致开机动画瞬间刷完。
- 恢复：`putc` 外层 **32**（~0.6ms/字符）、`anim_bar` **0x06/0xFF/0xFF**（~30ms/段）。sim 实测字符间隔 ~41K 周期。

## 5. RTL 改动清单（v3.4.1）

| 文件 | 改动 |
|------|------|
| `peripherals/timer.v` | 读路径 `bus_data_out <= cnt[]`（posedge 时序）→ `bus_data_out = cnt[]`（组合）；CPU LBU 才能读到正确计数。**ISA 不变** |

> 其余改动全在软件层（`tools/rtos_shell_game_mpu.asm`）：俄罗斯方块修复、MIPS 基准、status 界面、uptime_tick、开机动画参数。

## 6. 固件文件说明（v3.4.1 起双文件）

| 文件 | 内容 | 加载 |
|------|------|------|
| `ins_rom.hex` | 指令 ROM（代码） | `ins_rom.v` `$readmemh` |
| `data.hex` | .puts 字符串（RAM_3 @0xA000） | `ram_sec_init.v` `$readmemh` |

> 归档/烧录需**两份同步**。本次排查曾因只更新 ins_rom.hex 导致 status 字符串错位（"TASKS:" 残留）——字符串在 data.hex 而非 ins_rom.hex。

## 7. 调试记录（v3.4.1）

- **俄罗斯方块爆炸**：聚焦提取 check_cell（row-1 判 free）→ 修复；game over 交错 → 总线写探针确认 DMA 帧 + putc 菜单字节交错 → wait_dma 修复。
- **MIPS 计时错位**：timer 读时序化（晚 1 拍）→ 聚焦测试（读两遍 CNT 验证）+ timer.v 改组合；elapsed 减法曾因 RAM 回读错位 → 改全寄存器。
- **LBU 转发**：曾误判"2 拍间隔转发洞"（测试 SLTU 在死循环后未执行）→ 修正测试后确认 LBU→ALU 转发正常（rd_last1/rd_last2）。
