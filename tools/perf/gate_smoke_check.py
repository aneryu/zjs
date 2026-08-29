#!/usr/bin/env python3
"""Validate fixed-work smoke GC terminal state and optional expectations.

The optional JSON expectation file has this shape::

    {
      "benchmarks": {
        "regexp": {
          "source_sha256": "...",
          "stdout_regex": "^RegExp: [0-9]+$",
          "gc": {
            "retirement_commits": {"min": 1},
            "committed_live_milli": {"max": 5000}
          }
        }
      }
    }

By default every corpus script must have an entry. Set
``"require_all_benchmarks": false`` for a deliberately partial manifest.
Scalar GC expectations mean exact equality; ``{"min": N, "max": N}``
expresses an inclusive range. Built-in safety invariants are always enforced.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


RETIREMENT_RE = re.compile(
    r"^gc: major retirement commits (\d+), abandons (\d+), current state ([a-z_]+)$"
)
TERMINAL_RE = re.compile(r"^gc: terminal doomed_pending (true|false)$")
BLOCK_RE = re.compile(
    r"^gc: block heap committed (\d+) live (\d+) committed/live-x1000 (\d+) "
    r"superblocks (\d+) large maps (\d+)$"
)


class CheckFailure(ValueError):
    pass


def _one_match(pattern: re.Pattern[str], lines: list[str], label: str) -> re.Match[str]:
    matches = [match for line in lines if (match := pattern.fullmatch(line))]
    if len(matches) != 1:
        raise CheckFailure(f"expected exactly one {label} line, found {len(matches)}")
    return matches[0]


# `gc_block_heap.zig:20 superblock_bytes`. The reservation granularity of the
# block heap, and therefore the floor under `committed_bytes`.
BLOCK_HEAP_SUPERBLOCK_BYTES = 2 * 1024 * 1024


def parse_output(text: str, max_committed_live_milli: int) -> tuple[dict[str, Any], str]:
    lines = text.splitlines()
    retirement = _one_match(RETIREMENT_RE, lines, "retirement")
    terminal = _one_match(TERMINAL_RE, lines, "terminal doomed_pending")
    block = _one_match(BLOCK_RE, lines, "block heap")

    values: dict[str, Any] = {
        "retirement_commits": int(retirement.group(1)),
        "retirement_abandons": int(retirement.group(2)),
        "retirement_state": retirement.group(3),
        "doomed_pending": terminal.group(1) == "true",
        "committed_bytes": int(block.group(1)),
        "live_bytes": int(block.group(2)),
        "committed_live_milli": int(block.group(3)),
        "superblocks": int(block.group(4)),
        "large_maps": int(block.group(5)),
    }

    if values["retirement_abandons"] != 0:
        raise CheckFailure(
            f"retirement abandons is {values['retirement_abandons']}, expected 0"
        )
    if values["retirement_state"] != "clean":
        raise CheckFailure(
            f"retirement state is {values['retirement_state']}, expected clean"
        )
    if values["doomed_pending"]:
        raise CheckFailure("terminal doomed_pending is true")
    if values["committed_bytes"] < values["live_bytes"]:
        raise CheckFailure("block heap committed bytes is below live bytes")

    live = values["live_bytes"]
    committed = values["committed_bytes"]
    expected_milli = 0 if live == 0 else (committed * 1000 + live - 1) // live
    if values["committed_live_milli"] != expected_milli:
        raise CheckFailure(
            "block heap milli does not match committed/live: "
            f"printed {values['committed_live_milli']}, computed {expected_milli}"
        )
    # The ratio is a FRAGMENTATION check, and the denominator needs a floor of
    # one superblock for it to measure fragmentation at all.
    #
    # `committed` has a hard 2 MiB granularity: the block heap reserves whole
    # superblocks (gc_block_heap.zig:20 `superblock_bytes`, :1876/:1886), so a
    # run holding a single live cell still reports >= 2 MiB committed. Below
    # one superblock the quotient therefore reports the size of the LIVE SET,
    # not any allocator behaviour, and it moves hardest exactly when the live
    # set shrinks -- i.e. it fails on improvements.
    #
    # Booked instance (obj64 knife (3), 2026-08-29): raytrace's committed FELL
    # 2,097,152 -> 2,035,712 B (-2.9%) while the printed ratio rose 4739 ->
    # 52882 milli, because `live` at exit fell 442,592 -> 38,496 B. That number
    # is not the live set: in both arms live-at-exit ~= the young set, i.e.
    # "objects allocated since the last major" (base young=6962 vs
    # live-cells=6914; candidate young=515 vs live-cells=757). Allocating 9.6%
    # fewer payload bytes moved the small-heap-floor major schedule (3510 ->
    # 3104 majors), so the run simply ended at a different distance from its
    # last collection. Every other benchmark moved only ~30-45%, which is what
    # a ~25% object shrink predicts; raytrace's 11x was the artifact alone.
    # Independent evidence that the unfloored quantity was not measuring the
    # allocator: on ONE binary, deltablue's audit run reports a bit-identical
    # `committed` of 1,974,272 B on every run while the printed ratio wanders
    # 5058 / 5431 / 5851 milli -- all of the variance is in a sub-superblock
    # `live`. Under the floor all three read 942.
    #
    # The floor only ever relaxes the check (it appears in the denominator), and
    # only below one superblock. It does not blind the gate there: the test
    # degenerates to `committed <= limit * one superblock`, which still fails a
    # run that reserved dozens of superblocks while holding almost nothing --
    # the actual runaway-reservation shape this gate exists to catch.
    ratio_live = max(live, BLOCK_HEAP_SUPERBLOCK_BYTES)
    checked_milli = (committed * 1000 + ratio_live - 1) // ratio_live
    values["committed_live_checked_milli"] = checked_milli
    if checked_milli > max_committed_live_milli:
        raise CheckFailure(
            "block heap committed/live ratio exceeds limit: "
            f"{checked_milli} > {max_committed_live_milli} milli "
            f"(committed {committed} B over max(live {live} B, one superblock "
            f"{BLOCK_HEAP_SUPERBLOCK_BYTES} B))"
        )

    result_stdout = "\n".join(
        line for line in lines if line and not line.startswith("gc:")
    )
    if not result_stdout:
        raise CheckFailure("exited 0 but printed no benchmark result")
    if any("ERROR" in line for line in result_stdout.splitlines()):
        raise CheckFailure(f"benchmark harness reported ERROR: {result_stdout!r}")
    return values, result_stdout


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_expectations(path: Path | None, benchmark_names: set[str]) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise CheckFailure(f"cannot read expectation file {path}: {error}") from error
    if not isinstance(document, dict) or not isinstance(document.get("benchmarks"), dict):
        raise CheckFailure("expectation file must contain an object-valued 'benchmarks'")
    expected = document["benchmarks"]
    unknown = set(expected) - benchmark_names
    if unknown:
        raise CheckFailure(f"expectation file names unknown benchmarks: {sorted(unknown)}")
    if document.get("require_all_benchmarks", True):
        missing = benchmark_names - set(expected)
        if missing:
            raise CheckFailure(f"expectation file misses benchmarks: {sorted(missing)}")
    for name, entry in expected.items():
        if not isinstance(entry, dict):
            raise CheckFailure(f"expectation for {name} must be an object")
    return expected


def check_expected_value(name: str, key: str, actual: Any, expected: Any) -> None:
    if isinstance(expected, dict):
        if not isinstance(actual, int) or isinstance(actual, bool):
            raise CheckFailure(f"{name}: range expectation for non-integer GC field {key}")
        unknown = set(expected) - {"min", "max"}
        if unknown or not expected:
            raise CheckFailure(f"{name}: invalid range for {key}: {expected}")
        for bound, value in expected.items():
            if not isinstance(value, int) or isinstance(value, bool):
                raise CheckFailure(
                    f"{name}: {bound} bound for {key} must be an integer"
                )
        if "min" in expected and actual < expected["min"]:
            raise CheckFailure(f"{name}: {key} {actual} is below {expected['min']}")
        if "max" in expected and actual > expected["max"]:
            raise CheckFailure(f"{name}: {key} {actual} exceeds {expected['max']}")
        return
    if actual != expected:
        raise CheckFailure(f"{name}: {key} is {actual!r}, expected {expected!r}")


def check_expectation(
    name: str,
    script: Path,
    values: dict[str, Any],
    result_stdout: str,
    expectation: dict[str, Any] | None,
) -> None:
    if expectation is None:
        return
    allowed = {"source_sha256", "stdout_regex", "gc"}
    unknown = set(expectation) - allowed
    if unknown:
        raise CheckFailure(f"{name}: unknown expectation keys: {sorted(unknown)}")
    if "source_sha256" in expectation:
        actual_hash = sha256(script)
        if actual_hash != expectation["source_sha256"]:
            raise CheckFailure(
                f"{name}: source sha256 is {actual_hash}, expected "
                f"{expectation['source_sha256']}"
            )
    if "stdout_regex" in expectation:
        try:
            matched = re.fullmatch(expectation["stdout_regex"], result_stdout)
        except (TypeError, re.error) as error:
            raise CheckFailure(f"{name}: invalid stdout_regex: {error}") from error
        if matched is None:
            raise CheckFailure(
                f"{name}: result stdout {result_stdout!r} does not match "
                f"{expectation['stdout_regex']!r}"
            )
    gc_expected = expectation.get("gc", {})
    if not isinstance(gc_expected, dict):
        raise CheckFailure(f"{name}: 'gc' expectation must be an object")
    for key, expected in gc_expected.items():
        if key not in values:
            raise CheckFailure(f"{name}: unknown GC expectation field {key!r}")
        check_expected_value(name, key, values[key], expected)


def check_corpus(
    corpus: Path,
    outputs: Path,
    max_committed_live_milli: int,
    expectation_path: Path | None,
) -> None:
    scripts = sorted(corpus.glob("*.js"))
    names = {script.stem for script in scripts}
    if not scripts:
        raise CheckFailure(f"no .js files in corpus {corpus}")
    expectations = load_expectations(expectation_path, names)
    for script in scripts:
        name = script.stem
        output_path = outputs / f"{name}.stdout"
        if not output_path.is_file():
            raise CheckFailure(f"{name}: missing audited stats output {output_path}")
        try:
            output_text = output_path.read_text()
        except (OSError, UnicodeError) as error:
            raise CheckFailure(f"{name}: cannot read audited output: {error}") from error
        try:
            values, result_stdout = parse_output(output_text, max_committed_live_milli)
        except CheckFailure as error:
            raise CheckFailure(f"{name}: {error}") from error
        check_expectation(name, script, values, result_stdout, expectations.get(name))
        ratio_note = (
            ""
            if values["committed_live_checked_milli"] == values["committed_live_milli"]
            else (
                f" (checked {values['committed_live_checked_milli']}"
                " on a one-superblock live floor)"
            )
        )
        print(
            f"  ok  {name:<18} retirement={values['retirement_commits']} "
            f"committed/live={values['committed_live_milli']} milli{ratio_note}",
            flush=True,
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--outputs", type=Path, required=True)
    parser.add_argument("--max-committed-live-milli", type=int, default=32000)
    parser.add_argument("--expectations", type=Path)
    args = parser.parse_args(argv)
    try:
        check_corpus(
            args.corpus,
            args.outputs,
            args.max_committed_live_milli,
            args.expectations,
        )
    except CheckFailure as error:
        print(f"fixed-work stats FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
