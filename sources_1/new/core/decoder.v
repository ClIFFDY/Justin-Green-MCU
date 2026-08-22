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
    input wire [31:0] inst_raw,
    input wire [7:0] result_last_in, rd_data, rd_last1, rd_last2, baseline, 
    input wire [23:0] rd12_data,
    input wire [1:0] j_flag,
    output reg [15:0] r12_data,
    output wire [5:0] opcode,
    output reg [7:0] imm8, rd_out,
    output reg [15:0] bytmov,
    output reg frz, we, flush1, iret, irq_en,

    output reg [15:0] bus_addr_out,
    output reg [7:0] bus_data_out,
    output reg [3:0] bus_sig_out
    );
   
    localparam [5:0]
    HALT  = 6'b00_0000,//01
    ADDI  = 6'b00_0001,//11
    ADD   = 6'b00_0010,//11
    SUBI  = 6'b00_0011,//11
    SUB   = 6'b00_0100,//11
    AND   = 6'b00_0101,//11
    OR    = 6'b00_0110,//11
    XOR   = 6'b00_0111,//11
    LJAL  = 6'b00_1000,
    RJAL  = 6'b00_1001,
    ANDI  = 6'b00_1010,//11
    ORI   = 6'b00_1011,//11
    XORI  = 6'b00_1100,//11
    SLL   = 6'b00_1101,//11
    SRL   = 6'b00_1110,//11
    SLLI  = 6'b00_1111,//11
    SRLI  = 6'b01_0000,//11
    SLTU  = 6'b01_0001,//11
    SLTIU = 6'b01_0010,//11
    JALR  = 6'b01_0011,
    NOP   = 6'b01_0100,//01
    IRET  = 6'b01_0101,//01
    LBEQ  = 6'b01_0110,
    RBEQ  = 6'b01_0111,
    LBNE  = 6'b01_1000,
    RBNE  = 6'b01_1001,
    LBLTU = 6'b01_1010,
    RBLTU = 6'b01_1011,
    LBU   = 6'b01_1100,
    SB    = 6'b01_1101,
    SBI   = 6'b01_1110,
    LIND  = 6'b01_1111,
    SIND  = 6'b10_0000;

    assign opcode = inst_raw[31:26];
    wire [7:0] r_bus_raw = inst_raw[23:16];
    wire [7:0] r1_raw = (opcode >= 6'b010110 && opcode <= 6'b011011) ? inst_raw[7:4] : inst_raw[15:8];
    wire [7:0] r2_raw = (opcode >= 6'b010110 && opcode <= 6'b011011) ? inst_raw[3:0] : inst_raw[7:0];

    wire [7:0] r_bus = r_bus_raw + ((r_bus_raw < 8'd253) ? baseline : 8'd0);
    wire [7:0] r1 = r1_raw + ((r1_raw < 8'd253) ? baseline : 8'd0);
    wire [7:0] r2 = r2_raw + ((r2_raw < 8'd253) ? baseline : 8'd0);


    wire [7:0] bus_data_imm = (r_bus == rd_last2)? rd_data : rd12_data[23:16];
    wire [7:0] r1_data_imm = (r1 == rd_last2)? rd_data : rd12_data[15:8];
    wire [7:0] r2_data_imm = (r2 == rd_last2)? rd_data : rd12_data[7:0];
    
    wire [7:0] bus_data_final = (rd_last1 != 8'b0 && r_bus == rd_last1)?result_last_in : bus_data_imm;
    wire [7:0] r1_data_final = (rd_last1 != 8'b0 && r1 == rd_last1)? result_last_in : r1_data_imm;
    wire [7:0] r2_data_final = (rd_last1 != 8'b0 && r2 == rd_last1)? result_last_in : r2_data_imm;


    always @(*) begin
        if (rst) begin
            irq_en = 1'b1;
            bytmov = 16'b0;
            r12_data = 16'b0;
            rd_out = 8'd0;
            imm8 = 8'b0;
            frz = 1'b0;
            we = 1'b0;
            iret = 1'b0;
            flush1 = 1'b0;
            bus_addr_out = 16'b0;
            bus_data_out = 8'b0;
            bus_sig_out = 4'b0;
        end
        else begin
            irq_en = 1'b1;
            bytmov = 16'b0;
            r12_data = {r1_data_final, r2_data_final};
            rd_out = inst_raw[23:16] + ((inst_raw[23:16] < 8'd253) ? baseline : 8'd0);
            imm8 = 8'b0;
            frz = 1'b0;
            we  = 1'b0;
            iret = 1'b0;
            flush1 = 1'b0;
            bus_addr_out = 16'b0;
            bus_data_out = bus_data_final;
            bus_sig_out = 4'b0;
            case (inst_raw[31:26])
            LBU: begin
                bus_addr_out = inst_raw[15:0];
                we = 1'b1;
                bus_sig_out[0] = 1'b0;
            end
            LIND: begin
                bus_addr_out = {r1_data_final, r2_data_final};
                we = 1'b1;
                bus_sig_out[0] = 1'b0;
            end
            SB: begin
                bus_addr_out = inst_raw[15:0];
                bus_sig_out[0] = 1'b1;
            end
            SBI: begin
                bus_data_out = inst_raw[23:16];
                bus_addr_out = inst_raw[15:0];
                bus_sig_out[0] = 1'b1;
            end
            SIND: begin
                bus_addr_out = {r1_data_final, r2_data_final};
                bus_sig_out[0] = 1'b1;
            end
            LJAL, RJAL: begin
                irq_en = 1'b0;
                bytmov = inst_raw[23:8];
                if (!j_flag[1]) begin
                    flush1 = 1'b1;
                end
            end
            LBEQ, RBEQ: begin
                irq_en = 1'b0;
                if (r1_data_final == r2_data_final) begin
                    bytmov = inst_raw[23:8];
                    flush1 = 1'b1;
                end             
            end
            LBNE, RBNE: begin
                irq_en = 1'b0;
                if (r1_data_final != r2_data_final) begin
                    bytmov = inst_raw[23:8];
                    flush1 = 1'b1;
                end
            end
            LBLTU, RBLTU: begin
                irq_en = 1'b0;
                if (r1_data_final < r2_data_final) begin
                    bytmov = inst_raw[23:8];
                    flush1 = 1'b1;
                end
            end
            ADD, SUB, AND, OR, XOR, SLL, SRL, SLTU: begin
                we = 1'b1;
            end
            ADDI, SUBI, ANDI, ORI, XORI, SLLI, SRLI, SLTIU: begin
                imm8 = inst_raw[7:0];
                we = 1'b1;
            end
            JALR: begin
                irq_en = 1'b0;
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
