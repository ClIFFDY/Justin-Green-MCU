`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/08/20 14:01:35
// Design Name:
// Module Name: dma
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


module dma(
    input wire clk, rst, busy1, busy2, rx_irq,
    input wire [15:0] bus_addr_in,
    input wire [7:0] bus_data_in_cpu,
    input wire [7:0] bus_data_in,
    input wire [3:0] bus_sig_in,
    output reg [15:0] bus_addr_out,
    output reg [7:0] bus_data_out, bus_data_dma,
    output reg [3:0] bus_sig_out,
    output reg dma_irq
    );

    localparam [3:0]
    I2C = 4'b0001,
    UART = 4'b0010,
    TIMER = 4'b0011,
    GPIO = 4'b0100,
    IRQ = 4'b0101,
    BUS_CON = 4'b0110,
    DMA = 4'b0111,

    RAM_1 = 4'b1000,
    RAM_2 = 4'b1001,
    RAM_3 = 4'b1010,
    BANK_SEL = 4'b1011,
    RAM_EXT = 4'b1100,
    BASEL = 4'b1101;

    localparam [2:0]
    IDLE = 3'b000,
    INI = 3'b001,
    HSH = 3'b010,
    LD = 3'b011,
    WR = 3'b100;

    reg busy;
    reg [2:0] stage;
    reg [15:0] ini_addr;
    reg [7:0] ini_bank;
    reg [7:0] data_buf [0:15];
    reg [3:0] wr_ptr, ld_ptr;
    reg [15:0] cnt_ld, cnt_wr, cnt_due_set, cnt_due;
    reg [15:0] des_addr;

    always @(posedge clk) begin
        if (rst) begin
            stage <= IDLE;
            ini_addr <= 15'b0;
            ini_bank <= 8'b0;
            cnt_ld <= 16'b0;
            cnt_wr <= 16'b0;
            cnt_due <= 16'b0;
            des_addr <= 15'b0;
            ld_ptr <= 1'b1;    
            wr_ptr <= 1'b0;    
            dma_irq <= 1'b0;
        end
        else begin
            case (stage)
            IDLE: begin
                if (bus_addr_in[15:12] == DMA && bus_sig_in[0]) begin
                    if (bus_addr_in[11:8] == 4'd0) ini_addr <= {bus_addr_in[7:0], bus_data_in_cpu};
                    else if (bus_addr_in[11:8] == 4'd1) begin
                        cnt_ld <= {bus_addr_in[7:0], bus_data_in_cpu};
                        cnt_wr <= {bus_addr_in[7:0], bus_data_in_cpu};
                    end
                    else if (bus_addr_in[11:8] == 4'd2) begin
                        cnt_due_set <= {bus_addr_in[7:0], bus_data_in_cpu};
                    end
                    else if (bus_addr_in[11:8] == 4'd3) des_addr <= {bus_addr_in[7:0], bus_data_in_cpu};
                    else if (bus_addr_in[11:8] == 4'd4) ini_bank <= {bus_addr_in[7:0], bus_data_in_cpu};
                    else if (bus_addr_in[11:8] == 4'd5) begin
                        stage <= INI;
                    end
                    else if (bus_addr_in[11:8] == 4'd6) begin
                        dma_irq <= 1'b0;
                    end
                end
            end
            INI: begin
                if (ini_addr[15:12] == RAM_EXT || des_addr[15:12] == RAM_EXT) stage <= HSH;
                else if (ini_addr[15:12] == UART || ini_addr[15:12] == I2C) stage <= HSH;
                else stage <= HSH;
            end
            HSH: begin
                stage <= LD;
            end
            LD: begin
                if (ini_addr[15:12] == UART) begin
                    if (rx_irq && ld_ptr != wr_ptr) begin
                        data_buf[ld_ptr - 4'd1] <= bus_data_in;
                        ld_ptr <= ld_ptr + 1;
                        cnt_due <= 16'b0;
                        stage <= LD;
                    end
                    else if (ld_ptr == wr_ptr) begin
                        stage <= WR;
                    end
                    else if (cnt_due == cnt_due_set && wr_ptr != ld_ptr - 4'd1) begin
                        stage <= WR;
                        cnt_due <= 16'b0;
                    end
                    else if (cnt_due == cnt_due_set && wr_ptr == ld_ptr - 4'd1) begin
                        stage <= IDLE;
                        dma_irq <= 1'b1;
                    end
                    else cnt_due <= cnt_due + 1;
                end
                else if (cnt_ld > 16'd0 && ld_ptr != wr_ptr) begin
                    data_buf[ld_ptr - 4'd1] <= bus_data_in;
                    ld_ptr <= ld_ptr + 1;
                    cnt_ld <= cnt_ld - 1;
                    ini_addr <= ini_addr + 1;
                    stage <= HSH;
                end
                else stage <= WR;
            end
            WR: begin
                if (des_addr[15:12] == UART || des_addr[15:12] == I2C) begin
                    if (!busy && cnt_wr > 16'd0 && wr_ptr != ld_ptr - 4'd1) begin
                        wr_ptr <= wr_ptr + 1;
                        cnt_wr <= cnt_wr - 1;
                        stage <= WR;
                    end
                    else if (cnt_wr == 16'd0) begin
                        stage <= IDLE;
                        dma_irq <= 1'b1;
                    end
                    else if (wr_ptr == ld_ptr - 4'd1) stage <= HSH;   
                end
                else if (cnt_wr > 16'd0 && wr_ptr != ld_ptr - 4'd1) begin
                    wr_ptr <= wr_ptr + 1;
                    cnt_wr <= cnt_wr - 1;
                    des_addr <= des_addr + 1;
                    stage <= WR;
                end
                else if (wr_ptr != ld_ptr - 4'd1) stage <= HSH;     
                else if (cnt_wr == 16'd0) begin
                    stage <= IDLE;
                    dma_irq <= 1'b1;
                end
            end
            endcase
        end
    end

    always @(*) begin
        bus_addr_out = 16'b0;
        bus_data_out = 8'b0;
        bus_sig_out  = 4'b0;
        if (des_addr[15:12] == UART) busy = busy1;
        else if (des_addr[15:12] == I2C) busy = busy2;
        else busy = 1'b0;
        case (stage)
        INI: begin
            if (ini_addr[15:12] == RAM_EXT || des_addr[15:12] == RAM_EXT) begin
                bus_addr_out = {BANK_SEL, 8'b0};
                bus_data_out = ini_bank;
                bus_sig_out[0] = 1'b1;          
            end
        end
        HSH: begin
            bus_addr_out = ini_addr;
            bus_sig_out[0] = 1'b0;             
        end
        LD: begin
            if (ini_addr[15:12] == UART) begin
                if (rx_irq && ld_ptr != wr_ptr) begin
                    bus_addr_out = ini_addr;
                    bus_sig_out[0] = 1'b0;        
                end
            end
            else if (cnt_ld > 16'd0 && ld_ptr != wr_ptr) begin
                bus_addr_out = ini_addr;
                bus_sig_out[0] = 1'b0;           
            end
        end
        WR: begin
            if (des_addr[15:12] == UART || des_addr[15:12] == I2C) begin
                if (!busy && wr_ptr != ld_ptr - 4'd1) begin
                    bus_addr_out = des_addr;
                    bus_data_out = data_buf[wr_ptr];
                    bus_sig_out[0] = 1'b1;
                end
            end
            else if (cnt_wr > 16'd0 && wr_ptr != ld_ptr - 4'd1) begin
                bus_addr_out = des_addr;
                bus_data_out = data_buf[wr_ptr];
                bus_sig_out[0] = 1'b1;
            end
        end
        default: begin end
        endcase
    end

    always @(*) begin
        bus_data_dma = 16'b0;
        if (!rst && bus_addr_in[11:8] == 4'd6) begin
            bus_data_dma = cnt_wr[15:8];
        end
        else if (!rst && bus_addr_in[11:8] == 4'd7) begin
            bus_data_dma = cnt_wr[7:0];
        end
    end
endmodule
