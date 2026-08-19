`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/12 00:18:11
// Design Name: 
// Module Name: id_reg
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


module id_reg(
    input wire clk, we_in, flush1, stall,
    input wire [1:0] stage,
    input wire [5:0] opcode_in, 
    input wire [7:0] rd_in,
    input wire [7:0] imm8_in, bus_data_in,
    input wire [15:0] ab_raw_in,
    output reg [5:0] opcode,
    output reg [7:0] rd,
    output reg [15:0] ab_raw,
    output reg [7:0] imm8, bus_data,
    output reg we, flush2
    );

    always@(posedge clk) begin
        if (stage == 2'b01 && !stall) begin
            if (!flush1) begin
                opcode <= opcode_in;
                ab_raw <= ab_raw_in;
                rd <= (we_in)? rd_in : 8'b0;
                imm8 <= imm8_in;
                bus_data <= bus_data_in;
                we <= we_in;
                flush2 <= 1'b0;
            end
            else begin
                opcode <= opcode_in;
                ab_raw <= 15'b0;
                rd <= 8'b0;
                imm8 <= 8'b0;
                bus_data <= 8'b0;
                we <= 1'b0;
                flush2 <= 1'b1;
            end
        end
    end
endmodule