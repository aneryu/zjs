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
  * **RULE A: the runner's affinity self-report is corroborated, not trusted.**
    Every runner writes its own `effectiveAffinity`. That is one source
    attesting itself, which is not verification. `performance.sh` writes an
    independent ledger (`--affinity-attestation`) from inside each pinned
    process tree, read out of `/proc/self/status` rather than out of python's
    `os.sched_getaffinity`, and this file requires the ledger to exist, to show
    the requested CPU, and to have one line per pinned invocation. A runner
    claiming a pin the orchestrator did not observe is refused.

Gate in force (docs/qcp1_switch_decision.md 0.1.2), all three jointly:
  1. code-load, v2 / corrected-legacy >= 1.2359x
  2. full-zoo geomean not regressed versus the same corrected legacy
  3. no non-code-load benchmark negative beyond noise

Usage:
    tools/final-switch/join_results.py --perf DIR [--artifacts DIR]
                                       [--affinity-attestation FILE]
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


def load_affinity_attestation(path: Path, expected_runs: int) -> list[tuple[str, str, str]]:
    """RULE A, second half: the ORCHESTRATOR's own affinity ledger.

    Written by fs_pinned() from inside each pinned process tree via
    /proc/self/status -- a different process and a different mechanism from the
    runner's os.sched_getaffinity, so agreement between the two is corroboration
    rather than a self-report repeated twice.
    """
    if not path.is_file():
        fail(
            f"missing orchestrator affinity attestation {path}\n"
            "  the runners' own effectiveAffinity fields are self-reports and are not\n"
            "  accepted on their own. Run the measurements through performance.sh, which\n"
            "  sets FS_AFFINITY_ATTEST and invokes every runner via fs_pinned()."
        )
    rows: list[tuple[str, str, str]] = []
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            fail(f"{path}:{lineno}: malformed attestation line: {line!r}")
        rows.append((parts[0], parts[1], "\t".join(parts[2:])))
    if not rows:
        fail(f"{path} is empty: no pinned invocation attested its own affinity")
    for requested, observed, cmd in rows:
        if requested != observed:
            fail(
                f"orchestrator observed affinity [{observed}] while requesting [{requested}] "
                f"for: {cmd}"
            )
    if len(rows) != expected_runs:
        fail(
            f"{path} has {len(rows)} attested invocations, expected {expected_runs}\n"
            "  every artifact must correspond to a pinned invocation the orchestrator saw;\n"
            "  a runner self-report with no matching attestation is refused"
        )
    return rows


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
    ap.add_argument(
        "--affinity-attestation",
        help="orchestrator-side affinity ledger written by fs_pinned "
        "(default: <perf>/affinity-attestation.tsv)",
    )
    ap.add_argument("--output", help="write the joined summary here")
    ap.add_argument("--codeload-gate", type=float, default=CODELOAD_GATE)
    args = ap.parse_args()

    perf = Path(args.perf)
    zoo = {tag: load(perf / f"zoo-{tag}.json") for tag in CAND_TAGS + LEGACY_TAGS}
    micro = {tag: load(perf / f"micro-{tag}.json") for tag in MICRO_TAGS}

    # RULE A. Two independent sources must agree, and both are required.
    #
    #   (1) the ORCHESTRATOR's ledger, read from /proc inside each pinned
    #       process before the runner was exec'd -- this is the source that
    #       does not depend on the runner being honest, or even correct;
    #   (2) each runner's own effectiveAffinity self-report.
    attest_path = Path(args.affinity_attestation or (perf / "affinity-attestation.tsv"))
    attestation = load_affinity_attestation(attest_path, len(zoo) + len(micro))
    attested_cpus = set()
    for requested, _observed, _cmd in attestation:
        if not requested.isdigit():
            fail(
                f"{attest_path}: attested affinity {requested!r} is not a single CPU; "
                "a measurement must be pinned to exactly one core"
            )
        attested_cpus.add(int(requested))

    for tag, doc in list(zoo.items()) + list(micro.items()):
        effective = doc.get("effectiveAffinity")
        cpu = doc.get("cpu")
        if effective != [cpu]:
            fail(f"artifact {tag} was measured with effectiveAffinity={effective}, not [{cpu}]")
        if cpu not in attested_cpus:
            fail(
                f"artifact {tag} claims cpu {cpu}, but the orchestrator attested only "
                f"{sorted(attested_cpus)}; the runner's self-report is uncorroborated"
            )
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
        "affinityAttestation": {
            "source": str(attest_path),
            "mechanism": "/proc/self/status Cpus_allowed_list, read inside each pinned "
            "process tree before exec of the runner",
            "invocations": [
                {"requested": r, "observed": o, "command": c} for r, o, c in attestation
            ],
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
