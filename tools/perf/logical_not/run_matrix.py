#!/usr/bin/env python3
"""P7-60 collector: paired instruction/cycle counts for the `!` type matrix.

Discipline carried over from the P7-40/P7-41/P7-42 collectors:

* one case at a time; inside a case the two engines interleave ABBA so the pair
  stays adjacent in time, and the exclusive host lock is taken per case;
* sample counts must be even;
* every event carries an explicit PMU prefix (big.LITTLE host, two PMUs);
* stdout is compared between engines per case (a `k0`/`k1` pair legitimately
  differs from each other, but never between engines).
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
ITERATIONS = 20_000_000


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
    ap.add_argument("--events", default="basic",
                    choices=["basic", "extended"])
    ap.add_argument("--cases", default=None)
    ap.add_argument("--label", default="A1")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.samples % 2 != 0:
        sys.exit("samples must be even (ABBA balance)")

    p = args.pmu
    if args.events == "basic":
        events = [f"{p}/instructions/", f"{p}/cycles/", "task-clock"]
    else:
        events = [f"{p}/instructions/", f"{p}/cycles/",
                  f"{p}/stall_backend/", f"{p}/stall_frontend/",
                  f"{p}/br_retired/", f"{p}/br_mis_pred_retired/",
                  f"{p}/l1d_cache/", "task-clock"]

    if args.cases:
        names = args.cases.split(",")
    else:
        names = [l.strip() for l in
                 open(os.path.join(HERE, "case_list.txt")) if l.strip()]

    zjs = os.path.abspath(args.zjs)
    qjs = os.path.abspath(args.qjs)
    results = {}
    first_positions = {"qjs": 0, "zjs": 0}

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

        rec = {"case": name,
               "iterations": 0 if name == "baseline" else ITERATIONS,
               "outputs": {e: sorted(outputs[e]) for e in outputs},
               "output_match": outputs["qjs"] == outputs["zjs"]}
        for eng in ("qjs", "zjs"):
            per = {}
            for ev in events:
                vs = [x[ev] for x in samples[eng]]
                per[ev] = {"median": statistics.median(vs), "samples": vs}
            rec[eng] = per
        results[name] = rec
        qc = rec["qjs"][events[1]]["median"]
        zc = rec["zjs"][events[1]]["median"]
        qi = rec["qjs"][events[0]]["median"]
        zi = rec["zjs"][events[0]]["median"]
        print(f"{name:26s} insn q={qi:>13.0f} z={zi:>13.0f} "
              f"cyc q={qc:>13.0f} z={zc:>13.0f} r={zc/qc:.3f} "
              f"{'' if rec['output_match'] else 'OUTPUT-MISMATCH'}", flush=True)

    payload = {
        "collector": "tools/perf/logical_not/run_matrix.py",
        "build_label": args.label,
        "cpu": args.cpu,
        "pmu": args.pmu,
        "iterations_per_case": ITERATIONS,
        "samples_per_case_per_engine": args.samples,
        "sampling_order": "ABBA, per case, exclusive host lock held per case",
        "first_position_counts": first_positions,
        "first_position_balanced":
            first_positions["qjs"] == first_positions["zjs"],
        "zjs_binary": zjs,
        "qjs_binary": qjs,
        "events": events,
        "cases": results,
    }
    with open(args.out, "w") as fh:
        json.dump(payload, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
