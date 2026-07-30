#!/usr/bin/env python3
"""P7-41 analyser: per-callback builtin->JS bridge tax, per builtin.

For each engine and each builtin B with mirrored direct-loop control C:

    load(case)          = median(total) - median(baseline)          # same binary
    per_callback(case)  = load(case) / callback_count(case)

    bridge_tax(engine)  = (load(B) - load(C)) / callback_count      # spec form
    zjs_specific        = bridge_tax(zjs) - bridge_tax(qjs)

The spec form still carries each side's per-*call* constants (species lookup,
result-array construction, builtin entry). With LEN=100 those are diluted 100:1,
but the length-0 twins let us remove them outright:

    intercept(case)     = load(case0) / iterations(case0)           # per builtin call
    slope(case)         = (load(case)/iterations(case) - intercept) / LEN
    bridge_tax_slope    = slope(B) - slope(C)

`bridge_tax_slope` is the per-callback figure with every per-call constant
removed on both sides, so it is the authoritative column; the spec form is
reported next to it as a cross-check.
"""

import argparse
import json
import statistics


def med(rec, eng, key):
    return rec[eng][key]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timing", required=True, nargs="+",
                    help="one or more run_bridge.py outputs (replicates)")
    ap.add_argument("--counts", default=None)
    ap.add_argument("--record", default=None)
    ap.add_argument("--verify", default=None)
    ap.add_argument("--cases", default=None)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    runs = [json.load(open(p)) for p in args.timing]
    meta = json.load(open(args.cases)) if args.cases else None
    LEN = meta["LEN"] if meta else 100
    builtins = meta["builtins"] if meta else []

    metrics = ("instructions", "cycles")
    out = {
        "LEN": LEN,
        "replicates": [
            {"path": p, "build_label": r["build_label"],
             "zjs_binary": r["zjs_binary"], "qjs_binary": r["qjs_binary"],
             "samples_per_case_per_engine": r["samples_per_case_per_engine"],
             "first_position_balanced": r["first_position_balanced"],
             "cpu": r["cpu"], "pmu": r["pmu"]}
            for p, r in zip(args.timing, runs)],
        "output_match_all_cases": all(
            c["output_match"] for r in runs for c in r["cases"].values()),
        "per_replicate": [],
    }

    for r in runs:
        cases = r["cases"]
        base = {e: {m: cases["baseline"][e][f"{m}_median"] for m in metrics}
                for e in ("qjs", "zjs")}

        def load(name, eng, m):
            return cases[name][eng][f"{m}_median"] - base[eng][m]

        rep = {"build_label": r["build_label"], "baseline": base,
               "raw_case_table": {}, "builtins": {}}

        for name, rec in cases.items():
            row = {"iterations": rec["iterations"],
                   "elements_per_iteration": rec["elements_per_iteration"],
                   "callback_count": rec["callback_count"],
                   "output_match": rec["output_match"]}
            for m in metrics:
                for e in ("qjs", "zjs"):
                    row[f"{e}_{m}_total"] = rec[e][f"{m}_median"]
                    row[f"{e}_{m}_load"] = load(name, e, m)
                qv = rec["qjs"][f"{m}_median"]
                row[f"ratio_{m}_total"] = rec["zjs"][f"{m}_median"] / qv
                ql = load(name, "qjs", m)
                row[f"ratio_{m}_load"] = (load(name, "zjs", m) / ql
                                          if ql else None)
                row[f"qjs_{m}_ipc"] = None
            rep["raw_case_table"][name] = row

        override = (meta.get("control_override") or {}) if meta else {}
        # bytecode loop scaffolding (counter, bound test, back jump) per element
        scaffold = {}
        if "s_loop" in cases and "s0_loop" in cases:
            for m in metrics:
                for eng in ("qjs", "zjs"):
                    per = load("s_loop", eng, m) / cases["s_loop"]["iterations"]
                    inter = load("s0_loop", eng, m) / cases["s0_loop"]["iterations"]
                    scaffold[(m, eng)] = (per - inter) / LEN
            rep["scaffold_slope_per_element"] = {
                m: {e: scaffold[(m, e)] for e in ("qjs", "zjs")}
                for m in metrics}

        for key in builtins:
            b = f"b_{key}"
            c, c0 = override.get(key, (f"c_{key}", f"c0_{key}"))
            b0 = f"b0_{key}"
            n_long = cases[b]["iterations"]
            n_zero = cases[b0]["iterations"]
            cb = cases[b]["callback_count"]
            entry = {"callback_count": cb, "elements_per_call": LEN,
                     "builtin_case": b, "control_case": c,
                     "builtin_len0_case": b0, "control_len0_case": c0}
            for m in metrics:
                e = {}
                for eng in ("qjs", "zjs"):
                    bl = load(b, eng, m)
                    cl = load(c, eng, m)
                    b0l = load(b0, eng, m)
                    c0l = load(c0, eng, m)
                    b_per_call = bl / n_long
                    c_per_call = cl / n_long
                    b_int = b0l / n_zero
                    c_int = c0l / n_zero
                    b_slope = (b_per_call - b_int) / LEN
                    c_slope = (c_per_call - c_int) / LEN
                    e[eng] = {
                        "builtin_load": bl,
                        "control_load": cl,
                        "builtin_per_call": b_per_call,
                        "control_per_call": c_per_call,
                        "builtin_per_callback": bl / cb,
                        "control_per_callback": cl / cb,
                        "builtin_intercept_per_call": b_int,
                        "control_intercept_per_call": c_int,
                        "builtin_slope_per_element": b_slope,
                        "control_slope_per_element": c_slope,
                        "bridge_tax_spec": (bl - cl) / cb,
                        "bridge_tax_slope": b_slope - c_slope,
                        "bridge_tax_scaffold_corrected":
                            (b_slope - (c_slope - scaffold[(m, eng)]))
                            if scaffold else None,
                        "builtin_over_control_ratio": bl / cl if cl else None,
                    }
                e["zjs_specific_bridge_tax_spec"] = (
                    e["zjs"]["bridge_tax_spec"] - e["qjs"]["bridge_tax_spec"])
                e["zjs_specific_bridge_tax_slope"] = (
                    e["zjs"]["bridge_tax_slope"] - e["qjs"]["bridge_tax_slope"])
                if scaffold:
                    e["zjs_specific_bridge_tax_scaffold_corrected"] = (
                        e["zjs"]["bridge_tax_scaffold_corrected"]
                        - e["qjs"]["bridge_tax_scaffold_corrected"])
                e["builtin_ratio_zjs_over_qjs"] = (
                    e["zjs"]["builtin_load"] / e["qjs"]["builtin_load"])
                e["control_ratio_zjs_over_qjs"] = (
                    e["zjs"]["control_load"] / e["qjs"]["control_load"])
                entry[m] = e
            rep["builtins"][key] = entry

        # extra controls
        extras = {}
        for m in metrics:
            ex = {}
            for eng in ("qjs", "zjs"):
                cbn = cases["b_map_native"]["callback_count"]
                ex[eng] = {
                    "map_js_callback_per_callback":
                        load("b_map", eng, m) / cbn,
                    "map_native_callback_per_callback":
                        load("b_map_native", eng, m) / cbn,
                    "map_native_control_per_callback":
                        load("c_map_native", eng, m) / cbn,
                    "map_native_bridge_tax_spec":
                        (load("b_map_native", eng, m)
                         - load("c_map_native", eng, m)) / cbn,
                    "foreach_thisarg_per_callback":
                        load("b_foreach_thisarg", eng, m) / cbn,
                    "foreach_plain_per_callback":
                        load("b_foreach", eng, m) / cbn,
                    "thisarg_delta_per_callback":
                        (load("b_foreach_thisarg", eng, m)
                         - load("b_foreach", eng, m)) / cbn,
                }
            ex["zjs_specific_map_native_bridge_tax_spec"] = (
                ex["zjs"]["map_native_bridge_tax_spec"]
                - ex["qjs"]["map_native_bridge_tax_spec"])
            ex["zjs_specific_thisarg_delta"] = (
                ex["zjs"]["thisarg_delta_per_callback"]
                - ex["qjs"]["thisarg_delta_per_callback"])
            # dead-store guard: the checksummed map twins must reproduce the
            # plain pair's builtin-minus-control difference
            if "b_map_sum" in cases:
                for eng in ("qjs", "zjs"):
                    cbn = cases["b_map_sum"]["callback_count"]
                    ex[eng]["map_sum_bridge_tax_spec"] = (
                        load("b_map_sum", eng, m)
                        - load("c_map_sum", eng, m)) / cbn
                    ex[eng]["map_plain_bridge_tax_spec"] = (
                        load("b_map", eng, m) - load("c_map", eng, m)) / cbn
                ex["zjs_specific_map_sum_bridge_tax_spec"] = (
                    ex["zjs"]["map_sum_bridge_tax_spec"]
                    - ex["qjs"]["map_sum_bridge_tax_spec"])
            # logical-NOT probe: cost of one `!` on a mutable local, per element
            if "n_plain" in cases:
                for eng in ("qjs", "zjs"):
                    n = cases["n_plain"]["iterations"]
                    ex[eng]["lnot_cost_per_element"] = (
                        load("n_neg", eng, m) - load("n_plain", eng, m)) / (n * LEN)
                ex["zjs_specific_lnot_cost_per_element"] = (
                    ex["zjs"]["lnot_cost_per_element"]
                    - ex["qjs"]["lnot_cost_per_element"])
            extras[m] = ex
        rep["extra_controls"] = extras
        out["per_replicate"].append(rep)

    # cross-replicate summary of the headline numbers
    summary = {}
    for m in metrics:
        rows = {}
        for key in builtins:
            vals_slope = [r["builtins"][key][m]["zjs_specific_bridge_tax_slope"]
                          for r in out["per_replicate"]]
            vals_spec = [r["builtins"][key][m]["zjs_specific_bridge_tax_spec"]
                         for r in out["per_replicate"]]
            qz = [r["builtins"][key][m]["qjs"]["bridge_tax_slope"]
                  for r in out["per_replicate"]]
            zz = [r["builtins"][key][m]["zjs"]["bridge_tax_slope"]
                  for r in out["per_replicate"]]
            vals_sc = [r["builtins"][key][m].get(
                "zjs_specific_bridge_tax_scaffold_corrected")
                for r in out["per_replicate"]]
            vals_sc = [v for v in vals_sc if v is not None]
            rows[key] = {
                "qjs_bridge_tax_slope_median": statistics.median(qz),
                "zjs_bridge_tax_slope_median": statistics.median(zz),
                "zjs_specific_bridge_tax_slope_median":
                    statistics.median(vals_slope),
                "zjs_specific_bridge_tax_slope_replicates": vals_slope,
                "zjs_specific_bridge_tax_spec_median":
                    statistics.median(vals_spec),
                "zjs_specific_bridge_tax_spec_replicates": vals_spec,
                "replicate_spread_slope":
                    (max(vals_slope) - min(vals_slope)) if len(vals_slope) > 1
                    else 0.0,
            }
            if vals_sc:
                qsc = [r["builtins"][key][m]["qjs"][
                    "bridge_tax_scaffold_corrected"]
                    for r in out["per_replicate"]]
                zsc = [r["builtins"][key][m]["zjs"][
                    "bridge_tax_scaffold_corrected"]
                    for r in out["per_replicate"]]
                rows[key].update({
                    "qjs_bridge_tax_scaffold_corrected_median":
                        statistics.median(qsc),
                    "zjs_bridge_tax_scaffold_corrected_median":
                        statistics.median(zsc),
                    "zjs_specific_bridge_tax_scaffold_corrected_median":
                        statistics.median(vals_sc),
                    "zjs_specific_bridge_tax_scaffold_corrected_replicates":
                        vals_sc,
                    "replicate_spread_scaffold_corrected":
                        (max(vals_sc) - min(vals_sc)) if len(vals_sc) > 1
                        else 0.0,
                })
        summary[m] = rows
        # dispersion across builtins of the headline column
        for tag, field in (("slope", "zjs_specific_bridge_tax_slope_median"),
                           ("scaffold_corrected",
                            "zjs_specific_bridge_tax_scaffold_corrected_median")):
            vals = [rows[k][field] for k in builtins if field in rows[k]]
            if not vals:
                continue
            summary.setdefault(f"{m}_dispersion", {})[tag] = {
                "values": {k: rows[k][field] for k in builtins
                           if field in rows[k]},
                "min": min(vals), "max": max(vals),
                "median": statistics.median(vals),
                "same_sign_positive": sum(1 for v in vals if v > 0),
                "count": len(vals),
            }
    out["summary"] = summary

    # ---- adjudication ------------------------------------------------------
    # The four rungs whose mirrored control needs no per-element result write
    # and whose builtin reads the source through the dense fast leg are the
    # uncontaminated measurement of the bridge. `filter` appears twice: the
    # always-false predicate is its clean form, the always-true one adds the
    # per-element write axis. `reduce` is excluded because zjs's reduce element
    # read has no dense fast leg at all (dynamic counts: hole_check 1.000 per
    # callback against 0.000 for the iteration-mode family).
    clean = ["foreach", "some", "every", "filter_false"]
    write_axis = ["map", "filter_true"]
    if builtins:
        m = "cycles"
        col = "zjs_specific_bridge_tax_scaffold_corrected_median"
        cv = [summary[m][k][col] for k in clean]
        out["verdict"] = {
            "metric": m,
            "estimator": "scaffold_corrected per-callback zjs_specific_bridge_tax",
            "clean_rungs": clean,
            "clean_values": {k: summary[m][k][col] for k in clean},
            "clean_median": statistics.median(cv),
            "clean_min": min(cv), "clean_max": max(cv),
            "clean_spread": max(cv) - min(cv),
            "clean_spread_fraction_of_median":
                (max(cv) - min(cv)) / statistics.median(cv),
            "all_rungs_same_direction":
                all(summary[m][k][col] > 0 for k in builtins),
            "no_result_array_rungs_positive":
                [k for k in ("foreach", "some", "every")
                 if summary[m][k][col] > 0],
            "write_axis_credit": {
                "filter_true_minus_filter_false":
                    summary[m]["filter_true"][col]
                    - summary[m]["filter_false"][col],
                "map_minus_foreach":
                    summary[m]["map"][col] - summary[m]["foreach"][col],
            },
            "reduce_excess_over_clean_median":
                summary[m]["reduce"][col] - statistics.median(cv),
            "qjs_self_calibration_clean":
                {k: summary[m][k]["qjs_bridge_tax_scaffold_corrected_median"]
                 for k in clean},
        }

    if args.verify:
        out["abi_and_invocation_verification"] = json.load(open(args.verify))
    if args.counts:
        out["dynamic_counts"] = json.load(open(args.counts))
    if args.record:
        out["cycle_attribution"] = json.load(open(args.record))

    with open(args.out, "w") as fh:
        json.dump(out, fh, indent=1)
        fh.write("\n")

    # ---- console table -----------------------------------------------------
    for m in metrics:
        print(f"\n=== {m}: per-callback bridge tax ===")
        print(f"{'builtin':14s} {'sc:qjs':>9s} {'sc:zjs':>9s} {'sc:SPEC':>10s} "
              f"{'sl:zjs-sp':>10s} {'spec-form':>10s} {'spread':>8s}")
        for key in builtins:
            s = summary[m][key]
            sc_q = s.get("qjs_bridge_tax_scaffold_corrected_median")
            sc_z = s.get("zjs_bridge_tax_scaffold_corrected_median")
            sc_s = s.get("zjs_specific_bridge_tax_scaffold_corrected_median")
            sp = s.get("replicate_spread_scaffold_corrected", 0.0)
            f = lambda v: f"{v:>9.2f}" if v is not None else f"{'-':>9s}"
            print(f"{key:14s} {f(sc_q)} {f(sc_z)} "
                  f"{sc_s if sc_s is None else round(sc_s, 2):>10} "
                  f"{s['zjs_specific_bridge_tax_slope_median']:>10.2f} "
                  f"{s['zjs_specific_bridge_tax_spec_median']:>10.2f} "
                  f"{sp:>8.2f}")
        d = summary.get(f"{m}_dispersion", {}).get("scaffold_corrected")
        if d:
            print(f"  dispersion: min {d['min']:.2f} max {d['max']:.2f} "
                  f"median {d['median']:.2f} positive {d['same_sign_positive']}"
                  f"/{d['count']}")
    print("\nwrote", args.out)


if __name__ == "__main__":
    main()
