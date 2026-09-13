#!/usr/bin/env bash
# ============================================================================
# Nebula@BITS Goa - repository cleanup before submission
#
# Run from the repo root:   bash cleanup_repo.sh
#
# Nothing is deleted outright. Everything removed is first moved to _attic/,
# which is gitignored. Delete _attic/ by hand once you are happy.
#
# Phases:
#   0  safety checks
#   1  commit build-critical files that are currently missing from git
#   2  archive scratch / duplicate files
#   3  untrack vendor simulator cruft
#   4  install the new .gitignore
#   5  verify the repo can still build, and report
# ============================================================================
set -u

ATTIC="_attic"
mkdir -p "$ATTIC"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
keep() { printf '   keep    %s\n' "$1"; }
arch() { if [ -e "$1" ]; then mkdir -p "$ATTIC/$(dirname "$1")"
           mv "$1" "$ATTIC/$1" 2>/dev/null && printf '   attic   %s\n' "$1"
         fi; }

# ---------------------------------------------------------------- phase 0 ---
say "Phase 0 - safety checks"

if [ ! -f synth_soc_top.ys ]; then
  echo "   ERROR: run this from the repo root (synth_soc_top.ys not found)"; exit 1
fi

# The two headline result files must exist and hold the expected numbers.
python3 - <<'PY' || { echo "   ERROR: result files missing or unexpected - ABORTING"; exit 1; }
import json, sys
def viol(f):
    d = json.load(open(f)); return sum(1 for p in d if p['slack_ns'] < 0)
try:
    b, a = viol('soc_violations_firbase_v2.json'), viol('soc_violations_FINAL.json')
except Exception as e:
    print("   ", e); sys.exit(1)
print(f"    baseline violated={b}  final violated={a}")
sys.exit(0 if (b, a) == (31, 3) else 1)
PY
echo "   result files verified (31 -> 3 violated paths)"

# ---------------------------------------------------------------- phase 1 ---
say "Phase 1 - commit build-critical files"

# clk_divider.v is read by synth_soc_top.ys but was never tracked, and
# soc_top.v carries uncommitted changes (RAM_WORDS=384, div_status, the five
# dividers). Without both, a fresh clone cannot reproduce any measurement.
git add rtl/clk_divider.v rtl/soc_top.v

# Gold/gate pairs Track C needed and had to reconstruct by hand.
for f in rtl/vendor/spi/rtl/verilog/simple_spi_top.v.orig \
         rtl/vendor/spi/rtl/verilog/simple_spi_top.v.restructured \
         rtl/vendor/uart/rtl/uart_rx.v.BASE ; do
  [ -f "$f" ] && git add -f "$f" && printf '   added   %s\n' "$f"
done

# The 33-line real-coefficient FIR baseline: gold for Track C case 2 and the
# pre-fix file every FIR measurement is relative to. Verified: 33 lines,
# real coefficients, no psum, not the degenerate all-ones benchmark.
if [ -f rtl/peripherals/fir_filter.v.orig ]; then
  if [ "$(grep -c "16'sd31" rtl/peripherals/fir_filter.v.orig)" = "2" ] \
     && [ "$(grep -c psum rtl/peripherals/fir_filter.v.orig)" = "0" ]; then
    git add -f rtl/peripherals/fir_filter.v.orig
    echo "   added   rtl/peripherals/fir_filter.v.orig (FIR baseline, verified)"
  else
    echo "   WARNING: fir_filter.v.orig is not the real-coefficient baseline - skipped"
  fi
fi

# Stale archives left in the index from before the folder restructure.
git rm --cached --quiet rtl.zip rtl1.zip 2>/dev/null && echo "   untracked rtl.zip rtl1.zip"

# Module-scale FIR flow (section 4b results) - keep it reproducible.
git add -f constraints_fir.sdc sta_fir.tcl synth_fir.ys fir_violations.json 2>/dev/null

# Flow scripts and constraints that may not be tracked yet.
git add -f fix_sdc.py sta_hold.tcl sta_soc.tcl gen_clocks.sh \
           synth_soc_top.ys sanitize_netlist.py parse_violation.py \
           propose_fix.py constraints_soc.sdc constraints_soc_FINAL.sdc 2>/dev/null

# Canonical results.
git add -f soc_violations_firbase_v2.json soc_violations_firbase_v2_excluded.json \
           soc_violations_FINAL.json soc_violations_FINAL_excluded.json \
           soc_violations_base2.json soc_violations_base2_excluded.json \
           soc_violations_spifix.json soc_violations_spifix2.json \
           reports/soc_top_FINAL_setup.rpt reports/soc_top_FINAL_hold.rpt \
           reports/soc_top_firbase_v2.rpt reports/soc_top_hold_FIRBASE_v2.rpt \
           fixes/ 2>/dev/null
echo "   staged"

# ---------------------------------------------------------------- phase 2 ---
say "Phase 2 - archive scratch and duplicate files"

# Editor/scratch leftovers
arch propose_fix.py.bak
arch sta_soc.tcl.bak
arch constraints_soc.sdc.messy
arch fresh_clocks.txt
arch soc_top_sim.vvp

# Byte-identical duplicates (md5-verified). The kept copy is named in brackets.
arch soc_violations.json                      # [base2]
arch soc_violations_TUNED.json                # [base2]
arch soc_violations_excluded.json             # [base2_excluded]
arch soc_violations_FIRBASE_KEEP.json         # [firbase] - superseded by _v2
arch soc_violations_firbase.json              # superseded by _v2 (SDC fixed)
arch soc_violations_firbase_excluded.json     # [firbase_v2_excluded]
arch soc_violations_BOTHFIXED_KEEP.json       # [uartfix]
arch soc_violations_uartfix.json              # superseded by FINAL
arch soc_violations_uartfix_excluded.json     # [FINAL_excluded]
arch fir_violations_allones.json              # [fir_violations]
arch violations.json                          # pre-SoC single-clock scrap
arch constraints/                             # empty legacy dir
arch flow/                                    # empty legacy dir
arch constraints_soc_UARTFIX.sdc              # superseded by FINAL
arch constraints_soc_TUNED.sdc                # superseded by FINAL

# Superseded reports (the _v2 / FINAL versions are the canonical ones)
arch reports/soc_top_firbase.rpt
arch reports/soc_top_FIRBASE_KEEP.rpt
arch reports/soc_top_hold_FIRBASE.rpt
arch reports/soc_top_uartfix.rpt
arch reports/soc_top_TUNED.rpt

# Intermediate FIR variants - the accepted version is in git, and every
# variant is recoverable from modified_rtl in fixes/*.json
arch rtl/peripherals/fir_filter.v.base
arch rtl/peripherals/fir_filter.v.psum
arch rtl/peripherals/fir_filter.v.orig.bak
arch rtl/peripherals/fir_filter.v.FIXED
arch rtl/vendor/spi/rtl/verilog/simple_spi_top.v.base

# Vendor simulation output (~80 MB, regenerable by the vendor's own testbench)
arch rtl/vendor/uart/work
arch rtl/vendor/i2c/sim/i2c_verilog/run/bench.vcd

# ---------------------------------------------------------------- phase 3 ---
say "Phase 3 - untrack vendor simulator cruft"

# Cadence NC-Sim work directory: binary .pak databases, no use in this flow.
git rm -r --cached --quiet rtl/vendor/spi/sim/rtl_sim/run/ncwork 2>/dev/null \
  && echo "   untracked ncwork/ (2.8 MB of .pak)"
arch rtl/vendor/spi/sim/rtl_sim/run/ncwork

# 5.1 MB foundry liberty from the FIFO vendor's own ASIC flow. Unused here -
# this project synthesises against Nangate45.
git rm --cached --quiet rtl/vendor/async_fifo/syn/vsclib013.lib 2>/dev/null \
  && echo "   untracked vsclib013.lib (5.1 MB)"
arch rtl/vendor/async_fifo/syn/vsclib013.lib

# .doc sources duplicated by the PDFs that sit beside them.
for f in rtl/vendor/i2c/doc/src/I2C_specs.doc rtl/vendor/spi/doc/src/simple_spi.doc; do
  git rm --cached --quiet "$f" 2>/dev/null && printf '   untracked %s\n' "$f"
  arch "$f"
done

# ---------------------------------------------------------------- phase 4 ---
say "Phase 4 - install .gitignore"
cat > .gitignore <<'GITEOF'
# --- simulation / build artefacts ---
*.vvp
*.vcd
*.log
*.key
__pycache__/
*.pyc

# --- python env (284 MB; recreate: python3 -m venv .venv) ---
.venv/

# --- synthesis outputs; regenerate with `yosys synth_soc_top.ys` ---
netlist/*.v

# --- scratch ---
*.bak
*.messy
fresh_clocks.txt
_attic/

# --- vendor simulator work dirs ---
rtl/vendor/*/work/
rtl/vendor/*/sim/*/run/ncwork/
rtl/vendor/*/sim/*/run/*.vcd
GITEOF
git add .gitignore
echo "   installed"

# ---------------------------------------------------------------- phase 5 ---
say "Phase 5 - verify the repo can still build"

missing=0
for f in $(grep -oE "rtl/[A-Za-z0-9_/.]+\.v" synth_soc_top.ys | sort -u); do
  if [ ! -f "$f" ]; then
    printf '   MISSING ON DISK  %s\n' "$f"; missing=1
  elif ! git ls-files --error-unmatch "$f" >/dev/null 2>&1 \
       && ! git diff --cached --name-only | grep -qx "$f"; then
    printf '   NOT IN GIT       %s\n' "$f"; missing=1
  fi
done
[ "$missing" -eq 0 ] && echo "   all 26 synthesis inputs present and staged"

say "Summary"
printf '   tracked files : %s\n' "$(git ls-files | wc -l)"
printf '   staged changes: %s\n'  "$(git diff --cached --name-only | wc -l)"
printf '   archived      : %s files in %s/\n' "$(find $ATTIC -type f 2>/dev/null | wc -l)" "$ATTIC"
du -sh "$ATTIC" 2>/dev/null | sed 's/^/   attic size    : /'

cat <<'NEXT'

   Next:
     git status                 # review
     git commit -m "Clean repo: track build-critical RTL, drop vendor cruft"
     rm -rf _attic              # once you are happy nothing is needed
NEXT
