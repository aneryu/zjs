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
RUNNER = VERIFY_DIR.parent / "same_runtime" / "run_same_runtime.js"
POLICY_PATH = VERIFY_DIR.parent / "same_runtime" / "policy.json"
POLICY = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
P0_SENTINELS = tuple(
    sentinel["name"] for sentinel in POLICY["sentinels"]
)
GEOMEAN_LIMIT = POLICY["exit_line"]["geomean_limit"]
PER_CASE_LIMIT = POLICY["exit_line"]["per_case_limit"]
GEOMEAN_LIMIT_TEXT = f"{GEOMEAN_LIMIT:.2f}"
PER_CASE_LIMIT_TEXT = f"{PER_CASE_LIMIT:.2f}"


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
        # The verifier re-derives the exit line from these ratios instead of
        # trusting aggregate. A fixture with an empty paired_ratios cannot
        # satisfy --require-exit-line, and should not: an artifact carrying no
        # recomputable evidence must not pass on its own say-so.
        "paired_ratios": {
            "steady_execute_median_ns": {"median": 1.0},
        },
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
        "policy": {
            "policy_id": POLICY["policy_id"],
            "policy_version": POLICY["policy_version"],
        },
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
        "status_counts": {
            "ok": len(P0_SENTINELS),
            "mismatch": 0,
            "invalid": 0,
        },
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
                "geomean_limit": GEOMEAN_LIMIT,
                "per_case_limit": PER_CASE_LIMIT,
                "geomean_pass": True,
                "per_case_pass": True,
                "over_limit_cases": [],
            },
            "pmu": {"instructions": {}},
        },
        "cases": cases,
    }


def passing_harness_record() -> dict:
    return {
        "engine": "qjs",
        "layer": "same-runtime",
        "case": P0_SENTINELS[0],
        "source_sha256": "a" * 64,
        "compiles": 1,
        "top_level_executions": 1,
        "build": {"mode": "release"},
        "jsvalue_representation": {
            "size_bytes": 16,
            "nan_boxing": False,
        },
        "teardown_mode": "normal",
        "iterations": 1,
        "warmup": 0,
        "result_checksum": "same",
        "phases": {
            "eval_total_ns": 100,
            "promise_jobs_ns": 11,
            "final_job_drain_ns": 7,
            "job_drain_ns": 18,
        },
        "resources": {},
        "steady_execute": {
            "samples_ns": [10],
            "median_ns": 10,
        },
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
            "--require-policy-declaration",
            "--require-complete",
            "--require-canonical-provenance",
            "--require-output-match",
            "--require-exit-line",
        )
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertIn("PASS require-complete [required]", completed.stdout)
        self.assertIn("Overall: PASS (exit 0)", completed.stdout)

    def test_policy_identity_mismatch_is_explicit_and_opt_in(self) -> None:
        artifact = passing_artifact()
        artifact["policy"] = {
            "policy_id": "forged-policy",
            "policy_version": POLICY["policy_version"] + 1,
        }

        advisory = self.run_verifier(artifact)
        self.assertEqual(advisory.returncode, 0, advisory.stdout)
        self.assertIn(
            "FAIL require-policy-declaration [not requested]",
            advisory.stdout,
        )
        self.assertIn(
            "does not match checked-in policy_id", advisory.stdout
        )
        self.assertIn(
            "does not match checked-in policy_version", advisory.stdout
        )

        required = self.run_verifier(
            artifact, "--require-policy-declaration"
        )
        self.assertEqual(required.returncode, 1, required.stdout)

    def test_missing_policy_uses_explicit_legacy_path(self) -> None:
        artifact = passing_artifact()
        del artifact["policy"]

        advisory = self.run_verifier(artifact)
        self.assertEqual(advisory.returncode, 0, advisory.stdout)
        self.assertIn("policy declaration: absent", advisory.stdout)
        self.assertIn(
            "explicit legacy compatibility path", advisory.stdout
        )

        required = self.run_verifier(
            artifact, "--require-policy-declaration"
        )
        self.assertEqual(required.returncode, 1, required.stdout)
        self.assertIn(
            "artifact has no policy declaration", required.stdout
        )

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
                        "name": P0_SENTINELS[0],
                        "ratio": 1.6889821098939986,
                    },
                    {
                        "name": P0_SENTINELS[2],
                        "ratio": 1.347454778406315,
                    },
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
            f"geomean 1.1524 > limit {GEOMEAN_LIMIT_TEXT}",
            required.stdout,
        )
        self.assertIn(
            f"{P0_SENTINELS[0]} 1.6890 > {PER_CASE_LIMIT_TEXT}",
            required.stdout,
        )
        self.assertIn(
            f"{P0_SENTINELS[2]} 1.3475 > {PER_CASE_LIMIT_TEXT}",
            required.stdout,
        )

    def test_incomplete_artifact_fails_closed(self) -> None:
        artifact = passing_artifact()
        artifact["aggregate"]["complete"] = False
        missing_sentinel = P0_SENTINELS[-1]
        artifact["aggregate"]["missing_cases"] = [missing_sentinel]
        artifact["cases"] = artifact["cases"][:-1]

        completed = self.run_verifier(
            artifact, "--require-complete"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "aggregate.complete is not true", completed.stdout
        )
        self.assertIn(
            f"missing P0 sentinel in cases: {missing_sentinel}",
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
            f"{P0_SENTINELS[-1]}",
            completed.stdout,
        )

    def test_canonical_false_and_override_fail(self) -> None:
        artifact = passing_artifact()
        first_sentinel = P0_SENTINELS[0]
        artifact["cases"][0]["canonical_source"] = False
        artifact["cases"][0]["case_shape"] = "overridden"
        artifact["case_sources"][first_sentinel] = (
            "/tmp/replacement.js"
        )

        completed = self.run_verifier(
            artifact, "--require-canonical-provenance"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            f"case {first_sentinel} canonical_source is not true",
            completed.stdout,
        )
        self.assertIn(
            f"case {first_sentinel} has non-canonical case_shape: "
            "overridden",
            completed.stdout,
        )
        self.assertIn(
            f"case_sources.{first_sentinel} overrides canonical source",
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
            f"case {P0_SENTINELS[1]} checksums do not match "
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
            f"explicit checksum exemptions: {P0_SENTINELS[0]}",
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

    def test_artifact_cannot_launder_its_own_exit_line(self) -> None:
        """Rewriting aggregate while cases[] keep failing ratios must fail.

        The policy identity and both limits stay honest here; only the
        self-reported conclusions are forged. A gate that reads the audited
        object's own verdict is not a gate.
        """
        artifact = passing_artifact()
        failing = P0_SENTINELS[0]
        for case in artifact["cases"]:
            if case["name"] == failing:
                case["paired_ratios"]["steady_execute_median_ns"][
                    "median"
                ] = 1.90
        # aggregate still claims everything passed.
        completed = self.run_verifier(artifact, "--require-exit-line")
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("cases recompute to", completed.stdout)
        self.assertIn(
            f"recomputed {failing}", completed.stdout
        )

    def test_missing_case_ratios_cannot_pass_exit_line(self) -> None:
        artifact = passing_artifact()
        artifact["cases"][0]["paired_ratios"] = {}
        completed = self.run_verifier(artifact, "--require-exit-line")
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("cannot recompute exit line", completed.stdout)

    def test_over_limit_case_list_must_match_recomputation(self) -> None:
        artifact = passing_artifact()
        artifact["aggregate"]["exit_line"]["over_limit_cases"] = [
            {"name": P0_SENTINELS[1], "ratio": 1.5}
        ]
        artifact["aggregate"]["exit_line"]["per_case_pass"] = False
        completed = self.run_verifier(artifact, "--require-exit-line")
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("but cases recompute to", completed.stdout)

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
            f"expected policy limit {GEOMEAN_LIMIT_TEXT}",
            completed.stdout,
        )
        self.assertIn(
            f"expected policy limit {PER_CASE_LIMIT_TEXT}",
            completed.stdout,
        )
        self.assertIn(
            f"geomean 5.0000 > limit {GEOMEAN_LIMIT_TEXT}",
            completed.stdout,
        )

    def test_artifact_policy_limits_are_ignored(self) -> None:
        artifact = passing_artifact()
        artifact["policy"]["exit_line"] = {
            "geomean_limit": 10.0,
            "per_case_limit": 10.0,
        }
        artifact["aggregate"]["p0_sentinel_geomean"] = 5.0
        artifact["aggregate"]["exit_line"]["geomean_pass"] = True

        completed = self.run_verifier(
            artifact, "--require-exit-line"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "artifact policy declaration has unsupported field(s): "
            "exit_line; policy definitions are ignored",
            completed.stdout,
        )
        self.assertIn(
            f"geomean 5.0000 > limit {GEOMEAN_LIMIT_TEXT}",
            completed.stdout,
        )

    def test_artifact_policy_sentinel_set_is_ignored(self) -> None:
        artifact = passing_artifact()
        missing_sentinel = P0_SENTINELS[-1]
        artifact["policy"]["sentinels"] = list(P0_SENTINELS[:-1])
        artifact["cases"] = artifact["cases"][:-1]
        artifact["requested_cases"] = list(P0_SENTINELS[:-1])
        artifact["case_sources"].pop(missing_sentinel)

        completed = self.run_verifier(
            artifact, "--require-complete"
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn(
            "artifact policy declaration has unsupported field(s): "
            "sentinels; policy definitions are ignored",
            completed.stdout,
        )
        self.assertIn(
            f"missing P0 sentinel in cases: {missing_sentinel}",
            completed.stdout,
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

    def test_runner_phase_comparability_is_explicit_and_fail_closed(
        self,
    ) -> None:
        expected = {
            "runtime_create_ns": True,
            "compile_ns": True,
            "first_execute_ns": True,
            "eval_total_ns": True,
            "realm_raw_create_ns": False,
            "realm_bootstrap_ns": False,
            "realm_ready_ns": False,
            "compile_frontend_ns": False,
            "compile_finalize_ns": False,
            "parse_ns": False,
            "root_function_publish_ns": False,
            "vm_run_ns": False,
            "engine_cold_to_first_result_ns": False,
            "promise_jobs_ns": False,
            "final_job_drain_ns": False,
            "job_drain_ns": False,
            "__future_unknown_phase_ns": False,
        }
        metadata = {}
        for name in expected:
            completed = subprocess.run(
                [
                    "node",
                    str(RUNNER),
                    "--describe-phase",
                    name,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(
                completed.returncode,
                0,
                f"{name}: {completed.stderr}",
            )
            metadata[name] = json.loads(completed.stdout)
        self.assertEqual(
            {
                name: entry["comparable"]
                for name, entry in metadata.items()
            },
            expected,
        )
        self.assertIn(
            "not registered",
            metadata["__future_unknown_phase_ns"]["reason"],
        )
        self.assertIn(
            "Do not use this ratio as a hard parity gate",
            metadata["first_execute_ns"]["note"],
        )
        self.assertFalse(
            metadata["eval_total_ns"]["parity_gate_eligible"]
        )
        self.assertIn(
            "Do not use this ratio as a hard parity gate",
            metadata["eval_total_ns"]["note"],
        )
        self.assertIn(
            "parse_ns equals compile_ns",
            metadata["parse_ns"]["note"],
        )

    def test_runner_requires_split_job_drain_schema_and_sum(self) -> None:
        path = self.temp_path / "harness-record.json"

        def validate(record: dict) -> subprocess.CompletedProcess[str]:
            path.write_text(
                json.dumps(record) + "\n",
                encoding="utf-8",
            )
            return subprocess.run(
                [
                    "node",
                    str(RUNNER),
                    "--validate-record",
                    str(path),
                ],
                text=True,
                capture_output=True,
                check=False,
            )

        valid = validate(passing_harness_record())
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertTrue(json.loads(valid.stdout)["valid"])

        missing = passing_harness_record()
        del missing["phases"]["promise_jobs_ns"]
        invalid = validate(missing)
        self.assertEqual(invalid.returncode, 1, invalid.stderr)
        self.assertIn(
            "phases.promise_jobs_ns is required",
            invalid.stdout,
        )

        inconsistent = passing_harness_record()
        inconsistent["phases"]["job_drain_ns"] = 19
        invalid = validate(inconsistent)
        self.assertEqual(invalid.returncode, 1, invalid.stderr)
        self.assertIn(
            "phases.job_drain_ns must equal",
            invalid.stdout,
        )

    def test_runner_help_declares_external_affinity_and_explicit_pmu(
        self,
    ) -> None:
        completed = subprocess.run(
            ["node", str(RUNNER), "--help"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("never\nchanges affinity", completed.stdout)
        self.assertIn("--pmu", completed.stdout)
        self.assertIn("--no-pmu", completed.stdout)
        self.assertNotIn("CPU passed to taskset", completed.stdout)


if __name__ == "__main__":
    unittest.main()
