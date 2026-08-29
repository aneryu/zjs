#!/usr/bin/env python3
"""Contract tests for the fixed-work GC structure snapshot parser."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


VERIFY_DIR = Path(__file__).resolve().parent
MODULE_PATH = VERIFY_DIR.parent / "gc_stats_snapshot.py"
_spec = importlib.util.spec_from_file_location("gc_stats_snapshot", MODULE_PATH)
snapshot = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(snapshot)


PANEL = """\
gc: collection entries total 32, major completed 9, minor completed 22, failed 1
gc: collector counted objects freed 77 (excludes bytecode), zero-ref drains 88
gc: heap live 1000 bytes, account peak 2000 bytes
gc: weak refs current 3, finalizer queue current 4
gc: major pause p50 1 ns, p95 2 ns, p99 3 ns, max 4 ns, retained 9 of 50 pauses
gc: allocation histogram publications 100, payload bytes 200, p50-below-large 16, p95-below-large 32, p99-below-large 64, max-small 128, covered-by-small 90/95 below-large, large 5
gc: block heap committed 4000 live 500 committed/live-x1000 8000 superblocks 2 large maps 1
gc: major threshold resets growth 11, small-heap-floor 7
gc: block heap page returns cumulative decommitted 6000, recommitted 700
gc: block heap decommit checks 8, released blocks cumulative 9, current bytes 5300, max batch bytes 1000
gc: process heap trim attempts 1, successes 1
gc: incremental subphase ns totals begin-clear 10, begin-precise-seed 11, begin-conservative-seed 12, begin-retire 17, finish-remark-total 50, finish-conservative-seed-subset 14, finish-weak 15, finish-condemn 16
gc: incremental subphase work totals retired non-block headers 18, retired young blocks 7, retired remembered sets 6, clearMarks non-block headers 19
gc: generation current young 20, remembered owners 21
gc: minor collections 22, reclaimed 23, promoted-by-minor 24, promoted-all 25, remembered without young 26, remembered drops 27, suspensions 28
gc: major retirement commits 27, abandons 28, current state clean
gc: generational barrier calls 29, exit young-owner 10, exit old-target 5, remembered-owner 14
gc: exact-target marking barrier calls 40, exit marked-target 10, exit unpublished-owner 2, exit unpublished-target 3, requeued-owner 4, shaded-target 21
gc: incremental doomed condemned headers 48, destroyed counted objects 47, parked entries drained 46, parked-drain slices 6
gc: minor stw total 36 ns, mean 32 ns, max 33 ns
gc: minor pause p50 30 ns, p95 34 ns, p99 35 ns, max 36 ns over 21 retained of 22 samples
gc: minor phase totals clear 1, roots 2, conservative 3, remembered 4, trace 5, sweep+destroy 6, promote 7, other 8 ns
gc: minor young-at-start mean 34, max 35
gc: conservative-only young 3 over 22 verified minors
gc: incremental major cycles completed 8, aborted 1, forced 0, mark steps 37, cycle STW last 38 ns max 39 ns
gc: cycle envelope measured 7, skipped 1, max-P/T S 1000, T 1750, B 1751, P 1764, B/T-x1000000 1000572, P/T-x1000000 1008000, P/S-x1000000 1764000, forced 0
gc: incremental STW phase-segment max ns begin 5, increment 6, destroy 7, finish 8
gc: incremental STW phase totals begin 40 ns/41 segments, increment 42 ns/43 segments, destroy 44 ns/45 segments, finish 46 ns/47 segments
gc: marked-set census majors 9, headers 100, block headers 60, refcount-removed headers 85
gc: marked-set kinds object 70, function-bytecode 5, var-ref 5, realm-context 5, module 5, shape 10
gc: marked-set trace classes ordinary-object 40, fast-array 10, bytecode-function 5, exotic-object 15, non-object 30
gc: mark storage base allocation-touches 100, allocated-bytes 7200, touched-cache-lines 180
gc: mark storage shape allocation-touches 70, allocated-bytes 6000, touched-cache-lines 140
gc: mark storage property_slots allocation-touches 50, allocated-bytes 2000, touched-cache-lines 80
gc: mark storage dense_elements allocation-touches 10, allocated-bytes 1000, touched-cache-lines 30
gc: mark storage trace_payload allocation-touches 10, allocated-bytes 500, touched-cache-lines 20
gc: mark storage payload_backing allocation-touches 5, allocated-bytes 250, touched-cache-lines 10
gc: mark trace class storage ordinary_object allocation-touches 120, allocated-bytes 8000, touched-cache-lines 220
gc: mark trace class storage fast_array allocation-touches 40, allocated-bytes 3000, touched-cache-lines 80
gc: mark trace class storage bytecode_function allocation-touches 25, allocated-bytes 1800, touched-cache-lines 55
gc: mark trace class storage exotic_object allocation-touches 30, allocated-bytes 2150, touched-cache-lines 65
gc: mark trace class storage non_object allocation-touches 30, allocated-bytes 2000, touched-cache-lines 40
gc: inline property upper slots 1, eligible-objects 20, direct-inline 4, tail-grown-external 6, plain-external 10, external-allocated-bytes 640, external-touched-cache-lines 25
gc: inline ordinary property upper slots 1, eligible-objects 10, direct-inline 2, tail-grown-external 3, plain-external 5, external-allocated-bytes 320, external-touched-cache-lines 12
gc: inline property upper slots 2, eligible-objects 30, direct-inline 12, tail-grown-external 3, plain-external 15, external-allocated-bytes 960, external-touched-cache-lines 40
gc: inline ordinary property upper slots 2, eligible-objects 25, direct-inline 10, tail-grown-external 2, plain-external 13, external-allocated-bytes 800, external-touched-cache-lines 32
gc: inline property upper slots 4, eligible-objects 40, direct-inline 25, tail-grown-external 1, plain-external 14, external-allocated-bytes 1600, external-touched-cache-lines 55
gc: inline ordinary property upper slots 4, eligible-objects 35, direct-inline 22, tail-grown-external 0, plain-external 13, external-allocated-bytes 1400, external-touched-cache-lines 48
"""


class GcStatsSnapshotTests(unittest.TestCase):
    def test_completion_accepts_integer_or_decimal_without_parsing_score(self) -> None:
        self.assertTrue(snapshot.has_numeric_completion("Splay: 101\n"))
        self.assertTrue(snapshot.has_numeric_completion("RegExp: 96.8\n"))
        self.assertFalse(snapshot.has_numeric_completion("RegExp: failed\n"))

    def test_parser_extracts_structural_and_stw_fields(self) -> None:
        parsed = snapshot.parse_gc_stats(PANEL)
        self.assertEqual(parsed["cycles"]["majorCompleted"], 9)
        self.assertEqual(parsed["cycles"]["minor"], 22)
        self.assertEqual(parsed["collector"]["objectsFreed"], 77)
        self.assertEqual(parsed["blockHeap"]["currentDecommitted"], 5300)
        self.assertEqual(parsed["blockHeap"]["thresholdGrowthResets"], 11)
        self.assertEqual(parsed["blockHeap"]["thresholdSmallHeapFloorResets"], 7)
        self.assertEqual(parsed["allocations"]["publications"], 100)
        self.assertEqual(parsed["barriers"]["generational"]["calls"], 29)
        self.assertEqual(parsed["barriers"]["marking"]["exitMarkedTarget"], 10)
        self.assertEqual(parsed["barriers"]["totalCalls"], 69)
        self.assertEqual(parsed["doomed"]["condemnedHeaders"], 48)
        self.assertEqual(parsed["doomed"]["parkedEntriesDrained"], 46)
        self.assertEqual(parsed["marking"]["clearMarksNonBlockHeaders"], 19)
        self.assertEqual(parsed["marking"]["retiredYoungBlocks"], 7)
        self.assertEqual(parsed["marking"]["retiredRememberedSets"], 6)
        self.assertEqual(parsed["generation"]["minorReclaimed"], 23)
        self.assertEqual(parsed["generation"]["promotedByMinor"], 24)
        self.assertEqual(parsed["generation"]["promotedAll"], 25)
        self.assertEqual(parsed["generation"]["minorPauseDistribution"]["p99"], 35)
        self.assertEqual(parsed["generation"]["minorPauseDistribution"]["sampleDrops"], 1)
        self.assertEqual(parsed["generation"]["conservativeOnlyYoung"]["young"], 3)
        self.assertEqual(parsed["pauseNs"]["minor"]["total"], 36)
        self.assertEqual(parsed["pauseNs"]["minorPhaseTotals"]["sweepDestroy"], 6)
        self.assertEqual(parsed["markFootprint"]["markedHeaders"], 100)
        self.assertEqual(parsed["markFootprint"]["markedPerMajorX1000"], 11111)
        self.assertEqual(parsed["markFootprint"]["allocationTouches"], 245)
        self.assertEqual(parsed["markFootprint"]["allocationTouchesPerMarkedX1000"], 2450)
        self.assertEqual(parsed["markFootprint"]["cacheLinesPerMarkedX1000"], 4600)
        self.assertEqual(
            parsed["markFootprint"]["traceClassStorage"]["ordinary_object"]["allocationTouchesPerMarkedX1000"],
            3000,
        )
        self.assertEqual(
            parsed["markFootprint"]["storage"]["shape"]["averageAllocatedBytesX1000"],
            85714,
        )
        self.assertEqual(
            parsed["markFootprint"]["inlinePropertyUpper"]["slots2"]["eligibleObjects"],
            30,
        )
        self.assertEqual(
            parsed["markFootprint"]["inlineOrdinaryPropertyUpper"]["slots2"]["eligibleObjects"],
            25,
        )
        self.assertEqual(
            parsed["markFootprint"]["inlinePropertyUpper"]["slots4"],
            {
                "eligibleObjects": 40,
                "directInline": 25,
                "tailGrownExternal": 1,
                "plainExternal": 14,
                "externalAllocatedBytes": 1600,
                "externalTouchedCacheLines": 55,
                "cacheLinesPerMarkedX1000": 550,
            },
        )
        self.assertEqual(
            parsed["markFootprint"]["inlineOrdinaryPropertyUpper"]["slots1"]["tailGrownExternal"],
            3,
        )
        self.assertEqual(parsed["retirement"]["abandons"], 28)
        self.assertEqual(parsed["weakState"]["finalizerQueueCurrent"], 4)
        self.assertEqual(parsed["pauseNs"]["incrementalSubphaseTotals"]["finishRemarkTotal"], 50)
        self.assertEqual(parsed["pauseNs"]["incrementalPhaseSegmentMax"]["destroy"], 7)
        self.assertEqual(parsed["pauseNs"]["stwTotals"]["destroy"], {"ns": 44, "segments": 45})
        self.assertEqual(parsed["cycles"]["envelope"]["measured"], 7)
        self.assertEqual(
            parsed["cycles"]["envelope"]["maxPeakOverThreshold"]["peak"],
            1764,
        )
        self.assertTrue(parsed["cycles"]["envelope"]["passesPeakOverThreshold36Over35"])

    def test_missing_required_row_fails_closed(self) -> None:
        without_barrier = "\n".join(
            line for line in PANEL.splitlines() if "barrier calls" not in line
        )
        with self.assertRaisesRegex(snapshot.SnapshotError, "barrier row"):
            snapshot.parse_gc_stats(without_barrier)

    def test_explicitly_unavailable_stage5_probes_are_preserved(self) -> None:
        panel = PANEL.replace(
            "gc: minor pause p50 30 ns, p95 34 ns, p99 35 ns, max 36 ns over 21 retained of 22 samples",
            "gc: minor pause distribution unavailable, sample drops 0",
        ).replace(
            "gc: conservative-only young 3 over 22 verified minors",
            "gc: conservative-only young unavailable (set ZJS_GC_VERIFY_MINOR=1)",
        )
        parsed = snapshot.parse_gc_stats(panel)
        self.assertFalse(parsed["generation"]["minorPauseDistribution"]["available"])
        self.assertFalse(parsed["generation"]["conservativeOnlyYoung"]["available"])

    def test_duplicate_required_row_fails_closed(self) -> None:
        with self.assertRaisesRegex(snapshot.SnapshotError, "collection row"):
            snapshot.parse_gc_stats(PANEL + PANEL.splitlines()[0] + "\n")

    def test_inconsistent_barrier_partition_fails_closed(self) -> None:
        inconsistent = PANEL.replace(
            "remembered-owner 14", "remembered-owner 13"
        )
        with self.assertRaisesRegex(snapshot.SnapshotError, "do not add to calls"):
            snapshot.parse_gc_stats(inconsistent)

    def test_inconsistent_cycle_envelope_ratio_fails_closed(self) -> None:
        inconsistent = PANEL.replace(
            "P/T-x1000000 1008000", "P/T-x1000000 1008001"
        )
        with self.assertRaisesRegex(snapshot.SnapshotError, "P/T ratio"):
            snapshot.parse_gc_stats(inconsistent)

    def test_cycle_envelope_forced_count_must_match(self) -> None:
        inconsistent = PANEL.replace(
            "P/S-x1000000 1764000, forced 0",
            "P/S-x1000000 1764000, forced 1",
        )
        with self.assertRaisesRegex(snapshot.SnapshotError, "forced counts disagree"):
            snapshot.parse_gc_stats(inconsistent)

    def test_inconsistent_marked_partition_fails_closed(self) -> None:
        inconsistent = PANEL.replace(
            "shape 10", "shape 9"
        )
        with self.assertRaisesRegex(snapshot.SnapshotError, "marked kind partition"):
            snapshot.parse_gc_stats(inconsistent)

    def test_missing_storage_component_fails_closed(self) -> None:
        missing = "\n".join(
            line for line in PANEL.splitlines()
            if "mark storage payload_backing" not in line
        )
        with self.assertRaisesRegex(snapshot.SnapshotError, "mark storage rows differ"):
            snapshot.parse_gc_stats(missing)

    def test_outcome_columns_are_outside_the_monotonicity_contract(self) -> None:
        """driver ruling 2026-08-29: parse and report the three outcome
        columns, do not hold them to the slot-budget monotonicity contract.

        The shipped PANEL already walks tail-grown-external down 6 -> 3 -> 1;
        this drives direct-inline down as well (4 -> 12 -> 2) so the ruling is
        pinned by a case that would fail if the columns were ever folded back
        into `previous`. The partition identity is preserved, so a failure
        here can only come from the monotonicity loop.
        """
        panel = PANEL.replace(
            "gc: inline property upper slots 4, eligible-objects 40, direct-inline 25, tail-grown-external 1, plain-external 14,",
            "gc: inline property upper slots 4, eligible-objects 40, direct-inline 2, tail-grown-external 1, plain-external 37,",
        )
        parsed = snapshot.parse_gc_stats(panel)
        self.assertEqual(
            parsed["markFootprint"]["inlinePropertyUpper"]["slots4"]["directInline"],
            2,
        )

    def test_contracted_inline_metrics_still_fail_closed(self) -> None:
        """The three budget metrics keep their monotonicity contract."""
        panel = PANEL.replace(
            "gc: inline property upper slots 4, eligible-objects 40,",
            "gc: inline property upper slots 4, eligible-objects 25,",
        ).replace(
            "direct-inline 25, tail-grown-external 1, plain-external 14,",
            "direct-inline 10, tail-grown-external 1, plain-external 14,",
        )
        with self.assertRaisesRegex(snapshot.SnapshotError, "is not monotonic"):
            snapshot.parse_gc_stats(panel)

    def test_inline_outcome_partition_fails_closed(self) -> None:
        """The three outcomes must add to eligible-objects: a column-order or
        emitter drift that breaks the identity is a parse failure, not a
        silently wrong snapshot."""
        panel = PANEL.replace(
            "direct-inline 12, tail-grown-external 3, plain-external 15,",
            "direct-inline 12, tail-grown-external 3, plain-external 16,",
        )
        with self.assertRaisesRegex(
            snapshot.SnapshotError, "partition does not add to eligible objects"
        ):
            snapshot.parse_gc_stats(panel)

    def test_reserved_measurement_cpus_are_rejected(self) -> None:
        for cpu in (*range(5, 10), *range(15, 20)):
            with self.assertRaisesRegex(snapshot.SnapshotError, "reserved"):
                snapshot.validate_cpu(cpu)

    def test_compare_reports_only_threshold_crossings(self) -> None:
        def shape(value: int, zero_value: int) -> dict:
            return {
                "schemaVersion": 5,
                "kind": "gc-heavy-six-fixed-work-structure",
                "engine": {"configSignature": "same"},
                "workload": {"sourceRevision": "same"},
                "runs": [{
                    "benchmark": "case",
                    "fixedSourceSha256": "same",
                    "stats": {"count": value, "zeroBase": zero_value},
                }],
            }

        drifts = snapshot.compare_snapshots(shape(100, 0), shape(111, 2), 10.0, 0)
        self.assertEqual(
            [(row["metric"], row["candidate"]) for row in drifts],
            [("count", 111), ("zeroBase", 2)],
        )
        self.assertEqual(drifts[1]["relativePercent"], None)

    def test_compare_rejects_noncomparable_sources(self) -> None:
        old = {
            "schemaVersion": 4,
            "kind": "kind",
            "engine": {"configSignature": "a"},
            "workload": {},
            "runs": [],
        }
        new = {**old, "engine": {"configSignature": "b"}}
        with self.assertRaisesRegex(snapshot.SnapshotError, "config signatures"):
            snapshot.compare_snapshots(old, new, 10.0, 0)


if __name__ == "__main__":
    unittest.main()
