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
    output reg [31:0] inst_raw,
    output reg cstall
    );

    reg cstalled;
    reg [15:0] inst_raw_l;
    localparam NOP = 6'b01_0100;

    always @(posedge clk) begin
        if (rst) begin
            inst_raw <= {NOP, 26'b0};
            cstalled <= 1'b0;
            inst_raw_l <= 16'b0;
        end
        else if (stall) begin
            inst_raw <= inst_raw;
        end
        else begin
            if (stage == 2'b01 && !flush1 && !stall) begin
                inst_raw_l <= 16'b0;
                if (cstall) begin
                    cstalled <= 1'b1;
                    inst_raw_l <= inst_raw_in[15:0];
                    if (inst_raw_in[25]) 
                        inst_raw = {inst_raw_in[31:24], 6'b0, inst_raw_in[23:22],
                                    5'b0, inst_raw_in[21:19], 5'b0, inst_raw_in[18:16]};
                    else inst_raw = {inst_raw_in[31:16], 16'b0};
                end
                else if (cstalled) begin
                    cstalled <= 1'b0;
                    if (inst_raw_l[9]) 
                        inst_raw = {inst_raw_l[15:8], 6'b0, inst_raw_l[7:6], 5'b0,
                                    inst_raw_l[5:3], 5'b0, inst_raw_l[2:0]};
                    else inst_raw = {inst_raw_l[15:0], 16'b0};
                end
                else begin
                    inst_raw <= inst_raw_in;
                end
            end
            else begin
                inst_raw <= {NOP, 26'b0};
            end          
        end
    end

    always @(*) begin
        cstall = 1'b0;
        if (rst) cstall = 1'b0;
        if (inst_raw_in[25:24] != 2'b0 && inst_raw_in[9:8] != 2'b0 && !cstalled) begin
            cstall = 1'b1;
        end
    end
endmodule
