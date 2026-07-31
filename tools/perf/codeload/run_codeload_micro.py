#!/usr/bin/env python3
"""Paired A/B runner for the CodeLoad compile-throughput micro.

Measures two binaries (typically zjs-before vs zjs-after a cut; also usable
zjs-vs-qjs for normalization) on one of two fixed-workload modes:

  compile  fixed payload, throw-gated global eval; isolates parser/lowering
           throughput (cuts A, C1-C4)
  atom     fixed-width salted identifier renames, same runtime; adds intern
           miss + free-slot churn on top (cut B)

Design contracts (same lineage as run_zoo_compare.py and
reports/perf/qjs-align/measurement-contracts.md):

  * paired ABBA order: pair i runs [a,b] when i is even, [b,a] when i is odd,
    so each binary leads exactly half the pairs; odd --samples is refused,
    not rounded;
  * effective affinity must be exactly {--cpu}: attested via
    os.sched_getaffinity, not trusted from the caller;
  * instructions AND cycles are both collected (perf stat, dual-PMU
    <not counted> rows filtered); instructions are the primary metric for
    work-removal cuts (layout-immune), cycles and the macro score arbitrate;
  * the harness CHECKSUM line must be identical across every run of both
    binaries — a mismatch means the two sides did different work and the
    comparison is void;
  * per-pair ratios b/a are reported with median, geomean, and MAD; a single
    build per side cannot support a merge verdict — the formal protocol is
    two cold-cache builds per side (see README.md).

Usage:
  flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
    python3 tools/perf/codeload/run_codeload_micro.py \
      --a <binary-before> --b <binary-after> --mode compile \
      --samples 8 --cpu 19 --output <artifact.json>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
PAYLOAD = TOOL_DIR / "payload_octane_codeload.js"
MODES = {"compile": TOOL_DIR / "mode_compile.js", "atom": TOOL_DIR / "mode_atom.js"}


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


def cpu_model() -> str | None:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name") or line.startswith("Model"):
                return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return None


def parse_perf_csv(text: str) -> dict[str, int]:
    """Sum counted rows per event; dual-PMU <not counted> rows are dropped."""
    counters: dict[str, int] = {}
    for line in text.splitlines():
        parts = line.split(",")
        if len(parts) < 3:
            continue
        value, _, event = parts[0].strip(), parts[1], parts[2].strip()
        if not value or value in ("<not counted>", "<not supported>"):
            continue
        for want in ("instructions", "cycles"):
            if want in event:
                try:
                    counters[want] = counters.get(want, 0) + int(value)
                except ValueError:
                    pass
    return counters


def run_once(binary: Path, script: Path, cpu: int, timeout: int) -> dict:
    with tempfile.NamedTemporaryFile(prefix="codeload-perf-", suffix=".csv") as stat:
        started = time.monotonic()
        proc = subprocess.run(
            [
                "taskset", "-c", str(cpu), "perf", "stat", "-x", ",",
                "-e", "instructions,cycles", "-o", stat.name, "--",
                str(binary), str(script),
            ],
            capture_output=True, text=True, timeout=timeout,
        )
        elapsed = time.monotonic() - started
        counters = parse_perf_csv(Path(stat.name).read_text())
    if proc.returncode != 0:
        fail(f"{binary.name} exited {proc.returncode}: {proc.stderr.strip()[:300]!r}")
    checksum = None
    iters = None
    for line in proc.stdout.splitlines():
        if line.startswith("CHECKSUM: "):
            checksum = line.split(": ", 1)[1]
        elif line.startswith("ITERS: "):
            iters = int(line.split(": ", 1)[1])
    if checksum is None or iters is None:
        fail(f"{binary.name} printed no CHECKSUM/ITERS; stdout={proc.stdout[:200]!r}")
    if "instructions" not in counters or "cycles" not in counters:
        fail(f"perf stat produced no counted instructions/cycles rows for {binary.name}")
    return {
        "instructions": counters["instructions"],
        "cycles": counters["cycles"],
        "wallSeconds": elapsed,
        "checksum": checksum,
        "iters": iters,
    }


def geomean(values: list[float]) -> float:
    return math.exp(sum(math.log(v) for v in values) / len(values))


def mad(values: list[float]) -> float:
    med = statistics.median(values)
    return statistics.median(abs(v - med) for v in values)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--a", required=True, help="binary A (baseline)")
    ap.add_argument("--b", required=True, help="binary B (candidate)")
    ap.add_argument("--mode", required=True, choices=sorted(MODES))
    ap.add_argument("--samples", type=int, default=8, help="paired samples, must be even (default: 8)")
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--output")
    args = ap.parse_args()

    if args.samples % 2 != 0:
        fail(
            f"--samples must be even; {args.samples} is odd and cannot balance the "
            "paired ABBA order (measurement contract #3)"
        )
    if args.samples < 2:
        fail("--samples must be at least 2")

    affinity = set(os.sched_getaffinity(0))
    if affinity != {args.cpu}:
        fail(
            f"this process's effective affinity is {sorted(affinity)}, not exactly "
            f"[{args.cpu}]; re-run under `taskset -c {args.cpu}` and the exclusive "
            "host lock (affinity is attested, not requested)"
        )

    a, b = Path(args.a).resolve(), Path(args.b).resolve()
    for p in (a, b):
        if not p.is_file():
            fail(f"binary not found: {p}")
    if not PAYLOAD.is_file():
        fail(f"payload not found: {PAYLOAD}")

    runs: dict[str, list[dict]] = {"a": [], "b": []}
    order_log: list[str] = []
    with tempfile.TemporaryDirectory(prefix="codeload-micro-") as tmp:
        script = Path(tmp) / f"codeload_{args.mode}.js"
        script.write_text(PAYLOAD.read_text() + MODES[args.mode].read_text())
        for pair in range(args.samples):
            order = ["a", "b"] if pair % 2 == 0 else ["b", "a"]
            order_log.append("->".join(order))
            for side in order:
                binary = a if side == "a" else b
                result = run_once(binary, script, args.cpu, args.timeout)
                runs[side].append(result)
                print(
                    f"  pair {pair + 1}/{args.samples} {side} insn={result['instructions']:,} "
                    f"cyc={result['cycles']:,} wall={result['wallSeconds']:.3f}s",
                    file=sys.stderr,
                )

    checksums = {r["checksum"] for side in runs.values() for r in side}
    if len(checksums) != 1:
        fail(f"CHECKSUM mismatch across runs: {sorted(checksums)} — the two sides did different work")

    metrics = {}
    for counter in ("instructions", "cycles", "wallSeconds"):
        ratios = [
            runs["b"][i][counter] / runs["a"][i][counter] for i in range(args.samples)
        ]
        metrics[counter] = {
            "aMedian": statistics.median(r[counter] for r in runs["a"]),
            "bMedian": statistics.median(r[counter] for r in runs["b"]),
            "pairRatiosBOverA": ratios,
            "ratioMedian": statistics.median(ratios),
            "ratioGeomean": geomean(ratios),
            "ratioMAD": mad(ratios),
        }
    insn_dir = metrics["instructions"]["ratioMedian"]
    cyc_dir = metrics["cycles"]["ratioMedian"]
    direction = (
        "b-better" if insn_dir < 1 and cyc_dir < 1
        else "b-worse" if insn_dir > 1 and cyc_dir > 1
        else "mixed"
    )

    artifact = {
        "tool": "zjs-codeload-micro",
        "schemaVersion": 1,
        "mode": args.mode,
        "direction": "ratio = b/a; below 1.0 means b does less work / is faster",
        "sameDirectionVerdict": direction,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "pairedSamples": args.samples,
        "order": "ABBA by pair parity",
        "cpu": args.cpu,
        "effectiveAffinity": sorted(affinity),
        "kernel": platform.release(),
        "cpuModel": cpu_model(),
        "checksum": checksums.pop(),
        "payloadSha256": sha256_of(PAYLOAD),
        "binaries": {
            "a": {"path": str(a), "sha256": sha256_of(a)},
            "b": {"path": str(b), "sha256": sha256_of(b)},
            "repo": git_describe(TOOL_DIR.parents[2]),
        },
        "runs": runs,
        "metrics": metrics,
    }

    if args.output:
        target = Path(args.output)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(artifact, indent=1) + "\n")

    print(f"\nmode={args.mode} paired samples={args.samples} (ABBA), ratio = b/a")
    for counter in ("instructions", "cycles", "wallSeconds"):
        m = metrics[counter]
        print(
            f"  {counter:12} median {m['ratioMedian']:.5f}  geomean {m['ratioGeomean']:.5f}  "
            f"MAD {m['ratioMAD']:.5f}  (a {m['aMedian']:,.0f} -> b {m['bMedian']:,.0f})"
        )
    print(f"  direction: {direction}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
