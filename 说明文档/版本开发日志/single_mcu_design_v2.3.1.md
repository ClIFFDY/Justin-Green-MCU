# MCU 设计记录（v2.3.1 —— 系统层：菜单式 shell UI 升级）

> 版本：2026-08-19（v2.3 归档后）。**版本号第三位 = 系统层（软件）变动**：硬件/ISA/中断语义与 v2.3 完全一致（core 无改动，RTL 4 文件仍是 v2.3 状态），仅系统程序 `rtos_shell.asm` 大改 + 汇编器 `asm.py` 增强。
> 指令集速查见 `指令集说明/mc_v2.3.1_ins.md`（本版无 ISA 改动，opcode 表同 v2.3）。
> 内核/硬件（v2.3 不变部分）速查：irq 读路径（LBU 0x5000/0x5001 读 slot0）、IRQ_W else-if 写在前、regs[254]=j 调用栈分区、寄存器分块 + 共享子程序 r7-r11、抢占调度器（timer 5kHz）——均见 v2.3 设计记录，本节不复述。
> 核心变化（2026-08-19）：
> ① **菜单式 shell**：主菜单 + 可进入/回退子菜单（倒计时/LED），界面全英文（用户要求），菜单每项一行；
> ② **信息视图（MENU=3）**：version/status/init 打印内容 + `0. BACK TO MENU` + 提示符 `0> `，**视图只认 0 返回 → 天然屏蔽主菜单指令**；未知字符重显当前页（VIEW_TYPE）；
> ③ **RAM 用量 `#` 进度条**（print_bar 子程序）在 status 显示；
> ④ **倒计时**（CD 秒s [###] 进度 → [FLASH 5s] 频闪 → DONE）+ **LED 翻转/闪烁/频闪**（tick 驱动）；
> ⑤ **汇编器增强**（asm.py）：`.puts "..."` 宏、**自动补 jpad**（IRET W+2 垫层硬限制）、注释剥离修引号（`'#'`）、UTF-8 中文编码（工具能力，shell 不用中文）；
> ⑥ **修 1 个真 bug**：倒计时循环 `RJAL putc` 后 r8 被 tx_busy 轮询破坏 → 循环提前退出。

## 0. 版本说明

| 维度 | MCU v2.3 | MCU v2.3.1（当前） |
|------|----------|---------------------|
| 取指/流水线/指令集 | 词寻址 32bit + 压缩打包 + cstall | **相同**（无 ISA 改动） |
| 中断/irq 读/IRQ_W/regs[254] | v2.3 定版（读路径/写在前/调用栈分区） | **相同**（core 无改动） |
| 抢占调度器/寄存器分块/共享子程序 | v2.3 定版 | **相同** |
| 系统程序 | rtos_shell v1（help/cnt/led 命令行） | **rtos_shell 菜单式**（主菜单 + 子菜单 + 信息视图 + RAM bar + 倒计时/LED 功能） |
| 汇编器 | 死区 NOP / L-R 翻转 / 转义 | **+ .puts 宏 + 自动 jpad + 引号注释修复 + UTF-8** |
| 上板实测 | v2.3 全通 | **v2.3.1 待上板**（仿真全过） |

## 1. 菜单式 shell 架构（本轮核心）

### 1.1 导航模型（MENU 状态机）

| MENU | 页面 | 命令 | 提示符 |
|------|------|------|--------|
| 0 | 主菜单 | `1.init 2.count 3.led 4.version 5.status 0.menu`（+ 单词别名 help/init/led/ver/stat/cnt） | `> ` |
| 1 | 倒计时子菜单 | `1-9` 设秒数、`0` 返回 | `CD> ` |
| 2 | LED 子菜单 | `1` 翻转、`2` 闪烁、`0` 返回 | `LED> ` |
| 3 | 信息视图（version/status/init） | **只认 `0` 返回** | `0> ` |

- **屏蔽**：子菜单/视图只认本层命令 + `0`，主菜单指令（含单词别名）全被挡 → `?`。
- **未知字符重显**：`?` + 按 MENU/VIEW_TYPE 重显当前页（用户随时能看到 `0. BACK TO MENU`）。VIEW_TYPE@0x9127 记 0=init/1=version/2=status。
- **每个信息/子菜单页底部都有 `0. BACK TO MENU`**；LED 选模式后也补（TOGGLE OK / BLINK ON 后）。

### 1.2 主菜单/子菜单文本（全英文）

```
=== JUSTIN GREEN MCU ===
RTOS SHELL v2.3.1
MODULES: UART TIMER GPIO RAM OK

--- MAIN MENU ---
 1. INIT       BOOT INFO
 2. COUNTDOWN  COUNTDOWN
 3. LED        LED SETTINGS
 4. VERSION    VERSION
 5. STATUS     STATUS
 0. MENU       SHOW MENU
```

### 1.3 布局

- 0x000 核心区：boot + shell_loop（每轮调 tick_bookkeeping）+ 字符处理（ring 弹/回显/退格/CRLF/空闲超时），0x0C0 结束。
- 0x100 区：putc/put_crlf/print_hexdigit/print_hex + shell_parse（按 MENU 分派），0x1FE 结束。
- ISR 向量 0x208/0x228/0x248、uart_isr 0x260、shell_append 0x2A0、调度器 0x300、任务1 0x400、任务2 0x500（均 v2.3 原样）。
- **0x540+ 菜单/命令区**：menu_init/main/countdown/led、print_prompt（按 MENU 变提示符）、cmd_init/version/status/led_toggle/led_blink、print_bar、tick_bookkeeping、wait_ticks、cmd_countdown。程序 0x000–0xE97（3736 词）。
- 提示符按 MENU：`>`/`CD>`/`LED>`/`0>`。

## 2. 倒计时 + LED（tick 驱动，1s=5000 tick @0.2ms/格）

### 2.1 wait_ticks（阻塞等 tick，16 位累计）

- 阈值 WAIT_TH_LO/HI（16bit），CD_LAST + CD_ACC(16bit) 累计 TICK_LO 差值。
- **进位检测**：`SLTU r8, r1, r7`——`new_lo < diff ⟺ 旧值+diff ≥ 256 ⟺ 进位`（r1=CD_ACC_LO 累加后、r7=diff）。
- 阈值比较先比 hi 再比 lo。任务0 每 3 tick 才跑，须累加差值。

### 2.2 倒计时（cmd_countdown，阻塞）

- `CD Ns [` → 每秒 wait_ticks(5000) → `#` → N 个 `#` 后 `]\r\n` → `[FLASH 5s]`。
- 频闪：wait_ticks(1250=0.25s) × 20 次翻转 LED = 5s → LED 熄灭 → `DONE` → 回主菜单。
- **修的真 bug**：`__cd_sec_loop` 里 `RJAL putc` 打印 `#` 后，r8 被 putc 的 tx_busy 轮询（`ADDI r8,r255,0`）破坏 → `LBNE r8,r0,__cd_sec_loop` 提前退出（3 秒只出 1 个 #）。**修法：putc 后从 RAM 重载 CD_SEC 再判断**。教训：**r7-r11 跨 putc 调用不可残留，需从 RAM 重载**。

### 2.3 LED 翻转/闪烁/频闪

- `1. TOGGLE`：翻转一次（LED_STATE XOR 0x40）→ `TOGGLE OK` + `0. BACK TO MENU`，LED_MODE=0。
- `2. BLINK`：LED_MODE=1 → tick_bookkeeping 每 0.25s(1250 tick) 翻转 → `BLINK ON` + `0. BACK TO MENU`。
- 倒计时结束频闪：FLASH_CNT 计数翻转（独立于 blink 模式）。

## 3. RAM 用量 # 进度条（print_bar）

- status 显示 `RAM: [#...................] 2% (296B/16KB)`：20 段，fill=1（RAM_USED 296B/16KB≈2%，`max(1, 296*20/16384)=1`）。
- print_bar 入参 r7=填充段数、r8=总段数；**用 r17-r19（任务0 高区）存循环态（cnt/fill/width），r1/r2（低区）供分支比较**——分支寄存器只能 r0-r15，高区须拷贝到低区。

## 4. 汇编器增强（asm.py，v2.3.1）

1. **`.puts "text"` 伪指令**：展开为逐字符 `ADDI r7,r0,c + LBNE r0,r0,__putsN_i + __putsN_i: + LJAL putc`（每字符 3 词；ROM 数据不可 LBU 读回，字符串只能内联）。唯一标签计数器 `_PUTS_CTR`。
2. **自动补 jpad（IRET W+2 垫层硬限制）**：9 条控制转移前一条真实指令是顺序指令（授权点）时自动插 `LBNE r0,r0,<lab>`+`<lab>:`；前驱是控制转移（含 IRET/HALT）天然安全不插；源里手写 jpad 跳过（字节兼容既有程序）。**在旧 cmd_led 抓到 1 个真·潜伏 bug**（JALR 前缺垫层，中断会吞返回）。
3. **注释剥离修引号**：`#`/`//` 只在引号外作注释起点（`'#'` 字面量可用了）——`strip_comment` 跳过单双引号。
4. **UTF-8 中文**：parse_str 对非 ASCII 字符按 UTF-8 多字节编码（`.puts "开机信息"` → 12 字节；shell 全英文不用，工具能力保留）。
- 回归：三个既有程序（rtos_shell/preempt/diag_uart）各修 1 处真缺垫层后字节一致。

## 5. 仿真验证（temp_shell_tb/shell_tb.v + temp_cd_test/cd_tb.v）

- boot 横幅 + 主菜单 ✓；version 视图（Author: Justin (hardware) & Agent (software)）✓；视图内 `1` 被屏蔽出 `?` 并重显 ✓；`0` 返回主菜单 ✓。
- status + RAM bar ✓；LED 子菜单进入/blink/`0. BACK TO MENU`/返回 ✓；倒计时子菜单进入/未知字符 `x`→`?`+重显/返回 ✓。
- 快速连发 4\r5\r3\r 无卡死，RX 全消费（取模判断 `(WR-RD+8)&7==0`）✓。
- 倒计时缩时仿真（1s→50 tick、频闪→25 tick×4）：`CD 3s [###` 正好 3 个 # → `[FLASH 5s]` → `DONE` → 回主菜单，LED 6 次写 + 熄灭 ✓。
- **TB 教训**：中文/长菜单输出量大，uart_wr 捕获数组要 2048 深；WR/RD 判断要用取模（WR 会绕回）；`mem[0x44]` 无尺寸十六进制索引 iverilog 解析不了（用 `16'h44` 或十进制）。

## 6. 上板实测

- 待上板（仿真已覆盖全部命令路径；真实倒计时 5s+5s、blink 模式建议上板复验）。

## 7. 已知限制 / 后续

| 项 | 说明 |
|----|------|
| 倒计时阻塞 | cmd_countdown 阻塞期间不响应其他输入（5s+5s）；要可取消需改非阻塞状态机 |
| blink 与频闪 | 倒计时频闪会覆盖 blink 模式；结束后 LED 熄灭 |
| 行缓冲 8 字符 | 命令超 8 字符被截断（菜单单字符足够） |
| 视图只认 0 | 信息视图内其他键一律 `?`+重显（不含返回路径之外的操作） |
| 汇编器 `.puts` | 每字符 3 词，长文本占 ROM 多（当前 3736 词/4096）；后续可考虑 ROM 数据读路径（需 RTL） |

---

*本文档随项目演进同步更新。*
