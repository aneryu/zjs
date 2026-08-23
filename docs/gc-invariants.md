# Cycle collector invariants

Rules the current collector holds and a refactor must either preserve or
consciously replace. Every entry cites where it lives, so each one can be
re-read against the code rather than trusted from here. Behavioural baseline:
[perf/gc-baseline.md](perf/gc-baseline.md).

The collector is a three-phase trial-deletion mirror of QuickJS
(`src/core/object_gc.zig`, with `quickjs.c` line references inline). The
reference is cited for mechanism, but ECMA-262 and test262 are the semantic
authority (AGENTS.md, 2026-08-22 ruling).

## Ownership of edge enumeration

**The authority trace lives on `Object`, not in the collector.**
`Object.traceChildEdgesFallible` (`object.zig`) enumerates a node's child
edges beside the data it describes; `object_gc.zig` owns the phase driver and
the specialised mark arms. The 2026-08-22 split (Q11 T2) deliberately kept it
that way — moving enumeration into the collector required promoting 23
private payload accessors and was rejected.

**Specialised hot arms are copies and will drift.** `markOrdinaryObjectHot`
and `markFastArrayHot` hand-enumerate their edges for the hot path; hot arms
are never shared with cold bodies (standing policy — merging call layers has
fattened frames three times). That copy is the known hazard: in 2026-08-21
the fast-array arm was missing the iterator-next cache edge, so cycles
through it were never collected, invisible to both test262 and the leak
checker. Guards now compare each arm's visited-header set against the
authority (`src/tests/core.zig`, "cycle-mark hot arm matches authority child
headers"), plus comptime dual lists of `CycleHotEdgeKind` for the ordinary,
fast-array and shape arms. **Adding an edge means updating the authority, the
arm, and its comptime list; the guard fails if you miss one.**

## Failure and ordering

**Exactly one fallible operation per round, and it runs first.**
`gcRemoveWeakObjects` is the only step that can fail; it completes before any
trial refcount, list membership or round flag changes
(`destroyRuntimeCyclesWithValueRoots`). Everything after it is a committed
no-error path. A refactor that introduces a second failure point breaks the
"partially collected heap is unreachable" property this buys.

**Trial refcounts must balance exactly.** The decref phase lowers counts, the
scan phase restores them for reachable nodes. An over-trace (visiting an edge
the destroy side does not own) underflows the trial count and produces a
use-after-free; an under-trace only leaks. Every discrepancy found in the
2026-08-21 audit pointed in the leak direction, and that asymmetry is why the
edge guards exist.

**Free happens in two passes.** Pass A strips resources, Pass B frees the
husks (`gc_free_cycles`, quickjs.c:6797-6810). If class-payload finalizers
were deferred, Pass B is held back: those payloads may still hold JSValues
into the condemned cycle and must release them without dereferencing freed
object memory.

## Destroy-side pairing

Every payload kind that a trace arm visits must have a matching release on
the destroy side, and vice versa. A missing trace arm leaks; a missing
destroy arm double-frees or leaks the child. `markChildrenCold`'s switch is
exhaustive so a new GC kind cannot be silently skipped (Q8), and the four
zero-ref kind sets are one comptime predicate rather than four hand-copies.
`gc.ref_kind_catalog` classifies all eight kinds: the six intrusive Registry
carriers versus String/Rope and BigInt, which never enter `gc_obj_list` and
need an allocation-ledger census. A Rope is not a leaf.
`ArgumentsPayload` was found with destroy but no trace arm and fixed the same
way.

Per-family "the cycle is released" regression tests exist for eleven payload
families (`src/tests/core.zig`); each was proven to fail with its trace arm
removed. These catch trace-side misses — the allocator leak check only
catches destroy-side ones.

## What the gates do and do not cover

- test262 and the unified suite have shipped **green over real collector
  defects** twice (the iterator-next miss, and two collection-iteration
  defects). Suite green is not evidence about the collector.
- The leak checker only sees destroy-side misses.
- The edge-parity guards and per-family cycle tests are the collector's
  actual safety net, and both are deletion-probe verified.
- `--gc-stats` measures behaviour; see the baseline document for what the
  current numbers are and which of them are stable enough to compare.

## Representation is out of scope

Converting `ObjectStorage` to a tagged union or reordering `Object` fields is
forbidden as part of a GC change (Q11): QuickJS-parity representation is a
load-bearing wall, and those are representation experiments with their own
measurement burden. The four `align(16)` mark-arm entry pins have a
measurement lineage in git and travel with their functions when moved.
