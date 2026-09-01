`timescale 1ns / 1ps
module simple_ram #(
    parameter integer WORDS = 256,   // 256 words = 1KB
    parameter         INIT_FILE = ""
) (
    input             clk,
    input             valid,
    output reg        ready,
    input      [31:0] addr,
    input      [31:0] wdata,
    input      [ 3:0] wstrb,
    output reg [31:0] rdata
);

    reg [31:0] mem [0:WORDS-1];

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        ready <= 1'b0;
        if (valid && !ready) begin
            ready <= 1'b1;
            if (wstrb[0]) mem[addr[$clog2(WORDS)+1:2]][ 7: 0] <= wdata[ 7: 0];
            if (wstrb[1]) mem[addr[$clog2(WORDS)+1:2]][15: 8] <= wdata[15: 8];
            if (wstrb[2]) mem[addr[$clog2(WORDS)+1:2]][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[addr[$clog2(WORDS)+1:2]][31:24] <= wdata[31:24];
            rdata <= mem[addr[$clog2(WORDS)+1:2]];
        end
    end

endmodule
