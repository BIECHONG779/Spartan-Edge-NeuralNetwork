// ws2812_driver.v — N 路菊花链 WS2812(B) / SK6805 单线驱动
// 协议 (典型 800 kHz, 容差 ±150 ns):
//   '0' bit: T0H = 0.4 us H, T0L = 0.85 us L
//   '1' bit: T1H = 0.8 us H, T1L = 0.45 us L
//   reset  : >= 50 us 低电平
// 数据顺序: G7..G0, R7..R0, B7..B0, 第一颗 LED 数据先发, 然后菊花链转发.
//
// 输入: N_LEDS 个 24-bit GRB 值, 加载到 frame_buf 后由 send 触发发送.
// 安全自检: 输出 1 根 GPIO, 时序由内部计数器固定, 不接受外部数据通道.
`timescale 1ns/1ps
module ws2812_driver #(
    parameter integer CLK_HZ   = 100_000_000,
    parameter integer N_LEDS   = 2
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [24*N_LEDS-1:0] grb_pack,    // {LED0_GRB, LED1_GRB, ...}
    output reg         data_out,
    output reg         busy
);
    // 时序参数 (cycles), 100 MHz 下分别为 40 / 85 / 80 / 45 / 6000
    localparam integer T0H = (CLK_HZ * 400)  / 1_000_000_000;
    localparam integer T0L = (CLK_HZ * 850)  / 1_000_000_000;
    localparam integer T1H = (CLK_HZ * 800)  / 1_000_000_000;
    localparam integer T1L = (CLK_HZ * 450)  / 1_000_000_000;
    localparam integer TRS = (CLK_HZ * 60)   / 1_000_000;

    localparam integer TOTAL_BITS = 24 * N_LEDS;
    localparam integer LOG_BITS   = $clog2(TOTAL_BITS + 1);

    reg [24*N_LEDS-1:0] shift;
    reg [LOG_BITS-1:0]  bit_idx;
    reg [15:0]          tcnt;

    localparam [1:0] S_IDLE=0, S_HIGH=1, S_LOW=2, S_RES=3;
    reg [1:0] state;

    wire cur_bit = shift[24*N_LEDS-1];
    wire [15:0] th = cur_bit ? T1H[15:0] : T0H[15:0];
    wire [15:0] tl = cur_bit ? T1L[15:0] : T0L[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            data_out <= 1'b0;
            busy     <= 1'b0;
            shift    <= 0;
            bit_idx  <= 0;
            tcnt     <= 0;
        end else begin
            case (state)
            S_IDLE: begin
                data_out <= 1'b0;
                if (start) begin
                    shift   <= grb_pack;
                    bit_idx <= 0;
                    tcnt    <= 0;
                    busy    <= 1'b1;
                    state   <= S_HIGH;
                end else begin
                    busy <= 1'b0;
                end
            end
            S_HIGH: begin
                data_out <= 1'b1;
                if (tcnt == th - 1) begin
                    tcnt  <= 0;
                    state <= S_LOW;
                end else tcnt <= tcnt + 1'b1;
            end
            S_LOW: begin
                data_out <= 1'b0;
                if (tcnt == tl - 1) begin
                    tcnt  <= 0;
                    if (bit_idx == TOTAL_BITS - 1) begin
                        state <= S_RES;
                    end else begin
                        bit_idx <= bit_idx + 1'b1;
                        shift   <= {shift[24*N_LEDS-2:0], 1'b0};
                        state   <= S_HIGH;
                    end
                end else tcnt <= tcnt + 1'b1;
            end
            S_RES: begin
                data_out <= 1'b0;
                if (tcnt == TRS - 1) begin
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end else tcnt <= tcnt + 1'b1;
            end
            endcase
        end
    end
endmodule
