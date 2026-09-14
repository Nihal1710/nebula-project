read_liberty /home/nihal/OpenROAD-flow-scripts/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
read_verilog $env(NETLIST)
link_design soc_top
read_sdc $env(SDC)
report_power -digits 4
report_power -highest_power_instances 50 -digits 4
