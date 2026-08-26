#!/usr/bin/env python3
"""PERF-T-SPIKE A/B harness (policy: policies/spikes/perf-t-spike-v1.json).

Five arms over the four fixed-work workloads, ABBA-balanced, pinned, with
instructions and cycles taken in the SAME run as wall time (measurement
contract clause 8). Checksums are verified before any timing is kept.

  A base      main HEAD ReleaseFast                     -- production baseline
  B binctl    spike build, ZJS_TSPIKE unset             -- binary-layout delta
  C fusectl   spike build, ZJS_TSPIKE=fuseoff           -- fusion-loss only
  D u64       spike build (u64 guard), ZJS_TSPIKE=1     -- candidate
  E ptr       spike build (ptr guard), ZJS_TSPIKE=1     -- candidate, 2nd arm

Readings that matter:
  D/C, E/C  mechanism effect, fusion-neutral (the honest mechanism price)
  D/A, E/A  end-to-end vs production (the policy's candidate/baseline form)
  B/A       binary-layout noise floor;  C/B  cost of the suppressed fusions

Usage (must hold the host lock and be pinned):
  ZJS_MEASUREMENT_LOCK=/tmp/zjs-host-heavy.lock flock -x /tmp/zjs-host-heavy.lock \
    taskset -c 19 python3 tools/perf/tspike/run_tspike_ab.py \
      --base <main-zjs> --spike-u64 <bin> --spike-ptr <bin> \
      --samples 8 --cpu 19 --output /tmp/tspike-ab.json
"""
import argparse, json, os, re, statistics as st, subprocess, sys, time
from pathlib import Path

BENCHES = ["own_slot", "proto_slot", "poly_stress", "untyped_control"]
HERE = Path(__file__).resolve().parent
EVENTS = "instructions,cycles"


def fail(msg, code=2):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def check_pinned(cpu):
    mask = os.sched_getaffinity(0)
    if mask != {cpu}:
        fail(f"runner is not pinned to exactly CPU {cpu} (affinity={sorted(mask)}); "
             f"re-run under `taskset -c {cpu}`")


def run_once(binary, env_extra, js, cpu):
    env = dict(os.environ)
    env.pop("ZJS_TSPIKE", None)
    env.update(env_extra)
    cmd = ["taskset", "-c", str(cpu), "perf", "stat", "-x,", "-e", EVENTS, binary, str(js)]
    t0 = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=900)
    wall = time.perf_counter() - t0
    if p.returncode != 0:
        fail(f"{binary} {js} exited {p.returncode}: {p.stderr[-400:]}")
    counters = {}
    for line in p.stderr.splitlines():
        parts = line.split(",")
        if len(parts) >= 3 and parts[0] not in ("", "<not counted>", "<not supported>"):
            try:
                counters[parts[2]] = int(parts[0])
            except ValueError:
                pass
    return {"wall_s": wall, "stdout": p.stdout.strip(),
            "instructions": counters.get("instructions"), "cycles": counters.get("cycles")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--spike-u64", required=True)
    ap.add_argument("--spike-ptr", required=True)
    ap.add_argument("--samples", type=int, default=8)
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    if args.samples % 2 != 0:
        fail("--samples must be even (ABBA balance; odd counts have voided "
             "headline numbers twice in this project)")
    check_pinned(args.cpu)
    if not os.environ.get("ZJS_MEASUREMENT_LOCK"):
        fail("ZJS_MEASUREMENT_LOCK is not set; run under flock on the host lock")

    arms = [
        ("base",    args.base,       {}),
        ("binctl",  args.spike_u64,  {}),
        ("fusectl", args.spike_u64,  {"ZJS_TSPIKE": "fuseoff"}),
        ("u64",     args.spike_u64,  {"ZJS_TSPIKE": "1"}),
        ("ptr",     args.spike_ptr,  {"ZJS_TSPIKE": "1"}),
    ]

    # Correctness gate first: every arm must print the same checksum.
    for b in BENCHES:
        js = HERE / f"{b}.js"
        outs = {name: run_once(binary, env, js, args.cpu)["stdout"] for name, binary, env in arms}
        distinct = set(outs.values())
        if len(distinct) != 1 or not next(iter(distinct)):
            fail(f"{b}: checksums disagree across arms: {outs}")
        print(f"checksum ok {b}: {next(iter(distinct))}", flush=True)

    results = {b: {name: [] for name, _, _ in arms} for b in BENCHES}
    for s in range(args.samples):
        order = arms if s % 2 == 0 else list(reversed(arms))
        for b in BENCHES:
            for name, binary, env in order:
                results[b][name].append(run_once(binary, env, HERE / f"{b}.js", args.cpu))
        print(f"sample {s+1}/{args.samples} done", flush=True)

    def med(xs, key):
        vals = [x[key] for x in xs if x[key] is not None]
        return st.median(vals) if vals else None

    def cv(xs, key):
        vals = [x[key] for x in xs if x[key] is not None]
        if len(vals) < 2 or st.mean(vals) == 0:
            return None
        return st.stdev(vals) / st.mean(vals)

    summary = {}
    for b in BENCHES:
        row = {}
        for name, _, _ in arms:
            row[name] = {
                "wall_s": med(results[b][name], "wall_s"),
                "instructions": med(results[b][name], "instructions"),
                "cycles": med(results[b][name], "cycles"),
                "wall_cv": cv(results[b][name], "wall_s"),
            }
        def r(n, d, key="wall_s"):
            a, c = row[n][key], row[d][key]
            return round(a / c, 4) if a and c else None
        row["ratios"] = {
            "mechanism_u64_over_fusectl": r("u64", "fusectl"),
            "mechanism_ptr_over_fusectl": r("ptr", "fusectl"),
            "endtoend_u64_over_base": r("u64", "base"),
            "endtoend_ptr_over_base": r("ptr", "base"),
            "binary_delta_binctl_over_base": r("binctl", "base"),
            "fusion_cost_fusectl_over_binctl": r("fusectl", "binctl"),
            "insn_u64_over_fusectl": r("u64", "fusectl", "instructions"),
            "cycles_u64_over_fusectl": r("u64", "fusectl", "cycles"),
        }
        summary[b] = row

    artifact = {
        "tool": "run_tspike_ab.py",
        "policy": "policies/spikes/perf-t-spike-v1.json",
        "protocol": "fixed-work, function-wrapped workloads; paired ABBA arm rotation "
                    "(order reversed on odd samples); pinned CPU; host lock held; "
                    "instructions+cycles recorded in the same run as wall time",
        "samples": args.samples, "cpu": args.cpu,
        "binaries": {name: binary for name, binary, _ in arms},
        "arm_env": {name: env for name, _, env in arms},
        "summary": summary, "raw": results,
    }
    Path(args.output).write_text(json.dumps(artifact, indent=1))
    print(f"\nwrote {args.output}")
    hdr = f"{'bench':<16}{'D/C mech':>10}{'E/C mech':>10}{'D/A e2e':>10}{'B/A bin':>10}{'C/B fuse':>10}{'maxCV':>8}"
    print(hdr); print("-" * len(hdr))
    for b in BENCHES:
        rr = summary[b]["ratios"]
        cvs = [summary[b][n]["wall_cv"] for n, _, _ in arms if summary[b][n]["wall_cv"]]
        def f(x): return f"{x:>10.3f}" if x else f"{'--':>10}"
        print(f"{b:<16}{f(rr['mechanism_u64_over_fusectl'])}{f(rr['mechanism_ptr_over_fusectl'])}"
              f"{f(rr['endtoend_u64_over_base'])}{f(rr['binary_delta_binctl_over_base'])}"
              f"{f(rr['fusion_cost_fusectl_over_binctl'])}{max(cvs):>8.3f}")


if __name__ == "__main__":
    main()
