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
    input wire clk, rst,
    input wire [23:0] addr_r12_raw,
    output reg [23:0] addr_r12_mov,
    output reg [7:0] baseline,
    //
    input wire [15:0] bus_addr_in,   
    input wire [7:0] bus_data_in,
    input wire [3:0] bus_sig_in,
    output reg [7:0] bus_data_out
    );

    localparam [3:0]
    BASEL = 4'b1101;

    always @(posedge clk) begin
        if (rst) baseline <= 8'b0;
        else begin
            if (bus_addr_in[15:12] == BASEL && bus_sig_in[0]) begin
                baseline <= bus_data_in;
            end
        end
    end

    always @(*) begin
        if (rst) addr_r12_mov = 24'b0;
        else if (bus_addr_in[15:12] == BASEL && bus_sig_in[0]) begin
            addr_r12_mov = {addr_r12_raw[23:16] + ((addr_r12_raw[23:16] < 8'd253) ? bus_data_in : 8'd0),
                            addr_r12_raw[15:8] + ((addr_r12_raw[15:8] < 8'd253) ? bus_data_in : 8'd0),
                            addr_r12_raw[7:0] + ((addr_r12_raw[7:0] < 8'd253) ? bus_data_in : 8'd0)};
        end
        else begin
            addr_r12_mov = {addr_r12_raw[23:16] + ((addr_r12_raw[23:16] < 8'd253) ? baseline : 8'd0),
                            addr_r12_raw[15:8] + ((addr_r12_raw[15:8] < 8'd253) ? baseline : 8'd0),
                            addr_r12_raw[7:0] + ((addr_r12_raw[7:0] < 8'd253) ? baseline : 8'd0)};
        end
        if (bus_addr_in[15:12] == BASEL && !bus_sig_in[0]) begin
            bus_data_out = baseline;
        end 
    end

endmodule
