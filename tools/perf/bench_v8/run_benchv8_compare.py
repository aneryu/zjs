#!/usr/bin/env python3
"""Fixed bench-v8 comparison against a reference binary.

This is Octane 2.0 (V8 benchmark suite version 9) -- vendored unmodified
from chromium/octane under tools/perf/bench_v8/suite/ (each file keeps its
own original license header; see suite/LICENSE.octane and README.md for the
per-file exceptions to the default BSD header). Only driver.js is ours.

Version 9 is NOT the suite QuickJS's published bench.html numbers use --
that page reports version 7's narrower 8-benchmark suite. Comparisons run
through this tool are therefore no longer directly comparable to the
published QuickJS numbers; a fresh local qjs run against this same suite is
needed for any qjs comparison (see docs/perf/bench-v8-status.md).

Two modes, differing only in what the reference binary is:

  * `--qjs`      pinned QuickJS. This is the published metric
                 (docs/perf/bench-v8-status.md).
  * `--baseline` a second zjs build. This is the refactor-policy rule 2
                 A/B: does a hot-path reorganization move the number?

The reference role is named throughout the output and in the JSON artifact,
so an A/B result can never be misread later as a QuickJS comparison.

Scores are self-reported and higher-is-better. The reported ratio is
zjs / reference, so below 1.0 means the candidate is slower. The headline is
the suite's own composite "Score (version 9)" ratio (geometric mean per the
suite's definition), computed from per-engine median composites.

Discipline (same spirit as tools/perf/zoo/run_zoo_compare.py):
  * refuses to run unless outer affinity is already exactly the CPUs it will use;
  * every engine invocation re-pins via taskset;
  * samples interleave ABBA to cancel drift; medians decide;
  * emits a JSON artifact naming binaries, hashes, direction, and protocol.

Two protocols, and WHICH ONE IS LEGAL DEPENDS ON THE MODE:

  * serial (default) -- one CPU, one process at a time. Required for --qjs,
    because that mode publishes an ABSOLUTE score. Parallel execution shares
    L3 and memory bandwidth and lowers every absolute score, so a parallel
    number cannot be compared against a published serial one (owner ruling:
    across parallelism levels, only ratios compare).
  * --parallel-clusters A B -- available for --baseline only. Each lane runs
    both engines at the same instant, one per cluster, and the engine-to-
    cluster assignment swaps every batch so per-cluster bias cancels. Rule 2
    consumes only the ratio, so this is sound there, and it turns a 13-minute
    A/B into about two minutes. This is the same two-cluster protocol the zoo
    runner has had since the 2026-08-19 owner ruling; the bench-v8 runner was
    written without it when the metric moved, and got it on 2026-08-20.

Usage:
  # published metric (absolute score) -- serial, exclusive host
  flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
    python3 tools/perf/bench_v8/run_benchv8_compare.py \
      --zjs zig-out/bin/zjs --qjs /home/aneryu/quickjs/qjs \
      --samples 8 --output /tmp/benchv8.json

  # refactor-policy rule 2 A/B (ratio only) -- parallel two-cluster
  flock -x /tmp/zjs-host-heavy.lock taskset -c 5-9,15-19 \
    python3 tools/perf/bench_v8/run_benchv8_compare.py \
      --zjs candidate --baseline merge-base \
      --parallel-clusters 5-9 15-19 --samples 8 --output /tmp/refactor-ab.json
"""

import argparse
import concurrent.futures
import hashlib
import json
import re
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import measurement_pinning  # noqa: E402  (path set above)

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
    "pdfjs.js",
    "mandreel.js",
    "gbemu-part1.js",
    "gbemu-part2.js",
    "code-load.js",
    "box2d.js",
    "zlib.js",
    "zlib-data.js",
    "typescript.js",
    "typescript-input.js",
    "typescript-compiler.js",
]

# Octane's own result names include a digit (Box2D), so the class is
# alphanumeric, not just letters.
RESULT_RE = re.compile(r"^([A-Za-z0-9]+): (\d+(?:\.\d+)?)$")
SKIP_RE = re.compile(r"^([A-Za-z0-9]+): Skipped$")
SCORE_RE = re.compile(r"^Score \(version 9\): (\d+(?:\.\d+)?)$")

# zlib is skip-listed in driver.js pending a zjs engine fix (see
# docs/perf/bench-v8-status.md): indirect eval() of emscripten-generated
# code throws. Skipped suites report no numeric score for either engine, so
# they are excluded from the ratio table rather than expected as numeric.
SKIPPED_SUITES = {"zlib"}
EXPECTED_SUITES = 17 - len(SKIPPED_SUITES)  # 15 BenchmarkSuite registrations + SplayLatency + MandreelLatency


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
    skipped: set[str] = set()
    score = None
    for line in proc.stdout.splitlines():
        stripped = line.strip()
        if m := SKIP_RE.match(stripped):
            if m.group(1) not in SKIPPED_SUITES:
                raise RuntimeError(f"{binary}: unexpected skip not in SKIPPED_SUITES: {line}")
            skipped.add(m.group(1))
        elif m := RESULT_RE.match(stripped):
            if "ERROR" in line:
                raise RuntimeError(f"{binary}: {line}")
            suites[m.group(1)] = float(m.group(2))
        elif m := SCORE_RE.match(stripped):
            score = float(m.group(1))
    if score is None or len(suites) != EXPECTED_SUITES or skipped != SKIPPED_SUITES:
        raise RuntimeError(
            f"{binary}: incomplete output ({len(suites)} suites, skipped={skipped}, score={score})"
        )
    return {"suites": suites, "score": score}


def parallel_schedule(samples: int, width: int) -> list[tuple[int, bool]]:
    """Batches of (lane count, swap) that give each cluster assignment exactly
    half the samples.

    Balance is the whole point of swapping, and it is easy to lose: eight
    samples over five lanes batch as 5 + 3, so one assignment gets five
    samples and the other three, and any asymmetry between the two clusters
    survives straight into the median. Measured on 2026-08-20: that schedule
    read Splay -5.3% where a serial adjudication run read +0.2%.

    So the schedule is built from equal halves and the batches alternate.
    """
    if samples % 2 != 0:
        raise ValueError(f"--samples must be even under --parallel-clusters (got {samples})")
    half = samples // 2
    per_side: list[int] = []
    remaining = half
    while remaining > 0:
        take = min(width, remaining)
        per_side.append(take)
        remaining -= take
    schedule: list[tuple[int, bool]] = []
    for lanes in per_side:
        schedule.append((lanes, False))
        schedule.append((lanes, True))
    return schedule


def run_parallel_batch(
    lane_count: int,
    binaries: dict[str, Path],
    script: Path,
    cluster_a: list[int],
    cluster_b: list[int],
    swap: bool,
) -> list[dict[str, dict]]:
    """Run `lane_count` sample pairs at once, both engines simultaneously per lane.

    Running the pair at the same instant on equal clusters is what makes this
    sound: any drift in frequency, thermals or host noise hits both sides of
    the ratio together, which serial ABBA can only approximate. `swap` flips
    which engine gets which cluster so a systematic difference between the two
    clusters cancels across batches.
    """
    first, second = ("zjs", "ref") if not swap else ("ref", "zjs")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2 * lane_count) as pool:
        futures = {}
        for lane in range(lane_count):
            futures[(lane, first)] = pool.submit(run_once, binaries[first], script, cluster_a[lane])
            futures[(lane, second)] = pool.submit(run_once, binaries[second], script, cluster_b[lane])
        return [
            {role: futures[(lane, role)].result() for role in ("zjs", "ref")}
            for lane in range(lane_count)
        ]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zjs", required=True, help="the candidate zjs binary")
    reference = ap.add_mutually_exclusive_group(required=True)
    reference.add_argument("--qjs", help="pinned QuickJS binary (published-metric mode)")
    reference.add_argument("--baseline", help="a second zjs build (refactor-policy rule 2 A/B mode)")
    ap.add_argument("--samples", type=int, default=8, help="samples per engine (default: 8)")
    ap.add_argument("--cpu", type=int, default=19, help="CPU for the serial protocol")
    ap.add_argument(
        "--parallel-clusters",
        nargs=2,
        metavar=("CLUSTER_A", "CLUSTER_B"),
        help="run cluster-swapped parallel batches on two equal, disjoint cpulists "
        "(--baseline only; the published --qjs metric is an absolute score and stays serial)",
    )
    ap.add_argument("--output", help="write the JSON artifact here")
    args = ap.parse_args()

    # The reference role is carried as data, not as a hardcoded "qjs", so the
    # printed table and the artifact both state which comparison was run.
    ref_name = "qjs" if args.qjs else "baseline"

    clusters = None
    if args.parallel_clusters:
        if args.qjs:
            print(
                "error: --parallel-clusters is not available with --qjs.\n"
                "That mode publishes an absolute Score; parallel execution lowers every\n"
                "absolute score, so its number would not be comparable to the published one.\n"
                "Use it with --baseline, where only the ratio is consumed.",
                file=sys.stderr,
            )
            return 2
        try:
            clusters = measurement_pinning.parse_cluster_pair(*args.parallel_clusters)
        except ValueError as exc:
            print(f"error: invalid --parallel-clusters: {exc}", file=sys.stderr)
            return 2

    # Pinning must be effective, not merely requested.
    expected_affinity = set(clusters[0]) | set(clusters[1]) if clusters else {args.cpu}
    if message := measurement_pinning.affinity_error(expected_affinity, sys.argv[0]):
        print(message, file=sys.stderr)
        return 2

    here = Path(__file__).resolve().parent
    zjs = Path(args.zjs).resolve()
    ref = Path(args.qjs or args.baseline).resolve()

    with tempfile.NamedTemporaryFile(suffix=".js", delete=False) as tf:
        combined = Path(tf.name)
    try:
        build_combined(here / "suite", here / "driver.js", combined)

        runs: dict[str, list[dict]] = {"zjs": [], ref_name: []}
        if clusters is None:
            # ABBA interleave: AB BA AB BA ...
            for i in range(args.samples):
                order = [("zjs", zjs), (ref_name, ref)] if i % 2 == 0 else [(ref_name, ref), ("zjs", zjs)]
                for name, binary in order:
                    runs[name].append(run_once(binary, combined, args.cpu))
                    print(f"sample {i + 1}/{args.samples} {name}: score {runs[name][-1]['score']:.0f}", flush=True)
        else:
            cluster_a, cluster_b = clusters
            binaries = {"zjs": zjs, "ref": ref}
            done = 0
            for lanes, swap in parallel_schedule(args.samples, len(cluster_a)):
                pairs = run_parallel_batch(lanes, binaries, combined, cluster_a, cluster_b, swap)
                for lane, pair in enumerate(pairs):
                    runs["zjs"].append(pair["zjs"])
                    runs[ref_name].append(pair["ref"])
                    print(
                        f"sample {done + lane + 1}/{args.samples} "
                        f"zjs {pair['zjs']['score']:.0f} / {ref_name} {pair['ref']['score']:.0f}",
                        flush=True,
                    )
                done += lanes

        suite_names = list(runs["zjs"][0]["suites"].keys())
        med = {
            eng: {
                "score": statistics.median(r["score"] for r in runs[eng]),
                "suites": {s: statistics.median(r["suites"][s] for r in runs[eng]) for s in suite_names},
            }
            for eng in ("zjs", ref_name)
        }
        ratios = {s: med["zjs"]["suites"][s] / med[ref_name]["suites"][s] for s in suite_names}
        headline = med["zjs"]["score"] / med[ref_name]["score"]

        protocol_line = (
            f"parallel clusters {args.parallel_clusters[0]} / {args.parallel_clusters[1]}, "
            "cluster-swapped (ratios only; absolute scores are not comparable to serial runs)"
            if clusters
            else f"serial, CPU {args.cpu}"
        )
        print(f"\nprotocol: {protocol_line}")
        print(f"per-suite median (zjs / {ref_name}, higher is better):")
        for s in suite_names:
            print(f"  {s:14} {med['zjs']['suites'][s]:8.0f} / {med[ref_name]['suites'][s]:8.0f}  ratio {ratios[s]:.4f}")
        print(f"\ncomposite Score (version 9) medians: zjs {med['zjs']['score']:.0f} / {ref_name} {med[ref_name]['score']:.0f}")
        print(f"headline ratio (zjs/{ref_name}): {headline:.4f}")

        artifact = {
            "tool": "run_benchv8_compare",
            "suiteVersion": "9",
            "mode": "published-metric" if args.qjs else "refactor-ab",
            "referenceRole": ref_name,
            "scoreDirection": "higher-is-better",
            "ratioDefinition": f"zjs / {ref_name} of per-engine median composite Score",
            # Absolute scores are only comparable within one protocol, so the
            # artifact states which one produced them.
            "protocol": (
                {"kind": "parallel-clusters", "clusterA": clusters[0], "clusterB": clusters[1]}
                if clusters
                else {"kind": "serial", "cpu": args.cpu}
            ),
            "cpu": args.cpu,
            "samples": args.samples,
            "binaries": {
                "zjs": {"path": str(zjs), "md5": md5(zjs)},
                ref_name: {"path": str(ref), "md5": md5(ref)},
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
