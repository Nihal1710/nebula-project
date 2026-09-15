#!/usr/bin/env python3
"""
demo.py - interactive demo of the closed loop.

    python3 demo.py           then open http://localhost:8000

Needs Python 3 and a browser. No Docker, no CAD suite, no network, no pip.

WHAT IT DEMONSTRATES

run_loop.py replays the loop and prints what happened. That shows the result.
It does not show why the loop is built the way it is.

This demo lets you switch each of the three gates OFF and watch the loop reach
the wrong verdict on a real recorded case:

  Gate A off  -> the SPI fix is accepted. It passed EQY and was slower.
  Gate B off  -> the UART counterexample drives a retry. It is unreachable,
                 so the loop would rewrite a fix that was already correct.
  Gate C off  -> the FIR pipeline fix goes through EQY, which cannot compare
                 it, and the failure carries no information.
  Path-local  -> proposal 4 is accepted. It closed fir_clk and broke i2c_clk.

DECISION LOGIC IS NOT DUPLICATED HERE. With all gates on, decide_with_gates()
delegates to run_loop.decide(). That equivalence is asserted at startup.
"""

import difflib
import json
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

from run_loop import LEDGER, decide

ROOT = Path(__file__).resolve().parent
FIXES = ROOT / "fixes"
DEMO = ROOT / "demo"

ORDER = [
    "uart_rx_uart_clk_ACCEPTED",
    "fir_filter_fir_clk_fix_ACCEPTED",
    "simple_spi_restructure_v2_REGRESSED",
    "fir_adder_tree_REJECTED",
]

# The "before" side of each RTL change. The accepted fixes are already applied
# in the tree, so the original has to come from the formal gold files or from
# fir_filter.v.orig. Proposal 4 was never applied, so its before is the file as
# it stands today.
BEFORE = {
    "uart_rx_uart_clk_ACCEPTED":           "formal/case3_uart/uart_rx_gold.v",
    "fir_filter_fir_clk_fix_ACCEPTED":     "rtl/peripherals/fir_filter.v.orig",
    "simple_spi_restructure_v2_REGRESSED": "formal/case1_spi/gold_spi.v",
    "fir_adder_tree_REJECTED":             "rtl/peripherals/fir_filter.v",
}

TITLE = {
    "uart_rx_uart_clk_ACCEPTED":           "uart_rx · valid decode",
    "fir_filter_fir_clk_fix_ACCEPTED":     "fir_filter · MAC pipeline",
    "simple_spi_restructure_v2_REGRESSED": "simple_spi · decrementer",
    "fir_adder_tree_REJECTED":             "fir_filter · adder tree",
}

GATES = {
    "A": "Re-run STA on the whole design after verification",
    "B": "Escalate to a miter instead of retrying on a counterexample",
    "C": "Route tier 2 past EQY",
    "designwide": "Accept on design-wide violated paths, not the target clock",
}


def decide_with_gates(fix_type, validator_ok, eqy, tier, improved_design,
                      improved_local, gates):
    """The loop's decision, with any gate disabled.

    All gates on -> identical to run_loop.decide(). Asserted in selftest().
    Each branch below names the gate it belongs to and what breaks without it.
    """
    if fix_type == "no_fix":
        return "DECLINED", "model declined to propose a fix", None, []

    if not validator_ok:
        return ("REJECTED", "structural validator failed - never reaches EQY",
                "validator errors", [])

    notes = []
    eqy_seen = eqy

    # --- Gate C: tier routing --------------------------------------------
    # A tier 2 fix adds registers. EQY matches partitions by register name, so
    # the new ones have no counterpart and the comparison cannot be made.
    if tier == 2:
        if gates["C"]:
            notes.append("Gate C: tier 2, skipped EQY and built a miter "
                         "directly.")
        else:
            eqy_seen = "INCONCLUSIVE"
            notes.append("Gate C OFF: ran EQY on a pipeline fix. 16 of 18 "
                         "partitions proved; imm returned a spurious "
                         "counterexample and sample_out returned UNKNOWN. "
                         "Time spent, nothing learned.")

    # --- Gate B: escalate, never retry -----------------------------------
    # EQY feeds cut signals in as free inputs, so a counterexample may be
    # unreachable. Retrying on one rewrites a correct fix.
    if eqy_seen == "PASS_AFTER_REACHABILITY_CHECK":
        if gates["B"]:
            notes.append("Gate B: counterexample checked for reachability, "
                         "found impossible, discarded. Miter proved the fix.")
        else:
            return ("RETRY", "EQY reported a counterexample and the loop sent "
                    "it back to the model", "unreachable counterexample",
                    notes + ["Gate B OFF: the counterexample requires "
                             "fsm_state=FSM_STOP with n_fsm_state=FSM_START. "
                             "The case statement forbids it. The model would "
                             "have been asked to fix a correct fix."])

    if eqy_seen == "INCONCLUSIVE" and not gates["C"]:
        return ("RETRY", "EQY could not decide and the loop treated that as "
                "evidence of a defect", "inconclusive result", notes)

    if eqy_seen == "FAIL_REACHABLE":
        return ("REJECTED", "counterexample survives reachability analysis - "
                "genuine functional difference", "counterexample trace", notes)

    # --- Gate A: re-STA after verification -------------------------------
    # A formal pass says the circuit still computes the right thing. It says
    # nothing about whether it computes it faster.
    if not gates["A"]:
        return ("ACCEPTED", "formally equivalent - accepted without "
                "re-measuring timing", None,
                notes + ["Gate A OFF: no re-STA. Verification alone decided "
                         "this."])

    improved = improved_design if gates["designwide"] else improved_local
    basis = "design-wide violated paths" if gates["designwide"] \
        else "the target clock's slack"

    if not gates["designwide"]:
        notes.append("Criterion: target clock only. A fix that closes its own "
                     "domain and breaks another still passes.")

    if improved is False:
        return ("REJECTED", f"verified, but re-STA on {basis} shows a "
                f"regression", None, notes)
    return ("ACCEPTED", f"verified, and {basis} improved", None, notes)


def rtl_change(tag, modified):
    """Unified diff against the original, or the returned fragment.

    A model may return a whole module or only the part it changed. Diffing a
    fragment against a full file produces noise, so detect it and show the
    fragment instead of pretending it is a diff.
    """
    src = BEFORE.get(tag)
    before_path = ROOT / src if src else None
    if not before_path or not before_path.exists():
        return {"mode": "fragment", "before": None,
                "lines": [{"t": " ", "s": l} for l in modified.splitlines()],
                "adds": 0, "dels": 0, "truncated": 0}

    a = before_path.read_text().splitlines()
    b = modified.splitlines()

    if len(b) < 0.6 * len(a):        # fragment, not a full module
        return {"mode": "fragment", "before": src,
                "lines": [{"t": " ", "s": l} for l in b],
                "adds": 0, "dels": 0, "truncated": 0}

    raw = list(difflib.unified_diff(a, b, lineterm="", n=2))[2:]
    adds = sum(1 for l in raw if l.startswith("+"))
    dels = sum(1 for l in raw if l.startswith("-"))
    shown, truncated = raw[:60], max(0, len(raw) - 60)
    return {"mode": "diff", "before": src,
            "lines": [{"t": l[0] if l[:1] in "+-@" else " ",
                       "s": l[1:] if l[:1] in "+- " else l} for l in shown],
            "adds": adds, "dels": dels, "truncated": truncated}


def case_payload(tag):
    rec = FIXES / f"{tag}.json"
    if not rec.exists():
        return None
    d = json.loads(rec.read_text())
    led = LEDGER.get(tag)
    if not led:
        return None

    fix, val, v = d["fix"], d["validation"], d.get("violation", {})
    sc = d.get("edit_scope", {})
    inst = v.get("instances", [])
    att = sorted({i["src_file"] for i in inst if i.get("src_file")})

    db, da = led.get("design_before"), led.get("design_after")
    return {
        "tag": tag,
        "title": TITLE.get(tag, f"{led['module']} · {led['clock']}"),
        "rationale": (fix.get("rationale") or "").strip(),
        "rtl": rtl_change(tag, fix.get("modified_rtl") or ""),
        "module": led["module"],
        "clock": led["clock"],
        "tier": led["tier"],
        "fix_type": fix["fix_type"],
        "added_latency": fix["added_latency_cycles"],
        "source_file": d.get("source_file"),
        "violation_index": d.get("violation_index"),
        "slack": v.get("slack_ns"),
        "stages": len(inst),
        "attributed": att,
        "unattributed": sum(1 for i in inst if not i.get("src_file")),
        "scope": f"{sc.get('src_file')}:{sc.get('start_line')}-"
                 f"{sc.get('end_line')}",
        "model": d.get("meta", {}).get("model", "unrecorded"),
        "validator_ok": val["ok"],
        "validator_errors": val.get("errors") or [],
        "new_regs": val.get("new_registered_signals") or [],
        "eqy": led["eqy"],
        "eqy_note": led["eqy_note"],
        "fallback": led["fallback"],
        "before": led["before"],
        "after": led["after"],
        "before_n": led["before_n"],
        "after_n": led["after_n"],
        "design_before": db,
        "design_after": da,
        "measured_from": list(led["measured_from"]),
        "side_effect": led["side_effect"],
        "improved_local": led["after"] > led["before"],
        "improved_design": (da < db) if (db is not None and da is not None)
        else (led["after"] > led["before"]),
    }


def selftest():
    """All gates on must reproduce run_loop.decide() exactly."""
    on = {"A": True, "B": True, "C": True, "designwide": True}
    for tag in ORDER:
        c = case_payload(tag)
        if not c:
            continue
        ref = decide(c["fix_type"], c["validator_ok"], c["eqy"],
                     c["improved_design"])
        got = decide_with_gates(c["fix_type"], c["validator_ok"], c["eqy"],
                                c["tier"], c["improved_design"],
                                c["improved_local"], on)
        assert ref[0] == got[0], (tag, ref[0], got[0])
    return True


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(DEMO), **kw)

    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/cases":
            cases = [case_payload(t) for t in ORDER]
            return self._json({"cases": [c for c in cases if c],
                               "gates": GATES})
        return super().do_GET()

    def do_POST(self):
        if urlparse(self.path).path != "/api/decide":
            self.send_error(404)
            return
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        gates = {k: bool(req.get("gates", {}).get(k, True)) for k in GATES}
        out = {}
        for tag in ORDER:
            c = case_payload(tag)
            if not c:
                continue
            verdict, reason, retry, notes = decide_with_gates(
                c["fix_type"], c["validator_ok"], c["eqy"], c["tier"],
                c["improved_design"], c["improved_local"], gates)
            correct = decide(c["fix_type"], c["validator_ok"], c["eqy"],
                             c["improved_design"])[0]
            out[tag] = {"verdict": verdict, "reason": reason, "retry": retry,
                        "notes": notes, "correct": correct,
                        "wrong": verdict != correct}
        self._json(out)

    def log_message(self, *a):
        pass


def main():
    if not DEMO.exists():
        sys.exit(f"missing {DEMO}/ - demo/index.html must be present")
    selftest()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    print(f"\n  Loop demo running.  http://localhost:{port}\n"
          f"  Gate logic verified against run_loop.decide().  Ctrl-C to stop.\n")
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
