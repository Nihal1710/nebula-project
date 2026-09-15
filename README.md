# Constraint Optimization through RTL Enhancement Using Generative AI

Nebula@BITS Goa, Digital track, sponsored by Astera Labs.

A closed loop that takes a static timing violation, asks a language model for
an RTL fix, proves the fix functionally equivalent, re-synthesises the whole
design, and accepts or rejects the fix on the re-measured result.

The loop is the contribution. The 63,080-cell five-domain SoC in `rtl/` is the
benchmark it was measured on. The model never sees the SoC — it sees one
violating path and the local RTL around it, which is why the approach is not
specific to this design.

---

## Result

Nangate45, five asynchronous clock domains, setup and hold, one SDC, one
synthesis per column.

| clock | baseline | after two accepted fixes |
|---|---|---|
| `fir_clk` | −0.37 ns, 20 violated | **−0.03 ns, 2 violated** |
| `i2c_clk` | −0.10 ns, 10 violated | **+0.02 ns, 0 violated** |
| `spi_clk` | −0.06 ns, 1 violated | −0.05 ns, 1 violated |
| `uart_clk` | +0.02 ns, 0 violated | +0.02 ns, 0 violated |
| **design-wide violated paths** | **31** | **3** |
| hold violations | 0 | **0** |
| cells | 63,335 | 63,080 |
| total power | 135.2 mW | 101.5 mW |

`uart_clk` reads the same in both columns because the UART fix landed before
this baseline was taken. Its own comparison is `base2` → `uartfix`:
**−0.02 → +0.02 ns**. Two accepted fixes, two separate before/after pairs.

Four proposals, four outcomes: two accepted, two rejected — one for regressing
its own clock domain, one for closing its own domain while breaking another.
See `docs/REPORT.md`.

---

## Run the loop (no tools required)

This needs Python 3 and nothing else. No Docker, no OSS CAD Suite, no API key.

```bash
python3 run_loop.py --list          # every recorded proposal
python3 run_loop.py --all           # all four cases end to end
python3 run_loop.py --case uart_rx_uart_clk_ACCEPTED
```

Replay mode walks recorded artefacts from `fixes/*.json` and the saved SoC
measurements. It runs in about a second. The decision logic in `decide()` is
live code, not a transcript — it is what routes a case by tier, gates on
re-STA, and refuses to retry on an unreachable counterexample.

`--live` re-runs the proposal stage against the model. Synthesis, STA and
equivalence checking still come from artefacts, because those need Docker and
the CAD suite respectively.

---

## Layout

```
run_loop.py            orchestrator; decision logic lives in decide()
propose_fix.py         builds the prompt, calls the model, validates the patch
escalate.py            widens edit scope, bounded to files on the violating path
patch_schema.py        adds out_of_scope_fix to the patch schema (idempotent)
parse_violation.py     OpenSTA report -> JSON violation bundles with RTL spans
sanitize_netlist.py    makes a Yosys netlist parseable by OpenSTA
fix_sdc.py             strips and reinserts generated-clock blocks

rtl/                   the benchmark SoC (own RTL + rtl/vendor/ upstream cores)
tb/                    testbenches, tb_soc_top.v is the assembled-SoC one
formal/                three equivalence cases, configs, miters, logs
fixes/                 every proposal the model produced, accepted and rejected
fixes_modelcmp/        same violation, Sonnet vs Opus
reports/              OpenSTA setup, hold and power reports
docs/REPORT.md         the report
docs/HANDOFF.md        working state
```

`netlist/` is gitignored — netlists are 8 MB each and do not survive a clone.
Re-synthesise before trusting any measurement against an on-disk netlist.

`soc_violations_*.json` at the repo root are the measurement set:
`base2` (pre-UART-fix), `firbase_v2` (pre-FIR-fix, 31 violated), `FINAL` and
`FINAL_v2` (both fixes, 3 violated, independently rebuilt),
`FIRTREE_REJECTED` (proposal 4), `cpu200` (the PicoRV32 negative result).

---

## Reproducing the measurements

### Synthesis and STA — Docker

```bash
sudo systemctl start docker
docker run -it --rm --user $(id -u):$(id -g) \
  -v ~/nebula-project:/workspace \
  -v ~/OpenROAD-flow-scripts:/home/nihal/OpenROAD-flow-scripts:ro \
  -w /workspace openroad/flow-ubuntu22.04-builder:aeae7d bash

S=/OpenROAD-flow-scripts/tools/install/OpenROAD/bin/sta   # not on PATH
$S -version                                                # check this first
```

The liberty path is hardcoded in the `.ys` and `.tcl` scripts as
`/home/nihal/OpenROAD-flow-scripts/...`. That resolves inside the container
because of the mount above. Outside it, edit the three occurrences in
`synth_soc_top.ys` and the one in each `sta_*.tcl`.

```bash
yosys synth_soc_top.ys
python3 sanitize_netlist.py netlist/soc_top_netlist.v netlist/soc_top_netlist_clean.v

./gen_clocks.sh > fresh_clocks.txt
python3 fix_sdc.py constraints_soc.sdc fresh_clocks.txt
grep -c create_generated_clock constraints_soc.sdc          # must print 5

STA_OUT=run.rpt      $S -no_splash -exit sta_soc.tcl
STA_OUT=run_hold.rpt $S -no_splash -exit sta_hold.tcl

python3 parse_violation.py --report reports/run.rpt \
  --netlist netlist/soc_top_netlist_clean.v --repo-root . --out soc_violations_run.json
```

`gen_clocks.sh` prints, it does not write. The generated-clock pin names change
with every synthesis, which is why `fix_sdc.py` exists and why the `grep -c`
is not optional.

### Power

```bash
NETLIST=netlist/soc_top_netlist_FIRBASE.v  STA_OUT=power_FIRBASE.rpt  $S -no_splash -exit sta_power.tcl
NETLIST=netlist/soc_top_netlist_FINAL_v2.v STA_OUT=power_FINAL.rpt    $S -no_splash -exit sta_power.tcl
```

`sta_power_noact.tcl` deliberately runs **no** `set_power_activity`. Both
annotation strategies tried produced non-physical output (4e+15 W, NaN, inf);
removing the annotation entirely gives a finite, consistent report. The files
`reports/power_*_v2.rpt` and the `-input` pair are kept as evidence of that
failure, not as results.

The SDC must match the netlist. Generated clocks are pinned to synthesis-
specific cell names, and Yosys renumbers on every run, so measuring an archived
netlist against the current SDC silently builds a fictional clock network.
Regenerate first:

```bash
NL=<netlist> ./gen_clocks.sh > fresh_clocks_<tag>.txt
python3 fix_sdc.py constraints_soc_<tag>.sdc fresh_clocks_<tag>.txt
```

Module-scope power for the FIR, which needs no generated clocks at all:

```bash
NETLIST=netlist/fir_gl_BASE.v  $S -no_splash -exit sta_power_fir.tcl
NETLIST=netlist/fir_gl_FINAL.v $S -no_splash -exit sta_power_fir.tcl
```

### Simulation

```bash
bash run_soc_top.sh     # expect 4 PASS and "ALL 4 PERIPHERALS REACHED"
```

Needs `iverilog` with `-g2012`. This is the check formal verification
structurally cannot do: the fixes running inside the assembled SoC, including
the FIR pipeline's extra cycle not breaking `fir_wrapper`'s handshake.

### Equivalence checking

```bash
source ~/tools/oss-cad-suite/environment    # per shell, every shell
cd formal && cat README.md
```

`eqy: command not found` means the `source` was skipped. Full per-case
instructions and expected output are in `formal/README.md`.

---

## Guards

Two checks that catch the failure modes that cost the most time:

```bash
grep -c "c\[i\] <= 1" rtl/peripherals/fir_filter.v     # must be 0
```

A non-zero result means the degenerate all-ones FIR is in the tree. Yosys
constant-folds it, the multipliers vanish, and every timing number taken
against it is meaningless. The real 33-line baseline is
`rtl/peripherals/fir_filter.v.orig`.

```bash
ls -la netlist/*.v soc_violations_*.json
```

Compare mtimes. A violation JSON older than the netlist it claims to describe
is measuring something else. This happened once and cost an entire before/after
comparison.

More generally: verify with a check that can fail. Confirming a gate-level
netlist by grepping it for RTL syntax returns 0 for every file, including the
wrong one. The only real check on a netlist is re-running STA and comparing the
violated-path count.

---

## Who did what

Nihal — Track B (proposal, validation, scope escalation, orchestration),
integration, and the measurement runs. Prathik — Tracks A and B. Praneeth —
Track C, the EQY and SBY cases in `formal/` and their logs.

---

## Environment

Ubuntu 22.04.5. Yosys 0.67, OpenSTA 3.1.0 and OpenROAD 26Q3 via
`openroad/flow-ubuntu22.04-builder:aeae7d`. EQY and SBY from OSS CAD Suite.
Icarus Verilog for simulation. Track B runs outside Docker:

```bash
source .venv/bin/activate
unset ANTHROPIC_API_KEY     # the Pro subscription path does not use the API key
```
