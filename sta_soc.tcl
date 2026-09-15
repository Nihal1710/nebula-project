set ORFS [expr {[info exists env(ORFS)] ? $env(ORFS) : "/OpenROAD-flow-scripts"}]
read_liberty $ORFS/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
read_verilog netlist/soc_top_netlist_clean.v
link_design soc_top

read_sdc constraints_soc.sdc

report_clock_properties

report_checks -path_delay max -group_path_count 20 \
    -format full_clock_expanded > reports/$env(STA_OUT)
