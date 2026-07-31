#!/usr/bin/env python3
"""Contract tests for the compile/first-run anchors and collector."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
GENERATOR = SCRIPT_DIR / "generate_anchors.py"
COLLECTOR = SCRIPT_DIR / "run_compile_first.py"
MANIFEST = SCRIPT_DIR / "manifest.json"

FAKE_HARNESS = """\
#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--case", required=True)
parser.add_argument("--source", required=True)
parser.add_argument("--iterations", type=int, required=True)
parser.add_argument("--warmup", type=int, required=True)
parser.add_argument("--teardown", required=True)
args = parser.parse_args()
engine = "qjs" if "qjs" in Path(__file__).name else "zjs"
source = Path(args.source).read_bytes()
mode = os.environ.get("FAKE_COMPILE_FIRST_MODE", "ok")
checksum = f"compile-first/{args.case}/v1"
if mode == "bad-checksum":
    checksum += "-wrong"
phases = {
    "compile_ns": 1_000 + len(source) * (3 if engine == "qjs" else 5),
    "first_execute_ns": 100 + len(source) * (1 if engine == "qjs" else 2),
}
if mode == "missing-phase":
    del phases["first_execute_ns"]
record = {
    "engine": engine,
    "layer": "same-runtime",
    "case": args.case,
    "source_sha256": hashlib.sha256(source).hexdigest(),
    "compiles": 1,
    "top_level_executions": 1,
    "build": {"mode": "contract-test"},
    "jsvalue_representation": {
        "size_bytes": 16,
        "nan_boxing": False,
    },
    "clock_monotonic_resolution_ns": 1,
    "teardown_mode": args.teardown,
    "iterations": args.iterations,
    "warmup": args.warmup,
    "result_checksum": checksum,
    "phase_definitions": {
        "compile_ns": "fake compile boundary",
        "first_execute_ns": "fake first execution boundary",
    },
    "phases": phases,
}
log_path = os.environ.get("FAKE_COMPILE_FIRST_LOG")
if log_path:
    with open(log_path, "a", encoding="utf-8") as log:
        log.write(f"{engine}:{args.case}\\n")
print(json.dumps(record))
"""


class CompileFirstContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.temp_path = Path(self.temporary.name)
        self.qjs_harness = self.temp_path / "qjs-harness"
        self.zjs_harness = self.temp_path / "zjs-harness"
        for harness in (self.qjs_harness, self.zjs_harness):
            harness.write_text(
                textwrap.dedent(FAKE_HARNESS), encoding="utf-8"
            )
            harness.chmod(0o755)

    def run_collector(
        self,
        *,
        manifest: Path = MANIFEST,
        mode: str = "ok",
    ) -> subprocess.CompletedProcess[str]:
        output = self.temp_path / f"{mode}-artifact.json"
        environment = os.environ.copy()
        environment["FAKE_COMPILE_FIRST_MODE"] = mode
        environment["FAKE_COMPILE_FIRST_LOG"] = str(
            self.temp_path / f"{mode}-calls.log"
        )
        return subprocess.run(
            [
                sys.executable,
                str(COLLECTOR),
                "--manifest",
                str(manifest),
                "--zjs-harness",
                str(self.zjs_harness),
                "--qjs-harness",
                str(self.qjs_harness),
                "--zjs-repo",
                str(REPO_ROOT),
                "--qjs-repo",
                str(REPO_ROOT),
                "--samples-per-engine",
                "2",
                "--output",
                str(output),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env=environment,
        )

    def test_checked_in_generation_is_byte_exact(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(GENERATOR), "--check"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertIn("4 generated anchors are byte-exact", completed.stdout)

        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        sizes = {
            anchor["name"]: anchor["source_bytes"]
            for anchor in manifest["anchors"]
        }
        self.assertEqual(sizes["linear-100k"], 100 * 1024)
        self.assertLessEqual(abs(sizes["linear-10k"] - 10 * 1024), 4)

    def test_collector_enforces_abba_and_emits_raw_points_and_regression(
        self,
    ) -> None:
        completed = self.run_collector()
        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )
        artifact_path = self.temp_path / "ok-artifact.json"
        artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
        self.assertEqual(artifact["measurement_classification"], "diagnostic-only")
        self.assertFalse(artifact["formal_claim_allowed"])
        self.assertEqual(artifact["sampling"]["order"], "ABBA")
        self.assertEqual(len(artifact["raw_points"]), 16)
        self.assertEqual(artifact["validation"]["status"], "passed")

        calls = (
            self.temp_path / "ok-calls.log"
        ).read_text(encoding="utf-8").splitlines()
        expected_anchor_order = [
            anchor["name"] for anchor in artifact["inputs"]["anchors"]
        ]
        expected_calls = []
        for anchor in expected_anchor_order:
            expected_calls.extend(
                (
                    f"qjs:{anchor}",
                    f"zjs:{anchor}",
                    f"zjs:{anchor}",
                    f"qjs:{anchor}",
                )
            )
        self.assertEqual(calls, expected_calls)

        qjs_hash = hashlib.sha256(self.qjs_harness.read_bytes()).hexdigest()
        zjs_hash = hashlib.sha256(self.zjs_harness.read_bytes()).hexdigest()
        self.assertEqual(
            artifact["inputs"]["harnesses"]["qjs"]["binary_sha256"],
            qjs_hash,
        )
        self.assertEqual(
            artifact["inputs"]["harnesses"]["zjs"]["binary_sha256"],
            zjs_hash,
        )
        self.assertTrue(
            artifact["inputs"]["harnesses"]["qjs"][
                "binary_unchanged_during_run"
            ]
        )
        self.assertAlmostEqual(
            artifact["regressions"]["qjs"]["compile_ns"]["regression"][
                "slope_ns_per_source_byte"
            ],
            3.0,
        )
        self.assertAlmostEqual(
            artifact["regressions"]["zjs"]["first_execute_ns"]["regression"][
                "slope_ns_per_source_byte"
            ],
            2.0,
        )

    def test_source_byte_tamper_fails_before_collection(self) -> None:
        generated = self.temp_path / "generated"
        completed = subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--output-dir",
                str(generated),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout)
        with (generated / "anchors/minimal.js").open(
            "ab"
        ) as tampered_source:
            tampered_source.write(b"\n")

        failed = self.run_collector(manifest=generated / "manifest.json")
        self.assertEqual(failed.returncode, 1)
        self.assertIn("source byte mismatch", failed.stderr)
        self.assertFalse(
            (self.temp_path / "ok-calls.log").exists(),
            "source validation must fail before invoking either harness",
        )

    def test_checksum_mismatch_fails_closed(self) -> None:
        completed = self.run_collector(mode="bad-checksum")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("result_checksum mismatch", completed.stderr)
        self.assertFalse(
            (self.temp_path / "bad-checksum-artifact.json").exists()
        )

    def test_missing_phase_fails_schema_validation(self) -> None:
        completed = self.run_collector(mode="missing-phase")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("phases.first_execute_ns", completed.stderr)
        self.assertFalse(
            (self.temp_path / "missing-phase-artifact.json").exists()
        )


if __name__ == "__main__":
    unittest.main()
