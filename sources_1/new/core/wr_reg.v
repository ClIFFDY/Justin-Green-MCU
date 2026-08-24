`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/12 00:18:11
// Design Name: 
// Module Name: wr_reg
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


module wr_reg(
    input wire clk, we_in, rst, stall,
    input wire [1:0] stage,
    input wire [7:0] result_in,
    input wire [7:0] rd_in,
    output reg [7:0] rd_data,
    output reg [7:0] rd,
    output reg we
    );

    always @(posedge clk) begin
        if (rst) begin
            rd <= 8'b0;
            rd_data <= 8'b0;
            we <= 1'b0;
        end
        else begin
            if (stage == 2'b01 && !stall && we_in) begin
                rd_data <= result_in;
                rd <= rd_in;
                we <= we_in;
            end
            else if (stage == 2'b01 && stall && we_in) begin
                rd_data <= rd_data;
                rd <= rd;
                we <= we;
            end
            else begin
                rd_data <= 8'b0;
                rd <= 8'b0;
                we <= 1'b0;
            end
        end
    end

endmodule

