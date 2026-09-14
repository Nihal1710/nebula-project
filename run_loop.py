#!/usr/bin/env python3
"""
run_loop.py - the closed loop, end to end.

    synth -> STA -> violation -> propose -> validate -> EQY -> re-STA -> decide

Two modes:

  --replay   (default) walks recorded artefacts from fixes/*.json and the
             saved SoC measurements. Runs in about a second, needs no Docker,
             no API call and no OSS CAD Suite. This is the demo.

  --live     runs the real tools for the propose stage. Everything before it
             (synth/STA) and the EQY stage still come from artefacts, because
             those need Docker and the CAD suite respectively.

The point of this file is the DECISION LOGIC in decide(). The original design
was propose -> EQY -> retry-on-failure. Two measurements changed it:

  * SPI  - EQY PASSED and the fix made timing worse. So a formal pass is not
           an acceptance. A re-STA gate has to sit after verification.
  * UART - EQY returned "not equivalent" with a concrete counterexample that
           was UNREACHABLE. Feeding that back to the model would have made it
           rewrite a correct fix. Counterexamples need a reachability check
           before they are allowed to drive a retry.

Usage:
    python3 run_loop.py --list
    python3 run_loop.py --case uart_rx_uart_clk_ACCEPTED
    python3 run_loop.py --all
    python3 run_loop.py --case fir_filter_fir_clk_fix_ACCEPTED --live
"""

import argparse, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FIXES = ROOT / "fixes"

# ---------------------------------------------------------------------------
# Recorded outcomes. Track C verdicts come from Praneeth's EQY/SBY runs;
# timing deltas from the saved SoC measurements listed in `SOC`.
# ---------------------------------------------------------------------------
LEDGER = {
    "fir_filter_fir_clk_fix_ACCEPTED": dict(
        module="fir_filter", clock="fir_clk", tier=2,
        eqy="INCONCLUSIVE",
        eqy_note="16/18 partitions proved. fir_filter.imm and .sample_out "
                 "unmatched: gold's d1 has no gate counterpart and the gate's "
                 "psum_lo/psum_hi have no gold counterpart, so EQY left them "
                 "free and they trivially differ. No counterexample was "
                 "produced because none was searched for.",
        fallback="SBY miter, BMC PASS at depth 40 (+20k randomised cycles)",
        before=-0.37, after=-0.03, before_n=20, after_n=2,
        design_before=31, design_after=3,
        measured_from=("soc_violations_firbase_v2.json", "soc_violations_FINAL.json"),
        side_effect="i2c_clk -0.10 (10 violated) -> +0.02 (0 violated), "
                    "i2c RTL untouched"),
    "uart_rx_uart_clk_ACCEPTED": dict(
        module="uart_rx", clock="uart_clk", tier=1,
        eqy="PASS_AFTER_REACHABILITY_CHECK",
        eqy_note="12/13 partitions proved. uart_rx.uart_rx_valid returned "
                 "'partitions not equivalent' with a concrete counterexample: "
                 "fsm_state=FSM_STOP, next_bit=1, n_fsm_state=FSM_START. That "
                 "state is impossible - the case statement forces "
                 "n_fsm_state=FSM_IDLE there. EQY had cut the cone at "
                 "n_fsm_state and passed it in free.",
        fallback="combinational miter recomputing n_fsm_state: PASS at depth 1, "
                 "exhaustive over all 64 input combinations",
        before=-0.02, after=+0.02, before_n=1, after_n=0,
        design_before=5, design_after=3,
        measured_from=("soc_violations_base2.json", "soc_violations_FINAL.json"),
        side_effect=None),
    "simple_spi_restructure_v2_REGRESSED": dict(
        module="simple_spi", clock="spi_clk", tier=1,
        eqy="PASS",
        eqy_note="All partitions proved including simple_spi.clkcnt, which "
                 "contains the changed line. Unbounded sequential equivalence. "
                 "Independently exhaustive over all 4096 counter values.",
        fallback=None,
        before=-0.03, after=-0.08, before_n=4, after_n=46,
        design_before=5, design_after=46,
        measured_from=("soc_violations_base2.json", "soc_violations_spifix2.json"),
        side_effect="fir_clk -0.04 -> -0.08, fir_filter.v untouched"),
    "fir_adder_tree_REJECTED": dict(
        module="fir_filter", clock="fir_clk", tier=1,
        eqy="PASS",
        eqy_note="Not run through EQY. Equivalence is exact by construction: "
                 "the change is parenthesisation only, (a+b)+(c+d) instead of "
                 "((a+b)+c)+d. Addition is associative modulo the register "
                 "width, both groupings are evaluated at the same "
                 "context-determined width (41 bits, set by the LHS), and the "
                 "41-bit target cannot overflow - the worst 4-term half-sum "
                 "needs 23 bits. Checked over 200,000 random 41-bit trials, "
                 "0 mismatches.",
        fallback=None,
        before=-0.03, after=+0.07, before_n=2, after_n=0,
        design_before=3, design_after=4,
        measured_from=("soc_violations_FINAL.json",
                       "soc_violations_FIRTREE_REJECTED.json"),
        side_effect="i2c_clk +0.02 (0 violated) -> -0.06 (3 violated), i2c RTL "
                    "untouched. Design-wide violated paths 3 -> 4, which is "
                    "why this is rejected despite closing its own domain."),
    "simple_spi_restructure_REGRESSED": dict(
        module="simple_spi", clock="spi_clk", tier=1,
        eqy="NOT_RUN", eqy_note="superseded by v2", fallback=None,
        before=-0.03, after=-0.16, before_n=4, after_n=58,
        measured_from=("soc_violations_base2.json", "soc_violations_spifix.json"),
        side_effect=None),
}

SOC = {
    "soc_violations_base2.json":      "SoC baseline, pre-UART-fix",
    "soc_violations_firbase_v2.json": "SoC baseline, pre-FIR-fix (UART fix in)",
    "soc_violations_FINAL.json":      "SoC, both accepted fixes applied",
    "soc_violations_spifix.json":     "SoC, SPI restructure v1 applied",
    "soc_violations_spifix2.json":    "SoC, SPI restructure v2 applied",
}

BAR = "-" * 76


def hdr(n, name):
    print(f"\n[{n}] {name}\n{BAR}")


def soc_slack(fname, clock):
    """Worst slack + violated count for one clock group, from a saved run."""
    p = ROOT / fname
    if not p.exists():
        return None, None
    d = json.loads(p.read_text())
    s = [v["slack_ns"] for v in d if v.get("path_group") == clock]
    return (min(s), sum(1 for x in s if x < 0)) if s else (None, None)


# ---------------------------------------------------------------------------
# The decision logic. This is the part that is the contribution.
# ---------------------------------------------------------------------------
def decide(fix_type, validator_ok, eqy, timing_improved):
    """Return (verdict, reason, retry_payload).

    timing_improved is the DESIGN-WIDE verdict, not the target clock's.
    Proposal 4 is why: it closed fir_clk (-0.03 -> +0.07) and raised
    design-wide violated paths from 3 to 4 by breaking i2c_clk, whose RTL
    was untouched. A path-local criterion accepts it. L4-bis says slack
    deltas are whole-design deltas, so the design-wide criterion is the
    consistent one."""

    if fix_type == "no_fix":
        return "DECLINED", "model declined to propose a fix", None

    if not validator_ok:
        return ("REJECTED", "structural validator failed - never reaches EQY",
                "validator errors")

    if eqy == "FAIL_REACHABLE":
        return ("REJECTED", "counterexample survives reachability analysis - "
                "genuine functional difference", "counterexample trace")

    if eqy in ("INCONCLUSIVE", "PASS_AFTER_REACHABILITY_CHECK"):
        # EQY could not decide, or decided wrongly. Escalate to a miter rather
        # than retry: there is no evidence the fix is wrong.
        if timing_improved is False:
            return ("REJECTED", "verified by fallback, but whole-design re-STA "
                    "shows a net regression", None)
        return ("ACCEPTED", "verified via fallback path after EQY was "
                "inconclusive; re-STA confirms improvement", None)

    if eqy == "PASS":
        if timing_improved is False:
            return ("REJECTED", "formally equivalent, but whole-design re-STA "
                    "shows a net regression", None)
        return ("ACCEPTED",
                "formally equivalent and whole-design violated paths fell", None)

    return "PENDING", f"EQY state '{eqy}'", None


def run_case(tag, live=False):
    rec = FIXES / f"{tag}.json"
    if not rec.exists():
        sys.exit(f"no such fix record: {rec}")
    d = json.loads(rec.read_text())
    fix, val = d["fix"], d["validation"]
    led = LEDGER.get(tag)

    print(f"\n{'=' * 76}\n  {tag}\n{'=' * 76}")

    # -- 1 ----------------------------------------------------------------
    hdr(1, "SYNTHESIS + STA  (artefact)")
    src = d.get("source_file", "?")
    print(f"  netlist   : Yosys -> Nangate45, 63,080 cells, 5 clock domains")
    print(f"  violations: {src}")
    print(f"  selected  : index {d.get('violation_index')}")
    v = d.get("violation", {})
    if v.get("slack_ns") is not None:
        print(f"  path      : {v.get('path_group')}  slack={v['slack_ns']} ns  "
              f"{len(v.get('instances', []))} stages")
        att = {i["src_file"] for i in v.get("instances", []) if i.get("src_file")}
        una = sum(1 for i in v.get("instances", []) if not i.get("src_file"))
        print(f"  attributed: {len(att)} file(s), {una} cells unattributed")
        for a in sorted(att):
            print(f"              {a}")

    # -- 2 ----------------------------------------------------------------
    hdr(2, "PROPOSE  " + ("(live)" if live else "(artefact)"))
    sc = d.get("edit_scope", {})
    print(f"  scope     : {sc.get('src_file')}:{sc.get('start_line')}-"
          f"{sc.get('end_line')}  ({sc.get('scope')})")
    print(f"  model     : {d.get('meta', {}).get('model', '?')}")
    if live:
        cmd = ["python3", "propose_fix.py", src, "--index",
               str(d["violation_index"]), "--dry-run"]
        print(f"  $ {' '.join(cmd)}")
        subprocess.run(cmd, cwd=ROOT)
    print(f"  fix_type  : {fix['fix_type']}   "
          f"added_latency_cycles={fix['added_latency_cycles']}")
    if led:
        print(f"  tier      : {led['tier']}")

    # -- 3 ----------------------------------------------------------------
    hdr(3, "STRUCTURAL VALIDATOR  (pre-EQY filter, free)")
    print(f"  ok        : {val['ok']}")
    if val.get("errors"):
        for e in val["errors"]:
            print(f"  error     : {e}")
    if val.get("new_registered_signals"):
        print(f"  new regs  : {val['new_registered_signals']} "
              f"(delta {val.get('register_delta')})")
    if not val["ok"]:
        print("  -> stops here; no verification cost incurred")

    if fix["fix_type"] == "no_fix":
        hdr(4, "DECISION")
        print("  DECLINED - nothing to verify")
        print(f"  rationale : {fix['rationale'].strip().splitlines()[0][:70]}...")
        return

    # -- 4 ----------------------------------------------------------------
    hdr(4, "FORMAL EQUIVALENCE  (Track C)")
    if not led:
        print("  not run")
        return
    print(f"  EQY       : {led['eqy']}")
    for line in _wrap(led["eqy_note"], 70):
        print(f"              {line}")
    if led["fallback"]:
        print(f"  fallback  : {led['fallback']}")

    # -- 5 ----------------------------------------------------------------
    hdr(5, "REACHABILITY CHECK  (guards the retry path)")
    if led["eqy"] == "PASS_AFTER_REACHABILITY_CHECK":
        print("  EQY returned a definitive counterexample.")
        print("  Reachability analysis: state is UNREACHABLE.")
        print("  -> counterexample REJECTED as retry input.")
        print("  -> without this gate the loop would rewrite a correct fix.")
    elif led["eqy"] == "INCONCLUSIVE":
        print("  No counterexample produced - nothing to check.")
        print("  Structural matching failed on register layout, which is what")
        print("  every Tier 2 fix does by definition. Escalated to miter.")
    else:
        print("  No counterexample produced.")

    # -- 6 ----------------------------------------------------------------
    hdr(6, "RE-STA  (whole design, not module-local)")
    b, a = led["before"], led["after"]
    local_improved = a > b
    db, da = led.get("design_before"), led.get("design_after")
    improved = (da < db) if (db is not None and da is not None) else local_improved
    print(f"  {led['clock']:9} {b:+.2f} -> {a:+.2f} ns   "
          f"({'improved' if local_improved else 'REGRESSED'})   [target clock]")
    print(f"  violated  {led['before_n']:3} -> {led['after_n']:<3}   [target clock]")
    if db is not None:
        print(f"  DESIGN-WIDE violated paths  {db} -> {da}   "
              f"({'improved' if improved else 'WORSE'})  <- the accept criterion")
    print(f"  sources   {led['measured_from'][0]}")
    print(f"            {led['measured_from'][1]}")
    if led["side_effect"]:
        print(f"  note      {led['side_effect']}")

    # -- 7 ----------------------------------------------------------------
    hdr(7, "DECISION")
    verdict, reason, retry = decide(fix["fix_type"], val["ok"],
                                    led["eqy"], improved)
    print(f"  {verdict}")
    print(f"  reason    : {reason}")
    print(f"  retry     : {retry or 'no'}")


def _wrap(text, width):
    out, line = [], ""
    for w in text.split():
        if len(line) + len(w) + 1 > width:
            out.append(line); line = w
        else:
            line = f"{line} {w}".strip()
    if line:
        out.append(line)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--live", action="store_true")
    a = ap.parse_args()

    if a.list or not (a.case or a.all):
        print("\nFix records:\n")
        for f in sorted(FIXES.glob("*.json")):
            tag = f.stem
            d = json.loads(f.read_text())
            mark = "*" if tag in LEDGER else " "
            print(f" {mark} {tag:45} {d['fix']['fix_type']}")
        print("\n  * = has a recorded Track C verdict and re-STA measurement")
        print("\n  python3 run_loop.py --case <tag>\n  python3 run_loop.py --all\n")
        return

    if a.all:
        for tag in ("uart_rx_uart_clk_ACCEPTED",
                    "fir_filter_fir_clk_fix_ACCEPTED",
                    "simple_spi_restructure_v2_REGRESSED",
                    "fir_adder_tree_REJECTED",
                    "uart_rx_uart_clk_REFUSAL_baseline"):
            if (FIXES / f"{tag}.json").exists():
                run_case(tag, a.live)
        print(f"\n{'=' * 76}")
        print("  Four proposals, four outcomes: two accepted, one rejected for")
        print("  regressing its own domain, one rejected for breaking another")
        print("  domain while closing its own. Design-wide 31 -> 3 violated.")
        print(f"{'=' * 76}\n")
    else:
        run_case(a.case, a.live)


if __name__ == "__main__":
    main()
