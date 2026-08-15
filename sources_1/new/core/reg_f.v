`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/09 22:05:38
// Design Name: 
// Module Name: reg_f
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


module reg_f(
    input wire clk, rst,
    input wire we, tx_busy,
    input wire [1:0] jmpflg,
    input wire [23:0] addr_r12,
    input wire [7:0] rd,
    input wire [8:0] ra_in,
    input wire [7:0] rd_data,
    output wire [1:0] j_flag,
    output wire [8:0] ra,
    output wire [23:0] rd12_data
    );

    reg [7:0] regs [0:255];
    reg [8:0] rad [0:255];

    integer i;
    reg [8:0] j;

    initial begin
        for (i = 0; i < 64; i = i + 1) regs[i] = 8'b0;
        for (i = 0; i < 16; i = i + 1) rad[i] = 8'b0;
        j = 9'b0;
    end

    wire [7:0] r_ram = addr_r12[23:16];
    wire [7:0] r1 = addr_r12[15:8];
    wire [7:0] r2 = addr_r12[7:0];

    assign rd12_data[23:16] = (r_ram == 8'b0) ? 0 : regs[r_ram];
    assign rd12_data[15:8] = (r1 == 8'b0) ? 0 : regs[r1];
    assign rd12_data[7:0] = (r2 == 8'b0) ? 0 : regs[r2];

    assign ra = rad[j - 1];
    assign j_flag[1] = (j == 8'd255) ? 1'b1 : 1'b0;
    assign j_flag[0] = (j == 8'b0) ? 1'b1 : 1'b0;


    always @(posedge clk or posedge rst) begin
        if (rst) begin 
            for (i = 0; i < 256; i = i + 1) begin 
                regs[i] <= 8'b0;
                rad[i] <= 8'b0;
            end
            j <= 8'b0;
        end
        else begin
            regs[255] <= {7'b0, tx_busy};

            if (we && rd != 0) regs[rd] <= rd_data;

            if (jmpflg[1] && ra_in != 0) begin
                rad[j] <= ra_in;      
                j <= j + 1;
            end
            else if (jmpflg[0] && j != 9'b0) begin
                rad[j - 1] <= 9'b0;
                j <= j - 1;
            end           
        end
    end
endmodule
