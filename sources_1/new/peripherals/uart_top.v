`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/13 20:21:51
// Design Name: 
// Module Name: uart_top
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


module uart_top(
    input wire clk,
    input wire rst,
    input wire rx,
    output wire tx,
    input wire [15:0] bus_addr_in,   
    input wire [7:0] bus_data_in,
    input wire [3:0] bus_sig_in,
    output reg [7:0] bus_data_out,
    output reg tx_busy, rx_irq
    );

    wire [7:0] rx_data;
    reg tx_en, rx_read;
    wire busy, rx_done;

    reg [7:0] rx_buf [0:63];
    reg [5:0] wr_ptr, rd_ptr;
    integer i;
    initial begin
        for (i = 0; i < 64; i = i + 1) rx_buf[i] = 8'b0;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_ptr <= 6'd0;
            rd_ptr <= 6'd0;
            rx_irq <= 1'b0;
        end
        else begin
            if (rx_done && wr_ptr + 1'b1 != rd_ptr) begin
                rx_buf[wr_ptr] <= rx_data;
                wr_ptr <= wr_ptr + 1'b1;
                rx_irq <= 1'b1;
            end
            if (rx_read && rd_ptr != wr_ptr) begin
                rd_ptr <= rd_ptr + 1;
                if (rd_ptr + 1'b1 == wr_ptr && !(rx_done && wr_ptr + 1'b1 != rd_ptr)) begin 
                    rx_irq <= 1'b0;
                end
            end
        end
    end

    always @(*) begin
        tx_en = 1'b0;
        rx_read = 1'b0;
        bus_data_out = 8'b0;
        tx_busy = busy;
        if (bus_addr_in[15:13] == 3'b010) begin
            if (bus_sig_in[0]) begin
                tx_en = 1'b1;
            end
            else begin
                bus_data_out = rx_buf[rd_ptr];
                rx_read = 1'b1;
            end
        end
    end

    uart_tx u_uart_tx(
        .clk(clk),
        .rst(rst),
        .tx_en(tx_en),
        .tx_data(bus_data_in),
        //
        .tx(tx),
        .busy(busy)
    );

    uart_rx u_uart_rx(
        .clk(clk),
        .rst(rst),
        .rx(rx),
        //
        .rx_done(rx_done),
        .rx_data(rx_data)
    );



endmodule
