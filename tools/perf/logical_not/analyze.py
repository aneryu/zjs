#!/usr/bin/env python3
"""P7-60 analysis: derive per-`op.lnot` costs and the corpus Pareto share."""

import argparse
import json
import os
import statistics

N = 20_000_000

TYPES = ["bool_true", "bool_false", "int_nonzero", "int_zero",
         "double_nonzero", "double_pos_zero", "double_neg_zero", "double_nan",
         "undefined", "null",
         "string_short", "string_empty", "string_long", "string_rope",
         "object_plain", "object_array", "object_function",
         "bigint_short", "bigint_zero", "bigint_wide", "symbol"]

BRANCH_TYPES = ["bool_true", "int_nonzero", "double_nonzero",
                "string_short", "object_plain"]


def med(rec, eng, ev):
    return rec[eng][ev]["median"]


def load(path):
    d = json.load(open(path))
    ev = d["events"]
    return d, ev[0], ev[1]


def per_op(d, insn_ev, cyc_ev, hi, lo, eng, n=N):
    c = d["cases"]
    return {
        "insn": (med(c[hi], eng, insn_ev) - med(c[lo], eng, insn_ev)) / n,
        "cyc": (med(c[hi], eng, cyc_ev) - med(c[lo], eng, cyc_ev)) / n,
    }


def ipc(x):
    return x["insn"] / x["cyc"] if x["cyc"] else None


def type_matrix(d, insn_ev, cyc_ev):
    rows = {}
    for t in TYPES:
        hi, lo = f"t_{t}_k1", f"t_{t}_k0"
        if hi not in d["cases"] or lo not in d["cases"]:
            continue
        q = per_op(d, insn_ev, cyc_ev, hi, lo, "qjs")
        z = per_op(d, insn_ev, cyc_ev, hi, lo, "zjs")
        rows[t] = {
            "qjs_insn": q["insn"], "qjs_cyc": q["cyc"], "qjs_ipc": ipc(q),
            "zjs_insn": z["insn"], "zjs_cyc": z["cyc"], "zjs_ipc": ipc(z),
            "delta_insn": z["insn"] - q["insn"],
            "delta_cyc": z["cyc"] - q["cyc"],
        }
    return rows


def bool_slope(d, insn_ev, cyc_ev):
    out = {}
    for eng in ("qjs", "zjs"):
        steps_c, steps_i = [], []
        for k in range(1, 4):
            a, b = f"s_bool_k{k}", f"s_bool_k{k+1}"
            steps_c.append((med(d["cases"][b], eng, cyc_ev)
                            - med(d["cases"][a], eng, cyc_ev)) / N)
            steps_i.append((med(d["cases"][b], eng, insn_ev)
                            - med(d["cases"][a], eng, insn_ev)) / N)
        out[eng] = {"cyc_steps": steps_c, "insn_steps": steps_i,
                    "cyc_mean": statistics.mean(steps_c),
                    "insn_mean": statistics.mean(steps_i),
                    "cyc_median": statistics.median(steps_c)}
    out["delta_cyc_mean"] = out["zjs"]["cyc_mean"] - out["qjs"]["cyc_mean"]
    out["delta_insn_mean"] = out["zjs"]["insn_mean"] - out["qjs"]["insn_mean"]
    return out


def branch_family(d, insn_ev, cyc_ev):
    rows = {}
    for t in BRANCH_TYPES:
        none, iff, lnot = f"r_{t}_none", f"r_{t}_if", f"r_{t}_lnot"
        if none not in d["cases"]:
            continue
        row = {}
        for eng in ("qjs", "zjs"):
            row[f"{eng}_branch_cyc"] = per_op(d, insn_ev, cyc_ev, iff, none, eng)["cyc"]
            row[f"{eng}_branch_insn"] = per_op(d, insn_ev, cyc_ev, iff, none, eng)["insn"]
            row[f"{eng}_lnot_cyc"] = per_op(d, insn_ev, cyc_ev, lnot, iff, eng)["cyc"]
            row[f"{eng}_lnot_insn"] = per_op(d, insn_ev, cyc_ev, lnot, iff, eng)["insn"]
        row["delta_branch_cyc"] = row["zjs_branch_cyc"] - row["qjs_branch_cyc"]
        row["delta_lnot_cyc"] = row["zjs_lnot_cyc"] - row["qjs_lnot_cyc"]
        rows[t] = row
    return rows


def pareto(count_path, cyc_path, delta_cyc, zjs_cyc):
    counts = json.load(open(count_path))["entries"]
    cycles = json.load(open(cyc_path))["entries"]
    rows = {}
    for key, rec in cycles.items():
        hits = rec.get("lnot_total")
        if hits is None:
            hits = counts.get(key, {}).get("lnot_total", 0)
        cyc = rec.get("cycles")
        if not cyc:
            continue
        rows[key] = {
            "lnot_hits": hits,
            "total_cycles": cyc,
            "hits_per_Mcycle": 1e6 * hits / cyc,
            "tags": rec.get("tags") or counts.get(key, {}).get("tags", {}),
            "estimated_excess_cycles": hits * delta_cyc,
            "estimated_excess_share": hits * delta_cyc / cyc,
            "estimated_absolute_cycles": hits * zjs_cyc,
            "estimated_absolute_share": hits * zjs_cyc / cyc,
            "wall_s": rec.get("wall_s"),
        }
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", required=True, nargs="+")
    ap.add_argument("--count", default=None)
    ap.add_argument("--cycles", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    scans = {}
    for path in args.matrix:
        d, insn_ev, cyc_ev = load(path)
        label = d["build_label"]
        scans[label] = {
            "source": os.path.basename(path),
            "zjs_binary": d["zjs_binary"],
            "qjs_binary": d["qjs_binary"],
            "samples_per_case_per_engine": d["samples_per_case_per_engine"],
            "first_position_balanced": d["first_position_balanced"],
            "output_mismatches": [k for k, v in d["cases"].items()
                                  if not v["output_match"]],
            "type_matrix": type_matrix(d, insn_ev, cyc_ev),
            "bool_slope": bool_slope(d, insn_ev, cyc_ev),
            "branch_family": branch_family(d, insn_ev, cyc_ev),
        }

    print("=== bool slope (pure single-opcode, byte-exact steps) ===")
    for label, s in scans.items():
        b = s["bool_slope"]
        print(f"{label}: zjs {b['zjs']['cyc_mean']:.2f} cyc / "
              f"{b['zjs']['insn_mean']:.2f} insn   "
              f"qjs {b['qjs']['cyc_mean']:.2f} / {b['qjs']['insn_mean']:.2f}   "
              f"delta {b['delta_cyc_mean']:.2f} cyc / {b['delta_insn_mean']:.2f} insn")
        print("   zjs steps", [round(x, 2) for x in b["zjs"]["cyc_steps"]],
              " qjs steps", [round(x, 2) for x in b["qjs"]["cyc_steps"]])

    print("\n=== type matrix: cycles per executed op.lnot ===")
    labels = list(scans)
    hdr = f"{'operand type':18s}"
    for l in labels:
        hdr += f" | {l}: qjs   zjs  delta"
    print(hdr)
    for t in TYPES:
        line = f"{t:18s}"
        for l in labels:
            r = scans[l]["type_matrix"].get(t)
            if r is None:
                line += " |    --    --    --"
            else:
                line += f" | {r['qjs_cyc']:6.2f} {r['zjs_cyc']:6.2f} {r['delta_cyc']:+6.2f}"
        print(line)

    print("\n=== type matrix: instructions per executed op.lnot (scan 1) ===")
    l0 = labels[0]
    for t in TYPES:
        r = scans[l0]["type_matrix"].get(t)
        if r:
            print(f"{t:18s} qjs {r['qjs_insn']:7.2f} (IPC {r['qjs_ipc']:.2f})   "
                  f"zjs {r['zjs_insn']:7.2f} (IPC {r['zjs_ipc']:.2f})   "
                  f"delta {r['delta_insn']:+7.2f}")

    print("\n=== branch family: cyc for (get_loc+branch) and for the extra lnot ===")
    for t in BRANCH_TYPES:
        r = scans[l0]["branch_family"].get(t)
        if r:
            print(f"{t:16s} branch: qjs {r['qjs_branch_cyc']:6.2f} zjs {r['zjs_branch_cyc']:6.2f}"
                  f"   extra lnot: qjs {r['qjs_lnot_cyc']:6.2f} zjs {r['zjs_lnot_cyc']:6.2f}")

    result = {"scans": scans}

    if args.count and args.cycles:
        b = scans[l0]["bool_slope"]
        delta = b["delta_cyc_mean"]
        zjs_abs = b["zjs"]["cyc_mean"]
        rows = pareto(args.count, args.cycles, delta, zjs_abs)
        result["pareto"] = {
            "per_event_delta_cycles": delta,
            "per_event_zjs_cycles": zjs_abs,
            "entries": rows,
        }
        print(f"\n=== Pareto share (delta {delta:.2f} cyc/event, "
              f"zjs absolute {zjs_abs:.2f}) ===")
        print(f"{'entry':24s} {'hits':>12} {'cycles':>15} {'hits/Mcyc':>10} "
              f"{'excess_cyc':>13} {'excess%':>8} {'abs%':>7}")
        for k, r in sorted(rows.items(), key=lambda kv: -kv[1]["estimated_excess_share"]):
            print(f"{k.split('/')[-1]:24s} {r['lnot_hits']:>12} {r['total_cycles']:>15.0f} "
                  f"{r['hits_per_Mcycle']:>10.1f} {r['estimated_excess_cycles']:>13.0f} "
                  f"{100*r['estimated_excess_share']:>7.3f}% "
                  f"{100*r['estimated_absolute_share']:>6.3f}%")

    if args.out:
        with open(args.out, "w") as fh:
            json.dump(result, fh, indent=1)
            fh.write("\n")
        print("\nwrote", args.out)


if __name__ == "__main__":
    main()
