`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/12 20:40:27
// Design Name: 
// Module Name: data_ram
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


module data_ram(
    input wire clk,
    input wire [15:0] bus_addr_in,
    input wire [7:0] bus_data_in,
    input wire [3:0] bus_sig_in,
    output reg [7:0] bus_data_out,
    output wire stall_bus
    );

    (* ram_style = "block" *) reg [7:0] mem [0:8191];

    integer i;
    initial begin
        for (i = 0; i < 8192; i = i + 1) mem[i] = 8'b0;
    end

    reg done;
    wire access = (bus_addr_in[15:13] == 3'b001)? 1'b1 : 1'b0;
    assign stall_bus = access && !done;

    always @(posedge clk) begin
        done <= 1'b0;
        bus_data_out <= 8'b0;
        if (bus_addr_in[15:13] == 3'b001) begin
            done <= ~done;
            if (bus_sig_in[0]) begin
                mem[bus_addr_in[12:0]] <= bus_data_in;
            end
            else begin
                bus_data_out <= mem[bus_addr_in[12:0]]; 
            end
        end
    end
endmodule

