`timescale 1ns / 1ps
module tb_fir_wrapper_apb;

    reg cpu_clk = 0, cpu_rst = 1;
    reg fir_clk = 0, fir_rst = 1;
    always #5  cpu_clk = ~cpu_clk;
    always #7  fir_clk = ~fir_clk;   // deliberately different period - genuine async domains

    reg        PSEL_fir, PENABLE, PWRITE;
    reg [31:0] PADDR, PWDATA;
    wire [31:0] PRDATA;
    wire        PREADY;

    fir_wrapper #(.DSIZE(16), .ASIZE(3)) dut (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .PSEL_fir(PSEL_fir), .PADDR(PADDR), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY),
        .fir_clk(fir_clk), .fir_rst(fir_rst)
    );

    task apb_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge cpu_clk); PSEL_fir=1; PADDR=addr; PWRITE=1; PWDATA=data; PENABLE=0;
        @(posedge cpu_clk); PENABLE=1;
        @(posedge cpu_clk); PSEL_fir=0; PENABLE=0;
    end
    endtask

    task apb_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge cpu_clk); PSEL_fir=1; PADDR=addr; PWRITE=0; PENABLE=0;
        @(posedge cpu_clk); PENABLE=1;
        @(posedge cpu_clk); data=PRDATA; PSEL_fir=0; PENABLE=0;
    end
    endtask

    reg [31:0] status, result;
    integer i, errors = 0;

    initial begin
        PSEL_fir=0; PENABLE=0; PWRITE=0; PADDR=0; PWDATA=0;
        repeat(5) @(posedge cpu_clk); cpu_rst=0;
        repeat(5) @(posedge fir_clk); fir_rst=0;
        repeat(5) @(posedge cpu_clk);

        // push 8 samples of constant input 1 (same as the original hand-verified test),
        // all-1s-coefficient FIR should ramp 0,1,2,...,7
        for (i = 0; i < 8; i = i + 1) begin
            apb_write(32'h0, 32'h1);          // WRDATA offset 0
            // wait for a result to become available
            do
                apb_read(32'h8, status);      // STATUS offset (word2 = byte 8)
            while (status[0] !== 1'b1);
            apb_read(32'h4, result);          // RDDATA offset (word1 = byte 4)
            $display("sample %0d: fir output = %0d (expected %0d)", i, $signed(result), i);
            if (result !== i) begin
                $display("FAIL at sample %0d", i);
                errors = errors + 1;
            end
        end

        if (errors == 0) $display("\nALL TESTS PASSED - APB swap preserved original FIR behavior");
        else $display("\n%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
