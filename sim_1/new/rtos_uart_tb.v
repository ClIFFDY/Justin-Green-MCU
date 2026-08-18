`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 2026-08-18 RTOS UART 通路验证（rtos_diag_uart，timer OFF）
//   验证目标：
//     ① TX 发送链：putc → SB@0x2000 → uart_tx → pin1；boot 各 init 行 + 菜单 + "cmd> "
//     ② RX 捕获：pin0 字节 → uart_rx(rx_done/rx_data) → FIFO 非空 → rx_irq=1
//     ③ RX 派发：irq_controller IDLE→IRQ，跳 0x260 uart_isr，弹 FIFO 存 RX_BUF
//     ④ getc 轮询：读 RX_BUF → CMD 落位 → 命令回环（echo/Hello World/inv/LED）
//   判据：TX 字节流逐字节比对 + RAM CMD/RX_BUF 内部状态。
// 运行：cd project_self-try.srcs && iverilog -g2012 -o /tmp/rtos_uart_sim \
//          sources_1/new/mcu/single_mcu_top.v sources_1/new/mcu/rst_buf.v \
//          sources_1/new/core/*.v \
//          sources_1/new/peripherals/ram_top.v sources_1/new/peripherals/ram_sec.v \
//          sources_1/new/peripherals/uart_top.v sources_1/new/peripherals/uart_rx.v \
//          sources_1/new/peripherals/uart_tx.v sources_1/new/peripherals/timer.v \
//          sources_1/new/peripherals/gpio_group.v sim_1/new/rtos_uart_tb.v \
//       && vvp /tmp/rtos_uart_sim
//////////////////////////////////////////////////////////////////////////////////
module rtos_uart_tb;
    localparam MCNT = 434;              // 115200 @ 50MHz（分频 434 拍/位）
    integer pass = 0, fail = 0;

    reg clk = 0, rst_n = 1;
    wire [7:0] gpio_pin_bus;
    // pin0 = RX：模块配 RX 后三态，tb 经 pullup 弱上拉 + rx0_en 驱动
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

    // ===== TX 字节采集：busy 上升沿下一拍 tx_data_buf 已载入当字符 =====
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

    // ===== RX 路径 / 派发探针（每步 $display 便于失败定位）=====
    reg rxirq_prev = 1'b0;
    reg [1:0] st_prev = 2'b00;
    always @(posedge clk) begin
        if (u_top.u_uart.u_uart_rx.rx_done)
            $display("%0t [RX_CAP]   rx_data=0x%02h", $time, u_top.u_uart.u_uart_rx.rx_data);
        if (u_top.u_uart.rx_irq && !rxirq_prev)
            $display("%0t [RX_IRQ]   上升 FIFO非空 wr=%0d rd=%0d", $time,
                     u_top.u_uart.wr_ptr, u_top.u_uart.rd_ptr);
        if (u_top.u_cpu.u_irq_con.stage === 2'b01 && st_prev === 2'b00)
            $display("%0t [DISPATCH] pc=0x%03X -> vector 0x%03X", $time,
                     u_top.u_cpu.u_pc.pc_addr, u_top.u_cpu.u_irq_con.irq_addr);
        if (u_top.u_cpu.u_irq_con.stage === 2'b11 && st_prev === 2'b01)
            $display("%0t [IRET]     resume pc=0x%03X", $time, u_top.u_cpu.u_pc.pc_addr);
        if (u_top.u_ram_top.ram_sec_2.ram_sec === 1'b1 && u_top.u_ram_top.ram_sec_2.mode === 1'b1) begin
            if (u_top.u_ram_top.ram_sec_2.sec_addr_in == 12'h005)
                $display("%0t [RAM]      CMD    <- 0x%02h", $time, u_top.u_ram_top.bus_data_in);
            if (u_top.u_ram_top.ram_sec_2.sec_addr_in == 12'h006)
                $display("%0t [RAM]      RX_BUF <- 0x%02h", $time, u_top.u_ram_top.bus_data_in);
        end
        rxirq_prev = u_top.u_uart.rx_irq;
        st_prev = u_top.u_cpu.u_irq_con.stage;
    end

    // ===== 复位（短路 rst_buf 长脉冲）=====
    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
        repeat(15) @(posedge clk);
        force u_top.u_rst_buf.rst_stable = 1'b0;
    end

    // ===== 载入程序（#1 覆盖 ins_rom.v 自身 readmemh）=====
    initial begin
        #1;
        $readmemh("E:/Vivado_Projects/project_self-try/project_self-try.srcs/ins_rom.hex",
                  u_top.u_cpu.u_ins_rom.mem);
    end

    // ===== 发送一字节到 pin0（1 起始 + 8 数据 LSB-first + 1 停止）=====
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

    // ===== 等一次 TX 突发结束：busy 先升（突发开始），再连续空闲 2000 拍 =====
    integer idle_cnt;
    task wait_tx_burst_done;
        begin
            while (u_top.u_uart.tx_busy !== 1'b1) @(posedge clk);   // 等突发开始
            while (u_top.u_uart.tx_busy === 1'b1) @(posedge clk);   // 等首字节发完
            idle_cnt = 0;
            while (idle_cnt < 2000) begin
                @(posedge clk);
                if (u_top.u_uart.tx_busy === 1'b1) idle_cnt = 0;
                else idle_cnt = idle_cnt + 1;
            end
        end
    endtask

    // ===== 期望 TX 子串（从 txpos 起逐字节比对；expect_str 由主流程赋值）=====
    string expect_str = "";
    integer txpos = 0;
    task expect_tx;
        integer i, ok;
        begin
            ok = 1;
            for (i = 0; i < expect_str.len(); i = i + 1) begin
                if (txpos + i >= txidx || txbuf[txpos + i] !== expect_str[i]) ok = 0;
            end
            if (ok) begin
                $display("  OK  期望\"%s\"", expect_str);
                txpos = txpos + expect_str.len();
                pass = pass + 1;
            end else begin
                $display("  FAIL 期望\"%s\" @tx[%0d..%0d]（txidx=%0d）", expect_str,
                         txpos, txpos + expect_str.len() - 1, txidx);
                $write("       实际: ");
                for (i = 0; i < expect_str.len() && txpos + i < txidx; i = i + 1)
                    $write("%c", txbuf[txpos + i]);
                $display("");
                fail = fail + 1;
                txpos = txpos + expect_str.len();
            end
        end
    endtask

    // ===== 等 CMD 落位（带超时，失败继续往下）=====
    integer tmo;
    task wait_cmd(input [7:0] exp);
        begin
            tmo = 0;
            while (u_top.u_ram_top.ram_sec_2.mem[5] !== exp) begin
                @(posedge clk);
                tmo = tmo + 1;
                if (tmo > 1000000) begin
                    $display("  FAIL CMD 超时：期望 0x%02h，当前 0x%02h（RX 链未收到命令）",
                             exp, u_top.u_ram_top.ram_sec_2.mem[5]);
                    fail = fail + 1;
                    return;
                end
            end
            $display("  OK  CMD=0x%02h（getc 收到命令）", exp);
            pass = pass + 1;
        end
    endtask

    // ===== 主流程 =====
    integer i;
    initial begin
        #200;

        // ---------- Phase 1：boot TX 链 ----------
        $display("===== Phase1: boot TX 序列 =====");
        wait_tx_burst_done;
        $display("boot 突发完成，TX 共 %0d 字节", txidx);
        expect_str = "cpu init\x0D\n";    expect_tx;
        expect_str = "uart init\x0D\n";   expect_tx;
        expect_str = "timer init\x0D\n";  expect_tx;
        expect_str = "gpio init\x0D\n";   expect_tx;
        expect_str = "system init\x0D\n"; expect_tx;
        expect_str = "\x0D\n== MCU RTOS v1.0 ==\x0D\n  1 hello world\x0D\n  2 toggle led\x0D\n  0 refresh\x0D\n";
        expect_tx;
        expect_str = "cmd> ";           expect_tx;

        // ---------- Phase 2：'1' → Hello World + t=0000 ----------
        $display("===== Phase2: 发送 '1' (0x31) → Hello World =====");
        rx0_en = 1;
        send_byte(8'h31);
        rx0_en = 0;
        wait_cmd(8'h31);
        wait_tx_burst_done;
        expect_str = "1\x0D\n\x0D\nHello World!\x0D\nt=0000\x0D\ncmd> "; expect_tx;

        // ---------- Phase 3：'x' 未知命令 → inv=78 ----------
        $display("===== Phase3: 发送 'x' (0x78) → inv=78 =====");
        rx0_en = 1;
        send_byte(8'h78);
        rx0_en = 0;
        wait_cmd(8'h78);
        wait_tx_burst_done;
        expect_str = "x\x0D\ninv=78\x0D\ncmd> "; expect_tx;

        // ---------- Phase 4：'\r' 空输入 → 重新提示 ----------
        $display("===== Phase4: 发送 CR (0x0D) → 重新提示 =====");
        rx0_en = 1;
        send_byte(8'h0D);
        rx0_en = 0;
        wait_cmd(8'h0D);
        wait_tx_burst_done;
        expect_str = "\x0D\x0D\ncmd> "; expect_tx;

        // ---------- Phase 5：'2' → LED 菜单 → '0' 退出 ----------
        $display("===== Phase5: 发送 '2' → LED 菜单 → '0' 退出 =====");
        rx0_en = 1;
        send_byte(8'h32);
        rx0_en = 0;
        wait_cmd(8'h32);
        wait_tx_burst_done;
        expect_str = "2\x0D\n\x0D\nLED: key=toggle b=blink 0=quit\x0D\n"; expect_tx;

        rx0_en = 1;
        send_byte(8'h30);
        rx0_en = 0;
        wait_cmd(8'h30);
        wait_tx_burst_done;
        expect_str = "0\x0D\ncmd> "; expect_tx;

        // ---------- 结果 ----------
        $display("===== 全量 TX hex dump（%0d 字节）=====", txidx);
        for (txpos = 0; txpos < txidx; txpos = txpos + 16) begin
            $write("  tx[%03d] ", txpos);
            for (i = txpos; i < txidx && i < txpos + 16; i = i + 1)
                $write("%02h ", txbuf[i]);
            $display("");
        end
        $display("=============================================");
        $display("结果: %0d 通过 / %0d 失败", pass, fail);
        if (fail == 0) $display("ALL TESTS PASSED");
        else begin
            $display("SOME TESTS FAILED");
            // 失败时打印剩余 TX 流（txpos 之后）帮助定位
            $write("剩余 TX: ");
            for (txpos = txpos; txpos < txidx; txpos = txpos + 1)
                $write("%c", txbuf[txpos]);
            $display("");
        end
        $finish;
    end

    // ===== 兜底超时 =====
    initial begin
        #600000000;                     // 30M cycles ≈ 600ms
        $display("===== TIMEOUT =====");
        $finish;
    end
endmodule
