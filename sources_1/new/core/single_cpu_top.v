`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/10 00:01:51
// Design Name: 
// Module Name: single_cpu_top
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


module single_cpu_top(
    input wire clk,
    input wire rst, stall_bus, tx_busy, 
    input wire [7:0] bus_data_in, 
    input wire [5:0] irq_bus,
    output wire [15:0] bus_addr_out,
    output wire [7:0] bus_data_out,
    output wire [3:0] bus_sig_out
    );

    wire [1:0] stage;
    wire [11:0] pc_addr, irq_addr;
    wire [31:0] inst_raw, inst_raw_zip;
    wire [5:0] op_temp, opcode;
    wire [23:0] rd12, rd12_data;
    wire [15:0] r12_data, ab_raw;
    wire [7:0] rd_temp, rd;
    wire [7:0] rd_data, imm8_temp, imm8;
    wire [15:0] bytmov;
    wire [11:0] ra_fo, ra_ba;
    wire [7:0] result;
    wire [1:0] jmpflg, j_flag;
    wire we_temp1, we_temp2, we;
    wire frz, flush1, flush2, iret, irq_flush, cstall;;

    wire [7:0] bus_data_temp;

    fsm u_fsm(
        .clk(clk),
        .rst(rst),
        .frz(frz),
        //
        .stage(stage)
    );

    pc u_pc(
        .clk(clk),
        .rst(rst),
        .frz(frz),
        .stall_bus(stall_bus),
        .cstall(cstall),
        .irq_flag(irq_flush),
        .stage(stage),
        .j_flag(j_flag),
        .op_raw(op_temp),
        .bytmov(bytmov),
        .ra_in(ra_ba),
        .irq_addr(irq_addr),
        //
        .pc_addr(pc_addr),
        .ra(ra_fo),
        .jmpflg(jmpflg)
        );

    ins_rom u_ins_rom(
        .clk(clk),
        .rst(rst),
        .addr(pc_addr),
        .flush1(flush1),
        .stall(stall_bus),
        //
        .inst_raw(inst_raw_zip)
        );

    if_reg u_if_reg (
        .clk(clk),
        .rst(rst),
        .flush1(flush1),
        .stall(stall_bus),
        .stage(stage),
        .inst_raw_in(inst_raw_zip),
        //
        .inst_raw(inst_raw),
        .cstall(cstall)
    );

    decoder u_decoder(
        .rst(rst),
        .irq_flush(irq_flush),
        .inst_raw(inst_raw),
        .result_last_in(result),
        .rd_last1(rd_temp),
        .rd_last2(rd),
        .rd12_data(rd12_data),
        .rd_data(rd_data),
        .j_flag(j_flag),
        //
        .addr_dr12(rd12),
        .r12_data(r12_data),
        .opcode(op_temp),
        .imm8(imm8_temp),
        .bytmov(bytmov),
        .frz(frz),
        .we(we_temp1),
        .flush1(flush1),
        .iret(iret),
        //
        .bus_addr_out(bus_addr_out),
        .bus_data_out(bus_data_out),
        .bus_sig_out(bus_sig_out)
        );

    id_reg u_id_reg(
        .clk(clk),
        .stall(stall_bus),
        .stage(stage),
        .we_in(we_temp1),
        .flush1(flush1),
        .opcode_in(op_temp),
        .rd_in(rd12[23:16]),
        .imm8_in(imm8_temp),
        .ab_raw_in(r12_data),
        //
        .opcode(opcode),
        .ab_raw(ab_raw),
        .rd(rd_temp),
        .imm8(imm8),
        .we(we_temp2),
        .flush2(flush2),
        //
        .bus_data_in(bus_data_in),
        .bus_data(bus_data_temp)
    );

    alu u_alu(
        .ab_raw(ab_raw),
        .bus_data(bus_data_temp),
        .imm8(imm8),
        .opcode(opcode),
        //
        .result(result)
        );

    wr_reg u_wr_reg(
        .clk(clk),
        .stall(stall_bus),
        .we_in(we_temp2),
        .stage(stage),
        .flush2(flush2),
        .rst(rst),
        .result_in(result),
        .rd_in(rd_temp),
        //
        .rd_data(rd_data),
        .rd(rd),
        .we(we)
    );
    
    reg_f u_reg_f(
        .clk(clk), 
        .rst(rst),
        .we(we), 
        .tx_busy(tx_busy),
        .jmpflg(jmpflg),
        .addr_r12(rd12),
        .rd(rd),
        .ra_in(ra_fo),
        .rd_data(rd_data),
        //
        .j_flag(j_flag),
        .ra(ra_ba),
        .rd12_data(rd12_data)
        );

    irq_controller u_irq_con(
        .clk(clk),
        .iret(iret),
        .rst(rst),
        .irq_addr_in(irq_bus),
        .pc_addr_in(pc_addr),
        .bytmov(bytmov),
        //
        .irq_addr(irq_addr),
        .irq_flush(irq_flush),
        //
        .bus_addr_in(bus_addr_out[15:12]),
        .bus_data_in(bus_data_out),
        .bus_sig_in(bus_sig_out[0])
    );
endmodule

