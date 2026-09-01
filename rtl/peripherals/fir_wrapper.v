`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fir_wrapper
// Description: CDC wrapper around fir_filter - real APB register interface
//              (swapped in for the old wr_en/rd_en stub), bridged to FIR's
//              own clock domain via the same two async_fifo mailboxes as
//              before. All FIR-domain glue logic is UNCHANGED and already
//              verified - only the CPU-side register decode is new.
//
// Register map (word offsets, PADDR[4:2]):
//   0x0 WRDATA (write-only) - next input sample, PWDATA[15:0]
//   0x1 RDDATA (read-only)  - next filtered output sample
//   0x2 STATUS (read-only)  - bit0: result_valid (a filtered sample is
//                             waiting to be read)
//////////////////////////////////////////////////////////////////////////////////
module fir_wrapper #(
    parameter DSIZE = 16,
    parameter ASIZE = 3
)(
    // ---- CPU-clock / APB domain ----
    input                cpu_clk,
    input                cpu_rst,     // active-high
    input                PSEL_fir,
    input      [31:0]    PADDR,
    input                PENABLE,
    input                PWRITE,
    input      [31:0]    PWDATA,
    output reg [31:0]    PRDATA,
    output reg           PREADY,

    // ---- FIR-clock domain ----
    input                fir_clk,
    input                fir_rst      // active-high
);

    localparam WRDATA_OFFSET = 3'b000;
    localparam RDDATA_OFFSET = 3'b001;
    localparam STATUS_OFFSET = 3'b010;

    wire [2:0] local_addr = PADDR[4:2];

    // ------------------------------------------------------------------
    // FIFO 1: CPU -> FIR  (samples in)
    // ------------------------------------------------------------------
    wire                fifo1_rempty;
    wire [DSIZE-1:0]    fifo1_rdata;
    wire                fifo1_rinc;

    wire apb_write_complete = PSEL_fir && PENABLE && PWRITE && PREADY;
    wire fifo1_winc = apb_write_complete && (local_addr == WRDATA_OFFSET);

    async_fifo #(
        .DSIZE(DSIZE), .ASIZE(ASIZE), .FALLTHROUGH("TRUE")
    ) u_fifo_cpu_to_fir (
        .wclk    (cpu_clk),
        .wrst_n  (~cpu_rst),
        .winc    (fifo1_winc),
        .wdata   (PWDATA[DSIZE-1:0]),
        .wfull   (),
        .awfull  (),
        .rclk    (fir_clk),
        .rrst_n  (~fir_rst),
        .rinc    (fifo1_rinc),
        .rdata   (fifo1_rdata),
        .rempty  (fifo1_rempty),
        .arempty ()
    );

    // ------------------------------------------------------------------
    // FIFO 2: FIR -> CPU  (results out)
    // ------------------------------------------------------------------
    wire                fifo2_rempty;
    wire [DSIZE-1:0]    fifo2_rdata;
    wire                fifo2_winc;
    wire [DSIZE-1:0]    fifo2_wdata;
    wire                fifo2_rinc;

    wire apb_read_complete = PSEL_fir && PENABLE && ~PWRITE && PREADY;
    // reading RDDATA IS the pop - same convention as UART's RXDATA
    assign fifo2_rinc = apb_read_complete && (local_addr == RDDATA_OFFSET) && ~fifo2_rempty;

    async_fifo #(
        .DSIZE(DSIZE), .ASIZE(ASIZE), .FALLTHROUGH("TRUE")
    ) u_fifo_fir_to_cpu (
        .wclk    (fir_clk),
        .wrst_n  (~fir_rst),
        .winc    (fifo2_winc),
        .wdata   (fifo2_wdata),
        .wfull   (),
        .awfull  (),
        .rclk    (cpu_clk),
        .rrst_n  (~cpu_rst),
        .rinc    (fifo2_rinc),
        .rdata   (fifo2_rdata),
        .rempty  (fifo2_rempty),
        .arempty ()
    );

    // ------------------------------------------------------------------
    // APB register read mux + PREADY (zero-wait-state, plain register access)
    // ------------------------------------------------------------------
    always @(*) begin
        PREADY = 1'b1;
        case (local_addr)
            WRDATA_OFFSET: PRDATA = 32'h0;                          // write-only
            RDDATA_OFFSET: PRDATA = {{(32-DSIZE){fifo2_rdata[DSIZE-1]}}, fifo2_rdata}; // sign-extended
            STATUS_OFFSET: PRDATA = {31'h0, ~fifo2_rempty};
            default:       PRDATA = 32'hDEADBEEF;
        endcase
    end

    // ------------------------------------------------------------------
    // FIR-domain glue logic - UNCHANGED from the original, already
    // waveform-verified (rd_data ramped 0,1,2...7 correctly for
    // all-1s-coefficient FIR with constant input 1).
    // ------------------------------------------------------------------
    wire signed [DSIZE-1:0] fir_sample_out;
    reg                     sample_popped_last_cycle;

    assign fifo1_rinc = ~fifo1_rempty;

    fir_filter #(
        .N(8), .WIDTH(DSIZE)
    ) u_fir_filter (
        .clk        (fir_clk),
        .rst        (fir_rst),
        .en         (fifo1_rinc),
        .sample_in  (sample_held),
        .sample_out (fir_sample_out)
    );

    always @(posedge fir_clk) begin
        if (fir_rst)
            sample_popped_last_cycle <= 1'b0;
        else
            sample_popped_last_cycle <= fifo1_rinc;
    end

    assign fifo2_winc  = sample_popped_last_cycle;
    assign fifo2_wdata = fir_sample_out;

    reg signed [DSIZE-1:0] sample_held;
    always @(posedge fir_clk) begin
        if (fir_rst)
            sample_held <= 0;
        else if (fifo1_rinc)
            sample_held <= fifo1_rdata;
    end

endmodule
