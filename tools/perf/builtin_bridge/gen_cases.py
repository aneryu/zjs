#!/usr/bin/env python3
"""Generate the P7-41 builtin->JS bridge case corpus.

Every builtin case is paired with a *mirrored direct loop* control written at
the same layer: same source element read, same callback arity, same callback
count, same result write / accumulate shape. Subtracting the control from the
builtin removes ordinary JS call cost, element reads and result writes as far
as a same-layer control can, and what remains is the builtin->JS bridge.

Design rules, all deliberate:

* Every binding is function-local. P7-20 recorded that top-level lexical
  binding access is itself a zjs/qjs divergence, so a top-level corpus would
  fold that tax into every rung.
* The callback is pre-declared and **non-capturing** (it reads only its own
  parameters), so no closure is allocated per iteration. P7-40 found the
  inline-arrow closure allocation was a second, unrelated 48% of that case.
* Callback predicates are chosen so the callback runs exactly `LEN` times:
  `some` gets an always-false predicate, `every` an always-true one, so
  neither short-circuits.
* Arrays are dense integer arrays with no holes, built by literal.
* Round one passes no `thisArg` except in the single dedicated variant.

Run: python3 tools/perf/builtin_bridge/gen_cases.py
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")

LEN = 100          # elements per builtin call
N_LONG = 10000     # outer iterations at LEN -> 1e6 callback invocations
N_ZERO = 100000    # outer iterations for the length-0 intercept twins

# Shared preamble: the array and every callback used by the corpus. All
# callbacks are top-level *inside* run(), non-capturing, pre-declared.
PRELUDE_TMPL = """  const a = [{arr}];
  function cb_ident(v, i, arr) {{ return v; }}
  function cb_noop(v, i, arr) {{ }}
  function cb_false(v, i, arr) {{ return false; }}
  function cb_true(v, i, arr) {{ return true; }}
  function cb_acc(acc, v, i, arr) {{ return acc; }}
  const LEN = {length};
"""


def arr_literal(n):
    return ",".join(str(i + 1) for i in range(n))


def prelude(length):
    return PRELUDE_TMPL.format(arr=arr_literal(length), length=length)


def wrap(length, body, sink="t"):
    return ("function run() {\n"
            + prelude(length)
            + body
            + "\n  return " + sink + ";\n}\nprint(run());\n")


def case(name, text, written):
    with open(os.path.join(CASES, name + ".js"), "w") as fh:
        fh.write(text)
    written.append(name)
    return name


# ---------------------------------------------------------------------------
# Body pairs: (builtin body, mirrored direct-loop body, sink)
# `{N}` is the outer iteration count.
# ---------------------------------------------------------------------------

BODIES = {
    # map(identity): result array construction + per-element result write.
    "map": (
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{ t = a.map(cb_ident).length; }}""",
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{
    const out = new Array(LEN);
    for (let j = 0; j < LEN; j++) {{ out[j] = cb_ident(a[j], j, a); }}
    t = out.length;
  }}""",
        "t"),

    # forEach(noop): no result array, no result write. The cleanest rung.
    "foreach": (
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{ a.forEach(cb_noop); t = n; }}""",
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{
    for (let j = 0; j < LEN; j++) {{ cb_noop(a[j], j, a); }}
    t = n;
  }}""",
        "t"),

    # filter(alwaysFalse): result array constructed but never written.
    "filter_false": (
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{ t = a.filter(cb_false).length; }}""",
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{
    const out = [];
    let m = 0;
    for (let j = 0; j < LEN; j++) {{
      const v = a[j];
      if (cb_false(v, j, a)) {{ out[m] = v; m++; }}
    }}
    t = out.length;
  }}""",
        "t"),

    # filter(alwaysTrue): result array written once per element.
    "filter_true": (
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{ t = a.filter(cb_true).length; }}""",
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{
    const out = [];
    let m = 0;
    for (let j = 0; j < LEN; j++) {{
      const v = a[j];
      if (cb_true(v, j, a)) {{ out[m] = v; m++; }}
    }}
    t = out.length;
  }}""",
        "t"),

    # reduce(returnAccumulator): arity 4, accumulator carried, no result array.
    "reduce": (
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{ t = a.reduce(cb_acc, 0); }}""",
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{
    let acc = 0;
    for (let j = 0; j < LEN; j++) {{ acc = cb_acc(acc, a[j], j, a); }}
    t = acc;
  }}""",
        "t"),

    # some(alwaysFalse): callback runs exactly LEN times, no result array.
    "some": (
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{ t = a.some(cb_false) ? 1 : 0; }}""",
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{
    let hit = 0;
    for (let j = 0; j < LEN; j++) {{
      if (cb_false(a[j], j, a)) {{ hit = 1; break; }}
    }}
    t = hit;
  }}""",
        "t"),

    # every(alwaysTrue): callback runs exactly LEN times, no result array.
    "every": (
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{ t = a.every(cb_true) ? 1 : 0; }}""",
        """  let t = 0;
  for (let n = 0; n < {N}; n++) {{
    let hit = 1;
    for (let j = 0; j < LEN; j++) {{
      if (!cb_true(a[j], j, a)) {{ hit = 0; break; }}
    }}
    t = hit;
  }}""",
        "t"),
}

ORDER = ["map", "foreach", "filter_false", "filter_true",
         "reduce", "some", "every"]


def main():
    os.makedirs(CASES, exist_ok=True)
    written = []
    iterations = {}
    elements = {}
    callbacks = {}

    case("baseline", "print(0);\n", written)
    iterations["baseline"] = 0
    elements["baseline"] = 0
    callbacks["baseline"] = 0

    for key in ORDER:
        builtin_body, control_body, sink = BODIES[key]
        # length-LEN pair
        b = case(f"b_{key}",
                 wrap(LEN, builtin_body.format(N=N_LONG), sink), written)
        c = case(f"c_{key}",
                 wrap(LEN, control_body.format(N=N_LONG), sink), written)
        for name in (b, c):
            iterations[name] = N_LONG
            elements[name] = LEN
            callbacks[name] = N_LONG * LEN
        # length-0 intercept twins: same source, empty array
        b0 = case(f"b0_{key}",
                  wrap(0, builtin_body.format(N=N_ZERO), sink), written)
        c0 = case(f"c0_{key}",
                  wrap(0, control_body.format(N=N_ZERO), sink), written)
        for name in (b0, c0):
            iterations[name] = N_ZERO
            elements[name] = 0
            callbacks[name] = 0

    # ---- extra control: native callback vs JS callback on the same builtin --
    # Math.abs over a positive dense array returns the element unchanged, so
    # b_map_native's stdout matches b_map's, and the only difference against
    # b_map is which kind of callee the bridge dispatches to.
    case("b_map_native", wrap(LEN,
         """  let t = 0;
  for (let n = 0; n < %d; n++) { t = a.map(Math.abs).length; }""" % N_LONG),
         written)
    iterations["b_map_native"] = N_LONG
    elements["b_map_native"] = LEN
    callbacks["b_map_native"] = N_LONG * LEN

    case("c_map_native", wrap(LEN,
         """  let t = 0;
  for (let n = 0; n < %d; n++) {
    const out = new Array(LEN);
    for (let j = 0; j < LEN; j++) { out[j] = Math.abs(a[j], j, a); }
    t = out.length;
  }""" % N_LONG), written)
    iterations["c_map_native"] = N_LONG
    elements["c_map_native"] = LEN
    callbacks["c_map_native"] = N_LONG * LEN

    # ---- negation-free `every` control -------------------------------------
    # Round one's `c_every` used `if (!cb_true(...))`. Round one measured that
    # the bare `!` costs zjs +22.9 cycles/element against qjs's +3.7 (see the
    # n_plain/n_neg probe below), while the two *builtins* `some`/`every` are
    # within 2.8 cycles of each other on both engines. That is a control-side
    # artifact, so `every`'s primary control avoids the operator entirely and
    # keeps the same one-callback-one-branch-per-element shape.
    for length, n, suffix in ((LEN, N_LONG, ""), (0, N_ZERO, "0")):
        nm = case(f"c2{suffix}_every", wrap(length,
            """  let t = 0;
  for (let n = 0; n < %d; n++) {
    let hit = 1;
    for (let j = 0; j < LEN; j++) {
      if (cb_true(a[j], j, a)) { continue; }
      hit = 0; break;
    }
    t = hit;
  }""" % n), written)
        iterations[nm] = n
        elements[nm] = length
        callbacks[nm] = n * length

    # ---- bare loop scaffolding, for the scaffold-corrected estimator -------
    # The mirrored controls carry a bytecode loop counter/bound-test/back-jump
    # that the builtin runs in C. Measuring it once lets the analysis report a
    # second estimator that does not credit the builtin with that refund, which
    # is the estimator P7-40's +1.38 / +36.33 figures were built on.
    for length, n, suffix in ((LEN, N_LONG, ""), (0, N_ZERO, "0")):
        nm = case(f"s{suffix}_loop", wrap(length,
            """  let t = 0;
  for (let n = 0; n < %d; n++) {
    for (let j = 0; j < LEN; j++) { t = j; }
  }""" % n), written)
        iterations[nm] = n
        elements[nm] = length
        callbacks[nm] = 0

    # ---- logical-NOT probe -------------------------------------------------
    # Identical loops, identical not-taken branch, differing only by one `!`
    # applied to a mutable local (so it cannot be constant-folded).
    for nm, decl, test in (("n_plain", "false", "flag"),
                           ("n_neg", "true", "!flag")):
        c = case(nm, wrap(LEN,
            """  let flag = %s;
  let t = 0;
  for (let n = 0; n < %d; n++) {
    let hit = 0;
    for (let j = 0; j < LEN; j++) {
      if (%s) { hit = 1; break; }
      t = a[j];
    }
    t = hit;
  }""" % (decl, N_LONG, test)), written)
        iterations[c] = N_LONG
        elements[c] = LEN
        callbacks[c] = 0

    # ---- dead-store guard for map ------------------------------------------
    # `c_map`'s sink is `out.length`, which is 100 whatever the callback
    # returned. These twins checksum every element of the result instead, so
    # each callback's return value provably reaches printed output. If neither
    # engine was eliding the stores, the builtin-minus-control difference must
    # be unchanged against the plain pair.
    nm = case("b_map_sum", wrap(LEN,
        """  let t = 0;
  for (let n = 0; n < %d; n++) {
    const out = a.map(cb_ident);
    let s = 0;
    for (let j = 0; j < LEN; j++) { s = s + out[j]; }
    t = s;
  }""" % N_LONG), written)
    iterations[nm] = N_LONG
    elements[nm] = LEN
    callbacks[nm] = N_LONG * LEN
    nm = case("c_map_sum", wrap(LEN,
        """  let t = 0;
  for (let n = 0; n < %d; n++) {
    const out = new Array(LEN);
    for (let j = 0; j < LEN; j++) { out[j] = cb_ident(a[j], j, a); }
    let s = 0;
    for (let j = 0; j < LEN; j++) { s = s + out[j]; }
    t = s;
  }""" % N_LONG), written)
    iterations[nm] = N_LONG
    elements[nm] = LEN
    callbacks[nm] = N_LONG * LEN

    # ---- extra control: thisArg forwarding on forEach ----------------------
    case("b_foreach_thisarg", wrap(LEN,
         """  const host = { k: 1 };
  let t = 0;
  for (let n = 0; n < %d; n++) { a.forEach(cb_noop, host); t = n; }""" % N_LONG),
         written)
    iterations["b_foreach_thisarg"] = N_LONG
    elements["b_foreach_thisarg"] = LEN
    callbacks["b_foreach_thisarg"] = N_LONG * LEN

    # ---- ABI + dynamic invocation-count verification -----------------------
    # Engine-agnostic: the callback itself counts its invocations and checks the
    # arity, the argument values and the `this` binding it was handed, once
    # through the builtin and once through the mirrored control. Both engines
    # must print the same line, and the count must equal LEN. Not timed.
    VERIFY = {
        "map":          ("a.map(cbv);", "for (let j = 0; j < LEN; j++) { sink[j] = cbv(a[j], j, a); }", "v", 3),
        "foreach":      ("a.forEach(cbv);", "for (let j = 0; j < LEN; j++) { cbv(a[j], j, a); }", "undefined", 3),
        "filter_false": ("a.filter(cbv);", "for (let j = 0; j < LEN; j++) { if (cbv(a[j], j, a)) { sink[0] = 1; } }", "false", 3),
        "filter_true":  ("a.filter(cbv);", "for (let j = 0; j < LEN; j++) { if (cbv(a[j], j, a)) { sink[0] = 1; } }", "true", 3),
        "some":         ("a.some(cbv);", "for (let j = 0; j < LEN; j++) { if (cbv(a[j], j, a)) { break; } }", "false", 3),
        "every":        ("a.every(cbv);", "for (let j = 0; j < LEN; j++) { if (cbv(a[j], j, a)) { continue; } break; }", "true", 3),
    }
    for key, (builtin_stmt, control_stmt, ret, argc) in VERIFY.items():
        body = f"""  let calls = 0, bad_argc = 0, bad_arr = 0, bad_idx = 0, bad_val = 0, this_global = 0;
  const sink = new Array(LEN);
  function cbv(v, i, arr) {{
    if (arguments.length !== {argc}) {{ bad_argc++; }}
    if (arr !== a) {{ bad_arr++; }}
    if (i !== calls) {{ bad_idx++; }}
    if (v !== a[i]) {{ bad_val++; }}
    if (this === globalThis) {{ this_global++; }}
    calls++;
    return {ret};
  }}
  {builtin_stmt}
  const bi = [calls, bad_argc, bad_arr, bad_idx, bad_val, this_global].join("/");
  calls = 0; bad_argc = 0; bad_arr = 0; bad_idx = 0; bad_val = 0; this_global = 0;
  {control_stmt}
  const co = [calls, bad_argc, bad_arr, bad_idx, bad_val, this_global].join("/");
  const t = "{key} builtin=" + bi + " control=" + co;"""
        nm = case(f"verify_{key}", wrap(LEN, body), written)
        iterations[nm] = 1
        elements[nm] = LEN
        callbacks[nm] = LEN

    body = """  let calls = 0, bad_argc = 0, bad_arr = 0, bad_idx = 0, bad_val = 0, this_global = 0;
  function cbv(acc, v, i, arr) {
    if (arguments.length !== 4) { bad_argc++; }
    if (arr !== a) { bad_arr++; }
    if (i !== calls) { bad_idx++; }
    if (v !== a[i]) { bad_val++; }
    if (this === globalThis) { this_global++; }
    calls++;
    return acc;
  }
  a.reduce(cbv, 0);
  const bi = [calls, bad_argc, bad_arr, bad_idx, bad_val, this_global].join("/");
  calls = 0; bad_argc = 0; bad_arr = 0; bad_idx = 0; bad_val = 0; this_global = 0;
  let acc = 0;
  for (let j = 0; j < LEN; j++) { acc = cbv(acc, a[j], j, a); }
  const co = [calls, bad_argc, bad_arr, bad_idx, bad_val, this_global].join("/");
  const t = "reduce builtin=" + bi + " control=" + co;"""
    nm = case("verify_reduce", wrap(LEN, body), written)
    iterations[nm] = 1
    elements[nm] = LEN
    callbacks[nm] = LEN

    # ---- small-N twins used only for exact dynamic counting under gdb ------
    for key in ORDER:
        builtin_body, control_body, sink = BODIES[key]
        n = case(f"count_{key}", wrap(LEN, builtin_body.format(N=100), sink),
                 written)
        iterations[n] = 100
        elements[n] = LEN
        callbacks[n] = 100 * LEN
        n = case(f"count_c_{key}", wrap(LEN, control_body.format(N=100), sink),
                 written)
        iterations[n] = 100
        elements[n] = LEN
        callbacks[n] = 100 * LEN
    # the negation-free `every` control, so the counted control matches the
    # control the timing analysis actually uses
    n = case("count_c2_every", wrap(LEN,
        """  let t = 0;
  for (let n = 0; n < 100; n++) {
    let hit = 1;
    for (let j = 0; j < LEN; j++) {
      if (cb_true(a[j], j, a)) { continue; }
      hit = 0; break;
    }
    t = hit;
  }"""), written)
    iterations[n] = 100
    elements[n] = LEN
    callbacks[n] = 100 * LEN
    case("count_baseline", "print(0);\n", written)
    iterations["count_baseline"] = 0
    elements["count_baseline"] = 0
    callbacks["count_baseline"] = 0

    # ---- long twins used only for perf-record symbol attribution ----------
    perf_only = []
    for key in ("foreach", "every", "map"):
        builtin_body, control_body, sink = BODIES[key]
        n = case(f"perf_{key}", wrap(LEN, builtin_body.format(N=100000), sink),
                 written)
        perf_only.append(n)
        iterations[n] = 100000
        elements[n] = LEN
        callbacks[n] = 100000 * LEN
        n = case(f"perf_c_{key}",
                 wrap(LEN, control_body.format(N=100000), sink), written)
        perf_only.append(n)
        iterations[n] = 100000
        elements[n] = LEN
        callbacks[n] = 100000 * LEN

    count_only = [n for n in written if n.startswith("count_")]
    verify_only = [n for n in written if n.startswith("verify_")]

    meta = {
        "LEN": LEN,
        "N_LONG": N_LONG,
        "N_ZERO": N_ZERO,
        "builtins": ORDER,
        # `every`'s primary control is the negation-free rewrite; round one's
        # `c_every` is retained so the artifact stays visible in the record.
        "control_override": {"every": ("c2_every", "c20_every")},
        "verify_only": verify_only,
        "iterations": iterations,
        "elements_per_iteration": elements,
        "callback_count": callbacks,
        "perf_only": perf_only,
        "count_only": count_only,
        "cases": written,
    }
    with open(os.path.join(HERE, "cases.json"), "w") as fh:
        json.dump(meta, fh, indent=1)
        fh.write("\n")
    print(f"wrote {len(written)} cases")


if __name__ == "__main__":
    main()
