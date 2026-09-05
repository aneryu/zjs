#!/usr/bin/env python3
"""Contract tests for the fail-first Stage 0 GC screen."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


VERIFY_DIR = Path(__file__).resolve().parent
PERF_DIR = VERIFY_DIR.parent
MODULE_PATH = PERF_DIR / "stage0_screen.py"
sys.path.insert(0, str(PERF_DIR))
_spec = importlib.util.spec_from_file_location("stage0_screen", MODULE_PATH)
stage0 = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
sys.modules[_spec.name] = stage0
_spec.loader.exec_module(stage0)


def stats(
    *,
    published: int = 100,
    reopened: int = 50,
    deferred: int = 40,
    major: int = 10,
    minor: int = 20,
    stw: int = 1000,
    committed: int = 4096,
    reclaimed: int = 30,
    diagnostic: int = 7,
    reclaimed_leaf: str = "bitmapReclaimedCells",
) -> dict:
    return {
        "blockHeap": {
            "hotReusePublished": published,
            "reopened": reopened,
            "deferredBlockRuns": deferred,
            "committed": committed,
            reclaimed_leaf: reclaimed,
        },
        "cycles": {"majorCompleted": major, "minor": minor},
        "pauseNs": {"minor": {"total": stw}},
        "diagnostic": diagnostic,
    }


def snapshot(value: dict, version: int | None = None) -> dict:
    return {
        "schemaVersion": stage0.gc_snapshot.SCHEMA_VERSION if version is None else version,
        "kind": "gc-heavy-six-fixed-work-structure",
        "runs": [
            {
                "benchmark": "splay",
                "fixedSourceSha256": "fixed",
                "stats": value,
            }
        ],
    }


class Stage0ScreenTests(unittest.TestCase):
    def test_lifecycle_metrics_have_the_pre_registered_classification(self) -> None:
        classes = {path: classification for path, _, classification in stage0.METRICS}
        self.assertEqual(classes["cycles.minor"], "deterministic")
        self.assertEqual(classes["pauseNs.minor.total"], "phase-sensitive")
        self.assertEqual(classes["blockHeap.bitmapReclaimedCells"], "deterministic")
        self.assertEqual(classes["blockHeap.deferredBlockRuns"], "deterministic")
        self.assertEqual(classes["cycles.majorCompleted"], "phase-sensitive")
        self.assertEqual(classes["blockHeap.hotReusePublished"], "phase-sensitive")
        self.assertEqual(classes["blockHeap.reopened"], "phase-sensitive")
        self.assertEqual(classes["blockHeap.committed"], "phase-sensitive")

    def test_stats_compare_flags_fixed_group_and_keeps_other_drift_in_appendix(self) -> None:
        old = snapshot(stats())
        new = snapshot(stats(published=111, diagnostic=9))
        summary, other = stage0.compare_stats(old, new, ("splay",))
        self.assertFalse(summary["splay"]["deterministicDrift"])
        self.assertTrue(summary["splay"]["phaseSensitiveDrift"])
        self.assertTrue(
            summary["splay"]["metrics"]["hot reuse published"]["crossed"]
        )
        self.assertEqual([row["metric"] for row in other], ["diagnostic"])

    def test_frozen_baseline_tolerates_only_version_registered_new_leaves(self) -> None:
        # The frozen `main-d944f26d` baseline carries the v7 stamp but predates
        # the v7 atom-audit and string-kind rows, so a leaf the baseline's
        # version is allowed to lack is scored against 0 and annotated instead
        # of aborting the screen.
        old = snapshot(stats(), version=7)
        with_leaf = stats()
        with_leaf["markFootprint"] = {"byKind": {"bigInt": 5}}
        new = snapshot(with_leaf)
        summary, other = stage0.compare_stats(old, new, ("splay",))
        self.assertFalse(summary["splay"]["deterministicDrift"])
        rows = {row["metric"]: row for row in other}
        self.assertEqual(list(rows), ["markFootprint.byKind.bigInt"])
        self.assertEqual(rows["markFootprint.byKind.bigInt"]["baseline"], 0)
        self.assertTrue(rows["markFootprint.byKind.bigInt"]["baselineMissingLeaf"])
        self.assertIn("schemaVersion 7", rows["markFootprint.byKind.bigInt"]["note"])

    def test_unregistered_new_leaf_is_a_hard_schema_fork(self) -> None:
        old = snapshot(stats(), version=7)
        forked = stats()
        forked["novelCounter"] = 3
        with self.assertRaisesRegex(stage0.Stage0Error, "novelCounter"):
            stage0.compare_stats(old, snapshot(forked), ("splay",))
        with self.assertRaisesRegex(stage0.Stage0Error, "candidate dropped"):
            stage0.compare_stats(snapshot(forked, version=7), snapshot(stats()), ("splay",))
        with self.assertRaisesRegex(stage0.Stage0Error, "precedes the frozen baseline"):
            stage0.compare_stats(snapshot(stats()), snapshot(stats(), version=7), ("splay",))

    def test_a_renamed_contract_metric_still_reads_out_of_a_frozen_baseline(self) -> None:
        # `blockHeap.passASettledCells` became `blockHeap.bitmapReclaimedCells`
        # in TGC S5-a. The frozen baseline can never be re-emitted, so the
        # deterministic +-10% line has to follow the rename rather than either
        # aborting the screen or silently scoring the metric against 0.
        old = snapshot(stats(reclaimed=30, reclaimed_leaf="passASettledCells"), version=8)
        new = snapshot(stats(reclaimed=31))
        summary, other = stage0.compare_stats(old, new, ("splay",))
        row = summary["splay"]["metrics"]["bitmap reclaimed cells"]
        self.assertEqual(row["baseline"], 30)
        self.assertEqual(row["candidate"], 31)
        self.assertFalse(row["crossed"])
        self.assertFalse(summary["splay"]["deterministicDrift"])
        # The retired leaf is not reported as a dropped one, and it is not
        # replayed into the appendix either.
        self.assertEqual([r["metric"] for r in other], [])

        crossed = snapshot(stats(reclaimed=60))
        summary, _ = stage0.compare_stats(old, crossed, ("splay",))
        self.assertTrue(summary["splay"]["deterministicDrift"])

    def test_zero_baseline_is_stable_only_when_candidate_is_also_zero(self) -> None:
        self.assertFalse(stage0.drift_row("x", "m", 0, 0)["crossed"])
        self.assertTrue(stage0.drift_row("x", "m", 0, 1)["crossed"])
        self.assertEqual(stage0.ratio(0, 0), 1.0)
        self.assertIsNone(stage0.ratio(1, 0))

    def test_worst_failure_prefers_pmu_workload_for_symbol_attribution(self) -> None:
        pmu = {
            "splay": {"instructions": 1.004, "cycles": 1.010},
            "earley-boyer": {"instructions": 1.040, "cycles": 1.120},
        }
        clean_metric = {
            "crossed": False,
            "relativePercent": 0.0,
            "label": "x",
            "classification": "deterministic",
        }
        stats_rows = {
            "splay": {"metrics": {"x": clean_metric}},
            "earley-boyer": {"metrics": {"x": clean_metric}},
        }
        self.assertEqual(
            stage0.worst_failure(
                pmu, stats_rows, ("splay", "earley-boyer")
            )[:2],
            ("earley-boyer", "cycles"),
        )

    def test_cycles_between_half_and_two_percent_wait_for_formal_gate(self) -> None:
        self.assertEqual(stage0.cycles_disposition(1.0049), "ok")
        self.assertEqual(stage0.cycles_disposition(1.005), "待正式")
        self.assertEqual(stage0.cycles_disposition(1.0199), "待正式")
        self.assertEqual(stage0.cycles_disposition(1.020), "待正式")
        self.assertEqual(stage0.cycles_disposition(1.0201), "STOP")

        pmu = {"splay": {"instructions": 1.0, "cycles": 1.019}}
        clean_metric = {
            "crossed": False,
            "relativePercent": 0.0,
            "label": "x",
            "classification": "deterministic",
        }
        stats_rows = {"splay": {"metrics": {"x": clean_metric}}}
        self.assertIsNone(stage0.worst_failure(pmu, stats_rows, ("splay",)))

    def test_instruction_half_percent_and_cycles_two_percent_are_separate_stops(self) -> None:
        clean_metric = {
            "crossed": False,
            "relativePercent": 0.0,
            "label": "x",
            "classification": "deterministic",
        }
        stats_rows = {"splay": {"metrics": {"x": clean_metric}}}
        self.assertEqual(
            stage0.worst_failure(
                {"splay": {"instructions": 1.006, "cycles": 1.0}},
                stats_rows,
                ("splay",),
            )[:2],
            ("splay", "instructions"),
        )
        self.assertEqual(
            stage0.worst_failure(
                {"splay": {"instructions": 1.0, "cycles": 1.021}},
                stats_rows,
                ("splay",),
            )[:2],
            ("splay", "cycles"),
        )

    def test_perf_report_parser_and_delta_preserve_named_gc_symbols(self) -> None:
        base = stage0.parse_perf_report(
            " 6|[.] core.gc_block_heap.Heap.findCellState|x\n"
            " 25|[.] core.gc_block_heap.Heap.openBlock|x\n"
        )
        candidate = stage0.parse_perf_report(
            " 2882|[.] core.gc_block_heap.Heap.findCellState|x\n"
            " 1605|[.] core.gc_block_heap.Heap.openBlock|x\n"
        )
        top = stage0.symbol_delta(base, candidate)
        self.assertIn("findCellState", top[0]["symbol"])
        self.assertIn("openBlock", top[1]["symbol"])
        self.assertEqual(top[0]["deltaSamples"], 2876)
        self.assertEqual(top[1]["deltaSamples"], 1580)

    def test_perf_report_merges_renumbered_instantiations(self) -> None:
        # Same instance, different per-build numbering: one key, summed.
        base = stage0.parse_perf_report(
            " 72|[.] exec.tailcall_dispatch.opCall__struct_138912.h|x\n"
            " 2|[.] exec.tailcall_dispatch.opCall__struct_138896.h|x\n"
            " 9|[.] core.gc_trace_stw.traceHeaderEdges__anon_133046|x\n"
        )
        candidate = stage0.parse_perf_report(
            " 70|[.] exec.tailcall_dispatch.opCall__struct_139059.h|x\n"
            " 2|[.] exec.tailcall_dispatch.opCall__struct_139043.h|x\n"
            " 9|[.] core.gc_trace_stw.traceHeaderEdges__anon_133100|x\n"
        )
        self.assertEqual(base, {
            "exec.tailcall_dispatch.opCall__struct.h": 74,
            "core.gc_trace_stw.traceHeaderEdges__anon": 9,
        })
        top = stage0.symbol_delta(base, candidate)
        self.assertEqual([row["deltaSamples"] for row in top], [0, -2])

    def test_field_b_is_not_a_stage0_cli_choice(self) -> None:
        parser = stage0.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(["screen", "--base", "/tmp/base", "--field", "b"])

    def test_declared_stage0_placements_never_include_cpu19(self) -> None:
        self.assertNotIn("19", stage0.BUILD_CPUS.split(","))
        self.assertEqual(stage0.measure_fields.FIELDS["a"].single_cpu, 9)

    def test_pmu_validation_requires_attested_field_a_and_exact_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            baseline = root / "base"
            candidate = root / "candidate"
            baseline.write_bytes(b"base")
            candidate.write_bytes(b"candidate")
            artifact = {
                "samplesPerEnginePerBench": 2,
                "firstPositionBalanced": True,
                "measurementField": {
                    "name": "a",
                    "single_cpu": 9,
                    "fieldConforming": True,
                    "lockAttested": True,
                },
                "binaries": {
                    "zjs": {"sha256": stage0.sha256_of(candidate)},
                    "qjs": {"sha256": stage0.sha256_of(baseline)},
                },
                "benchmarks": {
                    "splay": {
                        "metrics": {
                            metric: {"ratioMedian": 1.0}
                            for metric in (
                                "instructions",
                                "cycles",
                                "minflt",
                                "maxrssKb",
                            )
                        }
                    }
                },
            }
            self.assertEqual(
                stage0.validate_pmu(
                    artifact, candidate, baseline, ("splay",)
                )["splay"]["cycles"],
                1.0,
            )
            artifact["measurementField"]["single_cpu"] = 19
            with self.assertRaisesRegex(stage0.Stage0Error, "field-A/CPU9"):
                stage0.validate_pmu(artifact, candidate, baseline, ("splay",))

    def test_cross_layout_requires_an_explicit_cli_flag(self) -> None:
        args = stage0.build_parser().parse_args(
            ["screen", "--base", "/tmp/base", "--cross-layout"]
        )
        self.assertTrue(args.cross_layout)


if __name__ == "__main__":
    unittest.main()
