`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/14 19:37:44
// Design Name: 
// Module Name: timer
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


module timer(
    input wire clk, rst,
    input wire [15:0] bus_addr_in,
    input wire [7:0] bus_data_in,
    input wire [3:0] bus_sig_in,
    output reg timer_irq
    );

    reg [7:0] cnt_set [0:3];
    reg [7:0] cnt [0:3];
    reg irq_mode;
    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < 4; i = i + 1) begin 
                cnt_set[i] <= 8'b0;
                cnt[i] <= 8'b0;
            end
            timer_irq <= 1'b0;
            irq_mode <= 1'b0;
        end
        else begin
            if (!irq_mode) timer_irq <= 0;
            if (bus_addr_in[15:13] == 3'b011 && bus_sig_in[0]) begin
                for (i = 0; i < 4; i = i + 1) cnt[i] <= 8'b0;
                if (bus_addr_in[12:0] <= 13'd3) begin
                    cnt_set[bus_addr_in[12:0]] <= bus_data_in;
                end
                else if (bus_addr_in[12:0] == 13'd4) begin
                    irq_mode <= bus_data_in[0];
                end
                else if (bus_addr_in[12:0] == 13'd5) begin
                     if (irq_mode && timer_irq) timer_irq <= 1'b0;
                end
            end
            else if (cnt_set[0] != 8'd0 || cnt_set[1] != 8'd0 
            || cnt_set[2] != 8'd0 || cnt_set[3] != 8'd0) begin
                cnt[0] <= cnt[0] + 1;
                if (cnt[0] == 8'd255) cnt[1] <= cnt[1] + 1;
                if (cnt[0] == 8'd255 && cnt[1] == 8'd255) cnt[2] <= cnt[2] + 1;
                if (cnt[0] == 8'd255 && cnt[1] == 8'd255 && cnt[2] == 8'd255) cnt[3] <= cnt[3] + 1;
                if (cnt_set[0] == cnt[0] && cnt_set[1] == cnt[1]
                && cnt_set[2] == cnt[2] && cnt_set[3] == cnt[3]) begin
                    timer_irq <= 1'b1;
                    for (i = 0; i < 4; i = i + 1) cnt[i] <= 8'd0;
                end
            end
        end
    end
endmodule
