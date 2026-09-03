#!/usr/bin/env python3
"""Contract tests for the fixed-work bench-v8 PMU script assembly and parser."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


VERIFY_DIR = Path(__file__).resolve().parent
BENCH_V8_DIR = VERIFY_DIR.parent / "bench_v8"
MODULE_PATH = BENCH_V8_DIR / "run_fixed_pmu.py"
sys.path.insert(0, str(BENCH_V8_DIR))
_spec = importlib.util.spec_from_file_location("run_fixed_pmu", MODULE_PATH)
runner = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(runner)


class FixedBenchV8PMUTests(unittest.TestCase):
    def fake_suite(self, tmp: str) -> Path:
        suite = Path(tmp)
        (suite / "base.js").write_text("var __base_marker = 1;\n")
        (suite / "richards.js").write_text("var __richards_marker = 2;\n")
        return suite

    def test_build_script_orders_base_bench_config_runner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite = self.fake_suite(tmp)
            script, provenance = runner.build_script("richards", suite, 1)
        base_at = script.index("__base_marker")
        bench_at = script.index("__richards_marker")
        config_at = script.index("BenchmarkSuite.config.doWarmup = false;")
        run_at = script.index("BenchmarkSuite.RunSuites(")
        self.assertTrue(base_at < bench_at < config_at < run_at)
        self.assertEqual(script.count("doWarmup = false"), 1)
        self.assertEqual(script.count("doDeterministic = true"), 1)
        self.assertEqual([entry["file"] for entry in provenance], ["base.js", "richards.js"])

    def test_iteration_divisor_scales_both_iteration_controls_upward(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite = self.fake_suite(tmp)
            script, _ = runner.build_script("richards", suite, 16)
            unscaled, _ = runner.build_script("richards", suite, 1)
        self.assertIn("Math.ceil(__zjs_item.deterministicIterations / 16)", script)
        self.assertIn("Math.ceil(__zjs_item.minIterations / 16)", script)
        self.assertNotIn("deterministicIterations /", unscaled)

    def test_unknown_benchmark_and_missing_file_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite = self.fake_suite(tmp)
            with self.assertRaises(SystemExit):
                runner.build_script("zlib", suite, 1)
            with self.assertRaises(SystemExit):
                runner.build_script("typescript", suite, 1)

    def test_score_parser_takes_results_and_skips_composite_and_errors(self) -> None:
        scores = runner.parse_scores(
            "Splay: 7114\nSplayLatency: 14815\n----\n"
            "Score (version 9): 4404\nBox2D: ERROR: boom\n"
        )
        self.assertEqual(scores, {"Splay": 7114.0, "SplayLatency": 14815.0})

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

    def test_time_rusage_parser_requires_both_integer_fields(self) -> None:
        self.assertEqual(
            runner.parse_time_rusage("minflt=123 maxrssKb=456\n"),
            {"minflt": 123, "maxrssKb": 456},
        )
        with self.assertRaises(SystemExit):
            runner.parse_time_rusage("minflt=123\n")

    def test_samples_retain_paired_abba_minimum(self) -> None:
        runner.validate_samples(2)
        with self.assertRaises(SystemExit):
            runner.validate_samples(1)
        with self.assertRaises(SystemExit):
            runner.validate_samples(3)

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
