module fir_filter #(parameter N=8, parameter WIDTH=16) (
    input clk, input rst, input en,
    input  signed [WIDTH-1:0] sample_in,
    output signed [WIDTH-1:0] sample_out
);
reg signed [WIDTH-1:0] c [N-1:0];
reg signed [WIDTH-1:0] Q [N-1:0];
reg signed [40:0] imm;
integer i, j, k;

always @(posedge clk) begin
    if (rst) begin
        for (i=0; i<N; i=i+1) begin
            c[i] <= 1;
            Q[i] <= 0;
        end
    end else if (en) begin        // <-- only shift on a genuine new sample
        Q[0] <= sample_in;
        for (j=1; j<N; j=j+1)
            Q[j] <= Q[j-1];
    end
    // else: hold — no new sample this cycle, don't shift
end

always @(*) begin
    imm = 0;
    for (k=0; k<N; k=k+1)
        imm = imm + (c[k] * Q[k]);
end
assign sample_out = imm[WIDTH-1:0];
endmodule
