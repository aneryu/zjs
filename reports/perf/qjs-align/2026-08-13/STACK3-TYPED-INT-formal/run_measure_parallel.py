#!/usr/bin/env python3
"""Finish remaining formal combos as independent serial ABBA2 jobs on distinct X925 cores.

Each job stays serial-alternating on one core. Independent pad/combo pairs do not
share a CPU. This keeps the D10 execution mode and only parallelizes across
already-independent measurements.
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import run_formal_lineage as fl


BIG_CORES = [6, 7, 8, 9, 15, 16, 17, 19]
ALLOWED_AFFINITY = {5, 6, 7, 8, 9, 15, 16, 17, 18, 19}


def artifact_valid_any_core(path: Path, base_sha: str, cand_sha: str) -> bool:
    if not path.exists():
        return False
    payload = json.loads(path.read_text())
    affinity = payload.get("effectiveAffinity")
    return (
        payload.get("schemaVersion") == 2
        and payload.get("executionMode") == "serial-alternating"
        and isinstance(affinity, list)
        and len(affinity) == 1
        and affinity[0] in ALLOWED_AFFINITY
        and payload.get("samplesPerEnginePerBench") == fl.SAMPLES_PER_COMBO
        and payload.get("firstPositionBalanced") is True
        and payload.get("binaries", {}).get("qjs", {}).get("sha256") == base_sha
        and payload.get("binaries", {}).get("zjs", {}).get("sha256") == cand_sha
        and len(payload.get("summary", {}).get("throughputRatios", {})) == 15
    )


def jobs(state: dict) -> list[dict]:
    out = []
    for pad_index, pad in enumerate(fl.PADS):
        for base_inst, cand_inst in fl.combo_order(pad_index):
            tag = f"pad{pad}/base-{base_inst}_cand-{cand_inst}"
            b = state["builds"][fl.build_key(pad, "base", base_inst)]
            c = state["builds"][fl.build_key(pad, "candidate", cand_inst)]
            path = fl.ROOT / "measurements" / f"pad{pad}-base{base_inst}-cand{cand_inst}-ab2.json"
            item = {
                "tag": tag,
                "pad": pad,
                "baseInstance": base_inst,
                "candidateInstance": cand_inst,
                "base": b,
                "cand": c,
                "path": path,
            }
            if artifact_valid_any_core(path, b["sha256"], c["sha256"]):
                item["reuse"] = True
            else:
                item["reuse"] = False
            out.append(item)
    return out


def record(state: dict, item: dict) -> None:
    payload = json.loads(item["path"].read_text())
    state["measurements"][item["tag"]] = {
        "pad": item["pad"],
        "baseInstance": item["baseInstance"],
        "candidateInstance": item["candidateInstance"],
        "path": str(item["path"]),
        "sha256": fl.sha256(item["path"]),
        "throughputGeomean": payload["summary"]["throughputGeomean"],
        "logEffectPercentagePoints": 100.0 * math.log(payload["summary"]["throughputGeomean"]),
        "measurementWallSeconds": payload.get("measurementWallSeconds"),
        "effectiveAffinity": payload.get("effectiveAffinity"),
        "parallelDispatch": True,
    }


def run_job(item: dict, cpu: int) -> dict:
    log = fl.ROOT / "logs" / f"measure-{item['tag'].replace('/', '-')}-cpu{cpu}.log"
    cmd = [
        "taskset", "-c", str(cpu),
        sys.executable, str(fl.RUNNER),
        "--zjs", item["cand"]["path"],
        "--qjs", item["base"]["path"],
        "--zoo", str(fl.ZOO),
        "--samples", str(fl.SAMPLES_PER_COMBO),
        "--cpu", str(cpu),
        "--output", str(item["path"]),
    ]
    started = time.time()
    print(f"MEASURE {item['tag']} cpu={cpu} ABBA{fl.SAMPLES_PER_COMBO}", flush=True)
    with log.open("w") as f:
        proc = subprocess.run(cmd, cwd=fl.CAND, stdout=f, stderr=subprocess.STDOUT, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"{item['tag']} failed on cpu {cpu}; see {log}")
    if not artifact_valid_any_core(item["path"], item["base"]["sha256"], item["cand"]["sha256"]):
        raise RuntimeError(f"{item['tag']} produced an invalid artifact on cpu {cpu}")
    payload = json.loads(item["path"].read_text())
    elapsed = time.time() - started
    print(
        f"DONE    {item['tag']} cpu={cpu} {elapsed:.1f}s "
        f"geomean={payload['summary']['throughputGeomean']:.6f}",
        flush=True,
    )
    return item


def main() -> None:
    source = fl.check_sources()
    state = fl.load_or_init(source)
    if len(state["builds"]) != 28:
        raise RuntimeError(f"expected 28 frozen builds, found {len(state['builds'])}")
    planned = jobs(state)
    reused = [j for j in planned if j["reuse"]]
    pending = [j for j in planned if not j["reuse"]]
    print(f"reuse {len(reused)} / pending {len(pending)} / cores {BIG_CORES}", flush=True)
    for item in reused:
        record(state, item)
    fl.atomic_json(fl.ROOT / "state.json", state)

    if pending:
        from threading import Lock

        state["measurementDispatch"] = {
            "mode": "independent-serial-abba2-on-distinct-x925-cores",
            "cores": BIG_CORES,
            "reusedBeforeDispatch": [j["tag"] for j in reused],
            "pendingAtDispatch": [j["tag"] for j in pending],
            "startedUnix": time.time(),
        }
        fl.atomic_json(fl.ROOT / "state.json", state)

        cores = list(BIG_CORES)
        lock = Lock()

        def take_core() -> int:
            while True:
                with lock:
                    if cores:
                        return cores.pop(0)
                time.sleep(0.2)

        def give_core(cpu: int) -> None:
            with lock:
                cores.append(cpu)

        def bound_job(item: dict) -> dict:
            cpu = take_core()
            try:
                return run_job(item, cpu)
            finally:
                give_core(cpu)

        with ThreadPoolExecutor(max_workers=len(BIG_CORES)) as pool:
            futs = [pool.submit(bound_job, item) for item in pending]
            for fut in as_completed(futs):
                item = fut.result()
                record(state, item)
                fl.atomic_json(fl.ROOT / "state.json", state)

    if len(state["measurements"]) != 28:
        raise RuntimeError(f"expected 28 measurements, found {len(state['measurements'])}")
    state["measurementDispatchCompletedUnix"] = time.time()
    fl.atomic_json(fl.ROOT / "state.json", state)
    fl.aggregate(state)


if __name__ == "__main__":
    os.chdir(fl.ROOT)
    main()
