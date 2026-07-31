#!/usr/bin/env python3
"""P7-42 analyser: build the per-stage table for the builtin->bytecode bridge.

Inputs
------
* `--stat`   run_phase_stat.py output covering the long `q_*` record cases, so
             every sample share can be turned into an absolute per-callback
             figure from the same binary under the same pinning.
* `--stage`  stage_map.py output per builtin family. Each carries several
             sample histograms per event: one per fixed sampling period.

Normalisation
-------------
    per_callback(event, case) = (median(event, case) - median(event, baseline))
                                / callback_count(case)
    stage(event) = median over periods of (stage share) * per_callback(event)

Two honesty rules are built in.

1. The share is a *sampled* quantity. Three mutually co-prime fixed periods are
   collected per event and the spread across them is reported, because a single
   auto-tuned (-F) period aliases against this workload's ~100-cycle inner
   period and can pile 20% of all cycles onto one instruction.
2. Cycles attributed to a stage are an attribution, not a ledger entry: on an
   out-of-order core a stall is charged to the consumer at the end of a
   dependency chain, not to the instruction that created it. The instruction
   column is much more robust (retired-instruction sampling is uniform over
   retired instructions) and IPC is printed so the two can be cross-checked.
"""

import argparse
import json
import statistics

BRIDGE = ["S1_callsite_entry_and_poll", "S2_fence_scope_construct",
          "S3_fence_publish", "S4_frame_admission", "S5_argument_staging",
          "S6_entry_publication",
          "S7a_fence_depth_check_and_driver_call",
          "S7b_driver_frame_save_restore", "S7c_vm_cache_rebuild",
          "S7d_run_prologue", "S7e_dispatch_entry_and_outcome",
          "S8_special_return", "S9_fence_restore", "S10_return_to_builtin",
          "X11a_fallback_args_hoisted", "X11b_fallback_call_cold",
          "X11c_owned_copy_leg"]
SHARED = ["C0_builtin_loop_and_element_read", "C8_run_loop_other",
          "C9_callback_return_handler", "C90_leaf_return_arms",
          "Xcall_unattributed"]
EVENTS = {"cyc": "cpu_cycles", "ins": "inst_retired", "stl": "stall_backend"}
GROUP = {"cpu_cycles": "mem", "inst_retired": "mem", "stall_backend": "stall"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stat", required=True)
    ap.add_argument("--stage", action="append", required=True,
                    help="family=path/to/stage_map.json")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    stat = json.load(open(args.stat))

    def per_cb(case, raw_event):
        g = GROUP[raw_event]
        rec = stat["cases"][f"{g}:{case}"]
        base = stat["cases"][f"{g}:baseline"]
        cbc = rec["callback_count"]
        return {e: (rec[e][raw_event]["median"]
                    - base[e][raw_event]["median"]) / cbc
                for e in ("qjs", "zjs")}

    out = {"stat_source": args.stat, "families": {}}
    for spec in args.stage:
        fam, _, path = spec.partition("=")
        sm = json.load(open(path))
        totals = {}
        for short, raw in EVENTS.items():
            b = per_cb(f"q_{fam}", raw)
            c = per_cb(f"q_c_{fam}", raw)
            totals[short] = {"zjs_builtin": b["zjs"], "zjs_control": c["zjs"],
                             "qjs_builtin": b["qjs"], "qjs_control": c["qjs"]}

        labels = {}
        for short in EVENTS:
            for side in ("b", "c"):
                labels[(short, side)] = sorted(
                    k for k in sm["samples"] if k.startswith(f"{short}_{side}_"))

        allstages = sorted(set(BRIDGE + SHARED) |
                           {k for lbl in sm["samples"]
                            for k in sm["samples"][lbl]["by_stage"]})
        rows = {}
        for stage in allstages:
            row = {}
            for short in EVENTS:
                for side, tag in (("b", "builtin"), ("c", "control")):
                    shares, counts = [], []
                    for lbl in labels[(short, side)]:
                        s = sm["samples"][lbl]
                        n = s["by_stage"].get(stage, 0)
                        counts.append(n)
                        shares.append(n / s["total_samples"])
                    if not shares:
                        continue
                    med = statistics.median(shares)
                    row[f"{short}_{tag}_share_median"] = med
                    row[f"{short}_{tag}_share_min"] = min(shares)
                    row[f"{short}_{tag}_share_max"] = max(shares)
                    row[f"{short}_{tag}_samples"] = counts
                    row[f"{short}_{tag}_per_callback"] = (
                        med * totals[short][f"zjs_{tag}"])
                    row[f"{short}_{tag}_per_callback_min"] = (
                        min(shares) * totals[short][f"zjs_{tag}"])
                    row[f"{short}_{tag}_per_callback_max"] = (
                        max(shares) * totals[short][f"zjs_{tag}"])
            for tag in ("builtin", "control"):
                c = row.get(f"cyc_{tag}_per_callback", 0.0)
                i = row.get(f"ins_{tag}_per_callback", 0.0)
                row[f"ipc_{tag}"] = (i / c) if c > 0 else None
                row[f"stall_frac_{tag}"] = (
                    row.get(f"stl_{tag}_per_callback", 0.0) / c) if c > 0 else None
            row["cyc_builtin_minus_control_per_callback"] = (
                row.get("cyc_builtin_per_callback", 0.0)
                - row.get("cyc_control_per_callback", 0.0))
            row["is_bridge_stage"] = stage in BRIDGE
            rows[stage] = row

        tax = ((totals["cyc"]["zjs_builtin"] - totals["cyc"]["zjs_control"])
               - (totals["cyc"]["qjs_builtin"] - totals["cyc"]["qjs_control"]))
        out["families"][fam] = {
            "process_per_callback": totals,
            "zjs_specific_bridge_tax_spec_cycles": tax,
            "bridge_stage_total_cycles_per_callback": sum(
                rows[s].get("cyc_builtin_per_callback", 0.0) for s in BRIDGE),
            "bridge_stage_total_instructions_per_callback": sum(
                rows[s].get("ins_builtin_per_callback", 0.0) for s in BRIDGE),
            "bridge_only_cycles_per_callback": sum(
                rows[s]["cyc_builtin_minus_control_per_callback"] for s in BRIDGE),
            "stages": rows,
        }

    with open(args.out, "w") as fh:
        json.dump(out, fh, indent=1)
        fh.write("\n")

    for fam, f in out["families"].items():
        t = f["process_per_callback"]["cyc"]
        print(f"\n===== {fam}: zjs builtin {t['zjs_builtin']:.2f} cyc/cb | "
              f"zjs control {t['zjs_control']:.2f} | qjs builtin "
              f"{t['qjs_builtin']:.2f} | qjs control {t['qjs_control']:.2f}")
        print(f"      spec tax {f['zjs_specific_bridge_tax_spec_cycles']:.2f} | "
              f"bridge stages {f['bridge_stage_total_cycles_per_callback']:.2f} cyc, "
              f"{f['bridge_stage_total_instructions_per_callback']:.0f} insn")
        print(f"{'stage':34s}{'ins/cb':>8s}{'cyc/cb':>8s}"
              f"{'[cycmin,cycmax]':>17s}{'IPC':>6s}{'stall/cb':>9s}{'ctlcyc':>8s}")
        for stage, r in sorted(
                f["stages"].items(),
                key=lambda kv: -kv[1].get("cyc_builtin_per_callback", 0.0)):
            ipc = r.get("ipc_builtin") or 0.0
            print(f"{stage:34s}"
                  f"{r.get('ins_builtin_per_callback', 0.0):8.1f}"
                  f"{r.get('cyc_builtin_per_callback', 0.0):8.2f}"
                  f"  [{r.get('cyc_builtin_per_callback_min', 0.0):6.2f},"
                  f"{r.get('cyc_builtin_per_callback_max', 0.0):6.2f}]"
                  f"{ipc:6.2f}{r.get('stl_builtin_per_callback', 0.0):9.2f}"
                  f"{r.get('cyc_control_per_callback', 0.0):8.2f}")
    print("\nwrote", args.out)


if __name__ == "__main__":
    main()
