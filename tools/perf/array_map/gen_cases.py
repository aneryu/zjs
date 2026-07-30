#!/usr/bin/env python3
"""Generate the P7-40 array-map decomposition case corpus.

Every case is a standalone script for both engines. The ladder is written so
that adjacent rungs differ by exactly one mechanism, and every rung except the
two `*_toplevel` cases keeps its bindings function-local: P7-20 recorded that
top-level lexical binding access is itself a zjs/qjs divergence
(`prop_read_mono` 1.234 against `prop_read_mono_loop` 0.874), so a ladder built
on top-level bindings would fold that tax into every rung.

Run: python3 tools/perf/array_map/gen_cases.py
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")

N = 100000       # outer iterations for the len-10 ladder
N_LONG = 10000   # outer iterations for the len-100 cases (10x the element work)
N_ORIG = 10000   # the P7-20 microbench iteration count
N_PERF = 1000000 # perf-record-only twins, long enough for dense sampling

ARR10 = "[1,2,3,4,5,6,7,8,9,10]"


def arr(n):
    return "[" + ",".join(str(i + 1) for i in range(n)) + "]"


def wrap(body, sink="t"):
    """Function-local wrapper: all bindings live in run()'s frame."""
    return "function run() {\n" + body + "\n  return " + sink + ";\n}\nprint(run());\n"


def case(name, text):
    with open(os.path.join(CASES, name + ".js"), "w") as fh:
        fh.write(text)
    return name


def main():
    os.makedirs(CASES, exist_ok=True)
    written = []

    # ---- rung 0: process baseline -------------------------------------------
    written.append(case("baseline", "print(0);\n"))

    # ---- rung 1-2: loop scaffolding -----------------------------------------
    written.append(case("loop_outer", wrap(
        f"  let t = 0;\n"
        f"  for (let i = 0; i < {N}; i++) {{ t = i; }}")))

    written.append(case("loop_nested", wrap(
        f"  let t = 0;\n"
        f"  for (let i = 0; i < {N}; i++) {{\n"
        f"    for (let j = 0; j < 10; j++) {{ t = j; }}\n"
        f"  }}")))

    # ---- rung 3-5: per-element property machinery, no call, no allocation ----
    written.append(case("elem_get", wrap(
        f"  const a = {ARR10};\n"
        f"  let t = 0;\n"
        f"  for (let i = 0; i < {N}; i++) {{\n"
        f"    for (let j = 0; j < 10; j++) {{ t = a[j]; }}\n"
        f"  }}")))

    written.append(case("elem_getset", wrap(
        f"  const a = {ARR10};\n"
        f"  const out = new Array(10);\n"
        f"  for (let i = 0; i < {N}; i++) {{\n"
        f"    for (let j = 0; j < 10; j++) {{ out[j] = a[j]; }}\n"
        f"  }}\n"
        f"  const t = out[9];", sink="t")))

    written.append(case("elem_getset_add", wrap(
        f"  const a = {ARR10};\n"
        f"  const out = new Array(10);\n"
        f"  for (let i = 0; i < {N}; i++) {{\n"
        f"    for (let j = 0; j < 10; j++) {{ out[j] = a[j] + 1; }}\n"
        f"  }}\n"
        f"  const t = out[9];", sink="t")))

    # ---- rung 6-7: callback invocation --------------------------------------
    written.append(case("elem_getcall", wrap(
        f"  const a = {ARR10};\n"
        f"  const f = (x) => x + 1;\n"
        f"  let t = 0;\n"
        f"  for (let i = 0; i < {N}; i++) {{\n"
        f"    for (let j = 0; j < 10; j++) {{ t = f(a[j]); }}\n"
        f"  }}")))

    written.append(case("elem_getcallset", wrap(
        f"  const a = {ARR10};\n"
        f"  const f = (x) => x + 1;\n"
        f"  const out = new Array(10);\n"
        f"  for (let i = 0; i < {N}; i++) {{\n"
        f"    for (let j = 0; j < 10; j++) {{ out[j] = f(a[j]); }}\n"
        f"  }}\n"
        f"  const t = out[9];", sink="t")))

    # ---- rung 8-10: result-array construction -------------------------------
    written.append(case("alloc_only", wrap(
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N}; i++) {{ out = new Array(10); }}\n"
        f"  const t = out.length;", sink="t")))

    written.append(case("alloc_fill", wrap(
        f"  const a = {ARR10};\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N}; i++) {{\n"
        f"    out = new Array(10);\n"
        f"    for (let j = 0; j < 10; j++) {{ out[j] = a[j] + 1; }}\n"
        f"  }}\n"
        f"  const t = out[9];", sink="t")))

    written.append(case("alloc_getcallset", wrap(
        f"  const a = {ARR10};\n"
        f"  const f = (x) => x + 1;\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N}; i++) {{\n"
        f"    out = new Array(10);\n"
        f"    for (let j = 0; j < 10; j++) {{ out[j] = f(a[j]); }}\n"
        f"  }}\n"
        f"  const t = out[9];", sink="t")))

    # ---- rung 11: per-iteration closure allocation --------------------------
    written.append(case("closure_only", wrap(
        f"  let g = null;\n"
        f"  for (let i = 0; i < {N}; i++) {{ g = (x) => x + 1; }}\n"
        f"  const t = g(1);", sink="t")))

    # ---- rung 12+: the builtin itself ---------------------------------------
    written.append(case("map_inline_arrow", wrap(
        f"  const a = {ARR10};\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N}; i++) {{ out = a.map((x) => x + 1); }}\n"
        f"  const t = out[9];", sink="t")))

    written.append(case("map_pre_arrow", wrap(
        f"  const a = {ARR10};\n"
        f"  const f = (x) => x + 1;\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N}; i++) {{ out = a.map(f); }}\n"
        f"  const t = out[9];", sink="t")))

    written.append(case("map_decl_fn", wrap(
        f"  const a = {ARR10};\n"
        f"  function g(x) {{ return x + 1; }}\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N}; i++) {{ out = a.map(g); }}\n"
        f"  const t = out[9];", sink="t")))

    written.append(case("map_identity", wrap(
        f"  const a = {ARR10};\n"
        f"  const id = (x) => x;\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N}; i++) {{ out = a.map(id); }}\n"
        f"  const t = out[9];", sink="t")))

    written.append(case("foreach_pre_arrow", wrap(
        f"  const a = {ARR10};\n"
        f"  const f = (x) => x + 1;\n"
        f"  let t = 0;\n"
        f"  for (let i = 0; i < {N}; i++) {{ a.forEach(f); t = i; }}")))

    # ---- length sweep: intercept/slope --------------------------------------
    written.append(case("map_len0", wrap(
        f"  const a = [];\n"
        f"  const f = (x) => x + 1;\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N}; i++) {{ out = a.map(f); }}\n"
        f"  const t = out.length;", sink="t")))

    written.append(case("map_len1", wrap(
        f"  const a = [1];\n"
        f"  const f = (x) => x + 1;\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N}; i++) {{ out = a.map(f); }}\n"
        f"  const t = out[0];", sink="t")))

    written.append(case("map_len100", wrap(
        f"  const a = {arr(100)};\n"
        f"  const f = (x) => x + 1;\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N_LONG}; i++) {{ out = a.map(f); }}\n"
        f"  const t = out[99];", sink="t")))

    written.append(case("foreach_len0", wrap(
        f"  const a = [];\n"
        f"  const f = (x) => x + 1;\n"
        f"  let t = 0;\n"
        f"  for (let i = 0; i < {N}; i++) {{ a.forEach(f); t = i; }}")))

    written.append(case("foreach_len1", wrap(
        f"  const a = [1];\n"
        f"  const f = (x) => x + 1;\n"
        f"  let t = 0;\n"
        f"  for (let i = 0; i < {N}; i++) {{ a.forEach(f); t = i; }}")))

    written.append(case("foreach_len100", wrap(
        f"  const a = {arr(100)};\n"
        f"  const f = (x) => x + 1;\n"
        f"  let t = 0;\n"
        f"  for (let i = 0; i < {N_LONG}; i++) {{ a.forEach(f); t = i; }}")))

    # ---- the P7-20 case verbatim, and its function-local twin ---------------
    written.append(case("map_original_toplevel",
                        f"const a = {ARR10};\n"
                        f"let out;\n"
                        f"for (let i = 0; i < {N_ORIG}; i++) out = a.map(x => x + 1);\n"
                        f"print(out[9]);\n"))

    written.append(case("map_original_local", wrap(
        f"  const a = {ARR10};\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N_ORIG}; i++) out = a.map((x) => x + 1);\n"
        f"  const t = out[9];", sink="t")))

    # small-N variants used only for exact dynamic counting under gdb
    written.append(case("count_map", wrap(
        f"  const a = {ARR10};\n"
        f"  const f = (x) => x + 1;\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < 100; i++) {{ out = a.map(f); }}\n"
        f"  const t = out[9];", sink="t")))

    written.append(case("count_foreach", wrap(
        f"  const a = {ARR10};\n"
        f"  const f = (x) => x + 1;\n"
        f"  let t = 0;\n"
        f"  for (let i = 0; i < 100; i++) {{ a.forEach(f); t = i; }}")))

    written.append(case("count_baseline", "print(0);\n"))

    # long-running twins used only for perf-record symbol attribution; they are
    # excluded from the timing ladder (run_decomp.py skips the perf_ prefix)
    perf_only = []
    perf_only.append(case("perf_map_long", wrap(
        f"  const a = {ARR10};\n"
        f"  const f = (x) => x + 1;\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N_PERF}; i++) {{ out = a.map(f); }}\n"
        f"  const t = out[9];", sink="t")))
    perf_only.append(case("perf_foreach_long", wrap(
        f"  const a = {ARR10};\n"
        f"  const f = (x) => x + 1;\n"
        f"  let t = 0;\n"
        f"  for (let i = 0; i < {N_PERF}; i++) {{ a.forEach(f); t = i; }}")))
    perf_only.append(case("perf_map_inline_long", wrap(
        f"  const a = {ARR10};\n"
        f"  let out = null;\n"
        f"  for (let i = 0; i < {N_PERF}; i++) {{ out = a.map((x) => x + 1); }}\n"
        f"  const t = out[9];", sink="t")))
    written.extend(perf_only)

    meta = {
        "N": N,
        "N_LONG": N_LONG,
        "N_ORIG": N_ORIG,
        "iterations": {
            name: (N_LONG if name.endswith("_len100")
                   else N_ORIG if name.startswith("map_original")
                   else N_PERF if name.startswith("perf_")
                   else 100 if name.startswith("count_")
                   else 0 if name in ("baseline",)
                   else N)
            for name in written
        },
        "elements_per_iteration": {
            "map_len0": 0, "foreach_len0": 0,
            "map_len1": 1, "foreach_len1": 1,
            "map_len100": 100, "foreach_len100": 100,
        },
        "perf_only": ["perf_map_long", "perf_foreach_long",
                      "perf_map_inline_long"],
        "cases": written,
    }
    with open(os.path.join(HERE, "cases.json"), "w") as fh:
        json.dump(meta, fh, indent=1)
        fh.write("\n")
    print(f"wrote {len(written)} cases")


if __name__ == "__main__":
    main()
