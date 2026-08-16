# ============================================================
# 引脚约束 + 时钟约束
# 目标器件：MicroPhase Z-7 Lite（PL 侧引脚）
# 新架构：UART 走 gpio_group 的 TX/RX 引脚，顶层已无 tx/rx 端口
#   gpio[0] N17  RX    UART 收（接 USB-TTL 的 TX；PULLUP 防悬空）
#   gpio[1] P18  TX    UART 发（接 USB-TTL 的 RX）
#   gpio[2] R16  未用（悬空）
#   gpio[3] R17  未用（悬空）
#   gpio[4] T16  未用（悬空）
#   gpio[5] U17  未用（悬空）
#   gpio[6] P15  LED   低电平点亮（程序配 OUT 模式）
#   gpio[7] V13  IRQ_IN(跳线激活)  低电平触发（程序配 IRQ 模式，按下拉低；PULLUP 防悬空）
# ============================================================

# ===== 时钟：PL_CLK_50M @ N18，50MHz =====
create_clock -period 20.000 -name sys_clk [get_ports clk]
set_property PACKAGE_PIN N18 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]

# ===== GPIO 引脚组 =====
set_property PACKAGE_PIN N17 [get_ports {gpio_pin_bus[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_pin_bus[0]}]
set_property PULLUP TRUE [get_ports {gpio_pin_bus[0]}]

set_property PACKAGE_PIN P18 [get_ports {gpio_pin_bus[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_pin_bus[1]}]

set_property PACKAGE_PIN R16 [get_ports {gpio_pin_bus[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_pin_bus[2]}]

set_property PACKAGE_PIN R17 [get_ports {gpio_pin_bus[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_pin_bus[3]}]

set_property PACKAGE_PIN T16 [get_ports {gpio_pin_bus[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_pin_bus[4]}]

set_property PACKAGE_PIN U17 [get_ports {gpio_pin_bus[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_pin_bus[5]}]

set_property PACKAGE_PIN P15 [get_ports {gpio_pin_bus[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_pin_bus[6]}]

set_property PACKAGE_PIN V13 [get_ports {gpio_pin_bus[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_pin_bus[7]}]
set_property PULLUP TRUE [get_ports {gpio_pin_bus[7]}]

# ===== 复位：PL_KEY2 @ P16，按下低电平有效 =====
# top 端口 rst_n：平时上拉为高（不复位），按下拉低 → 复位
set_property PACKAGE_PIN T12 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_property PULLUP TRUE [get_ports rst_n]

