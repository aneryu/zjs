#!/usr/bin/env python3
"""Capture or compare GC-shape snapshots from the six fixed-work cases.

This is a correctness/structure guardrail, not a performance measurement.  It
runs each deterministic Octane workload exactly once, records no benchmark
score, takes no host lock, and never invokes ``perf``.  Nanosecond counters are
kept because large directional changes are useful diagnostics, but one-run
timings are not a performance gate.

Comparison mode reads two existing snapshots and reports numeric leaves whose
absolute and relative movement crosses caller-provided thresholds. It runs no
engine process.

The lane measurement CPUs (5-9 and 15-19) are rejected explicitly.  CPU 0 is
the default so this check cannot accidentally occupy the measurement host's
reserved clusters.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


PERF_DIR = Path(__file__).resolve().parent
ZOO_TOOL_DIR = PERF_DIR / "zoo"
sys.path.insert(0, str(ZOO_TOOL_DIR))
from run_zoo_compare import git_describe, sha256_of  # noqa: E402
from run_zoo_fixed_pmu import fixed_source  # noqa: E402


GC_HEAVY_SIX = (
    "deltablue",
    "earley-boyer",
    "pdfjs",
    "raytrace",
    "regexp",
    "splay",
)
FORBIDDEN_CPUS = frozenset((*range(5, 10), *range(15, 20)))
COMPLETION_RE = re.compile(r"^[A-Za-z0-9_-]+:\s+[0-9]+(?:\.[0-9]+)?\s*$", re.MULTILINE)


class SnapshotError(RuntimeError):
    """The requested snapshot could not be produced without ambiguity."""


def has_numeric_completion(text: str) -> bool:
    """Accept benchmark completion without interpreting or storing its score."""
    return COMPLETION_RE.search(text) is not None


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def tracked_tree_dirty(repo: Path) -> bool:
    proc = subprocess.run(
        ["git", "-C", str(repo), "diff", "--quiet", "HEAD", "--"],
        capture_output=True,
        text=True,
    )
    if proc.returncode not in (0, 1):
        raise SnapshotError(f"cannot inspect tracked source state in {repo}")
    return proc.returncode == 1


def one_match(text: str, pattern: str, label: str) -> dict[str, int | str]:
    matches = list(re.finditer(pattern, text, re.MULTILINE))
    if len(matches) != 1:
        raise SnapshotError(
            f"expected exactly one {label} row, found {len(matches)}"
        )
    values: dict[str, int | str] = {}
    for key, value in matches[0].groupdict().items():
        values[key] = int(value) if value.isdigit() else value
    return values


def one_of_matches(
    text: str,
    patterns: dict[str, str],
    label: str,
) -> tuple[str, dict[str, int | str]]:
    """Require exactly one explicitly named panel variant."""
    found: list[tuple[str, re.Match[str]]] = []
    for variant, pattern in patterns.items():
        found.extend((variant, match) for match in re.finditer(pattern, text, re.MULTILINE))
    if len(found) != 1:
        raise SnapshotError(
            f"expected exactly one {label} row, found {len(found)}"
        )
    variant, match = found[0]
    values: dict[str, int | str] = {}
    for key, value in match.groupdict().items():
        values[key] = int(value) if value.isdigit() else value
    return variant, values


def indexed_matches(
    text: str,
    pattern: str,
    label: str,
    key: str,
    expected: set[str],
) -> dict[str, dict[str, int | str]]:
    """Parse a repeated panel row and require the complete named partition."""
    rows: dict[str, dict[str, int | str]] = {}
    for match in re.finditer(pattern, text, re.MULTILINE):
        values: dict[str, int | str] = {}
        for name, value in match.groupdict().items():
            values[name] = value if name == key else (
                int(value) if value.isdigit() else value
            )
        index = values.pop(key)
        if not isinstance(index, str):
            raise SnapshotError(f"{label} key is not text: {index!r}")
        if index in rows:
            raise SnapshotError(f"duplicate {label} row for {index}")
        rows[index] = values
    actual = set(rows)
    if actual != expected:
        raise SnapshotError(
            f"{label} rows differ: missing={sorted(expected - actual)}, "
            f"added={sorted(actual - expected)}"
        )
    return rows


def parse_gc_stats(text: str) -> dict:
    """Parse the required trace-STW panel rows, rejecting schema drift."""
    collections = one_match(
        text,
        r"^gc: collection entries total (?P<entries>\d+), major completed (?P<major>\d+), minor completed (?P<minor>\d+), failed (?P<failed>\d+)$",
        "collection",
    )
    collector = one_match(
        text,
        r"^gc: collector counted objects freed (?P<objects_freed>\d+) \(excludes bytecode\), zero-ref drains (?P<zero_ref_drains>\d+)$",
        "collector outcome",
    )
    heap = one_match(
        text,
        r"^gc: heap live (?P<live>\d+) bytes, account peak (?P<account_peak>\d+) bytes$",
        "heap bytes",
    )
    weak = one_match(
        text,
        r"^gc: weak refs current (?P<weak_refs>\d+), finalizer queue current (?P<finalizer_queue>\d+)$",
        "weak state",
    )
    major_pause = one_match(
        text,
        r"^gc: major pause p50 (?P<p50>\d+) ns, p95 (?P<p95>\d+) ns, p99 (?P<p99>\d+) ns, max (?P<max>\d+) ns, retained (?P<retained>\d+) of (?P<total>\d+) pauses$",
        "major pause",
    )
    allocation_shape = one_match(
        text,
        r"^gc: allocation histogram publications (?P<publications>\d+), payload bytes (?P<payload_bytes>\d+), p50-below-large (?P<p50>\d+), p95-below-large (?P<p95>\d+), p99-below-large (?P<p99>\d+), max-small (?P<max_small>\d+), covered-by-small (?P<covered>\d+)/(?P<below_large>\d+) below-large, large (?P<large>\d+)$",
        "allocation shape",
    )
    block = one_match(
        text,
        r"^gc: block heap committed (?P<committed>\d+) live (?P<live>\d+) committed/live-x1000 (?P<committed_over_live_x1000>\d+) superblocks (?P<superblocks>\d+) large maps (?P<large_maps>\d+)$",
        "block heap",
    )
    thresholds = one_match(
        text,
        r"^gc: major threshold resets growth (?P<growth>\d+), small-heap-floor (?P<small_heap_floor>\d+)$",
        "major threshold source",
    )
    decommit_totals = one_match(
        text,
        r"^gc: block heap page returns cumulative decommitted (?P<decommitted>\d+), recommitted (?P<recommitted>\d+)$",
        "block decommit totals",
    )
    decommit = one_match(
        text,
        r"^gc: block heap decommit checks (?P<checks>\d+), released blocks cumulative (?P<released_blocks>\d+), current bytes (?P<current>\d+), max batch bytes (?P<max_batch>\d+)$",
        "block decommit",
    )
    trim = one_match(
        text,
        r"^gc: process heap trim attempts (?P<attempts>\d+), successes (?P<successes>\d+)$",
        "process trim",
    )
    phases = one_match(
        text,
        r"^gc: incremental subphase ns totals begin-clear (?P<begin_clear>\d+), begin-precise-seed (?P<begin_precise_seed>\d+), begin-conservative-seed (?P<begin_conservative_seed>\d+), begin-retire (?P<begin_retire>\d+), finish-remark-total (?P<finish_remark_total>\d+), finish-conservative-seed-subset (?P<finish_conservative_seed_subset>\d+), finish-weak (?P<finish_weak>\d+), finish-condemn (?P<finish_condemn>\d+)$",
        "phase totals",
    )
    phase_work = one_match(
        text,
        r"^gc: incremental subphase work totals retired non-block headers (?P<retired_nonblock_headers>\d+), retired young blocks (?P<retired_young_blocks>\d+), retired remembered sets (?P<retired_remembered_sets>\d+), clearMarks non-block headers (?P<clear_marks_nonblock_headers>\d+)$",
        "phase work",
    )
    generation = one_match(
        text,
        r"^gc: generation current young (?P<young>\d+), remembered owners (?P<remembered_owners>\d+)$",
        "generation",
    )
    minors = one_match(
        text,
        r"^gc: minor collections (?P<collections>\d+), reclaimed (?P<reclaimed>\d+), promoted-by-minor (?P<promoted_by_minor>\d+), promoted-all (?P<promoted_all>\d+), remembered without young (?P<remembered_without_young>\d+), remembered drops (?P<remembered_drops>\d+), suspensions (?P<suspensions>\d+)$",
        "minor collection",
    )
    retirement = one_match(
        text,
        r"^gc: major retirement commits (?P<commits>\d+), abandons (?P<abandons>\d+), current state (?P<state>[a-z_]+)$",
        "retirement",
    )
    barriers = one_match(
        text,
        r"^gc: generational barrier calls (?P<calls>\d+), exit young-owner (?P<young_owner>\d+), exit old-target (?P<old_target>\d+), remembered-owner (?P<remembered_owner>\d+)$",
        "barrier",
    )
    marking_barriers = one_match(
        text,
        r"^gc: exact-target marking barrier calls (?P<calls>\d+), exit marked-target (?P<marked_target>\d+), exit unpublished-owner (?P<unpublished_owner>\d+), exit unpublished-target (?P<unpublished_target>\d+), requeued-owner (?P<requeued_owner>\d+), shaded-target (?P<shaded_target>\d+)$",
        "marking barrier",
    )
    doomed = one_match(
        text,
        r"^gc: incremental doomed condemned headers (?P<condemned_headers>\d+), destroyed counted objects (?P<destroyed_objects>\d+), parked entries drained (?P<parked_entries_drained>\d+), parked-drain slices (?P<parked_drain_slices>\d+)$",
        "doomed",
    )
    minor_stw = one_match(
        text,
        r"^gc: minor stw total (?P<total>\d+) ns, mean (?P<mean>\d+) ns, max (?P<max>\d+) ns$",
        "minor STW",
    )
    minor_phases = one_match(
        text,
        r"^gc: minor phase totals clear (?P<clear>\d+), roots (?P<roots>\d+), conservative (?P<conservative>\d+), remembered (?P<remembered>\d+), trace (?P<trace>\d+), sweep\+destroy (?P<sweep_destroy>\d+), promote (?P<promote>\d+), other (?P<other>\d+) ns$",
        "minor phase totals",
    )
    minor_work = one_match(
        text,
        r"^gc: minor young-at-start mean (?P<young_mean>\d+), max (?P<young_max>\d+)$",
        "minor work",
    )
    minor_pause_variant, minor_pause_distribution = one_of_matches(
        text,
        {
            "available": r"^gc: minor pause p50 (?P<p50>\d+) ns, p95 (?P<p95>\d+) ns, p99 (?P<p99>\d+) ns, max (?P<max>\d+) ns over (?P<retained>\d+) retained of (?P<total>\d+) samples$",
            "unavailable": r"^gc: minor pause distribution unavailable, sample drops (?P<drops>\d+)$",
        },
        "minor pause distribution",
    )
    conservative_variant, conservative_young = one_of_matches(
        text,
        {
            "available": r"^gc: conservative-only young (?P<young>\d+) over (?P<verified_minors>\d+) verified minors$",
            "unavailable": r"^gc: conservative-only young unavailable \(set ZJS_GC_VERIFY_MINOR=1\)$",
        },
        "conservative-only young",
    )
    incremental = one_match(
        text,
        r"^gc: incremental major cycles completed (?P<completed>\d+), aborted (?P<aborted>\d+), forced (?P<forced>\d+), mark steps (?P<mark_steps>\d+), cycle STW last (?P<last_stw>\d+) ns max (?P<max_stw>\d+) ns$",
        "incremental cycle",
    )
    envelope = one_match(
        text,
        r"^gc: cycle envelope measured (?P<measured>\d+), skipped (?P<skipped>\d+), max-P/T S (?P<start>\d+), T (?P<threshold>\d+), B (?P<begin>\d+), P (?P<peak>\d+), B/T-x1000000 (?P<begin_over_threshold_x1000000>\d+), P/T-x1000000 (?P<peak_over_threshold_x1000000>\d+), P/S-x1000000 (?P<peak_over_start_x1000000>\d+), forced (?P<forced>\d+)$",
        "cycle envelope",
    )
    slice_max = one_match(
        text,
        r"^gc: incremental STW phase-segment max ns begin (?P<begin>\d+), increment (?P<increment>\d+), destroy (?P<destroy>\d+), finish (?P<finish>\d+)$",
        "STW phase-segment max",
    )
    stw = one_match(
        text,
        r"^gc: incremental STW phase totals begin (?P<begin_ns>\d+) ns/(?P<begin_segments>\d+) segments, increment (?P<increment_ns>\d+) ns/(?P<increment_segments>\d+) segments, destroy (?P<destroy_ns>\d+) ns/(?P<destroy_segments>\d+) segments, finish (?P<finish_ns>\d+) ns/(?P<finish_segments>\d+) segments$",
        "STW totals",
    )
    marked = one_match(
        text,
        r"^gc: marked-set census majors (?P<majors>\d+), headers (?P<headers>\d+), block headers (?P<block_headers>\d+), refcount-removed headers (?P<refcount_removed_headers>\d+)$",
        "marked-set census",
    )
    marked_kinds = one_match(
        text,
        r"^gc: marked-set kinds object (?P<object>\d+), function-bytecode (?P<function_bytecode>\d+), var-ref (?P<var_ref>\d+), realm-context (?P<realm_context>\d+), module (?P<module>\d+), shape (?P<shape>\d+)$",
        "marked-set kinds",
    )
    trace_classes = one_match(
        text,
        r"^gc: marked-set trace classes ordinary-object (?P<ordinary_object>\d+), fast-array (?P<fast_array>\d+), bytecode-function (?P<bytecode_function>\d+), exotic-object (?P<exotic_object>\d+), non-object (?P<non_object>\d+)$",
        "marked-set trace classes",
    )
    storage = indexed_matches(
        text,
        r"^gc: mark storage (?P<component>[a-z_]+) allocation-touches (?P<allocation_touches>\d+), allocated-bytes (?P<allocated_bytes>\d+), touched-cache-lines (?P<touched_cache_lines>\d+)$",
        "mark storage",
        "component",
        {
            "base",
            "shape",
            "property_slots",
            "dense_elements",
            "trace_payload",
            "payload_backing",
        },
    )
    trace_class_storage = indexed_matches(
        text,
        r"^gc: mark trace class storage (?P<trace_class>[a-z_]+) allocation-touches (?P<allocation_touches>\d+), allocated-bytes (?P<allocated_bytes>\d+), touched-cache-lines (?P<touched_cache_lines>\d+)$",
        "mark trace class storage",
        "trace_class",
        {
            "ordinary_object",
            "fast_array",
            "bytecode_function",
            "exotic_object",
            "non_object",
        },
    )
    inline_properties = indexed_matches(
        text,
        r"^gc: inline property upper slots (?P<slots>\d+), eligible-objects (?P<eligible_objects>\d+), external-allocated-bytes (?P<external_allocated_bytes>\d+), external-touched-cache-lines (?P<external_touched_cache_lines>\d+)$",
        "inline property upper",
        "slots",
        {"1", "2", "4"},
    )
    inline_ordinary_properties = indexed_matches(
        text,
        r"^gc: inline ordinary property upper slots (?P<slots>\d+), eligible-objects (?P<eligible_objects>\d+), external-allocated-bytes (?P<external_allocated_bytes>\d+), external-touched-cache-lines (?P<external_touched_cache_lines>\d+)$",
        "inline ordinary property upper",
        "slots",
        {"1", "2", "4"},
    )

    if collections["minor"] != minors["collections"]:
        raise SnapshotError("minor collection rows disagree")
    if minor_stw["total"] != sum(minor_phases.values()):
        raise SnapshotError("minor phase totals do not add to total STW")
    if minor_pause_variant == "available":
        if minor_pause_distribution["retained"] > minor_pause_distribution["total"]:
            raise SnapshotError("retained minor pause count exceeds lifetime total")
    elif minor_pause_distribution["drops"] != 0 and minors["collections"] == 0:
        raise SnapshotError("minor pause samples dropped without a minor collection")
    if conservative_variant == "available" and conservative_young["verified_minors"] != minors["collections"]:
        raise SnapshotError("conservative-only verified minor count disagrees")
    if collections["entries"] < collections["major"] + collections["minor"]:
        raise SnapshotError("completed collections exceed collection entries")
    if incremental["completed"] > collections["major"]:
        raise SnapshotError("incremental majors exceed all completed majors")
    if envelope["measured"] > incremental["completed"]:
        raise SnapshotError("measured envelopes exceed completed incremental majors")
    if envelope["forced"] != incremental["forced"]:
        raise SnapshotError("cycle envelope and incremental forced counts disagree")
    if envelope["measured"] == 0:
        if any(envelope[key] != 0 for key in (
            "start", "threshold", "begin", "peak",
            "begin_over_threshold_x1000000",
            "peak_over_threshold_x1000000", "peak_over_start_x1000000",
        )):
            raise SnapshotError("empty cycle envelope has a nonzero max tuple")
    else:
        if (envelope["threshold"] == 0 or envelope["peak"] < envelope["begin"] or
                envelope["peak"] < envelope["threshold"]):
            raise SnapshotError("cycle envelope max tuple is not a threshold crossing")
        expected_bt = (
            envelope["begin"] * 1_000_000 + envelope["threshold"] - 1
        ) // envelope["threshold"]
        expected_pt = (
            envelope["peak"] * 1_000_000 + envelope["threshold"] - 1
        ) // envelope["threshold"]
        expected_ps = 0 if envelope["start"] == 0 else (
            envelope["peak"] * 1_000_000 + envelope["start"] - 1
        ) // envelope["start"]
        if envelope["begin_over_threshold_x1000000"] != expected_bt:
            raise SnapshotError("cycle envelope B/T ratio is inconsistent")
        if envelope["peak_over_threshold_x1000000"] != expected_pt:
            raise SnapshotError("cycle envelope P/T ratio is inconsistent")
        if envelope["peak_over_start_x1000000"] != expected_ps:
            raise SnapshotError("cycle envelope P/S ratio is inconsistent")
    if allocation_shape["publications"] != allocation_shape["below_large"] + allocation_shape["large"]:
        raise SnapshotError("allocation histogram populations disagree")
    if allocation_shape["covered"] > allocation_shape["below_large"]:
        raise SnapshotError("small-space coverage exceeds below-large population")
    if barriers["calls"] != barriers["young_owner"] + barriers["old_target"] + barriers["remembered_owner"]:
        raise SnapshotError("generational barrier exits do not add to calls")
    marking_exits = sum(marking_barriers[key] for key in (
        "marked_target", "unpublished_owner", "unpublished_target",
        "requeued_owner", "shaded_target",
    ))
    if marking_barriers["calls"] != marking_exits:
        raise SnapshotError("marking barrier exits do not add to calls")
    if phases["finish_conservative_seed_subset"] > phases["finish_remark_total"]:
        raise SnapshotError("finish conservative subset exceeds total remark")
    if major_pause["retained"] > major_pause["total"]:
        raise SnapshotError("retained pause count exceeds lifetime total")
    expected_ratio = 0 if block["live"] == 0 else (
        block["committed"] * 1000 + block["live"] - 1
    ) // block["live"]
    if block["committed_over_live_x1000"] != expected_ratio:
        raise SnapshotError("block committed/live ratio is inconsistent")
    if decommit["current"] != max(
        decommit_totals["decommitted"] - decommit_totals["recommitted"], 0
    ):
        raise SnapshotError("current decommitted bytes are inconsistent")
    if doomed["destroyed_objects"] > doomed["condemned_headers"]:
        raise SnapshotError("destroyed object count exceeds condemned headers")
    if marked["majors"] > collections["major"]:
        raise SnapshotError("marked-set censuses exceed completed majors")
    if marked["headers"] != sum(marked_kinds.values()):
        raise SnapshotError("marked kind partition does not add to headers")
    if marked["headers"] != sum(trace_classes.values()):
        raise SnapshotError("marked trace-class partition does not add to headers")
    if marked["block_headers"] > marked_kinds["object"]:
        raise SnapshotError("marked block headers exceed marked objects")
    expected_refcount_removed = sum(
        marked_kinds[key]
        for key in ("object", "function_bytecode", "var_ref", "module")
    )
    if marked["refcount_removed_headers"] != expected_refcount_removed:
        raise SnapshotError("refcount-removed marked partition is inconsistent")
    if storage["base"]["allocation_touches"] != marked["headers"]:
        raise SnapshotError("base allocation touches differ from marked headers")
    if storage["shape"]["allocation_touches"] != marked_kinds["object"]:
        raise SnapshotError("shape allocation touches differ from marked objects")
    for metric in ("allocation_touches", "allocated_bytes", "touched_cache_lines"):
        if sum(row[metric] for row in storage.values()) != sum(
            row[metric] for row in trace_class_storage.values()
        ):
            raise SnapshotError(f"trace class storage does not partition {metric}")
    for trace_class, marked_count in trace_classes.items():
        if trace_class_storage[trace_class]["allocation_touches"] < marked_count:
            raise SnapshotError(
                f"trace class {trace_class} has fewer allocation touches than headers"
            )
    property_storage = storage["property_slots"]
    previous = {
        "eligible_objects": 0,
        "external_allocated_bytes": 0,
        "external_touched_cache_lines": 0,
    }
    for slots in ("1", "2", "4"):
        row = inline_properties[slots]
        for metric in previous:
            if row[metric] < previous[metric]:
                raise SnapshotError(
                    f"inline property upper is not monotonic at {slots} slots"
                )
        if row["eligible_objects"] > property_storage["allocation_touches"]:
            raise SnapshotError("inline eligible objects exceed property allocations")
        if row["external_allocated_bytes"] > property_storage["allocated_bytes"]:
            raise SnapshotError("inline bytes exceed external property bytes")
        if row["external_touched_cache_lines"] > property_storage["touched_cache_lines"]:
            raise SnapshotError("inline cache lines exceed external property cache lines")
        previous = row
    previous = {
        "eligible_objects": 0,
        "external_allocated_bytes": 0,
        "external_touched_cache_lines": 0,
    }
    for slots in ("1", "2", "4"):
        row = inline_ordinary_properties[slots]
        all_classes = inline_properties[slots]
        for metric in previous:
            if row[metric] < previous[metric]:
                raise SnapshotError(
                    f"inline ordinary property upper is not monotonic at {slots} slots"
                )
            if row[metric] > all_classes[metric]:
                raise SnapshotError(
                    f"inline ordinary property upper exceeds all classes for {metric}"
                )
        previous = row
    for phase in ("begin", "increment", "destroy", "finish"):
        ns = stw[f"{phase}_ns"]
        segments = stw[f"{phase}_segments"]
        if ns != 0 and segments == 0:
            raise SnapshotError(f"{phase} STW time has no phase segment")
        if slice_max[phase] > ns:
            raise SnapshotError(f"{phase} phase-segment max exceeds total")

    return {
        "allocations": {
            "publications": allocation_shape["publications"],
            "payloadBytes": allocation_shape["payload_bytes"],
            "p50BelowLarge": allocation_shape["p50"],
            "p95BelowLarge": allocation_shape["p95"],
            "p99BelowLarge": allocation_shape["p99"],
            "maxSmall": allocation_shape["max_small"],
            "coveredBySmall": allocation_shape["covered"],
            "belowLarge": allocation_shape["below_large"],
            "large": allocation_shape["large"],
        },
        "barriers": {
            "generational": {
                "calls": barriers["calls"],
                "exitYoungOwner": barriers["young_owner"],
                "exitOldTarget": barriers["old_target"],
                "rememberedOwner": barriers["remembered_owner"],
            },
            "marking": {
                "calls": marking_barriers["calls"],
                "exitMarkedTarget": marking_barriers["marked_target"],
                "exitUnpublishedOwner": marking_barriers["unpublished_owner"],
                "exitUnpublishedTarget": marking_barriers["unpublished_target"],
                "requeuedOwner": marking_barriers["requeued_owner"],
                "shadedTarget": marking_barriers["shaded_target"],
            },
            "totalCalls": barriers["calls"] + marking_barriers["calls"],
        },
        "blockHeap": {
            "committed": block["committed"],
            "live": block["live"],
            "committedOverLiveX1000": block["committed_over_live_x1000"],
            "superblocks": block["superblocks"],
            "largeMaps": block["large_maps"],
            "decommittedCumulative": decommit_totals["decommitted"],
            "recommittedCumulative": decommit_totals["recommitted"],
            "thresholdGrowthResets": thresholds["growth"],
            "thresholdSmallHeapFloorResets": thresholds["small_heap_floor"],
            "decommitChecks": decommit["checks"],
            "releasedBlocksCumulative": decommit["released_blocks"],
            "currentDecommitted": decommit["current"],
            "maxDecommitBatch": decommit["max_batch"],
            "trimAttempts": trim["attempts"],
            "trimSuccesses": trim["successes"],
        },
        "cycles": {
            "collectionEntries": collections["entries"],
            "majorCompleted": collections["major"],
            "failed": collections["failed"],
            "minor": collections["minor"],
            "incrementalCompleted": incremental["completed"],
            "incrementalAborted": incremental["aborted"],
            "incrementalForced": incremental["forced"],
            "markSteps": incremental["mark_steps"],
            "envelope": {
                "measured": envelope["measured"],
                "skipped": envelope["skipped"],
                "maxPeakOverThreshold": {
                    "start": envelope["start"],
                    "threshold": envelope["threshold"],
                    "begin": envelope["begin"],
                    "peak": envelope["peak"],
                    "beginOverThresholdX1000000": envelope["begin_over_threshold_x1000000"],
                    "peakOverThresholdX1000000": envelope["peak_over_threshold_x1000000"],
                    "peakOverStartX1000000": envelope["peak_over_start_x1000000"],
                    "incrementalWindowGrowthBytes": envelope["peak"] - envelope["begin"],
                },
                "forcedFinishes": envelope["forced"],
                "passesPeakOverThreshold36Over35": (
                    envelope["measured"] != 0
                    and envelope["peak"] * 35 < envelope["threshold"] * 36
                ),
            },
        },
        "collector": {
            "objectsFreed": collector["objects_freed"],
            "zeroRefDrains": collector["zero_ref_drains"],
        },
        "generation": {
            "currentYoung": generation["young"],
            "rememberedOwners": generation["remembered_owners"],
            "minorReclaimed": minors["reclaimed"],
            "promotedByMinor": minors["promoted_by_minor"],
            "promotedAll": minors["promoted_all"],
            "rememberedWithoutYoung": minors["remembered_without_young"],
            "rememberedDrops": minors["remembered_drops"],
            "minorSuspensions": minors["suspensions"],
            "minorYoungAtStartMean": minor_work["young_mean"],
            "minorYoungAtStartMax": minor_work["young_max"],
            "minorPauseDistribution": {
                "available": minor_pause_variant == "available",
                "p50": minor_pause_distribution.get("p50", 0),
                "p95": minor_pause_distribution.get("p95", 0),
                "p99": minor_pause_distribution.get("p99", 0),
                "max": minor_pause_distribution.get("max", 0),
                "samplesRetained": minor_pause_distribution.get("retained", 0),
                "samplesTotal": minor_pause_distribution.get("total", 0),
                "sampleDrops": (
                    minor_pause_distribution["total"] - minor_pause_distribution["retained"]
                    if minor_pause_variant == "available"
                    else minor_pause_distribution["drops"]
                ),
            },
            "conservativeOnlyYoung": {
                "available": conservative_variant == "available",
                "young": conservative_young.get("young", 0),
                "verifiedMinors": conservative_young.get("verified_minors", 0),
            },
        },
        "heapBytes": {
            "live": heap["live"],
            "accountPeak": heap["account_peak"],
        },
        "weakState": {
            "weakRefsCurrent": weak["weak_refs"],
            "finalizerQueueCurrent": weak["finalizer_queue"],
        },
        "doomed": {
            "condemnedHeaders": doomed["condemned_headers"],
            "destroyedCountedObjects": doomed["destroyed_objects"],
            "parkedEntriesDrained": doomed["parked_entries_drained"],
            "parkedDrainSlices": doomed["parked_drain_slices"],
        },
        "marking": {
            "clearMarksNonBlockHeaders": phase_work["clear_marks_nonblock_headers"],
            "retiredNonBlockHeaders": phase_work["retired_nonblock_headers"],
            "retiredYoungBlocks": phase_work["retired_young_blocks"],
            "retiredRememberedSets": phase_work["retired_remembered_sets"],
        },
        "markFootprint": {
            "majors": marked["majors"],
            "markedHeaders": marked["headers"],
            "markedPerMajorX1000": (
                0 if marked["majors"] == 0
                else marked["headers"] * 1000 // marked["majors"]
            ),
            "blockHeaders": marked["block_headers"],
            "refcountRemovedHeaders": marked["refcount_removed_headers"],
            "byKind": {
                "object": marked_kinds["object"],
                "functionBytecode": marked_kinds["function_bytecode"],
                "varRef": marked_kinds["var_ref"],
                "realmContext": marked_kinds["realm_context"],
                "module": marked_kinds["module"],
                "shape": marked_kinds["shape"],
            },
            "byTraceClass": {
                "ordinaryObject": trace_classes["ordinary_object"],
                "fastArray": trace_classes["fast_array"],
                "bytecodeFunction": trace_classes["bytecode_function"],
                "exoticObject": trace_classes["exotic_object"],
                "nonObject": trace_classes["non_object"],
            },
            "storage": {
                component: {
                    "allocationTouches": row["allocation_touches"],
                    "allocatedBytes": row["allocated_bytes"],
                    "touchedCacheLines": row["touched_cache_lines"],
                    "averageAllocatedBytesX1000": (
                        0 if row["allocation_touches"] == 0
                        else row["allocated_bytes"] * 1000 // row["allocation_touches"]
                    ),
                    "cacheLinesPerMarkedX1000": (
                        0 if marked["headers"] == 0
                        else row["touched_cache_lines"] * 1000 // marked["headers"]
                    ),
                }
                for component, row in storage.items()
            },
            "traceClassStorage": {
                trace_class: {
                    "markedHeaders": trace_classes[trace_class],
                    "allocationTouches": row["allocation_touches"],
                    "allocationTouchesPerMarkedX1000": (
                        0 if trace_classes[trace_class] == 0 else
                        row["allocation_touches"] * 1000
                        // trace_classes[trace_class]
                    ),
                    "allocatedBytes": row["allocated_bytes"],
                    "averageAllocatedBytesX1000": (
                        0 if row["allocation_touches"] == 0 else
                        row["allocated_bytes"] * 1000 // row["allocation_touches"]
                    ),
                    "touchedCacheLines": row["touched_cache_lines"],
                    "cacheLinesPerMarkedX1000": (
                        0 if trace_classes[trace_class] == 0 else
                        row["touched_cache_lines"] * 1000
                        // trace_classes[trace_class]
                    ),
                }
                for trace_class, row in trace_class_storage.items()
            },
            "allocationTouches": sum(
                row["allocation_touches"] for row in storage.values()
            ),
            "allocationTouchesPerMarkedX1000": (
                0 if marked["headers"] == 0 else
                sum(row["allocation_touches"] for row in storage.values())
                * 1000 // marked["headers"]
            ),
            "allocatedBytes": sum(row["allocated_bytes"] for row in storage.values()),
            "touchedCacheLines": sum(
                row["touched_cache_lines"] for row in storage.values()
            ),
            "cacheLinesPerMarkedX1000": (
                0 if marked["headers"] == 0 else
                sum(row["touched_cache_lines"] for row in storage.values())
                * 1000 // marked["headers"]
            ),
            "inlinePropertyUpper": {
                f"slots{slots}": {
                    "eligibleObjects": row["eligible_objects"],
                    "externalAllocatedBytes": row["external_allocated_bytes"],
                    "externalTouchedCacheLines": row["external_touched_cache_lines"],
                    "cacheLinesPerMarkedX1000": (
                        0 if marked["headers"] == 0 else
                        row["external_touched_cache_lines"]
                        * 1000 // marked["headers"]
                    ),
                }
                for slots, row in inline_properties.items()
            },
            "inlineOrdinaryPropertyUpper": {
                f"slots{slots}": {
                    "eligibleObjects": row["eligible_objects"],
                    "externalAllocatedBytes": row["external_allocated_bytes"],
                    "externalTouchedCacheLines": row["external_touched_cache_lines"],
                    "cacheLinesPerMarkedX1000": (
                        0 if marked["headers"] == 0 else
                        row["external_touched_cache_lines"]
                        * 1000 // marked["headers"]
                    ),
                }
                for slots, row in inline_ordinary_properties.items()
            },
        },
        "pauseNs": {
            "major": {
                "p50": major_pause["p50"],
                "p95": major_pause["p95"],
                "p99": major_pause["p99"],
                "max": major_pause["max"],
                "retainedPauses": major_pause["retained"],
                "totalPauses": major_pause["total"],
            },
            "minor": minor_stw,
            "minorPhaseTotals": {
                "clear": minor_phases["clear"],
                "roots": minor_phases["roots"],
                "conservative": minor_phases["conservative"],
                "remembered": minor_phases["remembered"],
                "trace": minor_phases["trace"],
                "sweepDestroy": minor_phases["sweep_destroy"],
                "promote": minor_phases["promote"],
                "other": minor_phases["other"],
            },
            "incrementalCycleLast": incremental["last_stw"],
            "incrementalCycleMax": incremental["max_stw"],
            "incrementalPhaseSegmentMax": slice_max,
            "incrementalSubphaseTotals": {
                "beginClear": phases["begin_clear"],
                "beginPreciseSeed": phases["begin_precise_seed"],
                "beginConservativeSeed": phases["begin_conservative_seed"],
                "beginRetire": phases["begin_retire"],
                "finishRemarkTotal": phases["finish_remark_total"],
                "finishConservativeSeedSubset": phases["finish_conservative_seed_subset"],
                "finishWeak": phases["finish_weak"],
                "finishCondemn": phases["finish_condemn"],
            },
            "stwTotals": {
                "begin": {"ns": stw["begin_ns"], "segments": stw["begin_segments"]},
                "increment": {"ns": stw["increment_ns"], "segments": stw["increment_segments"]},
                "destroy": {"ns": stw["destroy_ns"], "segments": stw["destroy_segments"]},
                "finish": {"ns": stw["finish_ns"], "segments": stw["finish_segments"]},
            },
        },
        "retirement": retirement,
    }


def load_snapshot(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise SnapshotError(f"cannot read snapshot {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SnapshotError(f"snapshot root is not an object: {path}")
    return value


def comparable_runs(baseline: dict, candidate: dict) -> tuple[dict, dict]:
    for key in ("schemaVersion", "kind"):
        if baseline.get(key) != candidate.get(key):
            raise SnapshotError(f"snapshot {key} differs")
    if baseline.get("engine", {}).get("configSignature") != candidate.get("engine", {}).get("configSignature"):
        raise SnapshotError("engine config signatures differ")
    if baseline.get("workload") != candidate.get("workload"):
        raise SnapshotError("workload provenance differs")

    def index(snapshot: dict) -> dict:
        runs = snapshot.get("runs")
        if not isinstance(runs, list):
            raise SnapshotError("snapshot runs is not a list")
        indexed = {run.get("benchmark"): run for run in runs if isinstance(run, dict)}
        if len(indexed) != len(runs) or None in indexed:
            raise SnapshotError("snapshot has duplicate or missing benchmark names")
        return indexed

    old_runs = index(baseline)
    new_runs = index(candidate)
    if old_runs.keys() != new_runs.keys():
        raise SnapshotError("snapshot benchmark sets differ")
    for bench in old_runs:
        if old_runs[bench].get("fixedSourceSha256") != new_runs[bench].get("fixedSourceSha256"):
            raise SnapshotError(f"fixed-work source differs for {bench}")
    return old_runs, new_runs


def numeric_leaves(value: object, prefix: str = "") -> dict[str, int]:
    if isinstance(value, bool):
        return {}
    if isinstance(value, int):
        return {prefix: value}
    if not isinstance(value, dict):
        return {}
    leaves: dict[str, int] = {}
    for key, child in value.items():
        path = f"{prefix}.{key}" if prefix else key
        leaves.update(numeric_leaves(child, path))
    return leaves


def compare_snapshots(
    baseline: dict,
    candidate: dict,
    threshold_percent: float,
    threshold_absolute: int,
) -> list[dict]:
    if threshold_percent < 0 or threshold_absolute < 0:
        raise SnapshotError("comparison thresholds must be non-negative")
    old_runs, new_runs = comparable_runs(baseline, candidate)
    drifts: list[dict] = []
    for bench in sorted(old_runs):
        old = numeric_leaves(old_runs[bench].get("stats", {}))
        new = numeric_leaves(new_runs[bench].get("stats", {}))
        if old.keys() != new.keys():
            missing = sorted(old.keys() - new.keys())
            added = sorted(new.keys() - old.keys())
            raise SnapshotError(
                f"stats schema differs for {bench}: missing={missing}, added={added}"
            )
        for metric in sorted(old):
            before = old[metric]
            after = new[metric]
            delta = after - before
            relative_percent = None if before == 0 else delta * 100.0 / abs(before)
            relative_limit = abs(before) * threshold_percent / 100.0
            if abs(delta) <= max(threshold_absolute, relative_limit):
                continue
            drifts.append(
                {
                    "benchmark": bench,
                    "metric": metric,
                    "baseline": before,
                    "candidate": after,
                    "delta": delta,
                    "relativePercent": relative_percent,
                    "direction": "increase" if delta > 0 else "decrease",
                }
            )
    return drifts


def validate_cpu(cpu: int) -> None:
    if cpu < 0:
        raise SnapshotError("--cpu must be non-negative")
    if cpu in FORBIDDEN_CPUS:
        raise SnapshotError(
            f"CPU {cpu} is reserved for measurements; choose a non-reserved CPU"
        )
    affinity = os.sched_getaffinity(0)
    if cpu not in affinity:
        raise SnapshotError(
            f"CPU {cpu} is not in this process's allowed affinity {sorted(affinity)}"
        )


def run_checked(command: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        proc = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise SnapshotError(
            f"command timed out after {timeout}s: {' '.join(command)}"
        ) from exc
    if proc.returncode != 0:
        tail = (proc.stdout + "\n" + proc.stderr).strip()[-800:]
        raise SnapshotError(
            f"command exited {proc.returncode}: {' '.join(command)}\n{tail}"
        )
    return proc


def capture(args: argparse.Namespace) -> dict:
    validate_cpu(args.cpu)
    binary = Path(args.zjs).resolve()
    zoo = Path(args.zoo).resolve()
    bench_dir = zoo / "bench"
    if not binary.is_file():
        raise SnapshotError(f"zjs binary not found: {binary}")

    config_proc = run_checked(
        ["taskset", "-c", str(args.cpu), str(binary), "--print-config-signature"],
        args.timeout,
    )
    config = config_proc.stdout.strip()
    if "optimize=ReleaseFast" not in config:
        raise SnapshotError(f"expected a ReleaseFast zjs binary, got {config!r}")

    runs: list[dict] = []
    with tempfile.TemporaryDirectory(prefix="gc-stats-fixed-work-") as tmp:
        tmp_dir = Path(tmp)
        for bench in GC_HEAVY_SIX:
            original_path = bench_dir / f"{bench}.js"
            if not original_path.is_file():
                raise SnapshotError(f"benchmark not found: {original_path}")
            transformed = fixed_source(original_path.read_bytes(), original_path, 1)
            script = tmp_dir / original_path.name
            script.write_bytes(transformed)
            print(f"gc-stats snapshot: {bench} (one fixed-work run)", file=sys.stderr)
            proc = run_checked(
                ["taskset", "-c", str(args.cpu), str(binary), "--gc-stats", str(script)],
                args.timeout,
            )
            output = proc.stdout + "\n" + proc.stderr
            if not has_numeric_completion(output):
                non_gc = [
                    line for line in output.splitlines()
                    if line.strip() and not line.startswith("gc:")
                ]
                raise SnapshotError(
                    f"{bench} produced no numeric completion result; "
                    f"non-GC output: {non_gc[:8]!r}"
                )
            runs.append(
                {
                    "benchmark": bench,
                    "fixedSourceSha256": sha256_bytes(transformed),
                    "stats": parse_gc_stats(output),
                }
            )

    repo = PERF_DIR.parents[1]
    repo_desc = git_describe(repo)
    zoo_desc = git_describe(zoo)
    return {
        "schemaVersion": 6,
        "kind": "gc-heavy-six-fixed-work-structure",
        "interpretation": (
            "One run per benchmark; structural counts are diff guards. "
            "Nanosecond fields are diagnostic only, not a performance gate."
        ),
        "execution": {"cpu": args.cpu, "runsPerBenchmark": 1},
        "engine": {
            "configSignature": config,
            "sha256": sha256_of(binary),
            "sourceRevision": repo_desc["commit"],
            "sourceTreeDirty": repo_desc["dirty"],
            "sourceTrackedDirty": tracked_tree_dirty(repo),
        },
        "workload": {
            "suite": "javascript-zoo Octane deterministic fixed-work",
            "sourceRevision": zoo_desc["commit"],
            "sourceTreeDirty": zoo_desc["dirty"],
            "sourceTrackedDirty": tracked_tree_dirty(zoo),
            "iterationDivisor": 1,
        },
        "runs": runs,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zjs", default="zig-out/bin/zjs")
    parser.add_argument("--zoo", default="/home/aneryu/javascript-zoo")
    parser.add_argument("--cpu", type=int, default=0)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--output")
    parser.add_argument(
        "--compare",
        nargs=2,
        metavar=("BASELINE", "CANDIDATE"),
        help="compare two existing snapshots without running the engine",
    )
    parser.add_argument("--threshold-percent", type=float, default=10.0)
    parser.add_argument("--threshold-absolute", type=int, default=0)
    args = parser.parse_args()
    try:
        if args.compare:
            baseline_path, candidate_path = map(Path, args.compare)
            drifts = compare_snapshots(
                load_snapshot(baseline_path),
                load_snapshot(candidate_path),
                args.threshold_percent,
                args.threshold_absolute,
            )
            snapshot = {
                "schemaVersion": 6,
                "kind": "gc-shape-comparison",
                "baseline": str(baseline_path),
                "candidate": str(candidate_path),
                "thresholdPercent": args.threshold_percent,
                "thresholdAbsolute": args.threshold_absolute,
                "significantDriftCount": len(drifts),
                "significantDrifts": drifts,
            }
        else:
            snapshot = capture(args)
    except SnapshotError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    rendered = json.dumps(snapshot, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(rendered)
    else:
        sys.stdout.write(rendered)
    if args.compare and snapshot["significantDriftCount"] != 0:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
