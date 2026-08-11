#!/usr/bin/env python3
"""Fixed zoo (Octane) macro comparison between zjs and pinned QuickJS.

The zoo benchmarks are self-scoring: each `bench/<name>.js` prints one or more
`Name: <integer>` lines where **higher is better**. This runner exists so that
comparison is reproducible rather than re-improvised each time, and so that it
carries the same discipline as the whole-process microbench contract:

  * even sample count with a balanced first position (contract #3) -- an odd
    count is refused rather than rounded, since silently changing the sampling
    design behind the caller's back is the failure that contract exists to stop;
  * effective CPU affinity pinned to either one serial core or the exact two
    clusters requested for parallel comparison, verified rather than assumed;
  * the exclusive host lock held across the whole run, so no build or test
    perturbs the measurement;
  * full provenance in the artifact -- both binaries' SHA-256, both commits,
    kernel, CPU model, and the actual execution order.

Unlike the microbench runner this reports *scores*, so the ratio is
`zjs / qjs` with **higher meaning zjs is better**; a ratio below 1.0 means zjs
is slower. That inversion relative to the time-based tools is deliberate --
it keeps each benchmark's number in the units the benchmark itself publishes --
and every emitted field says which direction it is in.

Usage:
    tools/perf/zoo/run_zoo_compare.py --zjs zig-out/bin/zjs \\
        --qjs /home/aneryu/quickjs/qjs --samples 4 --cpu 19 \\
        --output reports/.../zoo-compare.json

    taskset -c 5-9,15-19 tools/perf/zoo/run_zoo_compare.py \\
        --zjs zig-out/bin/zjs --qjs /home/aneryu/quickjs/qjs --samples 4 \\
        --parallel-clusters 5-9 15-19 \\
        --output reports/.../zoo-compare-parallel.json
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import math
import os
import platform
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

# The Octane 2.0 set as vendored by javascript-zoo. `v8-v7*.js` belong to a
# different suite and are deliberately excluded; add them explicitly if wanted.
DEFAULT_BENCHES = [
    "box2d",
    "code-load",
    "crypto",
    "deltablue",
    "earley-boyer",
    "gbemu",
    "mandreel",
    "navier-stokes",
    "pdfjs",
    "raytrace",
    "regexp",
    "richards",
    "splay",
    "typescript",
    "zlib",
]

# Benchmarks that publish a second, latency-oriented score. It is reported but
# kept out of the headline geomean, because it is a different quantity from the
# throughput score and mixing them would make the aggregate uninterpretable.
LATENCY_KEYS = {"MandreelLatency", "SplayLatency"}

SCORE_RE = re.compile(r"^([A-Za-z0-9_]+):\s+([0-9]+)\s*$")


class RunFailure(RuntimeError):
    """One engine invocation did not produce a trustworthy score."""


def fail(message: str, code: int = 2) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_describe(repo: Path) -> dict:
    def run(*args: str) -> str | None:
        try:
            out = subprocess.run(
                ["git", "-C", str(repo), *args],
                capture_output=True, text=True, check=True,
            )
            return out.stdout.strip()
        except Exception:
            return None

    return {
        "path": str(repo),
        "commit": run("rev-parse", "HEAD"),
        "dirty": bool(run("status", "--porcelain")),
    }


def effective_affinity() -> set[int]:
    return set(os.sched_getaffinity(0))


def cpu_model() -> str | None:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name") or line.startswith("Model"):
                return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return None


def parse_scores(text: str) -> dict[str, int]:
    scores: dict[str, int] = {}
    for line in text.splitlines():
        m = SCORE_RE.match(line.strip())
        if m:
            scores[m.group(1)] = int(m.group(2))
    return scores


def parse_cpu_list(spec: str) -> list[int]:
    """Parse Linux cpulist syntax while preserving lane order."""
    cpus: list[int] = []
    seen: set[int] = set()
    for raw_part in spec.split(","):
        part = raw_part.strip()
        if not part:
            raise ValueError(f"invalid empty CPU-list component in {spec!r}")
        if "-" in part:
            bounds = part.split("-")
            if len(bounds) != 2 or not all(bound.isdigit() for bound in bounds):
                raise ValueError(f"invalid CPU range {part!r}")
            start, end = (int(bound) for bound in bounds)
            if end < start:
                raise ValueError(f"descending CPU range {part!r} is not allowed")
            values = range(start, end + 1)
        else:
            if not part.isdigit():
                raise ValueError(f"invalid CPU {part!r}")
            values = (int(part),)
        for cpu in values:
            if cpu in seen:
                raise ValueError(f"CPU {cpu} occurs more than once in {spec!r}")
            cpus.append(cpu)
            seen.add(cpu)
    if not cpus:
        raise ValueError("CPU list must not be empty")
    return cpus


def run_one(binary: Path, script: Path, cpu: int, timeout: int) -> tuple[dict[str, int], float]:
    started = time.monotonic()
    try:
        proc = subprocess.run(
            ["taskset", "-c", str(cpu), str(binary), str(script)],
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise RunFailure(
            f"{binary.name} timed out after {timeout}s for {script.name} on CPU {cpu}"
        ) from exc
    elapsed = time.monotonic() - started
    scores = parse_scores(proc.stdout + proc.stderr)
    if proc.returncode != 0:
        raise RunFailure(
            f"{binary.name} exited {proc.returncode} for {script.name} on CPU {cpu}; "
            f"stderr={proc.stderr.strip()[-400:]!r}"
        )
    if not scores:
        raise RunFailure(
            f"{binary.name} produced no parseable score for {script.name}; "
            f"exit={proc.returncode} stderr={proc.stderr.strip()[:200]!r}"
        )
    return scores, elapsed


def parallel_assignments(
    benches: list[str], sample: int, cluster_a: list[int], cluster_b: list[int]
) -> list[tuple[str, str, int, str]]:
    """Return (bench, engine, cpu, cluster) assignments for one batch."""
    if len(benches) > len(cluster_a) or len(cluster_a) != len(cluster_b):
        raise ValueError("parallel batch and cluster widths do not match")
    engine_a, engine_b = ("qjs", "zjs") if sample % 2 == 0 else ("zjs", "qjs")
    assignments: list[tuple[str, str, int, str]] = []
    for lane, bench in enumerate(benches):
        assignments.append((bench, engine_a, cluster_a[lane], "a"))
        assignments.append((bench, engine_b, cluster_b[lane], "b"))
    return assignments


def run_parallel_batch(
    assignments: list[tuple[str, str, int, str]],
    binaries: dict[str, Path],
    scripts: dict[str, Path],
    timeout: int,
) -> dict[tuple[str, str], tuple[dict[str, int], float, int, str]]:
    """Launch all assignments concurrently and return results by benchmark/engine."""
    outputs: dict[tuple[str, str], tuple[dict[str, int], float, int, str]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(assignments)) as pool:
        futures = {
            (bench, engine): (
                pool.submit(run_one, binaries[engine], scripts[bench], cpu, timeout),
                cpu,
                cluster,
            )
            for bench, engine, cpu, cluster in assignments
        }
        for bench, engine, _, _ in assignments:
            future, cpu, cluster = futures[(bench, engine)]
            scores, elapsed = future.result()
            outputs[(bench, engine)] = (scores, elapsed, cpu, cluster)
    return outputs


def geomean(values: list[float]) -> float:
    return math.exp(sum(math.log(v) for v in values) / len(values))


def median(values: list[int] | list[float]) -> int | float:
    return statistics.median(values)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zjs", required=True)
    ap.add_argument("--qjs", required=True)
    ap.add_argument("--zoo", default="/home/aneryu/javascript-zoo", help="javascript-zoo checkout")
    ap.add_argument("--samples", type=int, default=4, help="samples per engine per benchmark, must be even (default: 4)")
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument(
        "--parallel-clusters",
        nargs=2,
        metavar=("CLUSTER_A", "CLUSTER_B"),
        help=(
            "run cluster-swapped parallel batches on two equal Linux cpulists "
            "(example: 5-9 15-19); outer taskset affinity must equal their union"
        ),
    )
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--benches", nargs="*", default=None)
    ap.add_argument("--output")
    args = ap.parse_args()

    # Contract #3. Refuse rather than round: the caller asked for a specific
    # design and silently changing it is what the contract forbids.
    if args.samples % 2 != 0:
        fail(
            f"--samples must be even; {args.samples} is odd and cannot balance the "
            "paired order (measurement contract #3)"
        )
    if args.samples < 2:
        fail("--samples must be at least 2")

    parallel_clusters: tuple[list[int], list[int]] | None = None
    if args.parallel_clusters:
        try:
            cluster_a = parse_cpu_list(args.parallel_clusters[0])
            cluster_b = parse_cpu_list(args.parallel_clusters[1])
        except ValueError as exc:
            fail(f"invalid --parallel-clusters: {exc}")
        if len(cluster_a) != len(cluster_b):
            fail(
                "--parallel-clusters must have equal widths; "
                f"got {len(cluster_a)} and {len(cluster_b)} CPUs"
            )
        overlap = sorted(set(cluster_a) & set(cluster_b))
        if overlap:
            fail(f"--parallel-clusters must be disjoint; overlap: {overlap}")
        parallel_clusters = (cluster_a, cluster_b)

    # Pinning must be effective, not merely requested. An allowed set that
    # merely contains the requested CPUs is not pinning.
    affinity = effective_affinity()
    expected_affinity = (
        set(parallel_clusters[0]) | set(parallel_clusters[1])
        if parallel_clusters
        else {args.cpu}
    )
    if affinity != expected_affinity:
        requested = (
            ",".join(str(cpu) for cpu in sorted(expected_affinity))
            if parallel_clusters
            else str(args.cpu)
        )
        fail(
            f"this process's effective affinity is {sorted(affinity)}, not exactly "
            f"{sorted(expected_affinity)}; re-run under `taskset -c {requested}` and the exclusive "
            "host lock (measurement contract: affinity is attested, not requested)"
        )

    zjs, qjs = Path(args.zjs).resolve(), Path(args.qjs).resolve()
    zoo = Path(args.zoo).resolve()
    for p in (zjs, qjs):
        if not p.is_file():
            fail(f"binary not found: {p}")
    bench_dir = zoo / "bench"
    if not bench_dir.is_dir():
        fail(f"zoo bench directory not found: {bench_dir}")

    benches = args.benches or DEFAULT_BENCHES
    missing = [b for b in benches if not (bench_dir / f"{b}.js").is_file()]
    if missing:
        fail(f"missing benchmark sources: {', '.join(missing)}")

    repo_root = Path(__file__).resolve().parents[3]
    binary_info = {
        "zjs": {"path": str(zjs), "sha256": sha256_of(zjs), "repo": git_describe(repo_root)},
        "qjs": {"path": str(qjs), "sha256": sha256_of(qjs), "repo": git_describe(qjs.parent)},
    }
    zoo_info = git_describe(zoo)

    results: dict[str, dict] = {}
    order_log: list[dict] = []
    per_bench: dict[str, dict] = {
        bench: {
            "scores": {"zjs": {}, "qjs": {}},
            "wall": {"zjs": [], "qjs": []},
        }
        for bench in benches
    }
    scripts = {bench: bench_dir / f"{bench}.js" for bench in benches}
    binaries = {"zjs": zjs, "qjs": qjs}

    def record(bench: str, engine: str, scores: dict[str, int], elapsed: float) -> None:
        per_bench[bench]["wall"][engine].append(elapsed)
        for key, value in scores.items():
            per_bench[bench]["scores"][engine].setdefault(key, []).append(value)

    measurement_started = time.monotonic()
    try:
        if parallel_clusters:
            cluster_a, cluster_b = parallel_clusters
            width = len(cluster_a)
            for sample in range(args.samples):
                for batch_start in range(0, len(benches), width):
                    batch = benches[batch_start : batch_start + width]
                    assignments = parallel_assignments(batch, sample, cluster_a, cluster_b)
                    outputs = run_parallel_batch(assignments, binaries, scripts, args.timeout)
                    group = f"sample-{sample + 1}-batch-{batch_start // width + 1}"
                    for bench in batch:
                        cpu_assignments: dict[str, dict] = {}
                        for engine in ("qjs", "zjs"):
                            scores, elapsed, cpu, cluster = outputs[(bench, engine)]
                            record(bench, engine, scores, elapsed)
                            cpu_assignments[engine] = {"cpu": cpu, "cluster": cluster}
                            print(
                                f"  {bench:14} sample {sample + 1}/{args.samples} "
                                f"{engine:4}@{cpu:<2} {scores}",
                                file=sys.stderr,
                            )
                        order_log.append(
                            {
                                "bench": bench,
                                "sample": sample,
                                "concurrent": True,
                                "simultaneousGroup": group,
                                "cpuAssignments": cpu_assignments,
                            }
                        )
        else:
            for bench in benches:
                for sample in range(args.samples):
                    # Alternate the leading engine so each occupies each position equally.
                    order = ["qjs", "zjs"] if sample % 2 == 0 else ["zjs", "qjs"]
                    order_log.append({"bench": bench, "sample": sample, "order": "->".join(order)})
                    for engine in order:
                        scores, elapsed = run_one(binaries[engine], scripts[bench], args.cpu, args.timeout)
                        record(bench, engine, scores, elapsed)
                        print(
                            f"  {bench:14} sample {sample + 1}/{args.samples} "
                            f"{engine:4} {scores}",
                            file=sys.stderr,
                        )
    except RunFailure as exc:
        fail(str(exc), 1)

    for engine, path in binaries.items():
        final_hash = sha256_of(path)
        if final_hash != binary_info[engine]["sha256"]:
            fail(
                f"{engine} binary changed during measurement: "
                f"{binary_info[engine]['sha256']} -> {final_hash}",
                1,
            )
    measurement_wall_seconds = time.monotonic() - measurement_started

    for bench in benches:
        per_engine = per_bench[bench]["scores"]
        wall = per_bench[bench]["wall"]
        keys = sorted(set(per_engine["zjs"]) | set(per_engine["qjs"]))
        if set(per_engine["zjs"]) != set(per_engine["qjs"]):
            fail(
                f"{bench}: engines reported different score keys "
                f"(zjs {sorted(per_engine['zjs'])} vs qjs {sorted(per_engine['qjs'])})"
            )
        entry = {"scores": {}, "wallSecondsMedian": {}}
        for engine in ("zjs", "qjs"):
            if len(wall[engine]) != args.samples:
                fail(
                    f"{bench}: {engine} produced {len(wall[engine])}/{args.samples} runs",
                    1,
                )
            entry["wallSecondsMedian"][engine] = median(wall[engine])
        for key in keys:
            for engine in ("zjs", "qjs"):
                if len(per_engine[engine][key]) != args.samples:
                    fail(
                        f"{bench}: {engine} score {key} has "
                        f"{len(per_engine[engine][key])}/{args.samples} samples",
                        1,
                    )
            z = sorted(per_engine["zjs"][key])
            q = sorted(per_engine["qjs"][key])
            zm, qm = median(z), median(q)
            entry["scores"][key] = {
                "zjs": {"median": zm, "min": z[0], "max": z[-1], "samples": per_engine["zjs"][key]},
                "qjs": {"median": qm, "min": q[0], "max": q[-1], "samples": per_engine["qjs"][key]},
                "ratioZjsOverQjs": zm / qm,
                "isLatency": key in LATENCY_KEYS,
            }
        results[bench] = entry

    throughput = {
        bench: entry["scores"][key]["ratioZjsOverQjs"]
        for bench, entry in results.items()
        for key in entry["scores"]
        if not entry["scores"][key]["isLatency"]
    }
    latency = {
        f"{bench}:{key}": entry["scores"][key]["ratioZjsOverQjs"]
        for bench, entry in results.items()
        for key in entry["scores"]
        if entry["scores"][key]["isLatency"]
    }

    is_parallel = parallel_clusters is not None
    artifact = {
        "tool": "zjs-zoo-compare",
        "schemaVersion": 2,
        "medianMethod": "statistics.median; even sample counts average the middle pair",
        "scoreDirection": "higher-is-better; ratio = zjs/qjs, so below 1.0 means zjs is slower",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "measurementWallSeconds": measurement_wall_seconds,
        "samplesPerEnginePerBench": args.samples,
        "executionMode": "parallel-cluster-swap" if is_parallel else "serial-alternating",
        "samplingOrder": (
            "parallel cluster assignment swapped by sample parity; each engine occupies "
            "each cluster exactly half the samples"
            if is_parallel
            else "alternating by sample parity; each engine leads exactly half the samples"
        ),
        "firstPositionBalanced": True if not is_parallel else None,
        "clusterAssignmentBalanced": is_parallel,
        "cpu": None if is_parallel else args.cpu,
        "cpuClusters": (
            {"a": parallel_clusters[0], "b": parallel_clusters[1]}
            if parallel_clusters
            else None
        ),
        "parallelLanes": len(parallel_clusters[0]) if parallel_clusters else 1,
        "effectiveAffinity": sorted(affinity),
        "kernel": platform.release(),
        "cpuModel": cpu_model(),
        "binaries": binary_info,
        "zoo": zoo_info,
        "benchmarks": results,
        "summary": {
            "throughputGeomean": geomean(list(throughput.values())),
            "throughputRatios": throughput,
            "latencyRatios": latency,
            "zjsFaster": sorted(b for b, r in throughput.items() if r > 1.0),
            "zjsSlower": sorted(b for b, r in throughput.items() if r < 1.0),
        },
        "orderLog": order_log,
    }

    if args.output:
        target = Path(args.output)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(artifact, indent=1) + "\n")

    width = max(len(b) for b in results)
    print(f"\n{'benchmark':{width}}  {'qjs':>9} {'zjs':>9} {'zjs/qjs':>8}")
    for bench in sorted(throughput, key=lambda b: throughput[b]):
        key = next(k for k in results[bench]["scores"] if not results[bench]["scores"][k]["isLatency"])
        s = results[bench]["scores"][key]
        print(f"{bench:{width}}  {s['qjs']['median']:9} {s['zjs']['median']:9} {s['ratioZjsOverQjs']:8.3f}")
    for name, ratio in sorted(latency.items(), key=lambda kv: kv[1]):
        bench, key = name.split(":")
        s = results[bench]["scores"][key]
        print(f"{name:{width}}  {s['qjs']['median']:9} {s['zjs']['median']:9} {ratio:8.3f}  (latency)")
    print(f"\nthroughput geomean (zjs/qjs, higher is better): {artifact['summary']['throughputGeomean']:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
