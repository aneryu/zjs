#!/usr/bin/env python3
"""P7-42 collector: extended-event differential stat for the builtin bridge.

P7-41 closed with an unpaid debt: the builtin/control gap is an IPC gap, not an
instruction-count gap, and P7-41 collected only instructions/cycles/task-clock.
This collector adds stall and miss decomposition so the phase attribution can
say *what kind* of cycles the bridge spends.

Discipline carried over from `run_bridge.py`:

* one case at a time, ABBA inside the case, even sample count;
* exclusive host lock taken per case, not for the whole sweep;
* every event carries an explicit PMU prefix (big.LITTLE host, two PMUs; an
  unqualified event name emits `<not counted>` for the PMU the pinned core is
  not on);
* stdout compared between engines on every run.

Events are split into two groups that each fit the core's counter budget with
no multiplexing (verified: every row reports 100.00 enabled).
"""

import argparse
import fcntl
import json
import os
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
LOCK = "/tmp/zjs-host-heavy.lock"

GROUPS = {
    "stall": ["cpu_cycles", "inst_retired", "stall_backend", "stall_frontend",
              "stall_slot_backend", "stall_slot_frontend", "stall_backend_mem"],
    "mem": ["cpu_cycles", "inst_retired", "l1d_cache", "l1d_cache_refill",
            "ll_cache_miss_rd", "br_retired", "br_mis_pred_retired",
            "mem_access"],
}


def parse_perf(stderr_text, events):
    out = {}
    for line in stderr_text.splitlines():
        parts = line.split(",")
        if len(parts) < 3:
            continue
        raw, _unit, ev = parts[0], parts[1], parts[2]
        if ev not in events:
            continue
        if "not counted" in raw or "not supported" in raw:
            raise RuntimeError("perf row not counted: " + line)
        if len(parts) >= 5 and parts[4]:
            enabled = float(parts[4])
            if enabled < 99.5:
                raise RuntimeError("multiplexed row: " + line)
        out[ev] = float(raw)
    missing = [e for e in events if e not in out]
    if missing:
        raise RuntimeError("missing perf rows: " + ",".join(missing))
    return out


def run_once(engine_bin, script, cpu, events):
    cmd = ["taskset", "-c", str(cpu), "perf", "stat", "-x,",
           "-e", ",".join(events), "--", engine_bin, script]
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    wall = time.perf_counter() - t0
    if proc.returncode != 0:
        raise RuntimeError(f"{engine_bin} {script} failed: {proc.stderr[-400:]}")
    vals = parse_perf(proc.stderr, events)
    vals["wall_s"] = wall
    vals["stdout"] = proc.stdout.strip()
    return vals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zjs", required=True)
    ap.add_argument("--qjs", default="/home/aneryu/quickjs/qjs")
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument("--samples", type=int, default=6)
    ap.add_argument("--pmu", default="armv8_pmuv3_1")
    ap.add_argument("--cases", required=True)
    ap.add_argument("--label", default="A")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.samples % 2 != 0:
        sys.exit("samples must be even (ABBA balance)")

    meta = json.load(open(os.path.join(HERE, "cases.json")))
    names = args.cases.split(",")
    zjs = os.path.abspath(args.zjs)
    qjs = os.path.abspath(args.qjs)

    results = {}
    first_positions = {"qjs": 0, "zjs": 0}

    for group_name, raw_events in GROUPS.items():
        events = [f"{args.pmu}/{e}/" for e in raw_events]
        for name in names:
            script = os.path.join(CASES, name + ".js")
            samples = {"qjs": [], "zjs": []}
            outputs = {"qjs": set(), "zjs": set()}
            with open(LOCK, "a") as lock_fh:
                fcntl.flock(lock_fh, fcntl.LOCK_EX)
                try:
                    for s in range(args.samples):
                        order = ("qjs", "zjs") if s % 2 == 0 else ("zjs", "qjs")
                        first_positions[order[0]] += 1
                        for eng in order:
                            binary = qjs if eng == "qjs" else zjs
                            v = run_once(binary, script, args.cpu, events)
                            outputs[eng].add(v.pop("stdout"))
                            samples[eng].append(v)
                finally:
                    fcntl.flock(lock_fh, fcntl.LOCK_UN)

            key = f"{group_name}:{name}"
            rec = {"case": name, "group": group_name,
                   "iterations": meta["iterations"].get(name, 1),
                   "callback_count": meta["callback_count"].get(name, 0),
                   "outputs": {e: sorted(outputs[e]) for e in outputs},
                   "output_match": outputs["qjs"] == outputs["zjs"]}
            for eng in ("qjs", "zjs"):
                per = {}
                for raw, ev in zip(raw_events, events):
                    vals = [x[ev] for x in samples[eng]]
                    per[raw] = {"median": statistics.median(vals),
                                "samples": vals}
                rec[eng] = per
            results[key] = rec
            zc = rec["zjs"]["cpu_cycles"]["median"]
            qc = rec["qjs"]["cpu_cycles"]["median"]
            print(f"[{group_name}] {name:20s} cyc q={qc:>12.0f} z={zc:>12.0f} "
                  f"r={zc/qc:.3f} "
                  f"{'' if rec['output_match'] else 'OUTPUT-MISMATCH'}",
                  flush=True)

    payload = {
        "collector": "tools/perf/builtin_bridge/run_phase_stat.py",
        "build_label": args.label,
        "cpu": args.cpu,
        "pmu": args.pmu,
        "samples_per_case_per_engine": args.samples,
        "sampling_order": "ABBA, per case per event group, exclusive host lock per case",
        "first_position_counts": first_positions,
        "first_position_balanced":
            first_positions["qjs"] == first_positions["zjs"],
        "zjs_binary": zjs,
        "qjs_binary": qjs,
        "event_groups": GROUPS,
        "cases": results,
    }
    with open(args.out, "w") as fh:
        json.dump(payload, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
