#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


VERIFY_DIR = Path(__file__).resolve().parent
RUNNER = VERIFY_DIR.parent / "same_runtime" / "run_zjs_cold_ab.js"


NUMERIC_PHASES = {
    "runtime_create_ns": 100,
    "context_create_ns": 200,
    "realm_raw_create_ns": 20,
    "realm_bootstrap_ns": 170,
    "realm_ready_ns": 200,
    "compile_ns": 300,
    "parse_ns": 300,
    "compile_frontend_ns": 180,
    "compile_finalize_ns": 110,
    "root_function_publish_ns": 40,
    "first_execute_ns": 240,
    "vm_run_ns": 190,
    "promise_jobs_ns": 10,
    "final_job_drain_ns": 20,
    "engine_cold_to_first_result_ns": 900,
    "eval_total_ns": 550,
    "job_drain_ns": 30,
}


def write_fake_harness(
    path: Path,
    *,
    role: str,
    factor: int,
    missing_phase: str | None = None,
    unknown_phase: bool = False,
    stderr_text: str = "",
    checksum: str = "same-result",
    break_job_sum: bool = False,
    mutate_self: bool = False,
) -> None:
    config = {
        "role": role,
        "factor": factor,
        "missing_phase": missing_phase,
        "unknown_phase": unknown_phase,
        "stderr_text": stderr_text,
        "checksum": checksum,
        "break_job_sum": break_job_sum,
        "mutate_self": mutate_self,
        "numeric_phases": NUMERIC_PHASES,
    }
    script = f"""#!/usr/bin/env python3
import hashlib
import json
import os
import sys

CONFIG = json.loads({json.dumps(json.dumps(config))})
args = sys.argv[1:]
values = {{}}
for index in range(0, len(args), 2):
    values[args[index]] = args[index + 1]
source = open(values["--source"], "rb").read()
phases = {{
    name: value * CONFIG["factor"]
    for name, value in CONFIG["numeric_phases"].items()
}}
phases.update({{
    "globals_install_ns": None,
    "context_destroy_ns": None,
    "runtime_destroy_ns": None,
}})
if CONFIG["break_job_sum"]:
    phases["job_drain_ns"] += 1
if CONFIG["missing_phase"] is not None:
    phases.pop(CONFIG["missing_phase"], None)
if CONFIG["unknown_phase"]:
    phases["future_phase_ns"] = 77 * CONFIG["factor"]
log = os.environ.get("COLD_AB_TEST_LOG")
if log:
    with open(log, "a", encoding="utf-8") as handle:
        handle.write(CONFIG["role"] + "\\n")
if CONFIG["stderr_text"]:
    sys.stderr.write(CONFIG["stderr_text"])
record = {{
    "engine": "zjs",
    "layer": "same-runtime",
    "case": values["--case"],
    "source_sha256": hashlib.sha256(source).hexdigest(),
    "compiles": 1,
    "top_level_executions": 1,
    "teardown_mode": values["--teardown"],
    "iterations": int(values["--iterations"]),
    "warmup": int(values["--warmup"]),
    "result_checksum": CONFIG["checksum"],
    "build": {{
        "mode": "ReleaseFast",
        "optimize_mode_enum": 3,
    }},
    "jsvalue_representation": {{
        "size_bytes": 16,
        "nan_boxing": False,
        "description": "contract test",
    }},
    "phases": phases,
    "steady_execute": {{
        "samples_ns": [123],
        "median_ns": 123,
    }},
}}
if CONFIG["mutate_self"]:
    with open(__file__, "a", encoding="utf-8") as handle:
        handle.write("\\n# changed during collection\\n")
print(json.dumps(record))
"""
    path.write_text(script, encoding="utf-8")
    path.chmod(0o755)


class ColdABRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "case.js"
        self.source.write_text(
            "function run() { return 1; }\n",
            encoding="utf-8",
        )
        self.baseline = self.root / "baseline"
        self.candidate = self.root / "candidate"
        self.output = self.root / "out" / "summary.json"
        self.log = self.root / "order.log"

    def run_runner(
        self,
        *,
        samples: int = 4,
        baseline_options: dict | None = None,
        candidate_options: dict | None = None,
        include_identities: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        write_fake_harness(
            self.baseline,
            role="baseline",
            factor=1,
            **(baseline_options or {}),
        )
        write_fake_harness(
            self.candidate,
            role="candidate",
            factor=2,
            **(candidate_options or {}),
        )
        environment = os.environ.copy()
        environment["COLD_AB_TEST_LOG"] = str(self.log)
        identity_args = []
        if include_identities:
            baseline_identity = self.root / "baseline.identity.json"
            candidate_identity = self.root / "candidate.identity.json"
            baseline_identity.write_text(
                json.dumps(
                    {
                        "binary_sha256": hashlib.sha256(
                            self.baseline.read_bytes()
                        ).hexdigest(),
                        "global_normalized_signature": "a" * 64,
                    }
                ),
                encoding="utf-8",
            )
            candidate_identity.write_text(
                json.dumps(
                    {
                        "binary_sha256": hashlib.sha256(
                            self.candidate.read_bytes()
                        ).hexdigest(),
                        "global_normalized_signature": "b" * 64,
                    }
                ),
                encoding="utf-8",
            )
            identity_args = [
                "--baseline-identity",
                str(baseline_identity),
                "--candidate-identity",
                str(candidate_identity),
            ]
        return subprocess.run(
            [
                "node",
                str(RUNNER),
                "--baseline",
                str(self.baseline),
                "--candidate",
                str(self.candidate),
                "--case",
                "fixture",
                "--source",
                str(self.source),
                "--samples",
                str(samples),
                "--output",
                str(self.output),
                *identity_args,
            ],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def test_abba_order_paths_hashes_and_phase_statistics(self) -> None:
        completed = self.run_runner()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        artifact = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(artifact["protocol"]["sampling_order"], "ABBA")
        self.assertEqual(artifact["protocol"]["pair_count"], 4)
        self.assertEqual(
            [pair["order"] for pair in artifact["raw_pairs"]],
            [
                ["baseline", "candidate"],
                ["candidate", "baseline"],
                ["baseline", "candidate"],
                ["candidate", "baseline"],
            ],
        )
        self.assertEqual(
            self.log.read_text(encoding="utf-8").splitlines(),
            [
                "baseline",
                "candidate",
                "candidate",
                "baseline",
                "baseline",
                "candidate",
                "candidate",
                "baseline",
            ],
        )
        for role, harness in [
            ("baseline", self.baseline),
            ("candidate", self.candidate),
        ]:
            metadata = artifact["artifacts"][role]
            self.assertEqual(metadata["path"], str(harness.resolve()))
            self.assertEqual(
                metadata["sha256"],
                hashlib.sha256(harness.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                metadata["post_run_sha256"],
                metadata["sha256"],
            )
            self.assertTrue(metadata["unchanged_during_collection"])
        self.assertEqual(
            artifact["source"]["post_run_sha256"],
            artifact["source"]["sha256"],
        )
        self.assertTrue(
            artifact["source"]["unchanged_during_collection"]
        )
        baseline = artifact["endpoint_phase_statistics_ns"]["baseline"]
        candidate = artifact["endpoint_phase_statistics_ns"]["candidate"]
        self.assertEqual(baseline["realm_bootstrap_ns"]["median"], 170)
        self.assertEqual(candidate["realm_bootstrap_ns"]["median"], 340)
        ratio = artifact["paired_candidate_over_baseline"][
            "realm_bootstrap_ns"
        ]
        self.assertEqual(ratio["status"], "paired")
        self.assertEqual(
            (
                ratio["stats"]["p25"],
                ratio["stats"]["median"],
                ratio["stats"]["p75"],
            ),
            (2, 2, 2),
        )
        self.assertFalse(
            artifact["diagnostic_scope"]["formal_comparison"]
        )
        self.assertIsNone(
            artifact["diagnostic_scope"][
                "build_state_equivalence_conclusion"
            ]
        )
        if sys.platform == "darwin":
            self.assertEqual(
                artifact["affinity"]["status"],
                "unavailable",
            )
            self.assertFalse(artifact["affinity"]["pinned"])

    def test_identity_metadata_is_attested_without_equivalence_conclusion(
        self,
    ) -> None:
        completed = self.run_runner(include_identities=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        artifact = json.loads(self.output.read_text(encoding="utf-8"))
        baseline = artifact["artifacts"]["baseline"]["identity"]
        candidate = artifact["artifacts"]["candidate"]["identity"]
        self.assertEqual(baseline["global_normalized_signature"], "a" * 64)
        self.assertEqual(candidate["global_normalized_signature"], "b" * 64)
        self.assertTrue(baseline["binary_sha256_matches_harness"])
        self.assertTrue(candidate["binary_sha256_matches_harness"])
        self.assertIn(
            "no build-state equivalence conclusion",
            baseline["interpretation"],
        )
        self.assertIsNone(
            artifact["diagnostic_scope"][
                "build_state_equivalence_conclusion"
            ]
        )

    def test_unknown_phase_is_retained_raw_only(self) -> None:
        completed = self.run_runner(
            baseline_options={"unknown_phase": True},
            candidate_options={"unknown_phase": True},
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        artifact = json.loads(self.output.read_text(encoding="utf-8"))
        unknown = artifact["paired_candidate_over_baseline"][
            "future_phase_ns"
        ]
        self.assertEqual(unknown["status"], "raw-only")
        self.assertIsNone(unknown["stats"])
        self.assertEqual(
            artifact["endpoint_phase_statistics_ns"]["candidate"][
                "future_phase_ns"
            ]["median"],
            154,
        )
        self.assertEqual(
            artifact["raw_pairs"][0]["invocations"][0]["record"]["phases"][
                "future_phase_ns"
            ],
            77,
        )

    def test_missing_realm_phase_fails_closed(self) -> None:
        completed = self.run_runner(
            candidate_options={"missing_phase": "realm_bootstrap_ns"}
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn(
            "phases.realm_bootstrap_ns is required",
            completed.stderr,
        )
        self.assertFalse(self.output.exists())

    def test_job_drain_sum_fails_closed(self) -> None:
        completed = self.run_runner(
            baseline_options={"break_job_sum": True}
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn(
            "job_drain_ns must equal promise_jobs_ns + final_job_drain_ns",
            completed.stderr,
        )

    def test_nonempty_stderr_fails_closed(self) -> None:
        completed = self.run_runner(
            candidate_options={"stderr_text": "diagnostic noise\n"}
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("wrote non-empty stderr", completed.stderr)

    def test_harness_change_during_collection_fails_closed(self) -> None:
        completed = self.run_runner(
            candidate_options={"mutate_self": True}
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn(
            "candidate invocation 1 harness changed during collection",
            completed.stderr,
        )
        self.assertFalse(self.output.exists())

    def test_checksum_mismatch_fails_closed(self) -> None:
        completed = self.run_runner(
            candidate_options={"checksum": "different"}
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("result_checksum mismatch", completed.stderr)

    def test_odd_sample_count_is_rejected(self) -> None:
        completed = self.run_runner(samples=3)
        self.assertEqual(completed.returncode, 2)
        self.assertIn(
            "--samples must be a positive even integer",
            completed.stderr,
        )
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
