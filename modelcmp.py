#!/usr/bin/env python3
"""
modelcmp.py - is the Sonnet/Opus difference a model difference, or variance?

The recorded comparison is one Sonnet run and one Opus run on violation 112.
Sonnet declined, Opus proposed a retime. That supports "model choice changes
the outcome" only if each model is self-consistent. If Sonnet declines once and
proposes once, the difference is run-to-run noise and the claim is wrong.

    python3 modelcmp.py --n 5 --whole-file    # the scope the recorded runs used
    python3 modelcmp.py --n 5                 # the narrow default scope
    python3 modelcmp.py --report              # summarise everything run so far

SCOPE IS A VARIABLE, NOT A DETAIL. The default scope selector picks a window
around the launch flop - for violation 112 that is uart_rx.v:170-180, eleven
lines that do not contain the fix. --whole-file hands over all 214 lines, which
is what the recorded Sonnet/Opus comparison used. Results are grouped by scope
in the report, because comparing across scopes compares nothing.

Each run is written to fixes_modelcmp/runs/<model>_<n>_fix.json, so nothing
recorded is overwritten and the raw records survive for inspection.
"""

import argparse
import collections
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "fixes_modelcmp" / "runs"

VIOLATIONS = "soc_violations_base2.json"
INDEX = 112
MODELS = ["claude-sonnet-5", "claude-opus-4-1"]


def venv_python():
    v = ROOT / ".venv" / "bin" / "python3"
    return str(v) if v.exists() else sys.executable


def one_run(model, n, whole_file):
    """One proposal. Returns the parsed record, or None if the call failed."""
    tag = "whole" if whole_file else "narrow"
    tmp = OUT / f"_tmp_{model}_{tag}_{n}"
    tmp.mkdir(parents=True, exist_ok=True)
    cmd = [venv_python(), "propose_fix.py", VIOLATIONS,
           "--index", str(INDEX), "--model", model, "--outdir", str(tmp)]
    if whole_file:
        cmd.append("--whole-file")
    env = dict(os.environ)
    env.pop("ANTHROPIC_API_KEY", None)

    t0 = time.time()
    p = subprocess.run(cmd, cwd=ROOT, env=env, text=True,
                       capture_output=True)
    dt = time.time() - t0

    written = sorted(tmp.glob("*_fix.json"))
    if p.returncode != 0 or not written:
        print(f"  {model} run {n}: FAILED rc={p.returncode} ({dt:.0f}s)")
        tail = (p.stderr or p.stdout or "").strip().splitlines()[-3:]
        for line in tail:
            print(f"      {line[:100]}")
        return None

    dest = OUT / f"{model}_{tag}_{n}_fix.json"
    dest.write_text(written[-1].read_text())
    for f in tmp.iterdir():
        f.unlink()
    tmp.rmdir()

    d = json.loads(dest.read_text())
    fix, val = d["fix"], d["validation"]
    print(f"  {model} run {n}: {fix['fix_type']:12} "
          f"latency=+{fix['added_latency_cycles']} "
          f"regdelta={val.get('register_delta')} "
          f"valid={val['ok']} refused={val.get('refused')} ({dt:.0f}s)")
    return d


def report():
    if not OUT.exists():
        sys.exit(f"nothing in {OUT} yet - run without --report first")
    # Group by the scope each record says it used, not by filename. A record
    # carries its own conditions; trusting the filename is how the first run
    # of this experiment ended up comparing two different things.
    cells = collections.defaultdict(list)
    for f in sorted(OUT.glob("*_fix.json")):
        d = json.loads(f.read_text())
        s = d["edit_scope"]
        span = (s.get("start_line"), s.get("end_line"))
        cells[(span, d.get("meta", {}).get("model", "?"))].append(d)

    if not cells:
        return
    print(f"\nviolation {INDEX} of {VIOLATIONS}")

    for span in sorted({k[0] for k in cells}, key=lambda s: -(s[1] - s[0])):
        width = span[1] - span[0] + 1
        print(f"\n  scope {span[0]}-{span[1]}  ({width} lines)")
        inner = {}
        for (sp, model), runs in sorted(cells.items()):
            if sp != span:
                continue
            kinds = collections.Counter(r["fix"]["fix_type"] for r in runs)
            cost = sum(r.get("meta", {}).get("cost_usd", 0) for r in runs)
            spread = " ".join(f"{k}x{v}" for k, v in kinds.most_common())
            stable = "stable" if len(kinds) == 1 else "UNSTABLE"
            print(f"    {model:20} n={len(runs):2}  {spread:28} "
                  f"{stable:9} ${cost:.2f}")
            inner[model] = set(kinds)
        if len(inner) > 1:
            if len({frozenset(v) for v in inner.values()}) == 1:
                print(f"    {'':20} both models agree at this scope")
            else:
                print(f"    {'':20} the models disagree at this scope")

    unstable = [(sp, m) for (sp, m), runs in cells.items()
                if len({r["fix"]["fix_type"] for r in runs}) > 1]
    print()
    if unstable:
        for sp, m in unstable:
            print(f"  {m} gave different answers to an identical prompt at "
                  f"scope {sp[0]}-{sp[1]}.")
        print("  Run-to-run variance is present. A single run per violation is")
        print("  not evidence of what a model can or cannot do.")
    else:
        print("  Every model was self-consistent within every scope tested.")
    if len({k[0] for k in cells}) > 1:
        print("  Scopes differ between cells above - compare within a scope, "
              "never across.")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=5, help="runs per model")
    ap.add_argument("--models", nargs="+", default=MODELS)
    ap.add_argument("--whole-file", action="store_true",
                    help="hand the model the entire file, as the recorded "
                         "Sonnet/Opus comparison did")
    ap.add_argument("--report", action="store_true", help="summarise only")
    a = ap.parse_args()

    if a.report:
        return report()

    OUT.mkdir(parents=True, exist_ok=True)
    scope = "whole file" if a.whole_file else "default (narrow) scope"
    print(f"\n{len(a.models)} model(s) x {a.n} runs on violation {INDEX}, "
          f"{scope}.")
    print("Identical prompt every time. Ctrl-C is safe - finished runs are "
          "kept.\n")
    for model in a.models:
        for n in range(1, a.n + 1):
            one_run(model, n, a.whole_file)
    report()


if __name__ == "__main__":
    main()
