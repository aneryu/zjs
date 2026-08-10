#!/usr/bin/env python3
"""Contract tests for the Zoo throughput score collector."""

from __future__ import annotations

import importlib.util
import math
import unittest
from pathlib import Path


VERIFY_DIR = Path(__file__).resolve().parent
MODULE_PATH = VERIFY_DIR.parent / "zoo" / "run_zoo_compare.py"
_spec = importlib.util.spec_from_file_location("run_zoo_compare", MODULE_PATH)
runner = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(runner)


class ZooCompareTests(unittest.TestCase):
    def test_even_sample_median_averages_the_middle_pair(self) -> None:
        self.assertEqual(runner.median([1, 100, 2, 3]), 2.5)
        self.assertEqual(runner.median([1, 3, 2]), 2)

    def test_score_parser_ignores_noise_and_keeps_latency_keys(self) -> None:
        self.assertEqual(
            runner.parse_scores("noise\nSplay: 7318\nSplayLatency: 18021\n"),
            {"Splay": 7318, "SplayLatency": 18021},
        )

    def test_geomean_preserves_equal_ratios(self) -> None:
        self.assertTrue(math.isclose(runner.geomean([0.8, 0.8, 0.8]), 0.8))


if __name__ == "__main__":
    unittest.main()
