/*`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fir_wrapper
// Description: CDC wrapper around fir_filter — bridges CPU-clock register
//              interface (stub, to become APB) to FIR's own clock domain
//              via two async_fifo mailboxes.
//////////////////////////////////////////////////////////////////////////////////
module fir_wrapper #(
    parameter DSIZE = 16,   // matches fir_filter's WIDTH
    parameter ASIZE = 3     // depth = 2^3 = 8
)(
    // ---- CPU-clock domain (stub register interface, stands in for APB) ----
    input                   cpu_clk,
    input                   cpu_rst,     // active-high
    input                   wr_en,
    input      [DSIZE-1:0]  wr_data,
    input                   rd_en,
    output     [DSIZE-1:0]  rd_data,
    output                  result_valid, // status flag: result ready to read

    // ---- FIR-clock domain ----
    input                   fir_clk,
    input                   fir_rst      // active-high
);

    // ------------------------------------------------------------------
    // FIFO 1: CPU -> FIR  (samples in)
    // ------------------------------------------------------------------
    wire                fifo1_rempty;
    wire [DSIZE-1:0]    fifo1_rdata;
    wire                fifo1_rinc;

    async_fifo #(
        .DSIZE(DSIZE), .ASIZE(ASIZE), .FALLTHROUGH("TRUE")
    ) u_fifo_cpu_to_fir (
        .wclk    (cpu_clk),
        .wrst_n  (~cpu_rst),      // active-low reset on async_fifo
        .winc    (wr_en),
        .wdata   (wr_data),
        .wfull   (),              // unused for now; wire up if you want backpressure
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
        .rinc    (rd_en),
        .rdata   (fifo2_rdata),
        .rempty  (fifo2_rempty),
        .arempty ()
    );

    assign rd_data      = fifo2_rdata;
    assign result_valid = ~fifo2_rempty;   // already in cpu_clk domain, no extra sync needed

    // ------------------------------------------------------------------
    // FIR-domain glue logic
    // ------------------------------------------------------------------
    wire signed [DSIZE-1:0] fir_sample_out;
    reg                     sample_popped_last_cycle;

    // pop a new sample whenever one is waiting
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
    // Track whether *this* cycle's fir_sample_out corresponds to a fresh
    // input, so we only push a new result once per new sample - not once
    // per clock cycle (fir_filter has no valid/ready of its own; sample_out
    // is just whatever's currently in its internal shift register).
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
    // else: hold previous value, don't let x propagate
end

endmodule*/

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fir_wrapper
// Description: CDC wrapper around fir_filter — bridges CPU-clock register
//              interface (stub, to become APB) to FIR's own clock domain
//              via two async_fifo mailboxes.
//////////////////////////////////////////////////////////////////////////////////
module fir_wrapper #(
    parameter DSIZE = 16,   // matches fir_filter's WIDTH
    parameter ASIZE = 3     // depth = 2^3 = 8
)(
    // ---- CPU-clock domain (stub register interface, stands in for APB) ----
    input                   cpu_clk,
    input                   cpu_rst,     // active-high
    input                   wr_en,
    input      [DSIZE-1:0]  wr_data,
    input                   rd_en,
    output     [DSIZE-1:0]  rd_data,
    output                  result_valid, // status flag: result ready to read

    // ---- FIR-clock domain ----
    input                   fir_clk,
    input                   fir_rst      // active-high
);

    // ------------------------------------------------------------------
    // FIFO 1: CPU -> FIR  (samples in)
    // ------------------------------------------------------------------
    wire                fifo1_rempty;
    wire [DSIZE-1:0]    fifo1_rdata;
    wire                fifo1_rinc;

    async_fifo #(
        .DSIZE(DSIZE), .ASIZE(ASIZE), .FALLTHROUGH("TRUE")
    ) u_fifo_cpu_to_fir (
        .wclk    (cpu_clk),
        .wrst_n  (~cpu_rst),
        .winc    (wr_en),
        .wdata   (wr_data),
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
        .rinc    (rd_en),
        .rdata   (fifo2_rdata),
        .rempty  (fifo2_rempty),
        .arempty ()
    );

    assign rd_data      = fifo2_rdata;
    assign result_valid = ~fifo2_rempty;

    // ------------------------------------------------------------------
    // FIR-domain glue logic
    // ------------------------------------------------------------------
    wire signed [DSIZE-1:0] fir_sample_out;
    reg                     sample_popped_last_cycle;
    reg signed [DSIZE-1:0]  sample_held;
    reg                     fifo1_rinc_d;   // fifo1_rinc, delayed 1 cycle

    // pop a new sample whenever one is waiting
    assign fifo1_rinc = ~fifo1_rempty;

    // Load sample_held the instant a pop happens (unchanged from before).
    always @(posedge fir_clk) begin
        if (fir_rst)
            sample_held <= 0;
        else if (fifo1_rinc)
            sample_held <= fifo1_rdata;
        // else: hold previous value, don't let x propagate
    end

    // Delay fifo1_rinc by one cycle so fir_filter's `en` fires the cycle
    // AFTER sample_held has actually been loaded with the new sample --
    // avoids the same-edge NBA race where fir_filter would otherwise read
    // sample_held's PRE-edge (stale, one-pop-old) value.
    always @(posedge fir_clk) begin
        if (fir_rst)
            fifo1_rinc_d <= 1'b0;
        else
            fifo1_rinc_d <= fifo1_rinc;
    end

    fir_filter #(
        .N(8), .WIDTH(DSIZE)
    ) u_fir_filter (
        .clk        (fir_clk),
        .rst        (fir_rst),
        .en         (fifo1_rinc_d),   // delayed enable, now correctly aligned
        .sample_in  (sample_held),
        .sample_out (fir_sample_out)
    );

    // Track whether *this* cycle's fir_sample_out corresponds to a fresh
    // input, so we only push a new result once per new sample. Now gated
    // off the delayed enable, to stay aligned with when sample_out actually
    // becomes valid (one cycle after fifo1_rinc_d fires).
    always @(posedge fir_clk) begin
        if (fir_rst)
            sample_popped_last_cycle <= 1'b0;
        else
            sample_popped_last_cycle <= fifo1_rinc_d;
    end

    assign fifo2_winc  = sample_popped_last_cycle;
    assign fifo2_wdata = fir_sample_out;

endmodule
