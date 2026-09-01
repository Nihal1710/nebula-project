`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : mem_arbiter
// Description : Splits PicoRV32's mem_valid/mem_addr between local RAM
//               (code + data, addr < PERIPH_BASE) and the APB peripheral
//               path (addr >= PERIPH_BASE) - closes the gap flagged since
//               the bridge was first built ("every access currently goes
//               through APB, including instruction fetches").
//
// No latching needed for "which target" - PicoRV32 holds mem_addr stable
// for the entire duration of a transaction (the same guarantee the bridge
// itself already relies on), so a plain combinational address compare is
// safe to use as the mux select throughout.
//////////////////////////////////////////////////////////////////////////////////
module mem_arbiter #(
    parameter PERIPH_BASE = 32'h1000_0000
) (
    // CPU side
    input             mem_valid,
    output            mem_ready,
    input      [31:0] mem_addr,
    input      [31:0] mem_wdata,
    input      [ 3:0] mem_wstrb,
    output     [31:0] mem_rdata,

    // RAM side
    output            ram_valid,
    input             ram_ready,
    output     [31:0] ram_addr,
    output     [31:0] ram_wdata,
    output     [ 3:0] ram_wstrb,
    input      [31:0] ram_rdata,

    // peripheral (APB bridge) side
    output            periph_valid,
    input             periph_ready,
    output     [31:0] periph_addr,
    output     [31:0] periph_wdata,
    output     [ 3:0] periph_wstrb,
    input      [31:0] periph_rdata
);

    wire target_periph = (mem_addr >= PERIPH_BASE);

    assign ram_valid    = mem_valid && ~target_periph;
    assign periph_valid = mem_valid &&  target_periph;

    assign ram_addr     = mem_addr;
    assign ram_wdata    = mem_wdata;
    assign ram_wstrb    = mem_wstrb;

    assign periph_addr  = mem_addr;
    assign periph_wdata = mem_wdata;
    assign periph_wstrb = mem_wstrb;

    assign mem_ready = target_periph ? periph_ready : ram_ready;
    assign mem_rdata = target_periph ? periph_rdata : ram_rdata;

endmodule
