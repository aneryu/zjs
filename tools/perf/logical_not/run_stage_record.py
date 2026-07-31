#!/usr/bin/env python3
"""P7-60 stage attribution: symbol-scoped cycle profile of one `op.lnot`.

Two P7-42 lessons are load-bearing here and are enforced, not optional:

* **fixed, co-prime sampling periods only.**  `perf -F <freq>` auto-tunes its
  period, and on a workload whose inner period is a few tens of cycles it aliases
  onto a single instruction (P7-42 §7 measured one bucket move from 0.74% to
  20.09%).  Every profile below is taken at three fixed co-prime periods and the
  spread across them is reported.
* **attribution is scoped to symbols, never to bare `file:line`.**  `logicalNot`
  and `toBoolean` are real out-of-line symbols here, so the three stages of
  interest are separable by symbol without any line table at all.

The reported number for a stage is the *difference* between the `k1` case
(`u = !x`) and the `k0` case (`u = x`), so the loop scaffolding cancels.
"""

import argparse
import bisect
import collections
import fcntl
import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
LOCK = "/tmp/zjs-host-heavy.lock"
PERIODS = [50021, 65599, 82657]
ITERATIONS = 20_000_000

# Symbol -> stage label.  Anything unmatched is bucketed as `other` (the loop
# scaffolding: the counter update, the compare, the branch, `put_loc`).
STAGE_OF_SYMBOL = {
    "exec.tailcall_dispatch.coldStd__struct_69769.h":
        "S1_cold_wrapper_and_next_dispatch",
    "exec.vm_value.logicalNot": "S2_helper_frame_and_publication",
    "core.value_semantics.toBoolean": "S3_tag_classification_and_toboolean",
    "core.value.isZeroBigInt": "S3_tag_classification_and_toboolean",
}


def symbol_table(binary):
    out = subprocess.run(["nm", "-S", binary], capture_output=True, text=True).stdout
    syms = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        try:
            addr = int(parts[0], 16)
            size = int(parts[1], 16)
        except ValueError:
            continue
        syms.append((addr, size, parts[3]))
    syms.sort()
    return syms


def resolve(syms, starts, ip):
    i = bisect.bisect_right(starts, ip) - 1
    if i < 0:
        return None
    addr, size, name = syms[i]
    if size and ip >= addr + size:
        return None
    return name


def record(binary, script, cpu, pmu, period, tmp):
    data = os.path.join(tmp, "p760.data")
    cmd = ["taskset", "-c", str(cpu), "perf", "record", "-q",
           "-e", f"{pmu}/cycles/", "-c", str(period), "-o", data,
           "--", binary, script]
    subprocess.run(cmd, capture_output=True, text=True, check=True)
    script_out = subprocess.run(
        ["perf", "script", "-i", data, "-F", "ip"],
        capture_output=True, text=True, check=True).stdout
    ips = []
    for line in script_out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ips.append(int(line, 16))
        except ValueError:
            pass
    return ips


def profile(binary, script, cpu, pmu, period, tmp, syms, starts):
    ips = record(binary, script, cpu, pmu, period, tmp)
    per_symbol = collections.Counter()
    for ip in ips:
        per_symbol[resolve(syms, starts, ip) or "<unresolved>"] += 1
    return len(ips), per_symbol


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zjs", required=True)
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument("--pmu", default="armv8_pmuv3_1")
    ap.add_argument("--tmp", default=os.environ.get("TMPDIR", "/tmp"))
    ap.add_argument("--pairs", default="t_int_nonzero,t_object_plain")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    binary = os.path.abspath(args.zjs)
    syms = symbol_table(binary)
    starts = [s[0] for s in syms]
    results = {}

    with open(LOCK, "a") as lock_fh:
        fcntl.flock(lock_fh, fcntl.LOCK_EX)
        try:
            for pair in args.pairs.split(","):
                per_period = {}
                for period in PERIODS:
                    legs = {}
                    for leg in ("k0", "k1"):
                        script = os.path.join(CASES, f"{pair}_{leg}.js")
                        total, per_symbol = profile(binary, script, args.cpu,
                                                    args.pmu, period, args.tmp,
                                                    syms, starts)
                        legs[leg] = {"samples": total,
                                     "per_symbol": dict(per_symbol)}
                    stages = collections.Counter()
                    for name, n in legs["k1"]["per_symbol"].items():
                        stages[STAGE_OF_SYMBOL.get(name, "other")] += n
                    for name, n in legs["k0"]["per_symbol"].items():
                        stages[STAGE_OF_SYMBOL.get(name, "other")] -= n
                    cyc_per_sample = period
                    per_period[period] = {
                        "legs": legs,
                        "delta_samples": legs["k1"]["samples"] - legs["k0"]["samples"],
                        "delta_cycles_total":
                            (legs["k1"]["samples"] - legs["k0"]["samples"]) * cyc_per_sample,
                        "stage_cyc_per_lnot": {
                            k: v * cyc_per_sample / ITERATIONS
                            for k, v in sorted(stages.items())},
                    }
                    print(f"{pair} c={period}", flush=True)
                    for k, v in sorted(per_period[period]["stage_cyc_per_lnot"].items(),
                                       key=lambda kv: -kv[1]):
                        print(f"    {k:40s} {v:7.2f} cyc/lnot", flush=True)
                results[pair] = per_period
        finally:
            fcntl.flock(lock_fh, fcntl.LOCK_UN)

    payload = {
        "collector": "tools/perf/logical_not/run_stage_record.py",
        "zjs_binary": binary,
        "cpu": args.cpu,
        "pmu": args.pmu,
        "periods": PERIODS,
        "period_policy": "fixed co-prime periods only (P7-42 -F aliasing hazard)",
        "attribution_scope": "per-symbol (no file:line aggregation)",
        "iterations_per_case": ITERATIONS,
        "stage_of_symbol": STAGE_OF_SYMBOL,
        "pairs": results,
    }
    with open(args.out, "w") as fh:
        json.dump(payload, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
