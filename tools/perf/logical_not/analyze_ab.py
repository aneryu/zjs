#!/usr/bin/env python3
"""P7-61 arbitration: reduce run_ab.py payloads to the four-combination table.

`matrix` payloads are reduced two ways and both are printed, because the two
answer different questions:

* ``marginal`` -- ``(k1 - k0) / iterations``, the cost of the single extra
  `lnot` opcode byte with the loop scaffolding differenced away. This is the
  per-op number the synthetic threshold is stated in.
* ``whole``    -- the `k1` case as run. This is the number a "no stable
  regression" clause is normally read against, since it is what a workload
  containing this loop would actually pay.

Every P0/P1 pairing is reported (a-a, a-b, b-a, b-b); the intra-side spread is
reported alongside as the build-lottery noise floor.
"""

import argparse
import json
import math
import statistics
import sys

EV_I = None
EV_C = None


def med(rec, key, ev):
    return rec[key][ev]["median"]


def combos(p0, p1):
    """Improvement percent for each of the four P0/P1 build pairings.

    Positive = P1 better (smaller).
    """
    out = {}
    for a in ("p0a", "p0b"):
        for b in ("p1a", "p1b"):
            out[f"{a}/{b}"] = (p0[a] - p1[b]) / p0[a] * 100.0
    return out


def reduce_matrix(payload, iterations):
    cases = payload["cases"]
    pairs = sorted({n[:-3] for n in cases if n.endswith("_k1")})
    rows = {}
    for base in pairs:
        k0, k1 = cases[base + "_k0"], cases[base + "_k1"]
        row = {}
        for label, ev in (("cycles", EV_C), ("instructions", EV_I)):
            marg0 = {k: (med(k1, k, ev) - med(k0, k, ev)) / iterations
                     for k in ("p0a", "p0b", "p1a", "p1b")}
            whole = {k: med(k1, k, ev) for k in ("p0a", "p0b", "p1a", "p1b")}
            row[label] = {
                "marginal_per_op": marg0,
                "marginal_combos": combos(
                    {k: marg0[k] for k in ("p0a", "p0b")},
                    {k: marg0[k] for k in ("p1a", "p1b")}),
                "whole_case": whole,
                "whole_combos": combos(
                    {k: whole[k] for k in ("p0a", "p0b")},
                    {k: whole[k] for k in ("p1a", "p1b")}),
                "p0_spread_pct": abs(marg0["p0a"] - marg0["p0b"]) /
                                 max(abs(marg0["p0a"]), 1e-9) * 100.0,
                "p1_spread_pct": abs(marg0["p1a"] - marg0["p1b"]) /
                                 max(abs(marg0["p1a"]), 1e-9) * 100.0,
                "whole_p0_spread_pct": abs(whole["p0a"] - whole["p0b"]) /
                                       whole["p0a"] * 100.0,
                "whole_p1_spread_pct": abs(whole["p1a"] - whole["p1b"]) /
                                       whole["p1a"] * 100.0,
            }
        row["output_match"] = k1["output_match"] and k0["output_match"]
        rows[base] = row
    return rows


def reduce_script(payload):
    rows = {}
    for name, rec in payload["cases"].items():
        row = {}
        for label, ev in (("cycles", EV_C), ("instructions", EV_I),
                          ("wall_s", "wall_s")):
            whole = {k: med(rec, k, ev) for k in ("p0a", "p0b", "p1a", "p1b")}
            row[label] = {"whole": whole, "combos": combos(
                {k: whole[k] for k in ("p0a", "p0b")},
                {k: whole[k] for k in ("p1a", "p1b")}),
                "p0_spread_pct": abs(whole["p0a"] - whole["p0b"]) / whole["p0a"] * 100.0,
                "p1_spread_pct": abs(whole["p1a"] - whole["p1b"]) / whole["p1a"] * 100.0}
        row["output_match"] = rec["output_match"]
        if "scores" in rec:
            sc = rec["scores"]
            benches = sorted(sc["p0a"].keys())
            row["scores"] = {}
            for bench in benches:
                vals = {k: sc[k][bench] for k in ("p0a", "p0b", "p1a", "p1b")}
                # score: higher is better, so invert the improvement sign
                cb = {}
                for a in ("p0a", "p0b"):
                    for b in ("p1a", "p1b"):
                        cb[f"{a}/{b}"] = (vals[b] - vals[a]) / vals[a] * 100.0
                row["scores"][bench] = {"values": vals, "combos": cb,
                                        "worst_pct": min(cb.values()),
                                        "best_pct": max(cb.values()),
                                        "median_pct": statistics.median(cb.values())}
        rows[name] = row
    return rows


def main():
    global EV_I, EV_C
    ap = argparse.ArgumentParser()
    ap.add_argument("payloads", nargs="+")
    ap.add_argument("--iterations", type=int, default=20_000_000)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    out = {}
    for path in args.payloads:
        payload = json.load(open(path))
        EV_I, EV_C = payload["events"][0], payload["events"][1]
        if payload["mode"] == "matrix":
            rows = reduce_matrix(payload, args.iterations)
            print(f"\n=== {path} (mode=matrix) ===")
            print(f"{'case':24s} {'P0 cyc/op':>10s} {'P1 cyc/op':>10s} "
                  f"{'marg %':>8s} {'whole worst %':>13s} "
                  f"{'P0 spr':>7s} {'P1 spr':>7s}  insn/op P0->P1")
            for base, row in rows.items():
                c = row["cycles"]
                i = row["instructions"]
                p0 = statistics.median([c["marginal_per_op"]["p0a"],
                                        c["marginal_per_op"]["p0b"]])
                p1 = statistics.median([c["marginal_per_op"]["p1a"],
                                        c["marginal_per_op"]["p1b"]])
                worst_whole = min(c["whole_combos"].values())
                print(f"{base:24s} {p0:10.2f} {p1:10.2f} "
                      f"{(p0-p1)/p0*100:8.1f} {worst_whole:13.2f} "
                      f"{c['whole_p0_spread_pct']:7.2f} "
                      f"{c['whole_p1_spread_pct']:7.2f}  "
                      f"{statistics.median([i['marginal_per_op']['p0a'], i['marginal_per_op']['p0b']]):7.2f}"
                      f" -> {statistics.median([i['marginal_per_op']['p1a'], i['marginal_per_op']['p1b']]):7.2f}"
                      f"{'' if row['output_match'] else '  OUTPUT-MISMATCH'}")
            out[path] = rows
        else:
            rows = reduce_script(payload)
            print(f"\n=== {path} (mode={payload['mode']}) ===")
            for name, row in rows.items():
                c = row["cycles"]
                print(f"{name:26s} cyc P0={statistics.median([c['whole']['p0a'], c['whole']['p0b']]):>14.0f} "
                      f"P1={statistics.median([c['whole']['p1a'], c['whole']['p1b']]):>14.0f} "
                      f"worst={min(c['combos'].values()):+6.2f}% best={max(c['combos'].values()):+6.2f}% "
                      f"(P0 spread {c['p0_spread_pct']:.2f}%, P1 spread {c['p1_spread_pct']:.2f}%)"
                      f"{'' if row['output_match'] else '  OUTPUT-MISMATCH'}")
                for bench, s in row.get("scores", {}).items():
                    print(f"    score {bench:20s} P0={s['values']['p0a']:.0f}/{s['values']['p0b']:.0f} "
                          f"P1={s['values']['p1a']:.0f}/{s['values']['p1b']:.0f} "
                          f"worst={s['worst_pct']:+6.2f}% median={s['median_pct']:+6.2f}% best={s['best_pct']:+6.2f}%")
            out[path] = rows

    if args.out:
        with open(args.out, "w") as fh:
            json.dump(out, fh, indent=1)
            fh.write("\n")
        print("\nwrote", args.out)


if __name__ == "__main__":
    main()
