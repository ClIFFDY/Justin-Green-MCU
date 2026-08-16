`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/14 06:32:02
// Design Name: 
// Module Name: irq_controller
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


module irq_controller(
    input wire clk, rst, iret, 
    input wire [5:0] irq_addr_in,
    input wire [8:0] pc_addr_in, 
    input wire [7:0] bytmov,
    output reg [8:0] irq_addr,
    output reg irq_flush
    );

    localparam 
        UART_RX = 0,
        TIMER = 1,
        GPIO1 = 2,
        GPIO2 = 3;

    localparam [1:0] 
        IDLE = 2'b00,
        IRQ = 2'b01,
        BACK = 2'b10;

    reg [1:0] stage;

    reg [7:0] irq_vex [0:15];
    reg [10:0] pc_addr;

    initial begin
        pc_addr = 9'b0;
        irq_vex[UART_RX] = 10'd992; 
        irq_vex[TIMER] = 10'd968; 
        irq_vex[GPIO1] = 10'd936; 
        irq_vex[GPIO2] = 10'd904; 

    end

    always @(posedge clk) begin
        irq_flush <= 1'b0;
        irq_addr <= 9'b0;
        if (rst) begin
            stage <= IDLE;
            irq_flush <= 1'b0;
            irq_addr <= 9'b0;
        end
        else begin
            case (stage)
            IDLE: begin
                if (irq_addr_in != 11'b0 && bytmov == 8'b0) begin 
                    stage <= IRQ;
                    irq_flush <= 1'b1;
                    pc_addr <= pc_addr_in;
                    irq_addr <= irq_vex[irq_addr_in[5:3] + irq_addr_in[2:0] - 1];
                end
            end
            IRQ: begin
                if (iret == 1'b1) begin
                    stage <= BACK;
                    irq_flush <= 1'b1;
                    irq_addr <= pc_addr; 
                end
            end
            BACK: begin
                stage <= IDLE;
            end
            endcase
        end
    end
endmodule
