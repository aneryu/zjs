#!/usr/bin/env python3
"""Resume the formal 7-pad Zoo lineage for stack3 + typed-int.

The campaign was frozen mid-build with 17/28 cold binaries. Source identity
moved from a dirty e3e8190 worktree to the landed commit 42b6160f (same five
production/test files plus docs-only closeout/handoff). Frozen binaries are
reused by SHA; remaining builds use a clean e3e8190 base worktree and clean
42b6160f candidate. Measurements are serial-alternating on CPU 8.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path("/tmp/zjs-stacktyped-formal-20260813")
BASE = Path("/tmp/zjs-stacktyped-formal-base-e3e8190")
CAND = Path("/home/aneryu/zjs")
ZOO = Path("/home/aneryu/javascript-zoo")
RUNNER = CAND / "tools/perf/zoo/run_zoo_compare.py"
PADS = [0, 1, 3, 7, 15, 31, 63]
INSTANCES = ["a", "b"]
CPU = 8
SAMPLES_PER_COMBO = 2
EXPECTED_CONFIG = (
    "zjs-config-v2:compiler=v2,layout=short,repr=tagged,"
    "optimize=ReleaseFast,force_gc=off,ownership_audit=off"
)
MDE_LOG_PP = 0.278
EXPECTED_BASE_HEAD = "e3e8190a2ee50968602dc2f1d5c758379e5c37db"
EXPECTED_CAND_HEAD = "42b6160f0e7a20a38039e191e0ff499f542198e2"
EXPECTED_ZOO_HEAD = "a17d4e0aabe52719fab1074f4b566d16d08a563c"
EXPECTED_CAND_ENGINE_FILES = [
    "src/core/typed_array.zig",
    "src/exec/tailcall_dispatch.zig",
    "src/exec/tailcall_dispatch_colds.zig",
    "src/exec/vm_property_field.zig",
    "src/tests/exec.zig",
]


def run_text(cmd: list[str], cwd: Path | None = None) -> str:
    return subprocess.check_output(cmd, cwd=cwd, text=True).strip()


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def git_head(wt: Path) -> str:
    return run_text(["git", "rev-parse", "HEAD"], wt)


def git_status(wt: Path) -> list[str]:
    raw = subprocess.check_output(
        ["git", "status", "--porcelain=v1", "-z"], cwd=wt
    )
    return [entry.decode() for entry in raw.split(b"\0") if entry]


def git_diff_sha(wt: Path) -> str:
    raw = subprocess.check_output(["git", "diff", "--binary"], cwd=wt)
    return hashlib.sha256(raw).hexdigest()


def config(path: Path) -> str:
    return run_text([str(path), "--print-config-signature"])


def atomic_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def engine_file_diff_sha() -> str:
    raw = subprocess.check_output(
        ["git", "diff", "--binary", EXPECTED_BASE_HEAD, EXPECTED_CAND_HEAD, "--",
         *EXPECTED_CAND_ENGINE_FILES],
        cwd=CAND,
    )
    return hashlib.sha256(raw).hexdigest()


def check_sources() -> dict:
    if git_head(BASE) != EXPECTED_BASE_HEAD:
        raise RuntimeError(f"baseline HEAD drift: {git_head(BASE)}")
    if git_head(CAND) != EXPECTED_CAND_HEAD:
        raise RuntimeError(f"candidate HEAD drift: {git_head(CAND)}")
    if git_head(ZOO) != EXPECTED_ZOO_HEAD:
        raise RuntimeError(f"Zoo HEAD drift: {git_head(ZOO)}")
    if git_status(BASE):
        raise RuntimeError(f"baseline worktree is dirty: {git_status(BASE)}")
    if git_status(CAND):
        raise RuntimeError(f"candidate worktree is dirty: {git_status(CAND)}")
    if git_status(ZOO):
        raise RuntimeError(f"Zoo worktree is dirty: {git_status(ZOO)}")
    return {
        "base": {"path": str(BASE), "head": git_head(BASE), "status": []},
        "candidate": {
            "path": str(CAND),
            "head": git_head(CAND),
            "status": [],
            "engineDiffSha256": engine_file_diff_sha(),
            "landedCommit": EXPECTED_CAND_HEAD,
        },
        "zoo": {"path": str(ZOO), "head": git_head(ZOO), "status": []},
    }


def load_or_init(source: dict) -> dict:
    state_path = ROOT / "state.json"
    if not state_path.exists():
        raise RuntimeError("refusing to start a new campaign; resume only")
    state = json.loads(state_path.read_text())
    if state["preRegisteredDesign"]["pads"] != PADS:
        raise RuntimeError("existing campaign pad design differs")
    if state["preRegisteredDesign"]["cpu"] != CPU:
        raise RuntimeError("existing campaign CPU differs")
    if state["configuration"] != EXPECTED_CONFIG:
        raise RuntimeError("existing campaign configuration differs")
    freeze = state["sources"]
    if freeze["base"]["head"] != EXPECTED_BASE_HEAD:
        raise RuntimeError("frozen baseline HEAD is not e3e8190")
    if freeze["zoo"]["head"] != EXPECTED_ZOO_HEAD:
        raise RuntimeError("frozen Zoo HEAD drifted")
    if freeze["candidate"]["head"] != EXPECTED_BASE_HEAD:
        raise RuntimeError("frozen candidate was not based on e3e8190")
    state["sourcesAtFreeze"] = freeze
    state["sourcesAtResume"] = source
    state["resumeUnix"] = time.time()
    state["resumeNote"] = (
        "Frozen binaries reused by SHA. Remaining builds use clean e3e8190 "
        "base and landed 42b6160f candidate. Engine-file diff SHA is "
        f"{source['candidate']['engineDiffSha256']}."
    )
    atomic_json(state_path, state)
    return state


def build_key(pad: int, side: str, inst: str) -> str:
    return f"pad{pad}/{side}-{inst}"


def build_one(state: dict, pad: int, side: str, inst: str) -> None:
    key = build_key(pad, side, inst)
    out = ROOT / "binaries" / f"pad{pad}" / f"{side}-{inst}" / "zjs"
    previous = state["builds"].get(key)
    if previous and out.exists():
        if sha256(out) == previous["sha256"] and config(out) == EXPECTED_CONFIG:
            print(f"REUSE build {key} {previous['sha256'][:12]}", flush=True)
            return
        raise RuntimeError(f"frozen build drift for {key}")

    wt = BASE if side == "base" else CAND
    temp_root = ROOT / "cold-caches"
    temp_root.mkdir(parents=True, exist_ok=True)
    local_cache = Path(tempfile.mkdtemp(prefix=f"{key.replace('/', '-')}-local-", dir=temp_root))
    global_cache = Path(tempfile.mkdtemp(prefix=f"{key.replace('/', '-')}-global-", dir=temp_root))
    prefix = Path(tempfile.mkdtemp(prefix=f"{key.replace('/', '-')}-prefix-", dir=temp_root))
    log = ROOT / "logs" / f"build-pad{pad}-{side}-{inst}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "zig", "build", "zjs", "-Doptimize=ReleaseFast",
        f"-Dzjs_dossier_layout_pad={pad}", "--seed", "0", "--summary", "all",
        "--cache-dir", str(local_cache), "--global-cache-dir", str(global_cache),
        "--prefix", str(prefix),
    ]
    print(f"BUILD {key} cold local+global", flush=True)
    started = time.time()
    with log.open("w") as f:
        proc = subprocess.run(cmd, cwd=wt, stdout=f, stderr=subprocess.STDOUT, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"build failed for {key}; see {log}")
    built = prefix / "bin" / "zjs"
    if not built.exists():
        raise RuntimeError(f"missing build output for {key}")
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(built, out)
    out.chmod(0o755)
    digest = sha256(out)
    sig = config(out)
    if sig != EXPECTED_CONFIG:
        raise RuntimeError(f"config mismatch for {key}: {sig}")
    state["builds"][key] = {
        "pad": pad,
        "side": side,
        "instance": inst,
        "path": str(out),
        "sha256": digest,
        "configSignature": sig,
        "coldLocalCache": True,
        "coldGlobalCache": True,
        "seed": 0,
        "durationSeconds": time.time() - started,
        "log": str(log),
        "sourceHead": EXPECTED_BASE_HEAD if side == "base" else EXPECTED_CAND_HEAD,
        "resumedAfterLanding": True,
    }
    atomic_json(ROOT / "state.json", state)
    shutil.rmtree(local_cache)
    shutil.rmtree(global_cache)
    shutil.rmtree(prefix)
    print(f"DONE  {key} {digest[:12]} {state['builds'][key]['durationSeconds']:.1f}s", flush=True)


def build_all(state: dict) -> None:
    for pad_index, pad in enumerate(PADS):
        if pad_index % 2 == 0:
            order = [("base", "a"), ("candidate", "a"), ("candidate", "b"), ("base", "b")]
        else:
            order = [("candidate", "a"), ("base", "a"), ("base", "b"), ("candidate", "b")]
        for side, inst in order:
            build_one(state, pad, side, inst)


def artifact_valid(path: Path, base_sha: str, cand_sha: str) -> bool:
    if not path.exists():
        return False
    payload = json.loads(path.read_text())
    return (
        payload.get("schemaVersion") == 2
        and payload.get("executionMode") == "serial-alternating"
        and payload.get("effectiveAffinity") == [CPU]
        and payload.get("samplesPerEnginePerBench") == SAMPLES_PER_COMBO
        and payload.get("firstPositionBalanced") is True
        and payload.get("binaries", {}).get("qjs", {}).get("sha256") == base_sha
        and payload.get("binaries", {}).get("zjs", {}).get("sha256") == cand_sha
        and len(payload.get("summary", {}).get("throughputRatios", {})) == 15
    )


def combo_order(pad_index: int) -> list[tuple[str, str]]:
    order = [("a", "a"), ("b", "a"), ("b", "b"), ("a", "b")]
    return order if pad_index % 2 == 0 else list(reversed(order))


def measure_all(state: dict) -> None:
    for pad_index, pad in enumerate(PADS):
        for base_inst, cand_inst in combo_order(pad_index):
            tag = f"pad{pad}/base-{base_inst}_cand-{cand_inst}"
            b = state["builds"][build_key(pad, "base", base_inst)]
            c = state["builds"][build_key(pad, "candidate", cand_inst)]
            out = ROOT / "measurements" / f"pad{pad}-base{base_inst}-cand{cand_inst}-ab2.json"
            if artifact_valid(out, b["sha256"], c["sha256"]):
                print(f"REUSE measure {tag}", flush=True)
            else:
                log = ROOT / "logs" / f"measure-pad{pad}-base{base_inst}-cand{cand_inst}.log"
                cmd = [
                    "taskset", "-c", str(CPU),
                    sys.executable, str(RUNNER), "--zjs", c["path"], "--qjs", b["path"],
                    "--zoo", str(ZOO), "--samples", str(SAMPLES_PER_COMBO),
                    "--cpu", str(CPU), "--output", str(out),
                ]
                print(f"MEASURE {tag} ABBA{SAMPLES_PER_COMBO}", flush=True)
                started = time.time()
                with log.open("w") as f:
                    proc = subprocess.run(cmd, cwd=CAND, stdout=f, stderr=subprocess.STDOUT, text=True)
                if proc.returncode != 0:
                    raise RuntimeError(f"measurement failed for {tag}; see {log}")
                if not artifact_valid(out, b["sha256"], c["sha256"]):
                    raise RuntimeError(f"invalid measurement artifact for {tag}")
                print(f"DONE    {tag} {time.time() - started:.1f}s", flush=True)
            payload = json.loads(out.read_text())
            state["measurements"][tag] = {
                "pad": pad,
                "baseInstance": base_inst,
                "candidateInstance": cand_inst,
                "path": str(out),
                "sha256": sha256(out),
                "throughputGeomean": payload["summary"]["throughputGeomean"],
                "logEffectPercentagePoints": 100.0 * math.log(payload["summary"]["throughputGeomean"]),
                "measurementWallSeconds": payload.get("measurementWallSeconds"),
            }
            atomic_json(ROOT / "state.json", state)


def throughput_scores(payload: dict) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for bench, body in payload["benchmarks"].items():
        matches = [entry for entry in body["scores"].values() if not entry["isLatency"]]
        if len(matches) != 1:
            raise RuntimeError(f"{bench}: expected exactly one throughput score")
        out[bench] = matches[0]
    if len(out) != 15:
        raise RuntimeError(f"expected 15 throughput benchmarks, got {len(out)}")
    return out


def aggregate(state: dict) -> None:
    lineages: dict[str, dict] = {}
    all_residuals: list[float] = []
    for pad_index, pad in enumerate(PADS):
        cand_samples: dict[str, list[float]] = {}
        base_samples: dict[str, list[float]] = {}
        paired_global_effects: list[float] = []
        combo_entries = []
        for base_inst, cand_inst in combo_order(pad_index):
            tag = f"pad{pad}/base-{base_inst}_cand-{cand_inst}"
            meta = state["measurements"][tag]
            payload = json.loads(Path(meta["path"]).read_text())
            scores = throughput_scores(payload)
            for bench, entry in scores.items():
                cand_samples.setdefault(bench, []).extend(float(x) for x in entry["zjs"]["samples"])
                base_samples.setdefault(bench, []).extend(float(x) for x in entry["qjs"]["samples"])
            for sample_index in range(SAMPLES_PER_COMBO):
                logs = [
                    math.log(float(entry["zjs"]["samples"][sample_index]) /
                             float(entry["qjs"]["samples"][sample_index]))
                    for entry in scores.values()
                ]
                paired_global_effects.append(100.0 * statistics.fmean(logs))
            combo_entries.append(meta)
        if any(len(v) != 8 for v in cand_samples.values()) or any(len(v) != 8 for v in base_samples.values()):
            raise RuntimeError(f"pad {pad}: aggregate sample count is not 8 per side")
        ratios = {
            bench: statistics.median(cand_samples[bench]) / statistics.median(base_samples[bench])
            for bench in sorted(cand_samples)
        }
        ratio_of_medians_geo = math.exp(statistics.fmean(math.log(x) for x in ratios.values()))
        effect = statistics.median(paired_global_effects)
        residuals = [x - effect for x in paired_global_effects]
        all_residuals.extend(residuals)
        lineages[str(pad)] = {
            "pad": pad,
            "samplesPerSide": 8,
            "fullColdBuildCombinations": True,
            "pairedGlobalLogEffects": paired_global_effects,
            "effectLogPercentagePoints": effect,
            "ratioFromPairedMedian": math.exp(effect / 100.0),
            "ratioOfMediansGeomean": ratio_of_medians_geo,
            "ratioOfMediansLogPercentagePoints": 100.0 * math.log(ratio_of_medians_geo),
            "throughputRatiosFromCombinedMedians": ratios,
            "combinationResults": combo_entries,
            "combinationEffectRangeLogPercentagePoints": [
                min(x["logEffectPercentagePoints"] for x in combo_entries),
                max(x["logEffectPercentagePoints"] for x in combo_entries),
            ],
        }
        print(
            f"LINEAGE pad={pad:<2} paired-median={effect:+.4f} log-pp "
            f"ratio-medians={100.0 * math.log(ratio_of_medians_geo):+.4f} log-pp",
            flush=True,
        )

    effects = [lineages[str(p)]["effectLogPercentagePoints"] for p in PADS]
    median_effect = statistics.median(effects)
    worst_effect = min(effects)
    lineage_mad = statistics.median(abs(x - median_effect) for x in effects)
    observed_sigma = 1.4826 * lineage_mad
    within_sigma = 1.4826 * statistics.median(abs(x) for x in all_residuals)
    tau = math.sqrt(max(0.0, observed_sigma**2 - within_sigma**2 / 8.0))
    if median_effect > MDE_LOG_PP and worst_effect >= 0.0:
        verdict = "PASS"
    elif median_effect < -MDE_LOG_PP:
        verdict = "REJECT"
    else:
        verdict = "INCONCLUSIVE"
    source_after = check_sources()
    if source_after != state["sourcesAtResume"]:
        raise RuntimeError("source identity changed during campaign")
    for entry in state["builds"].values():
        path = Path(entry["path"])
        if sha256(path) != entry["sha256"] or config(path) != EXPECTED_CONFIG:
            raise RuntimeError(f"post-campaign binary drift: {path}")
    state["lineages"] = lineages
    state["decision"] = {
        "verdict": verdict,
        "medianEffectLogPercentagePoints": median_effect,
        "worstPadEffectLogPercentagePoints": worst_effect,
        "mdeLogPercentagePoints": MDE_LOG_PP,
        "signalOverMde": abs(median_effect) / MDE_LOG_PP,
        "lineageMadLogPercentagePoints": lineage_mad,
        "observedRobustSigmaLogPercentagePoints": observed_sigma,
        "withinLineageRobustSigmaLogPercentagePoints": within_sigma,
        "tauLogPercentagePoints": tau,
        "ordinaryMedianFactor": math.exp(median_effect / 100.0),
        "passesEffectGate": median_effect > MDE_LOG_PP,
        "passesWorstPadGate": worst_effect >= 0.0,
    }
    state["completedUnix"] = time.time()
    atomic_json(ROOT / "formal-lineage.json", state)
    atomic_json(ROOT / "state.json", state)
    print(json.dumps(state["decision"], indent=2, sort_keys=True), flush=True)


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    source = check_sources()
    state = load_or_init(source)
    build_all(state)
    measure_all(state)
    aggregate(state)


if __name__ == "__main__":
    main()
