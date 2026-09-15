set ORFS [expr {[info exists env(ORFS)] ? $env(ORFS) : "/OpenROAD-flow-scripts"}]
read_liberty $ORFS/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
read_verilog netlist/soc_top_netlist_clean.v
link_design soc_top
read_sdc constraints_soc.sdc

# 200 worst paths per group instead of 20: the top 20 cpu_clk paths all run
# through a single 723-load net (L1 fanout artifact) and are filtered out by
# parse_violation.py, leaving PicoRV32 with no reportable violations at all.
report_checks -path_delay max -group_path_count 200 \
    -format full_clock_expanded > reports/$env(STA_OUT)
