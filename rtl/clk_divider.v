`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// clk_divider / div_domain
//
// Adds the two benchmark items the SoC was missing:
//   - clock divider logic with multiple ratios
//   - >=1 generated clock per master clock domain
//
// div_domain instantiates a divider off a master clock, runs a counter on the
// DIVIDED clock, and samples that counter back into the MASTER clock domain.
// That last step is the point: it creates a real synchronous path between a
// master and its own generated clock, which STA times against the frequency
// ratio. Without it the divided logic is an isolated island and the generated
// clock constrains nothing.
//////////////////////////////////////////////////////////////////////////////////

// ---------------------------------------------------------------------------
// Even-ratio clock divider. RATIO must be even and >= 2.
// Output toggles every RATIO/2 input cycles -> output period = RATIO * input.
// ---------------------------------------------------------------------------
module clk_divider #(
    parameter integer RATIO = 4
) (
    input  wire clk_in,
    input  wire rst,        // active high, synchronous to clk_in
    output reg  clk_out
);
    localparam integer HALF  = RATIO / 2;
    localparam integer CW    = (RATIO <= 2)  ? 1 :
                               (RATIO <= 4)  ? 2 :
                               (RATIO <= 8)  ? 3 :
                               (RATIO <= 16) ? 4 :
                               (RATIO <= 32) ? 5 : 6;

    reg [CW-1:0] cnt;

    always @(posedge clk_in) begin
        if (rst) begin
            cnt     <= {CW{1'b0}};
            clk_out <= 1'b0;
        end else if (cnt == HALF[CW-1:0] - 1'b1) begin
            cnt     <= {CW{1'b0}};
            clk_out <= ~clk_out;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end
endmodule


// ---------------------------------------------------------------------------
// One master domain's generated-clock block.
//   clk_div    : the generated clock (declare with create_generated_clock)
//   slow_cnt   : free-running counter in the GENERATED clock domain
//   status     : slow_cnt sampled back into the MASTER clock domain
// ---------------------------------------------------------------------------
module div_domain #(
    parameter integer RATIO = 4,
    parameter integer W     = 8
) (
    input  wire         clk_in,
    input  wire         rst,
    output wire         clk_div,
    output reg  [W-1:0] status
);
    clk_divider #(.RATIO(RATIO)) u_div (
        .clk_in  (clk_in),
        .rst     (rst),
        .clk_out (clk_div)
    );

    // counter on the generated clock
    reg [W-1:0] slow_cnt;
    always @(posedge clk_div) begin
        if (rst) slow_cnt <= {W{1'b0}};
        else     slow_cnt <= slow_cnt + 1'b1;
    end

    // sampled back into the master domain: master <-> generated timed path
    always @(posedge clk_in) begin
        if (rst) status <= {W{1'b0}};
        else     status <= slow_cnt;
    end
endmodule
