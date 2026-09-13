// Tier-2 equivalence miter. EQY cannot verify this fix: gold's output
// delay register d1 and gate's psum_lo/psum_hi have no name counterparts,
// so partition matching leaves them unconstrained and 2/18 partitions
// fail spuriously. This compares the designs whole instead.

module fir_miter (
    input clk,
    input rst,
    input en,
    input signed [15:0] sample_in
);
    wire signed [15:0] out_gold, out_gate;

    fir_gold u_gold (.clk(clk), .rst(rst), .en(en),
                     .sample_in(sample_in), .sample_out(out_gold));
    fir_gate u_gate (.clk(clk), .rst(rst), .en(en),
                     .sample_in(sample_in), .sample_out(out_gate));

    // Require reset in the very first cycle.
    always @(*)
        if ($initstate) assume (rst);

    // At step 0 the registers still hold arbitrary solver-chosen values;
    // rst is asserted but no clock edge has applied it yet. Checking at
    // step 0 produces a false failure. Start from step 1.
    reg past_init = 0;
    always @(posedge clk)
        past_init <= 1;

    always @(posedge clk)
        if (past_init) assert (out_gold == out_gate);
endmodule
