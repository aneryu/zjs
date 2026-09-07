#!/usr/bin/env python3
"""Scheduling regressions; stubs intentionally test orchestration, not Zig."""
import importlib.util
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

WATCH = Path(__file__).with_name('watch.py').resolve()


def eventually(check, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if check():
            return
        time.sleep(0.02)
    raise AssertionError('condition did not become true')


class WatchTest(unittest.TestCase):
    def setUp(self):
        scratch = Path(__file__).resolve().parents[2] / '.scratch'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch, prefix='watch-test-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'input.zig'
        self.source.write_text('initial')
        self.lock = open(self.root / 'host.lock', 'a')
        self.log = open(self.root / 'output', 'w+')
        self.proc = None

    def tearDown(self):
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        self.lock.close()
        self.log.close()
        self.temp.cleanup()

    def launch(self, script, extra=()):
        driver = self.root / 'driver.py'
        driver.write_text(script)
        self.proc = subprocess.Popen([
            sys.executable, str(WATCH), '--path', str(self.source),
            '--lock', self.lock.name, '--interval', '.02', '--debounce', '.04',
            *extra, '--', sys.executable, str(driver)], cwd=self.root,
            stdout=self.log, stderr=subprocess.STDOUT)

    def output(self):
        return (self.root / 'output').read_text()

    def count(self):
        path = self.root / 'runs'
        return len(path.read_text().splitlines()) if path.exists() else 0

    def lock_available(self):
        try:
            fcntl.flock(self.lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        return True

    def test_idle_releases_and_external_measurement_blocks_build(self):
        self.launch("from pathlib import Path\nwith open('runs','a') as f: f.write('run\\n')\n")
        eventually(lambda: 'idle' in self.output())
        self.assertTrue(self.lock_available())
        fcntl.flock(self.lock, fcntl.LOCK_SH)
        self.source.write_text('modified')
        time.sleep(.2)
        self.assertEqual(self.count(), 1)
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        eventually(lambda: self.count() == 2)

    def test_edit_during_build_and_failure_waits_for_next_edit(self):
        self.launch("import time\nwith open('runs','a') as f: f.write('run\\n')\ntime.sleep(.25)\nraise SystemExit(1)\n")
        eventually(lambda: self.count() == 1)
        self.assertFalse(self.lock_available())
        self.source.write_text('changed during build')
        eventually(lambda: self.count() == 2)
        eventually(lambda: self.output().count('idle') == 2)
        time.sleep(.15)
        self.assertEqual(self.count(), 2)
        self.source.write_text('retry failed build')
        eventually(lambda: self.count() == 3)

    def test_signal_and_timeout_kill_descendants_before_unlock(self):
        for use_timeout in (False, True):
            with self.subTest(timeout=use_timeout):
                child = self.root / 'child'
                child.unlink(missing_ok=True)
                self.launch("import subprocess,sys,time\nfrom pathlib import Path\np=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'])\nPath('child').write_text(str(p.pid))\ntime.sleep(60)\n",
                            ('--build-timeout', '.2') if use_timeout else ())
                eventually(child.exists)
                pid = int(child.read_text())
                self.assertFalse(self.lock_available())
                if use_timeout:
                    eventually(lambda: 'timed out' in self.output())
                    eventually(self.lock_available)
                else:
                    self.proc.send_signal(signal.SIGTERM)
                    self.proc.wait(timeout=5)
                    self.assertTrue(self.lock_available())
                # Orphan zombies may await PID 1 reaping, but cannot execute.
                def child_stopped():
                    stat = Path(f'/proc/{pid}/stat')
                    return not stat.exists() or stat.read_text().split()[2] == 'Z'
                self.assertTrue(child_stopped())
                if self.proc.poll() is None:
                    self.proc.terminate()
                    self.proc.wait(timeout=5)

    def test_lock_wait_is_bounded_and_signal_interruptible(self):
        fcntl.flock(self.lock, fcntl.LOCK_SH)
        self.launch("raise AssertionError('must not run')", ('--lock-timeout', '.1'))
        self.assertEqual(self.proc.wait(timeout=5), 1)
        self.assertIn('lock acquisition timed out', self.output())
        self.launch("raise AssertionError('must not run')")
        time.sleep(.1)
        self.proc.terminate()
        self.assertEqual(self.proc.wait(timeout=5), 0)

    def test_default_inputs_exclude_generated_reports_and_worktrees(self):
        spec = importlib.util.spec_from_file_location('watch', WATCH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue({'src', 'build', 'tools', 'tests', 'build.zig',
                         'build.zig.zon', 'mise.toml', 'test262.conf'} <=
                        set(module.DEFAULT_PATHS))
        self.assertFalse({'reports', '.scratch', '.claude', 'zig-out',
                          '.zig-cache', 'test262'} & set(module.DEFAULT_PATHS))

    def test_reject_resident_command(self):
        result = subprocess.run([sys.executable, str(WATCH), '--',
                                 'zig', 'build', '--watch'], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b'command must exit', result.stderr)


if __name__ == '__main__':
    unittest.main()
