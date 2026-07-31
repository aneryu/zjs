#!/usr/bin/env python3
"""P7-40 exact dynamic-count instrument.

A gdb breakpoint with an unreachable ignore count never stops the inferior, so
the program runs to completion and `info breakpoints` then reports the exact
hit count of each named function. The same instrument is pointed at both
engines and neither engine's source is touched. Counting runs are not timed and
therefore do not take the exclusive host lock.

Counts are reported raw and net of the same binary running `count_baseline.js`,
so realm bootstrap is subtracted out.
"""

import argparse
import json
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")

QJS_SYMS = [
    "js_array_every",           # the map/forEach/every builtin body
    "JS_ArraySpeciesCreate",    # result-array construction entry
    "JS_ArraySpeciesGetCtor",   # species / constructor lookup
    "js_array_constructor",     # the actual result Array(len) construction
    "JS_GetPropertyInternal",   # generic property lookup (species chain walk)
    "JS_HasProperty",           # per-element hole check
    "JS_GetPropertyValue",      # per-element source get
    "JS_CallInternal",          # ordinary JS frame setup/return
    "JS_DefinePropertyValueValue",  # per-element result define
    "expand_fast_array",        # result array storage growth
    "convert_fast_array_to_array",  # dense -> sparse transition
    "js_closure",               # closure instantiation
    "js_call_c_function",       # builtin (C function) invocation
    "js_realloc2",              # result-array storage reallocation
    "js_def_malloc",            # allocations
]

ZJS_SYMS = [
    "exec.array_ops.qjsArrayIterationModeCall__anon_85051",
    "exec.array_ops.qjsArrayIterationModeCall__anon_85047",
    "exec.array_ops.arraySpeciesCreate",
    "exec.array_ops.arrayHasDefaultSpecies",
    "core.object.Object.getOwnProperty",
    "core.object.Object.createArray",
    "exec.object_ops.hasValueProperty",
    "core.object.Object.getDenseArrayElementValue",
    "exec.call_runtime.SyncInternalCallSite.call",
    "exec.inline_calls.Machine.pushFrame__anon_68561",
    "exec.inline_calls.Machine.pushFrame__anon_68568",
    "exec.inline_calls.Machine.pushFrame__anon_87519",
    "core.object.Object.defineDenseArrayDataPropertyUnchecked",
    "core.object.Object.appendUninitializedFastArraySlot",
    "exec.zjs_vm.runActiveInvocationUntilNativeBoundary",
    "exec.call_runtime.runSyncInlineRouteOwnedCopy",
    "exec.call_runtime.callValueOrBytecodeDispatchAfterInterruptPoll",
    "exec.frame.FrameSlab.carve",
    "exec.frame.FrameSlab.allocHeap",
    "core.memory.SmallObjectSlab.addArena",
    "malloc",
]


def run_gdb(binary, script, symbols):
    args = ["gdb", "-batch", "-nx",
            "-ex", "set confirm off",
            "-ex", "set pagination off",
            "-ex", "set breakpoint pending on"]
    for i, sym in enumerate(symbols, start=1):
        args += ["-ex", f"break {sym}", "-ex", f"ignore {i} 1000000000"]
    args += ["-ex", "run", "-ex", "info breakpoints",
             "--args", binary, script]
    proc = subprocess.run(args, capture_output=True, text=True)
    text = proc.stdout
    counts = {s: 0 for s in symbols}
    current = None
    for line in text.splitlines():
        m = re.match(r"^(\d+)\s+breakpoint", line)
        if m:
            current = int(m.group(1))
            continue
        m = re.search(r"breakpoint already hit (\d+) time", line)
        if m and current is not None and 1 <= current <= len(symbols):
            counts[symbols[current - 1]] = int(m.group(1))
    return counts, text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zjs", default=os.path.join(HERE, "..", "..", "..",
                                                  "zig-out", "bin", "zjs"))
    ap.add_argument("--qjs", default="/home/aneryu/quickjs/qjs")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    engines = {"qjs": (os.path.abspath(args.qjs), QJS_SYMS),
               "zjs": (os.path.abspath(args.zjs), ZJS_SYMS)}
    cases = ["count_baseline", "count_map", "count_foreach"]
    out = {"instrument": "gdb breakpoint hit counts, ignore 1e9 (never stops)",
           "map_calls": 100, "elements_per_call": 10, "engines": {}}

    for eng, (binary, syms) in engines.items():
        raw = {}
        for case in cases:
            script = os.path.join(CASES, case + ".js")
            counts, _ = run_gdb(binary, script, syms)
            raw[case] = counts
            print(f"{eng:4s} {case:16s} " +
                  " ".join(f"{s.split('.')[-1]}={counts[s]}" for s in syms),
                  flush=True)
        net = {c: {s: raw[c][s] - raw["count_baseline"][s] for s in syms}
               for c in ("count_map", "count_foreach")}
        per_call = {c: {s: net[c][s] / 100.0 for s in syms} for c in net}
        out["engines"][eng] = {"binary": binary, "raw": raw, "net": net,
                               "per_map_or_foreach_call": per_call}

    with open(args.out, "w") as fh:
        json.dump(out, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
