#!/usr/bin/env python3
"""Contract tests for the deterministic Zoo PMU source transform and parser."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


VERIFY_DIR = Path(__file__).resolve().parent
ZOO_DIR = VERIFY_DIR.parent / "zoo"
MODULE_PATH = ZOO_DIR / "run_zoo_fixed_pmu.py"
sys.path.insert(0, str(ZOO_DIR))
_spec = importlib.util.spec_from_file_location("run_zoo_fixed_pmu", MODULE_PATH)
runner = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(runner)


class FixedZooPMUTests(unittest.TestCase):
    def canonical_source(self) -> bytes:
        return b"\n".join(
            [
                b"var before = 1;",
                runner.WARMUP_MARKER.encode(),
                runner.DETERMINISTIC_MARKER.encode(),
                b"var after = 2;",
            ]
        )

    def test_fixed_source_changes_only_the_two_canonical_assignments(self) -> None:
        source = self.canonical_source()
        transformed = runner.fixed_source(source, Path("case.js"), 1)
        self.assertEqual(
            transformed,
            source.replace(
                runner.WARMUP_MARKER.encode(),
                b"BenchmarkSuite.config.doWarmup = false;",
            ).replace(
                runner.DETERMINISTIC_MARKER.encode(),
                b"BenchmarkSuite.config.doDeterministic = true;",
            ),
        )

    def test_iteration_divisor_scales_both_iteration_controls_upward(self) -> None:
        transformed = runner.fixed_source(
            self.canonical_source(), Path("case.js"), 16
        ).decode()
        self.assertIn(
            "Math.ceil(__zjs_item.deterministicIterations / 16)", transformed
        )
        self.assertIn("Math.ceil(__zjs_item.minIterations / 16)", transformed)
        self.assertEqual(transformed.count("doWarmup = false"), 1)
        self.assertEqual(transformed.count("doDeterministic = true"), 1)

    def test_noncanonical_or_duplicate_markers_fail_closed(self) -> None:
        with self.assertRaises(SystemExit):
            runner.fixed_source(b"var x = 1;", Path("missing.js"), 1)
        duplicate = self.canonical_source() + b"\n" + runner.WARMUP_MARKER.encode()
        with self.assertRaises(SystemExit):
            runner.fixed_source(duplicate, Path("duplicate.js"), 1)

    def test_perf_parser_does_not_confuse_instructions_with_branch_instructions(self) -> None:
        text = "\n".join(
            [
                "101,,armv8_pmuv3_1/instructions/,1,100.00,",
                "202,,armv8_pmuv3_1/branch-instructions/,1,100.00,",
                "303,,armv8_pmuv3_1/cycles/,1,100.00,",
            ]
        )
        self.assertEqual(
            runner.parse_perf_csv(
                text, ["instructions", "branch-instructions", "cycles"]
            ),
            {"instructions": 101, "branch-instructions": 202, "cycles": 303},
        )

    def test_missing_or_uncounted_perf_event_fails_closed(self) -> None:
        with self.assertRaises(SystemExit):
            runner.parse_perf_csv(
                "<not counted>,,armv8_pmuv3_1/instructions/,0,0.00,",
                ["instructions"],
            )
        with self.assertRaises(SystemExit):
            runner.parse_perf_csv(
                "101,,armv8_pmuv3_1/instructions/,1,100.00,",
                ["instructions", "cycles"],
            )

    def test_score_keys_must_match_every_run_and_engine(self) -> None:
        matching = {
            "qjs": [{"scores": {"Box2D": 1}}, {"scores": {"Box2D": 2}}],
            "zjs": [{"scores": {"Box2D": 3}}, {"scores": {"Box2D": 4}}],
        }
        self.assertEqual(runner.validate_score_keys("box2d", matching), ("Box2D",))

        inconsistent = {
            "qjs": [{"scores": {"Box2D": 1}}, {"scores": {"Other": 2}}],
            "zjs": [{"scores": {"Box2D": 3}}, {"scores": {"Box2D": 4}}],
        }
        with self.assertRaises(SystemExit):
            runner.validate_score_keys("box2d", inconsistent)

        different = {
            "qjs": [{"scores": {"Box2D": 1}}],
            "zjs": [{"scores": {"Other": 2}}],
        }
        with self.assertRaises(SystemExit):
            runner.validate_score_keys("box2d", different)


if __name__ == "__main__":
    unittest.main()
