#!/usr/bin/env python3
"""P7-41 exact dynamic-count instrument.

A gdb breakpoint with an unreachable ignore count never stops the inferior, so
the program runs to completion and `info breakpoints` then reports each named
function's exact hit count. The same instrument is pointed at both engines and
neither engine's source is touched. Counting runs are not timed and therefore
do not take the exclusive host lock.

Counts are reported raw and net of the same binary running `count_baseline.js`,
so realm bootstrap is subtracted out.

zjs symbol names carry Zig's `__anon_NNNNN` suffixes for generic
instantiations, and those numbers move with every build. They are therefore
resolved from the binary's own symbol table by regular expression instead of
being hardcoded (P7-40 hardcoded them and they have already changed).
"""

import argparse
import json
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")

QJS_SYMS = [
    # builtin bodies
    "js_array_every",
    "js_array_reduce",
    "js_call_c_function",
    # the callback bridge: qjs re-enters the same interpreter function
    "JS_Call",
    "JS_CallInternal",
    # per-element source machinery
    "JS_TryGetPropertyInt64",
    "JS_GetPropertyValue",
    "JS_HasProperty",
    # result machinery
    "JS_ArraySpeciesCreate",
    "js_array_constructor",
    "JS_DefinePropertyValueValue",
    "JS_SetPropertyValue",
    "expand_fast_array",
    "convert_fast_array_to_array",
    # allocation
    "js_def_malloc",
]

# (label, regular expression matched against the demangled zjs symbol table)
ZJS_SYM_PATTERNS = [
    # builtin bodies
    ("array_iteration_mode_call",
     r"^exec\.array_ops\.qjsArrayIterationModeCall__anon_\d+$"),
    ("array_reduce_call", r"^exec\.array_ops\.qjsArrayReduceCall$"),
    # the callback bridge
    ("callsite_call", r"^exec\.call_runtime\.SyncInternalCallSite\.call$"),
    ("native_fence_run",
     r"^exec\.zjs_vm\.runActiveInvocationUntilNativeBoundary$"),
    ("native_fence_error_run",
     r"^exec\.zjs_vm\.runActiveInvocationAfterNativeBoundaryError$"),
    ("native_boundary_scope_deinit",
     r"^exec\.inline_calls\.NativeBoundaryScope\.deinit$"),
    ("native_caller_release",
     r"^exec\.inline_calls\.Entry\.releaseNativeCaller$"),
    # new-Machine vs active-Machine reuse
    ("new_machine_run_with_call_env",
     r"^exec\.zjs_vm\.runWithCallEnvAfterInterruptPoll$"),
    ("run_tc", r"^exec\.zjs_vm\.runTC$"),
    # bridge argument / frame setup family
    ("boundary_setup_simple_entry",
     r"^exec\.inline_calls\.Machine\.setupNativeBoundarySimpleEntry__anon_\d+$"),
    ("boundary_push_copied_args_slow",
     r"^exec\.inline_calls\.Machine\.pushNativeBoundaryCopiedArgs$"),
    ("boundary_push_empty_slow",
     r"^exec\.inline_calls\.Machine\.pushNativeBoundaryEmpty$"),
    ("route_owned_copy",
     r"^exec\.call_runtime\.runSyncInlineRouteOwnedCopy$"),
    ("route_moved", r"^exec\.call_runtime\.runSyncInlineRouteMoved$"),
    ("route_moved_args",
     r"^exec\.call_runtime\.runSyncInlineRouteMovedArgs$"),
    ("frame_slab_carve", r"^exec\.frame\.FrameSlab\.carve$"),
    ("frame_slab_alloc_heap", r"^exec\.frame\.FrameSlab\.allocHeap$"),
    # generic fallback (must stay 0 for the fast leg to be the thing measured)
    ("generic_call_fallback",
     r"^exec\.call_runtime\.callValueOrBytecodeDispatchAfterInterruptPoll$"),
    ("call_root", r"^exec\.call_runtime\.callValueOrBytecodeRoot$"),
    # VM-level call/return family, identical callback body on both sides
    ("op_return", r"^exec\.tailcall_dispatch\.op_return$"),
    ("op_return_undef", r"^exec\.tailcall_dispatch\.op_return_undef$"),
    ("op_get_arg_short", r"^exec\.tailcall_dispatch\.op_get_arg_short$"),
    ("op_call_method", r"^exec\.tailcall_dispatch\.op_call_method$"),
    ("op_post_call_continuation",
     r"^exec\.tailcall_dispatch\.op_post_call_continuation$"),
    # per-element source machinery
    ("dense_element_read",
     r"^core\.object\.Object\.getDenseArrayElementValue$"),
    ("hole_check", r"^exec\.object_ops\.hasValueProperty$"),
    # result machinery
    ("species_probe", r"^exec\.array_ops\.arrayHasDefaultSpecies$"),
    ("species_create", r"^exec\.array_ops\.arraySpeciesCreate$"),
    ("create_array", r"^core\.object\.Object\.createArray$"),
    ("define_dense_unchecked",
     r"^core\.object\.Object\.defineDenseArrayDataPropertyUnchecked$"),
    # allocation
    ("malloc", r"^malloc$"),
]

# Stages of the bridge that LLVM inlined away, so no symbol exists. They are
# reached through gdb's line table instead, which needs no source change: the
# `inline fn` bodies still carry line records at every inlined copy, and gdb
# reports one `<MULTIPLE>` breakpoint whose hit count is the sum over copies.
# Each entry is (label, file:line, expected source text) and the expected text
# is re-read from the working tree and recorded, so a later line-number drift
# is visible in the artifact rather than silently mismeasured.
ZJS_LINE_BREAKPOINTS = [
    ("fence_scope_init", "call_runtime.zig", 545),
    # the publication store inside NativeBoundaryScope.push. `call_runtime.zig`
    # line 546 (`boundary.push();`) resolves to an address that is never
    # executed, so the count is taken inside the callee's own body instead.
    ("native_caller_publish", "inline_calls.zig", 1047),
    # NativeBoundaryScope.finish -> popBacktrace. popBacktrace is shared with
    # the error-only `deinit`, whose own count is reported separately and is 0,
    # so this equals the successful fence release count.
    ("fence_release_finish", "inline_calls.zig", 1091),
    ("return_special_check", "tailcall_dispatch.zig", 1197),
    ("special_return_native_boundary_arm", "tailcall_dispatch.zig", 1199),
]


def resolve_zjs_symbols(binary):
    """Map each label to the concrete symbol names present in this binary."""
    out = subprocess.run(["nm", "-C", binary], capture_output=True, text=True)
    names = set()
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            names.add(parts[2])
        elif len(parts) == 2:
            names.add(parts[1])
    resolved = {}
    for label, pattern in ZJS_SYM_PATTERNS:
        rx = re.compile(pattern)
        hits = sorted(n for n in names if rx.match(n))
        resolved[label] = hits
    return resolved


def run_gdb(binary, script, locations):
    """`locations` is an ordered list of gdb linespecs (symbol or file:line)."""
    args = ["gdb", "-batch", "-nx",
            "-ex", "set confirm off",
            "-ex", "set pagination off",
            "-ex", "set breakpoint pending on"]
    for i, loc in enumerate(locations, start=1):
        args += ["-ex", f"break {loc}", "-ex", f"ignore {i} 2000000000"]
    args += ["-ex", "run", "-ex", "info breakpoints", "--args", binary, script]
    proc = subprocess.run(args, capture_output=True, text=True)
    counts = {s: 0 for s in locations}
    current = None
    for line in proc.stdout.splitlines():
        m = re.match(r"^(\d+)\s+breakpoint", line)
        if m:
            current = int(m.group(1))
            continue
        m = re.search(r"breakpoint already hit (\d+) time", line)
        if m and current is not None and 1 <= current <= len(locations):
            counts[locations[current - 1]] = int(m.group(1))
    return counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zjs", required=True)
    ap.add_argument("--qjs", default="/home/aneryu/quickjs/qjs")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    meta = json.load(open(os.path.join(HERE, "cases.json")))
    cases = [c for c in meta["count_only"]]
    zjs = os.path.abspath(args.zjs)
    qjs = os.path.abspath(args.qjs)

    resolved = resolve_zjs_symbols(zjs)
    zjs_syms = []
    label_of = {}
    for label, hits in resolved.items():
        for h in hits:
            zjs_syms.append(h)
            label_of[h] = label
    missing = [lbl for lbl, hits in resolved.items() if not hits]

    # line-table locations for the inlined bridge stages
    src_root = os.path.join(HERE, "..", "..", "..", "src", "exec")
    line_records = []
    for label, fname, line in ZJS_LINE_BREAKPOINTS:
        path = os.path.abspath(os.path.join(src_root, fname))
        with open(path) as fh:
            text = fh.read().splitlines()
        loc = f"{fname}:{line}"
        zjs_syms.append(loc)
        label_of[loc] = label
        line_records.append({"label": label, "location": loc,
                             "source_text": text[line - 1].strip()})

    out = {
        "instrument": "gdb breakpoint hit counts, ignore 2e9 (never stops)",
        "builtin_calls_per_case": 100,
        "elements_per_call": meta["LEN"],
        "callbacks_per_case": 100 * meta["LEN"],
        "zjs_symbol_resolution": resolved,
        "zjs_unresolved_labels": missing,
        "zjs_line_breakpoints": line_records,
        "engines": {},
    }

    for eng, binary, syms in (("qjs", qjs, QJS_SYMS), ("zjs", zjs, zjs_syms)):
        raw = {}
        for case in cases:
            script = os.path.join(CASES, case + ".js")
            raw[case] = run_gdb(binary, script, syms)
            print(f"{eng:4s} {case:20s} done", flush=True)
        base = raw["count_baseline"]
        net = {c: {s: raw[c][s] - base[s] for s in syms}
               for c in cases if c != "count_baseline"}
        if eng == "zjs":
            # fold the per-symbol counts up to the labels
            folded = {}
            for c, d in net.items():
                agg = {}
                for s, v in d.items():
                    agg[label_of[s]] = agg.get(label_of[s], 0) + v
                folded[c] = agg
            per_cb = {c: {k: v / (100.0 * meta["LEN"])
                          for k, v in folded[c].items()} for c in folded}
            per_call = {c: {k: v / 100.0 for k, v in folded[c].items()}
                        for c in folded}
            out["engines"][eng] = {"binary": binary, "raw": raw, "net": net,
                                   "net_by_label": folded,
                                   "per_builtin_call": per_call,
                                   "per_callback": per_cb}
        else:
            per_cb = {c: {k: v / (100.0 * meta["LEN"]) for k, v in net[c].items()}
                      for c in net}
            per_call = {c: {k: v / 100.0 for k, v in net[c].items()}
                        for c in net}
            out["engines"][eng] = {"binary": binary, "raw": raw, "net": net,
                                   "per_builtin_call": per_call,
                                   "per_callback": per_cb}

    with open(args.out, "w") as fh:
        json.dump(out, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)
    if missing:
        print("UNRESOLVED zjs labels:", ", ".join(missing))


if __name__ == "__main__":
    main()
