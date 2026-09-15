# Constraint Optimization through RTL Enhancement Using Generative AI

Nebula@BITS Goa, Digital track, sponsored by Astera Labs.

---

## 1. The problem, and what is actually new here

Timing closure at the RTL level is a loop a human runs by hand. You read a
static timing analysis report, find the path that misses its clock period,
work out which lines of RTL produced the logic on that path, rewrite them,
re-synthesise, and check whether you made things better or worse. The
rewriting step is pattern work — split a long arithmetic chain, move a
register, restructure a wide comparison — and it is the obvious candidate for
a language model.

The obvious candidate is also the obvious trap. A model that edits RTL can
silently change what the circuit computes, and a timing report will happily
tell you the broken version is faster. So the interesting question is not
*can a model propose a fix* — it can — but *what has to sit around the model
before its output can be accepted*.

This project builds that surrounding structure and measures it. The
contribution is a closed loop:

> violation → propose → validate → prove equivalent → re-synthesise →
> re-measure → accept or reject

and, more specifically, three gates in that loop that we did not design in
advance. Each one was forced by a measurement that contradicted the original
plan. They are the result.

The design under test is a 63,080-cell SoC with five asynchronous clock
domains. It is the benchmark, not the contribution. The model never receives
full-SoC context — it receives one violating path, its delay breakdown, and
the RTL spans that path passes through. That is the basis for claiming the
loop generalises beyond this design: nothing in the prompt is specific to it.

---

## 2. The loop, and the three gates

### What we specified

```
propose → EQY → retry on counterexample → done
```

Equivalence checking as the gate; a failed proof feeds the counterexample
back so the model can try again.

### What measurement forced

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

**Gate A — re-synthesise and re-run STA after verification, not before.**

The SPI proposal restructured a 12-bit decrementer into carry-select form.
EQY proved it equivalent, unbounded, in three seconds. It was also slower:
`spi_clk` went from −0.03 ns to −0.08 ns. A second attempt reached −0.16 ns.

A formal pass says the circuit still computes the right thing. It says
nothing about whether it computes it faster. Without this gate, a proved-
correct regression is indistinguishable from a proved-correct improvement.

**Gate B — never retry on an equivalence-checker counterexample. Build a
miter.**

EQY reported the UART fix non-equivalent and produced a counterexample:
`fsm_state = FSM_STOP`, `next_bit = 1`, `n_fsm_state = FSM_START`. That state
cannot occur. The case statement forces `n_fsm_state = FSM_IDLE` whenever
`fsm_state = FSM_STOP` and `next_bit` is high. The counterexample is an
artefact of how EQY partitions the design, explained in section 5.

Had the loop done what it was specified to do, it would have handed that
counterexample to the model and asked it to fix a fix that was already
correct. The model would have complied. Section 5 explains why a miter is the
right escalation and why the miter *is* the reachability check.

**Gate C — route by tier, and skip equivalence checking for tier 2.**

Fixes are classified before verification:

| tier | transform | latency | verification |
|---|---|---|---|
| 1 | restructure, retime | unchanged | EQY, structural partition matching |
| 2 | pipeline insertion | +N fixed cycles | miter against a delayed golden model |
| 3 | data-dependent latency | variable | out of scope — needs a scoreboard, not a miter |

A tier 2 fix adds registers. EQY matches partitions by register name, so the
new registers have no counterpart and cannot be compared. It will always
return FAIL, and always without a counterexample. Running it wastes time and
produces a failure that carries no information. Route tier 2 straight to the
miter.

### The accept criterion is design-wide, not path-local

The criterion is the **design-wide violated-path count**, not the slack on the
clock that was being fixed. Proposal 4 is why. It closed its own domain —
`fir_clk` from −0.03 ns to +0.07 ns — and broke another, taking `i2c_clk` from
0 to 3 violated paths. Design-wide, 3 → 4. A path-local criterion accepts it.

### One thing that is implemented but untested

**The retry path has never fired.** Across four proposals, none was ever
genuinely broken — every counterexample that appeared was spurious. The retry
branch is written and reachable, but nothing in this report is evidence that
it works.

---

## 3. The benchmark

Briefly, because it is the vehicle and not the point.

Five independently clocked domains — PicoRV32 CPU, UART, I2C, SPI, and an
8-tap 16-bit signed FIR filter — on an APB bus, with every crossing handled by
a real asynchronous FIFO rather than constrained away. Each master has at
least one generated clock (divide ratios 2, 4, 8, 16, 32). Crossings are
declared with `set_clock_groups -asynchronous`, which is what makes the
remaining violations real intra-domain paths rather than CDC noise.

63,080 cells against Nangate45, past the ~50K target. The synthesis flow is
deliberately explicit — `proc; flatten; opt; memory; techmap; dfflibmap; abc`
— rather than Yosys's `synth` macro, which matters in section 6.

The two vendor cores that speak Wishbone (I2C, SPI) reach APB through shims;
UART and FIR are bare `clk`/`rst` modules behind register-mapped wrappers.
The assembled SoC simulates: 4 PASS, all four peripherals reached.

---

## 4. Results

### Timing

One SDC, one synthesis per column, setup and hold measured together.

| clock | period | baseline (`firbase_v2`) | final (`FINAL`) |
|---|---|---|---|
| `fir_clk` | 1.46 ns | −0.37 ns, 20 violated | **−0.03 ns, 2 violated** |
| `i2c_clk` | 0.90 ns | −0.10 ns, 10 violated | **+0.02 ns, 0 violated** |
| `spi_clk` | 0.62 ns | −0.06 ns, 1 violated | −0.05 ns, 1 violated |
| `uart_clk` | 0.96 ns | +0.02 ns, 0 violated | +0.02 ns, 0 violated |
| **design-wide** | | **31 violated** | **3 violated** |
| hold | | 0 | **0** |

`uart_clk` is unchanged across this pair because the UART fix was already
applied when the FIR baseline was taken. Its own comparison is a different
pair, `base2` → `uartfix`: **−0.02 ns → +0.02 ns, closed outright**. Two
accepted fixes, two before/after pairs. Reading one table as though it covers
both understates the work.

The final netlist was rebuilt independently on a later date and reproduces 3
violated paths (`soc_violations_FINAL_v2.json`).

### Frequency

`f_max = 1 / (period − slack)`:

| clock | baseline | final | change |
|---|---|---|---|
| `fir_clk` | 546 MHz | **671 MHz** | +22.8% |
| `i2c_clk` | 1000 MHz | **1136 MHz** | +13.6% |
| `spi_clk` | 1471 MHz | 1493 MHz | +1.5% |
| `uart_clk` (`base2`→`uartfix`) | 1020 MHz | 1064 MHz | +4.3% |

These are per-domain. A single design-wide f_max would be set by the slowest
domain including `cpu_clk`, and section 6 explains why the `cpu_clk` numbers
from this flow are not meaningful.

### Area and power

### Design-wide

| metric | FIRBASE | FINAL | delta |
|---|---|---|---|
| cells | 63,335 | 63,080 | −255 (−0.4%) |
| sequential power | 78.76 mW | 79.56 mW | **+1.0%** |
| combinational power | 56.49 mW | 21.93 mW | **−61.2%** |
| clock-network power | 0.0053 mW | 0.0053 mW | unchanged (see below) |
| leakage | 2.483 mW | 2.470 mW | −0.5% |
| **total** | **135.24 mW** | **101.48 mW** | **−25.0%** |

Sequential power rises, which is the correct direction: the accepted FIR fix
adds two 41-bit registers, so there are more flops to clock and toggle. Leakage
falls 0.5% against a 0.4% cell reduction, which is what leakage should do. The
fix has a cost and it is measured, not hidden.

### The FIR module in isolation

The design-wide combinational figure needs an explanation, because a 61% drop
out of a 0.4% cell reduction is not something a single RTL edit can plausibly
do on its own. To find out where it comes from, `fir_wrapper` was synthesised
and measured alone, before and after the fix, under `constraints_fir.sdc` —
which defines no generated clocks, so the whole class of constraint error that
can affect a full-SoC run cannot occur.

| metric | FIRBASE | FINAL | delta |
|---|---|---|---|
| sequential power | 4.303 mW | 4.556 mW | +5.9% |
| combinational power | 17.998 mW | 6.880 mW | −61.8% |
| leakage | 0.1175 mW | 0.1192 mW | +1.5% |
| **total** | **22.30 mW** | **11.44 mW** | **−48.7%** |

Every sign matches the design-wide result, and the mechanism is slew. Internal
power in a Liberty cell is a function of input transition time, and it grows
steeply with it. An unpipelined 8-term MAC chain forces long paths with
degraded edges; splitting it gives `abc` a shorter required time, so it maps
faster cells that transition more sharply and cost less energy per toggle.
**Closing the timing violation and reducing internal power are the same
physical change**, not two separate benefits.

The isolation also bounds the claim. The module accounts for 11.12 mW of the
34.56 mW design-wide combinational reduction — roughly a third. The remaining
two thirds are not attributable to the fix. They are the same design-wide
remapping documented in section 6: `flatten` followed by `abc` re-optimises the
entire design whenever any part of it changes, and the cell histogram confirms
it, with NAND2 down 548 and INV up 202 in modules nobody edited. The fix causes
a third of the improvement directly and triggers the rest indirectly.

### What these numbers are not

Activity is OpenSTA's default assumption, not a simulation trace. Both columns
were measured under identical assumptions, so the comparison is sound; the
absolute figures are not workload power.

Clock-network power is effectively absent — 0.0053 mW across a 63,080-cell
design. There is no clock tree, because the flow stops at logical synthesis.
Real clock distribution is frequently a fifth or more of total power, so every
total above understates. It is the same boundary that produces the fanout
artefact in section 6: what is missing is the physical implementation stage,
not a tool capability.

Reaching these numbers required discarding an earlier set. See section 8.

### The four proposals

Four proposals produced four different correct outcomes. That variety is the
evidence that the gates do something.

| # | violation | fix type | tier | verification | verdict |
|---|---|---|---|---|---|
| 1 | `fir_clk` −0.37 | `pipeline` +1 cycle | 2 | EQY inconclusive → SBY BMC, PASS at depth 40 | **ACCEPTED** |
| 2 | `uart_clk` −0.02 | `restructure` | 1 | EQY 12/13, then exhaustive miter PASS | **ACCEPTED** |
| 3 | `spi_clk` −0.03 | `restructure` ×2 | 1 | EQY PASS, unbounded | **REJECTED** — regressed its own domain, −0.03 → −0.08 |
| 4 | `fir_clk` −0.03 residual | `restructure` | 1 | bit-exact by construction | **REJECTED** — closed `fir_clk` but took `i2c_clk` 0 → 3 violated |

Three distinct reasons to reject: own-domain regression, other-domain
regression, and — in case 3's verification — a counterexample that could not
occur.

### What the accepted fixes actually are

**UART**, in `rtl/vendor/uart/rtl/uart_rx.v`:

```verilog
- assign uart_rx_valid = fsm_state == FSM_STOP && n_fsm_state == FSM_IDLE;
+ assign uart_rx_valid = fsm_state == FSM_STOP && next_bit;
```

plus relocating the `next_bit` and `payload_done` wire declarations above the
line that now references them. It adds no logic — `next_bit` already existed
and already carried the condition. The original expression forced the valid
signal to wait on the next-state decode; the replacement reads the same
information one level of logic earlier. The path went from 14 stages to 13,
and from −0.02 ns to +0.02 ns.

**FIR**, in `rtl/peripherals/fir_filter.v`: the 8-term multiply-accumulate sum
was a single serial chain. It is now two registered 4-term half-sums,
`psum_lo` and `psum_hi`, added in the following cycle. One extra cycle of
latency, 33 lines to 45. This is the fix that moved `fir_clk` from −0.37 ns to
−0.03 ns.

**The rejected fourth proposal** rebalanced each half from `((a+b)+c)+d` to
`(a+b)+(c+d)` — a shallower adder tree, and provably bit-exact, because
addition is associative modulo 2^41 and the 41-bit accumulator cannot overflow
(the worst half-sum needs 23 bits). 200,000 randomised trials, zero
mismatches. It was correct, it closed its target, and it was rejected anyway,
because Gate A measured the whole design and found `i2c_clk` had broken.

---

## 5. What each verification failure taught

Three cases, three verdicts, all pass. The interesting content is in *how*
two of them failed first.

| case | fix | result |
|---|---|---|
| SPI | `restructure` | EQY: all partitions proved, `DONE (PASS, rc=0)`, 3 s, unbounded |
| FIR | `pipeline` | EQY 16/18, `DONE (FAIL, rc=2)` — `imm` spurious CEX, `sample_out` UNKNOWN. SBY `bmc` PASS at depth 40; SBY `prove` induction fails → `UNKNOWN, rc=4` |
| UART | `restructure` | EQY 12/13; `uart_rx_valid` FAIL `rc=2` with a spurious counterexample. Miter PASS at depth 1, exhaustive |

### One mechanism: unmatched signals become free inputs

EQY does not compare two designs whole. It establishes a correspondence by
matching registers by name, cuts the design into partitions at those register
boundaries, and proves each partition's logic cone separately. Any signal that
crosses a cut is fed into the partition as a **free input** — the solver may
assign it any value, because within that partition there is no information
about what the surrounding circuit can actually produce.

For *proving* equivalence this is sound and conservative. If two partitions
agree for every possible value of the cut signals, they certainly agree for the
reachable ones. For *disproving* it is unsound: a counterexample may assign the
cut signals a combination the real circuit can never reach.

That single property produces every EQY failure in this project. It surfaces in
two different ways, and both were initially mistaken for something else.

**Case 3 — a spurious counterexample on a correct fix.** EQY proved 12 of 13
partitions and failed `uart_rx.uart_rx_valid` with `rc=2`, reporting
`fsm_state = FSM_STOP` together with `n_fsm_state = FSM_START`. That state
cannot occur: the next-state case statement forces `n_fsm_state = FSM_IDLE`
whenever `fsm_state = FSM_STOP` and `next_bit` is high. The VCD shows why the
solver was allowed to propose it — the signal appears as `__pi_n_fsm_state`,
where `__pi_` marks a partition input. The dependency between `fsm_state` and
`n_fsm_state` was cut away, so the solver treated them as independent. SAT
model: `in_gold=0, in_gate=1, okay=0`.

**Case 2 — the same mechanism, reached by a different route.** A pipeline fix
adds registers that have no counterpart in the original. Here `psum_lo` and
`psum_hi` appear in `gate_recoded.ids` and are absent from `matched.ids`
entirely; `partition.list` contains 18 partitions and none for either. Those
registers were not matched, so the signals around them became free inputs too.

EQY then failed 2 of those 18 partitions, and — this is the part worth being
precise about — it failed them for **two different reasons**:

- `fir_filter.imm` returned `FAIL` with a SAT model dumped to `trace.vcd`. The
  model sets `gold.__pi_sample_out = ffff`. Same `__pi_` mechanism as case 3: a
  spurious counterexample.
- `fir_filter.sample_out` returned `UNKNOWN` — "Reached maximum number of time
  steps, proof failed". A bounded search that ran out of depth.

Neither is a real defect, and neither is silence. It would be wrong to say the
tool declined to look; it looked, and what it returned could not be trusted.
**Every tier 2 fix reaches this by construction** — adding registers is what
pipelining is — which is the mechanism behind Gate C.

### The rule

> **An EQY PASS is conclusive. An EQY FAIL is not.**
> A FAIL may be a spurious counterexample, a depth-limited unknown, or a real
> defect, and the tool's output does not distinguish them. Only a **miter** —
> both whole designs run from reset, nothing cut, every signal driven by real
> logic — produces a counterexample trustworthy enough to send back to the
> model.

This is why Gate B says *escalate*, never *retry*. A miter is not a second
opinion. It is the reachability check the partitioned tool structurally cannot
perform.

Both escalations succeeded, and both were stronger than the proofs that failed.

**Case 3's miter is exhaustive.** `valid_miter.v` recomputes `n_fsm_state` from
the same case statement, so the dependency EQY cut is restored, then asserts
the two expressions agree. It is purely combinational — no state, six free
input bits — so bounded model checking at depth 1 covers all 64 combinations of
`{fsm_state[2:0], next_bit, rxd_reg, payload_done}`, including all four unused
`fsm_state` encodings. Zero mismatches.

**Case 2's miter is bounded, and the report should say so.** The original and
modified modules run side by side with the original's output delayed by the
added cycle. BMC passes at depth 40. The unbounded proof **was attempted**:
SBY's `prove` mode ran temporal induction, the base case passed, and the
induction step failed, returning `UNKNOWN, rc=4`. So the FIR result is
equivalence for all input sequences up to 40 cycles, plus 20,000 randomised
simulation cycles — not equivalence for all time. Writing "we used BMC" without
saying induction was tried and did not close would overstate it.

### What formal verification cannot cover, and what does

All three proofs are module-scoped. None of them says the fix works inside the
SoC. The FIR fix adds a cycle of latency, and `fir_wrapper`'s handshake with
the asynchronous FIFO could have broken on exactly that. Simulation of the
assembled design is what covers it: 4 PASS, all four peripherals reached.
Formal and simulation are checking different things here, and the loop needs
both.

---

## 6. What does not work, and why

Negative results, all measured. Several are more informative than the
successes because they identify where the boundary of the method is.

**The CPU contributed nothing, for a reason that is not about the CPU.** All
200 worst `cpu_clk` paths run through a single `NOR2_X1` driving 723 loads,
with a stage delay around 700 ns. None survives the fanout filter
(`MAX_STAGE_NS = 10.0`). This is not a design defect — Yosys performs no
buffer insertion, so a high-fanout net is modelled as one enormous delay that
physical synthesis would fix with a buffer tree. There is no RTL change that
addresses it. It is a flow artefact, and it is why no `cpu_clk` number in this
report should be treated as a real frequency.

**No retiming candidate exists in this design.** The `retime` strategy is
implemented and validated, but a search across all paths for register
imbalance found exactly two candidates, both in `clk_divider.v`, with +46.30 ns
and +3.42 ns of slack. Nothing that needs fixing is retimeable here. The
strategy has never been exercised against a real violation, and we say so.

**SPI is not fixable at the RTL level.** `abc` already maps the 12-bit ripple
decrementer optimally by sharing borrow terms across bits. Any RTL
carry-lookahead formulation requires an "is the low half all zeros" test,
which synthesises to a wide `OR4_X1` reduction tree at 0.11–0.14 ns per level
against roughly 0.05 ns for the 2-input gates already there. The restructure is
mathematically sound and physically slower. Diagnosed twice, independently;
the surviving `spi_clk` violation is the same path through the same gates.

**Source attribution survives on flip-flops only, and this is a hard limit.**
Across all 140 analysed paths, **zero** combinational gates carry a `src`
attribute. `dfflibmap` maps flops one-to-one so their tags survive; `abc`
re-synthesises combinational logic from scratch and the provenance is gone.
The consequence is structural: **no scope selector can ever point directly at
the logic causing a setup violation.** It can only point at the flops at each
end. Everything in section 7 about scope escalation exists because of this.

**The loop is an iteration, and it does not converge monotonically.** The FIR
was fixed twice — the pipeline split addressed the 8-term sum, and then the
two 4-term sums that split created became the next critical path. Proposal 4
attacked those and raised the design-wide count from 3 to 4. Order matters.
31 → 3 is one trajectory through the space, not a canonical optimum.

**Local edits have non-local effects, in both directions.** Four observations:
the SPI fix hurt `fir_clk`; the FIR pipeline *closed 10 `i2c_clk` violations*
in RTL nobody touched; the adder-tree rebalance *broke* `i2c_clk`.

The qualifier matters: this is a property of **flattened** synthesis. The flow
runs `flatten` before `abc`, so module boundaries are gone by the time
combinational optimisation happens and `abc`'s heuristics are free to reshuffle
logic anywhere in the design whenever any part of it changes. Under
hierarchical synthesis `abc` would optimise I2C in isolation and it would come
out bit-identical regardless of what happened to the FIR — the side effects
would largely disappear.

That does not weaken the case for Gate A, because flattening is what real flows
do and is the reason cross-module violating paths like UART 112 get optimised
as paths at all. It does mean the claim should be stated as measured: under
flattened synthesis, a per-fix delta is a whole-design delta whether or not you
choose to measure it that way. That is the second, independent argument for
whole-design re-measurement.

**The output is not a function of the violation alone, and repetition shows
it is not a function of the model either.** A single Sonnet run and a single
Opus run on violation 112 returned `no_fix` and a validated `retime`
respectively, which looks like a model difference. Repeating the experiment
does not support that reading. At the narrow default scope
(`uart_rx.v:170-180`, eleven lines that do not contain the fix) both models
returned `no_fix` five times out of five — a correct refusal, since no fix
exists in that window. At whole-file scope Sonnet returned `no_fix` three
times and a `restructure` once, and that `restructure` failed the structural
validator.

So **run-to-run variance is present within a single model**, and the
one-run-per-model comparison that suggested a model difference does not survive
repetition. Two things follow. Scope determines whether a fix is attempted at
all, which is the measured basis for section 7. And a single sample per
violation is not evidence of what a model can or cannot do — a loop that fires
once per violation will miss fixes the model is capable of finding, and will
occasionally act on ones it should not. This experiment is ongoing;
`modelcmp.py` reproduces it and the per-run records are in
`fixes_modelcmp/runs/`.

---

## 7. Scope escalation

The initial implementation picked the file to edit from `attributed[0]` — the
launch flop. On a path confined to one module that is right. On a path that
crosses modules it is often wrong.

UART violation 112 spans three files:

```
uart_rx.v        0.52 ns   launch flop, attributed
uart_wrapper.v   0.08 ns   no flop on the path — invisible to attribution
wptr_full.v      0.34 ns   capture flop, attributed
```

0.94 ns total, and 12 of the 14 cells on the path carry no attribution at all.
Given only `uart_rx.v`, the model partitioned the delay correctly, declined to
propose a fix because 55% of it lay outside its scope, and named
`uart_rx.v:108-123` as where the fix belonged. A manual re-run at that scope
produced the fix that was ultimately accepted.

That refusal was the correct behaviour, and it was more useful than a fix would
have been. Three pieces of machinery came out of it:

- `patch_schema.py` adds an `out_of_scope_fix` field, making the refusal
  machine-readable instead of prose the orchestrator has to parse.
- `escalate.py` walks the file ladder automatically, **bounded to files that
  lie on the violating path** — the bound is what stops scope escalation from
  becoming "give the model the whole design", which would void the
  generalisation claim in section 1. Terminal states are `SOLVED`, `REFUSED`
  (the model names nowhere else to look — a real refusal), and `EXHAUSTED`.
- `run_loop.py` ties the stages together with the decision logic in `decide()`.

---

## 8. Limitations

Stated plainly, because several of them bound what the numbers mean.

**The first power measurement was wrong, and finding out how is part of the
result.** Two annotation strategies were tried and both produced non-physical
output: `set_power_activity -input -activity 0.1` is rejected on clock ports,
so flip-flops receive no toggle rate and sequential internal power returns as
4×10^15 W, reported by the tool as 100.0% of total; `-global -activity 0.1
-duty 0.5` returns NaN and inf. Those runs are retained in `reports/` as
`power_*_v2.rpt` and the `-input` pair, as evidence, not as results.

Removing the annotation entirely fixes it. With no `set_power_activity` at all,
OpenSTA produces a complete, finite, internally consistent report. The
annotation was poisoning the calculation; the tool was never the problem. The
switching figures originally derived from the `-input` run were wrong by a
factor of seven and have been discarded.

A second fault was found in the same investigation and is worth recording
because it is generic. The power runs read an archived baseline netlist against
the *current* SDC. Yosys renumbers every cell on every synthesis, so the five
`create_generated_clock` statements — pinned to names like `_124918_/Q` —
landed on RAM flip-flops in the older netlist rather than on the clock
dividers. `fir_div32` was declared on a flop outside the `fir_clk` domain
entirely. OpenSTA built a fictional clock network and reported power against
it, with no error. The symptom was a 97% difference in clock-group power
between two designs whose clock networks are identical; regenerating the SDC
against the correct netlist brought the two to within four significant figures.
The timing measurements were unaffected, because the documented flow
regenerates the SDC before every STA run and that step was followed — it was
skipped only for the later power runs.

The general lesson is the one already stated in section 5 about
counterexamples, in a different domain: **a tool reporting a number is not the
same as a tool reporting a meaningful number.** Both faults here were silent.
Neither produced an error. Both were caught by asking whether a delta was
physically possible — a 97% change in an unchanged clock network, and a 61%
combinational power drop out of a 0.4% area change — and then checking.

**Synthesis is logical, not physical.** No placement, no clock tree, no buffer
insertion, no wire-load model beyond the library default. Every delay here is
a cell-delay estimate. Relative comparisons between two netlists through the
same flow are sound; absolute frequencies are not.

**One proof is bounded.** The FIR equivalence holds to depth 40, not for all
time. Section 5 gives the detail.

**The retry path is untested.** It has never fired, because no proposal was
ever genuinely broken.

**FSM re-encoding is deliberately excluded, not overlooked.** It is on the
problem statement, and there is real headroom: the flow never runs Yosys's
`fsm` passes, and `uart_rx` uses 3-bit binary encoding for four states, so
`fsm_state == FSM_STOP` would collapse to a single bit read under one-hot. It
is excluded because re-encoding changes the state register's width and values,
leaving EQY no register correspondence to work from — the same unmatched-
register mechanism that case 2 hit, but without a miter formulation that
recovers it, since there is no fixed latency offset to compare against. Taking it on would mean
weakening the verification gate, which is the part of this work we are least
willing to weaken.

**Four proposals is a small sample**, and the model-behaviour claims rest on
fewer runs still. Section 6 reports what repetition showed so far; that
experiment is incomplete at the time of writing.

**Fix records do not capture their own invocation.** `meta` stores the model,
cost, turn count and session id, but not the command line. Nothing in
`fixes_modelcmp/uart_OPUS.json` records that it was run with `--whole-file`,
which made its conditions ambiguous until they were reconstructed from the
recorded `edit_scope`. A record that cannot say how it was produced cannot be
reproduced from itself.

---

## 9. Contributions

1. **A closed loop from timing violation to verified, re-measured RTL fix**,
   implemented end to end and runnable as a single command.

2. **Three gates that the specified loop did not have, each forced by a
   measurement.** Re-STA after verification, because a proved-correct fix was
   slower. Escalate to a miter rather than retry on a counterexample, because
   a counterexample was unreachable. Route by tier, because equivalence
   checking cannot evaluate a pipeline fix at all.

3. **A characterisation of why an equivalence checker's failures cannot be
   trusted**, traced to a single mechanism — partition cuts turn unmatched
   signals into free inputs, which is sound for proving and unsound for
   disproving — with three surface forms observed (spurious counterexample,
   depth-limited unknown, unmatched pipeline registers) and every claim backed
   by the tool's own logs. The rule that follows: EQY PASS is conclusive, EQY
   FAIL is not.

4. **Measured non-local effects of local RTL edits**, in both directions,
   which is the independent argument for whole-design re-measurement.

5. **Negative results with mechanisms**: why the CPU's paths are unfixable at
   RTL, why SPI's decrementer is already optimal, why source attribution
   cannot survive `abc`, and why no retiming candidate exists here.

6. **A five-domain asynchronous benchmark SoC** with real CDC, as the vehicle
   for all of the above.

The measured outcome on that benchmark: design-wide violated paths 31 → 3,
`fir_clk` 546 → 671 MHz, `i2c_clk` closed outright, zero hold violations
introduced, every accepted fix formally verified, and two correct fixes
rejected for reasons a path-local criterion would have missed.

---

## Appendices

- `formal/README.md` — per-case reproduction instructions and expected output
- `fixes/` — every proposal, accepted and rejected, as produced
- `reports/` — OpenSTA setup, hold and power reports
- `formal/logs/` — verification logs and the spurious-counterexample VCD
