#!/usr/bin/env python3
"""P7-42: assemble the deliverable results JSON from the raw collections."""
import json, os, statistics, sys

R = sys.argv[1]
OUT = sys.argv[2]
FAMS = ["foreach", "some", "every", "filter_false"]
CTRL = {"foreach": "c_foreach", "some": "c_some", "every": "c2_every",
        "filter_false": "c_filter_false"}
ZERO = {"foreach": ("b0_foreach", "c0_foreach"), "some": ("b0_some", "c0_some"),
        "every": ("b0_every", "c20_every"),
        "filter_false": ("b0_filter_false", "c0_filter_false")}
LEN = 100


def load_timing(path):
    r = json.load(open(path))
    C = r["cases"]
    base = {e: {m: C["baseline"][e][f"{m}_median"] for m in ("instructions", "cycles")}
            for e in ("qjs", "zjs")}
    def load(n, e, m):
        return C[n][e][f"{m}_median"] - base[e][m]
    return r, C, load


def estimators(C, load, fam, metric="cycles"):
    b = "b_" + fam if fam != "foreach" else "b_foreach"
    b = {"foreach": "b_foreach", "some": "b_some", "every": "b_every",
         "filter_false": "b_filter_false"}[fam]
    c = CTRL[fam]
    b0, c0 = ZERO[fam]
    out = {}
    for e in ("qjs", "zjs"):
        spec = (load(b, e, metric) - load(c, e, metric)) / C[b]["callback_count"]
        ib = load(b0, e, metric) / C[b0]["iterations"]
        ic = load(c0, e, metric) / C[c0]["iterations"]
        sb = (load(b, e, metric) / C[b]["iterations"] - ib) / LEN
        sc = (load(c, e, metric) / C[c]["iterations"] - ic) / LEN
        s0 = load("s0_loop", e, metric) / C["s0_loop"]["iterations"]
        ss = (load("s_loop", e, metric) / C["s_loop"]["iterations"] - s0) / LEN
        out[e] = {"spec": spec, "slope": sb - sc,
                  "scaffold_corrected": sb - (sc - ss), "scaffold": ss}
    out["zjs_specific"] = {k: out["zjs"][k] - out["qjs"][k]
                           for k in ("spec", "slope", "scaffold_corrected")}
    return out


res = {
    "line": "P7-42",
    "question": ("within the shared builtin->bytecode callback bridge tax, is "
                 "there one stage hit on every callback that explains >=40% "
                 "(~11 cycles/callback) and is isolable by a single-mechanism "
                 "change"),
    "baseline_commit": "0e4ee496",
    "branch": "perf/qjs-align-p7-builtin-bridge-phase",
    "host": {"cpu_pinned": 19, "core": "Cortex-X925", "pmu": "armv8_pmuv3_1",
             "cpus": 20, "big_little": True,
             "exclusive_lock_for_timing_and_record": True,
             "shared_lock_for_builds": True},
    "binaries": {
        "zjs_build_A1_sha256": "6cfceba7c10bc98405ce68e9b39160f6740e72981bcf154ea4cc0d785d7e8832",
        "zjs_build_A2_sha256": "6cfceba7c10bc98405ce68e9b39160f6740e72981bcf154ea4cc0d785d7e8832",
        "two_cold_builds_byte_identical": True,
        "note": ("both cold-cache builds of 0e4ee496 produced the identical "
                 "binary, so this tree contributes no build bistability; the "
                 "noise ruler is two independent full timing sweeps (T1, T2) "
                 "on the same binary"),
        "differs_from_P7_41_binary": True,
        "P7_41_zjs_sha256_prefix": "77178af4",
        "qjs_sha256": "b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d",
        "qjs_pinned_commit": "04be2460",
    },
    "src_diff_against_baseline_empty": True,
    "diagnostic_counter_used": False,
    "noinline_forced": False,
}

# ---- canonical tax re-established on this tree -------------------------------
reps = {t: load_timing(os.path.join(R, f"P7-42-timing-{t}.json")) for t in ("T1", "T2")}
tax = {}
for fam in FAMS:
    tax[fam] = {}
    for t, (r, C, load) in reps.items():
        tax[fam][t] = estimators(C, load, fam)
res["canonical_tax_reestablished"] = {
    "per_family": tax,
    "median_over_families_and_replicates": {
        k: statistics.median([tax[f][t]["zjs_specific"][k]
                              for f in FAMS for t in ("T1", "T2")])
        for k in ("spec", "slope", "scaffold_corrected")},
    "P7_41_canonical_scaffold_corrected": 27.43,
    "normalisation_used_for_stage_shares": "scaffold_corrected median on this tree",
    "replicate_spread_scaffold_corrected": {
        f: abs(tax[f]["T1"]["zjs_specific"]["scaffold_corrected"]
               - tax[f]["T2"]["zjs_specific"]["scaffold_corrected"]) for f in FAMS},
    "bytecode_loop_scaffold_cycles_per_element": {
        e: statistics.median([reps[t][0] and estimators(reps[t][1], reps[t][2], f)[e]["scaffold"]
                              for f in FAMS for t in ("T1", "T2")])
        for e in ("qjs", "zjs")},
}

# ---- event class decomposition ------------------------------------------------
st = json.load(open(os.path.join(R, "P7-42-stat-A1.json")))
pairs = [("b_foreach", "c_foreach"), ("b_some", "c_some"),
         ("b_every", "c2_every"), ("b_filter_false", "c_filter_false")]
ev = {}
for g, evs in st["event_groups"].items():
    for e in evs:
        for b, c in pairs:
            row = {}
            for eng in ("qjs", "zjs"):
                bl = (st["cases"][f"{g}:{b}"][eng][e]["median"]
                      - st["cases"][f"{g}:baseline"][eng][e]["median"])
                cl = (st["cases"][f"{g}:{c}"][eng][e]["median"]
                      - st["cases"][f"{g}:baseline"][eng][e]["median"])
                row[eng] = (bl - cl) / st["cases"][f"{g}:{b}"]["callback_count"]
            row["zjs_specific"] = row["zjs"] - row["qjs"]
            ev.setdefault(e, {})[b] = row
res["event_class_decomposition_per_callback"] = ev

# ---- dynamic hit counts -------------------------------------------------------
res["dynamic_hits_per_callback"] = json.load(
    open(os.path.join(R, "P7-42-counts-A1.json")))

# ---- per stage table ----------------------------------------------------------
ph = json.load(open(os.path.join(R, "P7-42-phase3-A1.json")))
TAX = res["canonical_tax_reestablished"]["median_over_families_and_replicates"]["scaffold_corrected"]
stages = {}
for s in ph["families"]["foreach"]["stages"]:
    rows = {f: ph["families"][f]["stages"][s] for f in FAMS}
    med = {k: statistics.median([rows[f].get(k, 0.0) for f in FAMS])
           for k in ("cyc_builtin_per_callback", "ins_builtin_per_callback",
                     "stl_builtin_per_callback", "cyc_control_per_callback",
                     "ins_control_per_callback", "stl_control_per_callback")}
    stages[s] = {
        "per_family": {f: {k: rows[f].get(k) for k in
                           ("cyc_builtin_per_callback",
                            "cyc_builtin_per_callback_min",
                            "cyc_builtin_per_callback_max",
                            "ins_builtin_per_callback",
                            "stl_builtin_per_callback",
                            "cyc_control_per_callback",
                            "ipc_builtin", "stall_frac_builtin")}
                       for f in FAMS},
        "median_cycles_per_callback": med["cyc_builtin_per_callback"],
        "median_instructions_per_callback": med["ins_builtin_per_callback"],
        "median_backend_stall_cycles_per_callback": med["stl_builtin_per_callback"],
        "median_ipc": (med["ins_builtin_per_callback"] / med["cyc_builtin_per_callback"]
                       if med["cyc_builtin_per_callback"] else None),
        "median_control_cycles_per_callback": med["cyc_control_per_callback"],
        "share_of_canonical_tax_percent": (
            100.0 * med["cyc_builtin_per_callback"] / TAX),
        "is_bridge_stage": rows["foreach"]["is_bridge_stage"],
    }
res["stage_table"] = {"canonical_tax_used": TAX, "stages": stages}
res["stage_table_definition"] = json.load(
    open("tools/perf/builtin_bridge/stages_bridge.json"))
res["bridge_stage_totals_per_family"] = {
    f: {"cycles_per_callback": ph["families"][f]["bridge_stage_total_cycles_per_callback"],
        "instructions_per_callback": ph["families"][f]["bridge_stage_total_instructions_per_callback"],
        "spec_tax_cycles_per_callback": ph["families"][f]["zjs_specific_bridge_tax_spec_cycles"],
        "process_per_callback": ph["families"][f]["process_per_callback"]}
    for f in FAMS}

# ---- arity sweep (real-timing single-mechanism differential) -------------------
sweep = {}
for t, (r, C, load) in reps.items():
    for fam, pre in (("foreach", "k_foreach_a"), ("some", "k_some_a")):
        for a in (0, 1, 2, 3):
            b = f"{pre}{a}"
            if b not in C:
                continue
            c = f"k_c_{fam}_a{a}"
            n = C[b]["callback_count"]
            sweep.setdefault(fam, {}).setdefault(f"a{a}", {})[t] = {
                "zjs_builtin_cycles_per_callback": load(b, "zjs", "cycles") / n,
                "zjs_builtin_instructions_per_callback": load(b, "zjs", "instructions") / n,
                "zjs_control_cycles_per_callback": load(c, "zjs", "cycles") / n,
                "qjs_builtin_cycles_per_callback": load(b, "qjs", "cycles") / n,
            }
res["arity_sweep"] = sweep

json.dump(res, open(OUT, "w"), indent=1)
open(OUT, "a").write("\n")
print("wrote", OUT)
print("canonical scaffold_corrected tax on this tree:", round(TAX, 2))
top = sorted(((v["median_cycles_per_callback"], k) for k, v in stages.items()
              if v["is_bridge_stage"]), reverse=True)[:4]
print("top bridge stages:", [(k, round(c, 2), round(100*c/TAX, 1)) for c, k in top])
