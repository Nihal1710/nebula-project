#!/usr/bin/env python3
"""
escalate.py - automatic scope escalation for a single violation.

THE PROBLEM
-----------
propose_fix.py picks its edit scope from one attributed cell on the path.
On a path that crosses module boundaries that is often the wrong file. The
UART violation (index 112) needed three runs by hand:

  run 1  scope = uart_rx.v:170-180 (snippet)  -> no_fix
  run 2  scope = wptr_full.v (whole file)     -> no_fix, but the rationale
                                                 named uart_rx.v:108-123
  run 3  scope = uart_rx.v (whole file)       -> restructure, ACCEPTED

Run 3 happened because a human read run 2's prose and re-ran with different
flags. This script does that automatically.

WHY IT IS BOUNDED
-----------------
The generality claim is that the model only ever sees an isolated violating
path plus local RTL, never the whole SoC. So escalation may only reach files
that are ON the path:

  * files of attributed cells in the violation record, plus
  * any file the model itself names in out_of_scope_fix

and nothing else. Attribution survives only on flip-flops, so the attributed
set is usually incomplete - which is exactly why the model naming a file is
the second, necessary source.

STOPPING
--------
  1. a fix is produced and passes the validator          -> SOLVED
  2. no_fix with out_of_scope_fix = null                 -> REFUSED (real)
  3. every candidate file has been the edit scope        -> EXHAUSTED

Case 2 is the one that matters: it is the model saying "no fix exists
anywhere on this path", which is a sound refusal and not a scope problem.
Without it this would be a loop that only stops on success - i.e. one that
pressures a correct refusal until it breaks.

USAGE
    python3 escalate.py soc_violations_base2.json --index 112
    python3 escalate.py soc_violations_base2.json --index 112 --dry-run
    python3 escalate.py soc_violations_base2.json --index 112 --max-rounds 4
"""

import argparse, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BAR = "=" * 74


def log(msg=""):
    print(msg, flush=True)


def path_files(violation):
    """Files visible from attribution. Ordered launch-side first, since that is
    what propose_fix.py picks by default; the capture side is the usual second
    candidate."""
    seen, out = set(), []
    for i in violation.get("instances", []):
        f = i.get("src_file")
        if f and f not in seen:
            seen.add(f)
            out.append(f)
    return out


def run_propose(vjson, index, scope_file, context_files, dry_run,
                outdir=None, extra=()):
    """One propose_fix.py invocation with an explicit edit scope."""
    cmd = ["python3", "propose_fix.py", vjson, "--index", str(index),
           "--whole-file", "--scope-file", scope_file]
    for c in context_files:
        cmd += ["--context-file", c]
    if outdir:
        cmd += ["--outdir", outdir]
    cmd += list(extra)
    if dry_run:
        cmd.append("--dry-run")
    log(f"    $ {' '.join(cmd)}")
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if dry_run:
        return None
    if r.returncode != 0:
        log(f"    propose_fix.py exited {r.returncode}")
        log("    " + (r.stderr or "").strip()[:400])
        return None
    for line in ((r.stdout or "") + "\n" + (r.stderr or "")).splitlines():
        if "->" in line and line.strip().endswith(".json"):
            return Path(line.split("->")[-1].strip())
    log("    could not locate the output file in propose_fix.py stdout")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("violations")
    ap.add_argument("--index", type=int, required=True)
    ap.add_argument("--max-rounds", type=int, default=4)
    ap.add_argument("--outdir", default=None, metavar="DIR",
                    help="write fix records here instead of fixes/. Use this "
                         "to avoid overwriting recorded results - tags collide "
                         "on <module>_<clock>.")
    ap.add_argument("--model", default=None, metavar="NAME",
                    help="pin the model, e.g. claude-sonnet-5. Passed "
                         "straight through to propose_fix.py.")
    ap.add_argument("--dry-run", action="store_true",
                    help="build prompts, make no API calls")
    a = ap.parse_args()

    vfile = ROOT / a.violations
    viol = json.loads(vfile.read_text())[a.index]

    attributed = path_files(viol)
    unattr = sum(1 for i in viol.get("instances", []) if not i.get("src_file"))

    log(BAR)
    log(f"  ESCALATION  violation[{a.index}]  {viol.get('path_group')}  "
        f"slack={viol.get('slack_ns')} ns")
    log(BAR)
    log(f"  stages            : {len(viol.get('instances', []))}")
    log(f"  unattributed cells: {unattr}")
    log(f"  candidate files from attribution:")
    for f in attributed:
        log(f"      {f}")
    log("  (attribution survives only on flip-flops, so this list is a lower")
    log("   bound; the model may name additional files as it goes)")

    tried, queue = [], list(attributed)
    verdict, accepted = "EXHAUSTED", None

    for rnd in range(1, a.max_rounds + 1):
        if not queue:
            log(f"\n  no candidate files left after {rnd - 1} round(s)")
            break

        scope = queue.pop(0)
        if scope in tried:
            continue
        tried.append(scope)
        context = [f for f in attributed + tried if f != scope]
        context = list(dict.fromkeys(context))

        log(f"\n  ── round {rnd} ─────────────────────────────────────────")
        log(f"    edit scope : {scope}")
        log(f"    context    : {', '.join(context) if context else '(none)'}")

        out = run_propose(a.violations, a.index, scope, context, a.dry_run,
                          outdir=a.outdir,
                          extra=(["--model", a.model] if a.model else []))
        if a.dry_run:
            log("    [dry-run] prompt built; no call made")
            continue
        if out is None:
            verdict = "ERROR"
            break

        rec = json.loads((ROOT / out).read_text())
        fix, val = rec["fix"], rec["validation"]
        log(f"    result     : {fix['fix_type']}  validator_ok={val['ok']}")

        if fix["fix_type"] != "no_fix" and val["ok"]:
            verdict, accepted = "SOLVED", out
            log(f"    -> fix produced in {scope}")
            break

        if fix["fix_type"] != "no_fix" and not val["ok"]:
            log(f"    -> validator rejected: {val.get('errors')}")
            continue

        oos = fix.get("out_of_scope_fix")
        if oos is None:
            verdict = "REFUSED"
            log("    -> no_fix, and no other location named.")
            log("       The model is asserting no fix exists anywhere on this")
            log("       path. This is a sound refusal, not a scope problem.")
            break

        nxt = oos["src_file"]
        log(f"    -> no_fix, but points at {nxt}:"
            f"{oos['start_line']}-{oos['end_line']} "
            f"(confidence {oos['confidence']})")
        log(f"       {oos['reason']}")
        if nxt in tried:
            log("       already tried that scope - stopping to avoid a cycle")
            break
        if nxt not in queue:
            queue.insert(0, nxt)
        if nxt not in attributed:
            log("       NOTE: this file carries no attribution on this path -")
            log("       it is reachable only because the model named it.")

    log(f"\n{BAR}")
    log(f"  VERDICT: {verdict}")
    log(f"  scopes tried ({len(tried)}): {', '.join(tried) or '(none)'}")
    if accepted:
        log(f"  fix record: {accepted}")
    if verdict == "REFUSED":
        log("  Record as genuinely unfixable at RTL level for this path.")
    if verdict == "EXHAUSTED":
        log("  Every file on the path was tried without a fix. Either the fix")
        log("  is off-path, or it needs a transform outside the tier system.")
    log(BAR)

    return 0 if verdict in ("SOLVED", "REFUSED") else 1


if __name__ == "__main__":
    sys.exit(main())
