#!/usr/bin/env python3
"""P7-50 exact dynamic-stage counter.

A gdb breakpoint whose ignore count is unreachable never stops the inferior, so
the program runs to completion and `info breakpoints` then reports each named
function's exact hit count. The same instrument is pointed at both engines and
neither engine's source is touched.

Per-op counts come from a *within-case* difference: the identical case source is
generated at two inner-loop sizes (N_lo and N_hi) and the per-op count is
(count(N_hi) - count(N_lo)) / (N_hi - N_lo). That removes realm bootstrap,
parse, module-level initialisation and the fixed part of one `run()` call
exactly, without needing a separate baseline case.

For the `retain` lifetime the phases are separated by the iteration count:
`--iterations 1 --warmup 0` executes one fill only (N creations, no release),
and `--iterations 2` adds one clear (N releases, no creation). Creation counts
therefore come from the iterations=1 pair and release counts from
(iterations=2) - (iterations=1).

Counting runs are not timed and do not take the exclusive host lock.
"""

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

ZJS_SYMS = [
    # wrapper creation
    "exec.object_ops.createBytecodeFunctionObjectInternal",
    "core.object.Object.create",
    "core.object.Object.allocFunctionPayload",
    "core.object.Object.setFunctionBytecodeValue",
    "exec.object_ops.bytecodeFunctionPrototypeForRealm",
    # captured environment / cells
    "exec.object_ops.attachFunctionCaptures",
    "core.var_ref.VarRef.createClosed__anon_31568",
    "core.var_ref.VarRef.destroyFromHeader__anon_60948",
    "exec.frame.ensureVarRefsCapacity",
    "exec.frame.Frame.ensureOpenVarRefSlots",
    "exec.frame.Frame.closeOpenVarRefs__anon_65974",
    # property / shape publication
    "core.object.Object.defineOwnProperty",
    "core.object.Object.defineOwnPropertyAssumingNew",
    "core.object.Object.adoptShapeForNewProperty",
    "core.object.Object.ensureUniqueShapeForMutation",
    "core.object.Object.ensurePropertyCapacity",
    "core.shape.Registry.createObjectRoot",
    "core.shape.Registry.cloneShape",
    "core.shape.Registry.prepareUpdate",
    "core.shape.Registry.createInitialShape",
    "core.shape.Registry.transitionPropertyUncached",
    "core.shape.Registry.destroyShape",
    "core.shape.Registry.release",
    "core.shape.Registry.ensureShapeHashCapacity",
    "exec.object_ops.installOrdinaryFunctionPrototype",
    "exec.call_runtime.functionNameValueFromAtom",
    # destruction / GC
    "core.object.Object.destroyFromHeader",
    "core.object.FunctionRarePayload.destroy",
    "core.gc.destroyZeroRef__anon_32430",
    "core.gc.destroyZeroRefNow__anon_61467",
    "core.value.JSValue.destroyZeroRef__anon_24255",
    "core.runtime.JSRuntime.pollGC",
    "core.gc.Registry.endDecrefPhase__anon_60972",
    # allocator. The per-object slab carve is inlined, so these are the
    # non-inlined allocation entries plus the arena refill rate (the analogue of
    # quickjs js_def_malloc, not of js_malloc).
    "core.memory.MemoryAccount.allocAlignedBytesNoTrigger",
    "core.memory.MemoryAccount.freeAlignedBytes",
    "core.memory.SmallObjectSlab.addArena",
    "core.memory.SmallObjectSlab.releaseEmptyArena",
    "malloc",
]

QJS_SYMS = [
    # wrapper creation
    "js_closure",
    "js_closure2.isra.0",
    "JS_NewObjectClass",
    "JS_NewObjectProtoClass",
    "JS_NewObjectFromShape",
    # captured environment / cells
    "get_var_ref",
    "js_create_var_ref",
    "free_var_ref",
    "close_var_refs",
    # property / shape publication
    "js_function_set_properties",
    "JS_DefinePropertyValue",
    "add_property",
    "add_shape_property",
    "find_hashed_shape_prop",
    "find_hashed_shape_proto",
    "js_clone_shape",
    "js_shape_prepare_update",
    "js_new_shape2.constprop.0",
    "js_free_shape",
    "resize_properties",
    "JS_AtomToString",
    # destruction / GC
    "js_bytecode_function_finalizer",
    "__JS_FreeValueRT",
    "free_gc_object",
    "JS_RunGC",
    "gc_free_cycles",
    # allocator. js_def_malloc is only the ARENA REFILL rate in this build
    # (quickjs carries its own arena: js_malloc_new_arena / js_malloc_large), so
    # the per-object allocation count is js_malloc/js_mallocz/js_free, not
    # js_def_malloc.
    "js_malloc",
    "js_mallocz",
    "js_realloc",
    "js_free",
    "js_def_malloc",
    "js_def_realloc",
    "js_realloc2",
]


def run_gdb(binary, case_name, source, iterations, warmup, symbols):
    args = ["gdb", "-batch", "-nx",
            "-ex", "set confirm off",
            "-ex", "set pagination off",
            "-ex", "set breakpoint pending on"]
    for index, sym in enumerate(symbols, start=1):
        args += ["-ex", "break %s" % sym, "-ex", "ignore %d 2000000000" % index]
    args += ["-ex", "run", "-ex", "info breakpoints",
             "--args", binary,
             "--case", case_name, "--source", source,
             "--iterations", str(iterations), "--warmup", str(warmup),
             "--teardown", "normal"]
    proc = subprocess.run(args, capture_output=True, text=True, cwd=REPO)
    text = proc.stdout
    counts = {s: 0 for s in symbols}
    order = []
    current = None
    for line in text.splitlines():
        head = re.match(r"^(\d+)\s+breakpoint", line)
        if head:
            index = int(head.group(1))
            current = symbols[index - 1] if index - 1 < len(symbols) else None
            order.append(current)
            continue
        hit = re.search(r"breakpoint already hit (\d+) time", line)
        if hit and current is not None:
            counts[current] = int(hit.group(1))
    if not order:
        raise RuntimeError(
            "gdb produced no breakpoint table for %s: %s"
            % (binary, (proc.stdout + proc.stderr)[-3000:])
        )
    return counts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zjs", required=True)
    parser.add_argument("--qjs", required=True)
    parser.add_argument("--lo-dir", required=True,
                        help="generated cases dir with the small N")
    parser.add_argument("--hi-dir", required=True,
                        help="generated cases dir with the large N")
    parser.add_argument("--lo-n", type=int, required=True)
    parser.add_argument("--hi-n", type=int, required=True)
    parser.add_argument("--shapes", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    shapes = [s for s in args.shapes.split(",") if s]
    delta_n = args.hi_n - args.lo_n
    engines = {"zjs": (args.zjs, ZJS_SYMS), "qjs": (args.qjs, QJS_SYMS)}

    out = {
        "line": "P7-50",
        "instrument": "gdb unreachable-ignore-count breakpoint hit counts",
        "lo_n": args.lo_n,
        "hi_n": args.hi_n,
        "raw": {},
        "per_op": {},
    }

    for shape in shapes:
        for lifetime in ("retain", "churn"):
            case = "closure_%s_%s" % (shape, lifetime)
            # retain: iterations 1 = one fill only; iterations 2 = fill+clear.
            # churn: one call already contains creation and release.
            iter_plan = [1, 2] if lifetime == "retain" else [1]
            for iters in iter_plan:
                for engine, (binary, syms) in engines.items():
                    for size, cases_dir in (("lo", args.lo_dir),
                                            ("hi", args.hi_dir)):
                        source = os.path.join(cases_dir, case + ".js")
                        key = "%s|%s|it%d|%s|%s" % (case, engine, iters, size,
                                                    "gdb")
                        counts = run_gdb(binary, case, source, iters, 0, syms)
                        out["raw"][key] = counts
                        print("counted %s" % key, file=sys.stderr)

    for shape in shapes:
        for lifetime in ("retain", "churn"):
            case = "closure_%s_%s" % (shape, lifetime)
            for engine, (_binary, syms) in engines.items():
                def per_op(iters):
                    lo = out["raw"]["%s|%s|it%d|lo|gdb" % (case, engine, iters)]
                    hi = out["raw"]["%s|%s|it%d|hi|gdb" % (case, engine, iters)]
                    return {s: (hi[s] - lo[s]) / delta_n for s in syms}

                if lifetime == "retain":
                    create = per_op(1)
                    both = per_op(2)
                    out["per_op"]["%s|%s|create" % (case, engine)] = create
                    out["per_op"]["%s|%s|create_plus_release" % (case, engine)] = both
                    out["per_op"]["%s|%s|release" % (case, engine)] = {
                        s: both[s] - create[s] for s in syms
                    }
                else:
                    out["per_op"]["%s|%s|create_plus_release" % (case, engine)] = \
                        per_op(1)

    with open(args.out, "w") as handle:
        json.dump(out, handle, indent=1)
    print(args.out)


if __name__ == "__main__":
    main()
