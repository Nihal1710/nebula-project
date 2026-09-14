# Nebula@BITS Goa — Session Handoff

**Read this first in a new chat.** It holds everything needed to continue
without re-deriving anything.

**Date:** 14 Sep 2026 · **Submission:** 15 Sep · **Shortlisting:** 19 Sep ·
**Presentations:** 25 Sep

---

## 1. Project

**"Constraint Optimization through RTL Enhancement Using Generative AI"** —
Nebula@BITS Goa hackathon, Digital track, sponsored by Astera Labs. Team of
three.

**The contribution** is a closed loop: an LLM reads a timing violation,
proposes an RTL fix, the fix is formally verified for functional equivalence,
and then re-measured against whole-design re-synthesis and STA before being
accepted or rejected.

**The SoC is the benchmark vehicle, not the contribution.** The generality
claim rests on the LLM only ever seeing an isolated violating path plus local
RTL — never full-SoC context.

**Team**
- **Nihal** (the user) — Track B (LLM proposal + orchestration), overall
  integration, build machine (Dell G15, Ubuntu 22.04.5)
- **Prathik** — Tracks A + B
- **Praneeth** — Track C (formal verification, EQY/SBY), HP Victus

**Repo:** `github.com/Nihal1710/nebula-project` — clean, reproducible,
everything pushed as of commit `3fe9dbf`.

---

## 2. Status: technical work is COMPLETE

Measurement, verification, evidence and repo hygiene are all finished and
committed. What remains is writing. Do not re-run experiments unless the
user asks.

### Headline result

63,080-cell SoC, five asynchronous clock domains, Nangate45.

| clock | baseline (`firbase_v2`) | final (`FINAL`) |
|---|---|---|
| `fir_clk` | −0.37 ns, 20 violated | **−0.03 ns, 2 violated** |
| `i2c_clk` | −0.10 ns, 10 violated | **+0.02 ns, 0 violated** |
| `spi_clk` | −0.06 ns, 1 violated | −0.05 ns, 1 violated |
| `uart_clk` | +0.02 ns, 0 violated | +0.02 ns, 0 violated |
| **design-wide violated** | **31** | **3** |
| hold violations | 0 | **0** |

Both columns measured under one SDC, one synthesis each, setup and hold
together.

**Careful:** `uart_clk` reads +0.02 in *both* columns because the UART fix
was already applied before the FIR baseline was taken. The UART result comes
from a different pair: `base2` → `uartfix`, −0.02 → +0.02. **The report needs
two comparisons, not one.**

### The four proposals — four different correct outcomes

| # | violation | fix_type | tier | verification | timing | verdict |
|---|---|---|---|---|---|---|
| 1 | `fir_clk` −0.37 (module: −0.4069) | `pipeline` +1 | 2 | EQY inconclusive → SBY BMC depth 40 PASS | −0.37→−0.03 SoC; −0.4069→+0.0536 module | **ACCEPTED** |
| 2 | `uart_clk` −0.02 | `restructure` +0 | 1 | EQY 12/13 + miter PASS | −0.02→+0.02 | **ACCEPTED** |
| 3 | `spi_clk` −0.03 | `restructure` ×2 | 1 | EQY PASS, unbounded | −0.03→−0.08 (v2), −0.16 (v1) | **REJECTED — regressed own domain** |
| 4 | `fir_clk` −0.03 residual | `restructure` +0 | 1 | provably bit-exact (assoc. mod 2^41) | `fir_clk` −0.03→+0.07 **but** `i2c_clk` 0→3 violated; design-wide 3→4 | **REJECTED — broke another domain** |

Three rejection *reasons*, all different: own-domain regression, other-domain
regression, and (in Case 3) an unreachable counterexample.

### The two accepted fixes

**UART** (`rtl/vendor/uart/rtl/uart_rx.v`):
```verilog
- assign uart_rx_valid = fsm_state == FSM_STOP && n_fsm_state == FSM_IDLE;
+ assign uart_rx_valid = fsm_state == FSM_STOP && next_bit;
```
Plus a pure relocation of the `next_bit`/`payload_done` wire declarations
from ~line 108 to ~line 93 (needed because line 94 now references
`next_bit`). Adds no logic — `next_bit` already exists. Verified exhaustively
over all 64 combinations of `{fsm_state[2:0], next_bit, rxd_reg,
payload_done}` including all 32 unreachable encodings, 0 mismatches. Path
went 14 stages → 13.

**FIR** (`rtl/peripherals/fir_filter.v`): 8-term serial MAC sum split into
two registered 4-term halves `psum_lo`/`psum_hi`, +1 cycle latency. File went
33 lines → 45.

**Rejected #4** (recorded in `fixes/fir_adder_tree_REJECTED.json`): rebalanced
`(a+b)+(c+d)` instead of `((a+b)+c)+d` in each half. Bit-exact — addition is
associative modulo 2^41 and the 41-bit target cannot overflow (worst half-sum
needs 23 bits). Verified over 200,000 random 41-bit trials, 0 mismatches.

---

## 3. Formal verification — all three cases pass, logs in `formal/logs/`

| case | fix | tool result |
|---|---|---|
| 1 SPI | `restructure` | EQY: all partitions proved, "Successfully proved designs equivalent", `DONE (PASS, rc=0)`, 3s. Unbounded sequential. |
| 2 FIR | `pipeline` | EQY inconclusive (register-layout mismatch). SBY `bmc` **PASS depth 40**. SBY `prove` basecase pass, **induction FAIL → `DONE (UNKNOWN, rc=4)`** |
| 3 UART | `restructure` | EQY 12/13 proved, `uart_rx_valid` FAIL `rc=2` with a *spurious* counterexample. Miter **PASS depth 1**, exhaustive combinational. |

### The two EQY failure modes (a key contribution)

**Mode 1 — register-layout mismatch (Case 2).** EQY matches partitions by
register name. A pipeline fix adds registers with no gold counterpart, so
those partitions can't be compared. Returns FAIL with **no counterexample**,
because none was searched for. *Every Tier 2 fix hits this by construction —
adding registers is what pipelining is.*

**Mode 2 — spurious counterexample (Case 3).** EQY cuts the logic cone at
register boundaries and feeds crossing signals in as **free inputs**. Sound
for proving, **unsound for disproving**. It produced
`fsm_state=FSM_STOP, next_bit=1, n_fsm_state=FSM_START` — impossible, since
the case statement forces `n_fsm_state=FSM_IDLE` there. The VCD proves the
mechanism: signals appear as `__pi_n_fsm_state` (`__pi_` = *partition input*).
SAT model: `in_gold=0, in_gate=1, okay=0`.

**The rule:** EQY PASS is conclusive. EQY FAIL is not. Only a **miter**
counterexample — which runs both whole designs from reset with nothing cut —
is trustworthy enough to drive a retry.

---

## 4. The corrected loop

Originally specified as `propose → EQY → retry on failure`. Measurement
forced three gates:

```
propose → validate ─┬─ tier 1 → EQY ─┬─ PASS ──────────────┐
                    │                └─ FAIL/INCONCL ─┐    │
                    └─ tier 2 ──────────────────────→ miter │
                                 miter FAIL (real CEX) │    │
                                       ↓               │    │
                                     RETRY ←───────────┘    ↓
                                                         re-STA
                                                   ┌────────┴────────┐
                                                improved         regressed
                                                   ↓                 ↓
                                                ACCEPT            REJECT
```

- **Gate A — re-STA after verification.** SPI passed EQY and was slower.
- **Gate B — never retry on an EQY counterexample; escalate to a miter.**
  The miter *is* the reachability check.
- **Gate C — route by tier.** Tier 2 skips EQY; its failure carries no
  information.

**The retry path has never fired.** No proposal was ever genuinely broken.
Implemented but untested — say so plainly.

---

## 5. Scope escalation (built this session)

`propose_fix.py` picked its edit scope from `attributed[0]` — the *launch
flop*. On multi-module paths that's often the wrong file.

**UART violation 112 spans three files:**
```
uart_rx.v        0.52 ns  ← launch flop, attributed
uart_wrapper.v   0.08 ns  ← NO flop on path, INVISIBLE to attribution
wptr_full.v      0.34 ns  ← capture flop, attributed
```
Total 0.94 ns, 12 of 14 cells unattributed. The model partitioned this
correctly and declined because 55% of the delay was off-scope — then named
`uart_rx.v:108-123` as where the fix belonged.

**Built:**
- `patch_schema.py` — adds `out_of_scope_fix` to the schema (machine-readable
  refusal), a prompt section, validator rules, and a `--scope-file` flag
- `escalate.py` — walks the file ladder automatically, **bounded to files on
  the violating path**. Terminal states: `SOLVED`, `REFUSED` (model names
  nowhere else — a real refusal), `EXHAUSTED`.
- `run_loop.py` — end-to-end orchestrator with `--replay` (default),
  `--live`, `--all`, `--case <tag>`, `--list`

---

## 6. Negative results (all measured, all reportable)

- **PicoRV32 contributed nothing, by mechanism.** All **200** worst `cpu_clk`
  paths run through one `NOR2_X1` driving 723 loads at ~700 ns. Zero survive
  the fanout filter (`MAX_STAGE_NS = 10.0`). Yosys does no buffer insertion —
  this is a flow artifact, not a design defect. Physical synthesis would be
  needed. `soc_violations_cpu200.json`.
- **No `retime` candidate exists.** Searched all paths for register
  imbalance; two candidates found, both in `clk_divider.v` with **+46.30** and
  **+3.42 ns** slack. Strategy implemented and validated, never exercised
  against a real violation.
- **SPI is unfixable at RTL level.** `abc` already maps the 12-bit ripple
  decrementer optimally by sharing borrow terms. Any RTL carry-lookahead
  formulation needs an "is low half all zeros" test → wide `OR4_X1` reduction
  tree at 0.11–0.14 ns vs ~0.05 ns for 2-input gates. Diagnosed twice; the
  current `spi_clk` violation is the **same path, same gates**. Don't re-run.
- **Attribution survives on flip-flops only.** Across all 140 paths, **zero**
  combinational gates carry `src`. `dfflibmap` maps flops 1:1 so tags survive;
  `abc` re-synthesises combinational logic from scratch. **No scope selector
  can ever point at the logic causing a setup violation.**
- **Model choice changes the outcome.** Identical prompts on UART violation
  112: Sonnet → `no_fix`, Opus → `retime` (validator clean, RTL differs from
  input — not a disguised refusal). `fixes_modelcmp/`. Note Sonnet produced
  the *accepted* fix only when given cross-module context files.
- **The loop is an iteration, not a single pass, and does not converge
  monotonically.** FIR was fixed twice (pipeline on the 8-term sum, then the
  4-term sums that split created). Fix #4 closed its own domain and raised
  design-wide violations 3→4. **Order matters** — 31→3 reflects one
  trajectory, not a canonical optimum.
- **L4-bis, four observations, both directions.** Local RTL edits perturb
  untouched modules: SPI fix hurt `fir_clk`; FIR pipeline *fixed* 10
  `i2c_clk` violations; adder tree *broke* `i2c_clk`. Per-fix deltas are
  whole-design deltas.

---

## 7. Deliverables vs the spec (from the hackathon problem statement)

| deliverable | status |
|---|---|
| RTL timing analysis framework | ✅ |
| GenAI-based RTL optimization engine | ✅ |
| Critical path and timing violation analysis | ✅ |
| Optimized RTL implementation | ✅ |
| Timing, frequency and **PPA** comparison | ⚠️ **no power numbers — biggest gap** |
| Formal equivalence verification report | ✅ |
| Interactive demo | ⚠️ `run_loop.py` is a CLI replay, not interactive |

**Benchmark requirements all met:** 5 independent async masters ✅; ≥1
generated clock per master ✅ (ratios 2/4/8/16/32); CDC via async FIFOs +
`set_clock_groups -asynchronous` ✅; ~50K cells → **63,080** ✅.

**FSM optimization** is spec-listed and deliberately scoped out: re-encoding
changes the state register's width and values, leaving EQY no register
correspondence. Verified there IS headroom — the flow never runs Yosys's
`fsm` passes (`proc; flatten; opt; memory; techmap; dfflibmap; abc`, no
`synth`), and `uart_rx` uses 3-bit binary encoding for 4 states, so
`fsm_state == FSM_STOP` would become a single bit read under one-hot. State
it as a deliberate exclusion with the mechanism, not an omission.

---

## 8. Remaining work

1. **Power/PPA numbers** — the only real deliverable gap. `report_power` in
   OpenSTA on both netlists (`netlist/soc_top_netlist_FIRBASE.v` and the
   final). ~20 min. Frequency is free arithmetic: `f_max = 1/(period − slack)`
   — e.g. `fir_clk` 546 MHz → 671 MHz.
2. **`docs/` is EMPTY.** Needs the report plus Praneeth's `TRACK_C_REPORT.md`
   and `TRACK_C_ISSUES.md` as appendices.
3. **`README.md`** — doesn't exist.
4. **The report** — one document, organised by argument, NOT split by track.
   The best results span tracks (SPI: C proved it correct, A proved it
   slower). One short "who did what" paragraph covers attribution.
5. **Demo** — make it actually interactive, or stop calling it that.
6. **Praneeth still owes:** confirmation that `formal/` configs run from a
   fresh clone, and sign-off on `formal/README.md` wording (he ran the cases,
   it should be his words).

---

## 9. Environment

**Docker (Track A only — synthesis and STA):**
```bash
sudo systemctl start docker
docker run -it --rm --user $(id -u):$(id -g) \
  -v ~/nebula-project:/workspace \
  -v ~/OpenROAD-flow-scripts:/home/nihal/OpenROAD-flow-scripts:ro \
  -w /workspace openroad/flow-ubuntu22.04-builder:aeae7d bash
```
`sta` is NOT on PATH: `/OpenROAD-flow-scripts/tools/install/OpenROAD/bin/sta`

**Track B (no Docker, no API key — Pro subscription via Claude Agent SDK):**
```bash
source .venv/bin/activate
unset ANTHROPIC_API_KEY      # else it bills the API, which Pro doesn't include
```

**Full flow:**
```bash
yosys synth_soc_top.ys
python3 sanitize_netlist.py netlist/soc_top_netlist.v netlist/soc_top_netlist_clean.v
./gen_clocks.sh > fresh_clocks.txt && python3 fix_sdc.py constraints_soc.sdc fresh_clocks.txt
grep -c create_generated_clock constraints_soc.sdc     # MUST be 5
STA_OUT=<name>.rpt /OpenROAD-flow-scripts/tools/install/OpenROAD/bin/sta -no_splash -exit sta_soc.tcl
STA_OUT=<name>_hold.rpt ... -exit sta_hold.tcl
python3 parse_violation.py --report reports/<name>.rpt \
  --netlist netlist/soc_top_netlist_clean.v --repo-root . --out soc_violations_<name>.json
bash run_soc_top.sh          # iverilog SoC simulation, 4 PASS + "ALL 4 PERIPHERALS REACHED"
```

**Key files:** `soc_violations_base2.json` (pre-UART-fix baseline),
`soc_violations_firbase_v2.json` (pre-FIR-fix baseline, 31 violated),
`soc_violations_FINAL.json` (both fixes, 3 violated),
`soc_violations_FIRTREE_REJECTED.json` (proposal #4),
`soc_violations_cpu200.json`, `constraints_soc_FINAL.sdc`,
`fixes/*_ACCEPTED.json`, `formal/` (3 cases + logs).

---

## 10. Traps (learned the hard way — every one of these cost real time)

- **`gen_clocks.sh` prints, it does not write.** Pasting appended three
  stacked `create_generated_clock` blocks into the SDC → OpenSTA Error 374.
  `fix_sdc.py` now strips and reinserts. Always `grep -c` for 5 afterwards.
- **`sta_soc.tcl` had a hardcoded output path** and silently overwrote
  reports. Now `reports/$env(STA_OUT)`.
- **`2>/dev/null` hid an argparse error** and made a failed run look like a
  successful one that found nothing. Drop it when debugging.
- **`.gitignore` had `*.log` / `*.vcd`** and silently swallowed the formal
  evidence. `git commit` reporting fewer files than you added is the tell.
- **`git HEAD` had the WRONG `fir_filter.v`** — the degenerate all-ones
  benchmark (`c[i] <= 1`, Yosys constant-folds it, multipliers vanish). The
  real 33-line baseline is `rtl/peripherals/fir_filter.v.orig`. Guard:
  `grep -c "c\[i\] <= 1"` must be **0**.
- **`soc_violations_base2.json` was NOT a baseline** — the FIR fix was
  already in it (attributed to `fir_filter.v:30-38`, lines that only exist in
  the 45-line fixed file). Cost the whole FIR before/after. **Always check
  file mtimes against JSON mtimes.**
- **`run_soc_top.sh` was missing `rtl/clk_divider.v`** → "unknown module type
  div_domain". Fixed.
- **`rtl/clk_divider.v` was untracked** while being required by synthesis —
  the repo could not build from a fresh clone. Fixed.
- **`depth` is illegal in `[options]`** of a `.eqy` file; it belongs in
  `[strategy]`. **`[recipe]` is not a valid section at all** (I got this
  wrong and it cost Praneeth a syntax error).
- **Repo was 455 MB.** `.venv` 284 MB, vendor waveforms 75 MB, tracked
  foundry liberty 5.1 MB, Cadence `.pak` 2.8 MB. Now 42 MB working tree,
  6.3 MB tracked. `cleanup_repo.sh` did this; it archives to `_attic/` rather
  than deleting.

---

## 11. Working style (respect this)

- Prefers **running commands and reading real output before interpreting** —
  not explanation-first.
- **Pushes back hard on jargon.** If a term appears without first establishing
  what the underlying files or data actually say, expect to be called on it.
  "explain properly", "what do you mean" → go back to zero, use their own
  code as the example, define every term.
- Wants **copy-paste-ready commands**, not abstract guidance.
- Says **"just give me the code"** under time pressure — take it literally.
- **Verify claims against the actual repo before asserting them.** Several
  significant findings this session came from checking rather than assuming
  (the base2 baseline problem, the untracked `clk_divider.v`, the git `.orig`
  being the wrong version, Praneeth's "urgent" item already being fixed).
- Corrects imprecise framing mid-conversation and is right to.
- When something looks like a failure, **check whether it's actually a tooling
  error first** — several "failures" this session were argparse errors, stale
  clones, or gitignore rules.
