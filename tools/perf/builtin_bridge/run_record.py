#!/usr/bin/env python3
"""P7-41 cycle attribution: `perf record` on a builtin case and on its mirrored
direct-loop control, for both engines.

The point of the pairing is subtractive: symbols that carry cycles in the
builtin variant but not in the mirrored control are, by construction, the
builtin->JS bridge and not ordinary call/read/write cost.

Recording takes the exclusive host lock (it perturbs timing on the pinned core)
and is pinned to the same CPU as the timing sweep.
"""

import argparse
import fcntl
import json
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
LOCK = "/tmp/zjs-host-heavy.lock"


def record(binary, script, cpu, pmu, out_path, freq):
    cmd = ["taskset", "-c", str(cpu), "perf", "record", "-q",
           "-e", f"{pmu}/cycles/", "-F", str(freq), "-o", out_path,
           "--", binary, script]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"record failed: {proc.stderr[-400:]}")


def report(out_path, limit=25):
    proc = subprocess.run(
        ["perf", "report", "-i", out_path, "--stdio", "--no-children",
         "--percent-limit", "0.4", "-s", "symbol"],
        capture_output=True, text=True)
    rows = []
    for line in proc.stdout.splitlines():
        m = re.match(r"^\s+(\d+\.\d+)%\s+(.*)$", line)
        if not m:
            continue
        pct = float(m.group(1))
        sym = m.group(2).strip()
        sym = re.sub(r"^\[\.\]\s*", "", sym)
        rows.append({"percent": pct, "symbol": sym})
        if len(rows) >= limit:
            break
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zjs", required=True)
    ap.add_argument("--qjs", default="/home/aneryu/quickjs/qjs")
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument("--pmu", default="armv8_pmuv3_1")
    ap.add_argument("--freq", type=int, default=9973)
    ap.add_argument("--pairs", default="foreach,every,map")
    ap.add_argument("--tmpdir", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    os.makedirs(args.tmpdir, exist_ok=True)
    result = {"cpu": args.cpu, "pmu": args.pmu, "freq": args.freq,
              "zjs_binary": os.path.abspath(args.zjs),
              "qjs_binary": os.path.abspath(args.qjs),
              "pairs": {}}

    for key in args.pairs.split(","):
        entry = {}
        for variant, case in (("builtin", f"perf_{key}"),
                              ("control", f"perf_c_{key}")):
            script = os.path.join(CASES, case + ".js")
            for eng, binary in (("qjs", args.qjs), ("zjs", args.zjs)):
                data = os.path.join(args.tmpdir, f"{eng}-{case}.data")
                with open(LOCK, "a") as fh:
                    fcntl.flock(fh, fcntl.LOCK_EX)
                    try:
                        record(binary, script, args.cpu, args.pmu, data,
                               args.freq)
                    finally:
                        fcntl.flock(fh, fcntl.LOCK_UN)
                entry.setdefault(variant, {})[eng] = report(data)
                print(f"{key} {variant} {eng}: "
                      + ", ".join(f"{r['symbol']} {r['percent']}%"
                                  for r in entry[variant][eng][:6]),
                      flush=True)
        result["pairs"][key] = entry

    with open(args.out, "w") as fh:
        json.dump(result, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
