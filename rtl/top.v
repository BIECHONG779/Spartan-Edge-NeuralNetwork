// top.v — 顶层: 100 MHz 时钟 (板载有源晶振), 2 颗用户按键, 2 颗 SK6805 RGB + 2 颗普通 LED
// 数据流: 按键 → debounce → button_capture → mlp_inference → LED 着色 → ws2812_driver
// 复位: 板上 FPGA_RST 不接顶层, 用上电延时复位 (24-bit 计数器达到目标后 rst_n=1)
//
// 安全自检:
//   - 所有外部输入仅 2 根按键 GPIO, 已去抖, 无注入路径;
//   - WS2812 输出固定时序, 颜色由 class_id 选定, 不接受任意数据;
//   - 推理模块的权重在比特流中固化 (BRAM init), 运行时不可改写.
`timescale 1ns/1ps
`include "mem/params.vh"

module top (
    input  wire sysclk,            // 板载 100 MHz 有源晶振 (H4)
    input  wire btn0,              // USER1 按键 (C3, 低有效, XDC PULLUP)
    input  wire btn1,              // USER2 按键 (M4, 低有效, XDC PULLUP)
    output wire ws2812_din,        // SK6805 链 DIN (N11), 板上 2 颗 RGB LED
    output wire [1:0] led_status   // 板载 2 颗普通 LED (J1=FPGA_LED1, A13=FPGA_LED2)
);
    localparam integer CLK_HZ = 100_000_000;

    // ---------- 上电复位 ----------
    reg [23:0] por_cnt = 0;
    reg        rst_n   = 1'b0;
    always @(posedge sysclk) begin
        if (por_cnt != 24'hFF_FFFF) begin
            por_cnt <= por_cnt + 1'b1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    // ---------- 50 Hz tick ----------
    wire tick;
    clk_div #(.CLK_HZ(CLK_HZ), .TICK_HZ(50)) u_tick (
        .clk(sysclk), .rst_n(rst_n), .tick(tick)
    );

    // ---------- 去抖 ----------
    // 板上 USER1/2 按键 "按下=低", RTL 内部约定 "按下=高", 这里反相一次.
    wire btn0_act = ~btn0;
    wire btn1_act = ~btn1;
    wire btn0_db, btn1_db;
    debounce u_db0 (.clk(sysclk), .rst_n(rst_n), .tick(tick),
                    .btn_raw(btn0_act), .btn_stable(btn0_db));
    debounce u_db1 (.clk(sysclk), .rst_n(rst_n), .tick(tick),
                    .btn_raw(btn1_act), .btn_stable(btn1_db));

    // ---------- 采样 ----------
    wire [127:0] vec;
    wire         vec_valid;
    button_capture #(.N_FRAMES(64)) u_cap (
        .clk(sysclk), .rst_n(rst_n), .tick(tick),
        .btn0(btn0_db), .btn1(btn1_db),
        .vec(vec), .vec_valid(vec_valid)
    );

    // ---------- 推理 ----------
    wire [1:0] class_id;          // 2 bit for 4 classes
    wire       infer_done;
    mlp_inference u_mlp (
        .clk(sysclk), .rst_n(rst_n),
        .start(vec_valid),
        .x_vec(vec),
        .done(infer_done),
        .class_id(class_id)
    );

    // ---------- 类别 → 2 颗 RGB LED 颜色 ----------
    // 4 类手势: USER1/2 长按 + 双击. 颜色字段 24 bit = {G[7:0], R[7:0], B[7:0]}.
    function [23:0] led1_color;
        input [1:0] cls;
        case (cls)
            2'd0: led1_color = {8'h10, 8'h10, 8'h00};   // 黄   (USER1 长按)
            2'd1: led1_color = {8'h00, 8'h00, 8'h20};   // 蓝   (USER1 双击)
            2'd2: led1_color = {8'h00, 8'h20, 8'h20};   // 品红 (USER2 长按)
            2'd3: led1_color = {8'h20, 8'h00, 8'h20};   // 青   (USER2 双击)
        endcase
    endfunction
    function [23:0] led2_color;
        input [1:0] cls;
        case (cls)
            2'd0: led2_color = {8'h10, 8'h10, 8'h00};   // 黄   (USER1 长按)
            2'd1: led2_color = {8'h00, 8'h00, 8'h20};   // 蓝   (USER1 双击)
            2'd2: led2_color = {8'h00, 8'h20, 8'h20};   // 品红 (USER2 长按)
            2'd3: led2_color = {8'h20, 8'h00, 8'h20};   // 青   (USER2 双击)
        endcase
    endfunction

    reg [1:0]   last_class;
    reg [47:0]  grb_pack;       // 2 LED * 24 bit, 第一颗 (LED1) 在高位
    reg         ws_start;
    wire        ws_busy;

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            last_class <= 2'd0;
            grb_pack   <= 48'd0;
            ws_start   <= 1'b0;
        end else begin
            ws_start <= 1'b0;
            if (infer_done) begin
                last_class <= class_id;
                grb_pack   <= {led1_color(class_id), led2_color(class_id)};
                if (!ws_busy) ws_start <= 1'b1;
            end
        end
    end

    ws2812_driver #(.CLK_HZ(CLK_HZ), .N_LEDS(2)) u_ws (
        .clk(sysclk), .rst_n(rst_n),
        .start(ws_start), .grb_pack(grb_pack),
        .data_out(ws2812_din), .busy(ws_busy)
    );

    // ---------- 上电闪烁 ----------
    // 配置完成后两盏普通 LED 同时亮 ~0.67 s, 提供视觉确认 (FPGA alive).
    reg [25:0] por_blink_cnt;
    wire por_blink;
    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) por_blink_cnt <= 0;
        else if (por_blink_cnt < 26'd67_000_000)
            por_blink_cnt <= por_blink_cnt + 1'b1;
    end
    assign por_blink = (por_blink_cnt < 26'd67_000_000);

    assign led_status = por_blink ? 2'b11 : class_id[1:0];

endmodule
