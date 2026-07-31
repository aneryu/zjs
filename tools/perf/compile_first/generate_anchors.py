#!/usr/bin/env python3
"""Generate deterministic ordinary-script compile/first-run anchors."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent

# Fixed-width local names keep the scalable part regular. The declaration
# counts intentionally stay well below QuickJS's per-function local limit.
ANCHOR_SPECS = (
    ("minimal", 0),
    ("tiny", 16),
    ("linear-10k", 466),
    ("linear-100k", 4_496),
)


def render_anchor(name: str, declaration_count: int) -> bytes:
    checksum = f"compile-first/{name}/v1"
    parts = ["function compilePayload() {\n"]
    for index in range(declaration_count):
        parts.append(f"  const v{index:05d} = {index};\n")
    parts.extend(
        (
            "  return 0;\n",
            "}\n",
            "function run() {\n",
            f'  return "{checksum}";\n',
            "}\n",
        )
    )
    return "".join(parts).encode("ascii")


def generated_files() -> tuple[dict[str, bytes], dict[str, object]]:
    files: dict[str, bytes] = {}
    anchors: list[dict[str, object]] = []
    for name, declaration_count in ANCHOR_SPECS:
        relative_path = f"anchors/{name}.js"
        source = render_anchor(name, declaration_count)
        files[relative_path] = source
        anchors.append(
            {
                "name": name,
                "relative_path": relative_path,
                "payload_declarations": declaration_count,
                "source_bytes": len(source),
                "source_sha256": hashlib.sha256(source).hexdigest(),
                "expected_checksum": f"compile-first/{name}/v1",
            }
        )

    manifest: dict[str, object] = {
        "schema_version": 1,
        "generator": "generate_anchors.py",
        "encoding": "ASCII",
        "line_endings": "LF",
        "shape": (
            "One uncalled function with linearly many fixed-width local const "
            "declarations, plus a constant-work global run() checksum function."
        ),
        "padding": "none",
        "anchors": anchors,
    }
    files["manifest.json"] = (
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    return files, manifest


def write_files(output_dir: Path) -> None:
    files, _ = generated_files()
    for relative_path, contents in files.items():
        destination = output_dir / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(contents)


def check_files(output_dir: Path) -> list[str]:
    files, _ = generated_files()
    errors: list[str] = []
    for relative_path, expected in files.items():
        destination = output_dir / relative_path
        if not destination.is_file():
            errors.append(f"missing generated file: {destination}")
            continue
        actual = destination.read_bytes()
        if actual != expected:
            errors.append(f"generated file differs: {destination}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=SCRIPT_DIR,
        help="directory containing manifest.json and anchors/ (default: script directory)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify checked-in bytes instead of writing them",
    )
    args = parser.parse_args()
    output_dir = args.output_dir.resolve()

    if args.check:
        errors = check_files(output_dir)
        if errors:
            for error in errors:
                print(f"error: {error}")
            return 1
        print(f"OK: {len(ANCHOR_SPECS)} generated anchors are byte-exact")
        return 0

    write_files(output_dir)
    print(f"wrote {len(ANCHOR_SPECS)} anchors and manifest to {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
