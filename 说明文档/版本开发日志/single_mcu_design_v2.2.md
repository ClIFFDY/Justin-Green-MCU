# MCU 设计记录（v2.2 —— irq 冲刷收敛取指级 + irq_en 授权门控 + IRET W+2 语义 + 抢占断点修正 + RTOS 内核）

> 版本：2026-08-18（v2.1 归档后，配合 RTOS 控制台程序 rtos_diag_uart 定版，**上板实测通过、功能全通**）。在 v2.1（中断栈/嵌套 + SBI + 向量迁移）基础上**针对中断时序的修正版**，非架构重构：流水线/编码/地址空间/指令集骨架全部不变。
> 指令与外设速查见 `指令集说明/mc_v2.2_ins.md`；本日志只记设计、时序与调试。
> 核心变化（2026-08-18，共改 core 内 6 个文件：decoder/if_reg/ins_rom/irq_controller/single_cpu_top/fsm）：
> ① **irq_flush 只冲刷取指级**：ins_rom/if_reg 受 irq_flush 冲刷；decoder 不再（`flush1 = irq_flush` → `flush1 = 1'b0`）；id_reg/wr_reg 永不因 IRQ 冲刷 → **被中断指令的写回不丢失**（v2.1 及更早会丢写）；
> ② **irq_en 授权门控**（替换 v2.1 的 `bytmov==0`）：decoder 对全部 9 条控制转移（LJAL/RJAL/LBEQ/RBEQ/LBNE/RBNE/LBLTU/RBLTU/JALR）输出 `irq_en=0`，if_reg 对 cstall 拆包前半拍输出 `irq_en=0`；irq_controller 仅在 `irq_en == 2'b11`（两个源同时放行）才接受中断 → **中断只在干净的顺序指令（授权点）处派发**；
> ③ **IRET W+2 语义定版**：派发沿保存 `pc=W+2`，IRET 回 W+2；派发点（decoder 正在执行的 W）之后的 W+1 指令会被跳过 → RTOS 程序用 `LBNE r0,r0,__jpadN`（自跳 1 词、永不取、irq_en=0）垫在每条控制转移之前，保证被跳过的 W+1 恒为无害垫层；
> ④ **抢占断点修正**：IRQ 态被更高优先级抢占时保存 `pc_addr[j] <= pc_addr_in - 1`（v2.1 为 `pc_addr_in`）→ 内层 IRET 回 W+1，**嵌套时 ISR 指令不被跳过**（ISR 主体是授权点，无垫层也能保证不丢指令）；
> ⑤ fsm 复位收敛：`initial stage = 2'b01`（EXE），消除复位沿到来前的 X 态。
> ⑥ **新增 RTOS 内核程序 rtos_diag_uart**（协作式微内核 + CLI shell）：SysTick 1ms 滴答 + UART 控制台 + 锁存式 RX 中断 + 协作式命令派发，见 §6。

## 0. 版本说明

| 维度 | MCU v2.1 | MCU v2.2（当前） |
|------|----------|------------------|
| 取指/流水线 | 词寻址 32bit + ins_rom→if_reg→decoder | **相同** |
| 压缩/打包/cstall | flag 压缩 + 自动打包 + cstall 冻结 pc | **相同** |
| 指令集 | 32 真实 + 1 伪（含 SBI） | **相同**（v2.2 无新指令） |
| 中断冲刷 | irq_flush → decoder flush1 → 全流水线冲刷 | **只冲刷取指级**（ins_rom/if_reg），decoder 不动，id_reg/wr_reg 不冲刷 |
| 中断授权 | `bytmov == 0`（未取分支为授权点） | **irq_en == 2'b11**（decoder+if_reg 双放行；控制转移/cstall 前半拍强制屏蔽） |
| IRET 恢复 | 回派发沿保存的 pc（W+2） | **回 W+2 定版 + 程序 __jpad 垫层**（W+1 跳过无害化） |
| 抢占断点 | `pc_addr[j] <= pc_addr_in`（与 IDLE 相同） | **`pc_addr_in - 1`**（内层 IRET 回 W+1，ISR 不丢指令） |
| 被中断指令写回 | 随冲刷可能丢失 | **写回不丢失**（id_reg/wr_reg 不冲刷） |
| fsm 复位 | `stage` 复位沿前为 X | **`initial stage = 2'b01` 收敛** |
| 系统程序 | board_test / rtos 命令行式 | **RTOS 内核 rtos_diag_uart**（协作式微内核 + CLI shell，SysTick 1ms 滴答） |
| 上板实测 | 逐版本验证 | **2026-08-18 上板实测通过、功能全通** |

## 1. irq_flush 只冲刷取指级（本版核心修正，decoder/if_reg/ins_rom）

### 1.1 v2.1 的问题：中断冲刷全流水线，被中断指令的写回丢失

- v2.1 中 `flush1 = irq_flush`：中断被接受时，irq_flush 拉高，decoder 把 flush1 传给 if_reg/id_reg/wr_reg，**整条流水线被 NOP 冲刷**。
- 后果：中断恰好落在**带写回指令**（ALU/LBU）的译码/执行窗口时，该指令已译码但写回尚未到 wr_reg，冲刷把 id_reg/wr_reg 的清空——**这条指令白执行，结果丢失**。

### 1.2 修复：冲刷范围收敛到取指级

- `decoder.v`：`flush1 = irq_flush` → **`flush1 = 1'b0`**（IRQ 不再经 decoder 传冲刷）；仅分支/跳转/IRET 自身取用 flush1。
- `ins_rom.v` / `if_reg.v`：新增 `flush_irq` 输入，`if (rst || flush1 || flush_irq) inst_raw <= {NOP, 26'b0}`——irq_flush 直接冲刷取指两拍（ins_rom 输出 + if_reg 输出）。
- 效果：**被中断指令正常走完 id_reg→wr_reg 写回，数据不丢**；取指段两条在途指令（W+1、W+2）被 NOP 替换。
- **if_reg 复位/冲刷后普通路径必须恢复 `irq_en<=1`**：只把冲刷路径改 `irq_en<=0`、普通路径不补 `irq_en<=1` 会导致第一次冲刷后 irq_en 卡死 0、所有指令不可授权、派发永不触发（调试中出现过"进菜单没问题但操作没反应"，正是此半成品状态）。补全普通路径后（真实指令 irq_en=1、幻影 NOP irq_en=0）派发只在真实指令上发生。

## 2. irq_en 授权门控（替换 bytmov==0，decoder/if_reg/irq_controller）

### 2.1 动机

- v2.1 用 `bytmov == 0` 作为"当前不是跳转"的代理判断。但 bytmov 只对**取用分支偏移的指令**有区分度：未取分支时 bytmov 保持 0 → 仍被当作授权点；cstall 拆包期间的取指状态也无法用 bytmov 表达。
- 需要一个**明确的、逐指令/逐拍的授权信号**。

### 2.2 两个 irq_en 源

| 源 | 输出 | 置 0 条件 |
|----|------|-----------|
| decoder | `irq_en[1]`（默认 1） | **9 条控制转移**：LJAL/RJAL/LBEQ/RBEQ/LBNE/RBNE/LBLTU/RBLTU/JALR |
| if_reg | `irq_en[0]`（默认 1） | **cstall 拆包前半拍**（输出词[31:16]那条指令时）；后半拍（cstalled 输出词[15:0]）恢复 1 |

- 接线（single_cpu_top.v）：`if_reg → irq_en[0]`，`decoder → irq_en[1]`，合并 `irq_en[1:0]` 送 irq_controller。
- irq_controller 接受条件：`irq_addr_in != 0 && irq_en == 2'b11`（两个源同时放行）才派发/抢占。

### 2.3 语义：中断只在"授权点"派发

- **授权点 = irq_en==2'b11 的指令**：顺序指令（ALU/LBU/SB/SBI/NOP/IRET）且非 cstall 前半拍。
- 控制转移**无论取与不取**都屏蔽中断（v2.1 只屏蔽取中的），避免派发点落在跳转语义的半程。
- cstall 前半拍屏蔽、后半拍放行：前半拍 pc 被冻结、拆包状态机在途，中断会破坏 cstall 状态；后半拍第二半指令已稳定输出，可安全派发。

## 3. IRET W+2 语义与 __jpad 垫层（v2.2 定版，配合 RTOS 程序）

### 3.1 语义（probe_w2_loop 逐拍验证）

- 派发沿（IDLE 接受中断）保存 `pc_addr[j] <= pc_addr_in`；此时 `pc = W+2`（W = decoder 正在执行的指令），即**保存 W+2**。
- 取指级冲刷使 W+1、W+2 两条在途指令被丢弃；IRET 回 **W+2** → 重新取指执行。
- 净效果：**被中断指令 W 执行完（写回不丢），W+1 被跳过，W+2 起恢复**。

### 3.2 程序约定：__jpad 垫层

- 若 W+1 恰好是**控制转移**，跳过它 = 该跳转失效 → 控制流断裂。
- 对策（rtos_diag_uart.asm 统一约定）：**每条会被"派发点后的 W+1 被跳过"破坏的指令之前**垫一行 `LBNE r0,r0,__jpadN`：
  - 自跳 1 词（向后 1 词到自身），`r0 != r0` 恒假 → **永不取**；
  - LBNE 属控制转移 → `irq_en=0`，irq_controller 在此期间不派发；
  - 于是被跳过的 W+1 槽位恒为无害垫层，真实指令/真实跳转永远不在派发点后的 W+1。
- 代码形态（getc_wait 段）：
  ```
  getc_wait:
      LBU   r1, RX_BUF           # 授权点（irq_en=1）：字节到→派发→ISR 弹 FIFO 入 RX_BUF
      LBNE  r0, r0, __jpad5b     # 垫层（irq_en=0）
  __jpad5b:
      LBEQ  r1, r0, getc_wait    # 真实控制转移（irq_en=0），永不在 W+1 被跳过
  ```

### 3.3 拆双授权：相邻两条授权指令必须拆开（本程序的关键时序约定）

- 垫层不仅保护控制转移。**两条相邻的普通指令（都是授权点）同样危险**：中断在第一条（W）派发时，第二条（W+1）被跳过 → 第二条指令白执行，其副作用（写寄存器/SB 外设）丢失。
- 全程序按此规则在**几乎每两条相邻普通指令之间**插入垫层（`__jpadN`，共 **258 处**，编号 `__jpad0…__jpad243` + 字母后缀变体），例子：
  ```
  delay:     LBU  r5, TICK_LO
             LBNE r0, r0, __jpad9    # 拆 LBU+ADD：相邻吞 ADD → 目标低字节错
  __jpad9:   ADD  r5, r5, r1
  app_led:   LBU  r2, CMD
             LBNE r0, r0, __jpad27b  # 拆 LBU+ADDI：相邻吞 ADDI → 命令比较错
  __jpad27b: ADDI r3, r0, '0'
  app_led:   XORI r2, r2, 0x40
             LBNE r0, r0, __jpad30c  # 拆 XORI+SB：相邻吞 SB GPIO → 写丢
  __jpad30c: SB   r2, GPIO
             LBNE r0, r0, __jpad30d  # 拆 SB+SB：相邻吞 SB LED_STATE → 记录丢
  __jpad30d: SB   r2, LED_STATE
  delay:     NOP
             LBNE r0, r0, __jpad11   # 拆 NOP+LBU：相邻吞 LBU → r2 不更新 → 死循环
  __jpad11:  LBU  r2, TICK_LO
  ```
- 判断标准：**凡"被派发点跳过就坏"的指令，其左侧必须有垫层**（把该指令置于派发点的 W+2 及更远）；控制转移天然 irq_en=0 可作垫层使用。

### 3.4 验证（probe_w2_loop_tb，W+2 模型）

- 程序 probe_w2_loop.hex：0x000/0x001 ADDI 循环体，0x002 LBEQ 回跳，0x003 未用。
- **Phase A（词0 解码时中断）**：pc=0x002 派发 → 保存 0x002 → IRET 落 0x002=LBEQ → 回环，40 拍内 pc 多次经过 0x002，循环存活（W+1=词1 被跳过，无害）。
- **Phase B（词1 解码时中断）**：pc=0x003 派发 → 保存 0x003 → IRET 落 0x003=未用区 → HALT，循环穿出（证明 W+1=词2 LBEQ 确被跳过 → 无垫层则控制流断裂）。
- 结论：W+2 语义与"W+1 跳过"实证；__jpad 垫层是必要的程序侧配套。

## 4. 抢占断点修正（irq_controller.v）

- **改动**：IRQ 态被更高优先级抢占时 `pc_addr[j] <= pc_addr_in - 1`（v2.1 为 `pc_addr_in`）。
- **为什么**：ISR 主体（SB/LBU/ADDI）是授权点，随时可被抢占。若仍保存 pc=W+2、内层 IRET 回 W+2，则**外层 ISR 的 W+1 指令被跳过**——ISR 程序若未按 __jpad 全覆盖垫层（只有 IRET 前垫了），就会丢一条 ISR 指令。
- **修正后**：抢占保存 `pc-1 = W+1`，内层 IRET 回 W+1 → 重新取指执行，**外层 ISR 指令不丢**。
- **保持不变的 IDLE 派发**：仍保存 `pc_addr_in = W+2`（配合程序 __jpad 垫层）。两处刻意不对称：
  - IDLE 派发：W+1 跳过，靠 __jpad 垫层兜底（改掉需删光全程序 __jpad，代价大）；
  - IRQ 抢占：W+1 保留，ISR 指令不受损（正确性优先）。

## 5. fsm 复位收敛

- `fsm.v` 新增 `initial stage = 2'b01;`（EXE）。`always @(posedge clk or posedge rst)` 里 rst 分支本就是 `stage <= EXE`，但复位沿到来前的 X 态会导致 rst_buf 长复位期间 if_reg 的 `stage==2'b01` 判等不确定；initial 在仿真 0 时刻就把 stage 收敛到 EXE。

## 6. RTOS 内核 rtos_diag_uart（本版系统程序，重点）

> 程序：`tools/rtos_diag_uart.asm`（1270 行，汇编为 `tools/rtos_diag_uart.hex`，工作区 ins_rom.hex 与其字节一致）。
> 硬件前提：v2.2 中断时序（§1-§5）+ ISR 向量 TIMER=0x248、UART=0x260 + UART 硬件 FIFO(64) + 50MHz / 115200 baud（1 bit = 434 拍）。

### 6.1 架构总览：协作式微内核 + CLI shell

- **协作式（非抢占）微内核**：无任务切换/调度器。命令经 RJAL 派发为**前台任务**（hello / led），任务内循环、任务结束返回 shell；SysTick 与 UART 中断作为**后台中断服务**穿插在任意授权点。
- 内核 = 三块：**SysTick 定时**（1ms 滴答，16 位 k_tick）+ **UART 控制台**（putc/getc/flush）+ **协作式命令派发**（shell）。
- 交互模型：boot 打印 5 条 init → 程序目录 → `cmd> ` 单字符命令 → 回显 + 派发。

### 6.2 内存布局（ROM 词寻址 / RAM seg1）

| 区 | 地址 | 内容 |
|----|------|------|
| reset | 0x000 | 外设配置（GPIO UART 引脚→timer→LED）→ 逐外设 init 打印 → flush → shell |
| kernel | 0x01D-0x022 | putc（轮询 tx_busy → SB UART） |
| | 0x023-0x02B | getc（轮询锁存 RX_BUF，取走并清） |
| | 0x02C-0x034 | flush（弹空 FIFO 残留字节） |
| | 0x04x | delay（16 位精确延时，读 k_tick） |
| shell/apps | 0x222 | shell（菜单 + 命令比较 + RJAL 派发） |
| ISR 向量 | 0x208/0x228/0x248/0x260 | GPIO2/GPIO1（防御 IRET）/ timer_isr / uart_isr |
| 打印子程序 | 0x280+ | 逐字符打印（ADDI 'c'+LJAL putc 套路，ROM 不可读故不用字符串表） |

RAM 单元（seg1 0x9000，全局长活状态一律 RAM）：

| 单元 | 地址 | 用途 |
|------|------|------|
| TICK_LO / TICK_HI | 0x9000 / 0x9001 | 16 位 k_tick（低/高字节） |
| ISR_S1 / ISR_S2 | 0x9002 / 0x9003 | **timer ISR 现场槽**（保存 r1/r2） |
| LED_STATE | 0x9004 | LED 当前状态（bit6） |
| CMD | 0x9005 | 命令字节暂存 |
| RX_BUF | 0x9006 | **UART 锁存槽**（RX 首字节） |
| UART_S1 / UART_S2 | 0x9007 / 0x9008 | **uart ISR 现场槽**（保存 r1/r2） |

### 6.3 SysTick：timer_isr @0x248（1ms 滴答）

- 定时器 reload **49999 = 0x0000C34F**（TIMER_CNT0=0x4F、CNT1=0xC3，CNT2/3=0）→ 周期 50000 拍 @50MHz = **1ms**；`TIMER_MODE=1`（irq_mode 电平锁存）。
- 16 位 k_tick：`TICK_LO` 自增，进位则 `TICK_HI` 自增（RBNE 判低字节非 0 无进位）。
- 现场保存/恢复：`SB r1,ISR_S1` → `SB r2,ISR_S2` → 计数 → 恢复 → `IRET`；先 `SB r0,TIMER_ACK` ack。
- 优先级 prio=1，可被 UART 中断（prio=2）嵌套。

### 6.4 UART 控制台：putc / getc / flush

- **putc**：`LBU r6, r255`（tx_busy）→ busy 回跳等待 → `SB r1, UART` 发送。
- **getc**：轮询锁存槽 `RX_BUF`，非 0 → `SB r0, RX_BUF` 清锁存并返回字节。**ISR 外绝不直读 FIFO**。
- **flush**：弹空 FIFO 残留字节（进 shell 前调用，丢弃复位残留）。

### 6.5 UART RX 中断 + 锁存语义：uart_isr @0x260

- **触发**：硬件 FIFO(64) 非空 → 电平型 RX 中断。
- **锁存语义（本版关键）**：`RX_BUF` 空才存入**第一个**收到的字节，FIFO 多字节时后续弹入一律丢弃。否则 getc 只能读到最后弹入的字节 → **命令首字符丢失**。
- 实现：`LBU r1, UART`（弹 FIFO 队首）→ `LBU r2, RX_BUF` → 锁存非空则跳过存入 → 恢复 r1/r2 → `IRET`。
- **独立现场槽**：UART prio2 可嵌 timer prio1，须用独立 UART_S1/S2（与 timer 的 ISR_S1/S2 不互踩）。
- **ISR 内无派发**：嵌套需新 prio > 当前 prio；RX=2/timer=1 均不满足（GPIO 未用）→ 直写安全。

### 6.6 shell：协作式命令派发

- 流程：`print_menu` → `cmd> `（print_prompt）→ `getc` 阻塞等首字节 → `SB r1,CMD` → 回显 → `flush`（丢弃 \r 等行内剩余）→ `put_crlf` → 比较 CMD：
  - `'1'` → **hello**：`Hello World!` + `t=` + k_tick 高/低字节十六进制（实时 tick）；
  - `'2'` → **led**：子循环任意键翻转 LED、`b` 闪烁 5 次（100ms 间隔 delay）、`0/q` 退出回菜单；
  - `'0'` → **refresh**：重打程序目录；
  - `'\r'` → 空输入重提示；
  - 其他 → **invalid**：`inv=` + CMD 十六进制（调试用）。
- 命令回环是**协作式**：任务内循环不派发新命令，任务结束 `JALR` 返回 shell。

### 6.7 __jpad 垫层与授权点布局（程序侧核心约定）

- 全程序 **258 处** `__jpadN`（`__jpad0…__jpad243` + 字母后缀），由 asm.py 汇编时按 `__jpadN:` 展开。
- 规则（见 §3.2/3.3）：**凡"被派发点后的 W+1 跳过就坏"的指令，其左侧必须有垫层**——控制转移前垫（防跳转失效）、相邻双授权普通指令间垫（拆双授权，防第二条白执行）。
- 结果：程序任何位置被中断，W+1 恒为无害垫层，恢复后控制流/数据一致。

### 6.8 寄存器与现场约定

- `r0=0`（恒零）；`r255=tx_busy`（只读）；`r1=参数/返回值`（跨调用可破坏）；`r2-r254=临时`（跨调用可破坏）。
- **跨调用长活状态一律 RAM 单元**（k_tick/LED_STATE/CMD/RX_BUF/ISR 现场槽），不用寄存器保存——中断可随时打乱寄存器。
- **ISR 现场槽按中断源分槽**：timer 用 ISR_S1/S2，uart 用 UART_S1/S2——支持 UART 嵌套 timer，不互踩。

## 7. 仿真验证（2026-08-18，iverilog v14）

### 7.1 UART 整机通路回归（rtos_uart_tb.v，rtos_diag_uart，SysTick 1ms 滴答运行中）

- **结果：17 通过 / 0 失败，ALL TESTS PASSED**。
- 覆盖：boot TX **131 字节逐字节比对**（5 条 init + 菜单 + `cmd> `）；RX 捕获（RX_CAP→RX_IRQ→派发 0x260）；ISR 弹 FIFO 入 RX_BUF；IRET 回 getc_wait；getc 轮询 CMD 落位；SysTick 定时派发 0x248 + IRET 正常返回；5 个命令回环：
  - `'1'` → `1\r\n\r\nHello World!\r\nt=0000\r\ncmd> `
  - `'x'` → `x\r\ninv=78\r\ncmd> `（未知命令）
  - `'\r'` → `\r\r\ncmd> `（空输入重提示）
  - `'2'` → `2\r\n\r\nLED: key=toggle b=blink 0=quit\r\n`（进子菜单）
  - `'0'` → `0\r\ncmd> `（退出子菜单，**不带**额外空行——命令分支行为，非 bug）

### 7.2 W+2 语义探针（probe_w2_loop_tb / probe_iret4）

- probe_w2_loop：Phase A 安全回环、Phase B 穿出停机（§3.4），证明 W+2 恢复语义。
- probe_iret4：保存 pc=0x026/0x027/0x028（幻影 pc→cstall 冻结 pc 修复回归）。

### 7.3 RX 探针（rx_probe_tb，if_reg 修复补全回归）

- 逐拍记录 boot→菜单→getc 等待；cyc=250000 注入按键 '1'，验证 RX 派发沿→uart_isr→IRET→getc 返回链路；SysTick 定时派发 0x248 与 IRET 也逐拍可见。**无残留字节**（首次注入即被锁存）。

### 7.4 调试中发现并修复的回归

- **asm 定时器重装值回归**：rtos_diag_uart.asm 一度把 TIMER_CNT0/CNT1 写成 0（定时器 OFF），与工作区 ins_rom.hex（0x4F/0xC3 = 1ms）不一致 → 已改回 49999，重新汇编后与板上 hex 字节一致。
- **if_reg 半成品修复**：冲刷路径 `irq_en<=0` 已改、普通路径 `irq_en<=1` 未补 → irq_en 卡死 0 无派发（"进菜单没反应"）→ 补全后修复。

### 7.5 TB 工具链注意（iverilog v14 两坑）

- **string 字面量 `\r` 被存成 0x72（字符 'r'）而非 0x0D**：期望串一律写 `\x0D`；且 string 不能作 task 输入端口（用模块级 string + task 读取）。
- 详见记忆 `iverilog-string-cr-bug`；TB 模板见 `rtos-uart-tb-pattern`。

## 8. 已知限制 / 后续

| 项 | 说明 |
|----|------|
| W+1 跳过（IDLE 派发） | 派发点后的 W+1 指令恒被跳过；程序必须用 __jpad 垫层（rtos_diag_uart 已 258 处全覆盖） |
| 拆双授权成本 | 相邻普通指令必须插垫层 → 代码密度下降（约一半指令是垫层）；换更优语义可省但需动 RTL |
| 抢占与 IDLE 不对称 | IDLE 保存 W+2、抢占保存 W+1，语义不同，改任一侧需同步程序垫层策略 |
| IRET 非 irq_en 屏蔽 | IRET 本身 irq_en=1，理论上可在 IRET 译码窗口被抢占（当前程序 IRET 前有 __jpad，实际不触达） |
| bytmov=0 目标不可编码 | 沿用（`target=W+2` 不可编码，向前最少 2 词） |
| 中断栈深度 | pc_addr 8 深、门限 `j≤15` 沿用 v2.1 |
| irq_vex 兜底 | `irq_vex[4..15]=168` 沿用 v2.1 |
| RTOS 是协作式 | 单前台任务、无任务切换/调度器、命令非抢占；SysTick/UART 仅作中断服务穿插 |
| getc 阻塞语义 | getc 阻塞轮询 RX_BUF，锁存只保首字节 → 连续快速按键中间字符会被锁存语义丢弃（单命令交互可接受） |
| 上板板测 | **2026-08-18 上板实测通过、程序稳定、功能全通**（此前"操作没反应"为 if_reg 半成品修复，已闭环） |

---

*本文件随项目演进同步更新。*
