`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/19 07:37:43
// Design Name: 
// Module Name: pre_decoder
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


module pre_decoder(
    input wire clk, rst, flush1, flush_irq, stall,
    input wire [1:0] stage,
    input wire [31:0] inst_raw_in,
    output reg [31:0] inst_raw,
    output reg cstall,
    output reg irq_en,
    output reg [23:0] addr_dr12
    );

    reg cstalled;
    reg [15:0] inst_raw_l;
    localparam NOP = 6'b01_0100;
    localparam [5:0]
        LBEQ  = 6'b01_0110,
        RBEQ  = 6'b01_0111,
        LBNE  = 6'b01_1000,
        RBNE  = 6'b01_1001,
        LBLTU = 6'b01_1010,
        RBLTU = 6'b01_1011;

    always @(posedge clk) begin
        if (rst) begin
            inst_raw <= {NOP, 26'b0};
            cstalled <= 1'b0;
            inst_raw_l <= 16'b0;
            irq_en <= 1'b1;
        end
        else if (stall) begin
            inst_raw <= inst_raw;
        end
        else begin
            if (stage == 2'b01 && !flush1 && !flush_irq && !stall) begin
                irq_en <= 1'b1;
                inst_raw_l <= 16'b0;
                if (cstall) begin
                    cstalled <= 1'b1;
                    inst_raw_l <= inst_raw_in[15:0];
                    irq_en <= 1'b0;
                    if (inst_raw_in[25]) 
                        inst_raw <= {inst_raw_in[31:24], 6'b0, inst_raw_in[23:22],
                                    5'b0, inst_raw_in[21:19], 5'b0, inst_raw_in[18:16]};
                    else inst_raw <= {inst_raw_in[31:16], 16'b0};
                end
                else if (cstalled) begin
                    irq_en <= 1'b1;
                    cstalled <= 1'b0;
                    if (inst_raw_l[9]) 
                        inst_raw <= {inst_raw_l[15:8], 6'b0, inst_raw_l[7:6], 5'b0,
                                    inst_raw_l[5:3], 5'b0, inst_raw_l[2:0]};
                    else inst_raw <= {inst_raw_l[15:0], 16'b0};
                end
                else begin
                    inst_raw <= inst_raw_in;
                    irq_en <= 1'b1;
                end
            end
            else begin
                irq_en <= 1'b0;
                inst_raw <= {NOP, 26'b0};
            end          
        end
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