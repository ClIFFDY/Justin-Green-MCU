`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/13 10:00:20
// Design Name: 
// Module Name: uart_rx
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module uart_rx(
    input wire clk,
    input wire rst,
    input wire rx,
    output reg rx_done,
    output reg [7:0] rx_data
    );

    localparam BPS = 115200;
    localparam CLK = 50_000_000;
    localparam MCNT = CLK/BPS;

    reg [15:0] clk_cnt;
    reg [3:0] bit_cnt;
    reg [7:0] rx_data_buf;
    reg rx_sig1, rx_sig2, start;

    always @(posedge clk) begin
        if (rst) begin
            rx_sig1 <= 1'b1;
            rx_sig2 <= 1'b1;
        end
        else begin
            rx_sig2 <= rx_sig1;
            rx_sig1 <= rx;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            clk_cnt <= 16'b0;
            bit_cnt <= 4'b0;
            rx_data <= 8'b0;
            rx_done <= 1'b0;
            rx_data_buf <= 8'b0;
            start <= 1'b0;
        end
        else begin
            rx_done <= 1'b0;
            if (!start) begin
                if (!rx_sig1 && rx_sig2) begin
                    start <= 1'b1;
                    clk_cnt <= CLK/BPS/2;
                    bit_cnt <= 4'b0;
                end
            end
            else begin
                if (clk_cnt < MCNT - 1) clk_cnt <= clk_cnt + 1;
                else begin
                    clk_cnt <= 16'b0;
                    if (bit_cnt <= 4'd8) begin
                        rx_data_buf <= {rx_sig1, rx_data_buf[7:1]};
                        bit_cnt <= bit_cnt + 1;
                    end
                    else if (bit_cnt == 4'd9) begin
                        rx_data <= rx_data_buf;
                        rx_done <= 1'b1;
                        start <= 1'b0;
                        bit_cnt <= 4'b0;
                    end
                end
            end
        end
    end
endmodule
