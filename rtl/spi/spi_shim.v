`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : spi_shim
// Description : APB <-> Wishbone-like protocol translation + CDC for
//               olofk/simple_spi's simple_spi_top.v (3-bit adr_i, register
//               map fixed by the core: SPCR/SPSR/SPDR/SPER/SS). Same
//               request/response async_fifo mailbox pattern as i2c_shim.v.
//////////////////////////////////////////////////////////////////////////////////
module spi_shim (
    // ---- CPU-clock / APB domain ----
    input             cpu_clk,
    input             cpu_rst,
    input             PSEL_spi,
    input      [31:0] PADDR,
    input             PENABLE,
    input             PWRITE,
    input      [31:0] PWDATA,
    output     [31:0] PRDATA,
    output            PREADY,

    // ---- SPI-clock domain ----
    input             spi_clk,
    input             spi_rst,

    // ---- physical SPI pins ----
    output            sck_o,
    output            ss_o,
    output            mosi_o,
    input             miso_i
);

    wire [2:0] local_addr = PADDR[4:2];

    // -----------------------------------------------------------------
    // Request FIFO: cpu_clk -> spi_clk
    // -----------------------------------------------------------------
    wire access_active = PSEL_spi && PENABLE;

    reg req_pushed;
    always @(posedge cpu_clk) begin
        if (cpu_rst)
            req_pushed <= 1'b0;
        else if (!access_active)
            req_pushed <= 1'b0;
        else if (access_active && !req_pushed)
            req_pushed <= 1'b1;
    end

    wire        reqfifo_wfull;
    wire        reqfifo_winc = access_active && !req_pushed && !reqfifo_wfull;
    wire [11:0] reqfifo_wdata = {PWRITE, local_addr, PWDATA[7:0]};

    wire        reqfifo_rempty;
    wire [11:0] reqfifo_rdata;
    wire        reqfifo_rinc;

    async_fifo #(
        .DSIZE(12), .ASIZE(2), .FALLTHROUGH("TRUE")
    ) u_req_fifo (
        .wclk(cpu_clk), .wrst_n(~cpu_rst), .winc(reqfifo_winc), .wdata(reqfifo_wdata),
        .wfull(reqfifo_wfull), .awfull(),
        .rclk(spi_clk), .rrst_n(~spi_rst), .rinc(reqfifo_rinc), .rdata(reqfifo_rdata),
        .rempty(reqfifo_rempty), .arempty()
    );

    // -----------------------------------------------------------------
    // Response FIFO: spi_clk -> cpu_clk
    // -----------------------------------------------------------------
    wire       respfifo_wfull;
    wire       respfifo_winc;
    wire [7:0] respfifo_wdata;

    wire       respfifo_rempty;
    wire [7:0] respfifo_rdata;
    wire       respfifo_rinc = access_active && ~respfifo_rempty;

    async_fifo #(
        .DSIZE(8), .ASIZE(2), .FALLTHROUGH("TRUE")
    ) u_resp_fifo (
        .wclk(spi_clk), .wrst_n(~spi_rst), .winc(respfifo_winc), .wdata(respfifo_wdata),
        .wfull(respfifo_wfull), .awfull(),
        .rclk(cpu_clk), .rrst_n(~cpu_rst), .rinc(respfifo_rinc), .rdata(respfifo_rdata),
        .rempty(respfifo_rempty), .arempty()
    );

    assign PREADY = ~respfifo_rempty;
    assign PRDATA = {24'h0, respfifo_rdata};

    // -----------------------------------------------------------------
    // spi_clk side: pop request -> drive a WB-style cycle -> wait for
    // ack_o -> push response.
    // -----------------------------------------------------------------
    localparam S_IDLE = 1'b0, S_BUSY = 1'b1;
    reg       spi_state;
    reg       we_r;
    reg [2:0] addr_r;
    reg [7:0] wdata_r;

    assign reqfifo_rinc = (spi_state == S_IDLE) && ~reqfifo_rempty;

    always @(posedge spi_clk) begin
        if (spi_rst) begin
            spi_state <= S_IDLE;
        end else begin
            case (spi_state)
                S_IDLE: if (reqfifo_rinc) begin
                    {we_r, addr_r, wdata_r} <= reqfifo_rdata;
                    spi_state <= S_BUSY;
                end
                S_BUSY: if (ack_o) begin
                    spi_state <= S_IDLE;
                end
            endcase
        end
    end

    wire       ack_o;
    wire [7:0] dat_o;

    assign respfifo_winc  = (spi_state == S_BUSY) && ack_o;
    assign respfifo_wdata = dat_o;

    simple_spi #(
        .SS_WIDTH(1)
    ) u_simple_spi (
        .clk_i (spi_clk),
        .rst_i (spi_rst),
        .cyc_i (spi_state == S_BUSY),
        .stb_i (spi_state == S_BUSY),
        .adr_i (addr_r),
        .we_i  (we_r),
        .dat_i (wdata_r),
        .dat_o (dat_o),
        .ack_o (ack_o),
        .inta_o(),
        .sck_o (sck_o),
        .ss_o  (ss_o),
        .mosi_o(mosi_o),
        .miso_i(miso_i)
    );

endmodule
