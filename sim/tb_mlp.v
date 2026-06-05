// tb_mlp.v — bit-true 验证 mlp_inference 与 Python infer_hw 输出一致
// 读 sim/vectors/test_vectors.txt:  <128bit hex> <expected_class>
`timescale 1ns/1ps

module tb_mlp;
    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [127:0] x_vec = 0;
    wire        done;
    wire [1:0]  class_id;

    // 100 MHz (周期 10 ns), 与板载实际时钟一致;
    // 不过本 testbench 只验证 mlp_inference 的逻辑等价, 与频率无关.
    always #5 clk = ~clk;

    mlp_inference dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .x_vec(x_vec),
        .done(done), .class_id(class_id)
    );

    integer fd, code, n_total, n_pass, n_fail, expected;
    reg [127:0] xv;
    reg [255:0] line;   // 弃用, 仅占位
    integer i;

    initial begin
        $display("[tb] start");
        #100 rst_n = 1;
        #100;

        fd = $fopen("../sim/vectors/test_vectors.txt", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open test_vectors.txt");
            $finish;
        end

        n_total = 0; n_pass = 0; n_fail = 0;

        // 跳过 2 行注释
        code = $fgets(line, fd);
        code = $fgets(line, fd);

        while (!$feof(fd)) begin
            code = $fscanf(fd, "%h %d\n", xv, expected);
            if (code != 2) begin
                // 文件尾或空行
                code = $fgets(line, fd);
            end else begin
                @(posedge clk);
                x_vec <= xv;
                start <= 1'b1;
                @(posedge clk);
                start <= 1'b0;

                // 等 done
                wait (done == 1'b1);
                @(posedge clk);

                n_total = n_total + 1;
                if (class_id == expected[1:0]) begin
                    n_pass = n_pass + 1;
                end else begin
                    n_fail = n_fail + 1;
                    $display("  MISMATCH #%0d: got=%0d expected=%0d", n_total, class_id, expected);
                end
            end
        end
        $fclose(fd);

        $display("[tb] total=%0d pass=%0d fail=%0d", n_total, n_pass, n_fail);
        if (n_fail == 0 && n_total > 0)
            $display("[tb] PASS bit-true match");
        else
            $display("[tb] FAIL");
        $finish;
    end

    // 超时保护
    initial begin
        #20_000_000 $display("TIMEOUT"); $finish;
    end
endmodule
