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
    input wire clk, rst, iret, stall,
    input wire [8:0] irq_bus_in,
    input wire [12:0] pc_addr_in, 
    input wire [1:0] irq_en,
    output reg [12:0] irq_addr,
    output reg irq_flush,

    input wire [15:0] bus_addr_in,
    input wire [7:0] bus_data_in,
    output reg [7:0] bus_data_out,
    input wire bus_sig_in
    );

    localparam 
        TIMER = 0,
        UART_RX = 1,
        GPIO1 = 2,
        GPIO2 = 3,
        DMA = 4,
        I2C = 5;

    localparam [3:0] 
        IDLE = 3'b000,
        IRQ = 3'b001,
        OPR = 3'b010,
        WAIT = 3'b011;

    localparam [3:0]
    IRQ_W = 4'b0101;

    reg [1:0] stage;
    reg [3:0] j;

    reg [12:0] irq_vex [0:15];
    reg [12:0] pc_addr [0:7];
    reg [2:0] prio;
    integer i;

    initial begin
        irq_vex[I2C]     = 13'd1168;
        irq_vex[DMA]     = 13'd1136;
        irq_vex[UART_RX] = 13'd1104;
        irq_vex[TIMER]   = 13'd1088;
        irq_vex[GPIO1]   = 13'd1056;
        irq_vex[GPIO2]   = 13'd1024;
        for (i = 6; i < 16; i = i + 1) irq_vex[i] = 8'd0;
        for (i = 0; i < 8; i = i + 1) pc_addr[i] = 12'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            stage <= IDLE;
            prio <= 4'b0;
            j <= 1'b0;
        end
        else begin
            if (bus_sig_in && bus_addr_in[15:12] == IRQ_W) begin
                if (bus_addr_in[1:0] == 2'd1) begin 
                    irq_vex[bus_addr_in[4:2]][12:8] = bus_data_in;
                end
                else if (bus_addr_in[1:0] == 2'd2) begin 
                    irq_vex[bus_addr_in[4:2]][7:0] = bus_data_in;
                end
            end
            case (stage)
            IDLE: begin
                if (irq_bus_in != 13'b0 && irq_en == 2'b11 && !stall) begin 
                    stage <= IRQ;
                    prio <= irq_bus_in[8:6];
                    pc_addr[j] <= pc_addr_in - 1;
                    j <= j + 1;
                end
            end
            IRQ: begin
                if (iret == 1'b1) begin
                    stage <= WAIT;
                    if (j >= 1'b1) begin 
                        j <= j - 1;
                    end
                end
                else begin
                    if (bus_sig_in && bus_addr_in[15:12] == IRQ_W && bus_addr_in[1:0] == 2'd0) begin
                        pc_addr[0][12:8] <= bus_data_in;
                        stage <= OPR;
                    end
                    else if (irq_bus_in != 13'b0 && irq_en == 2'b11 && !stall 
                        && irq_bus_in[8:6] > prio && j <= 4'd15) begin 
                        stage <= IRQ;
                        prio <= irq_bus_in[8:6];
                        pc_addr[j] <= pc_addr_in - 1;
                        j <= j + 1;
                    end
                end
            end
            OPR: begin
                pc_addr[0][7:0] <= bus_data_in;
                stage <= IRQ;
            end
            WAIT: begin
                if (j == 0) stage <= IDLE;
                else stage <= IRQ;
            end
            endcase
        end
    end

    always @(*) begin
        if (rst) begin 
            irq_flush = 1'b0;
            irq_addr = 13'b0;
            bus_data_out = 8'b0;
        end
        else begin
            bus_data_out = 8'b0;
            irq_flush = 1'b0;
            irq_addr = 13'b0;
            if (!bus_sig_in && bus_addr_in[15:12] == IRQ_W) begin
                if (!bus_addr_in[0]) bus_data_out = pc_addr[bus_addr_in[4:1]][7:0];
                else bus_data_out = pc_addr[bus_addr_in[4:1]][11:8];
            end
            case (stage)
            IDLE: begin
                if (irq_bus_in != 13'b0 && irq_en == 2'b11 && !stall) begin 
                    irq_flush = 1'b1;
                    irq_addr = irq_vex[irq_bus_in[5:3] + irq_bus_in[2:0] - 1];
                end
            end
            IRQ: begin
                if (iret == 1'b1) begin
                    if (j >= 1'b1) begin 
                        irq_addr = pc_addr[j - 1];
                    end
                    irq_flush = 1'b1;
                end
                else begin
                    if (irq_bus_in != 13'b0 && irq_en == 2'b11 && !stall
                        && irq_bus_in[8:6] > prio && j <= 4'd15) begin 
                        irq_addr = irq_vex[irq_bus_in[5:3] + irq_bus_in[2:0] - 1];
                        irq_flush = 1'b1;
                    end
                end
            end
            endcase
        end
    end
endmodule 
