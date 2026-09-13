# ============================================================
# Track A - constraints_fir.sdc
# fir_wrapper has TWO real, independently clocked domains.
# Unlike the PicoRV32-alone run, this needs:
#   1) a clock definition for EACH domain
#   2) an explicit statement that they're asynchronous to each
#      other, or OpenSTA will try to time straight across the
#      CDC boundary as if it were a normal same-clock path -
#      producing bogus "violations" that aren't real bugs.
# ============================================================

create_clock -name cpu_clk -period 0.98 [get_ports cpu_clk]
create_clock -name fir_clk -period 1.48 [get_ports fir_clk]

# Tell STA these two clocks are unrelated - don't try to check
# timing paths that cross between them.
set_clock_groups -asynchronous -group {cpu_clk} -group {fir_clk}

# Idealize I/O per its actual clock domain (not a shared blanket
# statement this time, since inputs now belong to different clocks)
set_input_delay 0 -clock cpu_clk [get_ports {PSEL_fir PADDR PENABLE PWRITE PWDATA cpu_rst}]
set_input_delay 0 -clock fir_clk [get_ports {fir_rst}]
set_output_delay 0 -clock cpu_clk [get_ports {PRDATA PREADY}]
