#!/usr/bin/env python3
"""Exercise default/explicit gate entry with an already-built real zjs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GateSmokeEntryTests(unittest.TestCase):
    def setUp(self):
        binary = Path(os.environ.get('ZJS_GATE_TEST_BINARY', ROOT / 'zig-out/bin/zjs')).resolve()
        if not binary.is_file():
            raise FileNotFoundError(f'Build zjs before running this test: {binary}')
        scratch = ROOT / '.scratch'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='gate-entry-', dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / 'tools/perf'
        scripts.mkdir(parents=True)
        for name in ('gate_smoke.sh', 'gate_smoke_check.py', 'measure_fields.py'):
            shutil.copy2(ROOT / 'tools/perf' / name, scripts / name)
        self.entry = scripts / 'gate_smoke.sh'
        self.binary = self.root / 'zig-out/bin/zjs'
        self.binary.parent.mkdir(parents=True)
        shutil.copy2(binary, self.binary)
        # Model an older artifact without modifying the workspace binary.
        os.utime(self.binary, (1, 1))
        (self.root / 'src').mkdir()
        (self.root / 'src/new.zig').write_text('// newer source\n')
        (self.root / 'build.zig').write_text('// build fixture\n')
        self.corpus = self.root / 'corpus'
        self.corpus.mkdir()
        (self.corpus / 'fixture.js').write_text('print("fixture");\n')
        self.env = dict(os.environ)
        self.env.pop('ZJS_GATE_PARALLEL_CPUS', None)
        self.env['ZJS_MEASURE_FIELD'] = 'b'
        self.cpu = str(min(os.sched_getaffinity(0)))

    def run_gate(self, *args):
        return subprocess.run(['bash', str(self.entry), *map(str, args)], cwd=self.root,
                              env=self.env, capture_output=True, text=True, timeout=30)

    def test_default_and_empty_binary_still_reject_stale_artifact(self):
        for args in ((), ('', self.corpus, self.cpu, '1')):
            result = self.run_gate(*args)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('older than', result.stderr)

    def test_explicit_artifact_runs_real_ordinary_and_audit_checks(self):
        result = self.run_gate(self.binary, self.corpus, self.cpu, '1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('fixed-work smoke: all clean', result.stdout)

    def test_parallel_mode_probes_on_the_parallel_list_not_the_placeholder_cpu(self):
        # The merge gate passes a placeholder positional CPU in parallel mode
        # (build/gates.zig). A host without that CPU must still run: the stats
        # probe pins to the parallel list, not the placeholder.
        env = dict(self.env)
        env['ZJS_GATE_PARALLEL_CPUS'] = self.cpu
        result = subprocess.run(['bash', str(self.entry), str(self.binary), str(self.corpus), '4095', '1'],
                                cwd=self.root, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('fixed-work smoke: all clean', result.stdout)

    def test_parallel_list_is_validated_before_the_stats_probe(self):
        env = dict(self.env)
        env['ZJS_GATE_PARALLEL_CPUS'] = 'not-a-list'
        result = subprocess.run(['bash', str(self.entry), str(self.binary), str(self.corpus), self.cpu, '1'],
                                cwd=self.root, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('ZJS_GATE_PARALLEL_CPUS must be a taskset CPU list', result.stderr)
        self.assertNotIn('does not emit the collector stats lines', result.stderr)

    def test_explicit_wrong_artifact_is_rejected_by_stats_probe(self):
        result = self.run_gate(shutil.which('true'), self.corpus, self.cpu, '1')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('does not emit the collector stats lines', result.stderr)

    def test_explicit_artifact_does_not_bypass_workload_failure(self):
        (self.corpus / 'fixture.js').write_text('throw new Error("gate fixture failure");\n')
        result = self.run_gate(self.binary, self.corpus, self.cpu, '1')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('FAIL fixture ordinary run', result.stdout)


if __name__ == '__main__':
    unittest.main()
