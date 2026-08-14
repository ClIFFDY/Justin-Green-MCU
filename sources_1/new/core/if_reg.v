`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/12 00:06:14
// Design Name: 
// Module Name: if_reg
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


module if_reg(
    input wire clk, rst, flush1, stall,
    input wire [1:0] stage,
    input wire [31:0] inst_raw_in,
    output reg [31:0] inst_raw
    );

    localparam NOP = 6'b01_0100;

    always @(posedge clk) begin
        if (rst) inst_raw <= {NOP, 26'b0};
        else if (stall) begin
            inst_raw <= inst_raw;
        end
        else begin
            if (stage == 2'b01 && !flush1 && !stall) begin
                inst_raw <= inst_raw_in;
            end
            else begin
                inst_raw <= {NOP, 26'b0};
            end          
        end
    end
endmodule
