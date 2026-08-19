`timescale 1ns / 1ps
// v2_render_tb.v — 俄罗斯方块 v2 核心验证：boot 渲染 + 右移 + 旋转（抓 UART 帧）
// LIND/SIND 指令路径 + 方块移动/旋转 + col 8/9 渲染
module v2_render_tb;
    reg clk = 0, rst_n = 1;
    wire [7:0] gpio_pin_bus;
    reg rx0_drv = 1'b1, rx0_en = 1'b0;
    assign gpio_pin_bus[0] = rx0_en ? rx0_drv : 1'bz;
    pullup (gpio_pin_bus[0]);
    assign gpio_pin_bus[1] = 1'bz;
    pullup (gpio_pin_bus[1]);
    integer t0;
    single_mcu_top u_top(.clk(clk), .rst_n(rst_n), .gpio_pin_bus(gpio_pin_bus));
    always #10 clk = ~clk;
    task send_byte(input [7:0] b);
        integer i;
        begin
            rx0_en = 1'b1; rx0_drv = 1'b0;
            repeat(434) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rx0_drv = b[i];
                repeat(434) @(posedge clk);
            end
            rx0_drv = 1'b1;
            repeat(434) @(posedge clk);
            rx0_en = 1'b0;
        end
    endtask
    reg [7:0] uart_wr [0:8191];
    integer uw = 0;
    always @(posedge clk)
        if (u_top.bus_sig_f && u_top.bus_addr_f == 16'h2000) begin
            if (uw < 8192) begin uart_wr[uw] = u_top.bus_data_f; uw = uw + 1; end
        end
    initial begin rst_n = 0; #100; rst_n = 1; repeat(15) @(posedge clk);
        force u_top.u_rst_buf.rst_stable = 1'b0; end
    initial begin #1;
        $readmemh("E:/Vivado_Projects/project_self-try/project_self-try.srcs/ins_rom.hex",
                  u_top.u_cpu.u_ins_rom.mem);
    end
    task dump_board(input [31:0] from);
        integer i;
        begin
            for (i = from; i < from + 300 && i < uw; i = i + 1) begin
                if (uart_wr[i] >= 8'h20 && uart_wr[i] < 8'h7F)
                    $write("%c", uart_wr[i]);
                else
                    $write("<%02X>", uart_wr[i]);
            end
            $write("\n");
        end
    endtask
    initial begin
        #300; repeat(1000) @(posedge clk);
        $display("== 俄罗斯方块 v2 验证 ==");
        repeat(1200000) @(posedge clk);
        $write("[BOOT] "); dump_board(0);
        t0 = uw;
        send_byte("6"); repeat(1200000) @(posedge clk);
        $write("[右移] "); dump_board(t0);
        t0 = uw;
        send_byte("5"); repeat(1200000) @(posedge clk);
        $write("[旋转] "); dump_board(t0);
        $display("===== 完成 =====");
        $finish;
    end
    initial begin #2000000000; $display("===== TIMEOUT ====="); $finish; end
endmodule
