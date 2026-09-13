`timescale 1ns/1ps
`include "miter_gold.v"
`include "miter_gate.v"

module tb_diff;
  reg clk=0, rst=1, en=0;
  reg signed [15:0] sample_in = 0;
  wire signed [15:0] out_gold, out_gate;
  integer i, errors=0, checks=0;

  fir_gold u_gold(.clk(clk), .rst(rst), .en(en), .sample_in(sample_in), .sample_out(out_gold));
  fir_gate u_gate(.clk(clk), .rst(rst), .en(en), .sample_in(sample_in), .sample_out(out_gate));

  always #5 clk = ~clk;

  initial begin
    // two reset cycles
    repeat (2) @(posedge clk);
    #1 rst = 0;

    for (i = 0; i < 20000; i = i + 1) begin
      @(negedge clk);
      // random stimulus incl. occasional mid-stream reset
      en        = $random;
      sample_in = $random;
      if (i % 997 == 996) rst = 1; else rst = 0;
      @(posedge clk);
      #1;
      checks = checks + 1;
      if (out_gold !== out_gate) begin
        errors = errors + 1;
        if (errors < 6)
          $display("MISMATCH cycle=%0d rst=%b en=%b in=%0d gold=%0d gate=%0d",
                   i, rst, en, sample_in, out_gold, out_gate);
      end
    end
    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("RESULT: cycle-by-cycle IDENTICAL");
    else             $display("RESULT: DIVERGENT");
    $finish;
  end
endmodule
