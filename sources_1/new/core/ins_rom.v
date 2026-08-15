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

    // 指令由 tb 通过 $readmemh("ins_rom.hex") 层次引用载入，本模块不再内嵌程序。

module ins_rom(
    input wire clk, rst, flush1, stall,
    input wire [1:0] stage,
    input wire [15:0] addr,
    output reg [39:0] inst_raw,
    output wire [1:0] inst_num
    );

    localparam NOP = 6'b01_0100;
    integer i;
 
    (* ram_style = "distributed" *) reg [7:0] mem [0:4095];
    initial begin
        for (i = 0; i < 4096; i = i + 1) mem[i] = 8'b0;
        $readmemh("E:/Vivado_Projects/project_self-try/project_self-try.srcs/ins_rom.hex", mem);
    end

    assign inst_num = mem[addr][1:0];

    always @(posedge clk) begin
        if (rst) inst_raw <= {NOP, 34'b0};
        else if (stall) begin
            inst_raw <= inst_raw;
        end
        else begin
            if (stage == 2'b01 && !flush1 && !stall) begin
                inst_raw <= {mem[addr], mem[addr + 1], mem[addr + 2], mem[addr + 3], mem[addr + 4]};
            end
            else begin
                inst_raw <= {NOP, 34'b0};
            end
        end
    end
endmodule

