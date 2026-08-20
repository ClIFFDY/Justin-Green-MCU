`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/14 21:29:16
// Design Name: 
// Module Name: gpio_group
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


module gpio_group(
    input wire clk, rst,
    input wire [15:0] bus_addr_in,   
    input wire [7:0] bus_data_in,
    input wire [3:0] bus_sig_in,
    output reg [7:0] bus_data_out,
    output reg [1:0] gpio_irq,

    inout wire [7:0] gpio_pin_bus,
    inout wire sda,

    input wire tx,
    input wire scl,
    input wire pwm1, pwm2,
    output reg rx
    );

    localparam [3:0]
        UNUSE = 4'bz,
        OUT = 4'b0001,
        IN = 4'b0010,
        IRQ = 4'b0011,
        TX = 4'b0101,
        RX = 4'b0110,
        PWM1 = 4'b0111,
        PWM2 = 4'b1000,
        SCL = 4'b1001,
        SDA = 4'b1010;
    
    reg [7:0] gpio_output;
    reg [3:0] gpio_mode [0:7];
    integer i;
    initial begin
        for (i = 0; i < 8; i = i + 1) gpio_mode[i] = UNUSE;
    end
    
    genvar j;
    generate
        for (j = 0; j < 8; j = j + 1) begin
            assign gpio_pin_bus[j] = (gpio_mode[j] == OUT || gpio_mode[j] == TX
            || gpio_mode[j] == PWM1 || gpio_mode[j] == PWM2 || gpio_mode[j] == SCL)
             ? gpio_output[j] : (gpio_mode[j] == SDA) ? sda : 1'bz;
        end       
    endgenerate


    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 8; i = i + 1) gpio_mode[i] <= UNUSE;
            gpio_output <= 8'b0;
            rx <= 1'b1;
        end
        else begin
            gpio_irq <= 2'b0;
            rx <= 1'b1;
            if (bus_addr_in[15:12] == 4'b0100) begin
                if (bus_sig_in[0] && bus_addr_in[0]) begin
                    gpio_mode[bus_addr_in[3:1]] <= bus_data_in[3:0];
                end 
                else if (bus_sig_in[0] && !bus_addr_in[0]) begin 
                    for (i = 1; i < 8; i = i + 1) begin 
                        if (gpio_mode[i] == OUT) gpio_output[i] <= bus_data_in[i];
                    end
                end
            end
            for (i = 0; i < 8; i = i + 1) begin
                if (i < 4) begin
                    if (gpio_mode[i] == IRQ) gpio_irq[0] <= ~gpio_pin_bus[i];  
                end
                else if (i >= 4 && i < 8) begin
                    if (gpio_mode[i] == IRQ) gpio_irq[1] <= ~gpio_pin_bus[i];  
                end
                if (gpio_mode[i] == TX) gpio_output[i] <= tx;
                else if (gpio_mode[i] == RX) rx <= gpio_pin_bus[i];
                else if (gpio_mode[i] == PWM1) gpio_output[i] <= pwm1;
                else if (gpio_mode[i] == PWM2) gpio_output[i] <= pwm2;
                else if (gpio_mode[i] == SCL) gpio_output[i] <= scl;
            end            
        end
    end

    always @(*) begin 
        bus_data_out = 8'b0;
        if (bus_addr_in[15:12] == 4'b0100 && !bus_sig_in[0]) begin 
            for (i = 1; i < 8; i = i + 1) begin
                if (gpio_mode[i] == IN) bus_data_out[i] = gpio_pin_bus[i];
            end
        end
    end
endmodule
