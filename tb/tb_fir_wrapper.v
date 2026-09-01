`timescale 1ns / 1ps
module tb_fir_wrapper;

    reg  cpu_clk = 0, fir_clk = 0;
    reg  cpu_rst = 1, fir_rst = 1;
    reg  wr_en = 0, rd_en = 0;
    reg  signed [15:0] wr_data = 0;
    wire signed [15:0] rd_data;
    wire result_valid;

    // two different frequencies -> genuinely async domains
    always #5  cpu_clk = ~cpu_clk;   // 100 MHz
    always #7  fir_clk = ~fir_clk;   // ~71 MHz, deliberately non-integer ratio

    fir_wrapper #(.DSIZE(16), .ASIZE(3)) dut (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .wr_en(wr_en), .wr_data(wr_data),
        .rd_en(rd_en), .rd_data(rd_data), .result_valid(result_valid),
        .fir_clk(fir_clk), .fir_rst(fir_rst)
    );

    // dump waveform
    initial begin
        $dumpfile("fir_wrapper_tb.vcd");
        $dumpvars(0, tb_fir_wrapper);
    end

    // dump values for plotting later
    integer logfile;
    initial logfile = $fopen("fir_wrapper_results.csv", "w");

    task write_sample(input signed [15:0] val);
        begin
            @(posedge cpu_clk);
            wr_en = 1; wr_data = val;
            @(posedge cpu_clk);
            wr_en = 0;
        end
    endtask

    task read_result;
        begin
            wait (result_valid);
            @(posedge cpu_clk);
            rd_en = 1;
            @(posedge cpu_clk);
            rd_en = 0;
            $fwrite(logfile, "%0d\n", rd_data);
            $display("Result: %0d", rd_data);
        end
    endtask

    integer i;
    initial begin
        #20 cpu_rst = 0; fir_rst = 0;

        // reuse your already hand-verified FIR test vectors here
        for (i = 0; i < 8; i = i + 1) begin
            write_sample(i);   // matches your all-coefficients=1 hand-trace
            read_result();
        end

        #200 $fclose(logfile); $finish;
    end

endmodule
