#!/usr/bin/env python3
"""Fixed zoo (Octane) macro comparison between zjs and pinned QuickJS.

The zoo benchmarks are self-scoring: each `bench/<name>.js` prints one or more
`Name: <integer>` lines where **higher is better**. This runner exists so that
comparison is reproducible rather than re-improvised each time, and so that it
carries the same discipline as the whole-process microbench contract:

  * even sample count with a balanced first position (contract #3) -- an odd
    count is refused rather than rounded, since silently changing the sampling
    design behind the caller's back is the failure that contract exists to stop;
  * effective CPU affinity pinned to a single core, verified rather than
    requested (contract: an allowed-list containing the CPU is not pinning);
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
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
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


def run_one(binary: Path, script: Path, cpu: int, timeout: int) -> tuple[dict[str, int], float]:
    started = time.monotonic()
    proc = subprocess.run(
        ["taskset", "-c", str(cpu), str(binary), str(script)],
        capture_output=True, text=True, timeout=timeout,
    )
    elapsed = time.monotonic() - started
    scores = parse_scores(proc.stdout + proc.stderr)
    if not scores:
        fail(
            f"{binary.name} produced no parseable score for {script.name}; "
            f"exit={proc.returncode} stderr={proc.stderr.strip()[:200]!r}"
        )
    return scores, elapsed


def geomean(values: list[float]) -> float:
    return math.exp(sum(math.log(v) for v in values) / len(values))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zjs", required=True)
    ap.add_argument("--qjs", required=True)
    ap.add_argument("--zoo", default="/home/aneryu/javascript-zoo", help="javascript-zoo checkout")
    ap.add_argument("--samples", type=int, default=4, help="samples per engine per benchmark, must be even (default: 4)")
    ap.add_argument("--cpu", type=int, default=19)
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

    # Pinning must be effective, not merely requested. An allowed set that
    # merely contains the CPU is not pinning.
    affinity = effective_affinity()
    if affinity != {args.cpu}:
        fail(
            f"this process's effective affinity is {sorted(affinity)}, not exactly "
            f"[{args.cpu}]; re-run under `taskset -c {args.cpu}` and the exclusive "
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

    results: dict[str, dict] = {}
    order_log: list[dict] = []

    for bench in benches:
        script = bench_dir / f"{bench}.js"
        per_engine: dict[str, dict[str, list[int]]] = {"zjs": {}, "qjs": {}}
        wall: dict[str, list[float]] = {"zjs": [], "qjs": []}
        for sample in range(args.samples):
            # Alternate the leading engine so each occupies each position equally.
            order = ["qjs", "zjs"] if sample % 2 == 0 else ["zjs", "qjs"]
            order_log.append({"bench": bench, "sample": sample, "order": "->".join(order)})
            for engine in order:
                binary = zjs if engine == "zjs" else qjs
                scores, elapsed = run_one(binary, script, args.cpu, args.timeout)
                wall[engine].append(elapsed)
                for key, value in scores.items():
                    per_engine[engine].setdefault(key, []).append(value)
                print(f"  {bench:14} sample {sample + 1}/{args.samples} {engine:4} {scores}", file=sys.stderr)

        keys = sorted(set(per_engine["zjs"]) | set(per_engine["qjs"]))
        if set(per_engine["zjs"]) != set(per_engine["qjs"]):
            fail(
                f"{bench}: engines reported different score keys "
                f"(zjs {sorted(per_engine['zjs'])} vs qjs {sorted(per_engine['qjs'])})"
            )
        entry = {"scores": {}, "wallSecondsMedian": {}}
        for engine in ("zjs", "qjs"):
            entry["wallSecondsMedian"][engine] = sorted(wall[engine])[len(wall[engine]) // 2]
        for key in keys:
            z = sorted(per_engine["zjs"][key])
            q = sorted(per_engine["qjs"][key])
            zm, qm = z[len(z) // 2], q[len(q) // 2]
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

    artifact = {
        "tool": "zjs-zoo-compare",
        "schemaVersion": 1,
        "scoreDirection": "higher-is-better; ratio = zjs/qjs, so below 1.0 means zjs is slower",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "samplesPerEnginePerBench": args.samples,
        "samplingOrder": "alternating by sample parity; each engine leads exactly half the samples",
        "firstPositionBalanced": True,
        "cpu": args.cpu,
        "effectiveAffinity": sorted(affinity),
        "kernel": platform.release(),
        "cpuModel": cpu_model(),
        "binaries": {
            "zjs": {"path": str(zjs), "sha256": sha256_of(zjs), "repo": git_describe(Path(__file__).resolve().parents[3])},
            "qjs": {"path": str(qjs), "sha256": sha256_of(qjs), "repo": git_describe(qjs.parent)},
        },
        "zoo": git_describe(zoo),
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
