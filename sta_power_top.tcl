set ORFS [expr {[info exists env(ORFS)] ? $env(ORFS) : "/OpenROAD-flow-scripts"}]
read_liberty $ORFS/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
read_verilog $env(NETLIST)
link_design soc_top
read_sdc $env(SDC)
report_power -digits 4
report_power -highest_power_instances 50 -digits 4
