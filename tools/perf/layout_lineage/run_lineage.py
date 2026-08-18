#!/usr/bin/env python3
"""Layout-lineage A/B: separate a candidate's mechanism effect from the code-layout lottery.

Why this exists
---------------
`instructions` down while `cycles` up is not anomalous -- cycles = instructions / IPC,
so a candidate that removes instructions can still lose if it costs more IPC than it
saves work. But there are two very different reasons IPC can fall:

  * semantic     -- the new code really does stall more (dependency chain, cache miss,
                    branch mispredict caused by the new control flow);
  * layout       -- the new code merely sits at different addresses, and this host has a
                    documented +/-2.5% code-placement lottery (I-cache/BTB/uop-cache
                    aliasing) that has already produced "instructions bit-identical,
                    cycles +2.76%" readings.

Two cold builds do NOT separate these. Zig is deterministic for a fixed source, so the
usual "build each side twice" only samples compiler non-determinism, which is nearly
absent here. What separates them is holding the *source* fixed while forcing the
*layout* to move -- which is exactly what `-Dzjs_dossier_layout_pad` does
(see src/dossier_pad.zig: N non-foldable exported bodies in
`.text.zjs.layout_pad` on aarch64 ELF, KEEP'd inside the handler island
after its page-aligned start so pad N shifts handler VAs; zero bytes
emitted at N=0).

This runner builds both sides across several pad lineages, measures each lineage as its
own paired A/B, and reports whether the effect survives the layout change.

Verdict rule
------------
  SEMANTIC  -- every lineage agrees in sign AND |median effect| > lineage spread
  LAYOUT    -- sign flips across lineages, or |median effect| <= lineage spread
  UNRESOLVED-- lineages agree in sign but the effect is inside the spread

Instructions are reported alongside cycles because a semantic win usually shows a
stable instruction delta across all lineages (padding does not change what executes),
while a layout artifact shows a near-zero instruction delta with a moving cycle delta.

Usage
-----
    python3 tools/perf/layout_lineage/run_lineage.py \
        --base-worktree /tmp/wt-baseline --cand-worktree /home/aneryu/zjs \
        --pads 0 3 7 --benches regexp --samples 4 --cpu 6 \
        --output reports/.../regexp-lineage.json
"""

from __future__ import annotations

import argparse
import json
import subprocess
import statistics
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
FIXED_PMU = REPO / "tools" / "perf" / "zoo" / "run_zoo_fixed_pmu.py"


def fail(msg: str, code: int = 2) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def build(worktree: Path, pad: int, tag: str) -> Path:
    """Build one (side, pad) binary in its own cache so lineages cannot share objects."""
    cache = Path(f"/tmp/lineage-cache-{tag}-pad{pad}")
    out = Path(f"/tmp/lineage-bin-{tag}-pad{pad}")
    cmd = [
        "zig", "build", "zjs",
        "-Doptimize=ReleaseFast",
        f"-Dzjs_dossier_layout_pad={pad}",
        "--cache-dir", str(cache),
        "--prefix", str(Path(f"/tmp/lineage-prefix-{tag}-pad{pad}")),
    ]
    print(f"  building {tag} pad={pad} ...", flush=True)
    res = subprocess.run(cmd, cwd=worktree, capture_output=True, text=True)
    if res.returncode != 0:
        fail(f"build failed for {tag} pad={pad}:\n{res.stderr[-2000:]}")
    built = Path(f"/tmp/lineage-prefix-{tag}-pad{pad}") / "bin" / "zjs"
    if not built.exists():
        fail(f"expected binary missing: {built}")
    out.write_bytes(built.read_bytes())
    out.chmod(0o755)
    return out


def sha256(p: Path) -> str:
    return subprocess.run(["sha256sum", str(p)], capture_output=True, text=True).stdout.split()[0]


def measure(base: Path, cand: Path, benches: list[str], samples: int, cpu: int, pmu: str, tag: str) -> dict:
    out = Path(f"/tmp/lineage-pmu-{tag}.json")
    cmd = [
        sys.executable, str(FIXED_PMU),
        "--zjs", str(cand), "--qjs", str(base),
        "--benches", *benches,
        "--samples", str(samples), "--cpu", str(cpu), "--pmu", pmu,
        "--output", str(out),
    ]
    res = subprocess.run(["taskset", "-c", str(cpu)] + cmd, capture_output=True, text=True)
    if res.returncode != 0:
        fail(f"measurement failed for {tag}:\n{res.stdout[-1500:]}\n{res.stderr[-1500:]}")
    return json.loads(out.read_text())


# Metrics carried through to the lineage report. instructions/cycles drive the verdict;
# the rest are what a reader needs to attribute an IPC change without a second run.
TRACKED = ("instructions", "cycles", "branch-instructions", "branch-misses",
           "cache-references", "cache-misses")


def extract(payload: dict, bench: str) -> dict:
    """Return per-metric {ratioMedian, ratioMAD} plus IPC, as candidate/base."""
    body = payload.get("benchmarks", {}).get(bench)
    if body is None:
        fail(f"benchmark {bench} missing from artifact")
    metrics = body.get("metrics", {})
    out: dict = {}
    for name in TRACKED:
        entry = metrics.get(name)
        if entry is None or "ratioMedian" not in entry:
            if name in ("instructions", "cycles"):
                fail(f"artifact for {bench} lacks {name}.ratioMedian")
            continue
        out[name] = {"ratio": float(entry["ratioMedian"]), "mad": float(entry.get("ratioMAD", 0.0))}
    ipc = body.get("derived", {}).get("ipcRatioZjsOverQjs")
    if ipc is not None:
        out["ipc"] = {"ratio": float(ipc), "mad": 0.0}
    return out


def verdict(values: list[float]) -> tuple[str, float, float]:
    """Classify one metric's per-lineage effects (ratios, 1.0 == no change)."""
    effects = [(v - 1.0) * 100.0 for v in values]
    med = statistics.median(effects)
    spread = (max(effects) - min(effects)) if len(effects) > 1 else 0.0
    signs = {1 if e > 0 else (-1 if e < 0 else 0) for e in effects}
    if len(signs - {0}) > 1:
        return "LAYOUT (sign flips across lineages)", med, spread
    if abs(med) <= spread:
        return "UNRESOLVED (effect within lineage spread)", med, spread
    return "SEMANTIC (stable across lineages)", med, spread


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-worktree", required=True)
    ap.add_argument("--cand-worktree", required=True)
    ap.add_argument("--pads", nargs="+", type=int, default=[0, 3, 7],
                    help="layout-lineage pad slot counts; at least 3 recommended")
    ap.add_argument("--benches", nargs="+", required=True)
    ap.add_argument("--samples", type=int, default=4, help="must be even (measurement contract #3)")
    ap.add_argument("--cpu", type=int, required=True)
    ap.add_argument("--pmu", default="armv8_pmuv3_1")
    ap.add_argument("--output")
    args = ap.parse_args()

    if args.samples % 2 != 0:
        fail("--samples must be even to balance the paired order (measurement contract #3)")
    if len(args.pads) < 2:
        fail("at least two pad lineages are required; one lineage cannot separate layout from mechanism")
    if len(set(args.pads)) != len(args.pads):
        fail("--pads must be distinct")

    base_wt, cand_wt = Path(args.base_worktree), Path(args.cand_worktree)
    for p in (base_wt, cand_wt):
        if not (p / "build.zig").exists():
            fail(f"not a zjs worktree: {p}")

    print(f"layout-lineage A/B over pads {args.pads}, benches {args.benches}, cpu {args.cpu}")
    lineages = []
    for pad in args.pads:
        b = build(base_wt, pad, "base")
        c = build(cand_wt, pad, "cand")
        bs, cs = sha256(b), sha256(c)
        if bs == cs:
            fail(f"pad={pad}: base and candidate binaries are identical -- the candidate has no effect")
        payload = measure(b, c, args.benches, args.samples, args.cpu, args.pmu, f"pad{pad}")
        entry = {"pad": pad, "baseSha256": bs, "candSha256": cs, "benches": {}}
        for bench in args.benches:
            metrics = extract(payload, bench)
            entry["benches"][bench] = metrics
            insn, cyc = metrics["instructions"]["ratio"], metrics["cycles"]["ratio"]
            ipc = metrics.get("ipc", {}).get("ratio")
            bm = metrics.get("branch-misses", {}).get("ratio")
            extra = ""
            if ipc is not None:
                extra += f"  IPC {(ipc-1)*100:+6.2f}%"
            if bm is not None:
                extra += f"  brmiss {(bm-1)*100:+6.2f}%"
            print(f"  pad={pad:<3d} {bench:<14s} insn {(insn-1)*100:+7.3f}%   cyc {(cyc-1)*100:+7.3f}%{extra}")
        lineages.append(entry)

    print("\n=== verdict per benchmark ===")
    verdicts = {}
    for bench in args.benches:
        insn_vals = [l["benches"][bench]["instructions"]["ratio"] for l in lineages]
        cyc_vals = [l["benches"][bench]["cycles"]["ratio"] for l in lineages]
        iv, imed, ispread = verdict(insn_vals)
        cv, cmed, cspread = verdict(cyc_vals)
        verdicts[bench] = {
            "instructions": {"verdict": iv, "medianPercent": imed, "spreadPercent": ispread},
            "cycles": {"verdict": cv, "medianPercent": cmed, "spreadPercent": cspread},
        }
        print(f"  {bench}")
        print(f"    instructions  median {imed:+7.3f}%  spread {ispread:6.3f}pp  -> {iv}")
        print(f"    cycles        median {cmed:+7.3f}%  spread {cspread:6.3f}pp  -> {cv}")

    artifact = {
        "tool": "zjs-layout-lineage",
        "schemaVersion": 1,
        "rationale": "pad lineages hold source fixed and move layout; two cold builds do not, "
                     "because Zig is deterministic for a fixed source",
        "padSlots": args.pads,
        "samplesPerSide": args.samples,
        "cpu": args.cpu,
        "pmu": args.pmu,
        "baseWorktree": str(base_wt),
        "candWorktree": str(cand_wt),
        "lineages": lineages,
        "verdicts": verdicts,
    }
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(json.dumps(artifact, indent=1))
        print(f"\nartifact: {args.output}")


if __name__ == "__main__":
    main()
