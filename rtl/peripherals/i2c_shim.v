`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : i2c_shim
// Description : APB <-> Wishbone protocol translation + CDC for
//               i2c_master_top.v (opencores i2c-master, Wishbone slave,
//               3-bit wb_adr_i -> 8-register map fixed by the core itself:
//               PRERlo/PRERhi/CTR/TXR-RXR/CR-SR/... - not something we chose).
//
// Unlike UART/FIR (where the FIFO itself WAS the register), here there's a
// real register file living inside i2c_master_top, so each APB access has
// to become a genuine, separate Wishbone bus cycle on the far side and wait
// for that core's own wb_ack_o - this is a real multi-cycle, wait-stated
// APB slave (PREADY is NOT unconditional here, unlike UART's TXDATA).
//
// CDC: single-outstanding-transaction request/response mailbox, same
// async_fifo primitive as UART/FIR, just carrying a WB request/response
// instead of raw sample data. Request = {we, addr[2:0], wdata[7:0]} (12b).
// Response = wb_dat_o (8b), pushed exactly when the real core's wb_ack_o
// fires - so the response FIFO becoming non-empty on the cpu_clk side IS
// the CDC-safe completion signal, same role fifo2_rempty played for UART.
//////////////////////////////////////////////////////////////////////////////////
module i2c_shim (
    // ---- CPU-clock / APB domain ----
    input             cpu_clk,
    input             cpu_rst,       // active-high
    input             PSEL_i2c,
    input      [31:0] PADDR,
    input             PENABLE,
    input             PWRITE,
    input      [31:0] PWDATA,
    output     [31:0] PRDATA,
    output            PREADY,

    // ---- I2C-clock domain ----
    input             i2c_clk,
    input             i2c_rst,       // active-high

    // ---- physical I2C pins ----
    input             scl_pad_i,
    output            scl_pad_o,
    output            scl_padoen_o,
    input             sda_pad_i,
    output            sda_pad_o,
    output            sda_padoen_o
);

    wire [2:0] local_addr = PADDR[4:2];

    // -----------------------------------------------------------------
    // Request FIFO: cpu_clk -> i2c_clk. Pushed exactly once per APB
    // access, guarded by req_pushed so it doesn't re-push every cycle
    // ACCESS stays high while waiting on the response.
    // -----------------------------------------------------------------
    wire        access_active = PSEL_i2c && PENABLE;

    reg  req_pushed;
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
        .rclk(i2c_clk), .rrst_n(~i2c_rst), .rinc(reqfifo_rinc), .rdata(reqfifo_rdata),
        .rempty(reqfifo_rempty), .arempty()
    );

    // -----------------------------------------------------------------
    // Response FIFO: i2c_clk -> cpu_clk. Response FIFO non-empty on the
    // cpu_clk side is the completion signal - drives PREADY directly.
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
        .wclk(i2c_clk), .wrst_n(~i2c_rst), .winc(respfifo_winc), .wdata(respfifo_wdata),
        .wfull(respfifo_wfull), .awfull(),
        .rclk(cpu_clk), .rrst_n(~cpu_rst), .rinc(respfifo_rinc), .rdata(respfifo_rdata),
        .rempty(respfifo_rempty), .arempty()
    );

    assign PREADY = ~respfifo_rempty;
    assign PRDATA = {24'h0, respfifo_rdata};

    // -----------------------------------------------------------------
    // i2c_clk side: pop request -> drive a real WB cycle -> wait for
    // wb_ack_o -> push response. Single outstanding transaction, matches
    // APB's own one-transaction-at-a-time nature.
    // -----------------------------------------------------------------
    localparam I_IDLE = 1'b0, I_BUSY = 1'b1;
    reg         i2c_state;
    reg         we_r;
    reg [2:0]   addr_r;
    reg [7:0]   wdata_r;

    assign reqfifo_rinc = (i2c_state == I_IDLE) && ~reqfifo_rempty;

    always @(posedge i2c_clk) begin
        if (i2c_rst) begin
            i2c_state <= I_IDLE;
        end else begin
            case (i2c_state)
                I_IDLE: if (reqfifo_rinc) begin
                    {we_r, addr_r, wdata_r} <= reqfifo_rdata;
                    i2c_state <= I_BUSY;
                end
                I_BUSY: if (wb_ack_o) begin
                    i2c_state <= I_IDLE;
                end
            endcase
        end
    end

    wire wb_ack_o;
    wire [7:0] wb_dat_o;

    assign respfifo_winc  = (i2c_state == I_BUSY) && wb_ack_o;
    assign respfifo_wdata = wb_dat_o;

    i2c_master_top u_i2c_master (
        .wb_clk_i (i2c_clk),
        .wb_rst_i (i2c_rst),
        .arst_i   (1'b0),               // async reset unused, tie inactive
        .wb_adr_i (addr_r),
        .wb_dat_i (wdata_r),
        .wb_dat_o (wb_dat_o),
        .wb_we_i  (we_r),
        .wb_stb_i (i2c_state == I_BUSY),
        .wb_cyc_i (i2c_state == I_BUSY),
        .wb_ack_o (wb_ack_o),
        .wb_inta_o(),
        .scl_pad_i    (scl_pad_i),
        .scl_pad_o    (scl_pad_o),
        .scl_padoen_o (scl_padoen_o),
        .sda_pad_i    (sda_pad_i),
        .sda_pad_o    (sda_pad_o),
        .sda_padoen_o (sda_padoen_o)
    );

endmodule
