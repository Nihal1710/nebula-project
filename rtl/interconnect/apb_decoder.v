`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : apb_decoder
// Description : Sits between picorv32_apb_bridge and the 4 peripheral wrappers
//               (UART, I2C, SPI, FIR). Two jobs:
//                 1. Outbound: decode PADDR[6:5] (qualified by the bridge's
//                    PSEL) into one PSELx per peripheral. PADDR/PWRITE/PWDATA/
//                    PSTRB/PENABLE are NOT muxed - they fan out identically to
//                    all 4 peripherals unchanged (single source, the bridge).
//                 2. Inbound: mux PRDATA/PREADY from whichever peripheral is
//                    currently selected back onto the single bus the bridge
//                    is watching.
//
// Memory map (32-byte / 0x20 window per peripheral, base 0x1000_0000):
//   0x1000_0000 - 0x1000_001F : UART
//   0x1000_0020 - 0x1000_003F : I2C
//   0x1000_0040 - 0x1000_005F : SPI
//   0x1000_0060 - 0x1000_007F : FIR
//   PADDR[4:2] -> register offset within whichever peripheral is selected
//   PADDR[6:5] -> which peripheral (2 bits, exactly covers 4 peripherals)
//
// Default/no-transaction case: PSEL_x are all "PSEL && address-range" gated,
// so when the bridge's own PSEL=0 (IDLE), none of the four are asserted -
// the else branch below covers exactly that case (PREADY=1 so the bus can
// never hang waiting on a peripheral that was never actually selected).
//////////////////////////////////////////////////////////////////////////////////
module apb_decoder (
    input         PSEL,
    input  [31:0] PADDR,

    // one PRDATA/PREADY pair PER PERIPHERAL (already muxed internally by
    // each peripheral's own register-level case statement)
    input  [31:0] PRDATA_uart, input PREADY_uart,
    input  [31:0] PRDATA_i2c,  input PREADY_i2c,
    input  [31:0] PRDATA_spi,  input PREADY_spi,
    input  [31:0] PRDATA_fir,  input PREADY_fir,

    output        PSEL_uart, PSEL_i2c, PSEL_spi, PSEL_fir,

    output reg [31:0] PRDATA,
    output reg        PREADY
);

    assign PSEL_uart = PSEL && (PADDR[6:5] == 2'b00);
    assign PSEL_i2c  = PSEL && (PADDR[6:5] == 2'b01);
    assign PSEL_spi  = PSEL && (PADDR[6:5] == 2'b10);
    assign PSEL_fir  = PSEL && (PADDR[6:5] == 2'b11);

    always @(*) begin
        if (PSEL_uart) begin
            PRDATA = PRDATA_uart;
            PREADY = PREADY_uart;
        end else if (PSEL_i2c) begin
            PRDATA = PRDATA_i2c;
            PREADY = PREADY_i2c;
        end else if (PSEL_spi) begin
            PRDATA = PRDATA_spi;
            PREADY = PREADY_spi;
        end else if (PSEL_fir) begin
            PRDATA = PRDATA_fir;
            PREADY = PREADY_fir;
        end else begin
            // no peripheral currently selected (bridge PSEL=0, i.e. IDLE) -
            // PREADY=1 here is what keeps the bus from ever being able to
            // hang on a transaction nothing actually claimed.
            PRDATA = 32'h0;
            PREADY = 1'b1;
        end
    end

endmodule
