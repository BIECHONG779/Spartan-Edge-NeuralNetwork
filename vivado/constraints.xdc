## ============================================================
## constraints.xdc — Spartan Edge Accelerator Board v1.0
## (Seeed XC7S15-1FTGB196C, 引脚来自原理图截图实测核对)
##
## 板载资源映射 (与 Board/*.pdf 第 1 页 FPGA pinout 与第 3 页 LED 模块逐一核对):
##   时钟       : H4   (SYSCLK, 板载 100 MHz 有源晶振 O3225100MEDA4SC)
##   USER1 按键 : C3   (FPGA_IO10, IO_L1N_T0_34, 低有效, 内部上拉)  -> RTL btn0
##   USER2 按键 : M4   (FPGA_IO11, IO_L23N_T3_34, 低有效, 内部上拉) -> RTL btn1
##   FPGA_RST   : D14  (低有效, 这里不接顶层, 用上电延时复位)
##   SK6805 链  : N11  (FPGA_RGB, LED1.DOUT -> LED2.DIN 菊花链)     -> ws2812_din
##   FPGA_LED1  : J1   (绿 LED, 与 R44 串联到 GND)                  -> led_status[0]
##   FPGA_LED2  : A13  (红 LED, 与 R45 串联到 GND)                  -> led_status[1]
##
## 重要: 板上 USER1/2 物理按键 "按下=低", 但 RTL 假设 "按下=高".
##       为避免改动 RTL, 在 XDC 启用 PULLUP, 顶层用 ~btn 反相后接入 debounce.
##
## 配置流来源: ESP32 Slave Serial 从 SD 卡读 .bit, 不需要 JTAG 约束.
## ============================================================

## ---- 时钟 (100 MHz) ----
set_property PACKAGE_PIN H4 [get_ports sysclk]
set_property IOSTANDARD LVCMOS33 [get_ports sysclk]
create_clock -name sysclk -period 10.000 [get_ports sysclk]

## ---- 用户按键 USER1 / USER2 (低有效, 顶层用反相输入即可) ----
set_property PACKAGE_PIN C3 [get_ports btn0]   ;# FPGA_IO10 / IO_L1N_T0_34
set_property PACKAGE_PIN M4 [get_ports btn1]   ;# FPGA_IO11 / IO_L23N_T3_34
set_property IOSTANDARD LVCMOS33 [get_ports {btn0 btn1}]
set_property PULLUP true        [get_ports {btn0 btn1}]

## ---- SK6805 串行 RGB LED 数据线 (单线菊花链, 共 2 颗 LED) ----
set_property PACKAGE_PIN N11 [get_ports ws2812_din]
set_property IOSTANDARD LVCMOS33 [get_ports ws2812_din]
set_property DRIVE 12 [get_ports ws2812_din]
set_property SLEW FAST [get_ports ws2812_din]

## ---- 板载普通 LED ----
set_property PACKAGE_PIN J1  [get_ports {led_status[0]}]   ;# FPGA_LED1 (Green)
set_property PACKAGE_PIN A13 [get_ports {led_status[1]}]   ;# FPGA_LED2 (Red)
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[*]}]

## ---- bitstream 设置 (ESP32 Slave Serial 加载需要) ----
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33  [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO        [current_design]
