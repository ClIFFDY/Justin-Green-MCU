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
    input wire [11:0] pc_addr_in, 
    input wire [15:0] bytmov,
    output reg [11:0] irq_addr,
    output reg irq_flush,

    input wire [3:0] bus_addr_in,
    input wire [7:0] bus_data_in,
    input wire bus_sig_in
    );

    localparam 
        TIMER = 0,
        UART_RX = 1,
        GPIO1 = 2,
        GPIO2 = 3;

    localparam [1:0] 
        IDLE = 2'b00,
        IRQ = 2'b01,
        OPR = 2'b10,
        BACK = 2'b11;

    localparam [3:0]
    IRQ_W = 4'b0101;

    reg [1:0] stage;
    reg [3:0] j;

    reg [11:0] irq_vex [0:15];
    reg [11:0] pc_addr [0:7];
    reg [2:0] prio;
    integer i;

    initial begin
        irq_vex[TIMER]   = 12'd584;
        irq_vex[UART_RX] = 12'd608;
        irq_vex[GPIO1]   = 12'd552;
        irq_vex[GPIO2]   = 12'd520;
        for (i = 4; i < 16; i = i + 1) irq_vex[i] = 8'd168;
        for (i = 0; i < 8; i = i + 1) pc_addr[i] = 12'b0;
    end

    always @(posedge clk) begin
        irq_flush <= 1'b0;
        irq_addr <= 12'b0;
        if (rst) begin
            stage <= IDLE;
            prio <= 4'b0;
            j <= 1'b0;
            irq_flush <= 1'b0;
            irq_addr <= 12'b0;
        end
        else begin
            case (stage)
            IDLE: begin
                if (irq_addr_in != 12'b0 && bytmov == 16'b0) begin 
                    stage <= IRQ;
                    prio <= irq_addr_in[5:3];
                    irq_flush <= 1'b1;
                    pc_addr[j] <= pc_addr_in;
                    j <= j + 1;
                    irq_addr <= irq_vex[irq_addr_in[5:3] + irq_addr_in[2:0] - 1];
                end
            end
            IRQ: begin
                if (iret == 1'b1) begin
                    stage <= BACK;
                    irq_flush <= 1'b1;
                    if (j >= 1'b1) begin 
                        j <= j - 1;
                        irq_addr <= pc_addr[j - 1]; 
                    end
                end
                else begin
                    if (irq_addr_in != 12'b0 && bytmov == 16'b0 
                        && irq_addr_in[5:3] > prio && j <= 4'd15) begin 
                        stage <= IRQ;
                        prio <= irq_addr_in[5:3];
                        irq_flush <= 1'b1;
                        pc_addr[j] <= pc_addr_in;
                        j <= j + 1;
                        irq_addr <= irq_vex[irq_addr_in[5:3] + irq_addr_in[2:0] - 1];
                    end
                    else if (bus_sig_in && bus_addr_in == IRQ_W) begin
                        pc_addr[0][11:8] <= bus_data_in;
                        stage <= OPR;
                    end
                end
            end
            OPR: begin
                pc_addr[0][7:0] <= bus_data_in;
                stage <= IRQ;
            end
            BACK: begin
                if (j == 1'b0) stage <= IDLE;
                else stage <= IRQ;
            end
            endcase
        end
    end
endmodule
