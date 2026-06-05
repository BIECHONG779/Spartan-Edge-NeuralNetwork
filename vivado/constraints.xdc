## ============================================================
## constraints.xdc — Spartan Edge Accelerator Board v1.0
## (Seeed XC7S15-1FTGB196C, 引脚来自 Seeed 官方 Demo_project/spi2gpio.xdc 与 wiki)
##
## 板载资源映射 (实测与原理图核对):
##   时钟       : H4   (50 MHz osc)
##   USER1 按键 : C3   (低有效, 按下接 GND, 内部上拉)  -> RTL btn0
##   USER2 按键 : M4   (低有效)                        -> RTL btn1
##   FPGA_RST   : D14  (低有效) -- 用上电延时复位为主, 这里不接顶层
##   SK6805 链  : N11  (2 颗 RGB LED, WS2812 协议兼容) -> ws2812_din
##   FPGA_LED1  : J1   (普通 LED)  -> led_status[0]
##   FPGA_LED2  : A13  (普通 LED)  -> led_status[1]
##
## 重要: 板上 USER1/2 物理按键 "按下=低", 但我们的 RTL 假设 "按下=高".
##       为避免改动 RTL, 在 XDC 启用 PULLUP, 并在顶层用反相 wire 适配.
##       (见 rtl/top.v 顶部注释: 真实工程中如果你愿意, 可以直接改 debounce 极性)
##
## 配置流来源: ESP32 Slave Serial -> SD card .bit, 不需要 JTAG 约束.
## ============================================================

## ---- 时钟 ----
set_property PACKAGE_PIN H4 [get_ports clk_50m]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50m]
create_clock -name clk_50m -period 20.000 [get_ports clk_50m]

## ---- 用户按键 USER1 / USER2 (低有效, 顶层用反相输入即可) ----
set_property PACKAGE_PIN C3 [get_ports btn0]
set_property PACKAGE_PIN M4 [get_ports btn1]
set_property IOSTANDARD LVCMOS33 [get_ports {btn0 btn1}]
set_property PULLUP true        [get_ports {btn0 btn1}]

## ---- SK6805 串行 RGB LED 数据线 ----
set_property PACKAGE_PIN N11 [get_ports ws2812_din]
set_property IOSTANDARD LVCMOS33 [get_ports ws2812_din]
set_property DRIVE 12 [get_ports ws2812_din]
set_property SLEW FAST [get_ports ws2812_din]

## ---- 板载普通 LED ----
set_property PACKAGE_PIN J1  [get_ports {led_status[0]}]   ;# FPGA_LED1
set_property PACKAGE_PIN A13 [get_ports {led_status[1]}]   ;# FPGA_LED2
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[*]}]

## ---- bitstream 设置 (ESP32 Slave Serial 加载需要) ----
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33  [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO        [current_design]
