set ORFS [expr {[info exists env(ORFS)] ? $env(ORFS) : "/OpenROAD-flow-scripts"}]
# ============================================================
# Track A - Step 1: run OpenSTA report_checks
# Run:  sta sta.tcl        (binary name may be `opensta` on your setup)
#
# EDIT the liberty path to match synth.ys's.
# Make sure reports/ and netlist/ directories exist before running.
# ============================================================

read_liberty $ORFS/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib


read_verilog netlist/picorv32_netlist.v
link_design picorv32

read_sdc constraints.sdc

# Full point-by-point delay breakdown for the single worst path -
# this is what Step 4 (RTL tracing) will parse.
report_checks -path_delay max \
    -fields {slew cap input_pins} \
    -digits 4 \
    -format full_clock_expanded > reports/picorv32_max_paths.rpt

# Top 10 distinct violating paths, so you have more than one
# violation to choose from once the RTL-tracing step exists.
report_checks -path_delay max -group_count 10 \
    -format full_clock_expanded > reports/picorv32_top10.rpt
