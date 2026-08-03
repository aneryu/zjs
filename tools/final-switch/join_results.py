#!/usr/bin/env python3
"""FINAL SWITCH -- join the measurement artifacts into one arbitrated summary.

Reads the four zoo artifacts (`zoo-cand-b{1,2}.json`, `zoo-legacy-a{1,2}.json`)
and the four codeload micro artifacts written by `performance.sh`, and produces
the numbers the switch is actually gated on.

Two rules are enforced here rather than left to whoever writes the report:

  * **all four cross pairings are reported, always.** The zoo runner reports
    `zjs / qjs`, so the candidate-versus-legacy ratio is a ratio of ratios:
    `(cand/qjs) / (legacy/qjs)`. With two builds per side there are four such
    pairings, and the honest number is the whole set plus its spread -- not the
    best one. Dropping an unfavourable pairing is the specific failure this
    file exists to make impossible.
  * **a missing artifact is a failure, not a smaller sample.** If a runner
    refused (rc=2 from an unpinned invocation, the Gate A defect) the artifact
    is absent, and silently averaging the three that survived would report a
    confident number about a run that did not happen.

Gate in force (docs/qcp1_switch_decision.md 0.1.2), all three jointly:
  1. code-load, v2 / corrected-legacy >= 1.2359x
  2. full-zoo geomean not regressed versus the same corrected legacy
  3. no non-code-load benchmark negative beyond noise

Usage:
    tools/final-switch/join_results.py --perf DIR [--artifacts DIR]
                                       [--output FILE] [--codeload-gate 1.2359]
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

CAND_TAGS = ("cand-b1", "cand-b2")
LEGACY_TAGS = ("legacy-a1", "legacy-a2")
MICRO_TAGS = ("a1b1", "a1b2", "a2b1", "a2b2")

# The switch gate, restated against the corrected baseline (0.1.2).
CODELOAD_GATE = 1.2359
# "Negative beyond noise" for a single non-code-load benchmark. The measured
# build-layout lottery is around +/-2.5%, so a per-benchmark floor tighter than
# that would flag noise as regression.
PER_BENCH_FLOOR = 0.975


def fail(message: str, code: int = 2) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def load(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size == 0:
        fail(
            f"missing or empty artifact {path}\n"
            "  a run that did not happen must not be joined as a smaller sample;\n"
            "  re-run performance.sh (and check the runner was invoked under taskset)"
        )
    with path.open() as handle:
        return json.load(handle)


def geomean(values) -> float:
    values = list(values)
    if not values:
        fail("geomean over an empty set")
    if any(v <= 0 for v in values):
        fail("geomean over a non-positive ratio")
    return math.exp(sum(math.log(v) for v in values) / len(values))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--perf", required=True, help="directory holding zoo-*.json and micro-*.json")
    ap.add_argument("--artifacts", help="directory holding manifest.tsv")
    ap.add_argument("--output", help="write the joined summary here")
    ap.add_argument("--codeload-gate", type=float, default=CODELOAD_GATE)
    args = ap.parse_args()

    perf = Path(args.perf)
    zoo = {tag: load(perf / f"zoo-{tag}.json") for tag in CAND_TAGS + LEGACY_TAGS}
    micro = {tag: load(perf / f"micro-{tag}.json") for tag in MICRO_TAGS}

    # Every artifact must attest the pin it was measured under. This is the
    # second half of the affinity fix: performance.sh always passes taskset,
    # and the join refuses artifacts that nonetheless were not pinned.
    for tag, doc in list(zoo.items()) + list(micro.items()):
        effective = doc.get("effectiveAffinity")
        cpu = doc.get("cpu")
        if effective != [cpu]:
            fail(f"artifact {tag} was measured with effectiveAffinity={effective}, not [{cpu}]")
        samples = doc.get("samplesPerEnginePerBench", doc.get("pairedSamples"))
        if samples is None or samples % 2 != 0:
            fail(f"artifact {tag} has an odd/unknown sample count {samples}; ABBA is unbalanced")

    benches = sorted(zoo["cand-b1"]["summary"]["throughputRatios"])
    for tag, doc in zoo.items():
        got = sorted(doc["summary"]["throughputRatios"])
        if got != benches:
            fail(f"zoo artifact {tag} covers {got}, not the same set as cand-b1 ({benches})")
    if "code-load" not in benches:
        fail("code-load is not in the zoo benchmark set; the switch gate cannot be evaluated")

    # --- the four cross pairings, all of them ------------------------------
    pairings = {}
    for cand in CAND_TAGS:
        for legacy in LEGACY_TAGS:
            c = zoo[cand]["summary"]["throughputRatios"]
            l = zoo[legacy]["summary"]["throughputRatios"]
            per_bench = {b: c[b] / l[b] for b in benches}
            pairings[f"{cand}/{legacy}"] = {
                "perBench": per_bench,
                "geomean": geomean(per_bench.values()),
                "codeLoad": per_bench["code-load"],
            }

    geos = [p["geomean"] for p in pairings.values()]
    cls = [p["codeLoad"] for p in pairings.values()]

    # --- noise floors -------------------------------------------------------
    def floor(a: str, b: str) -> dict:
        ra = zoo[a]["summary"]["throughputRatios"]
        rb = zoo[b]["summary"]["throughputRatios"]
        ratios = {x: ra[x] / rb[x] for x in benches}
        return {
            "geomean": geomean(ratios.values()),
            "maxAbsDeviationPct": max(abs(v - 1.0) for v in ratios.values()) * 100.0,
            "identicalBinaries": zoo[a]["binaries"] == zoo[b]["binaries"],
        }

    noise = {
        "candidateRuntime(b1/b2)": floor("cand-b1", "cand-b2"),
        "legacyBuildLayout(a1/a2)": floor("legacy-a1", "legacy-a2"),
    }

    # --- gate evaluation ----------------------------------------------------
    worst_code_load = min(cls)
    worst_geomean = min(geos)
    per_bench_worst = {}
    for b in benches:
        if b == "code-load":
            continue
        per_bench_worst[b] = min(p["perBench"][b] for p in pairings.values())
    negatives = {b: v for b, v in per_bench_worst.items() if v < PER_BENCH_FLOOR}

    gates = {
        "codeLoad>=%.4f" % args.codeload_gate: {
            "required": args.codeload_gate,
            "measuredWorstPairing": worst_code_load,
            "measuredMean": statistics.fmean(cls),
            "met": worst_code_load >= args.codeload_gate,
        },
        "fullZooGeomeanNotRegressed": {
            "required": 1.0,
            "measuredWorstPairing": worst_geomean,
            "measuredMean": statistics.fmean(geos),
            "met": worst_geomean >= 1.0,
        },
        "noNonCodeLoadNegativeBeyondNoise": {
            "floor": PER_BENCH_FLOOR,
            "offenders": negatives,
            "met": not negatives,
        },
    }
    all_met = all(g["met"] for g in gates.values())

    micro_summary = {
        tag: {
            "instructionsRatioBOverA": micro[tag]["metrics"]["instructions"]["ratioMedian"],
            "cyclesRatioBOverA": micro[tag]["metrics"]["cycles"]["ratioMedian"],
            "wallRatioBOverA": micro[tag]["metrics"]["wallSeconds"]["ratioMedian"],
            "checksum": micro[tag].get("checksum"),
        }
        for tag in MICRO_TAGS
    }
    checksums = {v["checksum"] for v in micro_summary.values()}
    if len(checksums) != 1:
        fail(f"codeload micro checksums differ across pairings ({checksums}); the sides did different work")

    manifest = []
    if args.artifacts:
        mpath = Path(args.artifacts) / "manifest.tsv"
        if mpath.is_file():
            manifest = [line.rstrip("\n").split("\t") for line in mpath.read_text().splitlines()]

    summary = {
        "tool": "final-switch-join",
        "schemaVersion": 1,
        "tier": "FINAL SWITCH",
        "direction": "ratio = candidate / corrected-legacy on self-scoring benchmarks; ABOVE 1.0 is better",
        "benchmarks": benches,
        "pairings": pairings,
        "geomeanAcrossPairings": {
            "values": geos,
            "mean": statistics.fmean(geos),
            "min": min(geos),
            "max": max(geos),
        },
        "codeLoadAcrossPairings": {
            "values": cls,
            "mean": statistics.fmean(cls),
            "min": min(cls),
            "max": max(cls),
        },
        "noiseFloors": noise,
        "codeloadMicroAttribution": micro_summary,
        "gates": gates,
        "allGatesMet": all_met,
        "artifactManifest": manifest,
    }

    print("FINAL SWITCH -- joined summary (all four pairings, none dropped)")
    for name, p in sorted(pairings.items()):
        print(f"  {name:<22} geomean={p['geomean']:.4f}  code-load={p['codeLoad']:.4f}")
    print(f"  geomean   mean={statistics.fmean(geos):.4f} min={min(geos):.4f} max={max(geos):.4f}")
    print(f"  code-load mean={statistics.fmean(cls):.4f} min={min(cls):.4f} max={max(cls):.4f}")
    for name, f in noise.items():
        print(f"  noise {name:<26} geomean={f['geomean']:.4f} maxDev={f['maxAbsDeviationPct']:.2f}%")
    for name, g in gates.items():
        print(f"  GATE {name:<40} {'MET' if g['met'] else 'NOT MET'}")
    if negatives:
        for b, v in sorted(negatives.items(), key=lambda kv: kv[1]):
            print(f"    negative beyond noise: {b} = {v:.4f}")
    print(f"  ALL GATES MET: {all_met}")

    if args.output:
        Path(args.output).write_text(json.dumps(summary, indent=1) + "\n")
        print(f"  wrote {args.output}")

    return 0 if all_met else 1


if __name__ == "__main__":
    sys.exit(main())
