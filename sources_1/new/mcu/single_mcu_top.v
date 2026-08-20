`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/14 04:14:50
// Design Name: 
// Module Name: single_mcu_top
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

    
module single_mcu_top(
    input wire rst_n,
    input wire clk,
    inout wire [7:0] gpio_pin_bus
    );



    wire [15:0] bus_addr_f1, bus_addr_f2, bus_addr_dma;
    wire [7:0] bus_data_f1, bus_data_f2, bus_data_dma_cnt; 
    wire [3:0] bus_sig_f1, bus_sig_f2, bus_sig_dma;
    wire [7:0] bus_data_b;
    wire tx_flg, tx_busy;
    wire stall_bus_in, stall_bus_1, stall_bus_2;

    wire [7:0] bus_data_uart, bus_data_ram1, bus_data_ram2, bus_data_gpio, bus_data_irq, bus_data_to_dma;

    wire [8:0] irq_bus;
    wire rx, tx, pwm1, pwm2;
    wire rx_irq ,timer_irq, dma_irq;
    wire [1:0] gpio_irq;

    rst_buf u_rst_buf(
        .clk(clk),
        .rst_n(rst_n),
        //
        .rst_stable(rst)
    );
    
    single_cpu_top u_cpu(
        .clk(clk),
        .rst(rst),
        .bus_data_in(bus_data_b),
        .tx_busy(tx_busy),
        .stall_bus(stall_bus),
        .irq_bus(irq_bus),
        //
        .bus_addr_out(bus_addr_f1),
        .bus_data_out(bus_data_f1),
        .bus_data_irq(bus_data_irq),
        .bus_sig_out(bus_sig_f1)
    );

    bus_controller u_bus_controller(
        .clk(clk),
        .rst(rst),
        .bus_addr_f_in(bus_addr_f1),
        .bus_addr_dma_in(bus_addr_f2),
        .bus_data_in_cpu(bus_data_f1),
        .bus_sig_f_in(bus_sig_f1),
        //
        .timer_irq(timer_irq),
        .rx_irq(rx_irq),
        .dma_irq(dma_irq),
        .stall_bus_1(stall_bus_1),
        .stall_bus_2(stall_bus_2),
        .gpio_irq(gpio_irq),
        .irq_bus(irq_bus),
        .stall_bus(stall_bus),
        //
        .bus_data_ram1(bus_data_ram1),
        .bus_data_ram2(bus_data_ram2),
        .bus_data_uart(bus_data_uart),
        .bus_data_gpio(bus_data_gpio),
        .bus_data_irq(bus_data_irq),
        .bus_data_dma(bus_data_dma_cnt),
        .bus_data_b(bus_data_b),
        .bus_data_to_dma(bus_data_to_dma)
    );

    dma u_dma (
        .clk(clk),
        .rst(rst),
        .busy(tx_busy),
        .rx_irq(rx_irq),
        .bus_addr_in(bus_addr_f1),
        .bus_sig_in(bus_sig_f1),
        .bus_data_in_cpu(bus_data_f1),
        .bus_data_dma(bus_data_dma_cnt),
        //
        .bus_data_in(bus_data_to_dma),
        .bus_addr_out(bus_addr_f2),
        .bus_data_out(bus_data_f2),
        .bus_sig_out(bus_sig_f2),
        .dma_irq(dma_irq)
    );

    ram_top u_ram_top(
        .clk(clk),
        .bus_addr_in(bus_addr_f1),
        .bus_data_in(bus_data_f1),
        .bus_sig_in(bus_sig_f1),
        .bus_addr_dma(bus_addr_f2),
        .bus_data_dma(bus_data_f2),
        .bus_sig_dma(bus_sig_f2),
        //
        .bus_data_out(bus_data_ram1),
        .stall_bus(stall_bus_1)
    );

    ram_ext_top u_ram_ext_top(
        .clk(clk),
        .rst(rst),
        .bus_addr_in(bus_addr_f1),
        .bus_data_in(bus_data_f1),
        .bus_sig_in(bus_sig_f1),
        .bus_addr_dma(bus_addr_f2),
        .bus_data_dma(bus_data_f2),
        .bus_sig_dma(bus_sig_f2),
        //
        .bus_data_out(bus_data_ram2),
        .stall_bus(stall_bus_2)
    );

    gpio_group u_gpio(
        .clk(clk),
        .rst(rst),
        .rx(rx),
        .tx(tx),
        .pwm1(pwm1),
        .pwm2(pwm2),
        .bus_addr_in(bus_addr_f1),
        .bus_data_in(bus_data_f1),
        .bus_sig_in(bus_sig_f1),
        //
        .bus_data_out(bus_data_gpio),
        .gpio_irq(gpio_irq),
        .gpio_pin_bus(gpio_pin_bus)
    );

    uart_top u_uart(
        .clk(clk),
        .rst(rst),
        .bus_addr_in(bus_addr_f1),   
        .bus_data_in(bus_data_f1),
        .bus_sig_in(bus_sig_f1),
        .bus_addr_dma(bus_addr_f2),
        .bus_data_dma(bus_data_f2),
        .bus_sig_dma(bus_sig_f2),
        //
        .rx_irq(rx_irq),
        .bus_data_out(bus_data_uart),
        .tx_busy(tx_busy),
        //
        .tx(tx),
        .rx(rx)
    );

    timer u_timer(
        .clk(clk),
        .rst(rst),
        .bus_addr_in(bus_addr_f1),
        .bus_data_in(bus_data_f1),
        .bus_sig_in(bus_sig_f1),
        //
        .timer_irq(timer_irq),
        .pwm1(pwm1),
        .pwm2(pwm2)
    );
endmodule
