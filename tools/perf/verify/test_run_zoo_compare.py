#!/usr/bin/env python3
"""Contract tests for the Zoo throughput score collector."""

from __future__ import annotations

import importlib.util
import math
import subprocess
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


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

    def test_cpu_list_parser_preserves_lane_order(self) -> None:
        self.assertEqual(runner.parse_cpu_list("5-7,9"), [5, 6, 7, 9])

    def test_cpu_list_parser_rejects_ambiguous_lists(self) -> None:
        for spec in ("", "5,,6", "7-5", "5-7,6", "cpu5"):
            with self.subTest(spec=spec), self.assertRaises(ValueError):
                runner.parse_cpu_list(spec)

    def test_parallel_assignments_swap_clusters_by_sample(self) -> None:
        even = runner.parallel_assignments(["crypto", "zlib"], 0, [5, 6], [15, 16])
        odd = runner.parallel_assignments(["crypto", "zlib"], 1, [5, 6], [15, 16])
        self.assertEqual(
            even,
            [
                ("crypto", "qjs", 5, "a"),
                ("crypto", "zjs", 15, "b"),
                ("zlib", "qjs", 6, "a"),
                ("zlib", "zjs", 16, "b"),
            ],
        )
        self.assertEqual(
            odd,
            [
                ("crypto", "zjs", 5, "a"),
                ("crypto", "qjs", 15, "b"),
                ("zlib", "zjs", 6, "a"),
                ("zlib", "qjs", 16, "b"),
            ],
        )

    def test_parallel_batch_starts_all_assignments_concurrently(self) -> None:
        assignments = runner.parallel_assignments(
            ["crypto", "zlib"], 0, [5, 6], [15, 16]
        )
        barrier = threading.Barrier(len(assignments), timeout=2)

        def fake_run_one(binary: Path, script: Path, cpu: int, timeout: int):
            del binary, timeout
            barrier.wait()
            return {script.stem: cpu}, 0.25

        with mock.patch.object(runner, "run_one", side_effect=fake_run_one):
            outputs = runner.run_parallel_batch(
                assignments,
                {"zjs": Path("zjs"), "qjs": Path("qjs")},
                {"crypto": Path("crypto.js"), "zlib": Path("zlib.js")},
                10,
            )

        self.assertEqual(outputs[("crypto", "qjs")], ({"crypto": 5}, 0.25, 5, "a"))
        self.assertEqual(outputs[("zlib", "zjs")], ({"zlib": 16}, 0.25, 16, "b"))

    def test_run_one_rejects_nonzero_exit_even_with_a_score(self) -> None:
        completed = SimpleNamespace(returncode=1, stdout="Crypto: 123\n", stderr="boom")
        with mock.patch.object(subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(runner.RunFailure, "exited 1"):
                runner.run_one(Path("zjs"), Path("crypto.js"), 19, 10)

    def test_run_one_reports_timeout_as_run_failure(self) -> None:
        with mock.patch.object(
            subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(["zjs", "crypto.js"], 10),
        ):
            with self.assertRaisesRegex(runner.RunFailure, "timed out"):
                runner.run_one(Path("zjs"), Path("crypto.js"), 19, 10)


if __name__ == "__main__":
    unittest.main()
