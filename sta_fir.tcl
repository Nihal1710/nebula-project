set ORFS [expr {[info exists env(ORFS)] ? $env(ORFS) : "/OpenROAD-flow-scripts"}]
# ============================================================
# Track A - sta_fir.tcl
# Run: sta sta_fir.tcl
# (or the full path to the sta binary, same as before)
# EDIT: liberty path
# ============================================================
 
read_liberty $ORFS/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
read_verilog netlist/fir_wrapper_netlist_clean.v
link_design fir_wrapper
 
read_sdc constraints_fir.sdc
 
report_checks -path_delay max \
    -fields {slew cap input_pins} \
    -digits 4 \
    -format full_clock_expanded > reports/fir_wrapper_max_paths.rpt
 
report_checks -path_delay max -group_count 10 \
    -format full_clock_expanded > reports/fir_wrapper_top10.rpt
 

