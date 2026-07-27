#!/usr/bin/env python3

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


VERIFY_DIR = Path(__file__).resolve().parent
VERIFIER = VERIFY_DIR.parent / "verify_same_runtime"
P0_SENTINELS = (
    "global_write_loop",
    "prop_read_mono_loop",
    "fib_rec",
    "call_body_loop",
    "method_call_loop",
    "typed_array_read",
    "typed_array_write",
)


def passing_case(name: str) -> dict:
    return {
        "name": name,
        "source_path": (
            f"/checkout/tools/perf/same_runtime/cases/{name}.js"
        ),
        "source_sha256": "a" * 64,
        "checksum_required": True,
        "checksum_requirement_declared": True,
        "case_shape": "function-local",
        "provenance": "test fixture",
        "canonical_source": True,
        "status": "ok",
        "result_checksum": "same",
        "validation": {},
        "sample_pairs": [],
        "pmu": None,
        "paired_ratios": {},
        "status_before_comparability": "ok",
        "reason": None,
        "comparable": True,
        "comparability": {
            "formula": (
                "source_comparable && checksum_comparable && "
                "metric_comparable && provenance_comparable"
            ),
            "source": {"comparable": True},
            "checksum": {
                "comparable": True,
                "required": True,
                "checksum_requirement_declared": True,
                "validation_mode": "required",
                "all_invocations_match": True,
            },
            "metric": {"comparable": True},
            "provenance": {"comparable": True, "checks": {}},
        },
        "source_comparable": True,
        "source_comparable_reason": None,
        "checksum_comparable": True,
        "checksum_comparable_reason": None,
        "metric_comparable": True,
        "metric_comparable_reason": None,
        "provenance_comparable": True,
        "provenance_comparable_reason": None,
    }


def passing_artifact() -> dict:
    cases = [passing_case(name) for name in P0_SENTINELS]
    return {
        "tool": "dual-engine-same-runtime",
        "layer": "same-runtime",
        "timestamp": "2026-07-27T00:00:00.000Z",
        "sampling_order": "ABBA",
        "teardown_mode": "normal",
        "cpu": 19,
        "iterations": 200,
        "warmup": 20,
        "samples": 3,
        "phase_ratio_floor_ns": 1000,
        "pmu_enabled": False,
        "requested_cases": list(P0_SENTINELS),
        "comparability_formula": (
            "source_comparable && checksum_comparable && "
            "metric_comparable && provenance_comparable"
        ),
        "checksum_requirements": {},
        "case_sources": {
            name: f"/checkout/tools/perf/same_runtime/cases/{name}.js"
            for name in P0_SENTINELS
        },
        "environment": {},
        "status_counts": {"ok": 7, "mismatch": 0, "invalid": 0},
        "aggregate": {
            "status": "complete",
            "complete": True,
            "missing_cases": [],
            "missing_case_details": [],
            "p0_sentinel_geomean": 1.0,
            "partial_geomean": None,
            "partial_cases": [],
            "max_case_ratio": 1.0,
            "max_case_name": P0_SENTINELS[0],
            "partial_max_case_ratio": None,
            "partial_max_case_name": None,
            "exit_line": {
                "geomean_limit": 1.1,
                "per_case_limit": 1.2,
                "geomean_pass": True,
                "per_case_pass": True,
                "over_limit_cases": [],
            },
            "pmu": {"instructions": {}},
        },
        "cases": cases,
    }


class VerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.temp_path = Path(self.temporary.name)

    def run_verifier(
        self, artifact: dict, *options: str
    ) -> subprocess.CompletedProcess[str]:
        path = self.temp_path / "artifact.json"
        path.write_text(
            json.dumps(artifact, indent=2) + "\n", encoding="utf-8"
        )
        return subprocess.run(
            [sys.executable, str(VERIFIER), *options, str(path)],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_all_requirements_pass(self) -> None:
        completed = self.run_verifier(
            passing_artifact(),
            "--require-complete",
            "--require-canonical-provenance",
            "--require-output-match",
            "--require-exit-line",
        )
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertIn("PASS require-complete [required]", completed.stdout)
        self.assertIn("Overall: PASS (exit 0)", completed.stdout)

    def test_exit_line_is_opt_in_and_reports_concrete_ratios(self) -> None:
        artifact = passing_artifact()
        artifact["aggregate"]["p0_sentinel_geomean"] = (
            1.1524066349171431
        )
        artifact["aggregate"]["exit_line"].update(
            {
                "geomean_pass": False,
                "per_case_pass": False,
                "over_limit_cases": [
                    {
                        "name": "global_write_loop",
                        "ratio": 1.6889821098939986,
                    },
                    {"name": "fib_rec", "ratio": 1.347454778406315},
                ],
            }
        )

        advisory = self.run_verifier(artifact)
        self.assertEqual(advisory.returncode, 0, advisory.stdout)
        self.assertIn(
            "FAIL require-exit-line [not requested]", advisory.stdout
        )
        self.assertIn(
            "Overall: PASS (artifact parsed; policy checks not enforced)",
            advisory.stdout,
        )

        required = self.run_verifier(
            artifact, "--require-exit-line"
        )
        self.assertEqual(required.returncode, 1, required.stdout)
        self.assertIn(
            "geomean 1.1524 > limit 1.10", required.stdout
        )
        self.assertIn(
            "global_write_loop 1.6890 > 1.20", required.stdout
        )
        self.assertIn("fib_rec 1.3475 > 1.20", required.stdout)

    def test_incomplete_artifact_fails_closed(self) -> None:
        artifact = passing_artifact()
        artifact["aggregate"]["complete"] = False
        artifact["aggregate"]["missing_cases"] = [
            "typed_array_write"
        ]
        artifact["cases"] = artifact["cases"][:-1]

        completed = self.run_verifier(
            artifact, "--require-complete"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "aggregate.complete is not true", completed.stdout
        )
        self.assertIn(
            "missing P0 sentinel in cases: typed_array_write",
            completed.stdout,
        )

    def test_complete_requires_json_boolean_true(self) -> None:
        artifact = passing_artifact()
        artifact["aggregate"]["complete"] = "true"

        completed = self.run_verifier(
            artifact, "--require-complete"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "invalid field: aggregate.complete "
            "(expected boolean, got string)",
            completed.stdout,
        )

    def test_explicit_participants_cannot_omit_a_sentinel(self) -> None:
        artifact = passing_artifact()
        artifact["aggregate"]["participants"] = [
            {"name": name, "ratio": 1.0}
            for name in P0_SENTINELS[:-1]
        ]

        completed = self.run_verifier(
            artifact, "--require-complete"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "missing P0 sentinel in aggregate.participants: "
            "typed_array_write",
            completed.stdout,
        )

    def test_canonical_false_and_override_fail(self) -> None:
        artifact = passing_artifact()
        artifact["cases"][0]["canonical_source"] = False
        artifact["cases"][0]["case_shape"] = "overridden"
        artifact["case_sources"]["global_write_loop"] = (
            "/tmp/replacement.js"
        )

        completed = self.run_verifier(
            artifact, "--require-canonical-provenance"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "case global_write_loop canonical_source is not true",
            completed.stdout,
        )
        self.assertIn(
            "case global_write_loop has non-canonical case_shape: "
            "overridden",
            completed.stdout,
        )
        self.assertIn(
            "case_sources.global_write_loop overrides canonical source",
            completed.stdout,
        )

    def test_output_match_requires_status_and_checksum_evidence(
        self,
    ) -> None:
        artifact = passing_artifact()
        del artifact["cases"][0]["status"]
        artifact["cases"][1]["comparability"]["checksum"][
            "all_invocations_match"
        ] = False

        completed = self.run_verifier(
            artifact, "--require-output-match"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "missing field: cases[0].status", completed.stdout
        )
        self.assertIn(
            "case prop_read_mono_loop checksums do not match "
            "across all invocations",
            completed.stdout,
        )

    def test_explicit_checksum_not_required_is_allowed(self) -> None:
        artifact = passing_artifact()
        case = artifact["cases"][0]
        case["checksum_required"] = False
        case["checksum_requirement_declared"] = True
        del case["comparability"]["checksum"]

        completed = self.run_verifier(
            artifact, "--require-output-match"
        )
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertIn(
            "explicit checksum exemptions: global_write_loop",
            completed.stdout,
        )

    def test_null_checksum_requirement_is_not_a_pass(self) -> None:
        artifact = passing_artifact()
        artifact["cases"][0]["checksum_required"] = None

        completed = self.run_verifier(
            artifact, "--require-output-match"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "invalid field: cases[0].checksum_required "
            "(expected boolean, got null)",
            completed.stdout,
        )

    def test_missing_exit_line_reports_exact_field(self) -> None:
        artifact = passing_artifact()
        del artifact["aggregate"]["exit_line"]

        completed = self.run_verifier(
            artifact, "--require-exit-line"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "missing field: aggregate.exit_line", completed.stdout
        )

    def test_artifact_cannot_relax_fixed_exit_limits(self) -> None:
        artifact = passing_artifact()
        artifact["aggregate"]["p0_sentinel_geomean"] = 5.0
        artifact["aggregate"]["exit_line"].update(
            {
                "geomean_limit": 10.0,
                "per_case_limit": 10.0,
                "geomean_pass": True,
                "per_case_pass": True,
            }
        )

        completed = self.run_verifier(
            artifact, "--require-exit-line"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "expected policy limit 1.10", completed.stdout
        )
        self.assertIn(
            "expected policy limit 1.20", completed.stdout
        )
        self.assertIn(
            "geomean 5.0000 > limit 1.10", completed.stdout
        )

    def test_json_stdout_is_one_valid_document(self) -> None:
        completed = self.run_verifier(
            passing_artifact(), "--require-exit-line", "--json"
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        verdict = json.loads(completed.stdout)
        self.assertTrue(verdict["passed"])
        self.assertEqual(verdict["exit_code"], 0)
        self.assertEqual(completed.stderr, "")
        checks = {
            check["name"]: check for check in verdict["checks"]
        }
        self.assertTrue(checks["require-exit-line"]["requested"])

    def test_help_is_available(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(VERIFIER), "--help"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0)
        self.assertIn("--require-exit-line", completed.stdout)


if __name__ == "__main__":
    unittest.main()
