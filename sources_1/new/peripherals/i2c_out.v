`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/21 02:31:14
// Design Name: 
// Module Name: i2c_out
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


module i2c_out(
    input wire clk, rst,
    input wire [15:0] bus_addr_in,
    input wire [7:0] bus_data_in,
    input wire [3:0] bus_sig_in,
    input wire [15:0] bus_addr_dma,
    input wire [7:0] bus_data_dma,
    input wire [3:0] bus_sig_dma,

    output reg i2c_err_irq,
    inout wire sda,
    output wire scl, busy
    );

    wire dma_oc = (bus_addr_dma[15:12] == 4'b0001) ? 1'b1 : 1'b0;
    wire [15:0] bus_addr_final = (dma_oc) ? bus_addr_dma: bus_addr_in;
    wire [7:0] bus_data_final = (dma_oc) ? bus_data_dma : bus_data_in;
    wire [3:0] bus_sig_final = (dma_oc) ? bus_sig_dma : bus_sig_in;

    reg ack_mode, start, stop;
    reg [1:0] frq_mode;
    reg [3:0] rd_ptr, wr_ptr, bit_cnt;
    reg [7:0] addr_reg;
    reg [2:0] stage;
    reg sda_mode, scl_reg, sda_reg;
    reg phase_h; 

    localparam 
        CLK = 50_000_000,
        LOW_FREQ = 100_000,
        HIGH_FREQ = 400_000,
        ULTRA_FREQ = 1_000_000;

    localparam[2:0]
        IDLE = 3'd0,
        SEND = 3'd1,
        ACK1 = 3'd2,
        ACK2 = 3'd3,
        START = 3'd4,
        STOP = 3'd5,
        BACK = 3'd6;

        reg [8:0] cnt_l, cnt_h, cnt;
        reg [7:0] data_buf [0:15];
        reg [7:0] send_buf;

    assign scl = scl_reg;
    assign sda = (sda_mode) ? sda_reg : 1'bz;
    assign busy = (wr_ptr != rd_ptr + 1'b1) ? 1'b1 : 1'b0;

    always @(*) begin
        if (rst) begin cnt_l = 9'd0; cnt_h = 9'd0; end
        else begin
            case (frq_mode)
            2'd0: begin cnt_l = CLK * 2 / (LOW_FREQ * 5);   cnt_h = CLK * 3 / (LOW_FREQ * 5);  end
            2'd1: begin cnt_l = CLK * 2 / (HIGH_FREQ * 5);  cnt_h = CLK * 3 / (HIGH_FREQ * 5); end
            2'd2: begin cnt_l = CLK * 2 / (ULTRA_FREQ * 5); cnt_h = CLK * 3 / (ULTRA_FREQ * 5); end
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            frq_mode <= 2'd0;
            ack_mode <= 1'b1;
            wr_ptr <= 4'd1;
        end
        else begin
            if (bus_addr_final[15:12] == 4'b0001) begin
                if (bus_addr_final[11:9] == 3'd0 && bus_sig_final[0] && wr_ptr != rd_ptr) begin
                    data_buf[wr_ptr] <= bus_data_final;
                    wr_ptr = wr_ptr + 1;
                end
                else if (bus_addr_final[11:9] == 3'd1 && bus_sig_final[0]) begin
                    frq_mode <= bus_data_final[2:1];
                    ack_mode <= bus_data_final[0];
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            i2c_err_irq <= 1'b0;
            start <= 1'b0;
            stop <= 1'b0;
            rd_ptr <= 4'd0;
            cnt <= 9'd0;
            stage <= 3'd0;
            sda_reg <= 1'b1;
            sda_mode <= 1'b0;
            send_buf <= 8'b0;
            bit_cnt <= 4'd0;
            phase_h <= 1'b0;
            cnt <= 1'b0;
        end
        else begin
            if (bus_addr_final[15:12] == 4'b0001 && bus_sig_final[0]) begin
                if (bus_addr_final[11:9] == 3'd2) start <= 1'b1;
                else if (bus_addr_final[11:9] == 3'd3) stop <= 1'b1;
                else if (bus_addr_final[11:9] == 3'd4) i2c_err_irq <= 1'b0;
            end
            if (cnt >= (phase_h ? cnt_h : cnt_l) - 1'b1) cnt <= 0;
            else cnt <= cnt + 1'b1;
            if (cnt == (phase_h ? cnt_h : cnt_l) - 1'b1) begin
                case (stage)
                    IDLE: begin
                        scl_reg <= 1'b1;
                        sda_mode <= 1'b1;
                        sda_reg <= 1'b1;
                        if (rd_ptr != wr_ptr - 1'b1 && start) begin
                            send_buf <= data_buf[rd_ptr + 1'b1];
                            rd_ptr <= rd_ptr + 1'b1;
                            bit_cnt <= 4'd8;
                            phase_h <= 1'b0;
                            stage <= START;
                        end
                    end
                    START: begin
                        sda_mode <= 1'b1;
                        sda_reg <= 1'b0;     
                        scl_reg <= 1'b1;
                        phase_h <= 1'b0;
                        stage <= SEND;
                    end
                    SEND: begin
                        start <= 1'b0;
                        if (!phase_h) begin
                            scl_reg <= 1'b0;
                            sda_reg <= send_buf[7];
                            send_buf <= {send_buf[6:0], 1'b0};
                            phase_h <= 1'b1;
                        end
                        else begin
                            scl_reg <= 1'b1;
                            phase_h <= 1'b0;
                            if (bit_cnt > 1) begin
                                bit_cnt <= bit_cnt - 1'b1;
                            end
                            else begin
                                bit_cnt <= 4'd0;
                                if (ack_mode == 1'b1) begin
                                    stage <= ACK1; 
                                end
                                else if (stop) begin
                                    stop <= 1'b0;
                                    stage <= STOP;
                                end
                                else if (rd_ptr != wr_ptr - 1'b1) begin
                                    send_buf <= data_buf[rd_ptr + 1'b1]; 
                                    rd_ptr <= rd_ptr + 1'b1;
                                    bit_cnt <= 4'd8;
                                end
                                else stage <= IDLE;
                            end
                        end
                    end
                    ACK1: begin
                        sda_mode <= 1'b0;
                        stage <= ACK2;
                    end
                    ACK2: begin
                        if (sda == 1'b1) begin
                            i2c_err_irq <= 1'b1;
                            stage <= STOP;
                        end
                        else begin
                            stage <= BACK;
                        end
                    end
                    STOP: begin
                        scl_reg <= 1'b1;
                        sda_mode <= 1'b1;
                        sda_reg <= 1'b0;
                        stage <= BACK;
                    end
                    BACK: begin
                        scl_reg <= 1'b1;
                        sda_reg <= 1'b1;
                        sda_mode <= 1'b0;
                        stage <= IDLE;
                    end
                endcase
            end
        end
    end
endmodule
