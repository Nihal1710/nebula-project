#!/bin/bash
set -e
iverilog -g2012 \
  -I rtl/vendor/i2c/rtl/verilog \
  -o soc_top_sim.vvp \
  tb/tb_soc_top.v \
  rtl/soc_top.v \
  rtl/memory/mem_arbiter.v \
  rtl/memory/simple_ram.v \
  rtl/vendor/picorv32/picorv32.v \
  rtl/interconnect/picorv32_apb_bridge.v \
  rtl/interconnect/apb_decoder.v \
  rtl/peripherals/uart_wrapper.v \
  rtl/vendor/uart/rtl/uart_tx.v \
  rtl/vendor/uart/rtl/uart_rx.v \
  rtl/peripherals/i2c_shim.v \
  rtl/vendor/i2c/rtl/verilog/*.v \
  rtl/peripherals/spi_shim.v \
  rtl/vendor/spi/rtl/verilog/*.v \
  rtl/peripherals/fir_wrapper.v \
  rtl/peripherals/fir_filter.v \
  rtl/vendor/async_fifo/rtl/*.v
vvp soc_top_sim.vvp
