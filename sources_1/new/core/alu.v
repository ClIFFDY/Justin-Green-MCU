`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/09 22:05:38
// Design Name: 
// Module Name: alu
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


module alu(
    input wire [15:0] ab_raw,
    input wire [7:0] bus_data,
    input wire [7:0] imm8,
    input wire [5:0] opcode, 
    output reg [7:0] result
    );

    localparam [5:0] 
    ADDI = 6'b00_0001,
    ADD  = 6'b00_0010,
    SUBI = 6'b00_0011,
    SUB  = 6'b00_0100,
    AND  = 6'b00_0101,
    OR   = 6'b00_0110,
    XOR  = 6'b00_0111,
    ANDI = 6'b00_1010,
    ORI  = 6'b00_1011,
    XORI = 6'b00_1100,
    SLL =  6'b00_1101,
    SRL =  6'b00_1110,
    SLLI = 6'b00_1111,
    SRLI = 6'b01_0000,
    SLTU = 6'b01_0001,
    SLTIU = 6'b01_0010,
    LBU  = 6'b01_1100,
    LIND = 6'b01_1111;

    wire [7:0] a, b;

    assign a = ab_raw[15:8];
    assign b = ab_raw[7:0];
    
    always @(*) begin
        if (opcode == LBU || opcode == LIND) result = bus_data;
        else begin
            case(opcode)
            ADDI: result = a + imm8;
            ADD: result = a + b;
            SUBI:result = a - imm8;
            SUB: result = a - b;
            AND: result = a & b;
            OR: result = a | b;
            XOR: result = a ^ b;
            ANDI: result = a & imm8;
            ORI: result = a | imm8;
            XORI: result = a ^ imm8;
            SLL: result = a << b;
            SRL: result = a >> b;
            SLLI: result = a << imm8;
            SRLI: result = a >> imm8;
            SLTU: result = (a < b) ? 8'b1 : 8'b0;
            SLTIU: result = (a < imm8) ? 8'b1 : 8'b0;
            default: result = 8'b0;
            endcase            
        end
    end
endmodule
