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
    endpoint_pending: bool = False,
    endpoint_buckets: int = 0,
    endpoint_headers: int = 0,
    endpoint_cursor: bool = False,
    endpoint_blocks: int = 0,
    endpoint_parked: int = 0,
    endpoint_finalizers: int = 0,
    endpoint_active_finalizer: bool = False,
    settled_pending: bool = False,
    settled_buckets: int = 0,
    settled_headers: int = 0,
    settled_cursor: bool = False,
    settled_blocks: int = 0,
    settled_parked: int = 0,
    settled_finalizers: int = 0,
    settled_active_finalizer: bool = False,
    committed: int = 4096,
    live: int = 1024,
    milli: int = 4000,
) -> str:
    def doomed_line(
        layer: str,
        pending: bool,
        buckets: int,
        headers: int,
        cursor: bool,
        blocks: int,
        parked: int,
        finalizers: int,
        active_finalizer: bool,
    ) -> str:
        return (
            f"gc: {layer} doomed_pending {'true' if pending else 'false'}, "
            f"doomed_buckets {buckets}, doomed_headers {headers}, "
            f"doomed_cursor {'true' if cursor else 'false'}, "
            f"doomed_blocks {blocks}, parked_frees {parked}, "
            f"deferred_finalizers {finalizers}, "
            f"active_finalizer {'true' if active_finalizer else 'false'}"
        )

    return "\n".join(
        [
            "Fixture: 7",
            doomed_line(
                "endpoint",
                endpoint_pending,
                endpoint_buckets,
                endpoint_headers,
                endpoint_cursor,
                endpoint_blocks,
                endpoint_parked,
                endpoint_finalizers,
                endpoint_active_finalizer,
            ),
            f"gc: block heap committed {committed} live {live} committed/live-x1000 {milli} "
            "superblocks 1 large maps 0",
            f"gc: major retirement commits 3, abandons {abandons}, current state {state}",
            doomed_line(
                "settled",
                settled_pending,
                settled_buckets,
                settled_headers,
                settled_cursor,
                settled_blocks,
                settled_parked,
                settled_finalizers,
                settled_active_finalizer,
            ),
            "",
        ]
    )


class GateSmokeCheckTests(unittest.TestCase):
    def test_required_settled_invariants_accept_clean_output(self) -> None:
        values, result = parse_output(stats_output(), 8000)
        self.assertEqual(0, values["retirement_abandons"])
        self.assertEqual("clean", values["retirement_state"])
        self.assertFalse(values["endpoint_doomed_pending"])
        self.assertFalse(values["settled_doomed_pending"])
        self.assertEqual(4000, values["committed_live_milli"])
        self.assertEqual("Fixture: 7", result)

    def test_endpoint_state_and_open_retirement_are_diagnostic(self) -> None:
        values, _ = parse_output(
            stats_output(
                state="tracing",
                endpoint_pending=True,
                endpoint_buckets=1,
                endpoint_headers=7,
                endpoint_cursor=True,
                endpoint_blocks=2,
                endpoint_parked=3,
                endpoint_finalizers=4,
                endpoint_active_finalizer=True,
            ),
            8000,
        )
        self.assertEqual("tracing", values["retirement_state"])
        self.assertTrue(values["endpoint_doomed_pending"])
        self.assertEqual(7, values["endpoint_doomed_headers"])

    def test_each_required_settled_invariant_turns_red(self) -> None:
        bad_outputs = [
            stats_output(abandons=1),
            stats_output(settled_pending=True),
            stats_output(settled_buckets=1),
            stats_output(settled_headers=1),
            stats_output(settled_cursor=True),
            stats_output(settled_blocks=1),
            stats_output(settled_parked=1),
            stats_output(settled_finalizers=1),
            stats_output(settled_active_finalizer=True),
            stats_output(milli=3999),
            stats_output(committed=70_000_000, live=1000, milli=70_000_000),
        ]
        for output in bad_outputs:
            with self.subTest(output=output):
                with self.assertRaises(CheckFailure):
                    parse_output(output, 32000)

    def test_additive_superblock_allowance_is_continuous_at_raytrace_phase(self) -> None:
        committed = 86_261_760
        live = 2_117_248
        raw_milli = (committed * 1000 + live - 1) // live
        values, _ = parse_output(
            stats_output(committed=committed, live=live, milli=raw_milli),
            32000,
        )
        self.assertEqual(40743, values["committed_live_milli"])
        self.assertEqual(20469, values["committed_live_checked_milli"])

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
                                    "settled_doomed_pending": False,
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
                "affinity=$(awk '/Cpus_allowed_list/ {print $2}' /proc/self/status)\n"
                "printf '%s|%s|%s\\n' \"${ZJS_GC_ARENA_AUDIT:-0}\" \"$affinity\" \"$*\" >>\"$FAKE_LOG\"\n"
                "if [[ \"$*\" == *'--gc-gate-settle --gc-stats'* ]]; then\n"
                "  printf '%s\\n' 'Fixture: 7' \\\n"
                "    'gc: endpoint doomed_pending true, doomed_buckets 1, doomed_headers 7, doomed_cursor true, doomed_blocks 2, parked_frees 3, deferred_finalizers 4, active_finalizer false' \\\n"
                "    'gc: block heap committed 4096 live 1024 committed/live-x1000 4000 superblocks 1 large maps 0' \\\n"
                "    'gc: major retirement commits 3, abandons 0, current state clean' \\\n"
                "    'gc: settled doomed_pending false, doomed_buckets 0, doomed_headers 0, doomed_cursor false, doomed_blocks 0, parked_frees 0, deferred_finalizers 0, active_finalizer false'\n"
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
            self.assertEqual(3, len(calls))
            self.assertTrue(calls[0].startswith("0|0|--gc-gate-settle --gc-stats "), calls)
            self.assertTrue(calls[1].startswith("0|0|"), calls)
            self.assertTrue(calls[2].startswith("1|0|--gc-gate-settle --gc-stats "), calls)

            log.write_text("")
            env["ZJS_MEASURE_FIELD"] = "a"
            process = subprocess.run(
                [
                    "bash",
                    str(PERF_DIR / "gate_smoke.sh"),
                    str(fake),
                    str(corpus),
                ],
                text=True,
                capture_output=True,
                env=env,
            )
            self.assertEqual(0, process.returncode, process.stderr)
            field_calls = log.read_text().splitlines()
            self.assertEqual(5, len(field_calls))
            self.assertTrue(all(call.split("|", 2)[1] == "9" for call in field_calls))


if __name__ == "__main__":
    unittest.main()
