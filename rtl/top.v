// top.v — 顶层: 50MHz 时钟, 2 按键, 8 颗 WS2812
// 数据流: 按键 → debounce → button_capture → mlp_inference → LED 着色 → ws2812_driver
// 复位: 板上无 RST 按键时, 用上电延时复位 (24-bit 计数器达到目标后 rst_n=1)
//
// 安全自检:
//   - 所有外部输入仅 2 根按键 GPIO, 已去抖, 无注入路径;
//   - WS2812 输出固定时序, 颜色由 class_id 选定, 不接受任意数据;
//   - 推理模块的权重在比特流中固化 (BRAM init), 运行时不可改写.
`timescale 1ns/1ps
`include "mem/params.vh"

module top (
    input  wire clk_50m,
    input  wire btn0,
    input  wire btn1,
    output wire ws2812_din,        // SK6805 链 DIN (板上 2 颗 RGB LED, 兼容 WS2812 协议)
    output wire [1:0] led_status   // 板载 2 颗普通 LED (FPGA_LED1/2), 二进制显示 class_id
);
    // ---------- 上电复位 ----------
    reg [23:0] por_cnt = 0;
    reg        rst_n   = 1'b0;
    always @(posedge clk_50m) begin
        if (por_cnt != 24'hFF_FFFF) begin
            por_cnt <= por_cnt + 1'b1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    // ---------- 50 Hz tick ----------
    wire tick;
    clk_div #(.CLK_HZ(50_000_000), .TICK_HZ(50)) u_tick (
        .clk(clk_50m), .rst_n(rst_n), .tick(tick)
    );

    // ---------- 去抖 ----------
    // 板上 USER1/2 按键 "按下=低", RTL 内部约定 "按下=高", 这里反相一次.
    wire btn0_act = ~btn0;
    wire btn1_act = ~btn1;
    wire btn0_db, btn1_db;
    debounce u_db0 (.clk(clk_50m), .rst_n(rst_n), .tick(tick),
                    .btn_raw(btn0_act), .btn_stable(btn0_db));
    debounce u_db1 (.clk(clk_50m), .rst_n(rst_n), .tick(tick),
                    .btn_raw(btn1_act), .btn_stable(btn1_db));

    // ---------- 采样 ----------
    wire [127:0] vec;
    wire         vec_valid;
    button_capture #(.N_FRAMES(64)) u_cap (
        .clk(clk_50m), .rst_n(rst_n), .tick(tick),
        .btn0(btn0_db), .btn1(btn1_db),
        .vec(vec), .vec_valid(vec_valid)
    );

    // ---------- 推理 ----------
    wire [1:0] class_id;
    wire       infer_done;
    mlp_inference u_mlp (
        .clk(clk_50m), .rst_n(rst_n),
        .start(vec_valid),
        .x_vec(vec),
        .done(infer_done),
        .class_id(class_id)
    );

    // ---------- 类别 → 2 颗 RGB LED 颜色 ----------
    // 板上只有 2 颗 SK6805 RGB LED, 用 (LED1, LED2) 颜色组合区分 4 类.
    // 颜色字段 24 bit = {G[7:0], R[7:0], B[7:0]} (SK6805/WS2812 协议).
    // 选用低亮度 0x20 避免直视刺眼.
    function [23:0] led1_color;
        input [1:0] cls;
        case (cls)
            2'd0: led1_color = {8'h20, 8'h00, 8'h00};   // 绿 (BTN0 短按)
            2'd1: led1_color = {8'h00, 8'h00, 8'h00};   // 灭 (BTN1 短按)
            2'd2: led1_color = {8'h10, 8'h10, 8'h00};   // 黄 (BTN0 长按)
            2'd3: led1_color = {8'h00, 8'h00, 8'h20};   // 蓝 (BTN0 双击)
        endcase
    endfunction
    function [23:0] led2_color;
        input [1:0] cls;
        case (cls)
            2'd0: led2_color = {8'h00, 8'h00, 8'h00};   // 灭
            2'd1: led2_color = {8'h00, 8'h20, 8'h00};   // 红
            2'd2: led2_color = {8'h10, 8'h10, 8'h00};   // 黄
            2'd3: led2_color = {8'h00, 8'h00, 8'h20};   // 蓝
        endcase
    endfunction

    reg [1:0]   last_class;
    reg [47:0]  grb_pack;       // 2 LED * 24 bit, 第一颗 (LED1) 在高位
    reg         ws_start;
    wire        ws_busy;

    always @(posedge clk_50m or negedge rst_n) begin
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

    ws2812_driver #(.CLK_HZ(50_000_000), .N_LEDS(2)) u_ws (
        .clk(clk_50m), .rst_n(rst_n),
        .start(ws_start), .grb_pack(grb_pack),
        .data_out(ws2812_din), .busy(ws_busy)
    );

    assign led_status = last_class;

endmodule
