#!/bin/bash
# Regenerate create_generated_clock lines from the current netlist.
NL=${NL:-netlist/soc_top_netlist_clean.v}
find_q () { grep -B12 "\.Q($1)" $NL | grep -oE "_[0-9]+_ \($" | tail -1 | tr -d ' ('; }
for spec in "cpu_div2:clk:2:cpu_clk_div2" \
            "uart_div4:uart_clk:4:u_div_uart_clk_div " \
            "i2c_div8:i2c_clk:8:i2c_clk_div8" \
            "spi_div16:spi_clk:16:spi_clk_div16" \
            "fir_div32:fir_clk:32:fir_clk_div32"; do
  IFS=: read name src div net <<< "$spec"
  inst=$(grep -B12 "\.Q($net)" $NL | grep -oE "DFF[A-Z_]*_X[0-9]+ _[0-9]+_" | tail -1 | awk '{print $2}')
  echo "create_generated_clock -name $name -source [get_ports $src] \\"
  echo "    -divide_by $div [get_pins $inst/Q]"
done
