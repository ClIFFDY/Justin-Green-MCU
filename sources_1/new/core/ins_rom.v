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
    input wire [7:0] addr,
    output wire [31:0] inst_raw,
    output wire [1:0] inst_num
    );

    // 指令由 tb 通过 $readmemh("ins_rom.hex") 层次引用载入，本模块不再内嵌程序。
    // 但综合时 tb 不存在、ROM 是空数组 → opcode 恒 0（HALT）→ 整机被常量传播成死逻辑。
    // 这里加 initial $readmemh：Vivado 综合支持用 $readmemh 初始化 ROM，
    // 综合出的 ROM 会带真实程序内容，数据通路才有活动、逻辑才不被优化掉。
    reg [7:0] mem [0:511];
    initial $readmemh("E:/Vivado_Projects/project_self-try/project_self-try.srcs/ins_rom.hex", mem);

    assign inst_num = mem[addr][1:0];
    assign inst_raw = {mem[addr], mem[addr + 1], mem[addr + 2], mem[addr + 3]};

endmodule
