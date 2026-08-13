#!/usr/bin/env python3
"""Join counts, production PMU, and fixed-period samples into the exposure matrix."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path


def contribution_pp(saving_cycles: float, zjs_cycles: float, calibration: float) -> float:
    if saving_cycles <= 0 or saving_cycles >= zjs_cycles:
        return 0.0
    return calibration * (100.0 / 15.0) * -math.log1p(-saving_cycles / zjs_cycles)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--counts", required=True)
    parser.add_argument("--pmu", required=True)
    parser.add_argument("--sampling", required=True)
    parser.add_argument(
        "--p3-ablation",
        default="reports/perf/qjs-align/2026-08-13/PDFJS-DIAG-p3-native-backtrace-ablate-ab8.json",
    )
    parser.add_argument("--csv", required=True)
    parser.add_argument("--json", required=True)
    args = parser.parse_args()

    counts = json.loads(Path(args.counts).read_text())
    pmu = json.loads(Path(args.pmu).read_text())
    sampling = json.loads(Path(args.sampling).read_text())
    p3 = json.loads(Path(args.p3_ablation).read_text())
    benches = list(counts["benchmarks"])
    if set(benches) != set(pmu["benchmarks"]) or set(benches) != set(sampling["benchmarks"]):
        raise RuntimeError("benchmark sets differ across inputs")

    p3_cost = -float(p3["metrics"]["cycles"]["deltaMedian"])
    p3_cost_mad = float(p3["metrics"]["cycles"]["deltaMAD"])
    pdf_scopes = float(counts["benchmarks"]["pdfjs"]["counts"]["zjs"]["backtrace_publishes"])
    named_cycles_per_scope = p3_cost / pdf_scopes
    named_cycles_per_scope_mad = p3_cost_mad / pdf_scopes

    # The task supplies 23.689M ~= +0.06 pp for PdfJS.  Calibrate the ordinary
    # 15-item log-geomean formula to that empirical slope, then apply the same
    # factor to each fixed-work fractional saving.  This remains a prediction,
    # not a measured Zoo score.
    supplied_pdf_combined_cycles = 23_689_000.0
    supplied_pdf_combined_pp = 0.06
    target_named_pdf_pp = supplied_pdf_combined_pp * p3_cost / supplied_pdf_combined_cycles
    pdf_z_cycles = float(pmu["benchmarks"]["pdfjs"]["metrics"]["cycles"]["zjsMedian"])
    uncalibrated_named_pdf_pp = (100.0 / 15.0) * -math.log1p(-p3_cost / pdf_z_cycles)
    pp_calibration = target_named_pdf_pp / uncalibrated_named_pdf_pp

    columns = [
        "benchmark",
        "call_kind",
        "q_event_count",
        "z_event_count",
        "q_instructions_per_event",
        "z_instructions_per_event",
        "instruction_deficit_per_event",
        "q_cycles_per_event",
        "z_cycles_per_event",
        "cycle_deficit_per_event",
        "q_backend_stall_per_event",
        "z_backend_stall_per_event",
        "backend_stall_deficit_per_event",
        "absolute_cycle_deficit",
        "predicted_zoo_contribution_pp",
        "basis",
        "note",
    ]
    rows: list[dict] = []
    derived: dict[str, dict] = {}
    named_total_pp = 0.0
    named_total_cycles = 0.0
    entry_stable = 0
    return_stable = 0

    def add(benchmark: str, kind: str, q_count: float, z_count: float, **values: object) -> None:
        row = {key: "" for key in columns}
        row.update({"benchmark": benchmark, "call_kind": kind, "q_event_count": q_count, "z_event_count": z_count})
        row.update(values)
        rows.append(row)

    for bench in benches:
        c = counts["benchmarks"][bench]["counts"]
        q_count = c["qjs"]
        z_count = c["zjs"]
        metrics = pmu["benchmarks"][bench]["metrics"]
        sample_metrics = sampling["benchmarks"][bench]["metrics"]
        q_calls = float(q_count["js_to_js"] + q_count["native_calls"])
        z_calls = float(z_count["js_to_js"] + z_count["c_function_calls"])
        q_insn = float(metrics["instructions"]["qjsMedian"])
        z_insn = float(metrics["instructions"]["zjsMedian"])
        q_cycles = float(metrics["cycles"]["qjsMedian"])
        z_cycles = float(metrics["cycles"]["zjsMedian"])
        q_backend = float(metrics["stall_backend"]["qjsMedian"])
        z_backend = float(metrics["stall_backend"]["zjsMedian"])
        total_cycle_delta = float(metrics["cycles"]["pairedDeltaMedian"])

        add(
            bench,
            "whole_workload_per_semantic_call",
            q_calls,
            z_calls,
            q_instructions_per_event=q_insn / q_calls,
            z_instructions_per_event=z_insn / z_calls,
            instruction_deficit_per_event=z_insn / z_calls - q_insn / q_calls,
            q_cycles_per_event=q_cycles / q_calls,
            z_cycles_per_event=z_cycles / z_calls,
            cycle_deficit_per_event=z_cycles / z_calls - q_cycles / q_calls,
            q_backend_stall_per_event=q_backend / q_calls,
            z_backend_stall_per_event=z_backend / z_calls,
            backend_stall_deficit_per_event=z_backend / z_calls - q_backend / q_calls,
            absolute_cycle_deficit=total_cycle_delta,
            predicted_zoo_contribution_pp=contribution_pp(max(total_cycle_delta, 0.0), z_cycles, pp_calibration),
            basis="production perf stat ABBA8; whole workload normalized by each engine's calls",
            note="normalization only; not an isolated call-boundary unit cost",
        )

        for category in ("entry", "return"):
            sm = sample_metrics[category]
            q_region = float(sm["qjsMedianApproxCycles"])
            z_region = float(sm["zjsMedianApproxCycles"])
            delta = float(sm["pairedDeltaMedian"])
            stable = int(sm["positiveDeltaSamples"]) == sampling["samplesPerEnginePerBenchmark"]
            if stable:
                if category == "entry":
                    entry_stable += 1
                else:
                    return_stable += 1
            add(
                bench,
                f"sampled_call_{category}",
                q_calls,
                z_calls,
                q_cycles_per_event=q_region / q_calls,
                z_cycles_per_event=z_region / z_calls,
                cycle_deficit_per_event=z_region / z_calls - q_region / q_calls,
                absolute_cycle_deficit=delta,
                predicted_zoo_contribution_pp=contribution_pp(max(delta, 0.0), z_cycles, pp_calibration),
                basis=f"flat cycles samples, period {sampling['period']}, ABBA8",
                note=f"region upper bound, not a named mechanism; positive pairs {sm['positiveDeltaSamples']}/8",
            )

        named_cycles = float(z_count["backtrace_publishes"]) * named_cycles_per_scope
        named_pp = contribution_pp(named_cycles, z_cycles, pp_calibration)
        named_total_cycles += named_cycles
        named_total_pp += named_pp
        add(
            bench,
            "native_backtrace_publish_restore",
            q_count["backtrace_publishes"],
            z_count["backtrace_publishes"],
            z_cycles_per_event=named_cycles_per_scope,
            cycle_deficit_per_event=named_cycles_per_scope,
            absolute_cycle_deficit=named_cycles,
            predicted_zoo_contribution_pp=named_pp,
            basis="PdfJS causal ablation cost / PdfJS NativeBacktraceScope count, transferred by exposure",
            note=(
                f"z publish/restore {z_count['backtrace_publishes']}/{z_count['backtrace_restores']}; "
                f"unit MAD {named_cycles_per_scope_mad:.3f} cyc; semantic qualification remains blocked"
            ),
        )

        add(bench, "js_to_js", q_count["js_to_js"], z_count["js_to_js"], basis="counter-only ABBA8")
        add(
            bench,
            "js_to_native_c_function",
            q_count["native_calls"],
            z_count["c_function_calls"],
            basis="counter-only ABBA8; comparable observable C_FUNCTION seam",
        )
        add(
            bench,
            "bytecode_builtin_bytecode_reentry",
            q_count["native_reentries"],
            z_count["native_reentries"],
            basis="counter-only ABBA8",
        )
        add(
            bench,
            "bytecode_frame_push_pop",
            q_count["bytecode_entries"],
            z_count["bytecode_entries"],
            basis="counter-only ABBA8",
            note=(
                f"q push/pop {q_count['bytecode_entries']}/{q_count['bytecode_returns']}; "
                f"z push/pop {z_count['bytecode_entries']}/{z_count['bytecode_returns']}"
            ),
        )
        add(
            bench,
            "entry_or_current_frame_republication",
            q_count["bytecode_entries"],
            z_count["entry_republications"],
            basis="counter-only ABBA8; implementation-specific publication seams",
        )
        add(bench, "reload_top", 0, z_count["reload_top"], basis="counter-only ABBA8; zjs-specific seam")
        add(
            bench,
            "reload_after_pop",
            0,
            z_count["reload_after_pop"],
            basis="counter-only ABBA8; zjs-specific seam",
        )
        add(
            bench,
            "interrupt_poll",
            q_count["interrupt_polls"],
            z_count["interrupt_polls"],
            basis="counter-only ABBA8",
        )
        add(
            bench,
            "native_fence",
            q_count["native_reentries"],
            z_count["native_fences"],
            basis="counter-only ABBA8; native-to-bytecode boundary",
            note=f"z fence push/restore {z_count['native_fences']}/{z_count['native_fence_restores']}",
        )

        derived[bench] = {
            "qSemanticCalls": q_calls,
            "zSemanticCalls": z_calls,
            "pmuPerCall": {
                "qInstructions": q_insn / q_calls,
                "zInstructions": z_insn / z_calls,
                "qCycles": q_cycles / q_calls,
                "zCycles": z_cycles / z_calls,
                "qBackendStall": q_backend / q_calls,
                "zBackendStall": z_backend / z_calls,
            },
            "entry": sample_metrics["entry"],
            "return": sample_metrics["return"],
            "namedBacktrace": {
                "exposure": z_count["backtrace_publishes"],
                "predictedCycles": named_cycles,
                "predictedZooContributionPp": named_pp,
            },
        }

    with Path(args.csv).open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)

    result = {
        "schema": "call-boundary-exposure-matrix-v1",
        "inputs": {"counts": args.counts, "pmu": args.pmu, "sampling": args.sampling, "p3Ablation": args.p3_ablation},
        "namedBacktraceModel": {
            "pdfjsCausalCycles": p3_cost,
            "pdfjsCausalCyclesMAD": p3_cost_mad,
            "pdfjsExposure": pdf_scopes,
            "cyclesPerScopePair": named_cycles_per_scope,
            "cyclesPerScopePairMAD": named_cycles_per_scope_mad,
            "ppCalibrationFactor": pp_calibration,
            "calibration": "23.689M PdfJS cycles ~= 0.06 pp supplied by task",
            "crossZooPredictedCyclesRawSum": named_total_cycles,
            "crossZooPredictedContributionPp": named_total_pp,
        },
        "samplingDirection": {
            "entryStablePositiveBenchmarks": entry_stable,
            "returnStablePositiveBenchmarks": return_stable,
            "stableMeans": "8/8 paired deltas positive",
        },
        "benchmarks": derived,
    }
    Path(args.json).write_text(json.dumps(result, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
