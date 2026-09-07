#!/usr/bin/env python3
"""Run nightly's Unix contract checks on stripped and deliberately failing CLIs."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    workflow = (ROOT / ".github/workflows/nightly.yml").read_text().splitlines()
    checks = []
    for index, line in enumerate(workflow):
        if 'expected="$(cat zig-out/bin/zjs.config-signature)"' in line:
            checks.append("\n".join(part.strip() for part in workflow[index:index + 3]))
    if len(checks) != 2:
        raise AssertionError("missing Linux/macOS release contract checks")
    scratch = ROOT / ".scratch"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch, prefix="release-contract-") as temp:
        directory = Path(temp)
        bindir = directory / "zig-out/bin"
        bindir.mkdir(parents=True)
        binary = bindir / "zjs"
        sidecar = bindir / "zjs.config-signature"
        shutil.copy2(ROOT / "zig-out/bin/zjs", binary)
        shutil.copy2(ROOT / "zig-out/bin/zjs.config-signature", sidecar)
        subprocess.run(["strip", str(binary)], check=True, timeout=30)

        def check(expected_success):
            for shell in checks:
                result = subprocess.run(["bash", "-e", "-c", shell], cwd=directory,
                                        capture_output=True, text=True, timeout=30)
                if (result.returncode == 0) != expected_success:
                    raise AssertionError(f"exit={result.returncode}\n{result.stdout}\n{result.stderr}")

        check(True)
        expected = sidecar.read_text()
        sidecar.write_text("stale-config\n")
        check(False)
        sidecar.write_text(expected)
        # A failing process can print the expected signature. Its exit code
        # must fail the check even when the string equality would succeed.
        binary.write_text('#!/bin/sh\ncat zig-out/bin/zjs.config-signature\nexit 7\n')
        binary.chmod(0o755)
        check(False)
        sidecar.unlink()
        check(False)
    print("PASS: real stripped CLI matches build expectation; stale/missing expectation and failing CLI are rejected")


if __name__ == "__main__":
    main()
