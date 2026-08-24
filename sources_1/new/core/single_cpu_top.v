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
    input wire rst, stall_bus, tx_busy, i2c_busy,
    input wire [7:0] bus_data_in, 
    input wire [8:0] irq_bus,
    output wire [15:0] bus_addr_out,
    output wire [7:0] bus_data_out, bus_data_irq, bus_data_base,
    output wire [3:0] bus_sig_out
    );

    wire [1:0] stage, bubble;
    wire [12:0] pc_addr, irq_addr;
    wire [31:0] inst_raw_zip;
    wire [25:0] inst_raw_cont1, inst_raw_cont2;
    wire [5:0] opcode1, opcode2, opcode3, opcode_pc;
    wire [23:0] rd12, rd12_raw, rd12_data;
    wire [15:0] r12_data, ab_raw;
    wire [7:0] rd_temp, rd, rd_mov, baseline;
    wire [7:0] rd_data, imm8_temp, imm8;
    wire [15:0] bytmov_pc;
    wire [12:0] ra_fo, ra_ba;
    wire [7:0] result;
    wire [1:0] jmpflg, j_flag;
    wire we_temp1, we_temp2, we, irq_en, unz_irq_en;
    wire frz, iret, cstall, cstalled;
    wire jmp_flush, irq_flush;

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
        .cstalled(cstalled),
        .irq_flag(irq_flush),
        .stage(stage),
        .j_flag(j_flag),
        .op_raw(opcode_pc),
        .bytmov(bytmov_pc),
        .jmp_flush(jmp_flush),
        .ra_in(ra_ba),
        .irq_addr(irq_addr),
        //
        .pc_addr(pc_addr),
        .ra(ra_fo),
        .jmpflg(jmpflg),
        .bubble(bubble)
        );

    ins_rom u_ins_rom(
        .clk(clk),
        .rst(rst),
        .addr(pc_addr),
        .jmp_flush(jmp_flush),
        .irq_flush(irq_flush),
        .stall(stall_bus),
        .cstall(cstall),
        //
        .inst_raw(inst_raw_zip)
        );

    unzipper u_unzipper(
        .clk(clk),
        .rst(rst),
        .jmp_flush(jmp_flush),
        .irq_flush(irq_flush),
        .stall(stall_bus),
        .stage(stage),
        .inst_raw_in(inst_raw_zip),
        //
        .inst_raw_cont(inst_raw_cont1),
        .opcode(opcode1),
        .cstall(cstall),
        .cstalled(cstalled),   
        .addr_dr12(rd12_raw),
        .irq_en(unz_irq_en)
    );

    rpu u_rpu (
        .clk(clk),
        .rst(rst),
        .jmp_flush(jmp_flush),
        .stall(stall_bus),
        .stage(stage),
        .irq_flush(irq_flush),
        .addr_r12_raw(rd12_raw),
        .addr_r12_mov(rd12),
        .baseline(baseline),
        .inst_raw_cont_in(inst_raw_cont1),
        .opcode_in(opcode1),
        .inst_raw_cont(inst_raw_cont2),
        .opcode(opcode2),
        .bytmov_to_pc(bytmov_pc),
        .opcode_to_pc(opcode_pc),
        //
        .bus_data_out(bus_data_base),
        .bus_addr_in(bus_addr_out),
        .bus_sig_in(bus_sig_out)
    );

    decoder u_decoder(
        .rst(rst),
        .irq_flush(irq_flush),
        .opcode(opcode2),
        .inst_raw_cont(inst_raw_cont2),
        .result_last_in(result),
        .rd_last1(rd_temp),
        .rd_last2(rd),
        .baseline(baseline),
        .rd12_data(rd12_data),
        .rd_data(rd_data),
        .j_flag(j_flag),
        //
        .r12_data(r12_data),
        .rd_out(rd_mov),
        .imm8(imm8_temp),
        .frz(frz),
        .we(we_temp1),
        .jmp_flush(jmp_flush),
        .iret(iret),
        .irq_en(irq_en),
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
        .opcode_in(opcode2),
        .rd_in(rd_mov),
        .imm8_in(imm8_temp),
        .ab_raw_in(r12_data),
        //
        .opcode(opcode3),
        .ab_raw(ab_raw),
        .rd(rd_temp),
        .imm8(imm8),
        .we(we_temp2),
        //
        .bus_data_in(bus_data_in),
        .bus_data(bus_data_temp)
    );

    alu u_alu(
        .ab_raw(ab_raw),
        .bus_data(bus_data_temp),
        .imm8(imm8),
        .opcode(opcode3),
        //
        .result(result)
        );

    wr_reg u_wr_reg(
        .clk(clk),
        .stall(stall_bus),
        .we_in(we_temp2),
        .stage(stage),
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
        .stall(stall_bus),
        .we(we), 
        .tx_busy(tx_busy),
        .i2c_busy(i2c_busy),
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
        .irq_bus_in(irq_bus),
        .pc_addr_in(pc_addr),
        .irq_en(irq_en & unz_irq_en),
        .stall(stall_bus),
        .cstalled(cstalled),
        .bubble(bubble),
        //
        .irq_addr(irq_addr),
        .irq_flush(irq_flush),
        //
        .bus_addr_in(bus_addr_out),
        .bus_data_in(bus_data_out),
        .bus_sig_in(bus_sig_out[0]),
        .bus_data_out(bus_data_irq)
    );
endmodule

