#!/usr/bin/env python3
"""P7-42 case generator (additive; P7-41's cases are untouched).

Three families:

* `q_*`   long-running twins of P7-41's four no-write builtins and their
          mirrored controls, sized so one `perf record` collects >=100k samples
          without raising the sample rate near the kernel cap;
* `k_*`   callback-arity sweep. The builtin always hands the callee three
          actual arguments; only the callee's *declared* arity changes. That
          switches exactly one mechanism inside the bridge:
            arity 0 -> `Machine.tryPushNativeBoundaryEmptyFast`  (no argument
                       window is carved, no argument is duplicated)
            arity>0 -> `Machine.tryPushNativeBoundaryLeafArgsFast` (carves an
                       `arg_count`-wide window and duplicates min(3, arity)
                       values into it)
          The mirrored control passes three actuals at every arity too, so the
          callback ABI is identical across the whole sweep and between builtin
          and control.
* `g_*`   gdb-counting twins (few callbacks, so breakpoint counting finishes).

Every control is negation-free: P7-41 §2.4 measured one `!` on a mutable local
at ~18 cycles/element in zjs, which contaminated its first-round `every` rung.
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")

ARR = "[" + ",".join(str(i) for i in range(1, 101)) + "]"

PROLOGUE = """function run() {
  const a = %s;
  function cb_noop(v, i, arr) { }
  function cb_false(v, i, arr) { return false; }
  function cb_true(v, i, arr) { return true; }
  function cb_a0() { }
  function cb_a1(v) { }
  function cb_a2(v, i) { }
  function cb_a3(v, i, arr) { }
  function cb_a0f() { return false; }
  const LEN = 100;
  let t = 0;
""" % ARR

EPILOGUE = """  return t;
}
print(run());
"""

BODIES = {
    "foreach": {
        "builtin": "  for (let n = 0; n < %(N)d; n++) { a.forEach(%(CB)s); t = n; }\n",
        "control": ("  for (let n = 0; n < %(N)d; n++) {\n"
                    "    for (let j = 0; j < LEN; j++) { %(CB)s(a[j], j, a); }\n"
                    "    t = n;\n  }\n"),
    },
    "some": {
        "builtin": "  for (let n = 0; n < %(N)d; n++) { t = a.some(%(CB)s) ? 1 : 0; }\n",
        "control": ("  for (let n = 0; n < %(N)d; n++) {\n"
                    "    let hit = 0;\n"
                    "    for (let j = 0; j < LEN; j++) {\n"
                    "      if (%(CB)s(a[j], j, a)) { hit = 1; break; }\n"
                    "    }\n    t = hit;\n  }\n"),
    },
    "every": {
        "builtin": "  for (let n = 0; n < %(N)d; n++) { t = a.every(%(CB)s) ? 1 : 0; }\n",
        "control": ("  for (let n = 0; n < %(N)d; n++) {\n"
                    "    let hit = 1;\n"
                    "    for (let j = 0; j < LEN; j++) {\n"
                    "      if (%(CB)s(a[j], j, a)) { continue; }\n"
                    "      hit = 0; break;\n"
                    "    }\n    t = hit;\n  }\n"),
    },
    "filter_false": {
        "builtin": "  for (let n = 0; n < %(N)d; n++) { t = a.filter(%(CB)s).length; }\n",
        "control": ("  for (let n = 0; n < %(N)d; n++) {\n"
                    "    const out = [];\n    let m = 0;\n"
                    "    for (let j = 0; j < LEN; j++) {\n"
                    "      const v = a[j];\n"
                    "      if (%(CB)s(v, j, a)) { out[m] = v; m++; }\n"
                    "    }\n    t = out.length;\n  }\n"),
    },
}

CB_FOR = {"foreach": "cb_noop", "some": "cb_false",
          "every": "cb_true", "filter_false": "cb_false"}


def write(name, body):
    with open(os.path.join(CASES, name + ".js"), "w") as fh:
        fh.write(PROLOGUE + body + EPILOGUE)


def main():
    meta = json.load(open(os.path.join(HERE, "cases.json")))
    added = {}

    # --- q_*: long twins for perf record (5e5 * 100 = 5e7 callbacks) ---
    N_LONG = 500000
    for fam, tmpl in BODIES.items():
        cb = CB_FOR[fam]
        write("q_" + fam, tmpl["builtin"] % {"N": N_LONG, "CB": cb})
        write("q_c_" + fam, tmpl["control"] % {"N": N_LONG, "CB": cb})
        added["q_" + fam] = (N_LONG, 100, N_LONG * 100)
        added["q_c_" + fam] = (N_LONG, 100, N_LONG * 100)

    # --- g_*: short twins for gdb breakpoint counting (100 * 100 = 1e4) ---
    N_COUNT = 100
    for fam, tmpl in BODIES.items():
        cb = CB_FOR[fam]
        write("g_" + fam, tmpl["builtin"] % {"N": N_COUNT, "CB": cb})
        write("g_c_" + fam, tmpl["control"] % {"N": N_COUNT, "CB": cb})
        added["g_" + fam] = (N_COUNT, 100, N_COUNT * 100)
        added["g_c_" + fam] = (N_COUNT, 100, N_COUNT * 100)

    # --- k_*: callback-arity sweep on forEach, 1e4 * 100 = 1e6 callbacks ---
    N_SWEEP = 10000
    for arity in (0, 1, 2, 3):
        cb = f"cb_a{arity}"
        write(f"k_foreach_a{arity}",
              BODIES["foreach"]["builtin"] % {"N": N_SWEEP, "CB": cb})
        write(f"k_c_foreach_a{arity}",
              BODIES["foreach"]["control"] % {"N": N_SWEEP, "CB": cb})
        added[f"k_foreach_a{arity}"] = (N_SWEEP, 100, N_SWEEP * 100)
        added[f"k_c_foreach_a{arity}"] = (N_SWEEP, 100, N_SWEEP * 100)
    # arity-0 twin whose body returns false, so `some`/`filter` keep running
    # the whole array while taking the empty-leaf push leg.
    write("k_some_a0", BODIES["some"]["builtin"] % {"N": N_SWEEP, "CB": "cb_a0f"})
    write("k_c_some_a0", BODIES["some"]["control"] % {"N": N_SWEEP, "CB": "cb_a0f"})
    write("k_some_a3", BODIES["some"]["builtin"] % {"N": N_SWEEP, "CB": "cb_false"})
    write("k_c_some_a3", BODIES["some"]["control"] % {"N": N_SWEEP, "CB": "cb_false"})
    for n in ("k_some_a0", "k_c_some_a0", "k_some_a3", "k_c_some_a3"):
        added[n] = (N_SWEEP, 100, N_SWEEP * 100)

    # --- gdb twin for the arity-0 leg ---
    write("g_foreach_a0", BODIES["foreach"]["builtin"] % {"N": N_COUNT, "CB": "cb_a0"})
    added["g_foreach_a0"] = (N_COUNT, 100, N_COUNT * 100)

    for name, (it, epi, cbc) in added.items():
        meta["iterations"][name] = it
        meta["elements_per_iteration"][name] = epi
        meta["callback_count"][name] = cbc
        if name not in meta["cases"]:
            meta["cases"].append(name)
    meta.setdefault("p7_42_record_only", []).extend(
        n for n in added if n.startswith("q_"))
    meta.setdefault("p7_42_count_only", []).extend(
        n for n in added if n.startswith("g_"))
    meta.setdefault("p7_42_arity_sweep", []).extend(
        sorted(n for n in added if n.startswith("k_")))
    with open(os.path.join(HERE, "cases.json"), "w") as fh:
        json.dump(meta, fh, indent=1)
        fh.write("\n")
    print(f"wrote {len(added)} cases")


if __name__ == "__main__":
    main()
