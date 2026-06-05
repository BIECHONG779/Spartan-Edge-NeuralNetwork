// debounce.v — 简易按键去抖, 输出与输入同电平的稳定信号
// 安全自检: 仅处理板载按键 GPIO, 时钟域单一, 无外部数据流入.
`timescale 1ns/1ps
module debounce #(
    parameter integer N = 16   // 连续 N 个 tick 一致才更新
)(
    input  wire clk,
    input  wire rst_n,
    input  wire tick,
    input  wire btn_raw,
    output reg  btn_stable
);
    reg [$clog2(N+1)-1:0] cnt;
    reg btn_sync_0, btn_sync_1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {btn_sync_0, btn_sync_1} <= 2'b00;
        else        {btn_sync_0, btn_sync_1} <= {btn_raw, btn_sync_0};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt        <= 0;
            btn_stable <= 1'b0;
        end else if (tick) begin
            if (btn_sync_1 == btn_stable) begin
                cnt <= 0;
            end else if (cnt == N-1) begin
                btn_stable <= btn_sync_1;
                cnt        <= 0;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule
