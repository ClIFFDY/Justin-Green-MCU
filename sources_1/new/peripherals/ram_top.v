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
    input wire [15:0] bus_addr_dma,
    input wire [7:0] bus_data_dma,
    input wire [3:0] bus_sig_dma,
    output wire stall_bus
    );

    wire dma_oc = (bus_addr_dma[15:12] == 4'b1000 || bus_addr_dma[15:12] == 4'b1001
                    || bus_addr_dma[15:12] == 4'b1010) ? 1'b1 : 1'b0;
    wire [15:0] bus_addr_final = (dma_oc) ? bus_addr_dma : bus_addr_in;
    wire [7:0] bus_data_final = (dma_oc) ? bus_data_dma : bus_data_in;
    wire [3:0] bus_sig_final = (dma_oc) ? bus_sig_dma : bus_sig_in;

    reg done;
    reg [2:0] sec;
    wire [7:0] sec_out [0:2];
    wire access = (bus_addr_final[15:12] == 4'b1000 || bus_addr_final[15:12] == 4'b1001 
                  || bus_addr_final[15:12] == 4'b1010)? 1'b1 : 1'b0;
    assign stall_bus = access && !done && !bus_sig_final[0] && !dma_oc;

    always @(posedge clk) begin
        done <= 1'b0;
        if (access && !bus_sig_final[0]) begin
            done <= ~done;
        end
        else done <= 1'b0;
    end

    always @(*) begin
        sec = 4'b0;
        if (access) begin
            sec[bus_addr_final[13:12]] = 1'b1;
            bus_data_out = sec_out[bus_addr_final[13:12]];            
        end 
        else begin
            sec = 4'b0;
            bus_data_out = 8'b0;
        end
    end

    ram_sec ram_sec_1(
        .clk(clk),
        .ram_sec(sec[0]),
        .mode(bus_sig_final[0]),
        .sec_addr_in(bus_addr_final[11:0]),
        .bus_data_in(bus_data_final),
        .sec_data_out(sec_out[0])
    );

    ram_sec ram_sec_2(
        .clk(clk),
        .ram_sec(sec[1]),
        .mode(bus_sig_final[0]),
        .sec_addr_in(bus_addr_final[11:0]),
        .bus_data_in(bus_data_final),
        .sec_data_out(sec_out[1])
    );

    ram_sec_init ram_sec_init(
        .clk(clk),
        .ram_sec(sec[2]),
        .mode(bus_sig_final[0]),
        .sec_addr_in(bus_addr_final[11:0]),
        .bus_data_in(bus_data_final),
        .sec_data_out(sec_out[2])
    );

endmodule
