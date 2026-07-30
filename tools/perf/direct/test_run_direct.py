#!/usr/bin/env python3

import argparse
import importlib.util
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("run_direct.py")
SPEC = importlib.util.spec_from_file_location("run_direct_under_test", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RUN_DIRECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUN_DIRECT)


def observation(value: float = 0.0) -> dict:
    return {
        "before": value,
        "after": value,
        "delta": 0.0,
        "reason": None,
    }


def engine_record(
    engine: str,
    *,
    checksum_comparable: bool,
    instruction_value: float,
    wall_value: float,
) -> dict:
    performance_counters = {}
    perf_events = {}
    for event in RUN_DIRECT.PERF_EVENTS:
        value = instruction_value if event == "instructions" else 10.0
        performance_counters[event] = {
            "process_scope_per_op": value,
            "loop_only_per_op": value,
            "loop_only_reason": None,
        }
        perf_events[event] = {
            "status": "counted",
            "value": value,
            "event": event,
            "reason": None,
        }
    record = {
        "engine": engine,
        "category": "dtoa",
        "case": "mixed-free",
        "iterations": 100,
        "warmup": 10,
        "requested_iterations": 100,
        "requested_warmup": 10,
        "ns_per_op": wall_value,
        "checksum": "same",
        "fidelity": "true-direct",
        "entry": "test-entry",
        "comparable": True,
        "checksum_comparable": checksum_comparable,
        "caliber_note": "test",
        "valid": True,
        "exit_code": 0,
        "stderr_clean": True,
        "stderr_bytes": 0,
        "stdout_json_valid": True,
        "loop_counts_valid": True,
        "performance_counters": performance_counters,
        "perf_events": perf_events,
        "allocations": observation(),
        "allocated_bytes": observation(),
        "peak_rss_kb": 1,
        "peak_rss_reason": None,
    }
    record["baseline"] = {
        "engine": engine,
        "category": "dtoa",
        "case": "mixed-free",
        "iterations": 1,
        "warmup": 10,
        "requested_iterations": 1,
        "requested_warmup": 10,
        "ns_total": 1,
        "ns_per_op": 1,
        "checksum": "baseline-same",
        "fidelity": "true-direct",
        "entry": "test-entry",
        "comparable": True,
        "checksum_comparable": checksum_comparable,
        "caliber_note": "test",
        "valid": True,
        "exit_code": 0,
        "stderr_clean": True,
        "stderr_bytes": 0,
        "stdout_json_valid": True,
        "loop_counts_valid": True,
    }
    return record


def sample(*, checksum_comparable: bool) -> dict:
    return {
        "sample": 1,
        "order": ["qjs", "zjs"],
        "engines": {
            "zjs": engine_record(
                "zjs",
                checksum_comparable=checksum_comparable,
                instruction_value=1.10,
                wall_value=0.90,
            ),
            "qjs": engine_record(
                "qjs",
                checksum_comparable=checksum_comparable,
                instruction_value=1.0,
                wall_value=1.0,
            ),
        },
        "checksums_match": True if checksum_comparable else None,
        "baseline_checksums_match": (
            True if checksum_comparable else None
        ),
    }


def valid_provenance(*, perf_requested: bool = True) -> dict:
    provenance = {
        name: True for name in RUN_DIRECT.PROVENANCE_CHECK_NAMES
    }
    provenance.update(
        {
            "requested_iterations": 100,
            "requested_warmup": 10,
            "perf_requested": perf_requested,
        }
    )
    return provenance


class ComparabilityRegressionTests(unittest.TestCase):
    def test_checksum_not_comparable_excludes_headline(self) -> None:
        summary = RUN_DIRECT.summarize_case(
            "dtoa/mixed-free",
            [sample(checksum_comparable=False)],
            valid_provenance(),
        )

        self.assertFalse(summary["comparable"])
        self.assertIsNone(summary["headline_ratio_zjs_over_qjs"])
        self.assertIn(
            "checksum_comparable",
            summary["headline_excluded_reason"],
        )
        self.assertTrue(summary["direction_conflict"])
        self.assertFalse(
            summary["direction_conflict_detail"]["checksum_comparable"]
        )
        self.assertFalse(
            summary["direction_conflict_detail"]["comparable"]
        )

    def test_explicit_checksum_not_required_can_participate(self) -> None:
        test_sample = sample(checksum_comparable=False)
        for record in test_sample["engines"].values():
            record["checksum"] = None
            record["baseline"]["checksum"] = None
        definition = {
            "category": "dtoa",
            "case": "mixed-free",
            "checksum_required": False,
        }
        with mock.patch.dict(
            RUN_DIRECT.CASE_DEFINITIONS,
            {"dtoa/mixed-free": definition},
        ):
            summary = RUN_DIRECT.summarize_case(
                "dtoa/mixed-free",
                [test_sample],
                valid_provenance(),
            )

        self.assertTrue(summary["checksum_comparable"])
        self.assertTrue(summary["comparable"])
        self.assertFalse(summary["checksum_required"])
        self.assertTrue(summary["checksum_requirement_declared"])
        self.assertEqual(
            summary["comparability"]["checksum"]["validation_mode"],
            "explicitly not required",
        )

    def test_missing_provenance_is_not_a_pass(self) -> None:
        summary = RUN_DIRECT.summarize_case(
            "dtoa/mixed-free",
            [sample(checksum_comparable=True)],
            {
                "requested_iterations": 100,
                "requested_warmup": 10,
                "perf_requested": True,
            },
        )

        self.assertFalse(summary["provenance_comparable"])
        self.assertIn(
            "was not checked or is missing",
            summary["provenance_comparable_reason"],
        )


class CounterRegressionTests(unittest.TestCase):
    def test_negative_baseline_delta_preserves_raw_and_nulls_derived(self) -> None:
        def invocation(count: float) -> dict:
            return {
                "valid": True,
                "invalid_reasons": [],
                "perf_events": {
                    event: {
                        "status": "counted",
                        "value": count,
                        "event": event,
                        "reason": None,
                    }
                    for event in RUN_DIRECT.PERF_EVENTS
                },
            }

        main = invocation(90)
        baseline = invocation(100)
        args = argparse.Namespace(iterations=10, warmup=0, no_perf=False)
        with mock.patch.object(
            RUN_DIRECT,
            "run_invocation",
            side_effect=[main, baseline],
        ):
            record = RUN_DIRECT.run_direct_process(
                repo=Path("."),
                binary=Path("stub"),
                engine="zjs",
                case_id="dtoa/mixed-free",
                args=args,
                perf_available=True,
            )

        counter = record["performance_counters"]["branch-misses"]
        self.assertEqual(counter["main_raw"], 90)
        self.assertEqual(counter["baseline_raw"], 100)
        self.assertEqual(counter["iterations"], 10)
        self.assertEqual(counter["baseline_iterations"], 1)
        self.assertIsNone(counter["loop_only_per_op"])
        self.assertIn(
            "below_baseline_resolution",
            counter["loop_only_reason"],
        )


if __name__ == "__main__":
    unittest.main()
