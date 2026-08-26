`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/14 19:37:44
// Design Name: 
// Module Name: timer
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


module timer(
    input wire clk, rst,
    input wire [15:0] bus_addr_in,
    input wire [7:0] bus_data_in,
    input wire [3:0] bus_sig_in,
    output reg [7:0] bus_data_out,
    output reg timer_irq, pwm1, pwm2
    );

    reg [7:0] cnt_set [0:3];
    reg [7:0] cnt [0:3];
    reg [7:0] pwm_duty1 [0:3], pwm_duty2 [0:3];
    reg irq_mode, pwm_en1, pwm_en2;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 4; i = i + 1) begin 
                cnt_set[i] <= 8'b0;
                cnt[i] <= 8'b0;
                pwm_duty1[i] <= 8'b0;
                pwm_duty2[i] <= 8'b0;
                pwm_en1 <= 1'b0;
                pwm_en2 <= 1'b0;
            end
            timer_irq <= 1'b0;
            irq_mode <= 1'b0;
        end
        else begin
            if (!irq_mode) timer_irq <= 0;
            if (bus_addr_in[15:12] == 4'b0011 && bus_sig_in[0]) begin
                for (i = 0; i < 4; i = i + 1) cnt[i] <= 8'b0;
                if (bus_addr_in[11:0] <= 12'd3) begin
                    cnt_set[bus_addr_in[11:0]] <= bus_data_in;                    
                end
                else if (bus_addr_in[11:0] == 12'd4) begin
                    irq_mode <= bus_data_in[0];
                end
                else if (bus_addr_in[11:0] == 12'd5) begin
                    if (irq_mode && timer_irq) timer_irq <= 1'b0;
                end
                else if (bus_addr_in[11:0] >= 12'd6 && bus_addr_in[11:0] <= 12'd9) begin
                    pwm_duty1[bus_addr_in[11:0] - 12'd6] <= bus_data_in;
                end
                else if (bus_addr_in[11:0] >= 12'd10 && bus_addr_in[11:0] <= 12'd13) begin
                    pwm_duty2[bus_addr_in[11:0] - 12'd10] <= bus_data_in;
                end
                else if (bus_addr_in[11:0] == 12'd14) begin
                    pwm_en1 <= bus_data_in[0];
                    pwm_en2 <= bus_data_in[1];
                end
            end
            else if (cnt_set[0] != 8'd0 || cnt_set[1] != 8'd0 
            || cnt_set[2] != 8'd0 || cnt_set[3] != 8'd0) begin
                cnt[0] <= cnt[0] + 1;
                if (cnt[0] == 8'd255) cnt[1] <= cnt[1] + 1;
                if (cnt[0] == 8'd255 && cnt[1] == 8'd255) cnt[2] <= cnt[2] + 1;
                if (cnt[0] == 8'd255 && cnt[1] == 8'd255 && cnt[2] == 8'd255) cnt[3] <= cnt[3] + 1;
                if (cnt_set[0] == cnt[0] && cnt_set[1] == cnt[1]
                && cnt_set[2] == cnt[2] && cnt_set[3] == cnt[3]) begin
                    timer_irq <= 1'b1;
                    for (i = 0; i < 4; i = i + 1) cnt[i] <= 8'd0;
                end
            end
        end
    end

    always @(*) begin
        if (bus_addr_in[15:12] == 4'b0011 && !bus_sig_in[0]) begin
            bus_data_out = cnt[bus_addr_in[11:0]];
        end
        else bus_data_out = 8'b0;
    end

    always @(*) begin
        if (rst) begin
            pwm1 = 1'b0;
            pwm2 = 1'b0;
        end
        else begin
            if (pwm_en1) pwm1 = 1'b1;
            else pwm1 = 1'b0;
            if (pwm_en2) pwm2 = 1'b1;
            else pwm2 = 1'b0;
            if ({pwm_duty1[3], pwm_duty1[2], pwm_duty1[1], pwm_duty1[0]} <=
                {cnt[3], cnt[2], cnt[1], cnt[0]}) begin
                pwm1 = 1'b0;
            end
            if ({pwm_duty2[3], pwm_duty2[2], pwm_duty2[1], pwm_duty2[0]} <=
                {cnt[3], cnt[2], cnt[1], cnt[0]}) begin
                pwm2 = 1'b0; 
            end
        end
    end
endmodule
