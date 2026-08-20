`timescale 1ns / 1ps
// 2026-08-18 复现"连续发送数字后 UART 卡住"的整机 TB
//   rtos_diag_uart（timer OFF 版 hex 同源），连续 back-to-back 注入数字，观察：
//   ① TX 是否持续流动（busy 突发现象）
//   ② pc / irq j / FIFO 指针 / rx_irq / CMD / RX_BUF 状态
//   ③ 注入停止后系统是否恢复响应
// 运行：cd project_self-try.srcs && iverilog -g2012 -o /tmp/rtos_burst_sim \
//          sources_1/new/mcu/single_mcu_top.v sources_1/new/mcu/rst_buf.v \
//          sources_1/new/core/*.v \
//          sources_1/new/peripherals/ram_top.v sources_1/new/peripherals/ram_sec.v \
//          sources_1/new/peripherals/uart_top.v sources_1/new/peripherals/uart_rx.v \
//          sources_1/new/peripherals/uart_tx.v sources_1/new/peripherals/timer.v \
//          sources_1/new/peripherals/gpio_group.v sim_1/new/rtos_burst_tb.v \
//       && vvp /tmp/rtos_burst_sim
module rtos_burst_tb;
    localparam MCNT = 434;              // 115200 @ 50MHz

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
    reg [7:0] txbuf [0:16383];
    integer txidx = 0;
    reg txb_prev = 1'b0;
    always @(posedge clk) begin
        if (u_top.u_uart.tx_busy === 1'b1 && txb_prev === 1'b0 && txidx < 16384) begin
            txbuf[txidx] = u_top.u_uart.u_uart_tx.tx_data_buf;
            txidx = txidx + 1;
        end
        txb_prev = u_top.u_uart.tx_busy;
    end

    // ===== 状态采样：每当 rx_irq 边沿 / 派发 / 卡住探测时打印 =====
    reg [11:0] last_pc = 12'hFFF;
    integer pc_stall_cnt = 0;
    always @(posedge clk) begin
        if (u_top.u_cpu.u_pc.pc_addr === last_pc) begin
            pc_stall_cnt = pc_stall_cnt + 1;
            if (pc_stall_cnt == 5000000)
                $display("%0t [STUCK?] pc=0x%03X 停在同址 500 万拍 | irq.stage=%0d j=%0d | fifo wr=%0d rd=%0d | rx_irq=%0d | CMD=0x%02h RX_BUF=0x%02h",
                    $time, u_top.u_cpu.u_pc.pc_addr, u_top.u_cpu.u_irq_con.stage,
                    u_top.u_cpu.u_irq_con.j, u_top.u_uart.wr_ptr, u_top.u_uart.rd_ptr,
                    u_top.u_uart.rx_irq, u_top.u_ram_top.ram_sec_2.mem[5],
                    u_top.u_ram_top.ram_sec_2.mem[6]);
        end else begin
            pc_stall_cnt = 0;
        end
        last_pc = u_top.u_cpu.u_pc.pc_addr;
    end

    // 复位
    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
        repeat(15) @(posedge clk);
        force u_top.u_rst_buf.rst_stable = 1'b0;
    end

    // 载入程序
    initial begin
        #1;
        $readmemh("E:/Vivado_Projects/project_self-try/project_self-try.srcs/ins_rom.hex",
                  u_top.u_cpu.u_ins_rom.mem);
    end

    // 发一字节
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

    // 等 TX 空闲 2000 拍
    integer idle_cnt;
    task wait_tx_idle;
        begin
            idle_cnt = 0;
            while (idle_cnt < 2000) begin
                @(posedge clk);
                if (u_top.u_uart.tx_busy === 1'b1) idle_cnt = 0;
                else idle_cnt = idle_cnt + 1;
            end
        end
    endtask

    // 打 dump
    integer i;
    task dump_state(input string tag);
        begin
            $display("---- %s @%0t : pc=0x%03X irq.stage=%0d j=%0d prio=%0d | wr=%0d rd=%0d rx_irq=%0d | CMD=0x%02h RX_BUF=0x%02h | TX共%0d字节",
                tag, $time, u_top.u_cpu.u_pc.pc_addr, u_top.u_cpu.u_irq_con.stage,
                u_top.u_cpu.u_irq_con.j, u_top.u_cpu.u_irq_con.prio,
                u_top.u_uart.wr_ptr, u_top.u_uart.rd_ptr, u_top.u_uart.rx_irq,
                u_top.u_ram_top.ram_sec_2.mem[5], u_top.u_ram_top.ram_sec_2.mem[6],
                txidx);
        end
    endtask

    // ===== 主流程 =====
    integer b;
    initial begin
        #200;
        $display("===== Phase0: boot =====");
        wait_tx_idle;
        $display("boot 完成，TX %0d 字节", txidx);
        dump_state("boot");

        // ---- Phase1: 连续发 200 个 '1'（回环触发 hello，覆盖长时间打印窗口）----
        $display("===== Phase1: 连续注入 200 个 '1' =====");
        rx0_en = 1;
        for (b = 0; b < 200; b = b + 1) begin
            send_byte(8'h31);
            if (b == 199) $display("burst 注入完毕 @%0t", $time);
        end
        rx0_en = 0;

        // 注入结束后观察一段时间
        wait_tx_idle;
        dump_state("after burst");
        $display("===== Phase2: 注入停止后发 '0' 验证可响应 =====");
        rx0_en = 1;
        send_byte(8'h30);
        rx0_en = 0;
        wait_tx_idle;
        dump_state("after '0'");

        $display("===== TX 全量 hex dump（%0d 字节）=====", txidx);
        for (i = 0; i < txidx; i = i + 16) begin
            integer j;
            $write("  tx[%04d] ", i);
            for (j = i; j < txidx && j < i + 16; j = j + 1) $write("%02h ", txbuf[j]);
            $display("");
        end
        $finish;
    end

    // 兜底超时
    initial begin
        #900000000;                     // 45M cycles ≈ 900ms
        $display("===== TIMEOUT =====");
        dump_state("timeout");
        $finish;
    end
endmodule
