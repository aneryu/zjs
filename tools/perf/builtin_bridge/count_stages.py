#!/usr/bin/env python3
"""P7-42 exact dynamic hit counts per bridge stage, via gdb line breakpoints.

Same instrument as P7-41 §3 (unreachable ignore counts, then `info
breakpoints` for the exact hit count), narrowed to one representative line per
stage. Line breakpoints rather than symbol breakpoints because almost the whole
bridge is `inline fn`: no symbol exists, but every inlined copy still carries
DWARF line records, so gdb reports one `<MULTIPLE>` location set and sums the
hits across copies.

Not a timing instrument: no host lock, no pinning, results are counts only.
"""

import argparse
import json
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")

# stage -> representative source line that must execute once per callback
PROBES = [
    ("S1_callsite_entry_and_poll", "src/exec/call_runtime.zig:753"),
    ("S1b_active_invocation_check", "src/exec/call_runtime.zig:756"),
    ("S2_fence_scope_construct", "src/exec/inline_calls.zig:1019"),
    ("S2b_backtrace_view_segment", "src/exec/inline_calls.zig:1024"),
    ("S3_fence_publish", "src/exec/inline_calls.zig:1041"),
    ("S4_fast_push_dispatch", "src/exec/inline_calls.zig:3325"),
    ("S4a_empty_leaf_leg", "src/exec/inline_calls.zig:3361"),
    ("S4b_exact_args_leaf_leg", "src/exec/inline_calls.zig:3434"),
    ("S4c_arena_carve_leaf", "src/exec/inline_calls.zig:3445"),
    ("S5_argument_dup_window", "src/exec/inline_calls.zig:3456"),
    ("S6_entry_frame_publication", "src/exec/inline_calls.zig:3465"),
    ("S6b_entry_link", "src/exec/inline_calls.zig:3492"),
    ("S7_run_until_native_boundary", "src/exec/zjs_vm.zig:813"),
    ("S7b_vm_cache_rebuild", "src/exec/zjs_vm.zig:776"),
    ("S7c_run_prologue", "src/exec/tailcall_dispatch.zig:4302"),
    ("S8_native_boundary_return", "src/exec/tailcall_dispatch.zig:1198"),
    ("S9_fence_restore", "src/exec/inline_calls.zig:1100"),
    ("S10_return_to_builtin", "src/exec/call_runtime.zig:758"),
    ("X_fallback_dispatch", "src/exec/call_runtime.zig:770"),
    ("X_owned_copy_leg", "src/exec/call_runtime.zig:760"),
    ("X_cold_push_leg", "src/exec/call_runtime.zig:555"),
    ("X_fence_error_deinit", "src/exec/inline_calls.zig:1053"),
    ("C_exact_args_leaf_return", "src/exec/inline_calls.zig:4488"),
]


def run_gdb(binary, script, probes):
    cmds = ["set confirm off", "set pagination off", "set height 0"]
    for i, (_stage, loc) in enumerate(probes, start=1):
        cmds.append(f"break {loc}")
        cmds.append(f"ignore {i} 2000000000")
    cmds.append(f"run {script}")
    cmds.append("info breakpoints")
    cmds.append("quit")
    argv = ["gdb", "-batch", "-nx"]
    for c in cmds:
        argv += ["-ex", c]
    argv += ["--args", binary, script]
    proc = subprocess.run(argv, capture_output=True, text=True)
    return proc.stdout + proc.stderr


def parse(text, probes):
    """`info breakpoints` prints, per breakpoint, a trailing line
    `breakpoint already hit N times` (absent when N == 0)."""
    hits = {stage: 0 for stage, _ in probes}
    order = [stage for stage, _ in probes]
    cur = None
    for line in text.splitlines():
        m = re.match(r"^(\d+)\s+breakpoint", line)
        if m:
            idx = int(m.group(1)) - 1
            cur = order[idx] if 0 <= idx < len(order) else None
            continue
        m = re.search(r"breakpoint already hit (\d+) time", line)
        if m and cur is not None:
            hits[cur] = int(m.group(1))
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--cases", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    meta = json.load(open(os.path.join(HERE, "cases.json")))
    result = {"binary": os.path.abspath(args.binary),
              "probes": {s: l for s, l in PROBES},
              "cases": {}}
    for case in args.cases.split(","):
        script = os.path.join(CASES, case + ".js")
        text = run_gdb(args.binary, script, PROBES)
        hits = parse(text, PROBES)
        cbc = meta["callback_count"].get(case, 0)
        per = {k: (v / cbc if cbc else None) for k, v in hits.items()}
        result["cases"][case] = {"callback_count": cbc, "hits": hits,
                                 "hits_per_callback": per}
        print(f"--- {case} (callbacks={cbc})")
        for stage, _loc in PROBES:
            p = per[stage]
            print(f"    {stage:32s} {hits[stage]:9d}  "
                  f"{'n/a' if p is None else format(p, '.4f')}/callback")
    with open(args.out, "w") as fh:
        json.dump(result, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
