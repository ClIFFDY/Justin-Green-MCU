# MCU 设计记录（v2.0 —— ROM 4096 字节 + ins_rom 同步读 BRAM + 指令 2–5B + 总线前 4 位映射 + data_ram 16KB）

> 版本：2026-08-16
> MCU 系列第 5 版（v1.3 见 `single_mcu_design_v1.3.md`；CPU 系列见 `single_cpu_design_v6.5.md`）。
> **指令与外设速查见 `指令集说明/mc_v2.0_ins.md`**；本日志只记设计、时序与调试。
> 核心变化：
> ① **ins_rom 扩到 4096 字节，PC 16 位**（v1.3 为 512 字节 / 9 位）；
> ② **ins_rom 合并 if_reg 变 BRAM 同步读**（取指不再经独立 if_reg 寄存，直接同步读 block RAM）；
> ③ **指令长度从 1–4B 改为 2–5B**（byte0 = `opcode[5:0]<<2 | len`，`len=字节数−2`）；
> ④ **跳转/分支扩到 5B，bytmov 12 位**（±4095，一跳贯通 4KB ROM）；
> ⑤ **总线地址映射改前 4 位**，外设地址全部重排（UART=0x2000 / TIMER=0x3000 / GPIO=0x4000）；
> ⑥ **data_ram 扩到 16KB**（4 个 `ram_sec`，占用 0x8000–0xBFFF 双总线地址）。

## 0. 版本说明

| 维度 | MCU v1.3（旧） | MCU v2.0（当前） |
|------|----------------|------------------|
| 指令空间 | 9 位，512 字节 | **16 位，4096 字节（0x000–0xFFF）** |
| 取指 | ins_rom（同步读）+ if_reg 寄存 | **ins_rom 合并 if_reg，BRAM 同步读** |
| 指令长度 | 1–4 字节 | **2–5 字节** |
| 跳转/分支 | 2B，bytmov 8 位（±255） | **5B，bytmov 12 位（±4095）** |
| opcode | 稀疏编号 | **连续编号**（byte0 = op<<2\|len） |
| 总线映射 | 前 3 位（UART=0x4000 等） | **前 4 位**（UART=0x2000 / TIMER=0x3000 / GPIO=0x4000） |
| data_ram | 4KB（1 个块） | **16KB（4 个 ram_sec，0x8000–0xBFFF）** |
| 调用栈 | 9 位 RA，深 255 | **16 位 RA，深 255**（随 PC 加宽） |
| ISR 向量 | 0x88 / 0xA8 / 0xC8 / 0xE0 | 不变 |
| 汇编器 | ROM_TOP=0x1FF | **ROM_TOP=0xFFF** |

## 1. ROM 4096 字节 & PC 16 位

- `ins_rom.v`：`addr [15:0]`，`mem [0:4095]`；`inst_raw [39:0] = {mem[addr..addr+4]}` 5 字节连续取指。
- `pc.v`：`pc_addr / ra [15:0]`，复位/自增/跳转全 16 位；`bytmov [15:0]`（有效 12 位，见 §4）。
- `reg_f.v` 调用栈：`rad [0:255]` 槽位 16 位（返回地址覆盖全 4KB ROM）。
- 程序区 0x000–0xFFF 全部可执行；`irq_controller.v` 断点/`irq_addr` 同步 16 位。

## 2. 取指同步化（ins_rom 合并 if_reg）

v1.3 的 `if_reg` 独立寄存取指结果，v2.0 并入 `ins_rom`：

```verilog
if (rst) inst_raw <= {NOP, 34'b0};
else if (stall) inst_raw <= inst_raw;
else begin
    if (stage == 2'b01 && !flush1 && !stall)
        inst_raw <= {mem[addr], mem[addr+1], mem[addr+2], mem[addr+3], mem[addr+4]};
    else
        inst_raw <= {NOP, 34'b0};
end
```

- 同步读：`stage==EXE` 且未冲刷时，每拍从 `pc_addr` 连续取 5 字节到 `inst_raw`；冲刷/非执行拍插 NOP。
- **`inst_num` 改为组合导出**（见 §8 调试记录，关键修复）：

```verilog
assign inst_num = mem[addr][1:0];   // byte0[1:0] = len = 字节数−2
```

  `pc` 推进 `pc_addr + inst_num + 2` 与取指必须同地址同拍可见——inst_num 若滞后一拍，5B 跳转会在指令首字节（而非末尾）执行跳转，偏移错 1 字节。

## 3. 指令编码（2–5 字节）

**byte0 = `opcode[5:0] << 2 | len[1:0]`，`len = 字节数 − 2`**（0–3）。长度由 byte0 低 2 位直接可判：

| 长度 | len | 类别 | 布局 |
|------|-----|------|------|
| 2B | 00 | 控制（HALT/NOP/IRET/JALR） | `byte0` `0x00` |
| 4B | 10 | ALU-R / ALU-I / LBU / SB | `byte0` `rd/rs` `rs1/addr高` `rs2/imm8/addr低` |
| 5B | 11 | 跳转（LJAL/RJAL）/ 分支（6 条） | `byte0` `bm[11:4]` `…` `{bm[3:0],4'b0}` |

- **opcode 连续编号**（`decoder.v` localparam）：HALT 00、ADDI 01、ADD 02、SUBI 03、SUB 04、AND 05、OR 06、XOR 07；LJAL 08、RJAL 09、ANDI 0A、ORI 0B、XORI 0C、SLL 0D、SRL 0E、SLLI 0F；SRLI 10、SLTU 11、SLTIU 12、JALR 13、NOP 14、IRET 15；LBEQ 16、RBEQ 17、LBNE 18、RBNE 19、LBLTU 1A、RBLTU 1B、LBU 1C、SB 1D。
- v1.3 的 ins_rom.hex **不能直接复用**（byte0 全变），须用新汇编器（`tools/asm.py`）重新生成。

## 4. 跳转/分支 5B & bytmov 12 位

- 跳转（LJAL/RJAL）：`byte0` `bm[11:4]` `0x00` `0x00` `{bm[3:0],4'b0}`；byte2/3 为 0。
- 分支（LBEQ 等 6 条）：`byte0` `bm[11:4]` `r1` `r2` `{bm[3:0],4'b0}`（RISC-V 风格：寄存器在前、绝对目标在后）。
- decoder 拼 `bytmov = {inst_raw[31:24], inst_raw[7:4]}`（byte1 高 8 位 + byte4 高 4 位），**12 位有效 ±4095**。
- **相对指令末尾**：R 前缀（前向）`bytmov = 目标 − (addr+len)`；L 前缀（后向）`bytmov = (addr+len) − 目标`。
- **时序前提**：pc 执行跳转时 `pc_addr` 必须已推进到当前指令末尾（见 §8#3），`pc_addr ± bytmov = target` 才成立。
- 覆盖极限：0x000 ↔ 0xFFF **一跳贯通**（±4095），不再需要 v1.3 的链条式中转。

## 5. 总线地址映射（前 4 位）与外设

| 区间 | 设备 | LBU（读） | SB（写） |
|------|------|-----------|----------|
| 0x0000–0x1FFF | 未定义 | 黑洞（0） | 黑洞（丢弃） |
| 0x2000–0x2FFF | UART | 弹 RX FIFO → rd | 触发 TX 发送 |
| 0x3000–0x3FFF | timer | 黑洞（0） | 重装/模式/ack |
| 0x4000–0x4FFF | GPIO | 读 IN 引脚 | 推挽输出 / 单 pin 模式 |
| 0x5000–0x7FFF | 未定义 | 黑洞 | 黑洞 |
| 0x8000–0xBFFF | data_ram | 读 RAM → rd | 写 RAM |
| 0xC000–0xFFFF | 未定义 | 黑洞 | 黑洞 |

- 解码在 `single_mcu_top.v` 的 `case (bus_addr_f[15:12])`：RAM_1–4（1000–1011）、UART（0010）、GPIO（0100）；**TIMER（0011）无读回分支 → default 黑洞**（已知限制，见 §10）。
- 外设寄存器地址、模式编码、中断向量等全部见 `指令集说明/mc_v2.0_ins.md` §2（UART 0x2000 / timer 0x3000–05 / GPIO 0x4000+ 奇偶地址 / data_ram 0x8000）。

## 6. data_ram 16KB（0x8000–0xBFFF）

- 4 个 `ram_sec`（每区 `mem[0:4095]` 4KB，BRAM），`ram_top` 按 `bus_addr_in[15:12] ∈ {1000..1011}` 识别 RAM 区。
- **选区 `sec[bus_addr_in[1:0]]`**（`ram_top.v` 组合逻辑），每区 `sec_addr_in = bus_addr_in[11:0]`。
- 总线访问 2 拍（`stall_bus = access && !done`，`done` 每拍翻转一次，一次 RAM 读写插 1 拍 stall）。
- **已知限制**：选区用地址**低 2 位**而非页高 2 位，`bus_addr[11:2]` 只有 10 位范围 → 有效寻址仅 4KB（4096 位置），16KB 声明未全部利用（见 §10）。

## 7. 汇编器 & 上板程序

- `tools/asm.py`：`ROM_TOP = 0xFFF`，支持 `.org/.equ/.byte/.str`；按 byte0=op<<2|len 编码；bytmov 自动算 12 位（越界报错换方向）；`write_hex` 写满 0x000–0xFFF。
- `tools/board_test.asm`（v2.0 布局）：

| 区间 | 内容 |
|------|------|
| 0x00–0x3B | 初始化（pin 模式、r2=1 回环开、timer 重装 0x0000FFFF + 使能） |
| 0x3C | RJAL 0x110 调 banner（一次） |
| 0x41–0x49 | 主循环（NOP NOP LBEQ 自旋等中断，授权点） |
| 0x88–0xA6 | GPIO2 ISR（KEY2 翻转 r2、去抖） |
| 0xA8–0xA9 | GPIO1 ISR 占位（IRET） |
| 0xC8–0xDC | Timer ISR（ack、r4==0 直接返回、r4--、LED 亮、IRET） |
| 0xE0–0xF7 | UART ISR（弹 FIFO、XORI 0x20、回环开关、回发） |
| 0x100–0x10E | send_char 子程序（轮询 tx_busy、发字节） |
| 0x110–0x174 | banner "cpu ready\r\n"（ADDI+LJAL send_char，11 次） |

- **banner 用 LJAL（后向）**：banner 0x110 > send_char 0x100，v2.0 后向跳转一段直达（12 位覆盖，无需 v1.3 链条）。

## 8. 调试记录（v2.0 修复项）

| # | 问题 | 修复 |
|---|------|------|
| 1 | **ins_rom 复位 `{NOP, 26'b0}` 只有 32 位**，赋给 40 位 `inst_raw` 零扩展后 `byte0 = 0x00` = HALT → frz=1 → fsm 进 IDLE；而 fsm 只有 `frz→IDLE`、**没有回 EXE 的路径**，PC 永停在 0x000 死锁（fast CPU 测试 pc=0000/frz=1） | 两处都改 `{NOP, 34'b0}`（40 位满宽，复位后 opcode=NOP、frz=0，stage 保持 EXE） |
| 2 | **`inst_num` 只在 else（冲刷/非执行）分支赋值**，EXE 分支不赋 → 顺序执行时 `inst_num` 恒 x → `pc_addr + inst_num + 2 = x`，pc 变 x 整机死锁（r1 写入是流水线滞后残留，随后全废） | `inst_num` 改**组合导出** `assign inst_num = mem[addr][1:0]`（见 §2） |
| 3 | **`inst_num` 时序**：即使 EXE 分支 blocking 赋值，iverilog 按实例化顺序 `u_pc` 先于 `u_ins_rom` 求值，pc 读到**旧 inst_num** → 5B 指令推进错 1 字节（RJAL 执行拍 pc_addr=0x10 而非末尾 0x11，跳转基准错 → 跳到 0x31 而非 0x32） | 组合导出无 race、复位第一拍自然正确（mem[0][1:0]=2）。组合读 `mem[addr]` 不支持 block RAM → **`ram_style` 明确改 `"distributed"`**（v1.3 同款做法，4096×8=32Kbit，Z-7 的 LUTRAM 可容纳）；同步寄存方案需改 pc/汇编器/复位，代价大，未采用（见 §9） |
| 4 | （用户已修）timer 读回缺失 | `single_mcu_top` 总线 case 无 TIMER 分支 → 读 0x3000 返回 0，属已知限制不修（timer 只写不读） |

- **fast CPU 核心测试**（test_v14：ADDI/ADD/RJAL+JALR/RBEQ 不跳/RBNE 跳/HALT）修复后 **PASSED**：r1=0x11 r2=0x22 r3=0x33 r4=0x44 r5=0xAA r6=0x55 r7=0x00，跳转子程序正确返回。

## 9. 已知限制 / 后续

| 项 | 说明 |
|----|------|
| data_ram 实际 4KB | `ram_top` 用 `addr[1:0]` 选区，`addr[11:2]` 仅 10 位 → 16KB 声明未全部利用；建议改页高 2 位选区（`addr[13:12]`） |
| timer 只写 | `single_mcu_top` case 缺 TIMER 读回 → `LBU 0x3000` 返回 0；timer 按纯写设计（重装/模式/ack），暂可接受 |
| inst_num 组合读 | 组合读 `mem[addr][1:0]` 不支持 block RAM，**`ram_style="distributed"`**（4096×8=32Kbit 用 LUTRAM，Z-7 资源充裕）；后续若想用 BRAM，需改同步方案（pc 跳转基准改指令首字节 + 汇编器 bytmov 相对首字节 + 复位处理），改动面大 |
| irq_vex 依赖截断 | 沿用 v1.3：10 位字面量存 8 位数组靠截断得 0x88/0xA8/0xC8/0xE0，建议后续改干净 8 位字面量 |
| 双 GPIO 同触发 | 沿用 v1.2：`gpio_irq=2'b11` 向量索引越界，勿用 |
| 中断不可重入 | 沿用 v1.1：ISR 内不响应新中断 |
| fsm 单向 | `frz→IDLE` 后无回 EXE 路径（HALT 为停机终态，正常）；若需从 IDLE 恢复需加默认分支 |

## 10. 仿真验证（整机回归）

`sim_1/new/board_test_tb.v` 整机回归（iverilog `-g2012`，ins_rom.hex = v2.0 上板程序，含 ram_top/ram_sec/gpio_group）：

| 阶段 | 内容 | 结果 |
|------|------|------|
| Phase1 | 上电 banner "cpu ready\r\n" 11 字节逐字符比对 | 11/11 OK |
| Phase2 | 回环开：发 a/B/5，收大小写翻转 A/b/0x15 | 3/3 OK |
| Phase3 | KEY2 按下→回环关：发 'a' 无回显 | OK |
| Phase4 | KEY2 再按→回环开：发 'x' 回显 'X' | OK |
| Phase5 | LED 亮后保持 + r4 递减归零（v2.0 Timer ISR 归零后不灭） | OK（r4 归零、LED 保持亮） |

- 结果 **22 通过 / 0 失败，ALL TESTS PASSED**（自然结束，未触发兜底超时）。
- 该回归同时验证了 §8 三处 ins_rom 修复（复位满宽 NOP、inst_num 组合导出、跳转基准对齐）与 v2.0 上板程序（banner/回环/KEY2 中断去抖/timer LED 计数/UART ISR 回显）整体正确。

---
*本文件随项目演进同步更新。*
