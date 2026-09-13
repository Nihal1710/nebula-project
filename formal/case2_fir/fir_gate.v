module fir_filter #(parameter N=8, parameter WIDTH=16) (
    input clk, input rst, input en,
    input  signed [WIDTH-1:0] sample_in,
    output signed [WIDTH-1:0] sample_out
);
reg signed [WIDTH-1:0] c [N-1:0];
reg signed [WIDTH-1:0] Q [N-1:0];
reg signed [40:0] imm;
reg signed [40:0] psum_lo;
reg signed [40:0] psum_hi;
integer i, j, k;

always @(posedge clk) begin
    if (rst) begin
        for (i=0; i<N; i=i+1) begin
 
            Q[i] <= 0;
        end
        c[0] <= 16'sd3;  c[1] <= 16'sd11;  c[2] <= 16'sd24;  c[3] <= 16'sd31;
        c[4] <= 16'sd31; c[5] <= 16'sd24;  c[6] <= 16'sd11;  c[7] <= 16'sd3;
    end else if (en) begin        // <-- only shift on a genuine new sample
        Q[0] <= sample_in;
        for (j=1; j<N; j=j+1)
            Q[j] <= Q[j-1];
    end
    // else: hold — no new sample this cycle, don't shift
end

// Pipeline stage 1: two 4-product half-sums registered to split the MAC chain
always @(posedge clk) begin
    if (rst) begin
        psum_lo <= 0;
        psum_hi <= 0;
    end else begin
        psum_lo <= (c[0] * Q[0]) + (c[1] * Q[1]) + (c[2] * Q[2]) + (c[3] * Q[3]);
        psum_hi <= (c[4] * Q[4]) + (c[5] * Q[5]) + (c[6] * Q[6]) + (c[7] * Q[7]);
    end
end

// Pipeline stage 2: final reduction (combinational, as before)
always @(*) begin
    imm = psum_lo + psum_hi;
end
assign sample_out = imm[WIDTH-1:0];
endmodule
