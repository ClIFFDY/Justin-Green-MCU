`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/09 22:05:38
// Design Name: 
// Module Name: pc
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


module pc(
    input wire clk, rst, frz, stall, cstall, cstalled, irq_flag, jmp_flush,
    input wire [1:0] stage,
    input wire [1:0] j_flag,
    input wire [5:0] op_raw,
    input wire [15:0] bytmov,
    input wire [12:0] ra_in, irq_addr,
    output reg [12:0] pc_addr,
    output reg [12:0] ra,
    output reg [1:0] jmpflg,
    output reg [1:0] bubble
    );

    localparam
    IDLE = 2'b00,
    EXE = 2'b01,
    WAIT = 2'b10;

    localparam [5:0]
    LJAL  = 6'b00_1000,
    RJAL  = 6'b00_1001,
    JALR  = 6'b01_0011,
    LBEQ  = 6'b01_0110,
    RBEQ  = 6'b01_0111,
    LBNE  = 6'b01_1000,
    RBNE  = 6'b01_1001,
    LBLTU = 6'b01_1010,
    RBLTU = 6'b01_1011;

    always @(posedge clk) begin
        if (rst) begin
            pc_addr <= 13'b0;
            ra <= 13'b0;
            jmpflg <= 2'b0;
            bubble <= 2'b0;
        end
        else if (stage == EXE && !stall) begin
            jmpflg <= 2'b0;
            bubble <= (bubble != 2'd0) ? bubble - 2'd1 : 2'd0;
            if (irq_flag) begin
                pc_addr <= irq_addr;
                bubble <= 2'd2;
            end
            else if (frz) begin
            end
            else begin
                case (op_raw)
                LJAL, RJAL: begin
                    if (jmp_flush && !j_flag[1]) begin
                        ra <= pc_addr - ((cstalled) ? 1 : 2);
                        jmpflg[1] <= 1'b1;
                        bubble <= 2'd2;
                        pc_addr <= op_raw[0] ? pc_addr + bytmov : pc_addr - bytmov;
                    end
                    else if (!cstall) begin
                        pc_addr <= pc_addr + 1'b1;
                    end 
                end
                LBEQ, RBEQ, LBNE, RBNE, LBLTU, RBLTU: begin
                    if (jmp_flush) begin 
                        bubble <= 2'd2;
                        pc_addr <= op_raw[0] ? pc_addr + bytmov : pc_addr - bytmov;
                    end
                    else if (!cstall) pc_addr <= pc_addr + 1'b1;
                end
                JALR: begin
                    jmpflg[0] <= 1'b1;
                    if (!j_flag[0]) begin
                        bubble <= 2'd2;
                        pc_addr <= ra_in;
                    end
                    else if (!cstall) pc_addr <= pc_addr + 1'b1;
                end
                default: if (!cstall) pc_addr <= pc_addr + 1'b1;
                endcase
            end
        end
    end
endmodule
