#!/usr/bin/env python3

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import sys

PERF_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PERF_DIR))

from gate_smoke_check import CheckFailure, check_corpus, parse_output  # noqa: E402


def stats_output(
    *,
    abandons: int = 0,
    state: str = "clean",
    doomed_pending: bool = False,
    committed: int = 4096,
    live: int = 1024,
    milli: int = 4000,
) -> str:
    return "\n".join(
        [
            "Fixture: 7",
            f"gc: block heap committed {committed} live {live} committed/live-x1000 {milli} "
            "superblocks 1 large maps 0",
            f"gc: major retirement commits 3, abandons {abandons}, current state {state}",
            "gc: terminal doomed_pending "
            f"{'true' if doomed_pending else 'false'}",
            "",
        ]
    )


class GateSmokeCheckTests(unittest.TestCase):
    def test_required_terminal_invariants_accept_clean_output(self) -> None:
        values, result = parse_output(stats_output(), 8000)
        self.assertEqual(0, values["retirement_abandons"])
        self.assertEqual("clean", values["retirement_state"])
        self.assertFalse(values["doomed_pending"])
        self.assertEqual(4000, values["committed_live_milli"])
        self.assertEqual("Fixture: 7", result)

    def test_each_required_terminal_invariant_turns_red(self) -> None:
        bad_outputs = [
            stats_output(abandons=1),
            stats_output(state="abandoned"),
            stats_output(doomed_pending=True),
            stats_output(milli=3999),
            stats_output(committed=33000, live=1000, milli=33000),
        ]
        for output in bad_outputs:
            with self.subTest(output=output):
                with self.assertRaises(CheckFailure):
                    parse_output(output, 32000)

    def test_exit_zero_without_result_or_with_harness_error_turns_red(self) -> None:
        clean = stats_output()
        for output in (
            clean.replace("Fixture: 7\n", ""),
            clean.replace("Fixture: 7", "Fixture: ERROR"),
        ):
            with self.subTest(output=output):
                with self.assertRaises(CheckFailure):
                    parse_output(output, 32000)

    def test_expectation_manifest_checks_source_stdout_and_gc(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            corpus = root / "corpus"
            outputs = root / "outputs"
            corpus.mkdir()
            outputs.mkdir()
            script = corpus / "fixture.js"
            script.write_text("print('fixture')\n")
            (outputs / "fixture.stdout").write_text(stats_output())
            expectation = root / "expected.json"
            expectation.write_text(
                json.dumps(
                    {
                        "benchmarks": {
                            "fixture": {
                                "source_sha256": hashlib.sha256(
                                    script.read_bytes()
                                ).hexdigest(),
                                "stdout_regex": r"^Fixture: [0-9]+$",
                                "gc": {
                                    "retirement_commits": {"min": 1},
                                    "committed_live_milli": {"max": 4500},
                                    "doomed_pending": False,
                                },
                            }
                        }
                    }
                )
            )
            check_corpus(corpus, outputs, 8000, expectation)

            document = json.loads(expectation.read_text())
            document["benchmarks"]["fixture"]["gc"]["retirement_commits"] = 4
            expectation.write_text(json.dumps(document))
            with self.assertRaises(CheckFailure):
                check_corpus(corpus, outputs, 8000, expectation)

    def test_expectation_manifest_is_exhaustive_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            corpus = root / "corpus"
            outputs = root / "outputs"
            corpus.mkdir()
            outputs.mkdir()
            (corpus / "one.js").write_text("1\n")
            (corpus / "two.js").write_text("2\n")
            (outputs / "one.stdout").write_text(stats_output())
            (outputs / "two.stdout").write_text(stats_output())
            expectation = root / "expected.json"
            expectation.write_text(json.dumps({"benchmarks": {"one": {}}}))
            with self.assertRaises(CheckFailure):
                check_corpus(corpus, outputs, 8000, expectation)

    def test_shell_runs_each_case_normally_and_once_with_arena_audit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            corpus = root / "corpus"
            corpus.mkdir()
            script = corpus / "fixture.js"
            script.write_text("fixture\n")
            fake = root / "fake-zjs"
            fake.write_text(
                "#!/usr/bin/env bash\n"
                "set -eu\n"
                "printf '%s|%s\\n' \"${ZJS_GC_ARENA_AUDIT:-0}\" \"$*\" >>\"$FAKE_LOG\"\n"
                "if [[ \"${1:-}\" == --gc-stats ]]; then\n"
                "  [[ \"${ZJS_GC_ARENA_AUDIT:-0}\" == 1 ]]\n"
                "  printf '%s\\n' 'Fixture: 7' \\\n"
                "    'gc: block heap committed 4096 live 1024 committed/live-x1000 4000 superblocks 1 large maps 0' \\\n"
                "    'gc: major retirement commits 3, abandons 0, current state clean' \\\n"
                "    'gc: terminal doomed_pending false'\n"
                "fi\n"
            )
            fake.chmod(0o755)
            log = root / "calls.log"
            expectation = root / "expected.json"
            expectation.write_text(
                json.dumps(
                    {
                        "benchmarks": {
                            "fixture": {
                                "source_sha256": hashlib.sha256(
                                    script.read_bytes()
                                ).hexdigest(),
                                "stdout_regex": r"^Fixture: 7$",
                            }
                        }
                    }
                )
            )
            env = os.environ.copy()
            env["FAKE_LOG"] = str(log)
            process = subprocess.run(
                [
                    "bash",
                    str(PERF_DIR / "gate_smoke.sh"),
                    str(fake),
                    str(corpus),
                    "0",
                    "1",
                    str(expectation),
                ],
                text=True,
                capture_output=True,
                env=env,
            )
            self.assertEqual(0, process.returncode, process.stderr)
            calls = log.read_text().splitlines()
            self.assertEqual(2, len(calls))
            self.assertTrue(calls[0].startswith("0|"), calls)
            self.assertTrue(calls[1].startswith("1|--gc-stats "), calls)


if __name__ == "__main__":
    unittest.main()
