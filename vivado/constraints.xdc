## ============================================================
## constraints.xdc — Spartan Edge Accelerator Board (XC7S15-FTGB196)
##
## !!! 重要 !!!
## 下面的引脚分配基于 Seeed 官方 Wiki / 板手册的常见映射,
## 实际烧录前请打开 Board/Spartan Edge Accelerator Board v1.0.pdf
## 与本文件逐一核对; 不一致请以 PDF 为准.
##
## 板载资源 (典型):
##   - 50 MHz 晶振 -> H4
##   - 用户按键 USR_BTN0 -> A8 ; USR_BTN1 -> J11 (有上拉, 按下为低)
##   - WS2812 RGB 链 (8 颗) DIN -> H14
##   - 4 颗普通 LED -> H1, K1, J1, G1
##
## 注意: 板上按键默认是 "按下为低", 我们 RTL 假设 "按下为高",
## 所以约束里把 BTN 反相在 RTL 顶层处理 ── 见下方 PULLDOWN/反相 备注.
## ============================================================

## ---- 时钟 ----
set_property PACKAGE_PIN H4 [get_ports clk_50m]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50m]
create_clock -name clk_50m -period 20.000 [get_ports clk_50m]

## ---- 用户按键 (TODO: 与 PDF 核对) ----
set_property PACKAGE_PIN A8  [get_ports btn0]   ;# TODO verify
set_property PACKAGE_PIN J11 [get_ports btn1]   ;# TODO verify
set_property IOSTANDARD LVCMOS33 [get_ports {btn0 btn1}]
set_property PULLUP true         [get_ports {btn0 btn1}]

## ---- WS2812 链 (TODO: 与 PDF 核对) ----
set_property PACKAGE_PIN H14 [get_ports ws2812_din]   ;# TODO verify
set_property IOSTANDARD LVCMOS33 [get_ports ws2812_din]
set_property DRIVE 12 [get_ports ws2812_din]
set_property SLEW FAST [get_ports ws2812_din]

## ---- 普通 LED (用于显示当前 class_id 的低 2 位) (TODO: 与 PDF 核对) ----
set_property PACKAGE_PIN H1 [get_ports {led_status[0]}]   ;# TODO verify
set_property PACKAGE_PIN K1 [get_ports {led_status[1]}]   ;# TODO verify
set_property PACKAGE_PIN J1 [get_ports {led_status[2]}]   ;# TODO verify
set_property PACKAGE_PIN G1 [get_ports {led_status[3]}]   ;# TODO verify
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[*]}]

## ---- 配置: 让 ESP32 通过 SPI(Slave Serial) 加载 .bit ----
## XC7S15 Spartan-7 使用 M[2:0] 选择配置模式; ESP32 走 Slave Serial 时:
##   M2=1, M1=1, M0=1 (board strap 已设)
## 这里不需 XDC 配, 但要确保 BITSTREAM 设置正确:
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33  [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO        [current_design]
