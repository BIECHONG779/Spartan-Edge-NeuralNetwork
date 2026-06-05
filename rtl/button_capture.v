// button_capture.v — 在 50 Hz tick 上按帧记录 BTN0/BTN1, 共 64 帧 = 128 bit
// 触发: 检测到任一按键边沿后, 从下一 tick 开始连续采集 64 个 tick 的电平.
// 安全自检: 输入仅来自板载按键 (已去抖), 输出固定 128 bit 寄存器, 不涉及外部数据通道.
`timescale 1ns/1ps
module button_capture #(
    parameter integer N_FRAMES = 64
)(
    input  wire clk,
    input  wire rst_n,
    input  wire tick,           // 50 Hz
    input  wire btn0,           // 已去抖
    input  wire btn1,
    output reg  [2*N_FRAMES-1:0] vec,   // MSB = frame 0 BTN0
    output reg  vec_valid       // 单 cycle 高电平表示 vec 已就绪
);
    localparam integer LOG = $clog2(N_FRAMES);
    reg [LOG:0] cnt;
    reg busy;
    reg btn0_d, btn1_d;

    wire any_edge = (btn0 & ~btn0_d) | (btn1 & ~btn1_d);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt        <= 0;
            busy       <= 1'b0;
            vec        <= 0;
            vec_valid  <= 1'b0;
            btn0_d     <= 1'b0;
            btn1_d     <= 1'b0;
        end else begin
            vec_valid <= 1'b0;
            btn0_d    <= btn0;
            btn1_d    <= btn1;

            if (!busy && any_edge) begin
                busy <= 1'b1;
                cnt  <= 0;
                vec  <= 0;
            end else if (busy && tick) begin
                // 把当前帧 (BTN0,BTN1) 写到 vec 对应位
                // 帧 0 在最高 2 bit (与 Python 导出顺序一致: bits<<=1 先来的在高位)
                vec <= {vec[2*N_FRAMES-3:0], btn0, btn1};
                if (cnt == N_FRAMES-1) begin
                    busy      <= 1'b0;
                    vec_valid <= 1'b1;
                    cnt       <= 0;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end
endmodule
