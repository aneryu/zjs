#!/usr/bin/env python3
"""P7-60: assemble every collected artifact into one results JSON."""

import argparse
import hashlib
import json
import os
import statistics
import subprocess

import analyze  # noqa: E402  (same directory)

N = 20_000_000

# Which type-matrix cells stand for which runtime tag bucket.  The mapping was
# verified with the temporary tag census, not assumed.
TAG_TO_CELLS = {
    "boolean": ["bool_true", "bool_false"],
    "int": ["int_nonzero", "int_zero", "double_pos_zero"],
    "null": ["null"],
    "undefined": ["undefined"],
    "float64": ["double_nonzero", "double_neg_zero", "double_nan"],
    "string": ["string_short", "string_empty", "string_long"],
    "string_rope": ["string_rope"],
    "object": ["object_plain", "object_array", "object_function"],
    "short_big_int": ["bigint_short", "bigint_zero"],
    "big_int": ["bigint_wide"],
    "symbol": ["symbol"],
}
IMMEDIATE_TAGS = {"int", "boolean", "null", "undefined"}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def merged_matrix(scan_paths, rope_path):
    cells = {}
    for path in scan_paths:
        d, ie, ce = analyze.load(path)
        for t, row in analyze.type_matrix(d, ie, ce).items():
            cells.setdefault(t, []).append(row)
    d, ie, ce = analyze.load(rope_path)
    for t, row in analyze.type_matrix(d, ie, ce).items():
        cells[t] = [row]        # the rope cell is only valid in the rope scan
    out = {}
    for t, rows in cells.items():
        out[t] = {k: statistics.mean(r[k] for r in rows) for k in rows[0]}
        out[t]["scans"] = len(rows)
        out[t]["delta_cyc_spread"] = (max(r["delta_cyc"] for r in rows)
                                      - min(r["delta_cyc"] for r in rows))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", nargs="+", required=True)
    ap.add_argument("--rope", required=True)
    ap.add_argument("--stage", required=True)
    ap.add_argument("--census-count", nargs="+", required=True)
    ap.add_argument("--census-cycles-clean", required=True)
    ap.add_argument("--census-cycles-counter", required=True)
    ap.add_argument("--truth-zjs", required=True)
    ap.add_argument("--truth-qjs", required=True)
    ap.add_argument("--zjs-a1", required=True)
    ap.add_argument("--zjs-a2", required=True)
    ap.add_argument("--zjs-counter", required=True)
    ap.add_argument("--qjs", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    matrix = merged_matrix(args.matrix, args.rope)

    per_tag_delta = {}
    per_tag_zjs = {}
    for tag, names in TAG_TO_CELLS.items():
        have = [matrix[n] for n in names if n in matrix]
        if not have:
            continue
        per_tag_delta[tag] = statistics.mean(r["delta_cyc"] for r in have)
        per_tag_zjs[tag] = statistics.mean(r["zjs_cyc"] for r in have)

    # zjs's own inline branch arm on an immediate: `r_int_nonzero_if` minus
    # `r_int_nonzero_none` = get_loc + inline if_false, so it is an UPPER bound on
    # what a fast `op_lnot` immediate arm can cost.
    d0, ie, ce = analyze.load(args.matrix[0])
    branch = analyze.branch_family(d0, ie, ce)
    inline_arm_upper = branch["int_nonzero"]["zjs_branch_cyc"]

    counts = {}
    for path in args.census_count:
        counts.update(json.load(open(path))["entries"])
    clean = json.load(open(args.census_cycles_clean))["entries"]
    counter = json.load(open(args.census_cycles_counter))["entries"]

    workloads = {}
    for key, rec in counts.items():
        hits = rec.get("lnot_total", 0)
        tags = rec.get("tags", {})
        cyc = (clean.get(key) or {}).get("cycles")
        if cyc is None:
            cyc = (counter.get(key) or {}).get("cycles")
        weighted = (sum(per_tag_delta.get(t, 0) * n for t, n in tags.items()) / hits
                    if hits else 0.0)
        excess = sum(per_tag_delta.get(t, 0) * n for t, n in tags.items())
        imm_hits = sum(n for t, n in tags.items() if t in IMMEDIATE_TAGS)
        imm_recoverable = sum(
            max(0.0, per_tag_zjs.get(t, 0) - inline_arm_upper) * n
            for t, n in tags.items() if t in IMMEDIATE_TAGS)
        workloads[key] = {
            "group": rec.get("group"),
            "lnot_hits": hits,
            "operand_tag_distribution": tags,
            "immediate_operand_hits": imm_hits,
            "immediate_operand_share": imm_hits / hits if hits else None,
            "total_cycles_clean_build": cyc,
            "total_cycles_counter_build": (counter.get(key) or {}).get("cycles"),
            "hits_per_Mcycle": 1e6 * hits / cyc if cyc else None,
            "weighted_delta_cycles_per_event": weighted,
            "estimated_excess_cycles": excess,
            "estimated_excess_share_of_cycles": excess / cyc if cyc else None,
            "immediate_only_recoverable_cycles": imm_recoverable,
            "immediate_only_recoverable_share": (imm_recoverable / cyc
                                                 if cyc else None),
        }

    truth_zjs = open(args.truth_zjs).read()
    truth_qjs = open(args.truth_qjs).read()

    payload = {
        "line": "P7-60",
        "title": "op.lnot / OP_lnot attribution",
        "nature": "profiling only; no src change shipped; stops at the decision point",
        "baseline_commit": "ab4fc64b",
        "branch": "perf/qjs-align-p7-logicalnot",
        "qjs_pin": "04be2460",
        "binaries": {
            "zjs_cold_build_A1_sha256": sha256(args.zjs_a1),
            "zjs_cold_build_A2_sha256": sha256(args.zjs_a2),
            "zjs_cold_builds_byte_identical": sha256(args.zjs_a1) == sha256(args.zjs_a2),
            "zjs_counter_build_sha256": sha256(args.zjs_counter),
            "zjs_counter_build_flags": "-Dzjs_enable_opcode_profile=true plus a temporary counter; NEVER used for any timing number",
            "qjs_sha256": sha256(args.qjs),
        },
        "host": {
            "core": 19,
            "pmu": "armv8_pmuv3_1",
            "topology": "20-core big.LITTLE, two PMUs; every event carries a PMU prefix",
            "timing_lock": "flock -x + taskset -c 19",
            "build_lock": "flock -s",
            "counting_lock": "none (counting only, P7-51A precedent)",
        },
        "mechanism": {
            "zjs_registration": "src/exec/tailcall_dispatch_colds.zig:309 -- op.lnot is the cold-table entry only; there is no fast handler",
            "zjs_helper": "src/exec/vm_value.zig:235 noinline fn logicalNot -> core.value_semantics.toBoolean (a SECOND out-of-line call)",
            "zjs_cold_handler_symbol": "exec.tailcall_dispatch.coldStd__struct_69769.h",
            "zjs_existing_immediate_predicate": "src/core/value.zig:450 JSValue.asBranchImmediateBool -- already a verbatim mirror of the qjs arm, already used by op_if_false8/op_if_true8, not used by lnot",
            "qjs_inline_arm": "quickjs.c:19092-19105; (uint32_t)tag <= JS_TAG_UNDEFINED -> res = JS_VALUE_GET_INT(op1) != 0",
            "qjs_slow_arm": "JS_ToBoolFree (quickjs.c:11160), shared with OP_if_true/OP_if_false",
            "qjs_peephole": "none -- OP_lnot appears only at 19092 (interpreter) and 27620 (emitter); resolve_labels never rewrites it",
        },
        "syntactic_forms_emitting_op_lnot": {
            "measured_with": "temporary tag census, 1000 evaluations per form",
            "emit_one_per_evaluation": [
                "u = !x", "if (!x) {...}", "while (!x)", "for (; !x; )",
                "do {...} while (!x)", "return !x", "!x ? a : b",
                "t + (!x ? 1 : 0)", "x && !y", "!x || y", "!(a < b)", "if (!o.p)",
            ],
            "emit_two_per_evaluation": ["u = !!x  (second operand is the boolean)"],
            "emit_none": ["if (x) {...}", "x !== 0"],
            "conclusion": "zjs has NO condition-context inversion peephole: a `!` in a condition still executes op.lnot. A source-level `!` census would therefore have been nearly right for zjs, but every number below is from the dynamic counter regardless.",
        },
        "type_matrix": matrix,
        "per_tag_delta_cycles": per_tag_delta,
        "per_tag_zjs_cycles": per_tag_zjs,
        "zjs_inline_immediate_arm_upper_bound_cycles": inline_arm_upper,
        "bool_slope": {label: s["bool_slope"] for label, s in
                       {json.load(open(p))["build_label"]:
                        {"bool_slope": analyze.bool_slope(*analyze.load(p))}
                        for p in args.matrix}.items()},
        "branch_route_table": branch,
        "stage_attribution": json.load(open(args.stage)),
        "workloads": workloads,
        "correctness_boundary": {
            "script": "tools/perf/logical_not/truthiness_table.js",
            "rows": len(truth_zjs.splitlines()),
            "byte_identical_across_engines": truth_zjs == truth_qjs,
            "sha256": hashlib.sha256(truth_zjs.encode()).hexdigest(),
        },
    }
    with open(args.out, "w") as fh:
        json.dump(payload, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)

    imm = statistics.mean(per_tag_delta[t] for t in IMMEDIATE_TAGS)
    print(f"immediate-operand mean delta: {imm:.2f} cyc/event")
    print(f"zjs inline-arm upper bound:   {inline_arm_upper:.2f} cyc")
    print(f"{'workload':22s} {'hits':>11} {'imm%':>6} {'w.delta':>8} "
          f"{'excess_cyc':>12} {'excess%':>8} {'recover%':>9}")
    for k, w in sorted(workloads.items(),
                       key=lambda kv: -(kv[1]["estimated_excess_share_of_cycles"] or 0)):
        if w["lnot_hits"] < 1000 or w["estimated_excess_share_of_cycles"] is None:
            continue
        print(f"{k.split('/')[-1]:22s} {w['lnot_hits']:>11} "
              f"{100*w['immediate_operand_share']:>5.1f}% "
              f"{w['weighted_delta_cycles_per_event']:>8.2f} "
              f"{w['estimated_excess_cycles']:>12.0f} "
              f"{100*w['estimated_excess_share_of_cycles']:>7.3f}% "
              f"{100*w['immediate_only_recoverable_share']:>8.3f}%")


if __name__ == "__main__":
    main()
