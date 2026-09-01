`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : uart_wrapper
// Description : APB-facing register wrapper around ben-marshall/uart's
//               uart_tx.v / uart_rx.v, CDC'd via two async_fifo mailboxes -
//               same shape as fir_wrapper.v.
//
// Register map (word offsets within this peripheral's 32-byte APB window,
// PADDR[4:2] selects which):
//   0x0 TXDATA  (write-only) - byte to send. Firmware convention: always
//                write with a plain sw/sb at the base address, byte lands
//                on PWDATA[7:0] - PSTRB not decoded, not needed for this
//                problem statement.
//   0x1 RXDATA  (read-only)  - last received byte  [NOT YET WIRED - Step 3]
//   0x2 STATUS  (read-only)  - bit0: uart_tx_busy, bit1: rx_valid,
//                              bit2: rx_break        [NOT YET WIRED - Step 3]
//
// TX path (this file): CPU write -> FIFO A (cpu_clk->uart_clk) -> held
// register, delayed one cycle to line up with uart_tx_en -> uart_tx.v.
// Extra ~sample_popped_last_cycle term in fifo1_rinc closes the race where
// a second pop could fire before the first pop's data has actually reached
// uart_tx_en (uart_tx_busy alone lags by one cycle relative to the pop).
//////////////////////////////////////////////////////////////////////////////////
module uart_wrapper #(
    parameter DSIZE = 8,   // UART payload is a byte
    parameter ASIZE = 4    // FIFO depth = 2^ASIZE words
) (
    // ---- CPU-clock / APB domain ----
    input                cpu_clk,
    input                cpu_rst,     // active-high
    input                PSEL_uart,
    input      [31:0]    PADDR,
    input                PENABLE,
    input                PWRITE,
    input      [ 3:0]    PSTRB,       // unused (see note above)
    input      [31:0]    PWDATA,
    output reg [31:0]    PRDATA,
    output reg           PREADY,

    // ---- UART clock domain ----
    input                uart_clk,
    input                uart_rst,    // active-high (matches cpu_rst convention)
    output               uart_txd,
    input                uart_rxd
);

    localparam TXDATA_OFFSET = 3'b000;
    localparam RXDATA_OFFSET = 3'b001;
    localparam STATUS_OFFSET = 3'b010;

    wire [2:0] local_addr = PADDR[4:2];

    // one-shot: true only on the cycle this APB transaction actually
    // completes (zero-wait-state register access - PREADY driven combinationally
    // below, so ACCESS is always exactly 1 cycle here)
    wire apb_write_complete = PSEL_uart && PENABLE && PWRITE && PREADY;

    // -----------------------------------------------------------------
    // FIFO A: CPU -> UART TX (cpu_clk write side, uart_clk read side)
    // -----------------------------------------------------------------
    wire               fifo1_rempty;
    wire [DSIZE-1:0]   fifo1_rdata;
    wire               fifo1_rinc;
    wire               fifo1_winc;
    wire               fifo1_wfull;

    assign fifo1_winc = apb_write_complete && (local_addr == TXDATA_OFFSET);

    async_fifo #(
        .DSIZE(DSIZE), .ASIZE(ASIZE), .FALLTHROUGH("TRUE")
    ) u_fifo_cpu_to_txd (
        .wclk    (cpu_clk),
        .wrst_n  (~cpu_rst),
        .winc    (fifo1_winc),
        .wdata   (PWDATA[DSIZE-1:0]),
        .wfull   (fifo1_wfull),
        .awfull  (),
        .rclk    (uart_clk),
        .rrst_n  (~uart_rst),
        .rinc    (fifo1_rinc),
        .rdata   (fifo1_rdata),
        .rempty  (fifo1_rempty),
        .arempty ()
    );

    // -----------------------------------------------------------------
    // uart_clk side: pop -> held register -> delayed enable -> uart_tx
    // -----------------------------------------------------------------
    wire uart_tx_busy;

    reg sample_popped_last_cycle;
    assign fifo1_rinc = ~fifo1_rempty && ~uart_tx_busy && ~sample_popped_last_cycle;

    reg [DSIZE-1:0] sample_held;
    always @(posedge uart_clk) begin
        if (uart_rst)
            sample_held <= 0;
        else if (fifo1_rinc)
            sample_held <= fifo1_rdata;
    end

    always @(posedge uart_clk) begin
        if (uart_rst)
            sample_popped_last_cycle <= 1'b0;
        else
            sample_popped_last_cycle <= fifo1_rinc;
    end

    uart_tx u_uart_tx (
        .clk          (uart_clk),
        .resetn       (~uart_rst),
        .uart_txd     (uart_txd),
        .uart_tx_busy (uart_tx_busy),
        .uart_tx_en   (sample_popped_last_cycle),
        .uart_tx_data (sample_held)
    );

    // -----------------------------------------------------------------
    // FIFO B: UART RX -> CPU (uart_clk write side, cpu_clk read side)
    // -----------------------------------------------------------------
    wire                uart_rx_valid;
    wire                uart_rx_break;
    wire [DSIZE-1:0]    uart_rx_data;

    uart_rx u_uart_rx (
        .clk           (uart_clk),
        .resetn        (~uart_rst),
        .uart_rxd      (uart_rxd),
        .uart_rx_en    (1'b1),          // always receiving
        .uart_rx_break (uart_rx_break),
        .uart_rx_valid (uart_rx_valid),
        .uart_rx_data  (uart_rx_data)
    );

    wire fifo2_wfull;
    wire fifo2_rinc;
    wire [DSIZE-1:0] fifo2_rdata;
    wire fifo2_rempty;

    // uart_rx_valid is already a clean one-cycle pulse straight from the
    // core's own FSM transition - no held-register/edge-gating race here,
    // unlike the TX side, because there's no extra pipeline stage between
    // this trigger and the FIFO actually capturing the word.
    wire fifo2_winc = ~fifo2_wfull && uart_rx_valid;

    async_fifo #(
        .DSIZE(DSIZE), .ASIZE(ASIZE), .FALLTHROUGH("TRUE")
    ) u_fifo_rxd_to_cpu (
        .wclk    (uart_clk),
        .wrst_n  (~uart_rst),
        .winc    (fifo2_winc),
        .wdata   (uart_rx_data),
        .wfull   (fifo2_wfull),
        .awfull  (),
        .rclk    (cpu_clk),
        .rrst_n  (~cpu_rst),
        .rinc    (fifo2_rinc),
        .rdata   (fifo2_rdata),
        .rempty  (fifo2_rempty),
        .arempty ()
    );

    // uart_rx_break is a level generated entirely in uart_clk - reading it
    // directly from cpu_clk-domain combinational logic is an unsynchronized
    // CDC crossing (same category of bug ff_syn exists to prevent). Cheap
    // 2-flop synchronizer, same shape as ff_syn, since it's just a level
    // (not a single-cycle pulse like uart_rx_valid would have been - that's
    // exactly why rx_valid is read via fifo2_rempty instead, below, rather
    // than synchronized directly: a synchronized pulse can still be missed
    // between cpu_clk samples, but a synchronized FIFO-empty flag can't).
    reg uart_rx_break_sync0, uart_rx_break_sync1;
    always @(posedge cpu_clk) begin
        if (cpu_rst) begin
            uart_rx_break_sync0 <= 1'b0;
            uart_rx_break_sync1 <= 1'b0;
        end else begin
            uart_rx_break_sync0 <= uart_rx_break;
            uart_rx_break_sync1 <= uart_rx_break_sync0;
        end
    end

    // -----------------------------------------------------------------
    // APB register read mux + PREADY. Zero-wait-state (combinational
    // PREADY) since everything here is a plain register access, not a
    // real multi-cycle operation.
    // -----------------------------------------------------------------
    wire apb_read_complete = PSEL_uart && PENABLE && ~PWRITE && PREADY;

    // reading RXDATA IS the pop - mirrors how the TXDATA write IS the FIFO
    // A push. Guard on ~fifo2_rempty so a read against an empty FIFO
    // doesn't advance a pointer that has nothing behind it.
    assign fifo2_rinc = apb_read_complete && (local_addr == RXDATA_OFFSET) && ~fifo2_rempty;

    always @(*) begin
        PREADY = 1'b1;
        case (local_addr)
            TXDATA_OFFSET: PRDATA = 32'h0;          // write-only, reads as 0
            RXDATA_OFFSET: PRDATA = fifo2_rdata;
            STATUS_OFFSET: PRDATA = {29'h0, uart_rx_break_sync1, ~fifo2_rempty, uart_tx_busy};
            default:       PRDATA = 32'hDEADBEEF;
        endcase
    end

endmodule
