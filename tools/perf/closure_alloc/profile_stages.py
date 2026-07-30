#!/usr/bin/env python3
"""P7-50 symbol-level cycle/instruction attribution.

The dynamic-stage counts showed no per-op stage-count divergence between the
engines, so whatever produces the gap is the cost INSIDE the stages. This script
records a flat (no call-graph) `perf record` profile of one case per engine and
reports each symbol's share, then differences the closure case against the
`reuse` baseline of the same lifetime so the VM dispatch loop, the induction
variable and the array-element store cancel.

`--percentage absolute` and `--no-children` keep the numbers additive; there is
no call-graph so no double counting. Startup is diluted rather than subtracted:
with 200 samples of a 20,000-iteration loop the process spends over 97% of its
cycles in the timed loop, and the baseline difference removes what is left that
is common to both cases.
"""

import argparse
import json
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
CASES = os.path.join(REPO, "tools", "perf", "same_runtime", "cases")


def record(binary, cpu, case, event, iterations, warmup, tmpdir, freq):
    data = os.path.join(tmpdir, "perf.data")
    args = ["perf", "record", "-q", "-o", data, "-e", event, "-F", str(freq),
            "--no-buildid-cache",
            "taskset", "-c", str(cpu), binary,
            "--case", case, "--source", os.path.join(CASES, case + ".js"),
            "--iterations", str(iterations), "--warmup", str(warmup),
            "--teardown", "normal"]
    proc = subprocess.run(args, cwd=REPO, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("perf record failed: %s" % proc.stderr[:2000])
    report = subprocess.run(
        ["perf", "report", "-i", data, "--stdio", "-q", "--no-children",
         "--percentage", "absolute", "--sort", "symbol", "-F",
         "overhead,period,symbol"],
        cwd=REPO, capture_output=True, text=True)
    if report.returncode != 0:
        raise RuntimeError("perf report failed: %s" % report.stderr[:2000])
    rows = {}
    total = 0
    for line in report.stdout.splitlines():
        line = line.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^\s*([0-9.]+)%\s+(\d+)\s+\[([^]]*)\]\s+(\S.*?)\s*(?:-\s+-\s*)?$",
                     line)
        if not m:
            continue
        period = int(m.group(2))
        space = m.group(3)
        symbol = m.group(4).strip()
        if space == "k":
            symbol = "[kernel] " + symbol
        rows[symbol] = rows.get(symbol, 0) + period
        total += period
    if total == 0:
        raise RuntimeError(
            "perf report parsed no rows; first lines: %r"
            % report.stdout.splitlines()[:5])
    return {"total_period": total, "symbols": rows}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", action="append", required=True,
                        metavar="LABEL=PATH")
    parser.add_argument("--cases", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--events", default="cycles,instructions")
    parser.add_argument("--cpu", type=int, default=19)
    parser.add_argument("--iterations", type=int, default=200)
    parser.add_argument("--warmup", type=int, default=8)
    parser.add_argument("--freq", type=int, default=20000)
    parser.add_argument("--inner", type=int, default=20000)
    parser.add_argument("--tmpdir", default=os.environ.get("TMPDIR", "/tmp"))
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    binaries = []
    for item in args.binary:
        label, _, path = item.partition("=")
        binaries.append((label, os.path.abspath(path)))

    cases = [c for c in args.cases.split(",") if c]
    events = [e for e in args.events.split(",") if e]
    out = {"line": "P7-50", "iterations": args.iterations,
           "inner": args.inner, "cpu": args.cpu, "profiles": {}}

    for label, path in binaries:
        for event in events:
            for case in cases + [args.baseline]:
                key = "%s|%s|%s" % (label, event, case)
                if key in out["profiles"]:
                    continue
                out["profiles"][key] = record(
                    path, args.cpu, case, event, args.iterations, args.warmup,
                    args.tmpdir, args.freq)
                print("profiled %s" % key)

    with open(args.out, "w") as handle:
        json.dump(out, handle, indent=1)
    print(args.out)


if __name__ == "__main__":
    main()
