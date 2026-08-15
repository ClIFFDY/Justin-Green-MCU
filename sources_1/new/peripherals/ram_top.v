`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/16 04:35:55
// Design Name: 
// Module Name: ram_top
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


module ram_top(
    input wire clk,
    input wire [15:0] bus_addr_in,
    input wire [7:0] bus_data_in,
    input wire [3:0] bus_sig_in,
    output reg [7:0] bus_data_out,
    output wire stall_bus
    );

    reg done;
    reg [3:0] sec;
    wire [7:0] sec_out [0:3];
    wire access = (bus_addr_in[15:12] == 4'b1000 || bus_addr_in[15:12] == 4'b1001 
                  || bus_addr_in[15:12] == 4'b1010 || bus_addr_in[15:12] == 4'b1011)? 1'b1 : 1'b0;
    assign stall_bus = access && !done;

    always @(posedge clk) begin
        done <= 1'b0;
        if (access) begin
            done <= ~done;
        end
    end

    always @(*) begin
        sec = 4'b0;
        if (access) begin
            sec[bus_addr_in[1:0]] = 1'b1;
            bus_data_out = sec_out[bus_addr_in[1:0]];            
        end 
        else begin
            sec = 4'b0;
            bus_data_out = 8'b0;
        end
    end

    ram_sec ram_sec_1 (
        .clk(clk),
        .ram_sec(sec[0]),
        .mode(bus_sig_in[0]),
        .sec_addr_in(bus_addr_in[11:0]),
        .bus_data_in(bus_data_in),
        .sec_data_out(sec_out[0])
    );

    ram_sec ram_sec_2 (
        .clk(clk),
        .ram_sec(sec[1]),
        .mode(bus_sig_in[0]),
        .sec_addr_in(bus_addr_in[11:0]),
        .bus_data_in(bus_data_in),
        .sec_data_out(sec_out[1])
    );

    ram_sec ram_sec_3 (
        .clk(clk),
        .ram_sec(sec[2]),
        .mode(bus_sig_in[0]),
        .sec_addr_in(bus_addr_in[11:0]),
        .bus_data_in(bus_data_in),
        .sec_data_out(sec_out[2])
    );

    ram_sec ram_sec_4 (
        .clk(clk),
        .ram_sec(sec[3]),
        .mode(bus_sig_in[0]),
        .sec_addr_in(bus_addr_in[11:0]),
        .bus_data_in(bus_data_in),
        .sec_data_out(sec_out[3])
    );

endmodule
