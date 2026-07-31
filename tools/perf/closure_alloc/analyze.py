#!/usr/bin/env python3
"""P7-50 analyzer: turn the raw collector artefacts into per-op tables.

Every per-op number here is a DIFFERENCE against the matching `reuse` baseline
of the same lifetime, so the loop, the induction variable, the array-element
store and the retain/clear pass structure cancel and what remains is the
marginal cost of creating (and, for the churn lifetime, releasing) one closure.

The retain lifetime's samples alternate fill/clear by construction, so its
wall-clock creation and release costs come from the odd- and even-indexed raw
samples respectively rather than from the harness's pooled median.
"""

import argparse
import json
import statistics

SHAPES = [
    "reuse", "arrow_nocap", "fnexpr_nocap", "arrow_cap1", "fnexpr_cap1",
    "arrow_cap4", "arrow_loopbind", "arrow_call",
]


def med(values):
    return statistics.median(values) if values else float("nan")


def wall_per_op(matrix, case, zlabel, qlabel, inner, lifetime):
    key = "%s|%s|%s" % (case, zlabel, qlabel)
    series = matrix["wall"]["data"][key]
    out = {}
    for engine in ("zjs", "qjs"):
        pooled = []
        fill = []
        clear = []
        for rec in series[engine]:
            samples = rec["samples_ns"]
            pooled.extend(samples)
            # sample index 0 is call warmup+1; warmup is even so that call is
            # odd-numbered, i.e. a fill.
            fill.extend(samples[0::2])
            clear.extend(samples[1::2])
        out[engine] = {
            "pooled_median_ns": med(pooled),
            "fill_median_ns": med(fill) if lifetime == "retain" else None,
            "clear_median_ns": med(clear) if lifetime == "retain" else None,
            "n_samples": len(pooled),
        }
    return out


def pmu_per_op(matrix, case, label, inner, lifetime):
    key = "%s|%s" % (case, label)
    series = matrix["pmu_combined"]["data"][key]
    lo_n = matrix["pmu_combined"]["lo"]
    hi_n = matrix["pmu_combined"]["hi"]
    # A retain fill+clear PAIR is one churn-equivalent op set, so the delta of
    # (hi - lo) samples contains (hi-lo)/2 pairs.
    ops = (hi_n - lo_n) * inner
    if lifetime == "retain":
        ops = ops // 2
    out = {}
    for event in ("instructions", "cycles", "task-clock"):
        lo = med([r[event] for r in series["lo"]])
        hi = med([r[event] for r in series["hi"]])
        out[event] = (hi - lo) / ops
    out["ns"] = out.pop("task-clock") * 1e6  # task-clock is in msec
    return out


def split_per_op(matrix, case, label, inner):
    key = "%s|%s" % (case, label)
    series = matrix["pmu_split"]["data"].get(key)
    if series is None:
        return None
    out = {}
    for event in ("instructions", "cycles"):
        i0 = med([r[event] for r in series["i0"]])
        i1 = med([r[event] for r in series["i1"]])
        i2 = med([r[event] for r in series["i2"]])
        out[event] = {"fill": (i1 - i0) / inner, "clear": (i2 - i1) / inner}
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", required=True)
    parser.add_argument("--counts", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    matrix = json.load(open(args.matrix))
    counts = json.load(open(args.counts))
    inner = matrix["inner_loop_n"]

    zlabels = [k for k in matrix["binaries"] if k.startswith("zjs")]
    qlabels = [k for k in matrix["binaries"] if k.startswith("qjs")]

    result = {
        "line": "P7-50",
        "inner_loop_n": inner,
        "cpu": matrix["cpu"],
        "pmu_device": matrix["pmu_device"],
        "binaries": matrix["binaries"],
        "wall": {},
        "pmu": {},
        "split": {},
        "counts_per_op": counts["per_op"],
        "baseline_subtracted": {},
    }

    for lifetime in ("retain", "churn"):
        for shape in SHAPES:
            case = "closure_%s_%s" % (shape, lifetime)
            for zlabel in zlabels:
                for qlabel in qlabels:
                    result["wall"]["%s|%s|%s" % (case, zlabel, qlabel)] = \
                        wall_per_op(matrix, case, zlabel, qlabel, inner,
                                    lifetime)
            for label in matrix["binaries"]:
                result["pmu"]["%s|%s" % (case, label)] = \
                    pmu_per_op(matrix, case, label, inner, lifetime)
                if lifetime == "retain":
                    sp = split_per_op(matrix, case, label, inner)
                    if sp:
                        result["split"]["%s|%s" % (case, label)] = sp

    # baseline-subtracted marginal cost of one closure
    for lifetime in ("retain", "churn"):
        base = "closure_reuse_%s" % lifetime
        for shape in SHAPES:
            if shape == "reuse":
                continue
            case = "closure_%s_%s" % (shape, lifetime)
            for label in matrix["binaries"]:
                a = result["pmu"]["%s|%s" % (case, label)]
                b = result["pmu"]["%s|%s" % (base, label)]
                entry = {k: a[k] - b[k] for k in a}
                if lifetime == "retain":
                    sa = result["split"].get("%s|%s" % (case, label))
                    sb = result["split"].get("%s|%s" % (base, label))
                    if sa and sb:
                        entry["split"] = {
                            ev: {ph: sa[ev][ph] - sb[ev][ph]
                                 for ph in ("fill", "clear")}
                            for ev in ("instructions", "cycles")
                        }
                result["baseline_subtracted"]["%s|%s" % (case, label)] = entry

    for lifetime in ("retain", "churn"):
        base = "closure_reuse_%s" % lifetime
        for shape in SHAPES:
            if shape == "reuse":
                continue
            case = "closure_%s_%s" % (shape, lifetime)
            for zlabel in zlabels:
                for qlabel in qlabels:
                    a = result["wall"]["%s|%s|%s" % (case, zlabel, qlabel)]
                    b = result["wall"]["%s|%s|%s" % (base, zlabel, qlabel)]
                    key = "wall|%s|%s|%s" % (case, zlabel, qlabel)
                    entry = {}
                    for engine in ("zjs", "qjs"):
                        entry[engine] = {
                            "pooled_ns_per_op":
                                (a[engine]["pooled_median_ns"]
                                 - b[engine]["pooled_median_ns"]) / inner,
                        }
                        if lifetime == "retain":
                            entry[engine]["fill_ns_per_op"] = (
                                a[engine]["fill_median_ns"]
                                - b[engine]["fill_median_ns"]) / inner
                            entry[engine]["clear_ns_per_op"] = (
                                a[engine]["clear_median_ns"]
                                - b[engine]["clear_median_ns"]) / inner
                    result["baseline_subtracted"][key] = entry

    with open(args.out, "w") as handle:
        json.dump(result, handle, indent=1)
    print(args.out)


if __name__ == "__main__":
    main()
