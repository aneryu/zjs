#!/usr/bin/env python3
"""Debounced, per-build host locking for finite build commands.

Unlike wrapping Zig --watch in flock, this releases the host lock while idle.
Disk build caches remain reusable; the in-memory incremental compiler does not.
Additional input trees outside the repository need explicit --path arguments.
"""
import argparse
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

DEFAULT_PATHS = ('src', 'build', 'tests', 'tools', 'policies', 'build.zig',
                 'build.zig.zon', 'mise.toml', 'test262.conf')

IGNORED = {'.git', '.zig-cache', 'zig-out', '.scratch', '__pycache__',
           'node_modules', 'test262', '.venv'}


def snapshot(paths):
    """Metadata detects additions, removals, atomic saves, and same-size edits."""
    result = {}
    for path in paths:
        entries = [path]
        if path.is_dir():
            entries = []
            for root, dirs, files in os.walk(path):
                dirs[:] = [d for d in dirs if d not in IGNORED]
                entries.extend(Path(root) / name for name in files)
        for entry in entries:
            try:
                st = entry.stat()
                result[str(entry)] = (st.st_ino, st.st_size, st.st_mtime_ns,
                                      st.st_ctime_ns)
            except FileNotFoundError:
                # Editors may replace/remove a file during the scan.
                continue
    return result


def group_is_running(pgid):
    # Linux host tool: a zombie has finished executing and cannot consume the
    # measurement CPUs. Waiting for PID 1 to reap orphan zombies could hang.
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
        except (FileNotFoundError, ProcessLookupError):
            continue
        if int(fields[2]) == pgid and fields[0] not in ('Z', 'X'):
            return True
    return False


def stop_group(proc):
    # Also stop descendants when a failed build driver exited before its children.
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=0.3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()
    # SIGKILL delivery is asynchronous. Keep the host lock until every group
    # member has stopped, including grandchildren whose parent already exited.
    while group_is_running(proc.pid):
        time.sleep(0.01)


def watch(command, paths, lock_path, interval, debounce, build_timeout, lock_timeout):
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    old_handlers = {sig: signal.signal(sig, stop)
                    for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with open(lock_path, 'a') as lock:
            previous = snapshot(paths)
            pending = True  # Always build once at startup.
            changed_at = 0.0
            waiting_since = None
            while not stopping:
                current = snapshot(paths)
                if current != previous:
                    previous = current
                    pending = True
                    changed_at = time.monotonic()
                if not pending or time.monotonic() - changed_at < debounce:
                    time.sleep(interval)
                    continue
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    if waiting_since is None:
                        waiting_since = time.monotonic()
                    if time.monotonic() - waiting_since >= lock_timeout:
                        raise TimeoutError("host lock acquisition timed out")
                    time.sleep(interval)
                    continue
                try:
                    waiting_since = None
                    if stopping:
                        break
                    # Freeze immediately before launch; edits while building are
                    # detected on the next iteration and schedule another build.
                    previous = snapshot(paths)
                    pending = False
                    print('[watch] build started (host lock held)', flush=True)
                    proc = subprocess.Popen(command, start_new_session=True)
                    try:
                        deadline = time.monotonic() + build_timeout
                        while proc.poll() is None and not stopping:
                            if time.monotonic() >= deadline:
                                print('[watch] build timed out', file=sys.stderr,
                                      flush=True)
                                break
                            time.sleep(min(interval, 0.1))
                    finally:
                        stop_group(proc)
                finally:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                print(f'[watch] build exited {proc.returncode}; idle '
                      '(host lock released)', flush=True)
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--path', action='append', type=Path,
                        help='input file/tree (repeatable); default: ' + ', '.join(DEFAULT_PATHS))
    parser.add_argument('--lock', default='/tmp/zjs-host-heavy.lock')
    parser.add_argument('--interval', type=float, default=0.5)
    parser.add_argument('--debounce', type=float, default=0.2)
    parser.add_argument('--build-timeout', type=float, default=1200)
    parser.add_argument('--lock-timeout', type=float, default=1200)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ['--']:
        command = command[1:]
    if not command:
        parser.error('finite build command required after --')
    if any(arg in ('--watch', '--webui', '--fuzz') or
           arg.startswith(('--webui=', '--fuzz=')) for arg in command):
        parser.error('command must exit after one build; resident modes hold the lock')
    if args.interval <= 0 or args.debounce < 0 or args.build_timeout <= 0 or args.lock_timeout <= 0:
        parser.error('interval/timeout must be positive; debounce must be non-negative')
    try:
        return watch(command, args.path or [Path(p) for p in DEFAULT_PATHS], args.lock,
                     args.interval, args.debounce, args.build_timeout, args.lock_timeout)
    except (OSError, TimeoutError) as exc:
        print(f"[watch] {exc}", file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
