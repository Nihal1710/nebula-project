`timescale 1ns / 1ps
module tb_soc_top;

    reg clk = 0, resetn = 0;
    reg uart_clk = 0, uart_rst = 1;
    reg i2c_clk  = 0, i2c_rst  = 1;
    reg spi_clk  = 0, spi_rst  = 1;
    reg fir_clk  = 0, fir_rst  = 1;

    // 5 genuinely independent, non-integer-ratio clock periods
    always #5  clk      = ~clk;       // 100 MHz - cpu_clk
    always #40 uart_clk = ~uart_clk;  // 12.5 MHz
    always #17 i2c_clk  = ~i2c_clk;   // ~29.4 MHz
    always #13 spi_clk  = ~spi_clk;   // ~38.5 MHz
    always #7  fir_clk  = ~fir_clk;   // ~71.4 MHz

    wire uart_txd;
    wire scl_pad_o, scl_padoen_o, sda_pad_o, sda_padoen_o;
    wire sck_o, ss_o, mosi_o;

    soc_top #(
        .RAM_WORDS(256),
        .RAM_INIT("firmware/firmware.hex")
    ) dut (
        .clk(clk), .resetn(resetn),
        .uart_clk(uart_clk), .uart_rst(uart_rst),
        .i2c_clk(i2c_clk),   .i2c_rst(i2c_rst),
        .spi_clk(spi_clk),   .spi_rst(spi_rst),
        .fir_clk(fir_clk),   .fir_rst(fir_rst),
        .uart_txd(uart_txd), .uart_rxd(1'b1),
        .scl_pad_i(1'b1), .scl_pad_o(scl_pad_o), .scl_padoen_o(scl_padoen_o),
        .sda_pad_i(1'b1), .sda_pad_o(sda_pad_o), .sda_padoen_o(sda_padoen_o),
        .sck_o(sck_o), .ss_o(ss_o), .mosi_o(mosi_o), .miso_i(1'b1)
    );

    integer errors = 0;

    initial begin
        repeat(10) @(posedge clk);      resetn   = 1;
        repeat(10) @(posedge uart_clk); uart_rst = 0;
        repeat(10) @(posedge i2c_clk);  i2c_rst  = 0;
        repeat(10) @(posedge spi_clk);  spi_rst  = 0;
        repeat(10) @(posedge fir_clk);  fir_rst  = 0;

        $display("Reset released across all 5 clock domains - firmware running...\n");

        // ---- UART check: TXDATA write should reach uart_tx.v and start
        //      a real transmission ----
        wait (dut.u_uart.uart_tx_busy == 1'b1);
        $display("PASS: UART - TXDATA write reached uart_tx.v (busy asserted)");

        // ---- FIR check: WRDATA write should land in FIFO 1 and get consumed ----
        wait (dut.u_fir.fifo1_rempty == 1'b0);
        $display("PASS: FIR  - WRDATA write reached FIFO 1 (rempty deasserted)");
        wait (dut.u_fir.fifo1_rempty == 1'b1);
        $display("PASS: FIR  - sample consumed by fir_filter (rempty reasserted)");

        // ---- I2C check: CTR write should land in i2c_master_top's real
        //      internal register, through the full APB->WB shim ----
        wait (dut.u_i2c.u_i2c_master.ctr == 8'h81);
        $display("PASS: I2C  - CTR register updated to 0x81 through APB->WB shim");

        // ---- SPI check: SPCR write should land in simple_spi's real
        //      internal register ----
        wait (dut.u_spi.u_simple_spi.spcr == 8'h50);
        $display("PASS: SPI  - SPCR register updated to 0x50 through APB->WB shim");

        $display("\nALL 4 PERIPHERALS REACHED AND CONFIRMED THROUGH REAL FIRMWARE");
        $display("(UART transmission still in flight in the background - not waiting");
        $display(" for full completion here, already proven separately in tb_uart_wrapper_loopback.v)");
        $finish;
    end

    initial begin
        #3_000_000;
        $display("FAIL: global timeout - firmware did not reach all 4 peripherals in time");
        $display("  UART busy seen:  %b", dut.u_uart.uart_tx_busy);
        $display("  FIR  rempty now: %b", dut.u_fir.fifo1_rempty);
        $display("  I2C  ctr now:    0x%02h", dut.u_i2c.u_i2c_master.ctr);
        $display("  SPI  spcr now:   0x%02h", dut.u_spi.u_simple_spi.spcr);
        $finish;
    end

endmodule
