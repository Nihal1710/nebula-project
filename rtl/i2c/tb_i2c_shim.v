`timescale 1ns / 1ps
module tb_i2c_shim;

    reg cpu_clk = 0, cpu_rst = 1;
    reg i2c_clk = 0, i2c_rst = 1;
    always #5  cpu_clk = ~cpu_clk;
    always #17 i2c_clk = ~i2c_clk;   // deliberately different, non-integer-ratio period

    reg        PSEL_i2c, PENABLE, PWRITE;
    reg [31:0] PADDR, PWDATA;
    wire [31:0] PRDATA;
    wire        PREADY;

    wire scl_pad_o, scl_padoen_o, sda_pad_o, sda_padoen_o;

    i2c_shim dut (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .PSEL_i2c(PSEL_i2c), .PADDR(PADDR), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY),
        .i2c_clk(i2c_clk), .i2c_rst(i2c_rst),
        .scl_pad_i(1'b1), .scl_pad_o(scl_pad_o), .scl_padoen_o(scl_padoen_o),
        .sda_pad_i(1'b1), .sda_pad_o(sda_pad_o), .sda_padoen_o(sda_padoen_o)
    );

    // real wait-stated APB tasks - loop on PREADY like the actual bridge does
    task apb_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge cpu_clk); PSEL_i2c=1; PADDR=addr; PWRITE=1; PWDATA=data; PENABLE=0;
        @(posedge cpu_clk); PENABLE=1;
        while (!PREADY) @(posedge cpu_clk);
        @(posedge cpu_clk);
        PSEL_i2c=0; PENABLE=0;
    end
    endtask

    task apb_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge cpu_clk); PSEL_i2c=1; PADDR=addr; PWRITE=0; PENABLE=0;
        @(posedge cpu_clk); PENABLE=1;
        while (!PREADY) @(posedge cpu_clk);
        data = PRDATA;
        @(posedge cpu_clk);
        PSEL_i2c=0; PENABLE=0;
    end
    endtask

    reg [31:0] readback;
    integer errors = 0;

    initial begin
        PSEL_i2c=0; PENABLE=0; PWRITE=0; PADDR=0; PWDATA=0;
        repeat(5) @(posedge cpu_clk); cpu_rst=0;
        repeat(5) @(posedge i2c_clk); i2c_rst=0;
        repeat(5) @(posedge cpu_clk);

        $display("Writing 0x81 to CTR (offset 3'b010 -> byte addr 0x08)...");
        apb_write(32'h0000_0008, 32'h0000_0081);

        $display("Reading back CTR...");
        apb_read(32'h0000_0008, readback);
        $display("CTR readback = 0x%02h (expected 0x81)", readback[7:0]);
        if (readback[7:0] !== 8'h81) begin
            $display("FAIL: CTR round-trip mismatch");
            errors = errors + 1;
        end else
            $display("PASS: CTR round-trip through APB->WB shim matches");

        // also check PRER (offset 0), which resets to 0xFFFF - just prove
        // a DIFFERENT register address reads independently/correctly too
        apb_read(32'h0000_0000, readback);
        $display("PRERlo readback = 0x%02h (expected 0xff, reset default)", readback[7:0]);
        if (readback[7:0] !== 8'hFF) begin
            $display("FAIL: PRERlo default mismatch");
            errors = errors + 1;
        end else
            $display("PASS: PRERlo correctly independent register, default value intact");

        if (errors == 0) $display("\nALL TESTS PASSED");
        else $display("\n%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout - APB transaction never completed (PREADY never asserted)");
        $finish;
    end

endmodule
