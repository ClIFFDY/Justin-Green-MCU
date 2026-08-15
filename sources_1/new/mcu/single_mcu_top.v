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



    wire [15:0] bus_addr_f;
    wire [7:0] bus_data_f;
    wire [3:0] bus_sig_f;
    reg [7:0] bus_data_b;
    wire tx_flg;
    wire stall_bus;

    wire [7:0] bus_data_uart, bus_data_ram, bus_data_gpio;

    reg [5:0] irq_bus;
    wire rx, tx;
    wire rx_irq ,timer_irq;
    wire [1:0] gpio_irq;

    localparam [2:0]
        RAM = 3'b001,
        UART = 3'b010,
        TIMER = 3'b011,
        GPIO = 3'b100;

    always @(*) begin
        case (bus_addr_f[15:13])
        RAM: bus_data_b = bus_data_ram;
        UART: bus_data_b = bus_data_uart;
        GPIO: bus_data_b = bus_data_gpio;
        default: bus_data_b = 8'b0;
        endcase
    end

    always @(*) begin
        irq_bus = 6'b0;
        if (rx_irq) irq_bus[5:3] = 3'b001;
        if (timer_irq) irq_bus[5:3] = 3'b010;
        if (gpio_irq != 2'b0) irq_bus = {4'b010_0, gpio_irq};
    end

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
        .bus_addr_out(bus_addr_f),
        .bus_data_out(bus_data_f),
        .bus_sig_out(bus_sig_f)
    );

    data_ram u_data_ram(
        .clk(clk),
        .bus_addr_in(bus_addr_f),
        .bus_data_in(bus_data_f),
        .bus_sig_in(bus_sig_f),
        //
        .bus_data_out(bus_data_ram),
        .stall_bus(stall_bus)
    );

    gpio_group u_gpio(
        .clk(clk),
        .rst(rst),
        .rx(rx),
        .tx(tx),
        .bus_addr_in(bus_addr_f),
        .bus_data_in(bus_data_f),
        .bus_sig_in(bus_sig_f),
        //
        .bus_data_out(bus_data_gpio),
        .gpio_irq(gpio_irq),
        .gpio_pin_bus(gpio_pin_bus)
    );

    uart_top u_uart(
        .clk(clk),
        .rst(rst),
        .bus_addr_in(bus_addr_f),   
        .bus_data_in(bus_data_f),
        .bus_sig_in(bus_sig_f),
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
        .bus_addr_in(bus_addr_f),
        .bus_data_in(bus_data_f),
        .bus_sig_in(bus_sig_f),
        //
        .timer_irq(timer_irq)
    );
endmodule
