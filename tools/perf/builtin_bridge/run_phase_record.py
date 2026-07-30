#!/usr/bin/env python3
"""P7-42 recorder: sample cycles, retired instructions and backend stalls on
each builtin case and on its mirrored direct control, so the same stage table
can be filled with all three columns.

Three events, three separate records per case, because a grouped record shares
one sample stream and the per-event split is what the stage table needs.

`inst_retired` sampling is what supplies the *dynamic* instruction census: the
static disassembly census cannot distinguish the two argument-push legs (empty
leaf vs exact-args leaf) or the taken from the untaken fallback, and both legs
live in the same symbol.
"""

import argparse
import fcntl
import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
LOCK = "/tmp/zjs-host-heavy.lock"


def record(binary, script, cpu, event, out_path, period):
    # FIXED period, not -F. With -F perf auto-tunes the period, and on a
    # workload whose inner period is ~100 cycles the tuned period can land near
    # a multiple of the callback period: samples then pile up on a single
    # instruction. That aliasing was observed directly (one `bl next` return
    # site took 20% of all process cycles in one -F record of `every` and 0.7%
    # in the matching record of `forEach`). Fixed, mutually co-prime periods
    # plus period-to-period agreement is the guard.
    cmd = ["taskset", "-c", str(cpu), "perf", "record", "-q",
           "-e", event, "-c", str(period), "-o", out_path, "--", binary, script]
    with open(LOCK, "a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True)
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)
    if proc.returncode != 0:
        raise RuntimeError(f"record failed ({event} {script}): "
                           f"{proc.stderr[-500:]}")
    if "throttl" in proc.stderr.lower():
        print("  WARNING throttling reported:", proc.stderr.strip()[-200:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument("--pmu", default="armv8_pmuv3_1")
    ap.add_argument("--periods", required=True,
                    help="event:period,... e.g. cpu_cycles:50021,inst_retired:249989")
    ap.add_argument("--cases", required=True)
    ap.add_argument("--tmpdir", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    os.makedirs(args.tmpdir, exist_ok=True)
    specs = [s.split(":") for s in args.periods.split(",")]
    index = {"binary": os.path.abspath(args.binary), "cpu": args.cpu,
             "pmu": args.pmu, "periods": args.periods, "records": {}}
    for case in args.cases.split(","):
        script = os.path.join(CASES, case + ".js")
        for ev, period in specs:
            data = os.path.join(args.tmpdir, f"{case}.{ev}.p{period}.data")
            record(args.binary, script, args.cpu, f"{args.pmu}/{ev}/", data,
                   int(period))
            index["records"][f"{case}|{ev}|{period}"] = os.path.abspath(data)
            print(f"recorded {case} {ev} period={period}", flush=True)
    with open(args.out, "w") as fh:
        json.dump(index, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
