`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : picorv32_apb_bridge
// Description : Converts PicoRV32's native mem_valid/mem_ready handshake into
//               an APB3/APB4 master transfer (SETUP + ACCESS phases).
//
//               PicoRV32 side (slave-like, but PicoRV32 is the requester):
//                 mem_valid stays high from the cycle a transaction is
//                 requested until the cycle mem_ready pulses high. PicoRV32
//                 samples mem_rdata / advances only when it sees
//                 (mem_valid && mem_ready) in the same cycle.
//
//               APB side (this module is the APB master):
//                 IDLE   -> PSEL=0 PENABLE=0
//                 SETUP  -> PSEL=1 PENABLE=0   (addr/wdata/wstrb/write driven)
//                 ACCESS -> PSEL=1 PENABLE=1   (held until PREADY=1)
//
// Notes:
//   - This bridge currently claims every picorv32 mem transaction (there is
//     no address decoder / RAM in front of it yet). Once the address
//     decoder + peripheral-select mux exists, only transactions in APB
//     address space should reach this bridge (matches the PicoSoC pattern
//     of muxing mem_ready/mem_rdata from multiple sources).
//   - PWRITE / PSTRB are derived from mem_wstrb: wstrb != 0 -> write.
//   - No PSLVERR handling yet (peripherals don't drive it) - can be added
//     as a mem-side trap/error path later if needed.
//////////////////////////////////////////////////////////////////////////////////
module picorv32_apb_bridge (
    input                clk,
    input                resetn,       // active-low, matches picorv32

    // ---- PicoRV32 native mem interface ----
    input                mem_valid,
    output reg           mem_ready,
    input      [31:0]    mem_addr,
    input      [31:0]    mem_wdata,
    input      [ 3:0]    mem_wstrb,
    output reg [31:0]    mem_rdata,

    // ---- APB master interface ----
    output reg [31:0]    PADDR,
    output reg           PWRITE,
    output reg [31:0]    PWDATA,
    output reg [ 3:0]    PSTRB,
    output               PSEL,
    output               PENABLE,
    input      [31:0]    PRDATA,
    input                PREADY
);

    localparam IDLE   = 2'b00;
    localparam SETUP  = 2'b01;
    localparam ACCESS = 2'b10;

    reg [1:0] state;

    assign PSEL    = (state == SETUP) || (state == ACCESS);
    assign PENABLE = (state == ACCESS);

    always @(posedge clk) begin
        if (!resetn) begin
            state     <= IDLE;
            mem_ready <= 1'b0;
            mem_rdata <= 32'h0;
            PADDR     <= 32'h0;
            PWRITE    <= 1'b0;
            PWDATA    <= 32'h0;
            PSTRB     <= 4'h0;
        end else begin
            mem_ready <= 1'b0; // default: 1-cycle pulse, deasserted unless set below

            case (state)
                IDLE: begin
                    // Guard against re-latching the transaction that JUST
                    // completed: state and mem_ready both flip to
                    // IDLE/1 on the same edge (see ACCESS branch below), so
                    // on the very next edge mem_valid can still be showing
                    // the OLD address for one extra cycle (picorv32 only
                    // updates mem_valid/mem_addr at the edge where it
                    // itself observes mem_valid&&mem_ready==1, i.e. one
                    // edge after we do). Without "&& !mem_ready" here we'd
                    // treat that stale cycle as a brand-new request and
                    // double-issue the same transaction.
                    if (mem_valid && !mem_ready) begin
                        // latch the transaction, move into SETUP phase
                        PADDR  <= mem_addr;
                        PWRITE <= (mem_wstrb != 4'b0000);
                        PWDATA <= mem_wdata;
                        PSTRB  <= mem_wstrb;
                        state  <= SETUP;
                    end
                end

                SETUP: begin
                    // one cycle in SETUP unconditionally, then assert PENABLE
                    state <= ACCESS;
                end

                ACCESS: begin
                    if (PREADY) begin
                        // transfer completes this cycle. mem_rdata only
                        // means something on a read - gate the capture so
                        // it doesn't silently change on writes (PicoRV32
                        // never looks at it then, but it's confusing in a
                        // waveform otherwise).
                        if (!PWRITE)
                            mem_rdata <= PRDATA;
                        mem_ready <= 1'b1;
                        state     <= IDLE;
                    end
                    // else: stay in ACCESS (peripheral inserting wait states)
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
