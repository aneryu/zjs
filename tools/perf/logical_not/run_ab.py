#!/usr/bin/env python3
"""P7-61 P0/P1 arbitration collector.

Two cold-cache build instances per side, all four binaries interleaved inside
one exclusive-lock window per case, so a case's four readings are adjacent in
time and every binary occupies every position in the rotation equally.

Discipline (`reports/perf/qjs-align/measurement-contracts.md`):

* sample count must be a multiple of 4 (hence even), and the realised
  first-position counts are recorded in the payload;
* every perf event carries an explicit PMU prefix and `<not counted>` rows are
  a hard error (big.LITTLE host, two PMUs);
* `taskset -c 19` plus `flock -x`; no `perf -F` anywhere;
* instructions and cycles are always collected together.

Modes:

* ``matrix``   -- the P7-60 `k0`/`k1` case pairs. Reports the *marginal* cost of
  the single extra `lnot` byte, `(k1 - k0) / iterations`, which is the only
  quantity that isolates the opcode from the loop scaffolding; whole-case
  numbers are kept alongside.
* ``script``   -- one script per case, whole-run instructions/cycles/wall.
* ``product``  -- Octane-derived workloads, wall-clock scheduled, so the score
  printed on stdout is the metric and cycles are recorded for context only.
"""

import argparse
import fcntl
import json
import math
import os
import re
import statistics
import subprocess
import sys
import time

LOCK = "/tmp/zjs-host-heavy.lock"
ROTATIONS = [(0, 1, 2, 3), (3, 2, 1, 0), (1, 0, 3, 2), (2, 3, 0, 1)]
SCORE_RE = re.compile(r"^([A-Za-z0-9_]+):\s*([0-9.]+)\s*$")


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


def run_once(binary, script, cpu, events, cwd, timeout):
    cmd = ["taskset", "-c", str(cpu), "perf", "stat", "-x,",
           "-e", ",".join(events), "--", binary, script]
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd,
                          timeout=timeout)
    wall = time.perf_counter() - t0
    if proc.returncode != 0:
        raise RuntimeError(f"{binary} {script} failed: {proc.stderr[-400:]}")
    vals = parse_perf(proc.stderr, events)
    vals["wall_s"] = wall
    vals["stdout"] = proc.stdout.strip()
    return vals


def scores(stdout_text):
    out = {}
    for line in stdout_text.splitlines():
        m = SCORE_RE.match(line.strip())
        if m:
            out[m.group(1)] = float(m.group(2))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--p0a", required=True)
    ap.add_argument("--p0b", required=True)
    ap.add_argument("--p1a", required=True)
    ap.add_argument("--p1b", required=True)
    ap.add_argument("--mode", choices=["matrix", "script", "product"],
                    required=True)
    ap.add_argument("--case-dir", required=True)
    ap.add_argument("--cases", required=True,
                    help="comma-separated case names (no .js)")
    ap.add_argument("--iterations", type=int, default=20_000_000)
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument("--pmu", default="armv8_pmuv3_1")
    ap.add_argument("--samples", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--label", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.samples % 4 != 0:
        sys.exit("samples must be a multiple of 4 (four binaries, balanced "
                 "rotation, even count)")

    p = args.pmu
    events = [f"{p}/instructions/", f"{p}/cycles/", "task-clock"]
    ev_i, ev_c = events[0], events[1]
    binaries = [("p0a", os.path.abspath(args.p0a)),
                ("p0b", os.path.abspath(args.p0b)),
                ("p1a", os.path.abspath(args.p1a)),
                ("p1b", os.path.abspath(args.p1b))]
    first_positions = {k: 0 for k, _ in binaries}
    names = [c.strip() for c in args.cases.split(",") if c.strip()]
    case_dir = os.path.abspath(args.case_dir)

    results = {}
    for name in names:
        script = os.path.join(case_dir, name + ".js")
        if not os.path.exists(script):
            sys.exit("missing case: " + script)
        samples = {k: [] for k, _ in binaries}
        outputs = {k: set() for k, _ in binaries}
        with open(LOCK, "a") as lock_fh:
            fcntl.flock(lock_fh, fcntl.LOCK_EX)
            try:
                for s in range(args.samples):
                    order = ROTATIONS[s % 4]
                    first_positions[binaries[order[0]][0]] += 1
                    for idx in order:
                        key, binary = binaries[idx]
                        v = run_once(binary, script, args.cpu, events,
                                     case_dir, args.timeout)
                        outputs[key].add(v.pop("stdout"))
                        samples[key].append(v)
            finally:
                fcntl.flock(lock_fh, fcntl.LOCK_UN)

        rec = {"case": name,
               "outputs": {k: sorted(outputs[k]) for k in outputs},
               "output_match": len({tuple(sorted(outputs[k]))
                                    for k in outputs}) == 1}
        for key, _ in binaries:
            per = {}
            for ev in events + ["wall_s"]:
                vs = [x[ev] for x in samples[key]]
                per[ev] = {"median": statistics.median(vs),
                           "min": min(vs), "max": max(vs), "samples": vs}
            rec[key] = per
        if args.mode == "product":
            sc = {}
            for key, _ in binaries:
                vals = {}
                for text in outputs[key]:
                    for bench, score in scores(text).items():
                        vals.setdefault(bench, []).append(score)
                sc[key] = {b: statistics.median(v) for b, v in vals.items()}
            rec["scores"] = sc
        results[name] = rec
        line = f"{name:26s}"
        for key, _ in binaries:
            line += f" {key}={rec[key][ev_c]['median']:>13.0f}"
        if not rec["output_match"]:
            line += "  OUTPUT-MISMATCH"
        print(line, flush=True)

    payload = {
        "collector": "tools/perf/logical_not/run_ab.py",
        "label": args.label,
        "mode": args.mode,
        "cpu": args.cpu,
        "pmu": args.pmu,
        "events": events,
        "iterations_per_case": args.iterations if args.mode == "matrix" else None,
        "samples_per_case_per_binary": args.samples,
        "sampling_order": ("four-binary rotation, one exclusive host lock "
                           "window per case; every binary occupies every "
                           "position equally"),
        "first_position_counts": first_positions,
        "first_position_balanced":
            len(set(first_positions.values())) == 1,
        "binaries": {k: v for k, v in binaries},
        "cases": results,
    }
    with open(args.out, "w") as fh:
        json.dump(payload, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
