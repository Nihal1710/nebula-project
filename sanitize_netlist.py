#!/usr/bin/env python3
"""
sanitize_netlist.py

OpenSTA's Verilog reader cannot parse *escaped identifiers* - names
starting with a backslash, e.g. `\\$paramod$<hash>\\fir_filter` (a
Yosys-generated parameterized-module clone) or
`\\u_fifo.fifomem.mem[0]` (a memory-array word after flattening).
Rather than fight Yosys pass-by-pass to prevent it from ever emitting
these, this script cleans them up generically as a text pass after
write_verilog - it doesn't matter which Yosys pass caused a given
escaped name, they're all fixed the same way.

Where a `(* hdlname = "..." *)` attribute appears directly above a
`module` declaration, that original clean name is reused (so a
paramod'd `fir_filter` becomes `fir_filter` again, not a mangled
hash). Everything else gets a straightforward sanitized name.

Usage:
    python3 sanitize_netlist.py in_netlist.v out_netlist.v
"""
import re
import sys
from pathlib import Path

ESCAPED_ID_RE = re.compile(r"\\(\S+)")
HDLNAME_RE = re.compile(r'hdlname\s*=\s*"([^"]+)"')
MODULE_DECL_RE = re.compile(r"^\s*module\s+(\\?\S+)")


def sanitize(raw: str) -> str:
    clean = re.sub(r"[^A-Za-z0-9_]", "_", raw)
    clean = re.sub(r"_+", "_", clean).strip("_")
    if not clean:
        clean = "id"
    if clean[0].isdigit():
        clean = "s_" + clean
    return clean


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: sanitize_netlist.py <in.v> <out.v>")

    text = Path(sys.argv[1]).read_text()
    lines = text.splitlines(keepends=True)

    # Pass 1: map escaped module names -> their original hdlname, if any
    module_hdlname = {}
    pending_hdlname = None
    for line in lines:
        m = HDLNAME_RE.search(line)
        if m:
            pending_hdlname = m.group(1)
            continue
        mm = MODULE_DECL_RE.match(line)
        if mm and pending_hdlname:
            module_hdlname[mm.group(1)] = pending_hdlname
        if not line.strip().startswith("(*"):
            pending_hdlname = None  # attribute only covers the very next line

    # Pass 2: replace every escaped identifier, consistently, everywhere
    seen = {}
    used = set()

    def repl(m):
        full = m.group(0)
        if full in seen:
            return seen[full]
        base = module_hdlname.get(full) or sanitize(m.group(1))
        candidate = base
        i = 1
        while candidate in used:
            candidate = f"{base}_{i}"
            i += 1
        used.add(candidate)
        seen[full] = candidate
        return candidate

    out_text = ESCAPED_ID_RE.sub(repl, text)

    # OpenSTA's structural Verilog reader appears not to accept the
    # `signed` type qualifier on wire/port declarations (it's a
    # behavioral/simulation-time annotation - by gate level, sign
    # handling is already implemented as real gates, so dropping the
    # keyword itself is safe and doesn't change circuit connectivity).
    out_text = re.sub(r"\bsigned\b", "", out_text)

    Path(sys.argv[2]).write_text(out_text)

    print(f"Renamed {len(seen)} escaped identifier(s):", file=sys.stderr)
    for orig, new in seen.items():
        print(f"  {orig}  ->  {new}", file=sys.stderr)


if __name__ == "__main__":
    main()
