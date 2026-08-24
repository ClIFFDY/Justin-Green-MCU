`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/22 06:33:28
// Design Name: 
// Module Name: rpu
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


module rpu(
    input wire clk, rst, jmp_flush, stall, irq_flush,
    input wire [1:0] stage,
    input wire [5:0] opcode_in,
    input wire [25:0] inst_raw_cont_in,
    input wire [23:0] addr_r12_raw,
    output reg [5:0] opcode, opcode_to_pc,
    output reg [25:0] inst_raw_cont,
    output reg [15:0] bytmov_to_pc,
    output reg [23:0] addr_r12_mov,
    output reg [7:0] baseline,
    //
    input wire [15:0] bus_addr_in,
    input wire [3:0] bus_sig_in,
    output reg [7:0] bus_data_out
    );

    localparam [3:0]
    BASEL = 4'b1101;

    localparam NOP = 6'b00_0000;
    localparam [5:0]
        SBI   = 6'b01_1110,

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
            addr_r12_mov <= 24'b0;
            baseline <= 8'b0;
        end
        else if (stage == 2'b01) begin
            if (jmp_flush) begin
                addr_r12_mov <= addr_r12_mov;
                baseline <= baseline;
            end
            else if (opcode_in == SBI && inst_raw_cont_in[15:12] == BASEL) begin
                baseline <= inst_raw_cont_in[23:16];
                addr_r12_mov <= {addr_r12_raw[23:16] + ((addr_r12_raw[23:16] < 8'd253) ? inst_raw_cont_in[23:16] : 8'd0),
                            addr_r12_raw[15:8] + ((addr_r12_raw[15:8] < 8'd253) ? inst_raw_cont_in[23:16] : 8'd0),
                            addr_r12_raw[7:0] + ((addr_r12_raw[7:0] < 8'd253) ? inst_raw_cont_in[23:16] : 8'd0)};
            end
            else if (stall) begin
                addr_r12_mov <= addr_r12_mov;
                baseline <= baseline;
            end
            else begin
                addr_r12_mov <= {addr_r12_raw[23:16] + ((addr_r12_raw[23:16] < 8'd253) ? baseline : 8'd0),
                                addr_r12_raw[15:8] + ((addr_r12_raw[15:8] < 8'd253) ? baseline : 8'd0),
                                addr_r12_raw[7:0] + ((addr_r12_raw[7:0] < 8'd253) ? baseline : 8'd0)};
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            opcode <= NOP;
            opcode_to_pc <= NOP;
            inst_raw_cont <= 26'b0;
            bytmov_to_pc <= 16'b0;
        end
        else if (stage == 2'b01) begin
            if (jmp_flush) begin
                opcode <= NOP;
                opcode_to_pc <= NOP;
                inst_raw_cont <= 26'b0;
                bytmov_to_pc <= 16'b0;
            end
            else if (irq_flush) begin
                opcode <= NOP;
                opcode_to_pc <= NOP;
                inst_raw_cont <= 26'b0;
                bytmov_to_pc <= 16'b0;
            end
            else if (!stall) begin
                opcode <= opcode_in;
                opcode_to_pc <= opcode_in;
                inst_raw_cont <= inst_raw_cont_in;
                bytmov_to_pc <= inst_raw_cont_in[23:8];
            end
            else begin
                opcode <= opcode;
                opcode_to_pc <= opcode_to_pc;
                inst_raw_cont <= inst_raw_cont;
                bytmov_to_pc <= 16'b0;
            end
        end
    end

    always @(*) begin
        if (rst) bus_data_out = 8'b0;
        else if (bus_addr_in[15:12] == BASEL && !bus_sig_in[0]) begin
            bus_data_out = baseline;
        end 
        else bus_data_out = 8'b0;
    end

endmodule
