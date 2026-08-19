`timescale 1ns / 1ps
module lindbb_tb;
    reg clk = 0, rst_n = 1;
    wire [7:0] gpio_pin_bus;
    reg rx0_drv = 1'b1, rx0_en = 1'b0;
    assign gpio_pin_bus[0] = rx0_en ? rx0_drv : 1'bz;
    pullup (gpio_pin_bus[0]);
    assign gpio_pin_bus[1] = 1'bz;
    pullup (gpio_pin_bus[1]);
    single_mcu_top u_top(.clk(clk), .rst_n(rst_n), .gpio_pin_bus(gpio_pin_bus));
    always #10 clk = ~clk;
    initial begin rst_n = 0; #100; rst_n = 1; repeat(15) @(posedge clk);
        force u_top.u_rst_buf.rst_stable = 1'b0; end
    initial begin #1;
        $readmemh("E:/Vivado_Projects/project_self-try/temp_tetris_tb/isr_test/lindbb.hex",
                  u_top.u_cpu.u_ins_rom.mem);
    end
    integer c;
    initial begin
        repeat(150) @(posedge clk);
        $display("r4=%02X(应AA) r5=%02X(应BB) RAM9000=%02X RAM9001=%02X",
                 u_top.u_cpu.u_reg_f.regs[4], u_top.u_cpu.u_reg_f.regs[5],
                 u_top.u_ram_top.ram_sec_2.mem[16'h000], u_top.u_ram_top.ram_sec_2.mem[16'h001]);
        if (u_top.u_cpu.u_reg_f.regs[4] == 8'hAA && u_top.u_cpu.u_reg_f.regs[5] == 8'hBB)
            $display("PASS: 背靠背 LIND->LIND 读对");
        else if (u_top.u_cpu.u_reg_f.regs[4] == 8'hAA && u_top.u_cpu.u_reg_f.regs[5] != 8'hBB)
            $display("FAIL: 第2个LIND读错 → r5=%02X (应 BB)", u_top.u_cpu.u_reg_f.regs[5]);
        else
            $display("FAIL: 第1个LIND也错 → r4=%02X r5=%02X", u_top.u_cpu.u_reg_f.regs[4], u_top.u_cpu.u_reg_f.regs[5]);
        $finish;
    end
    initial begin #10000000; $finish; end
endmodule
