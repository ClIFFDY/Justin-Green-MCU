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
    input wire clk, rst, frz, stall_bus, cstall, irq_flag,
    input wire [1:0] stage,
    input wire [1:0] j_flag,
    input wire [5:0] op_raw,
    input wire [15:0] bytmov,
    input wire [11:0] ra_in, irq_addr,
    output reg [11:0] pc_addr,
    output reg [11:0] ra,
    output reg [1:0] jmpflg
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
    RBLTU = 6'b01_1011,
    IRET  = 6'b01_0101;

    
    always @(posedge clk or posedge rst) begin
        if (rst) begin 
            pc_addr <= 10'b0;
            ra <= 10'b0;
            jmpflg <= 2'b0;
        end
        else if (stage == EXE && !stall_bus) begin
            jmpflg <= 2'b0;
            case (op_raw)
            LJAL, RJAL: begin 
                if (bytmov != 16'b0 && !j_flag[1]) begin
                    ra <= pc_addr - 1;
                    jmpflg[1] <= 1'b1;
                    case (op_raw[0])
                    1'b0: pc_addr <= pc_addr - bytmov;
                    1'b1: pc_addr <= pc_addr + bytmov;
                    endcase                
                end
                else begin
                    if(!frz && !cstall) begin
                        pc_addr <= pc_addr + 1;
                    end
                end
            end
            LBEQ, RBEQ, LBNE, RBNE, LBLTU, RBLTU: begin
                if (bytmov != 16'b0) begin
                    case (op_raw[0])
                    1'b0: pc_addr <= pc_addr - bytmov;
                    1'b1: pc_addr <= pc_addr + bytmov;
                    endcase                
                end
                else begin
                    if(!frz && !cstall) begin
                        pc_addr <= pc_addr + 1;
                    end
                end                
            end
            JALR: begin
                jmpflg[0] <= 1'b1;
                if (!j_flag[0]) begin 
                    pc_addr <= ra_in;
                end
                else begin 
                    if (!frz && !cstall) pc_addr <= pc_addr + 1;
                end
            end
            default: begin
                if(!frz && !cstall) begin
                    pc_addr <= pc_addr + 1;
                end
            end
            endcase
            if (irq_flag) pc_addr <= irq_addr;
        end
    end
endmodule
