#!/usr/bin/env python3
"""Exercise the real test-fast graph and prove selections reuse one binary."""
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def run(*args):
    command = [
        "timeout", "1200", "flock", "-x", "/tmp/zjs-host-heavy.lock",
        "taskset", "-c", os.environ.get("ZJS_BUILD_CPUS", "5-8,15-18"),
        "zig", "build", "test-fast", "-j32", "--summary", "all", "--verbose",
    ]
    result = subprocess.run(command + ["--", *args], cwd=ROOT,
                            capture_output=True, text=True, timeout=1260)
    output = result.stdout + result.stderr
    paths = []
    for line in output.splitlines():
        if " --require-tests --skip-prefix tests.stress. --filter" in line:
            words = shlex.split(line)
            paths.append(words[words.index("--require-tests") - 1])
    return result.returncode, output, paths


def main():
    selected = [
        "synchronous native fence reuses one Machine and restores native cleanup order",
        "synchronous native reentry crosses Entry chunk boundaries exactly",
    ]
    artifacts = []
    for name in selected:
        code, output, paths = run(name)
        if code != 0 or "Summary: 1 passed; 0 skipped; 0 failed;" not in output:
            raise AssertionError(output)
        if len(paths) != 1 or not Path(paths[0]).is_file():
            raise AssertionError(f"missing actual runner command: {output}")
        artifacts.extend(paths)
    if len(set(artifacts)) != 1:
        raise AssertionError(f"runtime selections compiled different artifacts: {artifacts}")
    for args in [(), ("",), ("__zjs_test_fast_missing_20260907__",),
                 ("__zjs_test_fast_missing_20260907__", "--list")]:
        code, output, _ = run(*args)
        if code == 0:
            raise AssertionError(f"invalid/empty selection passed: {args}\n{output}")
        expected = "FAIL: test selection matched no tests." if len(args) == 1 and args[0] else "InvalidArgs"
        if expected not in output:
            raise AssertionError(output)
    print("PASS: two real single-test selections reuse one artifact; missing, empty, unmatched and list-only selections fail")


if __name__ == "__main__":
    main()
