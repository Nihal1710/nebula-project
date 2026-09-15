set ORFS [expr {[info exists env(ORFS)] ? $env(ORFS) : "/OpenROAD-flow-scripts"}]
read_liberty $ORFS/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
read_verilog $env(NETLIST)
link_design soc_top
read_sdc constraints_soc.sdc
#set_power_activity -global -activity 0.1 -duty 0.5
report_power -digits 4 > reports/$env(STA_OUT)
