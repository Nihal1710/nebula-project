#!/usr/bin/env python3
"""
Track B — LLM fix proposer.

Reads a violating path from Track A's JSON, builds a prompt, calls Claude with a
hard-enforced output schema, validates the returned fix structurally, and writes
a handoff JSON for Track C.

Usage:
    pip install anthropic
    export ANTHROPIC_API_KEY=sk-...

    python3 propose_fix.py fir_violations.json --list
    python3 propose_fix.py fir_violations.json --clock fir_clk --whole-file --dry-run
    python3 propose_fix.py fir_violations.json --clock fir_clk --whole-file
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

MODEL = "claude-sonnet-5"
MAX_TOKENS = 8000
MAX_STAGES_SHOWN = 24

SEQ_CELL_RE = re.compile(r"DFF|DLH|DLL|LATCH", re.IGNORECASE)


# ---------------------------------------------------------------------------
# Normalising Track A's output
# ---------------------------------------------------------------------------

def as_text(snippet):
    """rtl_snippet is a list of lines in Track A's output."""
    if snippet is None:
        return None
    if isinstance(snippet, list):
        return "\n".join(snippet)
    return str(snippet)


def module_name_of(path):
    """First `module <name>` in a Verilog file."""
    try:
        text = Path(path).read_text()
    except OSError:
        return Path(path).stem
    m = re.search(r"\bmodule\s+([A-Za-z_]\w*)", text)
    return m.group(1) if m else Path(path).stem


def normalize(entry, root, whole_file, cost_table=None,
              scope_from_endpoint=False, context_files=None,
              scope_file=None):
    """Flatten one Track A entry into the fields the prompt needs."""
    insts = entry.get("instances", [])
    attributed = [i for i in insts if i.get("rtl_snippet")]

    v = {
        "slack": entry.get("slack_ns"),
        "clock": entry.get("path_group"),
        "startpoint": entry.get("startpoint"),
        "endpoint": entry.get("endpoint"),
        "violated": entry.get("violated"),
        "instances": insts,
        "n_stages": len(insts),
        "n_sequential": sum(1 for i in insts
                            if SEQ_CELL_RE.search(i.get("cell_type", "") or "")),
        "n_unattributed": len(insts) - len(attributed),
        "truncated": any(i.get("truncated") for i in insts),
        "cost_table": cost_table,
    }

    if not attributed:
        v.update(src_file=None, start_line=None, end_line=None,
                 rtl=None, module=None, scope="none")
        return v

    # Track A attributes at most a handful of instances. Take the first.
    if scope_file:
        m = [x for x in attributed if x.get('src_file') == scope_file]
        a = m[0] if m else dict(src_file=scope_file,
                                src_start_line=1, src_end_line=10**6)
    else:
        a = attributed[-1] if scope_from_endpoint else attributed[0]
    src = a.get("src_file")
    full = Path(root) / src if src else None

    if whole_file and full and full.exists():
        text = full.read_text()
        v.update(src_file=src, start_line=1, end_line=len(text.splitlines()),
                 rtl=text.rstrip(), module=module_name_of(full), scope="file")
    else:
        v.update(src_file=src,
                 start_line=a.get("src_start_line"),
                 end_line=a.get("src_end_line"),
                 rtl=as_text(a.get("rtl_snippet")),
                 module=module_name_of(full) if full and full.exists()
                        else (Path(src).stem if src else None),
                 scope="snippet")

    ctx = []
    for cf in (context_files or []):
        cp = Path(root) / cf
        if not cp.exists():
            raise SystemExit(f"context file not found: {cp}")
        if str(cf) == str(v.get('src_file')):
            continue
        ctx.append({'path': str(cf), 'text': cp.read_text().rstrip()})
    v['context'] = ctx
    return v


def cell_cost_table(entries, min_samples=3, cap_ns=10.0):
    """Median observed stage delay per cell type, across every path in the
    report. Measured in THIS design, so it includes real loading — that is
    the point: it tells the model what a gate of each width actually costs
    here, not what the library says in isolation. Outliers above cap_ns are
    fanout artifacts and are dropped."""
    import statistics, collections
    by = collections.defaultdict(list)
    for p in entries:
        for i in p.get("instances", []):
            d, ct = i.get("delay_ns"), i.get("cell_type")
            if d is not None and ct and 0 < d < cap_ns:
                by[ct].append(d)
    return {ct: (round(statistics.median(v), 3), len(v))
            for ct, v in by.items() if len(v) >= min_samples}


def render_cost_table(costs):
    if not costs:
        return None
    rows = sorted(costs.items(), key=lambda kv: -kv[1][0])
    out = ["  {:<14} {:>9}  {}".format("cell type", "median ns", "samples")]
    out += ["  {:<14} {:>9}  {}".format(ct, f"{med:.3f}", n)
            for ct, (med, n) in rows]
    return "\n".join(out)


def load(path):
    data = json.loads(Path(path).read_text())
    if isinstance(data, dict):
        for k in ("violations", "paths", "entries", "results"):
            if isinstance(data.get(k), list):
                return data[k]
        return [data]
    return data


def select(entries, args):
    if args.all:
        return [(i, e) for i, e in enumerate(entries) if e.get("violated")]
    if args.index is not None:
        return [(args.index, entries[args.index])]
    if args.clock:
        hits = [(i, e) for i, e in enumerate(entries)
                if str(e.get("path_group", "")).strip() == args.clock]
        if not hits:
            found = sorted({str(e.get("path_group")) for e in entries})
            raise SystemExit(f"No path_group '{args.clock}'. Found: {found}")
        return hits
    viol = [(i, e) for i, e in enumerate(entries) if e.get("violated")]
    pool = viol or list(enumerate(entries))
    return [min(pool, key=lambda p: float(p[1].get("slack_ns") or 0.0))]


# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """\
You are a digital design engineer fixing a setup-timing violation by editing RTL.

You are shown ONE violating timing path in isolation, plus the RTL it was \
attributed to. You do not have full-chip context and must not assume any. Reason \
only from what you are given.

You may use exactly one of two strategies.

RETIME — move an EXISTING register across combinational logic so the long \
combinational chain is split between two already-existing pipeline stages.
  - Register count from input to output is unchanged, so output latency is \
unchanged.
  - Only legal when a register on or adjacent to this path can actually be \
moved. If there is no register inside the combinational chain, retiming is not \
available.
  - added_latency_cycles MUST be 0.

PIPELINE — insert a NEW register that cuts the combinational chain into two \
shorter chains.
  - This delays the affected output by exactly the number of stages you added.
  - Every parallel path that reconverges with the path you cut must be delayed \
by the same number of cycles, or the design's function changes. Accumulators, \
tap-delay lines, and control/valid signals are the usual traps.
  - added_latency_cycles MUST equal the number of added stages (>= 1).

RESTRUCTURE — change the COMBINATIONAL structure so the same function is \
computed through a shallower network. No register is added, moved or removed.
  - Latency is unchanged, so added_latency_cycles MUST be 0.
  - Typical moves: rebalance a serial reduction into a tree (a+b+c+d evaluated \
left-to-right becomes (a+b)+(c+d)); split a wide ripple-carry chain into \
cascaded sub-blocks; replace a priority chain with parallel comparisons; \
factor out a shared sub-expression that is currently recomputed in series.
  - The rewritten expression must be provably identical in value for every \
input, not merely equivalent for typical inputs. Watch associativity under \
truncation, signedness, and saturation.
  - Prefer this over PIPELINE when it is available: it costs no latency, so it \
needs no downstream re-balancing and is far cheaper to verify.

NO_FIX — none of the above can be applied safely to what you were shown.
  - Use this rather than returning an unchanged or token edit under another \
label. It is a legitimate, expected outcome, not a failure.
  - added_latency_cycles MUST be 0 and modified_rtl MUST be an empty string.
  - Legitimate reasons include: the critical logic is not in the RTL you were \
shown; the path is a single-register combinational feedback loop, whose delay \
cannot be reduced by retiming; a cut would change the function rather than its \
timing; the reconvergent logic that would need re-balancing lies outside the \
given scope.

Hard rules for modified_rtl:

1. SCOPE. Return a drop-in replacement for exactly the RTL scope you were given \
— it is spliced back over the stated line range. No markdown fences, no \
commentary, no extra context you were not shown.
2. INTERFACE. Do not change the port list: no renamed ports, no changed widths \
or directions. Equivalence checking compares against a golden version built on \
this exact interface.
3. STYLE. Match the surrounding code: same reset polarity and style, same \
blocking/non-blocking conventions, same naming.
4. FUNCTION. Change only WHEN a result becomes available, never WHAT it is. Bit \
widths, arithmetic, signedness, truncation and rounding must be preserved \
exactly.
5. If no strategy applies, answer NO_FIX with an empty modified_rtl and explain \
why in `rationale`. Never edit code you were not shown, and never return an \
unchanged scope under a fix label.

`rationale` must state: which strategy you chose and why each of the others was \
rejected, where exactly the cut, move or rewrite was made, and what else you \
delayed to keep reconvergent paths balanced. For NO_FIX, state what a correct \
fix would require and why it is out of reach at this scope.\
"""


def render_stages(v):
    insts = v["instances"]
    if not insts:
        return "(no instance list)"

    def row(n, i):
        src = i.get("src_file")
        loc = f"{src}:{i.get('src_start_line')}" if src else "-"
        d = i.get("delay_ns")
        return "  {:>3}  {:<12} {:<12} {:>8}  {}".format(
            n, str(i.get("name", ""))[:12], str(i.get("cell_type", ""))[:12],
            f"{d:.3f}" if d is not None else "-", loc)

    head = "  {:>3}  {:<12} {:<12} {:>8}  {}".format(
        "#", "instance", "cell type", "delay ns", "src")
    if len(insts) <= MAX_STAGES_SHOWN:
        body = [row(n, i) for n, i in enumerate(insts)]
    else:
        h = MAX_STAGES_SHOWN // 2
        body = ([row(n, i) for n, i in enumerate(insts[:h])]
                + [f"       ... {len(insts) - 2*h} further stages of the "
                   f"same form omitted ..."]
                + [row(len(insts) - h + n, i) for n, i in enumerate(insts[-h:])])
    return "\n".join([head] + body)


def build_prompt(v):
    L = []
    L.append("## Timing violation (OpenSTA, Nangate45)\n")
    L.append(f"clock / path group : {v['clock']}")
    L.append(f"slack              : {v['slack']} ns  (negative = setup violation)")
    L.append(f"startpoint         : {v['startpoint']}")
    L.append(f"endpoint           : {v['endpoint']}")

    L.append("\n## Path structure (extracted from the netlist, not interpreted)\n")
    L.append(f"cells on the path                    : {v['n_stages']}")
    L.append(f"sequential cells on the path         : {v['n_sequential']}")
    L.append(f"cells with no source attribution     : {v['n_unattributed']}")

    ds = [i["delay_ns"] for i in v["instances"]
          if i.get("delay_ns") is not None]
    if ds:
        L.append(f"summed stage delay                   : {sum(ds):.3f} ns")
        L.append(f"worst single stage                   : {max(ds):.3f} ns")
        L.append(f"mean stage delay                     : "
                 f"{sum(ds)/len(ds):.3f} ns")
    L.append("")
    L.append(render_stages(v))

    if v.get("cost_table"):
        L.append("\n## What each cell type costs in THIS design\n")
        L.append("Median observed stage delay per cell type, measured across "
                 "every path in this report (so it includes real loading, not "
                 "just intrinsic library delay). Use it to sanity-check what "
                 "your proposed logic would actually cost:\n")
        L.append(v["cost_table"])
        L.append("\nNote the spread. Reducing the NUMBER of logic levels only "
                 "helps if the replacement gates are no wider than the ones "
                 "they replace — a wide gate can cost several times a 2-input "
                 "one, so a shallower expression built from wider gates can be "
                 "SLOWER than the deeper one it replaces.")

    if v["n_unattributed"]:
        L.append(
            f"\nVISIBILITY WARNING: {v['n_unattributed']} of {v['n_stages']} cells "
            "on this path carry no source attribution from synthesis. The RTL "
            "below is what the tool could attribute — it is NOT guaranteed to "
            "contain the combinational logic that dominates this path. Read the "
            "cell sequence above and judge for yourself which part of the RTL it "
            "corresponds to. If the critical logic is not in the code you were "
            "given, say so in `rationale`."
        )

    if v.get("context"):
        L.append("\n## Additional RTL on this path (READ ONLY - do NOT modify)\n")
        L.append("This path crosses module boundaries. The files below also "
                 "contribute logic to it, but are NOT in your edit scope. Use "
                 "them to understand what the unattributed cells are doing and "
                 "what signals arrive at the module you may edit. If the only "
                 "correct fix lies in one of these files, return no_fix and say "
                 "which file and which lines.\n")
        for c in v["context"]:
            L.append(f"### {c['path']}  (context only)")
            L.append("```verilog")
            L.append(c["text"])
            L.append("```")

    L.append("\n## If the fix is not in your scope\n")
    L.append("If you return no_fix because the dominant delay lies in RTL "
             "outside your edit scope, populate `out_of_scope_fix` with the "
             "file and line range where the fix belongs, so the scope can be "
             "widened and this violation retried. Base the location on the "
             "gate sequence even if you have not been shown that file; set "
             "confidence to 'low' when you have not. If no fix exists "
             "anywhere on this path - the path is already minimal, or a fix "
             "would change observable behaviour - set out_of_scope_fix to "
             "null. That is a real refusal and correctly ends the search. "
             "Do not name a file merely to avoid declining.\n")

    L.append("\n## RTL to modify\n")
    L.append(f"module : {v['module']}")
    L.append(f"file   : {v['src_file']}")
    L.append(f"lines  : {v['start_line']}-{v['end_line']}  "
             f"(your output replaces exactly this range)")
    L.append("")
    if v["rtl"]:
        L.append("```verilog")
        L.append(v["rtl"])
        L.append("```")
    else:
        L.append("(nothing attributed — you cannot propose a safe edit; say so.)")
    return "\n".join(L)


# ---------------------------------------------------------------------------
# Enforced schema + call
# ---------------------------------------------------------------------------

FIX_SCHEMA = {
    "type": "object",
    "properties": {
        "fix_type": {"type": "string",
                     "enum": ["retime", "pipeline", "restructure", "no_fix"],
                     "description": "Strategy applied; routes the fix to the "
                                    "correct equivalence-checking tier. "
                                    "'retime' and 'restructure' preserve "
                                    "latency (Tier 1, native structural "
                                    "matching); 'pipeline' adds latency "
                                    "(Tier 2, golden delayed wrapper); "
                                    "'no_fix' means no safe fix exists at "
                                    "this scope."},
        "target_module": {"type": "string",
                          "description": "Module the modified RTL belongs to."},
        "added_latency_cycles": {"type": "integer",
                                 "description": "0 for retime, restructure "
                                                "and no_fix; number of "
                                                "inserted register stages "
                                                "for pipeline."},
        "modified_rtl": {"type": "string",
                         "description": "Drop-in replacement for the given "
                                        "scope. Raw Verilog, no fences. "
                                        "Empty string when fix_type is "
                                        "no_fix."},
        "rationale": {"type": "string",
                      "description": "Strategy choice, cut location, and what "
                                     "was delayed to stay balanced."},
        "out_of_scope_fix": {
            "type": ["object", "null"],
            "description": "Only meaningful when fix_type is no_fix. If the "
                           "dominant delay on this path lies in RTL you were "
                           "NOT permitted to edit, name it here so the scope "
                           "can be widened and the violation retried. Set to "
                           "null if no fix exists anywhere on this path - "
                           "that is a real refusal and stops the search.",
            "properties": {
                "src_file": {"type": "string",
                             "description": "Repo-relative path to the file "
                                            "containing the fixable logic."},
                "start_line": {"type": "integer"},
                "end_line": {"type": "integer"},
                "confidence": {"type": "string",
                               "enum": ["high", "medium", "low"],
                               "description": "low if inferred only from the "
                                              "gate sequence with no RTL "
                                              "seen for that file."},
                "reason": {"type": "string",
                           "description": "One sentence: why the fix belongs "
                                          "there rather than in your scope."},
            },
            "required": ["src_file", "start_line", "end_line",
                         "confidence", "reason"],
            "additionalProperties": False,
        },
    },
    "required": ["fix_type", "target_module", "added_latency_cycles",
                 "modified_rtl", "rationale", "out_of_scope_fix"],
    "additionalProperties": False,
}


def call_via_agent(v, model):
    """Claude Agent SDK — draws on the Pro plan's monthly Agent SDK credit.

    No API key. Requires the Claude Code CLI to be installed and logged in,
    and ANTHROPIC_API_KEY to be UNSET (if it is set, Claude Code bills the
    API instead of your subscription).
    """
    import asyncio
    from claude_agent_sdk import query, ClaudeAgentOptions, ResultMessage

    if os.environ.get("ANTHROPIC_API_KEY"):
        print("  warning ANTHROPIC_API_KEY is set — this will bill the API, "
              "not your subscription. `unset ANTHROPIC_API_KEY` to use the "
              "Agent SDK credit.", file=sys.stderr)

    opts = {
        "system_prompt": SYSTEM_PROMPT,
        "tools": [],          # no file/bash access: one shot, prompt in, JSON out
        "max_turns": 1,
        "output_format": {"type": "json_schema", "schema": FIX_SCHEMA},
    }
    if model:
        opts["model"] = model

    async def run():
        async for m in query(prompt=build_prompt(v),
                             options=ClaudeAgentOptions(**opts)):
            if isinstance(m, ResultMessage):
                if m.subtype == "success" and m.structured_output:
                    return m.structured_output, {
                        "backend": "agent_sdk",
                        "model": model or "(default)",
                        "num_turns": getattr(m, "num_turns", None),
                        "cost_usd": getattr(m, "total_cost_usd", None),
                        "model_usage": getattr(m, "model_usage", None),
                        "session_id": getattr(m, "session_id", None),
                    }
                if m.subtype == "error_max_structured_output_retries":
                    raise SystemExit("Agent could not produce output matching "
                                     "the schema after retries.")
                raise SystemExit(f"Run ended without structured output "
                                 f"(subtype={m.subtype}).")
        raise SystemExit("No result message returned by the agent.")

    return asyncio.run(run())


def call_via_api(v, model):
    """Direct Messages API — needs ANTHROPIC_API_KEY and Console credits."""
    import anthropic
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise SystemExit("ANTHROPIC_API_KEY is not set.")
    client = anthropic.Anthropic()
    r = client.messages.create(
        model=model or MODEL, max_tokens=MAX_TOKENS,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": build_prompt(v)}],
        output_config={"format": {"type": "json_schema", "schema": FIX_SCHEMA}},
    )
    if r.stop_reason == "max_tokens":
        raise SystemExit("Truncated — raise MAX_TOKENS.")
    if r.stop_reason == "refusal":
        raise SystemExit("Refusal — output does not follow the schema.")
    text = next(b.text for b in r.content if b.type == "text")
    return json.loads(text), {"backend": "messages_api",
                              "model": model or MODEL,
                              "input_tokens": r.usage.input_tokens,
                              "output_tokens": r.usage.output_tokens}


def call_claude(v, model, backend):
    return (call_via_agent if backend == "agent" else call_via_api)(v, model)


# ---------------------------------------------------------------------------
# Structural validation — cheap pre-EQY filter
# ---------------------------------------------------------------------------

def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)
    return re.sub(r"//[^\n]*", " ", s)


def reg_signals(s):
    return set(re.findall(r"([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)?<=",
                          strip_comments(s)))


def kw(s, w):
    return len(re.findall(rf"\b{w}\b", strip_comments(s)))


def ports_of(s):
    """Port identifiers in a module header, for interface-drift detection."""
    m = re.search(r"\bmodule\b.*?\((.*?)\)\s*;", strip_comments(s), flags=re.S)
    if not m:
        return None
    body = re.sub(r"#\s*\(.*?\)", " ", m.group(1), flags=re.S)
    return set(re.findall(r"(\w+)\s*(?=,|$)", body.strip()))


def validate(fix, v):
    errors, warnings = [], []
    orig, mod = v.get("rtl") or "", fix.get("modified_rtl", "")
    ft, added = fix.get("fix_type"), fix.get("added_latency_cycles")

    # --- no_fix: a declared refusal. Validate the declaration, nothing else. ---
    oos = fix.get("out_of_scope_fix")
    if ft != "no_fix" and oos is not None:
        errors.append("out_of_scope_fix must be null unless fix_type is no_fix")
    if oos is not None:
        if not (oos.get("src_file") or "").endswith((".v", ".sv")):
            errors.append(f"out_of_scope_fix.src_file is not RTL: "
                          f"{oos.get('src_file')!r}")
        if oos.get("start_line", 0) > oos.get("end_line", 0):
            errors.append("out_of_scope_fix line range is inverted")

    if ft == "no_fix":
        if added != 0:
            errors.append(f"no_fix but added_latency_cycles={added} (must be 0)")
        if mod.strip():
            errors.append("no_fix but modified_rtl is not empty")
        if not (fix.get("rationale") or "").strip():
            errors.append("no_fix with no rationale — the reason IS the result")
        return {"ok": not errors, "errors": errors, "warnings": warnings,
                "new_registered_signals": [], "register_delta": None,
                "tier": None, "refused": True}

    if ft in ("retime", "restructure") and added != 0:
        errors.append(f"{ft} but added_latency_cycles={added} (must be 0)")
    if ft == "pipeline" and (not isinstance(added, int) or added < 1):
        errors.append(f"pipeline but added_latency_cycles={added} (must be >= 1)")

    if v.get("module") and fix.get("target_module") != v["module"]:
        warnings.append(f"target_module '{fix.get('target_module')}' != "
                        f"'{v['module']}'")

    delta, new_regs = None, []
    if orig:
        before, after = reg_signals(orig), reg_signals(mod)
        delta, new_regs = len(after) - len(before), sorted(after - before)
        if ft == "pipeline" and delta < 1:
            errors.append(f"claims pipeline but registered-signal count changed "
                          f"by {delta:+d} (expected >= +1)")
        if ft == "retime" and delta != 0:
            warnings.append(f"claims retime but registered-signal count changed "
                            f"by {delta:+d} (new: {new_regs})")
        if ft == "restructure" and delta > 0:
            errors.append(f"claims restructure but added {delta} registered "
                          f"signal(s) {new_regs} — that is a pipeline fix and "
                          f"would be routed to the wrong verification tier")
        if ft == "restructure" and delta < 0:
            warnings.append(f"claims restructure but registered-signal count "
                            f"dropped by {-delta} — check no state was lost")

        had, has = kw(orig, "module") > 0, kw(mod, "module") > 0
        if has and not had:
            errors.append("fragment in, full module out — splice would break "
                          "the file")
        if had and not has:
            errors.append("full module in, no module header out")

        pb, pa = ports_of(orig), ports_of(mod)
        if pb and pa and pb != pa:
            errors.append(f"port list changed: added {sorted(pa - pb)}, "
                          f"removed {sorted(pb - pa)}")

    if kw(mod, "begin") != kw(mod, "end"):
        errors.append(f"unbalanced begin/end ({kw(mod,'begin')}/{kw(mod,'end')})")
    if kw(mod, "module") != kw(mod, "endmodule"):
        errors.append("unbalanced module/endmodule")
    if "```" in mod:
        errors.append("modified_rtl contains markdown fences")
    if orig and mod.strip() == orig.strip():
        errors.append("modified_rtl identical to input — no fix applied")
    if orig and len(mod.splitlines()) > 3 * max(len(orig.splitlines()), 1):
        warnings.append("modified_rtl >3x input length — check the scope rule")

    tier = {"retime": 1, "restructure": 1, "pipeline": 2}.get(ft)
    return {"ok": not errors, "errors": errors, "warnings": warnings,
            "new_registered_signals": new_regs, "register_delta": delta,
            "tier": tier, "refused": False}


# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description="Track B fix proposer")
    p.add_argument("violations")
    p.add_argument("--root", default=".", help="repo root for resolving src_file")
    p.add_argument("--index", type=int)
    p.add_argument("--clock", help="path_group, e.g. fir_clk")
    p.add_argument("--all", action="store_true", help="every violated entry")
    p.add_argument("--list", action="store_true", help="summarise and exit")
    p.add_argument("--whole-file", action="store_true",
                   help="edit scope = the whole attributed source file, not just "
                        "the attributed line range")
    p.add_argument("--model", default=None,
                   help="e.g. claude-sonnet-5, claude-opus-5; "
                        "omit to use the backend default")
    p.add_argument("--backend", choices=["agent", "api"],
                   default="agent",
                   help="agent = Claude Agent SDK on your Pro "
                        "plan credit (no API key); api = Messages "
                        "API (needs a key + Console credits)")
    p.add_argument("--outdir", default="fixes")
    p.add_argument("--dry-run", action="store_true", help="print prompt, no call")
    p.add_argument("--scope-file", default=None, metavar="PATH",
                   help="force the edit scope to this file "
                        "(used by escalate.py)")
    p.add_argument("--scope-from-endpoint", action="store_true",
                   help="scope from the LAST attributed cell (capture side)")
    p.add_argument("--context-file", action="append", default=[],
                   metavar="PATH", dest="context_file",
                   help="extra RTL shown read-only; repeatable")
    a = p.parse_args()

    entries = load(a.violations)

    if a.list:
        for i, e in enumerate(entries):
            v = normalize(e, a.root, False)
            flag = "VIOLATED" if e.get("violated") else "ok      "
            print(f"[{i}] {flag} {str(v['clock']):<14} slack={v['slack']:>9} "
                  f"cells={v['n_stages']:>3}  attributed -> "
                  f"{v['src_file']}:{v['start_line']}-{v['end_line']}")
        return

    costs = render_cost_table(cell_cost_table(entries))

    for idx, entry in select(entries, a):
        v = normalize(entry, a.root, a.whole_file, cost_table=costs,
                      scope_from_endpoint=a.scope_from_endpoint,
                      context_files=a.context_file,
                      scope_file=a.scope_file)
        tag = f"{v['module'] or 'mod'}_{v['clock'] or idx}"
        print(f"\n=== [{idx}] {tag}  slack={v['slack']}  scope={v['scope']} ===",
              file=sys.stderr)

        if a.dry_run:
            print("----- SYSTEM -----\n" + SYSTEM_PROMPT)
            print("\n----- USER -----\n" + build_prompt(v))
            continue

        fix, meta = call_claude(v, a.model, a.backend)
        rep = validate(fix, v)

        Path(a.outdir).mkdir(parents=True, exist_ok=True)
        out = Path(a.outdir) / f"{tag}_fix.json"
        out.write_text(json.dumps({
            "source_file": a.violations, "violation_index": idx,
            "edit_scope": {k: v[k] for k in
                           ("src_file", "start_line", "end_line", "scope")},
            "violation": entry, "fix": fix, "validation": rep, "meta": meta,
        }, indent=2))

        tier_s = "refused" if rep["refused"] else f"tier {rep['tier']}"
        print(f"  fix_type={fix['fix_type']}  "
              f"added_latency={fix['added_latency_cycles']}  "
              f"{tier_s}  ok={rep['ok']}", file=sys.stderr)
        for e in rep["errors"]:
            print(f"  ERROR   {e}", file=sys.stderr)
        for w in rep["warnings"]:
            print(f"  warning {w}", file=sys.stderr)
        print(f"  -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
