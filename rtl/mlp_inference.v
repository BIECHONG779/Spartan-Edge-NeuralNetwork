// mlp_inference.v — 串行 MAC 推理引擎 (带流水线 CE)
// 数据通路 (与 train_and_export.py infer_hw 严格一致):
//   FC1: acc1[j] = sum_{k=0..127}( x_q[k] * W1q[k,j] ) + b1q[j]
//        x_bit[k]=1 → x_q=127 ; x_bit[k]=0 → x_q=0  (硬件中 x_q 只取 0 或 127)
//   ReLU + 重量化: hq[j] = clip( (max(0,acc1) * REQ_MUL) >>> REQ_SHIFT , 0, 127 )
//   FC2: acc2[c] = sum_{j=0..H-1}( hq[j] * W2q[j,c] ) + b2q[c]
//   argmax: 在 C 个 acc2 中找最大 idx (C = N_CLASSES, default 4)
//
// 接口:
//   start    : 高一拍启动
//   x_vec    : 128 bit 输入
//   done     : 完成时高一拍
//   class_id : 2 bit 分类结果 (0-3 for 4 classes)
//
// 时序: 内部用 2 分频 CE (有效 50 MHz) 解决 Spartan-7 -1 在 100 MHz
//   下的 setup 违例 (~12.2 ns 关键路径对 10 ns 约束); 多周期约束见
//   vivado/constraints.xdc.
//
// 安全自检:
//   - 所有地址、计数器位宽都 >= 实际范围, 无溢出风险;
//   - 没有外部可控的数组下标 (idx 完全由内部状态机驱动);
//   - 不存在内存越界、除零、命令注入路径.
`timescale 1ns/1ps
`include "mem/params.vh"

module mlp_inference (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       start,
    input  wire [`INPUT_DIM-1:0]      x_vec,     // MSB = 第一个特征
    output reg                        done,
    output reg  [1:0]                 class_id     // 2 bit for 4 classes
);
    localparam integer IN  = `INPUT_DIM;   // 128
    localparam integer H   = `HIDDEN;      // 16
    localparam integer C   = `N_CLASSES;   // 4
    localparam integer LOG_IN = $clog2(IN);   // 7
    localparam integer LOG_H  = $clog2(H);    // 4
    localparam integer LOG_C  = $clog2(C);    // 2

    // ---------- 内部 CE: clk ÷ 2 ----------
    // Spartan-7 -1 的 MAC 关键路径 ~12.2 ns 无法满足 100 MHz (10 ns).
    // 用 1-bit 翻转 CE 使状态机每 2 cycle 走一步 → 有效 50 MHz (20 ns).
    reg ce;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ce <= 1'b0;
        else        ce <= ~ce;
    end

    // ---------- start 展宽 ----------
    // vec_valid (来自 button_capture) 是 1 cycle 脉冲, 可能落在 ce=0 的周期.
    // 用 SR 锁存器展宽到下一个 ce=1, 保证不漏.
    reg start_req;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) start_req <= 1'b0;
        else if (start) start_req <= 1'b1;
        else if (ce && state == S_IDLE) start_req <= 1'b0;
    end

    // ---------- 权重 BRAM ----------
    // W1: 128*16 = 2048 entries, 8-bit signed
    (* ram_style = "block" *) reg signed [7:0] w1_mem [0:IN*H-1];
    (* ram_style = "block" *) reg signed [7:0] w2_mem [0:H*C-1];
    (* ram_style = "block" *) reg signed [31:0] b1_mem [0:H-1];
    (* ram_style = "block" *) reg signed [31:0] b2_mem [0:C-1];

    initial begin
        $readmemh("mem/w1.mem", w1_mem);
        $readmemh("mem/w2.mem", w2_mem);
        $readmemh("mem/b1.mem", b1_mem);
        $readmemh("mem/b2.mem", b2_mem);
    end

    // ---------- 隐藏层缓存 ----------
    reg [7:0] hq [0:H-1];      // 0..127 无符号 (ReLU 后)

    // ---------- 状态机 ----------
    localparam [2:0]
        S_IDLE = 3'd0,
        S_FC1  = 3'd1,   // 累加 W1 over k for current j
        S_REQ  = 3'd2,   // ReLU + requant 写入 hq[j]
        S_FC2  = 3'd3,   // 累加 W2 over j for current c
        S_BIAS2= 3'd4,
        S_ARGM = 3'd5,
        S_DONE = 3'd6;

    reg [2:0]            state;
    reg [LOG_IN-1:0]     k;          // 0..127
    reg [LOG_H:0]        j;          // 0..16
    reg [LOG_C:0]        c;          // 0..4
    reg signed [31:0]    acc;
    reg signed [31:0]    acc2_arr [0:C-1];
    reg [LOG_C-1:0]      best_idx;
    reg signed [31:0]    best_val;

    // 辅助: 当前 W1 索引 = k*H + j
    wire [$clog2(IN*H)-1:0] w1_addr = k * H + j[LOG_H-1:0];
    wire signed [7:0]       w1_val  = w1_mem[w1_addr];
    wire                    x_bit   = x_vec[IN-1 - k];   // frame0 在最高位

    // 当前 W2 索引 = j*C + c
    wire [$clog2(H*C)-1:0]  w2_addr = j[LOG_H-1:0] * C + c[LOG_C-1:0];
    wire signed [7:0]       w2_val  = w2_mem[w2_addr];

    // requant: max(0,acc) * REQ_MUL >>> REQ_SHIFT, 截断到 [0,127]
    function [7:0] requant;
        input signed [31:0] a;
        reg signed [63:0]   m;
        reg signed [31:0]   s;
        begin
            if (a < 0) m = 0;
            else        m = a * `REQ_MUL;
            s = m >>> `REQ_SHIFT;
            if (s < 0)        requant = 8'd0;
            else if (s > 127) requant = 8'd127;
            else              requant = s[7:0];
        end
    endfunction

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            done     <= 1'b0;
            class_id <= 2'd0;
            k        <= 0; j <= 0; c <= 0;
            acc      <= 0;
            best_idx <= 0; best_val <= 0;
            for (i = 0; i < H; i = i + 1) hq[i] <= 0;
            for (i = 0; i < C; i = i + 1) acc2_arr[i] <= 0;
        end else if (ce) begin
            // ---- 仅 ce=1 时推进状态机 (有效 50 MHz) ----
            done <= 1'b0;
            case (state)
            S_IDLE: begin
                if (start_req) begin
                    j     <= 0;
                    k     <= 0;
                    acc   <= b1_mem[0];   // 预加 bias
                    state <= S_FC1;
                end
            end

            // 累加 IN 次: acc += x_q * W1[k,j], k=0..IN-1
            S_FC1: begin
                if (x_bit) acc <= acc + $signed({24'd0, 8'd127}) * w1_val;
                // x_bit=0 时不变
                if (k == IN-1) begin
                    state <= S_REQ;
                end else begin
                    k <= k + 1'b1;
                end
            end

            S_REQ: begin
                hq[j[LOG_H-1:0]] <= requant(acc);
                if (j == H-1) begin
                    j     <= 0;
                    c     <= 0;
                    acc   <= b2_mem[0];
                    state <= S_FC2;
                end else begin
                    j   <= j + 1'b1;
                    k   <= 0;
                    acc <= b1_mem[j + 1];   // 下一神经元 bias
                    state <= S_FC1;
                end
            end

            // 累加 H 次: acc += hq[j] * W2[j,c]
            S_FC2: begin
                acc <= acc + $signed({24'd0, hq[j[LOG_H-1:0]]}) * w2_val;
                if (j == H-1) begin
                    state <= S_BIAS2;
                end else begin
                    j <= j + 1'b1;
                end
            end

            S_BIAS2: begin
                acc2_arr[c[LOG_C-1:0]] <= acc;
                if (c == C-1) begin
                    state    <= S_ARGM;
                    best_idx <= 0;
                    best_val <= 32'h8000_0000;   // 最小值
                    c        <= 0;
                end else begin
                    c   <= c + 1'b1;
                    j   <= 0;
                    acc <= b2_mem[c + 1];
                    state <= S_FC2;
                end
            end

            S_ARGM: begin
                if ($signed(acc2_arr[c[LOG_C-1:0]]) > $signed(best_val)) begin
                    best_val <= acc2_arr[c[LOG_C-1:0]];
                    best_idx <= c[LOG_C-1:0];
                end
                if (c == C-1) begin
                    state <= S_DONE;
                end else begin
                    c <= c + 1'b1;
                end
            end

            S_DONE: begin
                class_id <= best_idx;
                done     <= 1'b1;
                state    <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
