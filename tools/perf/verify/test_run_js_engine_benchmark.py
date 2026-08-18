#!/usr/bin/env python3
"""Contract tests for the js-engine-benchmark v8-v7 scorer."""

from __future__ import annotations

import importlib.util
import math
import tempfile
import unittest
from pathlib import Path


VERIFY_DIR = Path(__file__).resolve().parent
MODULE_PATH = VERIFY_DIR.parent / "js_engine_benchmark" / "run.py"
_spec = importlib.util.spec_from_file_location("run_js_engine_benchmark", MODULE_PATH)
runner = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(runner)


class JsEngineBenchmarkTests(unittest.TestCase):
    def test_score_parser_matches_official_integer_truncation(self) -> None:
        text = (
            "Richards: 1126\n"
            "DeltaBlue: 1086.9\n"
            "----\n"
            "Score: 1813\n"
            "ignored: 9\n"
        )
        self.assertEqual(
            runner.parse_scores(text),
            {"Richards": 1126, "DeltaBlue": 1086, "Score": 1813},
        )

    def test_score_parser_uses_dash_column_as_official_offset(self) -> None:
        text = (
            'xx"Richards: 292"\n'
            "xx----\n"
            "xxScore: 100\n"
        )
        self.assertEqual(
            runner.parse_scores(text),
            {"Richards": 292, "Score": 100},
        )

    def test_score_parser_ignores_non_suite_keys(self) -> None:
        self.assertEqual(runner.parse_scores("Version: 1\nTime(s): 30\n"), {})

    def test_geomean_is_the_suite_score_definition(self) -> None:
        values = [1126, 1086, 1510, 2324, 2338, 732, 4686, 3393]
        self.assertTrue(math.isclose(runner.geomean(values), 1813, rel_tol=0, abs_tol=0.5))

    def test_score_per_mb_matches_update_ts(self) -> None:
        self.assertEqual(runner.score_per_mb(1865, 1071472), 1825)
        self.assertEqual(runner.score_per_mb(1813, 33145672), 57)
        self.assertEqual(runner.score_per_mb(1813, 0), 0)

    def test_bundle_inlines_every_load_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            v8 = root / "v8-v7"
            v8.mkdir()
            (v8 / "base.js").write_text("var BASE = 1;\n")
            (v8 / "richards.js").write_text("var RICHARDS = 2;\n")
            (v8 / "run.js").write_text("load('base.js');\nload('richards.js');\nrun();\n")
            bundled = runner.bundle_run_js(root)
            self.assertNotIn("load(", bundled)
            self.assertIn("var BASE = 1;", bundled)
            self.assertIn("var RICHARDS = 2;", bundled)
            self.assertTrue(bundled.endswith("run();\n"))


if __name__ == "__main__":
    unittest.main()
