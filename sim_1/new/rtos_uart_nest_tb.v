`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 2026-08-18 RTOS UART ISR 自嵌套验证（rtos_diag_uart，timer OFF）
//   问题（用户假设）：串口助手发指令常带 \r\n → FIFO 多字节同时存在 → rx_irq 电平保持
//       → 若硬件允许 ISR 执行期间再次派发同级 UART 中断（嵌套）：
//         UART_S1 单现场槽被覆盖 → r1 污染 → 字节覆盖/丢失 → 命令错乱 → 卡死
//   本 TB 三层验证：
//     P1 boot（shell 就绪）
//     P2 force FIFO 同时 3 字节（boot 后 FIFO 恒 rd=wr=0，常量索引）——最坏情况：
//        ISR 全周期 rx_irq 电平高（rd!=wr 自然驱动），若硬件允许同级嵌套必在此触发
//     P3 真实背靠背 "x\r\n"（0x78 0x0D 0x0A）——端到端弹 FIFO 顺序/不丢/不嵌套
//     P4 '1' 命令回环——压测后整机仍活着（r1 无污染的功能性铁证）
//   硬件判据（核心）：
//     - irq_controller IRQ 态抢占条件 = irq_addr_in[5:3] > prio（严格大于）
//       UART 自嵌套 [5:3]=010 > prio=010 恒假 → 硬件层面已屏蔽
//     - uart_isr 内每条 SB/LBU 后垫 LBEQ r0,r0（irq_en=0）→ 程序层面无授权点
//   TB 注意：iverilog force 数组索引须常量；string 不串 task 端口；期望串用 \x0D
// 运行：cd project_self-try.srcs && iverilog -g2012 -o /tmp/nest_sim \
//          sources_1/new/mcu/single_mcu_top.v sources_1/new/mcu/rst_buf.v \
//          sources_1/new/core/*.v \
//          sources_1/new/peripherals/ram_top.v sources_1/new/peripherals/ram_sec.v \
//          sources_1/new/peripherals/uart_top.v sources_1/new/peripherals/uart_rx.v \
//          sources_1/new/peripherals/uart_tx.v sources_1/new/peripherals/timer.v \
//          sources_1/new/peripherals/gpio_group.v sim_1/new/rtos_uart_nest_tb.v \
//       && vvp /tmp/nest_sim
//////////////////////////////////////////////////////////////////////////////////
module rtos_uart_nest_tb;
    localparam MCNT = 434;              // 115200 @ 50MHz
    integer pass = 0, fail = 0;

    reg clk = 0, rst_n = 1;
    wire [7:0] gpio_pin_bus;
    reg rx0_drv = 1'b1;
    reg rx0_en = 1'b0;
    assign gpio_pin_bus[0] = rx0_en ? rx0_drv : 1'bz;
    pullup (gpio_pin_bus[0]);
    assign gpio_pin_bus[7] = 1'bz;
    pullup (gpio_pin_bus[7]);

    single_mcu_top u_top(
        .clk(clk), .rst_n(rst_n),
        .gpio_pin_bus(gpio_pin_bus)
    );

    always #10 clk = ~clk;              // 50MHz

    // ===== TX 采集 =====
    reg [7:0] txbuf [0:2047];
    integer txidx = 0;
    reg txb_prev = 1'b0;
    always @(posedge clk) begin
        if (u_top.u_uart.tx_busy === 1'b1 && txb_prev === 1'b0 && txidx < 2048) begin
            txbuf[txidx] = u_top.u_uart.u_uart_tx.tx_data_buf;
            txidx = txidx + 1;
        end
        txb_prev = u_top.u_uart.tx_busy;
    end

    // ==========================================================
    // 嵌套监测（核心）
    //   dispatch_cnt : 0x260 派发次数（irq_flush 上升 且 irq_addr==0x260）
    //   nested_cnt   : 上述派发发生时前一拍 stage==IRQ（= 同级自嵌套！）
    //   j_max        : 中断栈指针最大深度（正常 ≤1）
    //   save_busy/peak: UART_S1 未配对写深（SB=+1, LBU=-1；>1 即单槽被覆盖）
    //   pop_seq      : LBU@UART(0x2000) 弹出的 FIFO 字节序列（无丢无乱序）
    //   irq_hi_inside: ISR 执行中 rx_irq==1 的拍数（电平保持窗口）
    // ==========================================================
    integer dispatch_cnt = 0;
    integer nested_cnt = 0;
    integer j_max = 0;
    integer save_busy = 0, save_peak = 0;
    integer pop_cnt = 0;
    reg [7:0] pop_seq [0:15];
    integer irq_hi_inside = 0;
    reg [1:0] st_prev = 2'b00;

    // UART_S1 save/restore 边沿检测（RAM 2 拍 stall 令条件保持 2 拍 → 必须边沿，否则单写被 +2）
    reg save_cond = 0, save_prev = 0;
    reg restore_cond = 0, restore_prev = 0;

    // P3 卡死诊断：第 4 次派发起逐拍打印 500 拍
    reg diag_on = 0;
    integer diag_cnt = 0;

    always @(posedge clk) begin
        if (u_top.u_cpu.u_irq_con.irq_flush === 1'b1 && u_top.u_cpu.u_irq_con.irq_addr === 12'h260) begin
            dispatch_cnt = dispatch_cnt + 1;
            if (st_prev === 2'b01) nested_cnt = nested_cnt + 1;
        end
        if (u_top.u_cpu.u_irq_con.j > j_max) j_max = u_top.u_cpu.u_irq_con.j;
        if (u_top.u_cpu.u_irq_con.stage === 2'b01 && u_top.u_uart.rx_irq === 1'b1)
            irq_hi_inside = irq_hi_inside + 1;

        // UART_S1 (0x9007) save / restore 配对（边沿计数，规避 RAM 双拍保持）
        save_cond = (u_top.u_ram_top.ram_sec_2.ram_sec === 1'b1
                     && u_top.u_ram_top.ram_sec_2.mode === 1'b1
                     && u_top.u_ram_top.ram_sec_2.sec_addr_in === 12'h007);
        restore_cond = (u_top.u_ram_top.ram_sec_2.ram_sec === 1'b1
                        && u_top.u_ram_top.ram_sec_2.mode === 1'b0
                        && u_top.u_ram_top.ram_sec_2.sec_addr_in === 12'h007);
        if (save_cond && !save_prev) begin
            save_busy = save_busy + 1;
            if (save_busy > save_peak) save_peak = save_busy;
        end
        if (restore_cond && !restore_prev) begin
            save_busy = save_busy - 1;
        end
        save_prev = save_cond;
        restore_prev = restore_cond;

        // P3 卡死诊断（从第 4 次派发起逐拍打印）
        if (dispatch_cnt > 3 && !diag_on) begin diag_on = 1; diag_cnt = 0; end
        if (diag_on) begin
            diag_cnt = diag_cnt + 1;
            if (diag_cnt <= 500)
                $display("[DIAG %0d] pc=0x%03X fsm=%b st=%b j=%0d prio=%b rx_irq=%b rd=%0d wr=%0d iain=0x%02X ia=0x%03X ifl=%b ien=%b stall=%b cstall=%b frz=%b ifs=0x%08X dins=0x%08X pcs0=0x%03X",
                         diag_cnt, u_top.u_cpu.u_pc.pc_addr,
                         u_top.u_cpu.u_fsm.stage, u_top.u_cpu.u_irq_con.stage,
                         u_top.u_cpu.u_irq_con.j, u_top.u_cpu.u_irq_con.prio,
                         u_top.u_uart.rx_irq, u_top.u_uart.rd_ptr, u_top.u_uart.wr_ptr,
                         u_top.u_cpu.irq_bus, u_top.u_cpu.u_irq_con.irq_addr,
                         u_top.u_cpu.u_irq_con.irq_flush, u_top.u_cpu.u_irq_con.irq_en,
                         u_top.u_cpu.stall_bus, u_top.u_cpu.cstall, u_top.u_cpu.frz,
                         u_top.u_cpu.u_if_reg.inst_raw, u_top.u_cpu.u_decoder.inst_raw,
                         u_top.u_cpu.u_irq_con.pc_addr[0]);
            if (diag_cnt == 500) diag_on = 0;
        end

        // FIFO 弹出序列（LBU @0x2000 读）
        if (u_top.u_cpu.bus_addr_out[15:12] === 4'b0010 && u_top.u_cpu.bus_sig_out[0] === 1'b0) begin
            if (pop_cnt < 16) pop_seq[pop_cnt] = u_top.u_uart.rx_buf[u_top.u_uart.rd_ptr];
            pop_cnt = pop_cnt + 1;
        end

        // IRET 沿打印
        if (u_top.u_cpu.u_irq_con.stage === 2'b11 && st_prev === 2'b01)
            $display("%0t [IRET]     resume pc=0x%03X r1=0x%02h",
                     $time, u_top.u_cpu.u_pc.pc_addr, u_top.u_cpu.u_reg_f.regs[1]);
        st_prev = u_top.u_cpu.u_irq_con.stage;
    end

    // ===== 复位 =====
    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
        repeat(15) @(posedge clk);
        force u_top.u_rst_buf.rst_stable = 1'b0;
    end

    // ===== 载入程序 =====
    initial begin
        #1;
        $readmemh("E:/Vivado_Projects/project_self-try/project_self-try.srcs/ins_rom.hex",
                  u_top.u_cpu.u_ins_rom.mem);
    end

    // ===== 发送一字节 =====
    task send_byte(input [7:0] d);
        integer k;
        begin
            rx0_drv = 0;
            repeat(MCNT) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                rx0_drv = d[k];
                repeat(MCNT) @(posedge clk);
            end
            rx0_drv = 1;
            repeat(MCNT) @(posedge clk);
        end
    endtask

    // ===== 等 TX 突发结束 =====
    integer idle_cnt;
    task wait_tx_burst_done;
        begin
            while (u_top.u_uart.tx_busy !== 1'b1) @(posedge clk);
            while (u_top.u_uart.tx_busy === 1'b1) @(posedge clk);
            idle_cnt = 0;
            while (idle_cnt < 2000) begin
                @(posedge clk);
                if (u_top.u_uart.tx_busy === 1'b1) idle_cnt = 0;
                else idle_cnt = idle_cnt + 1;
            end
        end
    endtask

    // ===== 等 FIFO 排空 =====
    integer tmo2;
    task wait_fifo_empty;
        begin
            tmo2 = 0;
            while (u_top.u_uart.rd_ptr !== u_top.u_uart.wr_ptr) begin
                @(posedge clk);
                tmo2 = tmo2 + 1;
                if (tmo2 > 2000000) begin
                    $display("  FAIL FIFO 未排空 rd=%0d wr=%0d", u_top.u_uart.rd_ptr, u_top.u_uart.wr_ptr);
                    fail = fail + 1;
                    return;
                end
            end
            $display("  OK  FIFO 排空 (rd=wr=%0d)", u_top.u_uart.rd_ptr);
        end
    endtask

    // ===== 等 rd_ptr == 指定值 =====
    task wait_rd_eq(input [5:0] v);
        begin
            tmo2 = 0;
            while (u_top.u_uart.rd_ptr !== v) begin
                @(posedge clk);
                tmo2 = tmo2 + 1;
                if (tmo2 > 2000000) begin
                    $display("  FAIL rd_ptr 未达 %0d（当前 %0d）", v, u_top.u_uart.rd_ptr);
                    fail = fail + 1;
                    return;
                end
            end
        end
    endtask

    // ===== 期望 TX 子串（搜索式，抗多字节残流）=====
    string substr_str = "";
    integer txpos = 0;
    task expect_substr;
        integer i, k, ok;
        begin
            ok = 0; i = txpos;
            while (!ok && i + substr_str.len() <= txidx) begin
                ok = 1;
                for (k = 0; k < substr_str.len(); k = k + 1)
                    if (txbuf[i + k] !== substr_str[k]) ok = 0;
                i = i + 1;
            end
            if (ok) begin
                $display("  OK  包含\"%s\" @tx[%0d]", substr_str, i - 1);
                pass = pass + 1;
                txpos = i - 1 + substr_str.len();
            end else begin
                $display("  FAIL 未找到\"%s\"（txidx=%0d, txpos=%0d）", substr_str, txidx, txpos);
                fail = fail + 1;
            end
        end
    endtask

    // ===== 硬件不变量检查（核心判据；tag 用模块级 string 规避 iverilog task 端口 bug）=====
    integer nb0, nb1, nb2;
    string tag_str = "";
    task check_hw;
        begin
            if (nested_cnt == nb0)
                $display("  OK  [%s] 无同级嵌套（ISR 内 0x260 再派发 = 0）", tag_str);
            else begin
                $display("  FAIL[%s] 检测到嵌套派发 %0d 次（UART_S1 将被覆盖）", tag_str, nested_cnt - nb0);
                fail = fail + 1;
            end
            if (j_max <= 1)
                $display("  OK  [%s] j 最大=%0d（中断栈未加深）", tag_str, j_max);
            else begin
                $display("  FAIL[%s] j 最大=%0d（嵌套加深！）", tag_str, j_max);
                fail = fail + 1;
            end
            if (save_peak <= 1)
                $display("  OK  [%s] UART_S1 写深峰值=%0d（单槽无覆盖）", tag_str, save_peak);
            else begin
                $display("  FAIL[%s] UART_S1 写深峰值=%0d（单槽被覆盖→r1 污染）", tag_str, save_peak);
                fail = fail + 1;
            end
        end
    endtask

    // ===== 打印硬件监测增量 =====
    task report_hw;
        begin
            $display("  [%s] 0x260派发=%0d 嵌套=%0d j_max=%0d UART_S1写深峰=%0d FIFO弹=%0d IRQ态rx_irq高=%0d拍",
                     tag_str, dispatch_cnt - nb1, nested_cnt - nb0, j_max, save_peak,
                     pop_cnt - nb2, irq_hi_inside);
        end
    endtask

    // ===== 打印 pop 序列 =====
    integer p;
    task print_pops(input [3:0] from, input [3:0] to);
        begin
            $write("  [%s] FIFO 弹出序列[%0d..%0d]: ", tag_str, from, to);
            for (p = from; p < to && p < pop_cnt; p = p + 1) $write("%02h ", pop_seq[p]);
            $display("");
        end
    endtask

    // ===== 主流程 =====
    integer i;
    initial begin
        #200;

        // ---------- Phase 1：boot ----------
        $display("===== Phase1: boot =====");
        wait_tx_burst_done;
        $display("boot TX 共 %0d 字节", txidx);
        if (txidx >= 5 && txbuf[txidx-5]==="c" && txbuf[txidx-4]==="m" &&
            txbuf[txidx-3]==="d" && txbuf[txidx-2]===">" && txbuf[txidx-1]===" ")
            $display("  OK  boot 尾部 = \"cmd> \"（shell 就绪）");
        else begin
            $display("  FAIL boot 尾部非 \"cmd> \"（txidx=%0d）", txidx);
            fail = fail + 1;
        end
        txpos = txidx;
        nb0 = nested_cnt; nb1 = dispatch_cnt; nb2 = pop_cnt;
        wait_fifo_empty;
        if (u_top.u_uart.rd_ptr !== 6'd0 || u_top.u_uart.wr_ptr !== 6'd0)
            $display("  WARN boot 后 FIFO 指针非 0（rd=%0d wr=%0d）", u_top.u_uart.rd_ptr, u_top.u_uart.wr_ptr);

        // ---------- Phase 2：force FIFO 3 字节同时存在（最坏情况，纯测派发行为）----------
        // iverilog 不能 force 数组元素 → 字节内容为 0x00（对本测试无意义；真内容由 Phase 3 真实注入覆盖）。
        // 关键：rd!=wr 全程 → rx_irq 电平保持贯穿 3 次连续 ISR；若硬件允许同级嵌套，必在此触发。
        $display("===== Phase2: force wr_ptr=3（FIFO 同时 3 字节，rd 自然推进，rx_irq 由 RTL 自驱）=====");
        nb0 = nested_cnt; nb1 = dispatch_cnt; nb2 = pop_cnt;
        force u_top.u_uart.wr_ptr = 6'd3;
        $display("  force wr_ptr=3, rd=0→1→2→3；rx_irq 全程高（0x00 内容，getc 视为空，无命令执行）");
        wait_rd_eq(6'd3);            // 等 3 次 pop 完成（rd==wr==3 → rx_irq 自然回落）
        repeat(20) @(posedge clk);   // 让最后一个 ISR 收尾
        tag_str = "P2"; report_hw;
        tag_str = "P2"; print_pops(nb2, pop_cnt);
        tag_str = "P2"; check_hw;
        if (pop_cnt - nb2 == 3)
            $display("  OK  [P2] 连续 3 次 ISR 派发、rx_irq 全程电平高，无同级嵌套");
        else begin
            $display("  FAIL[P2] 期望 3 次 pop，实际 %0d", pop_cnt - nb2);
            fail = fail + 1;
        end
        // 冻结一致空态（force 前 rd 已到 3，release 后 rd/wr 均回落到 3 → 一致）
        force u_top.u_uart.rd_ptr = 6'd0;
        force u_top.u_uart.wr_ptr = 6'd0;
        force u_top.u_uart.rx_irq = 1'b0;
        repeat(3) @(posedge clk);
        release u_top.u_uart.rd_ptr;
        release u_top.u_uart.wr_ptr;
        release u_top.u_uart.rx_irq;
        repeat(2) @(posedge clk);
        $display("  P2 后 FIFO rd=%0d wr=%0d（应一致且空）", u_top.u_uart.rd_ptr, u_top.u_uart.wr_ptr);
        wait_fifo_empty;

        // ---------- Phase 3：真实背靠背 "x\r\n" ----------
        $display("===== Phase3: 背靠背真实注入 'x'(0x78)+CR(0x0D)+LF(0x0A) =====");
        nb0 = nested_cnt; nb1 = dispatch_cnt; nb2 = pop_cnt;
        rx0_en = 1;
        send_byte(8'h78);
        send_byte(8'h0D);
        send_byte(8'h0A);
        rx0_en = 0;
        wait_tx_burst_done;
        $display("Phase3 处理完毕，TX 新增 %0d 字节", txidx - txpos);
        wait_fifo_empty;
        tag_str = "P3"; report_hw;
        tag_str = "P3"; print_pops(nb2, pop_cnt);
        tag_str = "P3"; check_hw;
        if (pop_cnt - nb2 == 3 && pop_seq[nb2]===8'h78 && pop_seq[nb2+1]===8'h0D && pop_seq[nb2+2]===8'h0A)
            $display("  OK  [P3] 3 字节按序弹出、无丢无乱");
        else begin
            $display("  FAIL[P3] 弹出序列非 78 0D 0A");
            fail = fail + 1;
        end
        substr_str = "inv=78"; expect_substr;
        substr_str = "cmd> ";  expect_substr;

        // ---------- Phase 4：'1' 回环（整机仍活着 + r1 未污染）----------
        $display("===== Phase4: 发送 '1' → Hello World（压测后整机回环）=====");
        nb0 = nested_cnt; nb1 = dispatch_cnt; nb2 = pop_cnt;
        rx0_en = 1;
        send_byte(8'h31);
        rx0_en = 0;
        wait_tx_burst_done;
        wait_fifo_empty;
        tag_str = "P4"; report_hw;
        tag_str = "P4"; print_pops(nb2, pop_cnt);
        tag_str = "P4"; check_hw;
        substr_str = "Hello World"; expect_substr;
        substr_str = "t=0000"; expect_substr;
        substr_str = "cmd> ";    expect_substr;

        // ---------- 结果 ----------
        $display("===== 全量 TX hex dump（%0d 字节）=====", txidx);
        for (i = 0; i < txidx; i = i + 16) begin
            $write("  tx[%03d] ", i);
            for (p = i; p < txidx && p < i + 16; p = p + 1)
                $write("%02h ", txbuf[p]);
            $display("");
        end
        $display("=============================================");
        $display("总派发=%0d 总嵌套=%0d j_max=%0d UART_S1写深峰=%0d FIFO总弹=%0d",
                 dispatch_cnt, nested_cnt, j_max, save_peak, pop_cnt);
        $display("结果: %0d 通过 / %0d 失败", pass, fail);
        if (fail == 0) $display("ALL TESTS PASSED");
        else $display("SOME TESTS FAILED");
        $finish;
    end

    // ===== 兜底超时 =====
    initial begin
        #800000000;                     // 40M cycles ≈ 800ms
        $display("===== TIMEOUT =====");
        $finish;
    end

    // ===== 进度心跳（每 2M 拍刷屏，便于观察长仿真）=====
    integer cyc = 0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if ((cyc % 2000000) == 0) begin
            $display("%0t [HEARTBEAT] %0d cycles, dispatch=%0d nested=%0d pop=%0d j_max=%0d | pc=0x%03X st=%b j=%0d rx_irq=%b rd=%0d wr=%0d",
                     $time, cyc, dispatch_cnt, nested_cnt, pop_cnt, j_max,
                     u_top.u_cpu.u_pc.pc_addr, u_top.u_cpu.u_irq_con.stage,
                     u_top.u_cpu.u_irq_con.j, u_top.u_uart.rx_irq,
                     u_top.u_uart.rd_ptr, u_top.u_uart.wr_ptr);
            $fflush;
        end
    end
endmodule
