#!/usr/bin/env python3
"""Check already-built production/size CLIs without recompiling the engine.

Build once with `zig build zjs zjs-size -Doptimize=ReleaseSmall`, then run
this script. Override --experiment-mode when checking another codegen mode.
"""

import argparse
from pathlib import Path
import subprocess


def run(binary: Path, *args: str) -> str:
    result = subprocess.run(
        [str(binary.resolve()), *args], capture_output=True, text=True, timeout=30,
        check=True,
    )
    if result.stderr:
        raise AssertionError(f"{binary}: unexpected stderr: {result.stderr}")
    return result.stdout.strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--production", type=Path, default=Path("zig-out/bin/zjs"))
    parser.add_argument("--experiment", type=Path, default=Path("zig-out/bin/zjs-size"))
    parser.add_argument("--experiment-mode", default="ReleaseSmall",
                        choices=("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"))
    args = parser.parse_args()
    production_signature = run(args.production, "--print-config-signature")
    sidecar = args.production.with_name("zjs.config-signature").read_text().strip()
    if production_signature != sidecar:
        raise AssertionError(f"production differs from build expectation: {production_signature} != {sidecar}")
    if ",optimize=ReleaseFast," not in production_signature:
        raise AssertionError(f"production mode was changed: {production_signature}")
    expected = production_signature.replace(
        ",optimize=ReleaseFast,", f",optimize={args.experiment_mode},"
    )
    actual = run(args.experiment, "--print-config-signature")
    if actual != expected:
        raise AssertionError(f"experimental mode was ignored or config drifted: {actual} != {expected}")
    script = 'const f = x => x * 2; const a = [1, 2, 3].map(f); if (a.join(",") !== "2,4,6") throw Error("map"); print(JSON.stringify(a));'
    for binary in (args.production, args.experiment):
        if run(binary, "-e", script) != "[2,4,6]":
            raise AssertionError(f"{binary}: JavaScript smoke output differs")
    print(f"PASS: production ReleaseFast and experimental {args.experiment_mode}; signatures and execution")


if __name__ == "__main__":
    main()
