#!/usr/bin/env python3
"""
patch_schema.py - add `out_of_scope_fix` to FIX_SCHEMA in propose_fix.py.

Why: a `no_fix` currently says "I can't fix this here" in prose only. The
UART violation needed a human to read that prose and re-run with a different
--scope. This field makes the same information machine-readable so
escalate.py can act on it.

Run once, from the repo root:   python3 patch_schema.py
Idempotent - running twice is a no-op.
"""
from pathlib import Path
import sys

p = Path("propose_fix.py")
if not p.exists():
    sys.exit("run from the repo root (propose_fix.py not found)")

s = p.read_text()

if "out_of_scope_fix" in s:
    print("already patched - nothing to do")
    sys.exit(0)

Path("propose_fix.py.preescalate").write_text(s)

# ---- 1. schema field -------------------------------------------------------
old_props = """        "rationale": {"type": "string",
                      "description": "Strategy choice, cut location, and what "
                                     "was delayed to stay balanced."},
    },
    "required": ["fix_type", "target_module", "added_latency_cycles",
                 "modified_rtl", "rationale"],"""

new_props = """        "rationale": {"type": "string",
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
                 "modified_rtl", "rationale", "out_of_scope_fix"],"""

if s.count(old_props) != 1:
    sys.exit("schema block not found or ambiguous - patch by hand")
s = s.replace(old_props, new_props)

# ---- 2. prompt instruction -------------------------------------------------
old_prompt = '    L.append("\\n## RTL to modify\\n")'
new_prompt = '''    L.append("\\n## If the fix is not in your scope\\n")
    L.append("If you return no_fix because the dominant delay lies in RTL "
             "outside your edit scope, populate `out_of_scope_fix` with the "
             "file and line range where the fix belongs, so the scope can be "
             "widened and this violation retried. Base the location on the "
             "gate sequence even if you have not been shown that file; set "
             "confidence to 'low' when you have not. If no fix exists "
             "anywhere on this path - the path is already minimal, or a fix "
             "would change observable behaviour - set out_of_scope_fix to "
             "null. That is a real refusal and correctly ends the search. "
             "Do not name a file merely to avoid declining.\\n")

    L.append("\\n## RTL to modify\\n")'''

if s.count(old_prompt) != 1:
    sys.exit("prompt anchor not found - patch by hand")
s = s.replace(old_prompt, new_prompt)

# ---- 3. validator: a fix must not claim an out-of-scope location -----------
old_val = '''    if ft == "no_fix":'''
new_val = '''    oos = fix.get("out_of_scope_fix")
    if ft != "no_fix" and oos is not None:
        errors.append("out_of_scope_fix must be null unless fix_type is no_fix")
    if oos is not None:
        if not (oos.get("src_file") or "").endswith((".v", ".sv")):
            errors.append(f"out_of_scope_fix.src_file is not RTL: "
                          f"{oos.get('src_file')!r}")
        if oos.get("start_line", 0) > oos.get("end_line", 0):
            errors.append("out_of_scope_fix line range is inverted")

    if ft == "no_fix":'''

if s.count(old_val) != 1:
    sys.exit("validator anchor not found - patch by hand")
s = s.replace(old_val, new_val)

# ---- 4. --scope-file: let a caller name the edit-scope file explicitly ------
old_flag = ('    p.add_argument("--scope-from-endpoint", action="store_true",')
new_flag = ('    p.add_argument("--scope-file", default=None, metavar="PATH",\n'
            '                   help="force the edit scope to this file "\n'
            '                        "(used by escalate.py)")\n'
            '    p.add_argument("--scope-from-endpoint", action="store_true",')
if s.count(old_flag) != 1:
    sys.exit("--scope-from-endpoint flag not found; apply the earlier patch first")
s = s.replace(old_flag, new_flag)

old_sel = "    a = attributed[-1] if scope_from_endpoint else attributed[0]"
new_sel = ("    if scope_file:\n"
           "        m = [x for x in attributed if x.get('src_file') == scope_file]\n"
           "        a = m[0] if m else dict(src_file=scope_file,\n"
           "                                src_start_line=1, src_end_line=10**6)\n"
           "    else:\n"
           "        a = attributed[-1] if scope_from_endpoint else attributed[0]")
if s.count(old_sel) != 1:
    sys.exit("scope selector not found")
s = s.replace(old_sel, new_sel)

old_sig = "              scope_from_endpoint=False, context_files=None):"
new_sig = ("              scope_from_endpoint=False, context_files=None,\n"
           "              scope_file=None):")
s = s.replace(old_sig, new_sig)

old_call = "                      context_files=a.context_file)"
new_call = ("                      context_files=a.context_file,\n"
            "                      scope_file=a.scope_file)")
s = s.replace(old_call, new_call)

p.write_text(s)
import ast
ast.parse(s)
print("patched propose_fix.py  (backup: propose_fix.py.preescalate)")
print("  + schema field out_of_scope_fix")
print("  + prompt section telling the model when to populate it")
print("  + validator rules")
