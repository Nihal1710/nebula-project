`timescale 1ns / 1ps
module tb_uart_wrapper_loopback;

    reg cpu_clk = 0, cpu_rst = 1;
    reg uart_clk = 0, uart_rst = 1;
    always #5  cpu_clk  = ~cpu_clk;
    always #20 uart_clk = ~uart_clk;

    reg        PSEL_uart, PENABLE, PWRITE;
    reg [31:0] PADDR, PWDATA;
    wire [31:0] PRDATA;
    wire        PREADY;
    wire        uart_txd;

    // loopback: this device's TX wire feeds straight back into its own RX wire
    wire uart_rxd = uart_txd;

    uart_wrapper #(.DSIZE(8), .ASIZE(4)) dut (
        .cpu_clk(cpu_clk), .cpu_rst(cpu_rst),
        .PSEL_uart(PSEL_uart), .PADDR(PADDR), .PENABLE(PENABLE),
        .PWRITE(PWRITE), .PSTRB(4'hF), .PWDATA(PWDATA),
        .PRDATA(PRDATA), .PREADY(PREADY),
        .uart_clk(uart_clk), .uart_rst(uart_rst),
        .uart_txd(uart_txd), .uart_rxd(uart_rxd)
    );

    task apb_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge cpu_clk);
        PSEL_uart = 1; PADDR = addr; PWRITE = 1; PWDATA = data; PENABLE = 0;
        @(posedge cpu_clk);
        PENABLE = 1;
        @(posedge cpu_clk);
        PSEL_uart = 0; PENABLE = 0;
    end
    endtask

    task apb_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge cpu_clk);
        PSEL_uart = 1; PADDR = addr; PWRITE = 0; PENABLE = 0;
        @(posedge cpu_clk);
        PENABLE = 1;
        @(posedge cpu_clk);
        data = PRDATA;
        PSEL_uart = 0; PENABLE = 0;
    end
    endtask

    reg [31:0] status, rxdata;
    integer errors = 0;

    initial begin
        PSEL_uart=0; PENABLE=0; PWRITE=0; PADDR=0; PWDATA=0;
        repeat(5) @(posedge cpu_clk);  cpu_rst = 0;
        repeat(5) @(posedge uart_clk); uart_rst = 0;
        repeat(5) @(posedge cpu_clk);

        // STATUS should show rx_valid=0 (bit1) before anything happens
        apb_read(32'h1000_0008, status);  // STATUS offset (word 2 = byte 8)
        if (status[1] !== 1'b0) begin
            $display("FAIL: rx_valid bit set before any transmission (status=%h)", status);
            errors = errors + 1;
        end else
            $display("PASS: STATUS rx_valid=0 before transmission, as expected");

        $display("Writing 0x55 to TXDATA, waiting for it to loop back through RX...");
        apb_write(32'h1000_0000, 32'h0000_0055);  // TXDATA

        // wait for transmission to complete (busy goes high then low)
        wait (dut.uart_tx_busy == 1'b1);
        wait (dut.uart_tx_busy == 1'b0);
        repeat(10) @(posedge uart_clk);  // let RX FIFO write settle across CDC

        // STATUS should now show rx_valid=1
        apb_read(32'h1000_0008, status);
        if (status[1] !== 1'b1) begin
            $display("FAIL: rx_valid bit NOT set after loopback (status=%h)", status);
            errors = errors + 1;
        end else
            $display("PASS: STATUS rx_valid=1 after byte looped back");

        // read RXDATA - should be 0x55, and this read should pop the FIFO
        apb_read(32'h1000_0004, rxdata);  // RXDATA offset (word 1 = byte 4)
        if (rxdata[7:0] !== 8'h55) begin
            $display("FAIL: RXDATA = %h, expected 0x55", rxdata[7:0]);
            errors = errors + 1;
        end else
            $display("PASS: RXDATA correctly returned 0x55");

        // STATUS should now show rx_valid=0 again (the read popped it)
        apb_read(32'h1000_0008, status);
        if (status[1] !== 1'b0) begin
            $display("FAIL: rx_valid still set after RXDATA read - read didn't pop the FIFO (status=%h)", status);
            errors = errors + 1;
        end else
            $display("PASS: rx_valid correctly cleared after RXDATA read popped the FIFO");

        if (errors == 0)
            $display("\nALL TESTS PASSED");
        else
            $display("\n%0d TEST(S) FAILED", errors);

        $finish;
    end

    initial begin
        #10_000_000;
        $display("FAIL: global timeout - simulation hung");
        $finish;
    end

endmodule
