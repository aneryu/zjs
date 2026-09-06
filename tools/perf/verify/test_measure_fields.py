#!/usr/bin/env python3
"""Contract tests for the measurement-field registry."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "measure_fields.py"
_spec = importlib.util.spec_from_file_location("measure_fields", MODULE_PATH)
fields = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
sys.modules[_spec.name] = fields
_spec.loader.exec_module(fields)


def isolated_launcher(root: Path) -> Path:
    """Copy the launcher onto private locks/CPUs for subprocess contract tests."""
    source = MODULE_PATH.read_text(encoding="utf-8")
    replacements = (
        ('HOST_LOCK = "/tmp/zjs-host-heavy.lock"', f"HOST_LOCK = {str(root / 'host.lock')!r}", 1),
        ('single_cpu=9,', "single_cpu=0,", 1),
        ('lock_path="/tmp/zjs-field-a.lock",', f"lock_path={str(root / 'field-a.lock')!r},", 1),
        # Field B and the whole-host field both use the canonical CPU19.
        ('single_cpu=19,', "single_cpu=1,", 2),
        ('lock_path="/tmp/zjs-field-b.lock",', f"lock_path={str(root / 'field-b.lock')!r},", 1),
    )
    for old, new, count in replacements:
        if source.count(old) != count:
            raise AssertionError(f"measure_fields fixture anchor drifted: {old}")
        source = source.replace(old, new)
    launcher = root / "measure_fields.py"
    launcher.write_text(source, encoding="utf-8")
    return launcher


class MeasureFieldTests(unittest.TestCase):
    def test_default_is_field_b_and_environment_can_select_a(self) -> None:
        self.assertEqual("b", fields.field_name(environ={}))
        self.assertEqual("a", fields.field_name(environ={"ZJS_MEASURE_FIELD": "a"}))

    def test_field_mapping_and_build_pool_are_exact(self) -> None:
        self.assertEqual((9,), fields.cpus_for(fields.FIELDS["a"], "single"))
        self.assertEqual((5, 6, 7, 8), fields.cpus_for(fields.FIELDS["a"], "topology"))
        self.assertEqual((19,), fields.cpus_for(fields.FIELDS["b"], "single"))
        self.assertEqual((15, 16, 17, 18), fields.cpus_for(fields.FIELDS["b"], "topology"))
        self.assertEqual((5, 6, 7, 8, 15, 16, 17, 18), fields.BUILD_CPUS)

    def test_host_is_exclusive_and_fields_use_shared_host_token(self) -> None:
        host = fields.field_metadata(fields.FIELDS["host"], "single")
        a = fields.field_metadata(fields.FIELDS["a"], "single")
        self.assertEqual("exclusive", host["hostTokenMode"])
        self.assertEqual("shared", a["hostTokenMode"])
        self.assertEqual(fields.HOST_LOCK, host["lock_path"])
        self.assertEqual(fields.HOST_LOCK, a["hostToken"])

    def test_explicit_cpu_override_is_compatible_but_not_field_conforming(self) -> None:
        field, cpu, conforming = fields.single_cpu("b", 17, {})
        self.assertEqual("b", field.name)
        self.assertEqual(17, cpu)
        self.assertFalse(conforming)
        _, canonical, conforming = fields.single_cpu("b", None, {})
        self.assertEqual(19, canonical)
        self.assertTrue(conforming)

    def test_invalid_field_and_layer_fail_closed(self) -> None:
        with self.assertRaises(ValueError):
            fields.field_name("c", {})
        with self.assertRaises(ValueError):
            fields.cpus_for(fields.FIELDS["a"], "wide")

    def test_lock_attestation_requires_real_inherited_descriptors(self) -> None:
        fake = {
            "ZJS_MEASURE_LOCK_HELD": "1",
            "ZJS_MEASURE_FIELD": "b",
            "ZJS_MEASURE_HOST_FD": "999999",
            "ZJS_MEASURE_FIELD_FD": "999998",
        }
        with mock.patch.dict(os.environ, fake, clear=True):
            self.assertFalse(fields.lock_attested(fields.FIELDS["b"]))

        with tempfile.TemporaryDirectory() as tmp:
            launcher = isolated_launcher(Path(tmp))
            code = (
                f"import sys; sys.path.insert(0, {str(launcher.parent)!r}); "
                "from measure_fields import FIELDS, lock_attested; "
                "print(lock_attested(FIELDS['b']))"
            )
            proc = subprocess.run(
                [
                    sys.executable,
                    str(launcher),
                    "run",
                    "--field",
                    "b",
                    "--layer",
                    "single",
                    "--",
                    sys.executable,
                    "-c",
                    code,
                ],
                capture_output=True,
                text=True,
                check=True,
                timeout=10,
            )
        self.assertEqual("True", proc.stdout.strip())

    def test_paired_command_separator_is_exact_and_fail_closed(self) -> None:
        left, right = fields.split_paired_commands(
            ["perf", "stat", "--", "left", ":::", "perf", "stat", "--", "right"]
        )
        self.assertEqual(["perf", "stat", "--", "left"], left)
        self.assertEqual(["perf", "stat", "--", "right"], right)
        for invalid in (
            [],
            ["left"],
            [":::", "right"],
            ["left", ":::"],
            ["left", ":::", "right", ":::", "extra"],
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                fields.split_paired_commands(invalid)

    def test_paired_simultaneous_uses_barrier_affinity_and_real_lock_fds(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            launcher = isolated_launcher(root)
            probe = (
                "import json, os, sys, time; "
                f"sys.path.insert(0, {str(root)!r}); "
                "from measure_fields import FIELDS, lock_attested; "
                "name = os.environ['ZJS_MEASURE_FIELD']; "
                "print(json.dumps({'field': name, "
                "'affinity': sorted(os.sched_getaffinity(0)), "
                "'attested': lock_attested(FIELDS[name]), "
                "'paired': os.environ.get('ZJS_MEASURE_PAIRED_SIMULTANEOUS')})); "
                "time.sleep(0.1)"
            )
            output = root / "paired.json"
            proc = subprocess.run(
                [
                    sys.executable,
                    str(launcher),
                    "run",
                    "--paired-simultaneous",
                    "--paired-output",
                    str(output),
                    "--paired-role-a",
                    "candidate",
                    "--paired-role-b",
                    "baseline",
                    "--",
                    sys.executable,
                    "-c",
                    probe,
                    ":::",
                    sys.executable,
                    "-c",
                    probe,
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(0, proc.returncode, proc.stderr)
            artifact = json.loads(output.read_text())

        self.assertEqual("paired-simultaneous", artifact["mode"])
        self.assertEqual("exclusive", artifact["hostTokenMode"])
        self.assertEqual(2, artifact["barrier"]["readyCount"])
        self.assertLess(artifact["synchrony"]["startDeltaNs"], 50_000_000)
        self.assertGreater(artifact["synchrony"]["overlapNs"], 0)
        for name, cpu, role in (("a", 0, "candidate"), ("b", 1, "baseline")):
            arm = artifact["arms"][name]
            self.assertEqual(cpu, arm["cpu"])
            self.assertEqual(role, arm["role"])
            self.assertEqual([cpu], arm["effectiveAffinity"])
            self.assertEqual(0, arm["exitCode"])
            probe_result = json.loads(arm["stdout"].strip())
            self.assertEqual(name, probe_result["field"])
            self.assertEqual([cpu], probe_result["affinity"])
            self.assertTrue(probe_result["attested"])
            self.assertEqual("1", probe_result["paired"])

    def test_paired_simultaneous_preserves_failure_artifact_and_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            launcher = isolated_launcher(root)
            output = root / "failed-pair.json"
            proc = subprocess.run(
                [
                    sys.executable,
                    str(launcher),
                    "run",
                    "--paired-simultaneous",
                    "--paired-output",
                    str(output),
                    "--",
                    sys.executable,
                    "-c",
                    "raise SystemExit(7)",
                    ":::",
                    sys.executable,
                    "-c",
                    "print('peer-complete')",
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(1, proc.returncode, proc.stderr)
            artifact = json.loads(output.read_text())
        self.assertEqual(7, artifact["arms"]["a"]["exitCode"])
        self.assertEqual(0, artifact["arms"]["b"]["exitCode"])
        self.assertEqual("peer-complete", artifact["arms"]["b"]["stdout"].strip())


if __name__ == "__main__":
    unittest.main()
