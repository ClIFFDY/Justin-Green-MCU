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
    input wire clk, we_in, flush2, rst, stall,
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
        else if (!stall) begin
            if (stage == 1'b1 && !flush2) begin
                rd_data <= result_in;
                rd <= (we_in)? rd_in : 8'b0;
                we <= we_in;
            end
            else begin
                rd_data <= 8'b0;
                rd <= 8'b0;
                we <= 1'b0;
            end
        end
    end

endmodule

