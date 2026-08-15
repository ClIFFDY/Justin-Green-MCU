`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/16 04:05:06
// Design Name: 
// Module Name: ram_sec
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


module ram_sec(
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
        for (i = 0; i < 4096; i = i + 1) mem[i] = 8'b0;
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
