#!/usr/bin/env python3
"""GC-GAP six-benchmark four-row account (policies/gc_merge_policy.json
gap_measurement). Fixed-work matched runs, three arms, paired rotation.
Rows per benchmark: wall ratio, peak RSS, quiescent committed/live,
pause distribution + collection counts."""
import json, re, subprocess, sys, time
from pathlib import Path

FROZEN = Path("/home/aneryu/zjs-frozen/base-g0-2026-08-26")
ARMS = {
    "trace": str(FROZEN / "zjs-tracestw-candidate-62061f94"),
    "rc_tip": str(FROZEN / "zjs-rc-branchtip-62061f94"),
    "rc_mb": str(FROZEN / "zjs-rc-mergebase-14b0618d"),
}
BENCHES = ["deltablue", "regexp", "pdfjs", "raytrace", "earley-boyer", "splay"]
SRC = Path("/home/aneryu/javascript-zoo/bench")
FIXED = Path("/tmp/gcgap-fixed")
SAMPLES = 8
CPU = "19"

FIXED.mkdir(exist_ok=True)
for b in BENCHES:
    s = (SRC / f"{b}.js").read_text()
    s = s.replace("BenchmarkSuite.config.doWarmup = undefined;",
                  "BenchmarkSuite.config.doWarmup = false;")
    s = s.replace("BenchmarkSuite.config.doDeterministic = undefined;",
                  "BenchmarkSuite.config.doDeterministic = true;")
    (FIXED / f"{b}.js").write_text(s)

def run_one(binary, js):
    t0 = time.perf_counter()
    p = subprocess.run(
        ["taskset", "-c", CPU, "/usr/bin/time", "-v", binary, "--gc-stats", str(js)],
        capture_output=True, text=True, timeout=600)
    wall = time.perf_counter() - t0
    if p.returncode != 0:
        raise RuntimeError(f"{binary} {js} exited {p.returncode}: {p.stderr[-400:]}")
    m = re.search(r"Maximum resident set size \(kbytes\): (\d+)", p.stderr)
    gc_lines = [l for l in p.stdout.splitlines() if l.startswith("gc: ")]
    return {"wall_s": wall, "maxrss_kb": int(m.group(1)) if m else None,
            "gc_panel": gc_lines}

results = {b: {a: [] for a in ARMS} for b in BENCHES}
order = list(ARMS)
for s in range(SAMPLES):
    arm_order = order if s % 2 == 0 else order[::-1]
    for b in BENCHES:
        for a in arm_order:
            results[b][a].append(run_one(ARMS[a], FIXED / f"{b}.js"))
        print(f"sample {s+1}/{SAMPLES} {b} done", flush=True)

out = {"samples": SAMPLES, "cpu": CPU, "arms": ARMS,
       "protocol": "fixed-work (doWarmup=false, doDeterministic=true), paired per-bench rotation ABBA-alternated, pinned CPU 19 under host-heavy flock",
       "results": results}
Path("/tmp/gcgap-account.json").write_text(json.dumps(out, indent=1))
print("account written to /tmp/gcgap-account.json")
