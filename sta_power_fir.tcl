read_liberty /home/nihal/OpenROAD-flow-scripts/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
read_verilog $env(NETLIST)
link_design fir_wrapper
read_sdc constraints_fir.sdc
report_power -digits 4
