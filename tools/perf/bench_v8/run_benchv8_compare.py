#!/usr/bin/env python3
"""Fixed bench-v8 comparison between zjs and pinned QuickJS.

This is the V8 benchmark suite version 7 -- the suite Bellard's QuickJS
publishes its scores with (bellard.org/quickjs/bench.html). The suite is
vendored unmodified under tools/perf/bench_v8/suite/ (BSD license headers
retained); only driver.js is ours.

Scores are self-reported and higher-is-better. This tool reports
ratio = zjs / qjs, so below 1.0 means zjs is slower. The headline is the
suite's own composite "Score (version 7)" ratio (geometric mean per the
suite's definition), computed from per-engine median composites.

Discipline (same spirit as tools/perf/zoo/run_zoo_compare.py):
  * refuses to run unless outer affinity is already pinned to --cpu;
  * every engine invocation re-pins via taskset to --cpu;
  * samples interleave ABBA to cancel drift; medians decide;
  * emits a JSON artifact naming binaries, hashes, and direction.

Usage:
  flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
    python3 tools/perf/bench_v8/run_benchv8_compare.py \
      --zjs zig-out/bin/zjs --qjs /home/aneryu/quickjs/qjs \
      --samples 8 --output /tmp/benchv8.json
"""

import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

SUITE_ORDER = [
    "base.js",
    "richards.js",
    "deltablue.js",
    "crypto.js",
    "raytrace.js",
    "earley-boyer.js",
    "regexp.js",
    "splay.js",
    "navier-stokes.js",
]

RESULT_RE = re.compile(r"^([A-Za-z]+): (\d+(?:\.\d+)?)$")
SCORE_RE = re.compile(r"^Score \(version 7\): (\d+(?:\.\d+)?)$")


def md5(path: Path) -> str:
    return hashlib.md5(path.read_bytes()).hexdigest()


def build_combined(suite_dir: Path, driver: Path, out: Path) -> None:
    parts = [(suite_dir / name).read_text() for name in SUITE_ORDER]
    parts.append(driver.read_text())
    out.write_text("\n".join(parts))


def run_once(binary: Path, script: Path, cpu: int) -> dict:
    proc = subprocess.run(
        ["taskset", "-c", str(cpu), str(binary), str(script)],
        capture_output=True,
        text=True,
        timeout=600,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"{binary} exited {proc.returncode}: {proc.stderr[:400]}")
    suites: dict[str, float] = {}
    score = None
    for line in proc.stdout.splitlines():
        if m := RESULT_RE.match(line.strip()):
            if "ERROR" in line:
                raise RuntimeError(f"{binary}: {line}")
            suites[m.group(1)] = float(m.group(2))
        elif m := SCORE_RE.match(line.strip()):
            score = float(m.group(1))
    if score is None or len(suites) != 8:
        raise RuntimeError(f"{binary}: incomplete output ({len(suites)} suites, score={score})")
    return {"suites": suites, "score": score}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zjs", required=True)
    ap.add_argument("--qjs", required=True)
    ap.add_argument("--samples", type=int, default=8, help="samples per engine (default: 8)")
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument("--output", help="write the JSON artifact here")
    args = ap.parse_args()

    affinity = set(os.sched_getaffinity(0))
    if affinity != {args.cpu}:
        print(
            f"error: outer affinity is {sorted(affinity)}, expected exactly [{args.cpu}].\n"
            f"Run under: taskset -c {args.cpu} python3 {sys.argv[0]} ...",
            file=sys.stderr,
        )
        return 2

    here = Path(__file__).resolve().parent
    zjs = Path(args.zjs).resolve()
    qjs = Path(args.qjs).resolve()

    with tempfile.NamedTemporaryFile(suffix=".js", delete=False) as tf:
        combined = Path(tf.name)
    try:
        build_combined(here / "suite", here / "driver.js", combined)

        runs: dict[str, list[dict]] = {"zjs": [], "qjs": []}
        # ABBA interleave: zq qz zq qz ...
        for i in range(args.samples):
            order = [("zjs", zjs), ("qjs", qjs)] if i % 2 == 0 else [("qjs", qjs), ("zjs", zjs)]
            for name, binary in order:
                runs[name].append(run_once(binary, combined, args.cpu))
                print(f"sample {i + 1}/{args.samples} {name}: score {runs[name][-1]['score']:.0f}", flush=True)

        suite_names = list(runs["zjs"][0]["suites"].keys())
        med = {
            eng: {
                "score": statistics.median(r["score"] for r in runs[eng]),
                "suites": {s: statistics.median(r["suites"][s] for r in runs[eng]) for s in suite_names},
            }
            for eng in ("zjs", "qjs")
        }
        ratios = {s: med["zjs"]["suites"][s] / med["qjs"]["suites"][s] for s in suite_names}
        headline = med["zjs"]["score"] / med["qjs"]["score"]

        print("\nper-suite median (zjs / qjs, higher is better):")
        for s in suite_names:
            print(f"  {s:14} {med['zjs']['suites'][s]:8.0f} / {med['qjs']['suites'][s]:8.0f}  ratio {ratios[s]:.4f}")
        print(f"\ncomposite Score (version 7) medians: zjs {med['zjs']['score']:.0f} / qjs {med['qjs']['score']:.0f}")
        print(f"headline ratio (zjs/qjs): {headline:.4f}")

        artifact = {
            "tool": "run_benchv8_compare",
            "suiteVersion": "7",
            "scoreDirection": "higher-is-better",
            "ratioDefinition": "zjs / qjs of per-engine median composite Score",
            "cpu": args.cpu,
            "samples": args.samples,
            "binaries": {
                "zjs": {"path": str(zjs), "md5": md5(zjs)},
                "qjs": {"path": str(qjs), "md5": md5(qjs)},
            },
            "medians": med,
            "suiteRatios": ratios,
            "headlineRatio": headline,
            "rawRuns": runs,
        }
        if args.output:
            Path(args.output).write_text(json.dumps(artifact, indent=2))
            print(f"artifact: {args.output}")
    finally:
        combined.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
