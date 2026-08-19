`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/20 02:12:07
// Design Name: 
// Module Name: ram_ext_top
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


module ram_ext_top(
    input wire clk, rst,
    input wire [15:0] bus_addr_in,
    input wire [7:0] bus_data_in,
    input wire [3:0] bus_sig_in,
    output reg [7:0] bus_data_out,
    output wire stall_bus
    );

    reg done;
    reg [3:0] bank_num;
    reg [1:0] sec_num;
    wire [7:0] sec_out [0:3];
    wire access = (bus_addr_in[15:12] == 4'b1100)? 1'b1 : 1'b0;
    assign stall_bus = access && !done && !bus_sig_in[0];

    always @(posedge clk) begin
        if (rst) begin
            bank_num <= 0;
            sec_num <= 0;
            done <= 1'b0;
        end 
        else begin
            done <= 1'b0;
            if (bus_addr_in[15:12] == 4'b1011 && bus_sig_in[0]) begin
                bank_num <= 4'b0001 << bus_data_in[1:0];
                sec_num <= bus_data_in[1:0];
            end
            if (access && !bus_sig_in[0]) begin
                done <= ~done;
            end
            else done <= 1'b0;
        end
    end

    always @(*) begin
        if (access) begin
            bus_data_out = sec_out[sec_num];            
        end 
        else begin
            bus_data_out = 8'b0;
        end
    end    

    ram_sec ram_ext_1(
        .clk(clk),
        .ram_sec(bank_num[0] & access),
        .mode(bus_sig_in[0]),
        .sec_addr_in(bus_addr_in[11:0]),
        .bus_data_in(bus_data_in),
        .sec_data_out(sec_out[0])
    );

    ram_sec ram_ext_2(
        .clk(clk),
        .ram_sec(bank_num[1] & access),
        .mode(bus_sig_in[0]),
        .sec_addr_in(bus_addr_in[11:0]),
        .bus_data_in(bus_data_in),
        .sec_data_out(sec_out[1])
    );

    ram_sec ram_ext_3(
        .clk(clk),
        .ram_sec(bank_num[2] & access),
        .mode(bus_sig_in[0]),
        .sec_addr_in(bus_addr_in[11:0]),
        .bus_data_in(bus_data_in),
        .sec_data_out(sec_out[2])
    );

    ram_sec ram_ext_4(
        .clk(clk),
        .ram_sec(bank_num[3] & access),
        .mode(bus_sig_in[0]),
        .sec_addr_in(bus_addr_in[11:0]),
        .bus_data_in(bus_data_in),
        .sec_data_out(sec_out[3])
    );
endmodule
