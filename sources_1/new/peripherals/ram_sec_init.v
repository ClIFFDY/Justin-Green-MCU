`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/19 23:33:23
// Design Name: 
// Module Name: ram_sec_init
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


module ram_sec_init(
    input wire clk,
    input wire ram_sec,
    input wire mode,
    input wire [11:0] sec_addr_in,
    input wire [7:0] bus_data_in,
    output reg [7:0] sec_data_out
    );

    (* ram_style = "block" *) reg [7:0] mem [0:4095];

    integer i;
    initial begin
        $readmemh("E:/Vivado_Projects/project_self-try/project_self-try.srcs/data.hex", mem);
    end

    always @(posedge clk) begin
        sec_data_out <= 8'b0;
        if (ram_sec) begin
            if (mode) begin
                mem[sec_addr_in] <= bus_data_in;
            end
            else begin
                sec_data_out <= mem[sec_addr_in];
            end
        end
    end
endmodule
