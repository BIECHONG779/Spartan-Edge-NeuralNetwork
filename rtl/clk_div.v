// clk_div.v — 50 MHz 分频出 50 Hz tick (1 cycle 高脉冲)
// 安全自检: 纯本地计数, 无外部输入, 不存在注入面.
`timescale 1ns/1ps
module clk_div #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer TICK_HZ = 50
)(
    input  wire clk,
    input  wire rst_n,
    output reg  tick
);
    localparam integer DIV = CLK_HZ / TICK_HZ;
    localparam integer W   = $clog2(DIV);
    reg [W-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= {W{1'b0}};
            tick <= 1'b0;
        end else if (cnt == DIV-1) begin
            cnt  <= {W{1'b0}};
            tick <= 1'b1;
        end else begin
            cnt  <= cnt + 1'b1;
            tick <= 1'b0;
        end
    end
endmodule
