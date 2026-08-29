#!/usr/bin/env python3
"""Assert every vendored bench-v8 benchmark still COMPLETES on this engine.

This is a correctness gate, not a measurement. It exists because the test
suites did not catch a whole class of collector defect: with the tracing
collector at `test262 0/49778` and the unit suites green, nine of the fifteen
vendored Octane benchmarks still failed outright -- three with a segfault, five
with `InvalidBuiltinRegistry`, one with `TypeError: not a function`. Every one
of them was a live object being reclaimed by a minor collection.

test262 cases are small and short-lived, so almost none of them survive long
enough to be promoted out of the young generation. A macro benchmark builds a
large, long-lived object graph and then keeps mutating it, which is precisely
the shape that exercises the generational write barrier. That is the coverage
this gate adds, and the reason a passing test262 does not imply it.

Each benchmark runs on its own so a failure names itself, and the combined
suite runs last because some defects only appear once the heap is large.

Usage:  check_completes.py <zjs-binary> [--timeout SECONDS]
Exit:   0 if every benchmark completes, 1 otherwise.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from run_benchv8_compare import SUITE_ORDER, build_combined

# `base.js` is the harness the others are written against, not a benchmark.
BENCHMARKS = [name for name in SUITE_ORDER if name != "base.js"]

RESULT_RE = re.compile(r"^([A-Za-z]+): (-?\d+(?:\.\d+)?)$")
SCORE_RE = re.compile(r"^Score \(version \d+\): (\d+(?:\.\d+)?)$")


def build_subset(suite_dir: Path, driver: Path, out: Path, names: list[str]) -> None:
    """Same concatenation `build_combined` does, restricted to `names`.

    `base.js` always leads: the benchmark bodies call into it.
    """
    parts = [(suite_dir / "base.js").read_text()]
    parts.extend((suite_dir / name).read_text() for name in names)
    parts.append(driver.read_text())
    out.write_text("\n".join(parts))


def run(binary: Path, script: Path, timeout: int) -> tuple[bool, str]:
    """Run one script. Returns (completed, detail).

    "Completed" means the process exited 0 AND printed at least one result
    line. A benchmark that exits 0 having printed nothing has not run, and a
    result line carrying `ERROR` is the harness reporting its own failure.
    """
    try:
        proc = subprocess.run(
            [str(binary), str(script)],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, f"timed out after {timeout}s"

    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout).strip().splitlines()
        detail = tail[-1] if tail else "no output"
        # A crash is worth distinguishing from a thrown JS error: the first is
        # always an engine defect, the second may be a missing feature.
        if proc.returncode < 0:
            return False, f"killed by signal {-proc.returncode}: {detail[:120]}"
        return False, f"exit {proc.returncode}: {detail[:120]}"

    results = []
    for line in proc.stdout.splitlines():
        stripped = line.strip()
        if "ERROR" in stripped:
            return False, f"harness error: {stripped[:120]}"
        if RESULT_RE.match(stripped) or SCORE_RE.match(stripped):
            results.append(stripped)
    if not results:
        return False, "exited 0 but printed no result line"
    return True, results[-1]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("binary", nargs="?", default="zig-out/bin/zjs")
    ap.add_argument("--timeout", type=int, default=300)
    args = ap.parse_args()

    binary = Path(args.binary).resolve()
    here = Path(__file__).resolve().parent
    suite_dir = here / "suite"
    driver = here / "driver.js"

    if not binary.is_file():
        print(f"check_completes: no such binary: {binary}", file=sys.stderr)
        return 1

    failures: list[tuple[str, str]] = []
    print(f"bench-v8 completion check: {binary}")

    for name in BENCHMARKS + ["<combined>"]:
        with tempfile.NamedTemporaryFile(suffix=".js", delete=False) as tf:
            script = Path(tf.name)
        try:
            if name == "<combined>":
                build_combined(suite_dir, driver, script)
            else:
                build_subset(suite_dir, driver, script, [name])
            ok, detail = run(binary, script, args.timeout)
        finally:
            script.unlink(missing_ok=True)

        print(f"  {'ok  ' if ok else 'FAIL'}  {name:<18} {detail}")
        if not ok:
            failures.append((name, detail))

    if failures:
        print(
            f"\ncheck_completes: {len(failures)} of {len(BENCHMARKS) + 1} did not complete",
            file=sys.stderr,
        )
        for name, detail in failures:
            print(f"  {name}: {detail}", file=sys.stderr)
        return 1

    print(f"\ncheck_completes: all {len(BENCHMARKS) + 1} completed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
