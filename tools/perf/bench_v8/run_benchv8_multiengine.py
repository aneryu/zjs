#!/usr/bin/env python3
"""Multi-engine bench-v8 (Octane 2.0) snapshot: zjs vs any of qjs/hermes/
v8-jitless/jsc-jitless, on the same combined suite script.

This is the N-way counterpart to run_benchv8_compare.py, which is
pairwise (zjs vs exactly one reference) by design. Use this tool only for
cross-engine snapshots that name every engine explicitly in the table and
the artifact; use run_benchv8_compare.py for the published zjs/QuickJS
metric and for refactor-policy A/B, where its pairwise fail-closed checks
and parallel-cluster protocol apply.

Discipline (same spirit as run_benchv8_compare.py and
tools/perf/zoo/run_zoo_compare.py):
  * refuses to run unless outer affinity is already exactly {--cpu};
  * every engine invocation re-pins via taskset;
  * samples round-robin forward then reverse across all engines each pair
    of rounds, so a systematic drift across the run does not land on one
    engine more than another;
  * every engine's binary MD5 is checked unchanged before and after;
  * emits a JSON artifact naming every binary, hash, and the full order log.

v8-jitless and jsc-jitless need engine-specific flags to disable their JIT
(`--jitless`, `--useJIT=false`); those are hardcoded per engine below, not
user-configurable, so the "jitless" label in the output is always true of
what actually ran.

Usage:
  flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
    python3 tools/perf/bench_v8/run_benchv8_multiengine.py \
      --zjs zig-out/bin/zjs \
      --qjs /home/aneryu/quickjs/qjs \
      --hermes /home/aneryu/hermes/build_release/bin/hermes \
      --v8 /home/aneryu/v8/out/arm64.release/d8 \
      --jsc /home/aneryu/WebKit/WebKitBuild/JSCOnly/Release/bin/jsc \
      --samples 8 --output /tmp/benchv8-multiengine.json
"""

import argparse
import hashlib
import json
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_benchv8_compare as bv8  # noqa: E402  (path set above)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import measurement_pinning  # noqa: E402  (path set above)

# Engine-specific flags needed to reach the comparison's declared
# configuration (jitless for v8 and jsc). Not exposed as CLI options: the
# whole point of naming these engines in the table is that the flag that
# gets them there is fixed, not caller-chosen.
ENGINE_EXTRA_ARGS = {
    "zjs": [],
    "qjs": [],
    "hermes": [],
    "v8": ["--jitless"],
    "jsc": ["--useJIT=false"],
}

ENGINE_LABELS = {
    "zjs": "zjs",
    "qjs": "QuickJS",
    "hermes": "Hermes",
    "v8": "V8 (jitless)",
    "jsc": "JSC (jitless)",
}


def md5(path: Path) -> str:
    return hashlib.md5(path.read_bytes()).hexdigest()


def run_once(binary: Path, extra_args: list[str], script: Path, cpu: int) -> dict:
    proc = subprocess.run(
        ["taskset", "-c", str(cpu), str(binary), *extra_args, str(script)],
        capture_output=True,
        text=True,
        timeout=600,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"{binary} exited {proc.returncode}: {proc.stderr[:400]}")
    suites: dict[str, float] = {}
    skipped: set[str] = set()
    score = None
    for line in proc.stdout.splitlines():
        stripped = line.strip()
        if m := bv8.SKIP_RE.match(stripped):
            if m.group(1) not in bv8.SKIPPED_SUITES:
                raise RuntimeError(f"{binary}: unexpected skip not in SKIPPED_SUITES: {line}")
            skipped.add(m.group(1))
        elif m := bv8.RESULT_RE.match(stripped):
            if "ERROR" in line:
                raise RuntimeError(f"{binary}: {line}")
            suites[m.group(1)] = float(m.group(2))
        elif m := bv8.SCORE_RE.match(stripped):
            score = float(m.group(1))
    if score is None or len(suites) != bv8.EXPECTED_SUITES or skipped != bv8.SKIPPED_SUITES:
        raise RuntimeError(
            f"{binary}: incomplete output ({len(suites)} suites, skipped={skipped}, score={score})"
        )
    return {"suites": suites, "score": score}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zjs", required=True, help="the zjs binary (always included)")
    ap.add_argument("--qjs", help="pinned QuickJS binary")
    ap.add_argument("--hermes", help="Hermes binary")
    ap.add_argument("--v8", help="V8 d8 binary (run with --jitless)")
    ap.add_argument("--jsc", help="JavaScriptCore jsc binary (run with --useJIT=false)")
    ap.add_argument("--samples", type=int, default=8, help="samples per engine (default: 8)")
    ap.add_argument("--cpu", type=int, default=19, help="CPU for the serial protocol")
    ap.add_argument("--output", help="write the JSON artifact here")
    args = ap.parse_args()

    engines: dict[str, Path] = {"zjs": Path(args.zjs).resolve()}
    for name, val in (("qjs", args.qjs), ("hermes", args.hermes), ("v8", args.v8), ("jsc", args.jsc)):
        if val:
            engines[name] = Path(val).resolve()
    if len(engines) < 2:
        print("error: need at least one reference engine besides --zjs", file=sys.stderr)
        return 2

    if message := measurement_pinning.affinity_error({args.cpu}, sys.argv[0]):
        print(message, file=sys.stderr)
        return 2

    names = list(engines.keys())
    hashes_before = {n: md5(p) for n, p in engines.items()}

    here = Path(__file__).resolve().parent
    with tempfile.NamedTemporaryFile(suffix=".js", delete=False) as tf:
        combined = Path(tf.name)
    try:
        bv8.build_combined(here / "suite", here / "driver.js", combined)

        runs: dict[str, list[dict]] = {n: [] for n in names}
        order_log: list[str] = []
        for r in range(args.samples):
            order = names if r % 2 == 0 else list(reversed(names))
            for name in order:
                result = run_once(engines[name], ENGINE_EXTRA_ARGS.get(name, []), combined, args.cpu)
                runs[name].append(result)
                order_log.append(name)
                print(f"round {r + 1}/{args.samples} {name}: score {result['score']:.0f}", flush=True)

        hashes_after = {n: md5(p) for n, p in engines.items()}
        changed = [n for n in names if hashes_before[n] != hashes_after[n]]
        if changed:
            raise RuntimeError(f"binary changed during the run: {changed}")

        suite_names = list(runs[names[0]][0]["suites"].keys())
        med = {
            n: {
                "score": statistics.median(r["score"] for r in runs[n]),
                "suites": {s: statistics.median(r["suites"][s] for r in runs[n]) for s in suite_names},
            }
            for n in names
        }

        ref = "qjs" if "qjs" in names else names[0]

        print(f"\nprotocol: serial, CPU {args.cpu}, forward/reverse round-robin, {args.samples} samples/engine")
        print(f"reference for ratios: {ENGINE_LABELS[ref]}")
        header = f"  {'suite':14}" + "".join(f"{ENGINE_LABELS[n]:>16}" for n in names)
        print(header)
        for s in suite_names:
            row = f"  {s:14}" + "".join(f"{med[n]['suites'][s]:16.0f}" for n in names)
            print(row)
        print(f"  {'Score (v9)':14}" + "".join(f"{med[n]['score']:16.0f}" for n in names))
        print()
        for n in names:
            if n == ref:
                continue
            print(f"ratio {ENGINE_LABELS[n]} / {ENGINE_LABELS[ref]}: {med[n]['score'] / med[ref]['score']:.4f}")

        artifact = {
            "tool": "run_benchv8_multiengine",
            "suiteVersion": "9",
            "scoreDirection": "higher-is-better",
            "referenceForRatios": ref,
            "skippedSuites": sorted(bv8.SKIPPED_SUITES),
            "protocol": {
                "kind": "serial-round-robin-forward-reverse",
                "cpu": args.cpu,
            },
            "cpu": args.cpu,
            "samples": args.samples,
            "engines": {n: ENGINE_LABELS[n] for n in names},
            "binaries": {n: {"path": str(engines[n]), "md5": hashes_before[n]} for n in names},
            "medians": med,
            "ratiosVsReference": {n: med[n]["score"] / med[ref]["score"] for n in names if n != ref},
            "executionOrder": order_log,
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
