`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/10 12:51:25
// Design Name: 
// Module Name: decoder
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


module decoder(
    input wire rst, irq_flush,
    input wire [39:0] inst_raw,
    input wire [7:0] result_last_in, rd_last1, rd_last2, 
    input wire [23:0] rd12_data,
    input wire [7:0] rd_data,
    input wire [1:0] j_flag,
    output reg [23:0] addr_dr12,
    output reg [15:0] r12_data,
    output wire [5:0] opcode,
    output reg [7:0] imm8,
    output reg [15:0] bytmov,
    output reg frz, we, flush1, iret,

    output reg [15:0] bus_addr_out,
    output reg [7:0] bus_data_out,
    output reg [3:0] bus_sig_out
    );
   
    localparam [5:0]
    HALT  = 6'b00_0000,
    ADDI  = 6'b00_0001,
    ADD   = 6'b00_0010,
    SUBI  = 6'b00_0011,
    SUB   = 6'b00_0100,
    AND   = 6'b00_0101,
    OR    = 6'b00_0110,
    XOR   = 6'b00_0111,
    LJAL  = 6'b00_1000,
    RJAL  = 6'b00_1001,
    ANDI  = 6'b00_1010,
    ORI   = 6'b00_1011,
    XORI  = 6'b00_1100,
    SLL   = 6'b00_1101,
    SRL   = 6'b00_1110,
    SLLI  = 6'b00_1111,
    SRLI  = 6'b01_0000,
    SLTU  = 6'b01_0001,
    SLTIU = 6'b01_0010,
    JALR  = 6'b01_0011,
    NOP   = 6'b01_0100,
    IRET  = 6'b01_0101,
    LBEQ  = 6'b01_0110,
    RBEQ  = 6'b01_0111,
    LBNE  = 6'b01_1000,
    RBNE  = 6'b01_1001,
    LBLTU = 6'b01_1010,
    RBLTU = 6'b01_1011,
    LBU   = 6'b01_1100,
    SB    = 6'b01_1101;
    
    assign opcode = inst_raw[39:34];
    wire [7:0] r_bus = inst_raw[31:24];
    wire [7:0] r1 = inst_raw[23:16];
    wire [7:0] r2 = inst_raw[15:8];

    wire [7:0] bus_data_imm = (r_bus == rd_last2) ? rd_data : rd12_data[23:16];
    wire [7:0] r1_data_imm = (r1 == rd_last2) ? rd_data : rd12_data[15:8];
    wire [7:0] r2_data_imm = (r2 == rd_last2) ? rd_data : rd12_data[7:0];

    wire [7:0] bus_data_final = (rd_last1 != 8'b0 && r_bus == rd_last1) ? result_last_in : bus_data_imm;
    wire [7:0] r1_data_final = (rd_last1 != 8'b0 && r1 == rd_last1) ? result_last_in : r1_data_imm;
    wire [7:0] r2_data_final = (rd_last1 != 8'b0 && r2 == rd_last1) ? result_last_in : r2_data_imm;

    always @(*) begin
        if (rst) begin
            bytmov = 16'b0;
            addr_dr12 = 24'b0;
            r12_data = 16'b0;
            imm8 = 8'b0;
            frz = 1'b0;
            we = 1'b0;
            flush1 = 1'b0;
            bus_addr_out = 16'b0;
            bus_data_out = 8'b0;
            bus_sig_out = 4'b0;
        end
        else begin
            bytmov = 16'b0;
            addr_dr12 = 24'b0;
            r12_data = {r1_data_final, r2_data_final};
            imm8   = 8'b0;
            frz    = 1'b0;
            we     = 1'b0;
            iret   = 1'b0;
            flush1 = irq_flush;
            bus_addr_out = 16'b0;
            bus_data_out = bus_data_final;
            bus_sig_out = 4'b0;
            case (inst_raw[39:34])
                LBU: begin
                    addr_dr12[23:16] = inst_raw[31:24];
                    bus_addr_out = inst_raw[23:8];
                    we = 1'b1;
                    bus_sig_out[0] = 1'b0;
                end
                SB: begin
                    addr_dr12[23:16] = inst_raw[31:24];
                    bus_addr_out = inst_raw[23:8];
                    bus_sig_out[0] = 1'b1;
                end
                LJAL, RJAL: begin
                    bytmov = {inst_raw[31:24], inst_raw[7:4]};
                    if (!j_flag[1]) begin
                        flush1 = 1'b1;
                    end
                end
                LBEQ, RBEQ: begin
                    addr_dr12[15:0] = inst_raw[23:8];
                    if (r1_data_final == r2_data_final) begin
                        bytmov = {inst_raw[31:24], inst_raw[7:4]};
                        flush1 = 1'b1;
                    end             
                end
                LBNE, RBNE: begin
                    addr_dr12[15:0] = inst_raw[23:8];
                    if (r1_data_final != r2_data_final) begin
                        bytmov = {inst_raw[31:24], inst_raw[7:4]};
                        flush1 = 1'b1;
                    end
                end
                LBLTU, RBLTU: begin
                    addr_dr12[15:0] = inst_raw[23:8];
                    if (r1_data_final < r2_data_final) begin
                        bytmov = {inst_raw[31:24], inst_raw[7:4]};
                        flush1 = 1'b1;
                    end
                end
                ADD, SUB, AND, OR, XOR, SLL, SRL, SLTU: begin
                    addr_dr12 = inst_raw[31:8];
                    we = 1'b1;
                end
                ADDI, SUBI, ANDI, ORI, XORI, SLLI, SRLI, SLTIU: begin
                    addr_dr12[23:8] = inst_raw[31:16];
                    imm8 = inst_raw[15:8];
                    we = 1'b1;
                end
                JALR: begin
                    if (!j_flag[0]) begin 
                        bytmov = 8'd1;
                        flush1 = 1'b1;
                    end
                end
                IRET: begin
                    flush1 = 1'b1;
                    iret = 1'b1;
                end
                HALT: begin
                    if (!rst) frz = 1'b1;
                end
                NOP: begin
                end
            endcase
        end
    end
endmodule