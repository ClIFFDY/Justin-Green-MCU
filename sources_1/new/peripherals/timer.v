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

    reg [7:0] cnt_set_h, cnt_set_l, cnt_h, cnt_l;
    reg irq_mode;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt_set_h = 8'b0;
            cnt_set_l = 8'b0;
            cnt_h = 8'b0;
            cnt_l = 8'b0;
            timer_irq = 1'b0;
            irq_mode = 1'b0;
        end
        else begin
            if (!irq_mode) timer_irq <= 0;
                if (bus_addr_in[15:13] == 3'b011 && bus_sig_in[0]) begin
                cnt_h <= 8'b0;
                cnt_l <= 8'b0;
                case (bus_addr_in[12:0])
                13'd0: begin
                    cnt_set_l <= bus_data_in;
                end
                13'd1: begin
                    cnt_set_h <= bus_data_in;
                end
                13'd2: begin
                    irq_mode <= bus_data_in[0];
                end
                default: begin
                    if (irq_mode && timer_irq) begin
                    cnt_h <= cnt_h;
                    cnt_l <= cnt_l;
                    timer_irq <= 1'b0;                   
                    end
                end
                endcase
            end
            else if (cnt_set_h != 8'd0 || cnt_set_l != 8'd0) begin
                cnt_l <= cnt_l + 1;
                if (cnt_l == 8'd255) cnt_h <= cnt_h + 1;
                if (cnt_l == cnt_set_l && cnt_h == cnt_set_h) begin
                    timer_irq <= 1'b1;
                    cnt_h <= 8'd0;
                    cnt_l <= 8'd0;
                end
            end
        end
    end
endmodule
