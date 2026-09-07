#!/usr/bin/env python3
"""Real ELF fixtures exercise the size screen; no engine build required."""
import argparse
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

import size_screen as screen


@unittest.skipUnless(shutil.which('cc') and shutil.which('strip') and shutil.which('readelf'), 'requires C compiler and binutils')
class SizeScreenTests(unittest.TestCase):
    def setUp(self):
        scratch = Path(__file__).resolve().parents[2] / '.scratch'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='size-screen-test-', dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        (self.repo / 'a.c').write_text('int original;\n')
        subprocess.run(['git', 'add', '.'], cwd=self.repo, check=True)
        subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'initial'], cwd=self.repo, check=True)

    def snapshot(self, name, mode='ReleaseFast'):
        out = self.root / name
        out.mkdir()
        source = out / 'fixture.c'
        source.write_text('#include <stdio.h>\nchar bss[65536];\n'
                          '__attribute__((section(".text.zjs.op_handlers"), noinline)) int opcode(void) { return bss[0]; }\n'
                          'int main(void) { puts("zjs-config-v3:compiler=v2,optimize=' + mode + '"); return opcode(); }\n')
        binary = out / 'fixture'
        subprocess.run(['cc', '-g', '-Wl,--unique=.text.zjs.op_handlers', str(source), '-o', str(binary)], check=True)
        (out / 'build.log').write_text('real C fixture compile\n')
        provenance = {'zig_version': 'fixture', 'strip_version': 'fixture', 'native_target': 'fixture',
                      'build_log_sha256': screen.digest((out / 'build.log').read_bytes())}
        screen.seal(out, binary, screen.inventory(self.repo), provenance, mode)
        return out

    def test_real_elf_sections_and_strip(self):
        out = self.snapshot('base')
        report = screen.load_snapshot(out)
        self.assertEqual(screen.run([str(out / 'binary'), '--print-config-signature']).decode().strip(), report['config'])
        self.assertEqual(screen.run([str(out / 'binary.stripped'), '--print-config-signature']).decode().strip(), report['config'])
        sections = report['stripped']['sections']
        self.assertTrue(any(s['name'] == '.text.zjs.op_handlers' and 'X' in s['flags'] for s in sections))
        self.assertTrue(any(s['type'] == 'NOBITS' and s['disk_bytes'] == 0 and s['memory_bytes'] >= 65536 for s in sections))
        self.assertLess(report['stripped']['file_bytes'], report['original_bytes'])
        self.assertEqual(report['stripped']['section_disk_bytes'] + report['stripped']['headers_padding_other_bytes'], report['stripped']['file_bytes'])

    def test_reuse_requires_owned_matching_inputs(self):
        report = screen.load_snapshot(self.snapshot('reuse'))
        source = screen.inventory(self.repo)
        reasons = screen.current_mismatches(report, source, 'ReleaseFast', 'fixture', 'fixture')
        self.assertIn('snapshot lacks successful owned-build provenance', reasons)
        # Exercise the provenance predicate separately from the real ELF/hash checks.
        report['provenance'].update(build_exit=0, build_step='zjs',
                                    source_evidence='owned build, identical inventories before and after')
        self.assertEqual(screen.current_mismatches(report, source, 'ReleaseFast', 'fixture', 'fixture'), [])
        for mode, version, target, reason in [
            ('ReleaseSmall', 'fixture', 'fixture', 'build mode differs'),
            ('ReleaseFast', 'different', 'fixture', 'Zig version differs'),
            ('ReleaseFast', 'fixture', 'different', 'native target differs'),
        ]:
            self.assertIn(reason, screen.current_mismatches(report, source, mode, version, target))
        original = (self.repo / 'a.c').read_bytes()
        (self.repo / 'a.c').write_bytes(original + b'// edit\n')
        self.assertIn('repository content differs', screen.current_mismatches(
            report, screen.inventory(self.repo), 'ReleaseFast', 'fixture', 'fixture'))
        (self.repo / 'a.c').write_bytes(original)
        self.assertEqual(screen.current_mismatches(report, screen.inventory(self.repo), 'ReleaseFast', 'fixture', 'fixture'), [])
        dirty = dict(source, files=[{'kind': 'submodule', 'status': ' M a.zig'}])
        self.assertIn('dirty submodule contents are not fully hashed', screen.current_mismatches(
            report, dirty, 'ReleaseFast', 'fixture', 'fixture'))

    def test_changed_deleted_and_untracked_source(self):
        old = screen.inventory(self.repo)
        (self.repo / 'a.c').unlink()
        (self.repo / 'new.zig').write_text('// one\n\n')
        new = screen.inventory(self.repo)
        self.assertNotEqual(old['content_sha256'], new['content_sha256'])
        self.assertTrue(next(f for f in new['files'] if f['path'] == 'a.c')['deleted'])
        self.assertEqual(new['totals']['other_source']['physical_lines'], 2)
        self.assertTrue(new['status'])

    def test_compare_stop_config_and_identity(self):
        base = self.snapshot('base')
        candidate = self.snapshot('candidate', 'ReleaseSmall')
        args = argparse.Namespace(baseline=base, candidate=candidate, allow_cross_config=False,
                                  objective='binary', min_bytes=1, min_lines=None, source_category=None)
        with self.assertRaisesRegex(ValueError, 'Configurations differ'):
            screen.compare(args)
        args.allow_cross_config = True
        with contextlib.redirect_stdout(io.StringIO()) as output:
            result = screen.compare(args)
        self.assertEqual(result, 3)
        result = json.loads(output.getvalue())
        self.assertEqual(result['screen'], 'STOP')
        self.assertEqual(result['stripped_bytes_delta'],
                         sum(result['section_disk_bytes_delta'].values()) + result['headers_padding_other_bytes_delta'])
        frozen = candidate / 'binary'
        frozen.chmod(0o644)
        frozen.write_bytes(frozen.read_bytes() + b'corruption')
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            screen.load_snapshot(candidate)

    def test_source_objective_and_manifest_tamper(self):
        base = self.snapshot('base')
        (self.repo / 'a.c').unlink()
        candidate = self.snapshot('candidate')
        args = argparse.Namespace(baseline=base, candidate=candidate, allow_cross_config=False,
                                  objective='source', min_bytes=None, min_lines=1, source_category=['other_source'])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(screen.compare(args), 0)
        manifest = candidate / 'manifest.json'
        manifest.chmod(0o644)
        manifest.write_bytes(manifest.read_bytes() + b' ')
        with self.assertRaisesRegex(ValueError, 'Manifest identity mismatch'):
            screen.load_snapshot(candidate)

    def test_source_categories_exclude_test_and_generated(self):
        self.assertEqual(screen.category('src/libs/unicode/data.zig'), 'generated')
        self.assertEqual(screen.category('src/abi/fun_native_abi.h'), 'generated')
        self.assertEqual(screen.category('src/abi/fun_native_abi.zig'), 'engine')
        self.assertEqual(screen.category('src/exec_tests.zig'), 'tests')
        self.assertEqual(screen.category('src/compiler/test_entry.zig'), 'tests')
        self.assertEqual(screen.category('src/exec/call.zig'), 'engine')

    def test_source_precheck_cli_without_compiler(self):
        src = self.repo / 'src'
        src.mkdir()
        (src / 'candidate.zig').write_text('const unused = 1;\n' * 20)
        (src / 'tests').mkdir()
        (src / 'tests' / 'only_test.zig').write_text('// test\n' * 30)
        base = self.snapshot('base')
        # Only Git is available to the child. Neither compiler, binutils,
        # nor a shell can be invoked through PATH during the precheck.
        path = self.root / 'git-only'
        path.mkdir()
        (path / 'git').symlink_to(shutil.which('git'))
        env = {**os.environ, 'PATH': str(path)}
        command = [sys.executable, str(Path(screen.__file__).resolve()),
                   'precheck-source', str(base), '--repo', str(self.repo), '--min-lines', '20']
        # Deleting tests cannot make the default engine objective pass.
        (src / 'tests' / 'only_test.zig').unlink()
        stopped = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(stopped.returncode, 3, stopped.stderr)
        self.assertEqual(json.loads(stopped.stdout)['screen'], 'STOP')
        (src / 'candidate.zig').unlink()
        passed = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(passed.returncode, 0, passed.stderr)
        result = json.loads(passed.stdout)
        self.assertEqual(result['source_physical_lines_delta']['engine'], -20)
        self.assertEqual(result['source_physical_lines_delta']['tests'], -30)
        self.assertEqual(result['candidate_source_sha256'], screen.inventory(self.repo)['content_sha256'])
        self.assertNotIn('stripped_bytes_delta', result)
        invalid = subprocess.run(command[:-1] + ['0'], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(invalid.returncode, 2)
        # Frozen identity corruption must fail even though no build is requested.
        manifest = base / 'manifest.json'
        manifest.chmod(0o644)
        manifest.write_bytes(manifest.read_bytes() + b' ')
        invalid = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(invalid.returncode, 2)
        self.assertIn('identity mismatch', invalid.stderr)

    def test_native_target_mismatch(self):
        base = self.snapshot('base')
        candidate = self.snapshot('candidate')
        manifest = candidate / 'manifest.json'
        data = json.loads(manifest.read_bytes())
        data['provenance']['native_target'] = 'different CPU features'
        manifest.chmod(0o644)
        manifest.write_bytes(screen.encoded(data))
        checksum = candidate / 'manifest.sha256'
        checksum.chmod(0o644)
        checksum.write_text(screen.digest(manifest.read_bytes()) + '\n')
        args = argparse.Namespace(baseline=base, candidate=candidate)
        with self.assertRaisesRegex(ValueError, 'Native codegen targets differ'):
            screen.compare(args)

    def test_reject_wrong_mode(self):
        out = self.snapshot('base')
        other = self.root / 'wrong-mode'
        other.mkdir()
        with self.assertRaisesRegex(ValueError, 'optimization signature'):
            screen.seal(other, out / 'fixture', screen.inventory(self.repo), {}, 'ReleaseSmall')

    def test_build_timeout_retains_log_and_kills_group(self):
        out = self.root / 'timeout'
        out.mkdir()
        child = 'import time; time.sleep(30)'
        parent = ('import subprocess,sys,time; '
                  'p=subprocess.Popen([sys.executable,"-c",' + repr(child) + ']); '
                  'print(p.pid,flush=True); time.sleep(30)')
        with self.assertRaisesRegex(ValueError, 'process group timed out'):
            screen.build_capture([sys.executable, '-c', parent], self.repo, out, timeout_seconds=0.2)
        pid = int((out / 'build.log').read_text().strip())
        status = Path('/proc') / str(pid) / 'status'
        if status.exists():
            state = next(line for line in status.read_text().splitlines() if line.startswith('State:'))
            self.assertIn('Z (zombie)', state)  # killed; awaiting the host reaper

    def test_build_normal_exit_retains_output_and_restores_handlers(self):
        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        for code in (0, 7):
            out = self.root / f'exit-{code}'
            out.mkdir()
            result, output = screen.build_capture(
                [sys.executable, '-c', f'print("build output", flush=True); raise SystemExit({code})'],
                self.repo, out,
            )
            self.assertEqual(result, code)
            self.assertEqual(output, b'build output\n')
            self.assertEqual((out / 'build.log').read_bytes(), output)
            self.assertEqual(handlers, {sig: signal.getsignal(sig) for sig in handlers})

    def test_build_cleanup_deadline_retains_log_and_reports_incomplete(self):
        out = self.root / 'cleanup-deadline'
        out.mkdir()
        child_pid = out / 'detached.pid'
        parent = (
            'import subprocess,sys,time; from pathlib import Path; '
            'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"], '
            'start_new_session=True); '
            f'Path({str(child_pid)!r}).write_text(str(p.pid)); '
            'print("output before cancellation",flush=True); time.sleep(60)'
        )
        # A detached descendant retains the pipe beyond the supervised group's
        # death. Cleanup must stop waiting and preserve the partial diagnostics.
        started = time.monotonic()
        try:
            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                with self.assertRaisesRegex(ValueError, 'process group timed out'):
                    screen.build_capture([sys.executable, '-c', parent], self.repo, out,
                                         timeout_seconds=0.5)
            self.assertLess(time.monotonic() - started, 10)
            self.assertIn('cleanup incomplete after 5 seconds', stderr.getvalue())
            self.assertEqual((out / 'build.log').read_bytes(), b'output before cancellation\n')
        finally:
            if child_pid.exists():
                try:
                    os.killpg(int(child_pid.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_build_cancellation_reaps_group_releases_lock_and_retains_log(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                out = self.root / f'cancel-{signum}'
                out.mkdir()
                lock_path = out / 'build.lock'
                parent_pid = out / 'parent.pid'
                child_pid = out / 'child.pid'
                # The grandchild ignores cooperative cancellation and has no
                # inherited output pipe, but still owns the build lock.
                child = (
                    'import fcntl,os,signal,time; from pathlib import Path; '
                    'signal.signal(signal.SIGINT, signal.SIG_IGN); '
                    'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                    f'lock=open({str(lock_path)!r},"a"); fcntl.flock(lock,fcntl.LOCK_EX); '
                    f'Path({str(child_pid)!r}).write_text(str(os.getpid())); time.sleep(60)'
                )
                parent = (
                    'import os,subprocess,sys,time; from pathlib import Path; '
                    f'Path({str(parent_pid)!r}).write_text(str(os.getpid())); '
                    f'subprocess.Popen([sys.executable,"-c",{child!r}], '
                    'stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); '
                    'print("build started",flush=True); time.sleep(60)'
                )
                driver = (
                    'import sys; from pathlib import Path; '
                    f'sys.path.insert(0,{str(Path(screen.__file__).parent)!r}); '
                    'import size_screen; '
                    f'size_screen.build_capture([sys.executable,"-c",{parent!r}], '
                    f'Path({str(self.repo)!r}),Path({str(out)!r}),timeout_seconds=30)'
                )
                proc = subprocess.Popen([sys.executable, '-c', driver], start_new_session=True,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 5
                    while not child_pid.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(child_pid.exists(), 'grandchild did not acquire lock')
                    with open(lock_path, 'a') as lock:
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        os.killpg(proc.pid, signum)
                        stdout, stderr = proc.communicate(timeout=5)
                        self.assertEqual(proc.returncode, 128 + signum, (stdout, stderr))
                        deadline = time.monotonic() + 5
                        while True:
                            try:
                                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                                break
                            except BlockingIOError:
                                if time.monotonic() >= deadline:
                                    self.fail('cancelled build descendant retained lock')
                                time.sleep(0.01)
                    self.assertIn(b'build started\n', (out / 'build.log').read_bytes())
                    for path in (parent_pid, child_pid):
                        stat = Path('/proc') / path.read_text() / 'stat'
                        deadline = time.monotonic() + 5
                        while True:
                            try:
                                state = stat.read_text().rsplit(')', 1)[1].split()[0]
                            except FileNotFoundError:
                                break
                            if state in ('Z', 'X'):
                                break
                            if time.monotonic() >= deadline:
                                self.fail('cancelled build process is still running')
                            time.sleep(0.01)
                finally:
                    if parent_pid.exists():
                        try:
                            os.killpg(int(parent_pid.read_text()), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    if proc.poll() is None:
                        proc.kill()
                    proc.communicate(timeout=5)

    def test_reject_non_elf(self):
        path = self.root / 'text'
        path.write_text('not an ELF')
        with self.assertRaisesRegex(ValueError, 'ELF64'):
            screen.elf_sections(path)


if __name__ == '__main__':
    unittest.main()
