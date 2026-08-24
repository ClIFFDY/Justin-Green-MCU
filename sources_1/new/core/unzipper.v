`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/22 22:22:43
// Design Name: 
// Module Name: unzipper
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


module unzipper(
    input wire clk, rst, jmp_flush, irq_flush, stall,
    input wire [1:0] stage,
    input wire [31:0] inst_raw_in,
    output reg [25:0] inst_raw_cont,
    output reg [5:0] opcode,
    output reg cstall, cstalled,
    output reg irq_en,
    output reg [23:0] addr_dr12
    );

    reg post_stalled;
    reg [15:0] inst_raw_l;
    localparam NOP = 6'b00_0000;
    localparam [5:0]
        JALR  = 6'b01_0011,
        LJAL  = 6'b00_1000,
        RJAL  = 6'b00_1001,

        LBEQ  = 6'b01_0110,
        RBEQ  = 6'b01_0111,
        LBNE  = 6'b01_1000,
        RBNE  = 6'b01_1001,
        LBLTU = 6'b01_1010,
        RBLTU = 6'b01_1011;

    always @(posedge clk) begin
        if (rst) begin
            opcode <= NOP;
            inst_raw_cont <= 26'b0;
            cstalled <= 1'b0;
            post_stalled <= 1'b0;
            inst_raw_l <= 16'b0;
        end
        else begin
            if (stage == 2'b01) begin
                if (jmp_flush) begin
                    opcode <= NOP;
                    inst_raw_cont <= 26'b0;
                    cstalled <= 1'b0;
                    post_stalled <= 1'b0;
                    inst_raw_l <= 16'b0;
                end
                else if (irq_flush) begin
                    opcode <= NOP;
                    inst_raw_cont <= 26'b0;
                    cstalled <= 1'b0;
                    post_stalled <= 1'b0;
                    inst_raw_l <= 16'b0;
                end
                else if (!stall) begin
                    inst_raw_l <= 16'b0;
                    post_stalled <= 1'b0;
                    if (cstall) begin
                        cstalled <= 1'b1;
                        inst_raw_l <= inst_raw_in[15:0];
                        opcode <= inst_raw_in[31:26];
                        if (inst_raw_in[25]) begin
                            inst_raw_cont <= {inst_raw_in[25:24], 6'b0, inst_raw_in[23:22],
                                            5'b0, inst_raw_in[21:19], 5'b0, inst_raw_in[18:16]};
                        end
                        else inst_raw_cont <= {inst_raw_in[25:16], 16'b0};
                    end
                    else if (cstalled) begin
                        cstalled <= 1'b0;
                        post_stalled <= 1'b1;
                        opcode <= inst_raw_l[15:10];
                        if (inst_raw_l[9]) begin
                            inst_raw_cont <= {inst_raw_l[9:8], 6'b0, inst_raw_l[7:6], 5'b0,
                                            inst_raw_l[5:3], 5'b0, inst_raw_l[2:0]};
                        end
                        else inst_raw_cont <= {inst_raw_l[9:0], 16'b0};
                    end
                    else begin
                        opcode <= inst_raw_in[31:26];
                        inst_raw_cont <= inst_raw_in[25:0];
                    end
                end
                else begin
                    opcode <= opcode;
                    inst_raw_cont <= inst_raw_cont;
                end
            end
            else begin
                opcode <= NOP;
                inst_raw_cont <= 26'b0;
            end       
        end
    end

    always @(*) begin
        if (rst) irq_en = 1'b0;
        else irq_en = !post_stalled;
    end

    always @(*) begin
        cstall = 1'b0;
        addr_dr12 = 24'b0;
        if (rst) cstall = 1'b0;
        if (!stall) begin
            if (inst_raw_in[25:24] != 2'b0 && inst_raw_in[9:8] != 2'b0 && !cstalled) begin
                cstall = 1'b1;
            end
            if (cstall) begin
                addr_dr12 = {6'b0, inst_raw_in[23:22], 5'b0, inst_raw_in[21:19], 5'b0, inst_raw_in[18:16]};
            end
            else if (cstalled) begin
                addr_dr12 = {6'b0, inst_raw_l[7:6], 5'b0, inst_raw_l[5:3], 5'b0, inst_raw_l[2:0]};
            end
            else begin
                if (inst_raw_in[31:26] >= 6'b01_0110 && inst_raw_in[31:26] <= 6'b01_1011)
                    addr_dr12[15:0] = {4'b0, inst_raw_in[7:4], 4'b0, inst_raw_in[3:0]};
                else
                    addr_dr12 = inst_raw_in[23:0];
            end
        end
    end

endmodule
