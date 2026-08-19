#!/usr/bin/env python3
"""Run the vendored bench-v8 suite once on a single engine (diagnostic).

No pinning, no comparison — a smoke/diagnostic entry for `zig build
perf-bench-v8`. Official comparisons go through run_benchv8_compare.py.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

from run_benchv8_compare import SUITE_ORDER, build_combined


def main() -> int:
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zjs")
    here = Path(__file__).resolve().parent
    with tempfile.NamedTemporaryFile(suffix=".js", delete=False) as tf:
        combined = Path(tf.name)
    try:
        build_combined(here / "suite", here / "driver.js", combined)
        return subprocess.run([str(binary), str(combined)]).returncode
    finally:
        combined.unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())
