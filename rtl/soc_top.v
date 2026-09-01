`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : soc_top
// Description : Wires together everything built so far:
//   PicoRV32 --(native mem)--> mem_arbiter --(RAM region)--> simple_ram
//                                          \-(peripheral region)-->
//   picorv32_apb_bridge --(single APB)--> apb_decoder --(per-peripheral
//   PSELx)--> {uart_wrapper, i2c_shim, spi_shim, fir_wrapper}
//
// Address map: 0x0000_0000 - RAM_WORDS*4  -> local RAM (code + data)
//              0x1000_0000+                -> APB peripherals (see
//                                             apb_decoder.v for the
//                                             per-peripheral sub-ranges)
//
// PADDR/PWRITE/PWDATA/PSTRB/PENABLE fan out identically to all 4
// peripherals (broadcast) - only PSELx and each peripheral's own
// PRDATA/PREADY differ, per the bus discussion earlier in this project.
//////////////////////////////////////////////////////////////////////////////////
module soc_top #(
    parameter RAM_WORDS  = 256,
    parameter RAM_INIT   = ""
) (
    input clk,        // cpu_clk - drives PicoRV32, bridge, decoder
    input resetn,      // active-low, matches picorv32 convention

    // ---- independently-clocked peripheral domains (5-domain SoC) ----
    input uart_clk, input uart_rst,
    input i2c_clk,  input i2c_rst,
    input spi_clk,  input spi_rst,
    input fir_clk,  input fir_rst,

    // ---- physical pins ----
    output uart_txd, input uart_rxd,
    input  scl_pad_i, output scl_pad_o, output scl_padoen_o,
    input  sda_pad_i, output sda_pad_o, output sda_padoen_o,
    output sck_o, output ss_o, output mosi_o, input miso_i
);

    wire cpu_rst = ~resetn;   // this project's active-high convention, matches bridge/wrappers

    // ---- PicoRV32 native mem interface ----
    wire        mem_valid, mem_instr, mem_ready;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [ 3:0] mem_wstrb;

    picorv32 u_cpu (
        .clk       (clk),
        .resetn    (resetn),
        .trap      (),
        .mem_valid (mem_valid),
        .mem_instr (mem_instr),
        .mem_ready (mem_ready),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata)
    );

    // ---- arbiter: split CPU accesses between local RAM (code/data) and
    //      the APB peripheral path, by address range ----
    wire        ram_valid, ram_ready;
    wire [31:0] ram_addr, ram_wdata, ram_rdata;
    wire [ 3:0] ram_wstrb;

    wire        periph_valid, periph_ready;
    wire [31:0] periph_addr, periph_wdata, periph_rdata;
    wire [ 3:0] periph_wstrb;

    mem_arbiter #(.PERIPH_BASE(32'h1000_0000)) u_arbiter (
        .mem_valid(mem_valid), .mem_ready(mem_ready), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
        .ram_valid(ram_valid), .ram_ready(ram_ready), .ram_addr(ram_addr),
        .ram_wdata(ram_wdata), .ram_wstrb(ram_wstrb), .ram_rdata(ram_rdata),
        .periph_valid(periph_valid), .periph_ready(periph_ready), .periph_addr(periph_addr),
        .periph_wdata(periph_wdata), .periph_wstrb(periph_wstrb), .periph_rdata(periph_rdata)
    );

    simple_ram #(.WORDS(RAM_WORDS), .INIT_FILE(RAM_INIT)) u_ram (
        .clk(clk), .valid(ram_valid), .ready(ram_ready),
        .addr(ram_addr), .wdata(ram_wdata), .wstrb(ram_wstrb), .rdata(ram_rdata)
    );

    // ---- bridge: native -> single APB (now only sees genuine peripheral accesses) ----
    wire [31:0] PADDR, PWDATA, PRDATA;
    wire        PWRITE, PSEL, PENABLE, PREADY;
    wire [ 3:0] PSTRB;

    picorv32_apb_bridge u_bridge (
        .clk       (clk),
        .resetn    (resetn),
        .mem_valid (periph_valid),
        .mem_ready (periph_ready),
        .mem_addr  (periph_addr),
        .mem_wdata (periph_wdata),
        .mem_wstrb (periph_wstrb),
        .mem_rdata (periph_rdata),
        .PADDR     (PADDR),
        .PWRITE    (PWRITE),
        .PWDATA    (PWDATA),
        .PSTRB     (PSTRB),
        .PSEL      (PSEL),
        .PENABLE   (PENABLE),
        .PRDATA    (PRDATA),
        .PREADY    (PREADY)
    );

    // ---- decoder: single APB -> per-peripheral PSELx, response mux ----
    wire PSEL_uart, PSEL_i2c, PSEL_spi, PSEL_fir;
    wire [31:0] PRDATA_uart, PRDATA_i2c, PRDATA_spi, PRDATA_fir;
    wire        PREADY_uart, PREADY_i2c, PREADY_spi, PREADY_fir;

    apb_decoder u_decoder (
        .PSEL  (PSEL),
        .PADDR (PADDR),
        .PRDATA_uart(PRDATA_uart), .PREADY_uart(PREADY_uart),
        .PRDATA_i2c (PRDATA_i2c ), .PREADY_i2c (PREADY_i2c ),
        .PRDATA_spi (PRDATA_spi ), .PREADY_spi (PREADY_spi ),
        .PRDATA_fir (PRDATA_fir ), .PREADY_fir (PREADY_fir ),
        .PSEL_uart(PSEL_uart), .PSEL_i2c(PSEL_i2c),
        .PSEL_spi(PSEL_spi),   .PSEL_fir(PSEL_fir),
        .PRDATA(PRDATA), .PREADY(PREADY)
    );

    // ---- peripheral wrappers - PADDR/PWRITE/PWDATA/PSTRB/PENABLE
    //      broadcast identically to all 4; only PSELx differs ----
    uart_wrapper #(.DSIZE(8), .ASIZE(4)) u_uart (
        .cpu_clk(clk), .cpu_rst(cpu_rst),
        .PSEL_uart(PSEL_uart), .PADDR(PADDR), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PSTRB(PSTRB), .PWDATA(PWDATA), .PRDATA(PRDATA_uart), .PREADY(PREADY_uart),
        .uart_clk(uart_clk), .uart_rst(uart_rst),
        .uart_txd(uart_txd), .uart_rxd(uart_rxd)
    );

    i2c_shim u_i2c (
        .cpu_clk(clk), .cpu_rst(cpu_rst),
        .PSEL_i2c(PSEL_i2c), .PADDR(PADDR), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PWDATA(PWDATA), .PRDATA(PRDATA_i2c), .PREADY(PREADY_i2c),
        .i2c_clk(i2c_clk), .i2c_rst(i2c_rst),
        .scl_pad_i(scl_pad_i), .scl_pad_o(scl_pad_o), .scl_padoen_o(scl_padoen_o),
        .sda_pad_i(sda_pad_i), .sda_pad_o(sda_pad_o), .sda_padoen_o(sda_padoen_o)
    );

    spi_shim u_spi (
        .cpu_clk(clk), .cpu_rst(cpu_rst),
        .PSEL_spi(PSEL_spi), .PADDR(PADDR), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PWDATA(PWDATA), .PRDATA(PRDATA_spi), .PREADY(PREADY_spi),
        .spi_clk(spi_clk), .spi_rst(spi_rst),
        .sck_o(sck_o), .ss_o(ss_o), .mosi_o(mosi_o), .miso_i(miso_i)
    );

    fir_wrapper #(.DSIZE(16), .ASIZE(3)) u_fir (
        .cpu_clk(clk), .cpu_rst(cpu_rst),
        .PSEL_fir(PSEL_fir), .PADDR(PADDR), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PWDATA(PWDATA), .PRDATA(PRDATA_fir), .PREADY(PREADY_fir),
        .fir_clk(fir_clk), .fir_rst(fir_rst)
    );

endmodule
