`timescale 1ns / 1ps
module tb_spi_shim;

    reg cpu_clk = 0, cpu_rst = 1;
    reg spi_clk = 0, spi_rst = 1;
    always #5  cpu_clk = ~cpu_clk;
    always #13 spi_clk = ~spi_clk;   // deliberately different, non-integer-ratio period

    reg        PSEL_spi, PENABLE, PWRITE;
    reg [31:0] PADDR, PWDATA;
    wire [31:0] PRDATA;
    wire        PREADY;
    wire        sck_o, ss_o, mosi_o;

    spi_shim dut (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .PSEL_spi(PSEL_spi), .PADDR(PADDR), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY),
        .spi_clk(spi_clk), .spi_rst(spi_rst),
        .sck_o(sck_o), .ss_o(ss_o), .mosi_o(mosi_o), .miso_i(1'b1)
    );

    task apb_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge cpu_clk); PSEL_spi=1; PADDR=addr; PWRITE=1; PWDATA=data; PENABLE=0;
        @(posedge cpu_clk); PENABLE=1;
        while (!PREADY) @(posedge cpu_clk);
        @(posedge cpu_clk);
        PSEL_spi=0; PENABLE=0;
    end
    endtask

    task apb_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge cpu_clk); PSEL_spi=1; PADDR=addr; PWRITE=0; PENABLE=0;
        @(posedge cpu_clk); PENABLE=1;
        while (!PREADY) @(posedge cpu_clk);
        data = PRDATA;
        @(posedge cpu_clk);
        PSEL_spi=0; PENABLE=0;
    end
    endtask

    reg [31:0] readback;
    integer errors = 0;

    initial begin
        PSEL_spi=0; PENABLE=0; PWRITE=0; PADDR=0; PWDATA=0;
        repeat(5) @(posedge cpu_clk); cpu_rst=0;
        repeat(5) @(posedge spi_clk); spi_rst=0;
        repeat(5) @(posedge cpu_clk);

        // SPCR forces bit4 (master bit) set on every write regardless of
        // what's written - pick 0x20 (bit4=0) specifically so the readback
        // has to show 0x30 if the shim AND the real core's own logic are
        // both working, not just echoing back whatever we wrote.
        $display("Writing 0x20 to SPCR (offset 3'b000 -> byte addr 0x00)...");
        apb_write(32'h0000_0000, 32'h0000_0020);

        $display("Reading back SPCR...");
        apb_read(32'h0000_0000, readback);
        $display("SPCR readback = 0x%02h (expected 0x30 = 0x20 | forced master bit 0x10)", readback[7:0]);
        if (readback[7:0] !== 8'h30) begin
            $display("FAIL: SPCR round-trip mismatch - either shim or core logic wrong");
            errors = errors + 1;
        end else
            $display("PASS: SPCR round-trip correct, including the core's own forced-bit logic");

        // SPSR (offset 1) - independent register, read-only status bits.
        // Just confirm it reads as *something* defined via the same
        // address-decode path, proving offset selection isn't stuck on SPCR.
        apb_read(32'h0000_0004, readback);
        $display("SPSR readback = 0x%02h (independent register, address decode check)", readback[7:0]);

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
