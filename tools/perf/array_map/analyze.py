#!/usr/bin/env python3
"""P7-40 analysis: turn the ladder / count / profile artifacts into the dossier
JSON. Every number printed by this script has a sibling in P7-40-results.json.
"""

import argparse
import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))


def load(path):
    with open(path) as fh:
        return json.load(fh)


def profile(data_path, limit=1.0):
    out = subprocess.run(["perf", "report", "--stdio", "--no-children",
                          "--percent-limit", str(limit), "-i", data_path],
                         capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line or not line[0].isdigit():
            continue
        parts = line.split()
        if len(parts) < 5 or not parts[0].endswith("%"):
            continue
        rows.append({"percent": float(parts[0].rstrip("%")),
                     "symbol": parts[-1]})
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ladder", required=True)
    ap.add_argument("--ladder2", default=None)
    ap.add_argument("--counts", required=True)
    ap.add_argument("--build-b", default=None,
                    help="ladder json produced with the second build instance")
    ap.add_argument("--pareto", default=None,
                    help="pinned re-measurement of the P7-20 Pareto top cases")
    ap.add_argument("--wall", default=None,
                    help="wall-clock json for map_original_toplevel")
    ap.add_argument("--snapshot", default=None,
                    help="phase-6-closeout process-microbench.json")
    ap.add_argument("--profile-dir", default=None)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    lad = load(args.ladder)
    C = lad["cases"]

    def payload(name, eng, metric):
        it = C[name]["iterations"]
        return (C[name][eng][metric] - C["baseline"][eng][metric]) / it

    metrics = {"instructions": "instructions_median", "cycles": "cycles_median",
               "task_clock_ms": "task_clock_ms_median"}
    ladder = {}
    for name in C:
        if name == "baseline" or name.startswith("count_"):
            continue
        rec = {"iterations": C[name]["iterations"]}
        for label, key in metrics.items():
            q = payload(name, "qjs", key)
            z = payload(name, "zjs", key)
            rec[label] = {"qjs_per_iteration": q, "zjs_per_iteration": z,
                          "ratio": z / q}
        rec["ipc"] = {
            "qjs": payload(name, "qjs", "instructions_median") /
                   payload(name, "qjs", "cycles_median"),
            "zjs": payload(name, "zjs", "instructions_median") /
                   payload(name, "zjs", "cycles_median")}
        rec["paired_instruction_ratios"] = C[name]["paired_instruction_ratios"]
        rec["paired_cycle_ratios"] = C[name]["paired_cycle_ratios"]
        ladder[name] = rec

    def P(name, eng, label):
        return ladder[name][label][f"{eng}_per_iteration"]

    # ---- slope / intercept model -------------------------------------------
    model = {}
    for label in ("instructions", "cycles"):
        m = {}
        for eng in ("qjs", "zjs"):
            map0, map1, map10, map100 = (P("map_len0", eng, label),
                                         P("map_len1", eng, label),
                                         P("map_pre_arrow", eng, label),
                                         P("map_len100", eng, label))
            fe0, fe1, fe10, fe100 = (P("foreach_len0", eng, label),
                                     P("foreach_len1", eng, label),
                                     P("foreach_pre_arrow", eng, label),
                                     P("foreach_len100", eng, label))
            m[eng] = {
                "map_intercept_len0": map0,
                "map_slope_1_to_10": (map10 - map1) / 9,
                "map_slope_10_to_100": (map100 - map10) / 90,
                "foreach_intercept_len0": fe0,
                "foreach_slope_1_to_10": (fe10 - fe1) / 9,
                "foreach_slope_10_to_100": (fe100 - fe10) / 90,
                "result_construction_per_call": map0 - fe0,
                "define_per_element_1_to_10": (map10 - map1) / 9 - (fe10 - fe1) / 9,
                "define_per_element_10_to_100":
                    (map100 - map10) / 90 - (fe100 - fe10) / 90,
                "predicted_map_len10": map0 + 10 * ((map10 - map1) / 9),
                "measured_map_len10": map10,
            }
            m[eng]["model_error_pct"] = 100 * (
                m[eng]["predicted_map_len10"] - map10) / map10
        m["deltas_zjs_minus_qjs"] = {
            k: m["zjs"][k] - m["qjs"][k]
            for k in ("map_intercept_len0", "foreach_intercept_len0",
                      "result_construction_per_call",
                      "foreach_slope_1_to_10", "define_per_element_1_to_10",
                      "map_slope_1_to_10")}
        model[label] = m

    # ---- three-way split ----------------------------------------------------
    splits = {}
    for label in ("instructions", "cycles"):
        d = model[label]["deltas_zjs_minus_qjs"]
        per_elem_call = 10 * d["foreach_slope_1_to_10"]
        per_elem_define = 10 * d["define_per_element_1_to_10"]
        builtin_entry = d["foreach_intercept_len0"]
        result_ctor = d["result_construction_per_call"]
        hoisted_total = P("map_pre_arrow", "zjs", label) - P("map_pre_arrow", "qjs", label)
        closure_q = P("map_inline_arrow", "qjs", label) - P("map_pre_arrow", "qjs", label)
        closure_z = P("map_inline_arrow", "zjs", label) - P("map_pre_arrow", "zjs", label)
        closure_delta = closure_z - closure_q
        original_total = P("map_inline_arrow", "zjs", label) - P("map_inline_arrow", "qjs", label)
        comps = {
            "callback_invocation_and_source_get": per_elem_call,
            "result_element_define": per_elem_define,
            "builtin_entry_fixed": builtin_entry,
            "result_array_construction_and_species": result_ctor,
            "inline_arrow_closure_allocation": closure_delta,
        }
        splits[label] = {
            "components_zjs_minus_qjs_per_map_call": comps,
            "component_sum": sum(comps.values()),
            "measured_total_inline_arrow": original_total,
            "measured_total_hoisted_callback": hoisted_total,
            "closure_cost_per_call": {"qjs": closure_q, "zjs": closure_z},
            "shares_of_inline_arrow_total_pct": {
                k: 100 * v / original_total for k, v in comps.items()},
            "shares_of_hoisted_total_pct": {
                k: 100 * v / hoisted_total for k, v in comps.items()
                if k != "inline_arrow_closure_allocation"},
            "closure_of_sum_pct": 100 * comps["inline_arrow_closure_allocation"] /
                                  sum(comps.values()),
            "residual_vs_measured_pct":
                100 * (sum(comps.values()) - original_total) / original_total,
        }

    # ---- VM-layer reference for the callback bridge -------------------------
    vm = {}
    for label in ("instructions", "cycles"):
        v = {}
        for eng in ("qjs", "zjs"):
            read = (P("elem_get", eng, label) - P("loop_nested", eng, label)) / 10
            call = (P("elem_getcall", eng, label) - P("elem_get", eng, label)) / 10
            builtin = model[label][eng]["foreach_slope_1_to_10"]
            v[eng] = {"vm_dense_read_per_element": read,
                      "vm_call_per_element": call,
                      "vm_read_plus_call": read + call,
                      "builtin_get_plus_call_per_element": builtin,
                      "builtin_surcharge": builtin - (read + call)}
        v["delta_zjs_minus_qjs"] = {
            k: v["zjs"][k] - v["qjs"][k] for k in v["qjs"]}
        vm[label] = v

    out = {
        "line": "P7-40",
        "question": "is the 2.618x mainly callback invocation, result-array "
                    "construction, or per-element property machinery?",
        "answer": {
            "headline": "the 2.618 does not reproduce on the current tree; "
                        "pinned it is 1.364x cycles / 1.121x instructions. "
                        "Of what remains, callback invocation is the single "
                        "largest term (70.9% of the cycle delta), the inline "
                        "arrow's per-iteration closure allocation is a second, "
                        "nearly equal term (48.1%) that is not part of map, "
                        "result-array construction is small (+9.0%) and the "
                        "per-element result define is negative (-38.5%, zjs "
                        "faster). Source-element property machinery is near "
                        "parity and zjs does strictly less of it.",
            "primary_metric": "cycles, process payload net of an empty-script "
                              "baseline, median of 6 ABBA samples on CPU 19"},
        "stale_binary_evidence": {
            "claim": "the P7-20 snapshot measured a zjs binary that predates "
                     "63c409c0 'perf: reuse active Machine for array callbacks'",
            "snapshot_zjs_commit": "0f726fc0",
            "snapshot_zjs_sha256": "df03ae4919b571f227af2da3af490680b28a7daad67e340856e0c3360eb3d14c",
            "snapshot_zjs_path_sha256_now": "d0eef3c1fc55e2bb95673eef2b80043fab873eba5430b9e1b401bbf6f6002e0d",
            "snapshot_zjs_binary_still_available": False,
            "63c409c0_is_ancestor_of_0f726fc0": False,
            "245ccaea_is_ancestor_of_0f726fc0": False,
            "96a3f8ff_is_ancestor_of_0f726fc0": False,
            "entered_through_merge": "222df098",
            "SyncInternalCallSite_occurrences_at_0f726fc0": {
                "src/exec/array_ops.zig": 0, "src/exec/call_runtime.zig": 0},
            "map_element_loop_call_at_0f726fc0":
                "callValueOrBytecode(ctx, output, global, callback_this, args[0], ...)",
            "map_element_loop_call_at_a5bbbe52":
                "callback_call.call(&.{ item, index_value, receiver_object_value })",
            "verified_by_rebuild": False,
            "not_established": "0f726fc0 was not rebuilt and re-measured; this "
                               "line may not create worktrees or touch src/"},
        "extra_counts": {
            "zjs_ensureArrayBufferCapacity_hits_count_map": 1001,
            "zjs_ensureArrayBufferCapacity_per_map_call": 10.0,
            "note": "separate single-symbol gdb run; the function returns early "
                    "when capacity suffices, and its growth policy mirrors qjs "
                    "expand_fast_array, so the real reallocation count is 7 per "
                    "call on both engines (0->1->2->3->4->6->9->10)"},
        "cleanliness": {
            "git_diff_a5bbbe52_src": "empty",
            "temporary_instrumentation_in_src": False,
            "instruments": ["gdb breakpoint hit counts", "perf stat", "perf record"],
            "git_stash_used": False},
        "collectors": {
            "ladder": os.path.basename(args.ladder),
            "counts": os.path.basename(args.counts),
        },
        "provenance": {k: lad[k] for k in
                       ("cpu", "pmu", "samples_per_case_per_engine",
                        "sampling_order", "first_position_counts",
                        "first_position_balanced", "zjs_binary", "qjs_binary",
                        "events")},
        "ladder": ladder,
        "model": model,
        "split": splits,
        "vm_layer_reference": vm,
        "dynamic_counts": load(args.counts),
    }
    if args.ladder2:
        lad2 = load(args.ladder2)
        out["repeat_run"] = {
            "provenance": {k: lad2[k] for k in
                           ("samples_per_case_per_engine",
                            "first_position_counts", "zjs_binary")},
            "cases": {n: {"instruction_ratio":
                          lad2["cases"][n]["zjs"]["instructions_median"] /
                          lad2["cases"][n]["qjs"]["instructions_median"],
                          "cycle_ratio":
                          lad2["cases"][n]["zjs"]["cycles_median"] /
                          lad2["cases"][n]["qjs"]["cycles_median"]}
                      for n in lad2["cases"]}}
    if args.build_b:
        ladb = load(args.build_b)
        lada = load(args.ladder2) if args.ladder2 else lad
        rows = {}
        for n in ladb["cases"]:
            if n == "baseline":
                continue
            def r(src, m):
                return (src["cases"][n]["zjs"][m] / src["cases"][n]["qjs"][m])
            rows[n] = {
                "instruction_ratio_build_a": r(lada, "instructions_median"),
                "instruction_ratio_build_b": r(ladb, "instructions_median"),
                "cycle_ratio_build_a": r(lada, "cycles_median"),
                "cycle_ratio_build_b": r(ladb, "cycles_median"),
            }
            rows[n]["cycle_ratio_spread_pct"] = 100 * (
                rows[n]["cycle_ratio_build_b"] / rows[n]["cycle_ratio_build_a"] - 1)
        out["build_instances"] = {
            "why": "rule: an A/B claim needs multiple build instances per side; "
                   "two independent builds of the same tree were measured",
            "build_a": lada["zjs_binary"], "build_b": ladb["zjs_binary"],
            "cases": rows}
    if args.pareto:
        par = load(args.pareto)
        out["pareto_cross_check"] = {
            "note": "P7-20 top cases re-measured pinned on CPU 19 with payload "
                    "net of the process baseline; P7-20's own numbers are "
                    "unpinned wall time including startup",
            "cases": {n: {
                "instruction_ratio": par["cases"][n]["zjs"]["instructions_median"] /
                                     par["cases"][n]["qjs"]["instructions_median"],
                "cycle_ratio": par["cases"][n]["zjs"]["cycles_median"] /
                               par["cases"][n]["qjs"]["cycles_median"],
                "qjs_task_clock_ms": par["cases"][n]["qjs"]["task_clock_ms_median"],
                "zjs_task_clock_ms": par["cases"][n]["zjs"]["task_clock_ms_median"],
            } for n in par["cases"]}}
    if args.wall:
        out["wall_clock_original_case"] = load(args.wall)
    if args.snapshot:
        import math
        snap = load(args.snapshot)
        c = [x for x in snap["cases"] if x["name"] == "array_map_callback"][0]
        q, z = c["qjs"]["samples"], c["zjs"]["samples"]
        qf = [x for x in q if x < 8]
        qs_ = [x for x in q if x >= 8]
        zf = [x for x in z if x < 20]
        zs_ = [x for x in z if x >= 20]
        import statistics as st
        pr = c["paired"]["ratios"]
        out["p7_20_snapshot"] = {
            "source": args.snapshot,
            "affinity": snap["meta"]["host"]["affinitySource"],
            "affinity_mask": snap["meta"]["host"]["affinityMask"],
            "cpu_model": snap["meta"]["host"]["cpuModel"],
            "zjs_binary_sha256": snap["meta"]["zjs"]["sha256"],
            "zjs_commit": snap["meta"]["zjs"]["commit"],
            "zjs_dirty": snap["meta"]["zjs"]["dirty"],
            "qjs_binary_sha256": snap["meta"]["qjs"]["sha256"],
            "paired_geomean": c["paired"].get("geomean"),
            "paired_ratio_min": min(pr), "paired_ratio_max": max(pr),
            "avg_ratio": c["ratio"],
            "bimodality": {
                "qjs_fast_n": len(qf), "qjs_fast_median_ms": st.median(qf),
                "qjs_slow_n": len(qs_), "qjs_slow_median_ms": st.median(qs_),
                "zjs_fast_n": len(zf), "zjs_fast_median_ms": st.median(zf),
                "zjs_slow_n": len(zs_), "zjs_slow_median_ms": st.median(zs_),
                "qjs_slow_over_fast": st.median(qs_) / st.median(qf),
                "zjs_slow_over_fast": st.median(zs_) / st.median(zf),
                "mode_matched_ratio_fast": st.median(zf) / st.median(qf),
                "mode_matched_ratio_slow": st.median(zs_) / st.median(qs_),
            }}
    if args.profile_dir:
        prof = {}
        for f in sorted(os.listdir(args.profile_dir)):
            if f.endswith(".data"):
                prof[f[:-5]] = profile(os.path.join(args.profile_dir, f))
        out["perf_record_profiles"] = prof

    with open(args.out, "w") as fh:
        json.dump(out, fh, indent=1)
        fh.write("\n")

    for label in ("instructions", "cycles"):
        s = splits[label]
        print(f"--- {label} ---")
        print(f"  measured delta per map call, inline arrow : "
              f"{s['measured_total_inline_arrow']:.1f}")
        print(f"  measured delta per map call, hoisted      : "
              f"{s['measured_total_hoisted_callback']:.1f}")
        for k, v in s["components_zjs_minus_qjs_per_map_call"].items():
            print(f"    {k:44s} {v:9.1f}  "
                  f"{s['shares_of_inline_arrow_total_pct'][k]:6.1f}%")
        print(f"  sum {s['component_sum']:.1f}  residual "
              f"{s['residual_vs_measured_pct']:.1f}%")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
