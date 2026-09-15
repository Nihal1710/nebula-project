set ORFS [expr {[info exists env(ORFS)] ? $env(ORFS) : "/OpenROAD-flow-scripts"}]
read_liberty $ORFS/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
read_verilog $env(NETLIST)
link_design fir_wrapper
read_sdc constraints_fir.sdc
report_power -digits 4
