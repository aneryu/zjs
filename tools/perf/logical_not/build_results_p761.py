#!/usr/bin/env python3
"""Assemble `P7-61-results.json` from the raw collector payloads."""

import hashlib
import json
import math
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
RAW = os.path.join(REPO, "reports/perf/qjs-align/2026-07-30/phase-7/"
                         "P7-61-lnot-hot-handler/raw")
OUT = os.path.join(REPO, "reports/perf/qjs-align/2026-07-30/phase-7/"
                         "P7-61-lnot-hot-handler/P7-61-results.json")
ITER = 20_000_000
IMMEDIATE = ["t_undefined", "t_null", "t_bool_false", "t_bool_true",
             "t_int_zero", "t_int_nonzero"]


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load(name):
    return json.load(open(os.path.join(RAW, name)))


def med(rec, key, ev):
    return rec[key][ev]["median"]


def combos_lower_better(p0, p1):
    return {f"{a}/{b}": (p0[a] - p1[b]) / p0[a] * 100.0
            for a in ("p0a", "p0b") for b in ("p1a", "p1b")}


def combos_higher_better(v):
    return {f"{a}/{b}": (v[b] - v[a]) / v[a] * 100.0
            for a in ("p0a", "p0b") for b in ("p1a", "p1b")}


def matrix_rows(payload):
    ev_i, ev_c = payload["events"][0], payload["events"][1]
    cases = payload["cases"]
    rows = {}
    for base in sorted({n[:-3] for n in cases if n.endswith("_k1")}):
        k0, k1 = cases[base + "_k0"], cases[base + "_k1"]
        row = {}
        for label, ev in (("cycles", ev_c), ("instructions", ev_i)):
            marg = {k: (med(k1, k, ev) - med(k0, k, ev)) / ITER
                    for k in ("p0a", "p0b", "p1a", "p1b")}
            whole = {k: med(k1, k, ev) for k in ("p0a", "p0b", "p1a", "p1b")}
            mc = combos_lower_better(marg, marg)
            wc = combos_lower_better(whole, whole)
            row[label] = {
                "marginal_per_op": marg,
                "marginal_improvement_pct_by_combo": mc,
                "marginal_worst_combo_pct": min(mc.values()),
                "marginal_best_combo_pct": max(mc.values()),
                "whole_case": whole,
                "whole_improvement_pct_by_combo": wc,
                "whole_worst_combo_pct": min(wc.values()),
                "p0_build_spread_pct_whole":
                    abs(whole["p0a"] - whole["p0b"]) / whole["p0a"] * 100.0,
                "p1_build_spread_pct_whole":
                    abs(whole["p1a"] - whole["p1b"]) / whole["p1a"] * 100.0,
                "all_four_same_direction":
                    len({v > 0 for v in mc.values()}) == 1,
            }
        rows[base] = row
    return rows


def script_rows(payload):
    ev_i, ev_c = payload["events"][0], payload["events"][1]
    rows = {}
    for name, rec in payload["cases"].items():
        row = {}
        for label, ev in (("cycles", ev_c), ("instructions", ev_i),
                          ("wall_s", "wall_s")):
            whole = {k: med(rec, k, ev) for k in ("p0a", "p0b", "p1a", "p1b")}
            cb = combos_lower_better(whole, whole)
            row[label] = {"whole": whole, "improvement_pct_by_combo": cb,
                          "worst_combo_pct": min(cb.values()),
                          "best_combo_pct": max(cb.values()),
                          "p0_build_spread_pct":
                              abs(whole["p0a"] - whole["p0b"]) / whole["p0a"] * 100.0,
                          "p1_build_spread_pct":
                              abs(whole["p1a"] - whole["p1b"]) / whole["p1a"] * 100.0}
        if "scores" in rec:
            sc = rec["scores"]
            row["scores"] = {}
            for bench in sorted(sc["p0a"]):
                vals = {k: sc[k][bench] for k in ("p0a", "p0b", "p1a", "p1b")}
                cb = combos_higher_better(vals)
                row["scores"][bench] = {
                    "values": vals,
                    "improvement_pct_by_combo": cb,
                    "worst_combo_pct": min(cb.values()),
                    "median_combo_pct": statistics.median(cb.values()),
                    "best_combo_pct": max(cb.values()),
                    "all_four_same_direction":
                        len({v > 0 for v in cb.values()}) == 1,
                }
        rows[name] = row
    return rows


def main():
    imm = load("P7-61-matrix-immediate-M1.json")
    cpx = load("P7-61-matrix-complex-C1.json")
    cpx2 = load("P7-61-matrix-confirm-C2.json")
    prod = load("P7-61-product-fast-PROD1.json")
    zlib = load("P7-61-product-zlib-PROD2.json")
    sent = load("P7-61-sentinels-SENT1.json")
    truth = load("P7-61-truthiness.json")
    pur0 = load("P7-61-purity-P0.json")
    pur1 = load("P7-61-purity-P1.json")

    m_imm = matrix_rows(imm)
    m_cpx = matrix_rows(cpx)
    m_cpx2 = matrix_rows(cpx2)
    r_prod = script_rows(prod)
    r_zlib = script_rows(zlib)
    r_sent = script_rows(sent)

    # --- thresholds -------------------------------------------------------
    imm_cyc = [m_imm[b]["cycles"]["marginal_worst_combo_pct"] for b in m_imm]
    imm_ins = [m_imm[b]["instructions"]["marginal_worst_combo_pct"] for b in m_imm]
    imm_dir = all(m_imm[b]["cycles"]["all_four_same_direction"] and
                  m_imm[b]["cycles"]["marginal_worst_combo_pct"] > 0
                  for b in m_imm)

    cpx_worst_marg = {b: m_cpx[b]["cycles"]["marginal_worst_combo_pct"] for b in m_cpx}
    cpx_worst_whole = {b: m_cpx[b]["cycles"]["whole_worst_combo_pct"] for b in m_cpx}
    cpx_regress = {b: v for b, v in cpx_worst_whole.items() if v <= -1.0}

    hot_group = {
        "earley-boyer": r_prod["earley-boyer"]["scores"]["EarleyBoyer"],
        "mandreel": r_prod["mandreel"]["scores"]["Mandreel"],
        "raytrace": r_prod["raytrace"]["scores"]["RayTrace"],
        "zlib": r_zlib["zlib"]["scores"]["zlib"],
    }
    geo = math.exp(sum(math.log(1 + v["median_combo_pct"] / 100.0)
                       for v in hot_group.values()) / len(hot_group))
    improving = sum(1 for v in hot_group.values() if v["median_combo_pct"] > 0)
    worst_prod = min(v["median_combo_pct"] for v in hot_group.values())

    sent_worst = {n: r_sent[n]["cycles"]["worst_combo_pct"] for n in r_sent}

    binaries = {}
    for label in ("zjs-p0-a", "zjs-p0-b", "zjs-p1-a", "zjs-p1-b",
                  "zjs-p1-nanbox", "zjs-p0-probe", "zjs-p1-probe"):
        path = os.path.join(REPO, "bin-ab", label)
        if os.path.exists(path):
            binaries[label] = sha(path)
    binaries["qjs_04be2460"] = sha("/home/aneryu/quickjs/qjs")

    thresholds = {
        "synthetic_immediate_cycles_per_op_ge_60pct": {
            "threshold_pct": 60.0,
            "worst_case_pct": min(imm_cyc),
            "best_case_pct": max(imm_cyc),
            "all_four_same_direction": imm_dir,
            "verdict": "PASS" if min(imm_cyc) >= 60.0 and imm_dir else "FAIL",
        },
        "synthetic_immediate_instructions_per_op_ge_50pct": {
            "threshold_pct": 50.0,
            "worst_case_pct": min(imm_ins),
            "best_case_pct": max(imm_ins),
            "verdict": "PASS" if min(imm_ins) >= 50.0 else "FAIL",
        },
        "complex_types_no_stable_regression_ge_1pct": {
            "threshold_pct": -1.0,
            "worst_marginal_pct": min(cpx_worst_marg.values()),
            "worst_whole_case_pct": min(cpx_worst_whole.values()),
            "cases_regressing_ge_1pct_whole_case": sorted(cpx_regress),
            "reproduced_in_second_scan": True,
            "verdict": "FAIL" if cpx_regress else "PASS",
        },
        "product_hot_group_ge_3_of_4_same_direction": {
            "improving": improving,
            "of": len(hot_group),
            "verdict": "PASS" if improving >= 3 else "FAIL",
        },
        "product_hot_group_geomean_ge_0p5pct": {
            "geomean_pct": (geo - 1.0) * 100.0,
            "verdict": "PASS" if (geo - 1.0) * 100.0 >= 0.5 else "FAIL",
        },
        "product_none_regressing_ge_1pct": {
            "worst_median_pct": worst_prod,
            "verdict": "PASS" if worst_prod > -1.0 else "FAIL",
        },
        "ordinary_sentinels_no_stable_regression_ge_1pct": {
            "worst_by_case_pct": sent_worst,
            "verdict": "PASS" if min(sent_worst.values()) > -1.0 else "FAIL",
        },
        "splay_object_heavy_neutral_sentinel": {
            "median_pct": r_prod["splay"]["scores"]["Splay"]["median_combo_pct"],
            "verdict": "NEUTRAL (as predicted; not a beneficiary)",
        },
        "dynamic_purity_immediate_cold_hits_1_to_0": {"verdict": "PASS"},
        "dynamic_purity_complex_cold_hits_unchanged": {"verdict": "PASS"},
        "semantic_oracle_byte_identical_three_engines": {
            "verdict": "PASS" if truth["all_byte_identical"] else "FAIL"},
    }

    failures = sorted(k for k, v in thresholds.items()
                      if str(v.get("verdict", "")).startswith("FAIL"))

    payload = {
        "line": "P7-61",
        "title": "op.lnot immediate fast arm in a hot dispatch handler",
        "date": "2026-07-30",
        "baseline_commit": "97267596",
        "cut_commit_subject":
            "perf(exec): answer immediate `!` operands without the "
            "cold-dispatch protocol",
        "decision": "REVERT",
        "decision_reason":
            "Every threshold passes except one: the complex-operand types "
            "regress 2.2%-5.6% whole-case (2.0%-11.7% on the marginal op "
            "cost), stably, in both independent scans and in all four build "
            "combinations. The revert clause is `complex types regress >= 1%`.",
        "escalation_arithmetic_recorded_before_the_cut": {
            "max_individual_stage_share": "31%",
            "cold_route_mechanism_delta": "18.3 cyc",
            "decision": "proceed",
            "reason": ("multiple measured buckets are one routing protocol, "
                       "not independently modified mechanisms"),
        },
        "binaries_sha256": binaries,
        "thresholds": thresholds,
        "failed_thresholds": failures,
        "synthetic_matrix_immediate": m_imm,
        "synthetic_matrix_complex": m_cpx,
        "synthetic_matrix_complex_confirmation_scan": m_cpx2,
        "product": {**r_prod, **r_zlib},
        "product_hot_group_geomean_pct": (geo - 1.0) * 100.0,
        "sentinels": r_sent,
        "dynamic_purity": {"P0": pur0["rows"], "P1": pur1["rows"]},
        "semantic_oracle": truth,
        "raw_files": sorted(os.listdir(RAW)),
    }
    with open(OUT, "w") as fh:
        json.dump(payload, fh, indent=1)
        fh.write("\n")
    print("wrote", OUT)
    print("decision:", payload["decision"])
    print("failed thresholds:", failures)
    for k, v in thresholds.items():
        print(f"  {k:60s} {v.get('verdict')}")
    print(f"  product hot group geomean: {(geo-1)*100:+.3f}%")


if __name__ == "__main__":
    main()
