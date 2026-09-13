#!/usr/bin/env python3
"""
Track A - Step 3 & 4: parse an OpenSTA report_checks report into structured
JSON, and pull the corresponding RTL context for each path using the
`src` attributes left in the (non -noattr) gate-level netlist.

Usage:
    python3 parse_violation.py \\
        --report reports/picorv32_max_paths.rpt \\
        --netlist netlist/picorv32_netlist.v \\
        --repo-root . \\
        --out violations.json

A report file can contain more than one path (e.g. picorv32_top10.rpt,
generated with -group_count 10) - each block starting with "Startpoint:"
is parsed as a separate violation.

Output shape (one entry per path found in the report):
{
  "startpoint": "_18362_",
  "endpoint": "_19778_",
  "path_group": "clk",
  "path_type": "max",
  "slack_ns": -8.2869,
  "violated": true,
  "instances": [
    {
      "name": "_14283_",
      "cell_type": "AOI221_X1",
      "src_file": "rtl/vendor/picorv32/picorv32.v",
      "src_start_line": 1402,
      "src_end_line": 1975,
      "rtl_snippet": ["...", "..."],   # null if no src tag or span too large
      "truncated": false
    },
    ...
  ]
}
"""

import argparse
import json
import re
import sys
from pathlib import Path

# ---- tunables -------------------------------------------------------
MAX_SNIPPET_LINES = 150  # spans larger than this get flagged, not dumped
MAX_STAGE_NS = 10.0      # single-stage delay above this = fanout artifact
# -----------------------------------------------------------------------

HEADER_RE = {
    "startpoint": re.compile(r"^Startpoint:\s+(\S+)"),
    "endpoint": re.compile(r"^Endpoint:\s+(\S+)"),
    "path_group": re.compile(r"^Path Group:\s+(\S+)"),
    "path_type": re.compile(r"^Path Type:\s+(\S+)"),
}

# matches a delay-table row, tolerating either column layout:
#    1.5353    0.0977    0.0244    9.1806 v _14283_/ZN (AOI221_X1)   (-fields)
#                        0.0244    9.1806 v _14283_/ZN (AOI221_X1)   (plain)
# The two numbers immediately before the transition marker are always
# (incremental delay, cumulative arrival time).
ROW_RE = re.compile(
    r"([-\d.]+)\s+([-\d.]+)\s+[\^v]\s+([^\s/]+)/(\S+)\s+\(([^)]+)\)"
)

# matches the final slack line, e.g.:
#                                  -8.2869   slack (VIOLATED)
SLACK_RE = re.compile(r"([-\d.]+)\s+slack\s+\((VIOLATED|MET)\)")

# matches a src attribute line in the netlist, e.g.:
#   (* src = "rtl/vendor/picorv32/picorv32.v:1402.2-1975.5" *)
SRC_ATTR_RE = re.compile(r'src\s*=\s*"([^"]+)"')
SRC_SPAN_RE = re.compile(r"^(.*):(\d+)\.\d+-(\d+)\.\d+$")
SRC_SINGLE_RE = re.compile(r"^(.*):(\d+)\.\d+$")


def split_into_blocks(report_text: str):
    """Split a report file into one chunk per 'Startpoint:' occurrence."""
    lines = report_text.splitlines()
    blocks, current = [], []
    for line in lines:
        if line.startswith("Startpoint:") and current:
            blocks.append(current)
            current = []
        current.append(line)
    if current:
        blocks.append(current)
    return [b for b in blocks if any(l.startswith("Startpoint:") for l in b)]


def parse_block(lines):
    path = {
        "startpoint": None,
        "endpoint": None,
        "path_group": None,
        "path_type": None,
        "slack_ns": None,
        "violated": None,
        "instances": [],
    }
    seen_instances = {}  # name -> cell_type, keeps first-seen order

    for line in lines:
        for key, rx in HEADER_RE.items():
            m = rx.match(line.strip())
            if m:
                path[key] = m.group(1)

        m = SLACK_RE.search(line)
        if m:
            path["slack_ns"] = float(m.group(1))
            path["violated"] = m.group(2) == "VIOLATED"

        m = ROW_RE.search(line)
        if m:
            delay = float(m.group(1))
            arrival = float(m.group(2))
            inst_name, _pin, cell_type = m.group(3), m.group(4), m.group(5)
            # full_clock_expanded prints two rows per cell: the input pin
            # (delay 0) and the output pin (the real stage delay). Keep
            # first-seen order, but take the largest delay/arrival seen.
            if inst_name not in seen_instances:
                seen_instances[inst_name] = {
                    "cell_type": cell_type,
                    "delay_ns": delay,
                    "arrival_ns": arrival,
                }
            else:
                e = seen_instances[inst_name]
                e["delay_ns"] = max(e["delay_ns"], delay)
                e["arrival_ns"] = max(e["arrival_ns"], arrival)

    path["instances"] = [
        {"name": name, "cell_type": d["cell_type"],
         "delay_ns": d["delay_ns"], "arrival_ns": d["arrival_ns"]}
        for name, d in seen_instances.items()
    ]

    # flag stages whose delay is dominated by drive strength / fanout rather
    # than logic depth - see fanout_outlier() for why these are excluded
    path["fanout_outlier"] = fanout_outlier(path)
    return path


def fanout_outlier(path):
    """
    Return the worst offending stage if any single gate on this path exceeds
    MAX_STAGE_NS, else None.

    A synthesis-only flow (yosys + abc) performs no buffer insertion or
    drive-strength sizing, so a gate driving hundreds of loads is modelled
    with a delay orders of magnitude above a normal stage. Those violations
    are artifacts of stopping before physical synthesis: no RTL restructuring
    can fix them, and handing them to the optimiser produces meaningless
    fixes. They are recorded and excluded rather than silently dropped.
    """
    worst = None
    for inst in path["instances"]:
        d = inst.get("delay_ns")
        if d is not None and d > MAX_STAGE_NS:
            if worst is None or d > worst["delay_ns"]:
                worst = inst
    return None if worst is None else {
        "name": worst["name"],
        "cell_type": worst["cell_type"],
        "delay_ns": worst["delay_ns"],
    }


def find_src_for_instance(netlist_lines, instance_name):
    """
    Look for `<instance_name> (` on a line, then check the line(s) directly
    above it for a `(* src = "..." *)` attribute. Returns (file, start, end)
    or None.
    """
    inst_decl_re = re.compile(r"\b" + re.escape(instance_name) + r"\s*\(")
    for i, line in enumerate(netlist_lines):
        if inst_decl_re.search(line):
            # scan a few lines upward for the attribute
            for j in range(max(0, i - 3), i):
                m = SRC_ATTR_RE.search(netlist_lines[j])
                if m:
                    src = m.group(1)
                    sm = SRC_SPAN_RE.match(src)
                    if sm:
                        return sm.group(1), int(sm.group(2)), int(sm.group(3))
                    sm = SRC_SINGLE_RE.match(src)
                    if sm:
                        ln = int(sm.group(2))
                        return sm.group(1), ln, ln
            return None  # instance found, but no src tag directly above it
    return None  # instance name never found in netlist (shouldn't happen)


def extract_rtl_snippet(repo_root: Path, src_file: str, start: int, end: int):
    span = end - start + 1
    full_path = repo_root / src_file
    if not full_path.exists():
        return None, True  # (snippet, truncated) - file not found

    if span > MAX_SNIPPET_LINES:
        return None, True  # too large to hand an LLM as "local" context

    lines = full_path.read_text(errors="replace").splitlines()
    # start/end are 1-indexed
    snippet = lines[start - 1 : end]
    return snippet, False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--report", required=True, help="OpenSTA report_checks output file")
    ap.add_argument("--netlist", required=True, help="Gate-level netlist (written WITHOUT -noattr)")
    ap.add_argument("--repo-root", default=".", help="Root to resolve src file paths against")
    ap.add_argument("--out", default="-", help="Output JSON path, or '-' for stdout")
    ap.add_argument("--excluded-out", default=None,
                    help="Write fanout-artifact paths here instead of --out "
                         "(default: <out stem>_excluded.json when --out is a file)")
    ap.add_argument("--no-filter", action="store_true",
                    help="Keep fanout-artifact paths in the main output")
    args = ap.parse_args()

    report_path = Path(args.report)
    netlist_path = Path(args.netlist)
    repo_root = Path(args.repo_root)

    if not report_path.exists():
        sys.exit(f"Report file not found: {report_path}")
    if not netlist_path.exists():
        sys.exit(f"Netlist file not found: {netlist_path}")

    report_text = report_path.read_text(errors="replace")
    netlist_lines = netlist_path.read_text(errors="replace").splitlines()

    blocks = split_into_blocks(report_text)
    if not blocks:
        sys.exit("No 'Startpoint:' blocks found - is this a report_checks output file?")

    results = []
    for block in blocks:
        path = parse_block(block)
        for inst in path["instances"]:
            src = find_src_for_instance(netlist_lines, inst["name"])
            if src is None:
                inst["src_file"] = None
                inst["src_start_line"] = None
                inst["src_end_line"] = None
                inst["rtl_snippet"] = None
                inst["truncated"] = False
                continue
            src_file, start, end = src
            snippet, truncated = extract_rtl_snippet(repo_root, src_file, start, end)
            inst["src_file"] = src_file
            inst["src_start_line"] = start
            inst["src_end_line"] = end
            inst["rtl_snippet"] = snippet
            inst["truncated"] = truncated
        results.append(path)

    if args.no_filter:
        kept, excluded = results, []
    else:
        kept = [p for p in results if not p["fanout_outlier"]]
        excluded = [p for p in results if p["fanout_outlier"]]

    out_json = json.dumps(kept, indent=2)
    if args.out == "-":
        print(out_json)
    else:
        Path(args.out).write_text(out_json)
        print(f"Wrote {len(kept)} path(s) to {args.out}", file=sys.stderr)

    if excluded:
        if args.excluded_out:
            exc_path = Path(args.excluded_out)
        elif args.out != "-":
            p = Path(args.out)
            exc_path = p.with_name(p.stem + "_excluded" + p.suffix)
        else:
            exc_path = None

        print(f"Excluded {len(excluded)} path(s) as fanout artifacts "
              f"(single stage > {MAX_STAGE_NS} ns):", file=sys.stderr)
        for p in excluded:
            o = p["fanout_outlier"]
            print(f"  {p['path_group']:<12} slack={p['slack_ns']:>10}  "
                  f"{o['name']} ({o['cell_type']}) = {o['delay_ns']} ns",
                  file=sys.stderr)
        if exc_path:
            exc_path.write_text(json.dumps(excluded, indent=2))
            print(f"  -> {exc_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
