# formal/ — equivalence proofs for every accepted RTL fix

Three cases, one per fix. Each directory is self-contained and reproducible
from a clean checkout.

| Case | Fix | Verdict |
|---|---|---|
| `case1_spi` | carry-select decrement of `clkcnt` | PASS, unbounded (EQY) |
| `case2_fir` | MAC pipeline split, +1 cycle latency | PASS, bounded depth 40 (SBY miter) |
| `case3_uart` | `uart_rx_valid` reads `next_bit` | PASS, 12/13 EQY + exhaustive miter |

## Tooling

    mkdir -p ~/tools && cd ~/tools
    curl -sL https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest \
      | grep -o 'https://[^"]*oss-cad-suite-linux-x64-[0-9]*\.tgz' \
      | head -1 | xargs curl -L -o oss-cad-suite.tgz
    tar -xzf oss-cad-suite.tgz
    source ~/tools/oss-cad-suite/environment

`source` is per-shell. If `eqy: command not found`, that is why.

## Running

**Case 1.** Needs `fifo4.v` from the vendor tree; `simple_spi` instantiates
it without defining it.

    cd case1_spi
    cp ../../rtl/vendor/spi/rtl/verilog/fifo4.v .
    eqy -f spi_restructure.eqy

**Case 2.**

    cd case2_fir
    eqy -f fir_pipeline.eqy          # expected: 16/18, see below
    bash make_miter.sh
    sby -f fir_miter.sby             # bmc PASS, prove UNKNOWN

Optional simulation cross-check, no formal tools needed:

    iverilog -g2012 -o tb.vvp tb_fir_diff.v && vvp tb.vvp

**Case 3.**

    cd case3_uart
    eqy -f uart_case3.eqy            # expected: 12/13, see below
    sby -f valid_miter.sby           # PASS at depth 1

---

# Decision rule: EQY or miter

Drafted from what the three cases actually did. Praneeth to confirm or
correct — he ran them.

**1. Does the fix change the number or position of registers?**

If yes — pipeline insertion, retiming, anything with
`added_latency_cycles != 0` — **skip EQY entirely and build a miter.**

EQY proves equivalence by matching registers between gold and gate by name
and then proving the combinational logic between matched registers
equivalent. A fix that moves registers leaves them unmatched, so the proof
has nothing to stand on. This is not a tuning problem and no `depth` value
fixes it. Case 2 failed 2/18 partitions for exactly this reason, and those
two were the only partitions the fix touched.

Corollary: **EQY cannot verify Tier 2 fixes as a class.** Pipelining *is*
moving registers.

**2. Otherwise, run EQY first.** It is fast — Case 1 took two seconds — and
when every register matches one-to-one the per-partition results compose
into full sequential equivalence: all inputs, all reachable states,
unbounded. That is a stronger result than any miter gives you.

**3. If EQY returns FAIL, do not treat it as a bug.** Two distinct failures
look similar in the log and mean very different things:

- *Matching failure* ("Failed to prove equivalence of partition X") — EQY
  could not set up the comparison. No counterexample was produced because
  none was searched for. Case 2.
- *Spurious counterexample* ("partitions not equivalent", with a trace) —
  EQY did search, and found a state where the two differ. **Check the trace
  for reachability before believing it.** Case 3's counterexample had
  `fsm_state=FSM_STOP`, `next_bit=1`, `n_fsm_state=FSM_START`, which the
  FSM's own case statement makes impossible. EQY had cut the cone at
  `n_fsm_state` and passed it in as a free input, losing the dependency.

Either way the response is the same: build a miter that preserves whatever
EQY discarded, and believe only that result.

**4. Miter construction, two traps.**

- *Reset.* `assume($initstate -> rst)` requests reset but no clock edge has
  applied it at step 0, so registers still hold arbitrary solver-chosen
  values. Asserting at step 0 gives a false failure. Gate the assertion on
  a `past_init` flag. Cost us a debugging cycle on Case 2.
- *Hierarchical references.* Yosys cannot reference into a submodule's
  array registers. With a genvar index it errors on `AST_AUTOWIRE`; with
  constant indices it silently creates new undriven wires and the assertion
  compares undefined values — a false failure that looks real. If an
  invariant needs cross-module visibility, restate it at miter level or
  flatten both designs.

**5. Bounded is a real result.** `prove` failing while `bmc` passes is not a
gap to apologise for. BMC PASS at depth N means the designs agree for
*every* input sequence up to N cycles, not a sample of them. State the
bound and why it suffices: Case 2 used depth 40 against a design whose
pipeline flushes in ~10 cycles and which has no counter, FSM, or
accumulator that could drift — 40 covers every distinct phase four times
over.

Where the module is purely combinational, depth 1 is *exhaustive*. Case 3's
miter enumerated all 64 input combinations, including all 32 unreachable
state encodings.

---

# Known gaps

**Gold wrappers are hand-written.** `fir_gold_delayed.v` was authored by
hand to match `added_latency_cycles = 1`. In a loop that claims to be
automatic this is a manual step performed by whoever runs the check; it
should be generated from the fix record.

**Note on the wrapper's structure.** It inlines the original FIR body rather
than instantiating it. An earlier version used a submodule `u_core`, which
after flattening renames every shared register (`u_core.Q[0]` vs `Q[0]`) and
defeats EQY's matching entirely — not just for the asymmetric registers.
Keep gold wrappers flat.

**Unbounded proof for Case 2 remains open.** It needs the invariant
`d1 == psum_lo + psum_hi`, which Yosys cannot express across module
boundaries. Route if anyone wants it: flatten both designs into one module
so the references resolve. Polish, not a gap in the result.
