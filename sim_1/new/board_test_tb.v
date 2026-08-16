`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// MCU v1.2 上板程序回归（ins_rom.hex，UART 走 GPIO + KEY2 切回环 + LED 0.2s）
//   引脚：pin0=RX(N17) pin1=TX(P18) pin6=LED(P15,低电平点亮) pin7=KEY2(T12,按下低电平)
//   前提：gpio_group.v 的 IRQ 已反转成低电平有效（gpio_irq[0/1] <= ~gpio_pin_bus[i]）
//   Phase1 上电 "cpu ready\r\n" 11 字节
//   Phase2 回环开(默认 r2=1)：发 a B 5，收大小写翻转回显 A b $0x15
//   Phase3 KEY2 按下→中断→回环关：r2==0；发 'a' 无回显
//   Phase4 KEY2 再按→回环开：r2==1；发 'x' 回显 'X'
//   Phase5 LED：回发后 pin6 低(亮)，~0.2s 后 pin6 高(灭)
// 运行：cd project_self-try.srcs && iverilog -g2012 -o /tmp/board_sim \
//          sources_1/new/mcu/single_mcu_top.v sources_1/new/mcu/rst_buf.v \
//          sources_1/new/core/*.v \
//          sources_1/new/peripherals/ram_top.v sources_1/new/peripherals/ram_sec.v \
//          sources_1/new/peripherals/uart_top.v sources_1/new/peripherals/uart_rx.v \
//          sources_1/new/peripherals/uart_tx.v sources_1/new/peripherals/timer.v \
//          sources_1/new/peripherals/gpio_group.v sim_1/new/board_test_tb.v \
//       && vvp /tmp/board_sim
//////////////////////////////////////////////////////////////////////////////////
module board_test_tb;

    localparam MCNT = 434;              // 115200 @ 50MHz

    reg clk = 0, rst_n = 1;
    wire [7:0] gpio_pin_bus;

    // pin0 = RX：模块配 RX 前是输出（强驱动 0），配 RX 后三态；tb 经 pullup 弱上拉驱动
    reg rx0_drv = 1'b1;
    reg rx0_en = 1'b0;
    assign gpio_pin_bus[0] = rx0_en ? rx0_drv : 1'bz;
    pullup (gpio_pin_bus[0]);

    // pin7 = KEY2：idle 高（不按），按下拉低；模块配 IRQ 后为三态
    reg key_drv = 1'b1;
    reg key_en = 1'b0;
    assign gpio_pin_bus[7] = key_en ? key_drv : 1'bz;
    pullup (gpio_pin_bus[7]);

    single_mcu_top u_top(
        .clk(clk), .rst_n(rst_n),
        .gpio_pin_bus(gpio_pin_bus)
    );

    always #10 clk = ~clk;              // 50MHz

    integer i, pass = 0, fail = 0;
    reg [7:0] b;
    reg [7:0] banner [0:10];
    reg found_tmo;

    // 载入上板程序（#1 确保在 ins_rom.v 的 $readmemh 之后覆盖）
    initial begin
        #1;
        $readmemh("E:/Vivado_Projects/project_self-try/project_self-try.srcs/ins_rom.hex",
                  u_top.u_cpu.u_ins_rom.mem);
    end

    // 发一个字节到 RX 引脚（pin0）：1 起始 + 8 数据(LSB first) + 1 停止
    task send_byte(input [7:0] d);
        integer k;
        begin
            rx0_drv = 0;
            repeat(MCNT) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                rx0_drv = d[k];
                repeat(MCNT) @(posedge clk);
            end
            rx0_drv = 1;
            repeat(MCNT) @(posedge clk);
        end
    endtask

    // 从 TX 引脚（pin1）收一个字节：等下降沿（起始位）→ 逐位中点采样
    task recv_byte(output [7:0] d);
        integer k;
        begin
            while (gpio_pin_bus[1]) @(posedge clk);
            repeat(MCNT/2) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                repeat(MCNT) @(posedge clk);
                d[k] = gpio_pin_bus[1];
            end
            repeat(MCNT/2) @(posedge clk);
        end
    endtask

    // 带超时收字节：tmo 个时钟内无起始位 → found_tmo=0 返回
    task recv_byte_timeout(output [7:0] d, input integer tmo);
        integer k, cnt;
        begin
            d = 8'h00;
            found_tmo = 1'b0;
            cnt = 0;
            while (gpio_pin_bus[1] && cnt < tmo) begin
                @(posedge clk);
                cnt = cnt + 1;
            end
            if (cnt >= tmo) found_tmo = 1'b0;
            else begin
                found_tmo = 1'b1;
                repeat(MCNT/2) @(posedge clk);
                for (k = 0; k < 8; k = k + 1) begin
                    repeat(MCNT) @(posedge clk);
                    d[k] = gpio_pin_bus[1];
                end
                repeat(MCNT/2) @(posedge clk);
            end
        end
    endtask

    // 按一次 KEY2：按下(低)→中断翻转 r2→ISR 切 IN 轮询等松手(去抖)→松手恢复 IRQ
    task press_key(input [7:0] old_r2);
        begin
            key_drv = 0; key_en = 1;                        // 按下
            while (u_top.u_cpu.u_reg_f.regs[2] === old_r2) @(posedge clk);   // 等 ISR 翻转 r2
            while (u_top.u_gpio.gpio_mode[7] !== 4'b0010) @(posedge clk);    // 等 ISR 布防为 IN 轮询
            repeat(10) @(posedge clk);                      // 保持按住一小段时间
            key_en = 0;                                     // 松手（pullup 拉高）
            while (u_top.u_gpio.gpio_mode[7] !== 4'b0011) @(posedge clk);    // 等去抖轮询结束、恢复 IRQ
            repeat(30) @(posedge clk);
        end
    endtask

    initial begin
        banner[0] = "c"; banner[1] = "p"; banner[2] = "u"; banner[3] = " ";
        banner[4] = "r"; banner[5] = "e"; banner[6] = "a"; banner[7] = "d";
        banner[8] = "y"; banner[9] = 8'h0D; banner[10]= 8'h0A;
    end

    // 复位：低有效。rst_buf 上电复位脉冲长达 2M 拍≈42ms，纯仿真太耗时；
    // 先让真实复位跑 ~15 拍给同步复位外设清零，再 force 内部 rst 短路掉长脉冲。
    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
        repeat(15) @(posedge clk);
        force u_top.u_rst_buf.rst_stable = 1'b0;
    end

    initial begin
        #200;
        // ===== Phase1: banner =====
        while (u_top.u_gpio.gpio_mode[1] !== 4'b0101) @(posedge clk);
        repeat(10) @(posedge clk);
        $display("===== Phase1: banner 'cpu ready\\r\\n' =====");
        for (i = 0; i < 11; i = i + 1) begin
            recv_byte(b);
            if (b == banner[i]) begin
                $display("  TX[%0d] 0x%02h OK", i, b);
                pass = pass + 1;
            end else begin
                $display("  TX[%0d] 0x%02h (期望 0x%02h)  FAIL", i, b, banner[i]);
                fail = fail + 1;
            end
        end

        // 使能引脚驱动：等 pin0=RX、pin7=IRQ 配好
        while (u_top.u_gpio.gpio_mode[0] !== 4'b0110) @(posedge clk);
        while (u_top.u_gpio.gpio_mode[7] !== 4'b0011) @(posedge clk);
        repeat(10) @(posedge clk);
        rx0_en = 1;
        key_en = 1;

        // ===== Phase2: 回环开（默认 r2=1）=====
        $display("===== Phase2: 回环开（默认）=====");
        if (u_top.u_cpu.u_reg_f.regs[2] == 8'h01) begin
            $display("  r2=1 OK");
            pass = pass + 1;
        end else begin
            $display("  r2=0x%02h FAIL（期望 1）", u_top.u_cpu.u_reg_f.regs[2]);
            fail = fail + 1;
        end
        begin : p2
            reg [7:0] txq [0:2];
            txq[0] = 8'h61; txq[1] = 8'h42; txq[2] = 8'h35;
            for (i = 0; i < 3; i = i + 1) begin
                send_byte(txq[i]);
                recv_byte(b);
                if (b == (txq[i] ^ 8'h20)) begin
                    $display("  send 0x%02h -> recv 0x%02h  OK", txq[i], b);
                    pass = pass + 1;
                end else begin
                    $display("  send 0x%02h -> recv 0x%02h（期望 0x%02h）  FAIL", txq[i], b, txq[i] ^ 8'h20);
                    fail = fail + 1;
                end
            end
        end

        // ===== Phase3: KEY2 按下 → 回环关 =====
        $display("===== Phase3: KEY2 按下→回环关 =====");
        press_key(8'h01);
        if (u_top.u_cpu.u_reg_f.regs[2] == 8'h00) begin
            $display("  r2=0 OK（回环关）");
            pass = pass + 1;
        end else begin
            $display("  r2=0x%02h FAIL（期望 0）", u_top.u_cpu.u_reg_f.regs[2]);
            fail = fail + 1;
        end
        send_byte(8'h61);                       // 发 'a'，回环关不应回显
        recv_byte_timeout(b, MCNT * 20);
        if (!found_tmo) begin
            $display("  回环关：无回显 OK");
            pass = pass + 1;
        end else begin
            $display("  回环关：却收到 0x%02h  FAIL", b);
            fail = fail + 1;
        end

        // ===== Phase4: KEY2 再按 → 回环开 =====
        $display("===== Phase4: KEY2 再按→回环开 =====");
        press_key(8'h00);
        if (u_top.u_cpu.u_reg_f.regs[2] == 8'h01) begin
            $display("  r2=1 OK（回环开）");
            pass = pass + 1;
        end else begin
            $display("  r2=0x%02h FAIL（期望 1）", u_top.u_cpu.u_reg_f.regs[2]);
            fail = fail + 1;
        end
        send_byte(8'h78);                       // 发 'x'，回环开应回显 'X'
        recv_byte(b);
        if (b == 8'h58) begin
            $display("  回环开：0x78 -> 0x58 'X' OK");
            pass = pass + 1;
        end else begin
            $display("  回环开：收到 0x%02h（期望 0x58 'X'）  FAIL", b);
            fail = fail + 1;
        end

        // ===== Phase5: LED 亮（跳过 timer 熄灭检查，0.2s 慢等）=====
        $display("===== Phase5: LED 亮（跳过 timer 熄灭检查）=====");
        begin : p5
            integer w;
            w = 0;
            // 回发后 LED 应亮（pin6 低）；若刚好在两次 timer tick 之间未写，等至多 100k 拍
            while (gpio_pin_bus[6] !== 1'b0 && w < 100000) begin
                @(posedge clk); w = w + 1;
            end
            if (gpio_pin_bus[6] === 1'b0) begin
                $display("  LED 亮（pin6=0） OK");
                pass = pass + 1;
            end else begin
                $display("  LED 未亮  FAIL");
                fail = fail + 1;
            end
        end

        $display("===== 结果: %0d 通过 / %0d 失败 =====", pass, fail);
        if (fail == 0) $display("ALL TESTS PASSED");
        else           $display("SOME TESTS FAILED");
        $finish;
    end

    // 兜底超时：rst_buf 上电复位脉冲 ~2M 拍≈42ms，之后程序 ~5ms 跑完，总 ~47ms；100ms 留 ~2 倍余量
    initial begin
        #100000000;
        $display("===== TIMEOUT =====");
        $finish;
    end
endmodule
