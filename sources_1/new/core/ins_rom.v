`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/08/09 22:05:38
// Design Name:
// Module Name: ins_rom
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


module ins_rom(
    input wire clk, rst, flush1, flush_irq, stall,
    input wire [11:0] addr,
    output reg [31:0] inst_raw
    );

    // 指令由 tb 通过 $readmemh("ins_rom.hex") 层次引用载入，本模块不再内嵌程序。

    (* ram_style = "block" *) reg [31:0] mem [0:4095];
    
    initial 
        $readmemh("E:/Vivado_Projects/project_self-try/project_self-try.srcs/ins_rom.hex", mem);

    localparam NOP = 6'b01_0100;

    always @(posedge clk) begin
        if (rst || flush1 || flush_irq) begin
            inst_raw <= {NOP, 26'b0};
        end
        else if (stall) begin
            inst_raw <= inst_raw;     
        end
        else begin
            inst_raw <=  mem[addr];
        end
    end
endmodule
