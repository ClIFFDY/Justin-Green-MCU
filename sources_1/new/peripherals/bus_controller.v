`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/20 02:16:27
// Design Name: 
// Module Name: bus_controller
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


module bus_controller(
    input wire clk, rst,
    input wire timer_irq, rx_irq, stall_bus_1, stall_bus_2, bus_sig_in,
    input wire [1:0] gpio_irq,
    input wire [15:0] bus_addr_in,   
    input wire [7:0] bus_data_in_cpu,
    input wire [7:0] bus_data_ram1, bus_data_ram2, bus_data_uart, bus_data_gpio, bus_data_irq,
    output reg [7:0] bus_data_b,
    output reg [8:0] irq_bus,
    output reg stall_bus
    );

    localparam [3:0]
    UART = 4'b0010,
    TIMER = 4'b0011,
    GPIO = 4'b0100,
    IRQ = 4'b0101,
    BUS_CON = 4'b0110,

    RAM_1 = 4'b1000,
    RAM_2 = 4'b1001,
    RAM_3 = 4'b1010,
    BANK_SEL = 4'b1011,
    RAM_EXT = 4'b1100;

    reg [2:0] irq_prio [0:3];
    reg irq_h1, irq_h2, irq_h3;
    integer i;
        
    always @(*) begin
        case (bus_addr_in[15:12])
        RAM_1, RAM_2, RAM_3: bus_data_b = bus_data_ram1;
        RAM_EXT: bus_data_b = bus_data_ram2;
        UART: bus_data_b = bus_data_uart;
        GPIO: bus_data_b = bus_data_gpio;
        IRQ: bus_data_b = bus_data_irq;
        default: bus_data_b = 8'b0;
        endcase
    end

    always @(*) begin
        irq_bus = 9'b0;
        if (timer_irq && irq_prio[0] != 3'b0) irq_bus = {irq_prio[0], 3'b001, 3'b000};
        if (rx_irq && (irq_bus == 9'b0 || irq_prio[1] > irq_bus[8:6]) && irq_prio[1] != 3'b0)
            irq_bus = {irq_prio[1], 3'b010, 3'b000};
        if (gpio_irq[0] && (irq_bus == 9'b0 || irq_prio[2] > irq_bus[8:6]) && irq_prio[2] != 3'b0)
            irq_bus = {irq_prio[2], 3'b011, 3'b000};
        if (gpio_irq[1] && (irq_bus == 9'b0 || irq_prio[3] > irq_bus[8:6]) && irq_prio[3] != 3'b0)
            irq_bus = {irq_prio[3], 3'b100, 3'b000};
        stall_bus = (stall_bus_1 | stall_bus_2);
    end

    always @(posedge clk) begin
        if (rst) for (i = 0; i < 4; i = i + 1) irq_prio[i] <= i + 1;
        else begin
            if (bus_addr_in[15:12] == BUS_CON && bus_sig_in)
                irq_prio[bus_addr_in[1:0]] <= bus_data_in_cpu[1:0];
        end
    end

endmodule
