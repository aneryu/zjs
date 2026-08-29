# Tracing GC: pause-first execution plan

**Status (2026-08-26): Phases 0-2 and Phase 3's first tranche (sliced
destruction, §4b) executed and landed on `gc/tracing`; every outcome,
including the two missed lines, is recorded in its section. Standing against
§1.3: minor pauses mean 1.0 ms / max 2.8 ms; major-ring p50 1.00 ms, p95
1.007 ms, p99 33.6 ms, max 34.8 ms -- the tail is now exactly the two O(heap)
walks (begin's clearMarks and the condemn walk), which fall with versioned
marks and the block heap. Throughput geomean 1.31, bench-v8 combined 0.79 of
rc, with splay carrying nearly the whole residue in both. Remaining Phase 3
items stay trigger-gated.**

Companion to `tracing-gc-design.md`. That document says what the collector
should be; this one sequences the work from where the implementation stands on
2026-08-26, after the arena-geometry campaign and two adversarial reviews of it.
When the two disagree, the design document wins.

## 0. What this plan optimizes for, in order

1. **Pause.** The product goal is §1.1's "bound interactive pauses", and §1.3
   makes it concrete: major STW p99 below 2 ms, minor p99 below 1 ms. This is
   the reason the collector is being replaced at all — RC already fails the
   pause row (p99 2.45 ms, max 46.6 ms on the V8 suite), and its failure is a
   tail. The current tracer replaces that tail with a uniform failure: every
   major on a 49 MB live set pauses ~112 ms. A design that improves throughput
   while leaving that number is missing the point of its own charter.
2. **Throughput parity.** §1.3's gate is "no statistically supported
   regression" against RC — parity, not improvement. Currently 1.31 geomean on
   the fixed-work suite; splay 3.16 is almost the entire gap.
3. **Memory envelope.** §1.3 has two separate rows: allocator-side quiescent
   committed/live < 1.3, and collector-pacing cycle peak/live < 2.0 (owner
renegotiation 2026-08-29; the cap was 1.8 while the growth factor was 1.75,
and the two move together by construction — see the growth-2.0 adoption
below). They do
   not share a numerator, denominator, or sampling point; §P1.2's 2026-08-28
   correction below defines both before using either as a gate.

## 1. Baseline (2026-08-26, corrected)

Fixed-work scripts (`doDeterministic=true`), idle big cores, matched-pair
binaries from one HEAD, census-subtracted major-only pause ring. Numbers from
the re-reviewed measurement; the earlier "41 majors / 70%" figures mixed a
pre-backoff binary into the arithmetic and are superseded by these.

| | deltablue | regexp | pdfjs | raytrace | earley-boyer | splay |
|---|---|---|---|---|---|---|
| trace/rc wall | 0.985 | 1.052 | 1.073 | 1.123 | 1.254 | **3.162** |

splay anatomy: ~35 majors x ~112 ms ≈ 3.9 s of 6.23 s wall (**~63% of the run
inside GC pauses**; ~92% of the gap to RC). Mutator time 2.33 s vs RC's 1.97 s
total — the mutator itself carries ~0.3 s of barrier and allocation-path tax.
Minors are yield-suspended on splay (young survival 95%+); each probe minor
costs ~29 ms because sweep currently breaks mark stickiness (see P1.1).

## 2. Phase 0 — correctness prerequisites (small, blocking)

### P0.1 Fix the marking barrier protocol (tri-color violation)

`shadeForConcurrentMark` (gc.zig:1973) marks its target and never enqueues it,
so a barrier-shaded object is black-without-having-been-traced: pre-existing
children whose only path runs through it are never marked and get swept alive.
The final remark cannot save them — `shade()` skips already-marked objects.
This hole exists for **single-threaded incremental marking too**, not just for
a concurrent thread: an object traced in increment N and mutated in the
mutator window is not re-examined in increment N+1.

Fix: shade the **target grey** -- mark it AND push it onto the barrier queue
(`gc_mark_queue.zig`); the remark drains the queue, tracing each entry, with
queue overflow downgrading to one pass over every marked object.

Decision record: the first draft of this plan prescribed JSC's shape instead
(`Heap::addToRememberedSet` appends the **owner** to `m_mutatorMarkStack`,
Heap.cpp:1266-1268). JSC can afford owner-append because `CellState` gives it
a grey state that deduplicates it -- the second barrier on a remembered owner
takes the fast path. Our header has one mark bit and no free flag, so
owner-append would re-push the same hot owner on every store, flood the
4096-entry ring, and force the coarse overflow rescan every cycle. Shading
the target dedups for free (the mark bit IS the already-queued test), at the
documented cost of more floating garbage. `markAssist` was deleted rather
than kept: under grey-queue semantics an entry's presence in the queue is the
only record that its children are untraced, so popping without tracing --
which is all a Registry-level assist can do -- loses work. The bounded
increment returns in Phase 2 inside `gc_trace_stw`, where tracing lives.

Evidence required: a unit test that constructs the counterexample — owner
traced black, store of an untraced object whose other paths are then erased,
remark, assert the stored object's child survives. The existing
`collectConcurrentMajor` test is green over the broken protocol precisely
because it never builds this interleaving.

### P0.2 Take the accidental costs off the barrier fast path

Two findings, one site (`generationalBarrier`, gc.zig:2050-2073):

- `markingActive()` performs an `.acquire` atomic load per call — an `ldar` on
  every barrier in tracer builds (55.8 M calls on earley-boyer). Until a
  marker thread exists there is exactly one thread; relax to `.monotonic`
  (plain `ldr`) with a comment that the JSC threshold protocol
  (`m_barrierThreshold` as a plain field, fences only in the slow path —
  HeapInlines.h:106, Heap.cpp:2871) is the shape to adopt when a real marker
  lands.
- Two unconditional stat RMWs per call (`barrier_calls` plus one outcome
  counter). JSC's fast path carries zero counters. Move them under
  `detailed_reports` or into the slow path.

Gates for Phase 0: both unit suites, macro-check with `ZJS_GC_ARENA_AUDIT=1`,
plus the new interleaving test red-on-old-code.

## 3. Phase 1 — collection economics (cheap, shrinks what Phase 2 must bound)

### P1.1 Restore sticky marks (the implementation contradicts its own design)

§8.2 defines old as `allocated && marked`, and the Debug invariant at
gc.zig:2382-2386 was already amended to permit sticky marks — but
`sweepUnmarked` (gc_trace_stw.zig:996-998) clears every survivor's mark during
the major sweep. Consequence: the first minor after any major finds the whole
heap unmarked and re-traces the entire live set from the roots. That is the
~29 ms probe minor on splay, and it makes the 1 ms minor target unreachable
regardless of any other work.

Change: the major sweep keeps survivor marks set (the next major's
`clearMarks` is already the clearer; today it clears twice), and the
`young = false` retirement folds into the same sweep walk, deleting
`clearYoungState`'s third whole-heap pass (majors go from 3 walks to 2; the
last walk falls to versioned marks in Phase 3).

Precondition: audit the non-collector readers of `flags.mark` under
trace_stw — runtime.zig:2512 (weak-husk discriminator), object_gc.zig:60/81,
object.zig:1895/1942/2081/2108 (trial-deletion sites; believed rc-only),
gc.zig:1562 (registration assert; holds because `initGcPrefix` rewrites the
flags byte on slab reuse). Each gets a one-line disposition in the commit.

Expected: probe minors drop from O(live) to O(young + remembered); minor
economics become measurable again on workloads where young objects do die.

### P1.2 A growth factor for the collector we actually have

`resetGCThreshold` copies qjs's `live * 1.5` (quickjs.c:1795). That constant
governs qjs's **cycle** collector, which runs over a heap where refcounting
already freed every acyclic object; our tracer must trace to free anything.
Copying the constant across that semantic change is faithfulness to the wrong
collector — splay: RC completes in 16 collection rounds, the tracer performs
~35 whole-heap majors.

JSC's precedent for a full-tracing heap: `smallHeapGrowthFactor = 2`
(OptionsList.h:219; a 49 MB heap is "small" under
`smallHeapRAMFraction = 0.25`), medium 1.5, large 1.24.

Change: a tracer-specific factor ~2.0 (`tracer_heap_growth`), leaving the rc
build's qjs rule untouched, with the faithfulness argument in the constant's
doc comment. Verified non-blocker: `major_debt_threshold` (64 MB) cannot cap
this — `allocation_debt` is fed only by external-bytes registrations
(gc.zig:1247/1262), which pure JS object workloads never touch.

Measurement obligation: this deliberately spends the §1.3 memory envelope, so
the A/B must include peak RSS and quiescent committed/live across the six
benchmarks, both factors, and the result must stay inside cycle peak/live
< 1.8. If 2.0 breaks the envelope on some workload, bisect the factor.
(Resolved 2026-08-29: the owner renegotiated the cap to 2.0 and the compiled
factor moved to 2.0 — pricing in docs/slab-reuse-2026-08-29.md 种群治理节:
splay cycles −7.25%, six-benchmark cycles geomean 0.9867, peak RSS +10–13%,
JSC smallHeapGrowthFactor parity.)

Expected: majors roughly halve; splay from 3.16 toward ~2.0. This is the
single largest throughput lever available and it is one constant.

### P1.3 Bloom prefilter for conservative candidates

Today every stack word inside the bounds window costs a wyhash probe
(`arenas.contains`). JSC rejects almost every word with two ALU ops before any
hash structure: `TinyBloomFilter::ruleOut` (ConservativeRoots.cpp:168-173,
TinyBloomFilter.h:69-77), filter built per collection from the full block set.

**Soundness constraint the first draft of this idea missed:** the filter must
cover BOTH populations the resolver consults — arena bases AND the occupant
table's pages (standalone-prefix allocations past the slab ceiling). A filter
built from arenas alone would early-out on words pointing into standalone
objects and the scan would miss live objects: a use-after-free, not an
optimization. Build it at collection start by OR-ing both key sets (a few
hundred entries; per-collection rebuild is what JSC does and it sidesteps
bloom's inability to remove).

Expected: cuts the fixed per-word cost of every conservative scan, which is a
floor under both minor and major pause times.

### Phase 1 exit gate

Re-measure the six benchmarks fixed-work, matched pair, plus the memory rows.
Proceed to Phase 2 when splay ≤ ~2.0 and no other benchmark regresses past
1.1x its Phase-0 value. Everything here is also strictly useful to Phase 2:
fewer and cheaper majors mean fewer and smaller pauses to incrementalize.

**Outcome (2026-08-26).** P1.1 landed as designed: probe minors fell from
~29 ms to 0.85 ms mean / 2.07 ms max on splay -- the 1 ms minor target is in
reach -- and majors lost their third whole-heap walk (one wrinkle the design
missed: objects allocated DURING the sweep publish young behind the walk's
cursor; they form a contiguous tail run and are retired by a backward walk,
which the suffix invariant caught). P1.3 landed with the corrected two-
population filter. P1.2 landed at **1.75, not 2.0**: fixing the peak
instrument (the panel's `peak` field had echoed `live` for its whole history,
and per-allocation peak tracking is Debug-only, so the §1.3 rows had no
production instrument at all -- peak is now sampled at collection entry, one
@max per collection) showed that steady-state cycle peak/live equals the
growth factor by construction, so the §1.3 cap of 1.8 ruled 2.0 out at the
time. (2026-08-29: the renegotiation happened — owner raised the cap to 2.0
on the instrumented ABBA n=16 pricing, and the compiled factor is now 2.0.)

Result: splay 3.162 → 2.376 (majors ~41 → ~26), geomean 1.31 → 1.24, all
other benchmarks within noise of their Phase-0 values. **The splay ≤ ~2.0
line is missed**: it is reachable at a growth factor of 2.0 (measured 2.133)
but the constitution caps the factor first. The gate line was this plan's
estimate, not a design row; the design row wins. Raising it again is a
renegotiation of §1.3's 1.8 with the design's owner, not a tuning decision.
Residual splay RSS (479 MB vs heap peak 262 MB) is allocator retention --
survivors scattered across arenas keep pages committed -- which is the
quiescent committed/live row's territory and a block-heap (Phase 3) item.
Phase 2 proceeds: its goal does not depend on this line.

#### §1.3 memory-envelope correction and owner decision input (2026-08-28)

The original `gate_smoke.sh` evidence was block-allocator density, in milli:

| | deltablue | earley-boyer | pdfjs | raytrace | regexp | splay |
|---|---:|---:|---:|---:|---:|---:|
| block committed/live | 12.042 | 3.721 | 5.255 | 4.722 | 3.486 | 3.426 |

After rebasing onto `19324287`, the same ReleaseFast binary and identical
fixed-work sources produced these two end-of-run samples:

| sample | deltablue | earley-boyer | pdfjs | raytrace | regexp | splay |
|---|---:|---:|---:|---:|---:|---:|---:|
| schema-6 stats, CPU 4 | 12.043 | 3.920 | 5.851 | 4.720 | 4.119 | 3.774 |
| arena-audit smoke, CPU 18 | 14.855 | 3.672 | 6.338 | 4.720 | 4.092 | 3.773 |

Both samples fail the old raw 1.3 rule for all six. Their endpoint variation
does not change that verdict, but it confirms that a replacement committed
gate must define the scavenger/quiescent service point rather than treating an
arbitrary process-exit census as reproducible.

These figures all fail §1.3's **quiescent committed/live < 1.3** row. They do
**not** measure, and must not be compared with, the separate **cycle
peak/live < 1.8** row:

- `C`, block committed, charges an entire 2 MiB superblock when it is reserved,
  plus large mappings, and subtracts cell pages only after an explicit aged
  `madvise`. It therefore contains unused blocks, empty cells, deliberately
  stranded partially-free blocks, allocator metadata/granularity, and capacity
  that has not yet passed the one-second decommit age.
- `L_block`, the denominator printed beside it, is current allocated block-cell
  capacity (`allocated_count * cell_size`) plus medium user bytes and large
  mappings. It is an allocator occupancy census, not the settled logical
  account from which the next major threshold was chosen.
- §1.3's cycle quantity must instead use one accounting domain throughout.
  Let `S` be `MemoryAccount.allocated_bytes` after the preceding major's doomed
  objects have been excluded/destroyed, `T` the threshold selected from that
  same `S`, and `P` the maximum of that same account until the cycle completes.
  The two useful ratios are pacing `P/S` and true overshoot `P/T`; external
  memory is reported separately. The current panel's lifetime `account peak`
  beside GC-node-only `heap live` mixes scopes and is not either ratio.

The table in §1.3 is underspecified at this point: "report heap and external
bytes separately" does not define whether heap means the whole internal
`MemoryAccount` pressure domain or only GC-node bytes. The former is the
recommended normative definition because it is the domain that selects `T`;
both `P` and `S` must then include the same non-GC internal allocations. If the
owner instead wants a GC-node-only physical-heap envelope, it needs a separate
per-cycle `H_peak/H_live` instrument and the 1.75 account growth factor cannot
be used to derive its bound. What is invalid in either definition is the
existing hybrid `whole-account peak / GC-node live`.

Consequently there is no universal ordering between the two reported ratios,
although `C/L_block` is normally much larger on a small heap because it prices
retained allocator capacity that logical `P/S` deliberately does not. A gate
for quiescent commitment must also define quiescence: after doomed destruction
has drained and after a deterministic scavenger service point. Otherwise the
one-second wall-clock decommit rule makes `C` depend on host contention.

DeltaBlue is the limiting example for why a raw ratio is a poor small-heap
allocator gate, not evidence of a 12x GC growth overshoot. A same-revision
snapshot had one 2 MiB superblock and about 141 KiB of block live bytes:
`2,097,152 / 141,200 = 14.85x` before enough empty cell pages aged out. The
smoke run's 12.042x is the same fixed granularity after more decommit. Other
loads amortize that fixed mapping over larger live sets. As `L_block -> 0`,
`C/L_block` diverges even when the absolute retained capacity stays below one
superblock.

Recommended allocator gate: always report absolute `C - L_block`, and replace
one raw ratio across all heap sizes with

```text
C - L_block <= F + 0.30 * L_block
```

where `F` is the topology-required fixed commitment (2 MiB per populated
superblock kind: classed and, if used, medium; large mappings are already
charged directly). Equivalently, after removing that explicit fixed floor,
the scalable committed overhead remains below the existing 30% intent. The
panel needs classed/medium counts before this can be an automated verdict; this
is a definition proposal, not an implementation claim.

For the cycle row, the implemented threshold is

```text
T = max(1.75 * S, S + 1.5 MiB).
```

On the growth arm, `P/S < 1.8` is mathematically attainable but very tight: it
allows only `1.8 / 1.75 - 1 = 2.857%` growth beyond `T`. The earlier splay
cycle probe measured `P/T = 1.000031` (about 0.0031%, 7,899 bytes), so the
observed 4.63x mixed-scope `account peak / GC-node live` was not incremental
allocation overshoot. Allocator fragmentation must not be added to logical
`P`; it belongs to the committed row above.

The panel cannot decompose that 4.63x into a byte count attributable to
non-GC internal allocations: its numerator and denominator do not provide the
paired whole-account `S` and `P`. The only defensible decomposition today is
qualitative: measured cycle overshoot was 7,899 bytes in that probe; the rest
of the apparent ratio is unquantifiable denominator-scope mismatch, not
evidence that those bytes existed as real overshoot.

The universal `P/S < 1.8` wording is nevertheless inconsistent with the
small-heap floor. There `T/S = 1 + 1.5 MiB/S`, which already exceeds 1.8 for
`S < 1.875 MiB` with zero overshoot and is unbounded as `S -> 0`. No larger
finite ratio fixes that definition for all heap sizes. Preserve the original
growth-arm intent by expressing the gate against the selected threshold:

```text
P/T < 36/35 (= 1.028571...); use 1.025 if the gate needs a rounded constant
```

`36/35` is exactly `1.8 / 1.75`; on the growth arm it retains the effective
`P/S < 1.8` decision. A rounded `1.03` would actually permit `P/S = 1.8025`,
so it is not a faithful hard gate; `1.025` leaves a small measurement margin.
On the floor arm either form becomes a meaningful bound around `S + 1.5 MiB`
instead of dividing a fixed allowance by a vanishing live set.
This is a performance target, not the implementation's safety guarantee: the
current forced-finish valve fires only beyond `P > 1.5T` (2.625S on the growth
arm), so forced finishes and the per-cycle `P/T` distribution must be reported.

Owner decision requested: do not raise 1.8 because block committed/live is
3-15x; that comparison crosses metrics. Split the two rows operationally,
retain the 1.8 growth-arm intent as `P/T < 36/35` (or a rounded-down 1.025),
and use the fixed-plus-scaled absolute envelope for allocator commitment.

#### §10 external-pressure domain audit (2026-08-28)

"External reported separately" is now pinned as a reporting rule, not a claim
that every external-classified byte is absent from `MemoryAccount`. Ordinary
ArrayBuffer backing over 32 bytes uses `rt.memory`, so it participates in the
same whole-account `S/T/B/P` domain and is also classified in the external
token/debt panel. Shared and embedder-adopted backing stays outside
`MemoryAccount`; its token adds `bytes * external_weight` to a separate
weighted-debt trigger. With defaults, 8 MiB of such backing reaches the
64 MiB debt threshold and requests a major without changing the ordinary heap
threshold.

The live account is symmetric across ordinary detach/replace/destroy, inline
storage release, and the final shared-store owner. Weighted allocation debt is
not a live-byte account and intentionally does not fall on free; a completed
major resets it. The executable core probe isolates this path by setting the
heap threshold to `maxInt`: seven rooted 1 MiB SharedArrayBuffers do not request
GC, the eighth queues `allocation_debt`, one poll increments the major count,
and final release plus collection leaves zero external bytes and tokens.

FNABI's byte-length default is present: token creation requires a byte count
and ordinary/adopted paths use backing `byte_length`. The public
`JSBytes.Store` does not yet expose a distinct price override, so the full
future ABI's mandatory price field is not implemented if that ruling requires
the caller to state a value other than the default. Growable shared buffers
charge the up-front committed `maxByteLength`, because that is the actual store
capacity in this implementation. The `--gc-stats` panel now emits current/peak
external bytes, token bytes/count, untracked bytes, alloc/free and invalid-
release counts, and weighted debt as a row separate from heap/account figures.
The raw untracked hook is only for inline bytes already inside the account and
does not itself request a major; it is not a valid FNABI route for off-account
memory.

**Measured outcome (2026-08-28; instrument `e0c4e1c9`, capture source
`02541f9d`).** `--gc-stats` now starts exact
per-allocation peak tracking when a completed major selects a same-account
`S/T` pair and stops it only when the next automatic incremental major,
including sliced destruction, completes. The first cycle has no preceding
policy baseline and is reported as skipped; manual thresholds invalidate the
pair instead of manufacturing evidence. The panel retains the coherent
`S/T/B/P` tuple from the cycle with maximum `P/T`, where `B` is the account at
incremental begin. `B/T` separates threshold-crossing granularity from the
additional `P-B` allocated during the incremental window.

One ReleaseFast fixed-work run per load on CPU 4 produced:

| workload | measured / skipped | S | T | B | P | B/T | P/T | P/S | P-B | forced | 36/35 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| deltablue | 967 / 1 | 511,665 | 2,084,529 | 2,088,433 | 2,088,641 | 1.001873 | 1.001973 | 4.082048 | 208 | 0 | pass |
| earley-boyer | 7,749 / 1 | 1,789,862 | 3,362,726 | 3,363,478 | 3,364,814 | 1.000224 | 1.000621 | 1.879930 | 1,336 | 0 | pass |
| pdfjs | 18 / 1 | 16,869,509 | 29,521,640 | 29,633,552 | 29,878,979 | 1.003791 | 1.012105 | 1.771183 | 245,427 | 0 | pass |
| raytrace | 3,733 / 1 | 439,665 | 2,012,529 | 2,154,481 | 2,154,793 | 1.070535 | **1.070690** | 4.900989 | 312 | 0 | **fail** |
| regexp | 235 / 1 | 638,070 | 2,210,934 | 2,434,961 | 2,769,434 | 1.101327 | **1.252609** | 4.340330 | 334,473 | 0 | **fail** |
| splay | 28 / 1 | 262,070 | 1,834,934 | 1,834,906 | 1,835,522 | 0.999985 | 1.000321 | 7.003938 | 616 | 0 | pass |

Splay's `B/T` slightly below one is valid: the allocation-threshold request
was recorded while the account was above `T`, then a small free occurred
before the request was serviced. Tracking P from the S/T reset, rather than
only from incremental begin, retains that real crossing peak.

The cycle row is therefore **measured and fails** for the declared corpus:
raytrace and regexp exceed `36/35`, although all six stay far below the
emergency `1.5T` forced-finish valve and report zero forced finishes. The
attribution differs. Raytrace's maximum is almost entirely present at begin
(`B/T = 1.070537`, then only 312 bytes to `P`), so its failure is allocation-
crossing granularity, not a slow incremental marker. Regexp is already 10.1%
over at begin and adds another 334,473 bytes before completion, so both
crossing granularity and the incremental window contribute. The very large
floor-arm `P/S` values remain the predicted reason the old universal 1.8 rule
was malformed; earley-boyer passes `P/T` while its same tuple has `P/S =
1.879930`.

The auditable snapshot is `tools/perf/gc_shape_snapshot.baseline.json`
(schema 6). Its source tracked tree is clean; lane-private untracked reports
make the broader `sourceTreeDirty` provenance flag true. No throughput score
or timing field from this one-run stats capture is used as performance
evidence. The allocator committed row remains separately measured and fails
under its current raw 1.3 rule.

## 4. Phase 2 — incremental marking (the pause goal itself)

The only work that moves §1.3's pause rows. Design sketch below; **the full
design gets its own review against tracing-gc-design.md §8.6 before
implementation** — the A2 lesson is that protocol scaffolding can validate an
unsound protocol if the review happens after the fact.

### Shape

Mutator-conducted increments, no second thread (JSC's `GCConductor::Mutator`
mode is the precedent; a single-threaded increment protocol is a strict subset
of §8.6's concurrent major and shares its barrier obligations):

1. **Begin (STW):** clearMarks, seed precise + conservative roots, publish
   `marking_active`.
2. **Increments:** at each `pollGC`, drain the mark queue under a time budget
   (~1 ms; `markAssist` and `gc_mark_queue` are the existing, currently
   orphaned pieces). Mutator runs between increments; the P0.1 barrier keeps
   its writes visible by enqueuing owners.
3. **Final remark (STW):** re-seed roots (the stack moved), drain barrier
   queue to empty, ephemeron fixed point, weak processing.
4. **Sweep:** initially still STW (measure its share after Phase 1; it is the
   smaller term today). Incremental sweep is Phase 3, gated on the block heap.

Decisions settled by the design review against §8.6 (2026-08-26):

- **Allocation color:** allocate-black. Not a choice after all -- §8.6's
  concurrent-mark clause prescribes it verbatim ("new objects are
  black-published"), as it prescribes target shading ("all later strong
  writes use target shading"), which retroactively makes P0.1's Dijkstra
  deviation the constitutional reading and the plan's original owner-append
  draft the violation.
- **Cycle state:** `major_marking_active` alone carries "a cycle is open";
  `gc.phase` stays `.none` between increments so every existing phase guard
  keeps its meaning. The grey queue IS the persistent frontier (capacity
  raised 4096 -> 65536; overflow still downgrades to the marked-rescan).
- **Explicit collections abort, never join.** `runObjectCycleRemoval`,
  `forceGC` and urgent polls abort an open cycle (reset queue, drop
  marking_active) and run the untouched STW `collectCycles`. Finishing the
  cycle instead would honor its floating garbage -- objects marked during
  increments that died before remark -- and "collect everything" callers,
  which is every determinism-sensitive test, require full precision. Aborting
  wastes only the increments already run.
- **Minors:** closed while a cycle is open (§8.6 Prepare: "close admission of
  a new minor request"); a poll that would have offered one runs an increment
  instead ("minor requests become major assist/completion requests").
- **Begin also retires the young/remembered state** (§8.6 initial mark step
  3): remembered owners are not major roots.
- **Termination:** the poll that finds the queue empty runs the final remark:
  re-seed all roots (stack slots are not barriered, so the rescan is what
  catches white objects referenced only from native frames), drain, then the
  barrier-queue drain with its overflow path, ephemerons, weak, sweep.
- **Safety valve:** if the account grows past 1.5x the threshold while a
  cycle is open, the next poll finishes it regardless of budget -- one big
  pause, counted and reported, instead of an unbounded heap.
- **Ephemerons:** fixed point at remark only, current holder-iteration form;
  the discovered-ephemeron queue (B5) waits for remark-budget evidence.
- **Instrument:** begin, each increment, and remark are separate samples in
  the major ring; the panel reports increments per cycle and the cycle's
  cumulative STW (§1.3's third pause row, previously uninstrumented).

Honest expectation, from the Phase-1 pause anatomy: marking is ~40% of a
splay major. Incrementalizing it bounds that slice at the budget, but begin
still walks the heap once (`clearMarks`) and remark still sweeps and destroys
synchronously, so splay's worst slice lands near ~60 ms, not 2 ms. Small
heaps (raytrace-class) land in low single-digit ms immediately. The 2 ms row
on large heaps falls only with Phase 3 (versioned marks kill the begin walk;
the block heap makes sweep lazy). Phase 2 is judged on the marking slice and
on the machinery being sound, not on the full row.

**Outcome (2026-08-26).** Landed. splay, fixed work: major-ring p50
112 ms -> 1.00 ms, p95 1.007 ms (the increments, sitting exactly on their
budget); p99 64 ms, max 67.7 ms -- the remark+sweep slice, within the ~60 ms
this section predicted. 29 cycles, ~35 increments each, zero forced finishes.
Two dispatch defects were found by the first real run, not by the design:
threshold crossings reach polls as `.allocation_threshold` REQUESTS recorded
at the allocation boundary, so "pure threshold == no request" routed
everything to STW (cycles: 0); the corrected condition treats a
`.soon`-urgency threshold request as self-paced. And the boundary's poll gate
needed nothing at all: while a cycle is open the account is over the not-yet-
reset threshold, so the boundary re-records the request each time and the
existing gate drives the increments unaided.

The throughput tax, measured: splay 2.376 -> 2.785 (cycle STW total 154 ms vs
the old monolithic 112 ms -- floating garbage from allocate-black inflates
the sweep and the survivor set), geomean 1.24 -> 1.29. That is the price of
p50 going from 112 ms to 1 ms; reclaiming it is Phase 3's lazy sweep, which
removes the largest remaining slice and most of the incremental overhead in
the same stroke.

Semantics deliberately preserved: every REQUESTED collection (host manual,
pressure, urgent) still completes at its poll, STW; only self-paced threshold
crossings run incrementally, and the reset of the growth threshold moves to
the poll where the cycle completes. Four tests updated to drive open cycles
to completion (`helpers.finishGcCycles`); four new protocol tests cover cycle
completion, the mid-cycle store with retraction (the floating-garbage
guarantee, strong form), explicit-collection supersession, and urgent abort.

### Acceptance

- major-attributable STW samples: p99 ≤ 2 ms on the declared workloads except
  final remark; remark p99 reported separately with a stated bound.
- No throughput regression beyond an agreed budget (incremental marking costs
  barrier traffic and floating garbage; measure, do not assume).
- test262 0/49778 both modes; `ZJS_GC_VERIFY_MINOR` and arena audits clean.

### Explicitly out of scope for Phase 2

Parallel marking (shortens total mark time — a throughput property; a bounded
increment is bounded regardless of heap size, so it is not needed for the
pause row). Time-to-safepoint instrumentation (unmeasurable until a marker
thread exists; in mutator-conducted mode the safepoint IS the poll).

## 4b. Phase 3, first tranche — sliced destruction (executed 2026-08-26)

The trigger fired immediately: the finish-slice probe put destruction at
99.5% of the p99 pause (63.9 of 64.2 ms on splay; remark itself is 0.3 ms).
The finish now only CONDEMNS -- detach unmarked objects onto a morgue, retire
survivor young bits, delist condemned shapes from the transition table -- and
destruction runs in bounded slices at later polls, under `.remove_cycles`
parking with a single deferred-free drain after the last slice, preserving
the five-pass kind order across slices via a persistent phase cursor.

Result: **major p99 64 ms -> 33.6 ms, max 67.7 -> 34.8 ms** on splay; what
remains of the tail is the two O(heap) walks (begin's clearMarks, the condemn
walk), which are the versioned-marks item. Throughput: geomean 1.29 -> 1.31
(the slice tax), splay 2.79 -> 2.87.

Three defects found by the gates and one by the panel, all of the same
species -- **the mutator window between condemn and destruction is a new
liveness domain, and everything that assumed "condemned means gone within
this pause" had to be found**:

- The grey queue held entries across mutator windows, and rc-counted kinds
  (shapes, replacement churn) could be freed while queued: pops now
  revalidate through `containsHeader`, whose arena-membership check also
  keeps the read off potentially unmapped pages.
- `rememberOwnerForBulkWrite`'s "deliberately absent" concurrent arm was a
  hole, not a design: dense-array appends into black arrays were invisible to
  the remark (the remembered set is retired at begin), and richards, crypto
  and raytrace all condemned live objects through it. The marking arm
  re-queues the owner.
- The shape transition table kept serving condemned shapes through the
  window: a live parent's dead transition child was still in the buckets, a
  mutator re-performing the transition adopted the corpse, and a later slice
  freed it under a live object. Condemned shapes are delisted at condemn.
  Found by bisection: synchronous destruction through the identical code path
  was green, so the window itself was the defect surface.
- Gating minors for the window was itself a disease: young grew to 1.7M
  objects, the completion-time account ballooned, and the 1.75x threshold
  amplified it into an 841 MB peak on a ~50 MB live set. Minors now run
  through the window -- `shade` refuses `cycle_visited` corpses, the bit
  `detachCycleCandidate` already stamps -- and the threshold resets at
  condemn time NET OF the morgue's bytes, with the completion poll refining
  it from the truly shrunk account.

## 4c. The splay verdict, taken whole (2026-08-26)

Asked to look at splay as a whole rather than knife by knife, the anatomy:

**The workload is the tracer's worst case by construction, not by our
implementation.** The tree holds ~8000 nodes; every iteration inserts a
~50-object payload and removes an OLD node's payload -- each object lives
~8000 iterations before dying. So the garbage is 100% old, 100% acyclic, and
dies at a constant rate. Refcounting is the information-theoretic optimum for
that shape (removal drops the count to zero, freeing is O(1) with zero
traversal); a tracer pays a whole-heap mark to discover each death. The 95%+
young survival that suspends our minors is a property of the workload, and
generational filtering is correctly useless here.

Profile at this state (share of total runtime): mutator ~33%, marking ~19%,
begin/condemn walks and poll dispatch ~21%, destruction ~10%, queue-pop
validation 4.3% (since removed). Incremental knives taken: pop validation
deleted by keeping rc-managed kinds out of the queue entirely (shapes expand
synchronously at shade -- one proto edge; the barrier re-queues the OWNER for
rc-managed targets), worth 3-5%.

**One knife was drawn and retracted with a lesson worth the retraction: the
O(1) mark-parity flip is unsound under sticky generations.** A flip equals a
clear only when the heap is uniformly marked, and the sticky rule ends every
cycle mixed -- survivors marked, newborns unmarked. Flipping reads every
newborn as marked (they leak; their children get condemned alive), and
allocate-black-always as a fix kills the minor outright. JSC escapes with
per-BLOCK versions plus a newlyAllocated bitmap; that is the block heap's
job, not a global bit's. The parity accessors stay in as the migration seam.

**The structural ceiling:** incremental knives top out around splay ~2.3
(from 2.87). Reaching the gate (bench-v8 composite >= 0.995, splay >= ~0.8)
requires removing ~70% of remaining GC time, and only two paths do that:

1. **Block heap serving GC nodes** (§4.5's own tranche): lazy sweep folds
   condemn+destroy into allocation (the allocator's freelist scan IS the
   sweep), per-block version bits kill the begin walk, block bitmaps replace
   list traversal, and arena fragmentation (RSS 479 MB vs heap peak 263 MB)
   falls out. This is the correct end-state and the plan's standing
   recommendation.
2. **Constitutional relief on §1.3's cycle peak/live < 1.8**: the growth
   factor is the largest single lever (1.75 -> 3.0 halves collection count;
   splay ~2.9 -> ~1.9 by arithmetic) and is capped by that row, since steady-
   state peak/live equals the factor. Owner's call, not a tuning decision.

## 4d. Block heap tranche, Step 1 — objects served from block cells (2026-08-26)

Path A, first step: plain objects allocate from the collector's block heap
(`[8B metadata prefix][object]` cells, `alloc_info = 0x1F` as the route
marker), with the slab as graceful fallback and the rc build untouched (its
hook is null). The conservative resolver gained the block population --
superblock ranges ride the scan-filter refresh, cold APIs ask the heap
directly, and the dereference-before-membership order in `blockOf` was
inverted before it could read an unmapped page.

Measured, same protocol as every gate: splay 2.87 -> **2.09**, geomean
1.31 -> **1.21**, bench-v8 combined 0.79 -> **0.865**, and the pause tail
collapsed: splay major p99 33.6 -> **8.4 ms**, max 34.8 -> 8.5 ms. The cell
economy is simply better than the slab's for this population, and the
condemn walk got most of its locality back.

The defect ledger for this step is a study in publication semantics, all
found by the gate ladder (macro caught none of them alone; test262's volume
and the combined workload caught all):

- A fixed [8] superblock-range cache silently truncated: earley-boyer's ninth
  superblock made its words invisible to the scan. Dynamic, sorted, coalesced
  now; a population index must never have a silent capacity.
- §8.6's "black-published AND all initial strong edges are shaded" was
  implemented as published-grey -- push the object at publication -- and the
  first version pushed EVERY kind, replanting both mines just cleared:
  shapes (mutator-freeable) back in the queue, and FunctionBytecode clones
  popped mid-construction. The settled rule: **published-grey is for plain
  objects only**. Every other kind becomes reachable through a store made
  after its construction completes, and that store's barrier greys it at a
  moment it is fully traceable; until then it stays white under its
  creator's stack reference, which the remark's conservative rescan honors.
- The write barrier now ignores unpublished owners AND unpublished targets
  (construction is not mutation), and `shade` refuses unpublished headers
  outright -- a published container can briefly hold a pointer to an object
  still being built, and tracing through it reached undefined fields.

## 4e. Block heap Steps 2-3 and lazy sweep (2026-08-27): the pause target is met

Step 2 moved the mark authority for block cells into per-block bitmaps under
the heap's mark epoch (begin's clearMarks became one epoch bump -- the sound
form of what the retracted parity flip attempted), delisted objects from
gc_obj_list behind a composite iterator that kept every consumer source-
compatible, made young tracking block-granular, and turned condemnation into
a dead-scan. Its honest ledger: the first cut was 6% slower with a worse
p99, and three profile-led fixes (word-skipping enumeration, list-only
clearMarks, allocation-time cell-index stamping) brought it to throughput
parity at p99 8.4 -> 6.1ms. One latent defect: isBlockCellHeader compared
the whole alloc_info byte and publication's accounted bit defeated it --
every published block object double-counted on the first audit.

The lazy-sweep tranche finished the job. Condemnation is a word-arithmetic
bitmap snapshot into each block's doomed bitmap (microseconds, no corpse
touched -- the frozen-window semantics that lets destruction slice across
polls without mistaking new allocations for corpses); doomed blocks queue on
an intrusive list the destruction slices drain under budget. The tail moved
twice and the per-kind slice maxima caught it both times: the single-shot
parked-frees drain at the last slice's tail (6.8ms for a whole morgue; now
budgeted like everything else), then begin's rare 3.5ms conservative-scan
max, which the p99 does not see.

**splay, fixed work: major p50 42us, p95 1.003ms, p99 1.007ms, max 3.53ms.
§1.3's major-pause row -- p99 below 2ms -- is met on the workload that
paused 112ms per collection when this plan began. Throughput parity held
throughout.**

### 4e.1 §8.7 state-machine audit and owner resolution (2026-08-28): the actual doomed protocol is the design

The pre-audit design spelled `fresh -> active -> needs_sweep -> sweeping ->
swept -> active`. That is **five distinct states and five edges**; the repeated
`active` closes the cycle, it is not a sixth state. An uninitialised/free-pool
block is a separate lifecycle condition, not a `SweepState` enumerator.

There are also two implementations that must not be conflated:

- `gc_sweep_model.Model` is a logical 64 KiB address-window observation map.
  `sweep_model_stats_enabled` populates it only in tests or the shadow tracer;
  a ReleaseFast reclaiming-tracer binary has an empty `windows` map even under
  the runtime arena-audit switch.
- `gc_block_heap.Block.sweep_state` is the field on the blocks that actually
  hold Objects. Its state does not drive condemnation or sliced destruction;
  those use the doomed bitmap/list and `Registry.doomed_pending`.

#### State ledger

| distinct state | logical `Model` implementation | physical `Block` implementation | production reachability verdict |
|---|---|---|---|
| `fresh` | `noteAllocated` inserts a window as fresh and immediately calls `transition(..., .active)` | `resetBlock` writes fresh; both arms of `openBlock` overwrite it with active before returning | Transient inside a private function only; no caller or audit boundary can observe a fresh block |
| `active` | Stable state after publication and after `endSweep` | Every opened block is active; blocks with pending doomed cells also remain active | Reached; this is the only state of populated physical blocks today |
| `needs_sweep` | `endMark` changes every active logical window | No constructor, whole-struct reset or field assignment produces it | **Unreachable in the physical heap** |
| `sweeping` | `beginSweep` changes every logical needs-sweep window | No constructor, whole-struct reset or field assignment produces it | **Unreachable in the physical heap** |
| `swept` | `endSweep` enters it and immediately leaves it in the same iterator iteration | `freeSmall` assigns it only after an active-state block that is no longer the per-class allocation source becomes completely empty and links that block on the per-class free list | Reached physically, but means empty/free, not “this cycle's dead cells were swept” |

The physical unreachability proof is a closed writer proof, not a frequency
grep: `Block.sweep_state` is initialised only by `Block`/`resetBlock`, and its
complete source writer set is `resetBlock`, the two return arms of private
`openBlock`, and the empty-block arm of private `freeSmall`. `resetBlock` and
`openBlock` cannot call out or fail between fresh and active; `freeSmall`
produces only swept. Block pointers escape for bitmap/mark operations, but no
other production source writes the field. Therefore no control-flow path can
produce needs-sweep or sweeping on a physical block. History gives the same
answer from a second direction: `git log -S'.needs_sweep' --
src/core/gc_block_heap.zig` has no introducing commit; neither missing state
has ever been assigned since the physical heap landed in `1b75cc435`.

#### Edge ledger

| historical design edge | logical trigger | physical trigger | verdict |
|---|---|---|---|
| `fresh -> active` | `Model.noteAllocated` | `Heap.openBlock` after `resetBlock` | Reached, but fresh is only an implementation transient |
| `active -> needs_sweep` | `Model.endMark` | none; `snapshotAllDoomed` snapshots bits without changing the state or invalidating `Heap.active` | **Missing physically** |
| `needs_sweep -> sweeping` | `Model.beginSweep` | none; `destroyDoomedSlice` consumes the doomed list while blocks remain active | **Missing physically** |
| `sweeping -> swept` | first transition in `Model.endSweep` | none; the physical empty-block path instead takes `active -> swept` directly | **Missing physically; historical-only edge** |
| `swept -> active` | second transition in `Model.endSweep`, or `noteAllocated` for a swept logical window | `Heap.openBlock` reopens a block from `free_blocks` | Reached physically |
| `active -> swept` | absent from the historical model | `freeSmall` after destruction makes an active-state block that is no longer the per-class allocation source completely empty | **Reached and promoted by the owner to the normative physical edge** |

The logical five edges are executable in tests/shadow and the focused model
test traverses them. They are not evidence for the ReleaseFast collector:
publication does not call `Model.noteAllocated` there, so collection-time
`endMark/beginSweep/endSweep` iterate an empty map. Incremental finish also
calls `Model.endSweep` immediately after condemnation, before any later
destruction slice; the model reports active and zero sweep debt while the
morgue is still non-empty.

#### What actually implements lazy sweep today

| historical §8.7 obligation | current mechanism | owner resolution |
|---|---|---|
| freeze the dead set at final remark | `Heap.snapshotAllDoomed` copies `alloc & ~mark` into the doomed bitmap and links non-empty doomed blocks | Implemented |
| sweep only on the owner mutator | `destroyDoomedSlice` runs from ordinary polls/allocation boundaries; urgent pressure and teardown call `finishPendingDestruction` synchronously | Implemented |
| guarantee progress without idle callbacks | `doomed_pending` keeps polls and object-allocation boundaries servicing bounded slices | Implemented |
| do not begin another collection with sweep debt | collection entry gates on `doomed_pending`; the logical `debt.sweep_debt` is already zero before physical destruction | `doomed_pending` is the normative production gate; model debt is diagnostic |
| mark blocks needs-sweep and invalidate allocation caches | no physical state transition; final remark detaches only a current block with at least 10% newly dead cells, and every new major withdraws the per-class hot lists | Historical five-state requirement retired; targeted allocator ownership invalidation now serves block reuse without becoming lifecycle state |
| never allocate from needs-sweep blocks | each doomed cell retains its alloc bit; a nominated partial block is withheld until the entire parked-free Pass B drains | Implemented as a transaction/publication gate rather than an unreachable `needs_sweep` state |
| rebuild allocation state, then publish swept/active | after Pass B, bitmap holes become maximal ordered intervals and the populated block joins a per-class hot list; `openBlock` owns it exclusively and interval-bumps. Completely empty non-current blocks still take `active -> swept` and use the aged-decommit free list | Implemented by the normative two-state lifecycle plus orthogonal hot-list allocator policy |

**Verdict and owner decision:** mutator-only lazy *destruction* is live and is
what moved corpse work out of the final STW pause. The historical five-state
physical machine was never landed and is not required: its missing middle
states would not move any additional work out of STW because the doomed bitmap
already freezes liveness and the bounded destruction slices already provide
progress. §8.7 now specifies the production mechanism directly: doomed-slice
budgeting, `doomed_pending` as the transaction gate, ordered-interval hot-block
publication only after parked frees drain, and stable physical block states
`active/swept` with the direct `active -> swept` edge. The logical
five-state `Model` remains only a test/shadow oracle; it is not described as a
ReleaseFast authority.

The arena audit now enforces that boundary with general checkers rather than
edge-specific tests. `Model.verify` recounts every logical window, rejects any
edge outside the five-edge graph, and checks flow conservation across all five
cumulative transition counters. `Heap.verify` requires every observable
physical block to be a stable active block or a completely empty swept/free
block, and cross-checks active/free/doomed-list membership against that state.
A half-wired needs-sweep/sweeping write therefore fails the audit immediately
instead of making the implementation look more complete than it is.

## 4f. Parallel marking (2026-08-26): the throughput front

The pause goal is met; §1.3's remaining obligation is throughput parity,
and the owner's G1-GC ruling picked option B of the process ledger's
throughput triangle -- promote parallel marking, leave the memory
envelope at 1.75x. Pricing backed that choice: raising growth to 2.5x
bought back only about a third of the gap while pushing splay's RSS to
4.6x rc (`reports/evidence/GC-GAP/growth-pricing-2026-08-26.md`).

**Why a stopped mutator makes this cheap.** A mark slice already runs
with the world stopped, so inside it the object graph is frozen. Helper
threads only read object fields and claim mark bits. There is no
snapshot protocol to build (design Appendix A stays dormant) and no new
interaction with the write barrier: barrier greys land in the same ring the
lanes already drain.

**Substrate, in three commits.**

1. *Atomic mark claim.* `Block.ensureMarkEpoch` was check-then-memset
   with no synchronization -- two threads first-marking the same stale
   block could each zero the bitmap and wipe the other's fresh marks
   (a live object condemned). Heap epochs now advance by 2, the odd
   value between them is a per-block transition lock taken by CAS, and
   readers treat any non-current value as unmarked, which is correct
   for both the stale and the locked case. `tryAcquireHeaderMark`
   claims a mark atomically and reports whether this caller won; the
   winner alone walks the object's edges, which also keeps the trace's
   rare write-backs single-writer.
2. *MPMC ring + owner-private stack.* The ring became a Vyukov bounded
   MPMC queue (the old SPSC head/tail let two poppers advance past each
   other's item), with protocol-compatible single-threaded variants so
   the owner's uncontended path stays CAS-free -- the all-CAS version
   cost 3.4% of fixed-work splay. The tracing hot loop then moved OFF
   the ring onto a per-lane fixed-capacity LIFO stack; the ring carries
   only seeds, barrier greys, and spill. **This alone was +12% on
   fixed-work splay**, most of it from LIFO making the trace
   depth-first over freshly shaded (cache-hot) objects.
3. *The pool.* Owner plus up to three helpers, sized from the affinity
   mask at first spawn, woken by condition variable. Slices end either
   on the budget (helpers spill their stacks to the ring and park, so
   the frontier survives to the next slice) or on a busy-count-and-
   empty-ring termination.

**Work distribution is the part that has to follow JSC.** The first
build gained nothing: an up-front feed is useless because depth-first
tracing keeps the visible frontier at a few hundred entries even over a
million-object graph, so helpers starved. JSC's `SlotVisitor::
donateKnownParallel` is the answer -- every lane donates the older half
of its local stack whenever the shared stack is empty, checked on a
fixed scan cadence, with a floor below which donating is not worth the
traffic. The older half is the right half to give: the bottom of a LIFO
trace stack holds the earliest-discovered, widest subtrees.
`popPrefetch` mirrors `popAndPrefetch` for the same stated reason (the
cache miss on the popped cell is marking's top cost), though it
measured neutral here.

**Result, fixed work, 4-core cluster.** splay 3727 -> ~4140 (+11%),
cycle STW 60ms -> 45ms, mark slices per run 519 -> 206. Single-core
affinity yields zero workers and bit-for-bit the previous path. Pause
distribution unchanged (splay major p99 ~1.01ms).

### 4f.1 Decommit policy: idle duration, not collection count

The aged decommit shipped with the RSS attribution used "free across
one full major" as its age. That is conservative only if collections
are far apart. earley-boyer's are 0.4ms apart: over 7745 cycles the
rule produced 4.95 GB of `madvise(DONTNEED)` and 4.94 GB of immediate
re-faulting inside a 30-second run -- the exact thrash the aging was
introduced to prevent, reintroduced by measuring age in the wrong unit.

libpas has the general form: pages return after an idle DURATION
(`pas_scavenger_max_epoch_delta`, 300-600s off Apple platforms) checked
on a fixed period (100-125ms), never per collection. Duration is
invariant to collection frequency, which is the property the policy
needs. Now 1s idle on a 100ms period, with the clock stamped at cycle
boundaries so the allocation path never reads one. **earley-boyer
+8.2%**; splay unchanged (its free blocks recycle in milliseconds
either way).

### 4f.2 Standing account after this tranche

Fixed-work, paired, three GC-heaviest benchmarks, candidate/rc:

| | splay | earley-boyer | deltablue | geomean |
|---|---|---|---|---|
| before this tranche | 2.037 | 1.299 | 0.979 | **1.373** |
| single core | 1.798 | 1.209 | 0.977 | **1.285** |
| 4-core cluster | 1.651 | 1.207 | 0.981 | **1.250** |

Re-priced after 4f.1 with every change in. The single-core row is what
a machine with no spare core gets: it keeps the mark-stack and
decommit-policy wins and gives up only the parallel slice.

For reference, the declined option A (growth 2.5x) reached 1.280 while
taking splay's RSS to 4.6x rc. Parallel marking beats it and costs no
memory.

### 4f.3 The policy statistic, both topologies

`policies/gc_merge_policy.json` binds its margin on the fixed-work
geomean over `gc_heavy_six`, so that is the number to carry. Measured
against the frozen rc merge-base, five paired samples per benchmark:

| | deltablue | regexp | pdfjs | raytrace | earley-boyer | splay | **geomean** |
|---|---|---|---|---|---|---|---|
| candidate, single core | 0.979 | 1.060 | 1.047 | 1.190 | 1.207 | 1.819 | **1.190** |
| candidate, 4-core cluster | 0.983 | 1.039 | 1.043 | 1.182 | 1.207 | 1.645 | **1.165** |

GC-GAP's official account on the pre-tranche candidate was 1.2062, so
the single-core figure is the like-for-like improvement: 1.206 -> 1.190
on one core, and 1.165 when the collector is allowed helper threads.

**A methodology question the driver session has to settle before this
is quoted as a gate input.** The 4-core row gives the candidate three
extra cores that rc cannot use, because rc has no parallel machinery.
Whether that counts as throughput depends on what the gate is asking:
"same wall clock for the same work on the same machine" says yes,
"same CPU-seconds" says no. The single-core row is the conservative
reading and is the one to use if only one may be quoted. Recorded here
rather than resolved because the margin and its statistic are owner
territory (roadmap §3 puts G2's statistical machinery in the driver
session).

Either way the margin of 1.05 is not met and G2 remains INCONCLUSIVE
by prediction, exactly as the G1-GC ruling anticipated.

### 4f.4 Three knives that did not pay, recorded so they are not re-chased

* **Enabling the plain-object fast destroy arm under `.remove_cycles`.**
  The tracer frees every object inside a `.remove_cycles` window, and
  the fast arm's guard excluded that phase -- so the tracing build had
  never once used its own fast teardown, and `destroyFromHeaderSlow`
  was 7.3% of fixed-work splay. Folding in the two things the general
  path does differently under that phase (do not decref a shape
  condemned by the same pass; defer the struct free to the second
  pass) made the arm fire: the symbol split 7.29% -> 4.50% fast +
  2.65% slow, total unchanged, and a paired ABBA A/B put the win at
  0.55% on splay and 0.15% on earley-boyer, both under the resolution
  floor. It also **broke the rc build**: `.remove_cycles` is not the
  tracer's private phase, rc's own cycle collector uses it and needs
  more from teardown than those two behaviours (its `enqueueZeroRef`
  asserts `phase == .decref`). Reverted. The lesson is the phase name:
  a guard that reads as "the tracer's destroy window" is in fact
  shared, and the cost it was hiding was cache misses on dying
  objects, not the destruction-plan lookup it appeared to be.
* **O(1) size-class index and removing the division from the cell
  stamp** (kept, since both are strictly less work): exactly zero.
  `@sizeOf(Object)` is 64, so the "linear scan" was four iterations of
  a perfectly predicted loop.
* **Raising the worker cap from 3.** On eight cores, seven workers buy
  1.3%; on four they cost 0.4% to oversubscription. Both at the floor,
  and the cap interacts with topology in a way a fixed number cannot
  win, so 3 stands.



**earley-boyer did not move on parallelism, and the profile says why**:
its cycles are ~7800 objects each, so its tracer tax is per-cycle fixed
cost and allocation-path overhead, not marking throughput. Its GC-
attributable profile share is ~20% spread thinly (allocation hook 5%,
destruction 5%, shading 3%, poll 2%) with the interpreter dominating
the rest. Two knives aimed at that 5% allocation hook -- an O(1)
size-class index replacing a linear scan, and removing an integer
division from the stamp -- measured exactly zero, the insn-phantom law
again: `@sizeOf(Object)` is 64, so the scan was four iterations of a
predictable loop. The remaining earley-boyer gap is a separate front
and should not be attacked by guesswork.

## 4g. Where splay's gap actually is (2026-08-27 root-cause pass)

Everything before this section attacked splay with knives and got 1-2%
at a time. This section is the bisection that should have come first,
and it **refutes the working hypothesis** §4c left standing -- that
splay is the tracer's structural worst case and its gap is irreducible
marking and sweeping tax.

### 4g.1 Three independent methods put the collector at a quarter

**Ablation by threshold.** `ZJS_GC_MIN_THRESHOLD` (diagnostic only,
zero in every shipped configuration) raises the major-collection floor,
so the collector can be made to run rarely without touching anything
else. Sweeping it on fixed-work splay, against the frozen rc
merge-base at 1.86s:

| major threshold | wall | vs rc | cycles | account peak |
|---|---|---|---|---|
| default | 3.365 | 1.810 | 29 | 240 MB |
| 200 MB | 3.300 | 1.775 | 20 | 240 MB |
| 400 MB | 2.967 | **1.596** | 9 | 381 MB |
| 800 MB | 2.963 | **1.594** | 4 | 763 MB |
| 1600 MB | 3.295 | 1.772 | 2 | 1526 MB |

Going from 29 collections to 4 saves 0.40s of a 1.51s gap. Past that
the heap's own footprint costs more than the collections did. **The
collector is worth about 27% of the gap.**

**PMU.** rc 27.1 G instructions / 7.17 G cycles (IPC 3.78); tracer
40.8 G / 12.66 G (IPC 3.22). The 1.77x cycle ratio decomposes into a
1.50x instruction ratio and a 0.85x IPC ratio: roughly two thirds
extra work, one third extra stalling (L2 refills 149 M -> 312 M).

**Symbol-level absolute diff** (percent x wall, so the two arms are
comparable), summed by category:

| category | delta | share |
|---|---|---|
| allocation and free path | **+0.49s** | 33% |
| collector, net of what rc pays for destruction and cycle marking | +0.36s | 24% |
| interpreter ops that merely got slower | +0.29s | 19% |
| generational bookkeeping | +0.07s | 4% |

The three methods agree on the headline: **the collector is a quarter
of splay's gap; three quarters is the rest of the engine running
slower under the tracing build.** Two entries make the point sharply:
`destroyFromHeader` is 0.20s CHEAPER under the tracer (it frees the
same objects rc does, with less bookkeeping), while `op_lnot` -- an
opcode with no connection to memory management whatsoever -- is 0.06s
more expensive.

An adversarial review of the same code (codex, gpt-5.6-sol, read-only,
2026-08-27) reached the same verdict independently and priced full-live
marking at ~0.52s against a 1.5s wall gap, which is the same
arithmetic from the other direction.

### 4g.2 The footprint hypothesis, and why it is also wrong

The obvious explanation for "everything got slower" is footprint:
splay's block heap committed 234 MB over 68 MB live (3.4x), and the
same review found the mechanism -- `allocSmall` abandons the active
block when it runs out and never returns to it, so cells freed in any
block the allocator has moved past are stranded until that whole 64 KiB
block empties. On a tree whose nodes die scattered, most never do.
JSC does not have this problem: `BlockDirectory` keeps a `canAllocate`
bitvector and comes back to partially-free blocks.

Implementing that (reusable-block list keyed on "has a free cell"
rather than "is entirely empty") **halved the footprint and did not
help throughput at all**:

| | committed | splay 1c | splay 4c | earley-boyer 1c | earley-boyer 4c |
|---|---|---|---|---|---|
| before | 234 MB | 1.836 | 1.661 | 1.206 | 1.210 |
| after | 109 MB | 1.872 | 1.672 | 1.249 | 1.268 |

Committed-over-live went 3.4x -> 1.6x and every benchmark got slower,
earley-boyer by 4-5%. Bump allocation into a fresh block is worth more
than density: consecutive allocations land in consecutive cells, and
scattering them across recycled blocks gives that up. **Not merged.**
The finding stands on its own -- the footprint is real, and it is not
what costs the throughput.

So the ranked target is now `allocation and free path, +0.49s`, which
over ~18.4 M allocations and ~17.5 M frees is about 40 cycles per
operation that rc does not pay. That is the block-cell route itself:
an indirect call through the allocator hook, an atomic read-modify-write
on the alloc bitmap for every allocation and every free, the prefix
stamp, and the registration bookkeeping. It is implementation, not
tracing, and it is where the next attempt belongs.

### 4g.3 Two defects the pass turned up

**Nothing checks block-heap accounting.** `verifyHeapAccounting` checks
published logical bytes against the old and large space accounts and
never opens a block, yet three operations trust `allocated_count`
absolutely: `resetBlock` zeroes the alloc bitmap, the decommit walk
hands cell ranges back to the OS, and `openBlock` re-serves a block as
empty. A drift of one turns any of them into "free a live object".
`BlockHeap.verify` now cross-checks bitmap popcounts against
`allocated_count`, the derived live bytes against the stats, and the
free lists against emptiness, under the arena audit -- per the
2026-08-25 ruling that an invariant gets a checker rather than N
targeted tests.

**`resetBlock` zeroes the intrusive links, and something depends on
that.** The whole-struct assignment clears `doomed_link` and
`young_link`, so resetting a block that is still on either list severs
the list there. Preserving them across the reset -- which looks
obviously right, since the function also zeroes the bitmaps, so both
lists would find nothing to do and walk past -- makes the incremental
cycle reclaim measurably LESS (the bounded-poll threshold-garbage test
drops below its floor). That means the current reclamation depends on
the truncation in a way nobody has written down. Left as-is and
recorded here rather than "fixed": the safe change is the one whose
mechanism is understood, and this one's is not.

## 4h. Second root-cause pass (2026-08-27, with an adversarial reviewer)

§4g established where splay's gap is NOT. This pass ran the same
discipline over all four GC-heavy workloads with a second model reading
the source adversarially in parallel, and it moved the policy statistic
from 1.190 to **1.153** (fixed-work geomean over `gc_heavy_six` against
the frozen rc merge-base, single core).

### 4h.1 What paid

Every one of these removes repeated fixed work whose amount scales with
collection count or allocation count. None of them changes what the
collector decides.

* **The alloc bitmap loses its atomics** (+1.3% splay). Marking needs
  atomics because lanes claim mark bits in a shared 64-cell word; the
  alloc bitmap has no such reader -- written only by allocation and
  freeing on the owner thread, read only inside stop-the-world windows.
* **The mark ring stops rewriting 65,536 sequence numbers per cycle.**
  A regression the MPMC conversion introduced: positions are monotonic,
  so an empty ring is already reset. 509 M stores and 3.8 GiB through L2
  per earley-boyer run, restoring a state the ring was already in.
* **`takeDoomedCell` gets a cursor.** It restarted its bitmap scan at
  word 0 for every corpse, making a block's drain quadratic in its word
  count.
* **The destruction budget check goes from every 8 items to every 256,
  and counts visited rather than destroyed nodes.** The morgue is walked
  once per kind; with the counter inside the destroyed arm, a pass
  looking for shapes stepped over every object on the list without ever
  reading the clock -- an unbounded scan inside a budgeted slice.
* **The thread's stack bounds are cached** (+1.8% raytrace, +1.6%
  earley-boyer). glibc resolves the initial thread's bounds by parsing
  `/proc/self/maps`, and the conservative scan asked on every
  invocation: ~18,300 times per earley-boyer run.

Together, paired and ABBA on a quiet host: splay 1.776 -> 1.581 on four
cores, raytrace 1.186 -> 1.147, earley-boyer 1.194 -> 1.156, deltablue
0.974 -> 0.970.

### 4h.2 What did not pay, and the pattern in the failures

* **Raising the small-heap headroom.** The floor sets the major cadence
  for every small live set -- a new counter reads raytrace as 0
  collections paced by growth against 7468 paced by the floor. Raising
  it 1.5 MiB -> 12 MiB took raytrace from 3734 majors to 2, a 233x
  reduction, and made it **3% slower**; the suite geomean degraded
  monotonically, 1.156 -> 1.182. Lowering it was also worse. 1.5 MiB is
  a local optimum and this target is closed.
* **Caching the conservative scan filter** (neutral to -1.0%). Its
  failure mode is severe -- one missed dirty flag drops a filter bit and
  a live object is rejected as a candidate -- and it bought nothing.
* **De-atomicizing the owner-only MARK path** (zero, -1.9% raytrace on
  four cores). Instructive next to the alloc bitmap: the same
  transformation on a different bitmap paid there and not here.
* **Deleting the begin-time young retirement.** Measured at 469-533 ms
  on earley-boyer, it looked like the largest remaining single cost.
  But the same walk runs again in `clearYoungState` at the end of every
  finish, so removing one merely moves the population to the other:
  +0.2% geomean. The adversarial review also found a hole the deletion
  opens on its own -- a minor may run during doomed destruction and the
  young iterator does not mask the doomed bitmap, so a corpse can be
  seen as young again -- plus three failure exits (abort, begin failure,
  `arenaSetWhole() == false`) with no retirement transaction. Reverted.

**The pattern**: what pays is deleting repeated fixed work. What does
not pay is shaving instructions off a path whose cost is a cache line,
and what actively loses is anything that grows the footprint or breaks
the sequentiality of bump allocation (see also §4g.2's block-reuse
result). Three separate experiments now agree on that last point.

### 4h.3 The target that survived, and how it was taken

Retiring the young generation cost 469-533 ms on earley-boyer, 182 ms on
raytrace, 65 ms on splay, at ~4.3 ns per header -- already the streaming
floor, so the only way to win was to touch fewer objects. Two attempts:

**Deleting the begin-time walk did not work.** The same walk runs again
in `clearYoungState` at the end of every finish, so removing one merely
moves the population to the other: +0.2% geomean. Reverted.

**Trace-coupled retirement did.** A block cell's young bit is cleared
where `traceHeaderEdges` has just finished expanding it, in both the
serial collector and each parallel lane, so only SURVIVORS are touched
and the header is already in cache. Non-block populations keep the old
treatment -- the condemnation walk already retires those survivors, and
clearing them at trace time would break `young_head`'s exact-suffix
invariant. begin_retire: earley-boyer 469 ms/125 M -> 134 ms/71.6 M,
raytrace 182 ms/44.2 M -> 7 ms/2.96 M, splay 65 ms/11.9 M -> 0.8 ms/257.

The window between initial mark and commit then holds a half-promoted
young population, and a **retirement transaction** is what makes that
safe: opened before anything can shade, closed to minors at the
scheduler AND inside `collectMinor` (ahead of the stress knobs -- an
open transaction is a correctness condition, not a scheduling
preference), committed only where sweeping finished, abandoned with a
repair-major request on every other exit, and with the young iterator
masking condemned cells so a minor running between destruction slices
cannot be handed a corpse to reclaim twice. Three checkers replace the
invariant the deleted walk used to establish by construction: a
retirement audit, both-directions young- and doomed-list chain checks in
`BlockHeap.verify`, and two semantic tests. Design and review with codex,
which rejected an earlier cross-major deferred version, supplied this
shape, and found the double-reclaim hole in the first cut.

### 4h.4 Standing account

Fixed-work geomean over `gc_heavy_six` against the frozen rc merge-base,
single core, five paired samples each:

| | deltablue | regexp | pdfjs | raytrace | earley-boyer | splay | geomean |
|---|---|---|---|---|---|---|---|
| GC-GAP account | 0.983 | 1.039 | 1.043 | 1.182 | 1.207 | 1.645 | 1.206 |
| after §4f | 0.979 | 1.060 | 1.047 | 1.190 | 1.207 | 1.819 | 1.190 |
| after §4h.1 | 0.973 | 1.012 | 1.042 | 1.134 | 1.147 | 1.764 | 1.153 |
| after §4h.3 | 0.974 | 0.995 | 1.034 | 1.123 | 1.134 | 1.737 | **1.142** |

regexp is now below parity, deltablue stays there, and the margin of
1.05 is met on four of the six. splay remains the outlier and the
account's whole remaining distance: at 1.737 it alone contributes more
to the geomean than the other five combined.

### 4h.5 Where the target used to be

Retiring the young generation still costs 469-533 ms on earley-boyer,
177 ms on raytrace, 65 ms on splay, at ~4.3 ns per header -- already the
streaming floor, so the only way to win is to touch fewer objects. The
design that does that is **trace-coupled retirement**: clear a block
cell's young bit where the tracer has already loaded its header (after
`traceHeaderEdges` returns), leave list survivors to the condemnation
walk that already retires them, and let dead cells be retired by their
destruction. That reduces header touches to survivors instead of the
whole young population.

It needs a retirement transaction to be sound, and that is why it is not
in this tranche: `begin` must open it before `clearMarks`, all three
failure exits must either retire or forbid minors until a full
stop-the-world major consumes the pending state, the young iterator must
mask doomed bits, and `collectMinor` needs a guard. The design and its
test list are recorded; the implementation is a tranche of its own.

## 4i. Third pass (2026-08-27): two more knives, and a gate hole

`gc_heavy_six` fixed-work geomean, single core, against the frozen rc
merge-base: **1.142 -> ~1.137**.

**Kept.** Condemnation and the whole-heap iterator walk `used_blocks`
rather than a fixed 32 block slots per superblock, and skip blocks with
no allocated cell -- `used_blocks` is monotonic, so it bounds both walks
exactly. `retireYoungSet` skips the clear when the remembered set is
already empty: Zig's `clearRetainingCapacity` re-initialises the whole
metadata array regardless of count, and this runs at both ends of every
major, which earley-boyer takes 7,772 of while holding two remembered
owners. Together, earley-boyer 1.133 -> 1.109 single core.

**Reverted, measured backwards.** Requiring the parallel-slice frontier
threshold on every slice rather than only the cycle's first cost splay
10% on four cores. The frontier is an instantaneous reading of a
depth-first traversal: it dips below any threshold repeatedly inside a
cycle with millions of objects still to go, and each dip parks the
helpers for the rest of that slice. **What a slice is worth is a property
of the cycle, not of the frontier at the instant it opens.**

**Reverted, then fixed and restored.** Bucketing the morgue by kind at condemnation
removes a real cost -- destruction walks the list once per kind, so a
corpse of the last kind is stepped over five times before its own pass
reaches it -- and was worth 2% on earley-boyer. It also produced an
intermittent SEGV in `popCell`, reading a free-list link out of a cell
whose metadata prefix had been overwritten, which is the shape of a
double destruction. Established: it is the buckets and not the two knives
that shipped beside them; it is not pre-existing (the three preceding
binaries pass 12 of 12 where this one fails 6 of 6); and it does not
reproduce under the arena audit, so whatever happens falls between the
checkers' sampling points. Reverted because the mechanism is not
understood -- the fix and the revert are not interchangeable when the
next person has to trust the code.

### 4i.1 The free-cell impersonation bug

The bucket change did not create the defect it exposed; it changed the
timing enough to make an existing one reachable. The arithmetic matches
the crash byte for byte.

A free cell stores its successor's index in its first four bytes, which
are also the object metadata prefix: byte 2 is `alloc_info`, whose low
five bits are the `0x1F` marker meaning "this is a block cell", and byte
3 is the GC flags. The terminator was `0xFFFFFFFF`, so byte 2 read
`0xFF`, its low five bits read `0x1F`, and **a free cell at the end of a
chain impersonated a live block-cell header**. Clearing `young` (bit 4,
mask `0x10`) rewrote the link to `0xEFFFFFFF` -- which is exactly the
value gdb reported as the victim object's shape pointer. `popCell` tested
the link against the terminator rather than against the cell count, so it
followed the corrupted value outside the block, and the failure surfaced
in the NEXT allocation, two steps from the write.

Real indices are below `cell_count` -- a few thousand -- so their byte 2
is zero and they never collided. Only the terminator did.

Fixed by changing the representation rather than the constant. A cell
index needs 16 bits, so **the link lives in the low half and the high
half is a poison pattern**, which puts both bytes a header write can
reach outside the link entirely -- for set bits as well as cleared ones,
which no choice of 32-bit terminator could manage. The poison makes a
free cell read as un-accounted, cycle-visited, and of a kind that is not
traced, so every path that could reach one now refuses it; a comptime
block checks each of those properties instead of trusting a comment.
`popCell` is strict again: an out-of-range head is corruption, not an
empty list, because reading it as empty silently strands every cell
behind it.

Three checkers close the gap that let this be invisible. `BlockHeap.
verify` walks every block's cell free chain and requires it to be
**complete** (`walked == bump - allocated_count`) as well as well-formed,
since a chain truncated by a bad link is perfectly well-formed and simply
shorter. `retireTracedYoung` asserts the frontier invariant it depends on
-- the object it is about to WRITE must be published and un-condemned --
so a stale queue entry fails loudly rather than corrupting memory. And
the free-chain head is checked separately from its links.

**Not closed**: which code path wrote the bit has not been identified. The
frontier assertion does not fire, so the tracer is not reaching free
cells. The corruption is now both impossible to produce by a header write
and impossible to follow, and the checker will name it if it recurs.

With that, the buckets are back: earley-boyer 1.133 -> 1.109 with the
other two knives, and the regexp soak is 20 runs clean where the pre-fix
build failed 6 of 6.

### 4i.2 The gate hole

The macro sweep passed 9/9 on the broken build. It runs each benchmark as
shipped; the perf harness runs the FIXED-WORK variants (`doWarmup=false`,
`doDeterministic=true`), and only those reach the state that crashes. A
gate that cannot see the states the measurements run in is not a gate.
`tools/perf/gate_smoke.sh` now runs the fixed-work corpus and belongs in
the battery beside the macro sweep.

## 4j. The external anchor: how much SHOULD a tracing GC cost? (2026-08-27)

Asked directly -- would switching collectors really cost this much? -- the
answer is no, and it can be measured rather than argued.

Same machine, same fixed-work `splay.js`, all four single-threaded and
none of them JIT-compiling:

| engine | collector | wall |
|---|---|---|
| QuickJS | refcounting | 1.70 s |
| **Hermes** | **Hades, concurrent tracing** | **1.84 s** |
| zjs | refcounting | 1.87 s |
| zjs | this tracer | 3.17 s |

**Hermes pays 8% for tracing where we pay 70%.** Hermes and QuickJS are
different engines, so the 1.08 is not a pure GC measurement -- but it is
an upper bound on how expensive tracing has to be, and it is an order of
magnitude below ours. Hermes' own numbers on that run: 465 collections,
a final heap of 200 MB over a live set near 50 MB, collector reported as
`hades (concurrent)`. It is not being frugal with memory or with
collections; it is not stopping the mutator to do the work.

### 4j.1 Where our gap is -- and a correction

A first pass at this multiplied the last cycle's stop-the-world total by
the cycle count and concluded the stopped time was 117% of the gap. Both
halves of that were wrong: cycles are not equal, and total stopped time
is not all overhead, because refcounting pays for destruction too. The
per-slice-kind cumulative counters give the real figures.

Cumulative stop-the-world, whole run. The first version of this table
credited the marking done by the slice that empties the frontier to
`finish`, because that slice runs both -- so earley-boyer read as 64 ms
of marking against 1.44 s of finish when most of that finish WAS
marking. The counters now split them, while the pause sample stays the
whole stop (the two questions -- "how long is one stop" and "which phase
owns the stopped time" -- have different right answers):

| | begin | increment (marking) | destroy | finish | total |
|---|---|---|---|---|---|
| splay | 4 ms | **515 ms** (50%) | **499 ms** (49%) | 5 ms | 1.02 s |
| earley-boyer | 522 ms (13%) | 995 ms (24%) | **2124 ms** (51%) | 528 ms (13%) | 4.17 s |
| raytrace | 81 ms (8%) | 39 ms (4%) | **813 ms** (80%) | 82 ms (8%) | 1.02 s |

**Destruction is the largest stop-the-world consumer on all three**, and
marking is half of splay's stopped time but a quarter of earley-boyer's
and almost none of raytrace's.

For splay against a 1.30 s gap: stopped time is 1.01 s (78%), but rc's
own memory management -- `destroyFromHeader`, its slow arm,
`markOrdinaryObjectHot`, `enqueueZeroRef` -- costs 0.48 s of its 1.87 s.
The stopped time rc does NOT also pay is **0.54 s, about 41% of the
gap**. Concurrent marking could remove at most the marking share net of
rc's own marking: **0.42 s, 32% of the gap**, landing splay near 1.47
rather than 1.70. Real, and worth having, and not the whole distance.

**And marking is not where the other two spend their stopped time at
all.** raytrace does no incremental marking (its cycles finish in one
slice) and earley-boyer spends 64 ms of 4.13 s on it. Both are dominated
by destruction, and earley-boyer additionally by `finish` -- 1.44 s over
7,759 cycles, which is 186 us of per-cycle remark and condemnation
repeated eight thousand times.

So there is no single structural lever. There are three, and they are
different per workload:

* **destruction**, the largest single consumer everywhere (49%, 51%,
  80%). But refcounting destroys the same objects, so only the delta is
  ours: on splay, 499 ms of stopped destruction against rc's 345 ms of
  `destroyFromHeader`, a delta of about 150 ms. That delta -- not the
  813 ms -- is what a change here can win, and it must be measured
  per workload before it is chased.
* **marking**, half of splay's stopped time, a quarter of
  earley-boyer's, 4% of raytrace's. Concurrent marking (6.3) is worth
  about a third of splay's gap and proportionally less elsewhere.
* **begin**, 13% on earley-boyer -- 522 ms over 7,748 cycles, of which
  the probes attribute 189 ms to `clearMarks` and 111 ms to the
  conservative root scan. Per-cycle fixed cost against a cycle count
  that the workload, not the collector, chooses.

The Hermes anchor stands unchanged: 1.08 against QuickJS where we are
1.70, so the distance is implementation and not the algorithm. What the
corrected arithmetic removes is the claim that one change closes it.

### 4j.3 And it is not about overlap either

An adversarial review objected that the Hermes anchor might only show
Hermes using more cores. It does not, and the check is worth recording
because it decides whether concurrent marking is the answer.

Everything below is pinned to one core and every arm ran at 99-100% CPU,
so no arm overlapped anything:

| engine | user CPU | wall |
|---|---|---|
| QuickJS (refcounting) | 1.62 s | 1.69 s |
| Hermes (tracing) | 1.74 s | 1.83 s |
| zjs refcounting | 1.78 s | 1.85 s |
| zjs this tracer | **2.92 s** | 3.18 s |

**Hermes spends 7% more CPU than QuickJS to trace. We spend 64% more
than our own refcounting.** Hermes does use a background thread when it
is allowed one -- unpinned it reaches 152% CPU and 1.39 s -- but it did
not have one here and still paid 8%.

That settles what concurrency can and cannot do for us. Moving marking to
another core would improve wall time on a multicore host; it would not
remove the 1.14 s of extra CPU work, and that work is the thing that is
out of line. The target is the work, not its schedule.

### 4j.2 What this says about the tranche just finished

Parallel marking was the right item off the throughput triangle and it
did what it claimed: more threads inside a slice, splay 3727 -> 4140.
But it shortens the stop-the-world window; it does not remove it. **The
mutator is stopped for the whole of every slice either way.** Hermes'
lever is a different one: Hades marks the old generation on a background
thread WHILE the mutator runs, and the design here keeps that as Appendix A's
dormant mutator-concurrent protocol.

That reframes part of the remaining distance, not all of it. Concurrent
marking is worth about a third of splay's gap and almost nothing on the
other two; the corrected numbers above are what the decision should rest
on.

The prerequisite is the one Appendix A names: a mutator running during payload
enumeration needs the snapshot protocol, and this collector's barrier is
already the Dijkstra direction it would need. The pause work of §4 built most
of the machinery -- incremental slices, a barrier that shades targets, an
overflow contract, and now atomic mark claims and a work-donating pool that
already runs marking on threads other than the owner's.

## 4k. Destruction, and the point where the knives run out (2026-08-27)

`gc_heavy_six` fixed-work geomean, single core: **1.142 -> 1.131**, with
earley-boyer under 1.10 for the first time.

### 4k.1 Destruction was the biggest winnable item, and it was measured first

Cumulative stopped time said destruction dominated everywhere, but
refcounting destroys the same objects, so the total is not the prize.
Measured per workload -- rc's destruction cost from its profile against
the tracer's stopped destruction time:

| | rc | tracer | delta |
|---|---|---|---|
| raytrace | 0.497 s | 1.518 s | **+1.021 s** (about 64% of its gap) |
| earley-boyer | 1.417 s | 2.208 s | **+0.791 s** |
| splay | 0.411 s | 0.499 s | +0.088 s |
| pdfjs | 0.187 s | 0.031 s | -0.156 s |
| regexp | 0.154 s | 0.111 s | -0.043 s |

Six knives took raytrace's stopped destruction from 1518 ms to 616 ms
against rc's 497 ms. The one that mattered structurally: the tracer set
`phase = .remove_cycles` for its destruction slices, and
`destroyFromHeader`'s fast arm excludes that phase -- so the tracing
build had never used its own fast teardown. Admitting `.remove_cycles`
broke the rc build (its cycle collector shares the value and its
`enqueueZeroRef` asserts `phase == .decref`), so the tracer got its own
phase and thirteen shared sites moved to `phaseIsTwoPassTeardown`. The
other five removed repeated per-corpse work: a doubly-linked parked queue
became a singly-linked stack, the weak-identity test moved to the call
site, `takeDoomedCell` serves a whole bitmap word from a register, the
object free hook skips two hash probes the allocation side already ruled
out, and condemnation stores a doomed word only when it changes.

### 4k.2 The rule keeps holding, in both directions

`live_bytes`, `live_count` and `small_allocs` are now derived from the
bitmaps instead of maintained -- three read-modify-writes per allocation
and two per free, over 255 M allocations on earley-boyer, all of it for
diagnostics. +0.2-0.4%.

Resolving the object hook's size class once instead of per call measured
**zero**, and is not merged. That is the fourth time a
count-the-instructions change on a cache-line-bound path has come back at
zero, against a perfect record for changes that delete repeated fixed
work. The two categories look identical in a diff and are not the same
thing; only the measurement tells them apart.

## 4l. Six parallel implementation lanes (2026-08-27)

`gc_heavy_six` fixed-work geomean, single core: **1.131 -> 1.112**, with
raytrace and earley-boyer both under 1.07.

| | before | after |
|---|---|---|
| deltablue | 0.968 | 0.963 |
| regexp | 1.002 | 1.032 |
| pdfjs | 1.032 | 1.030 |
| raytrace | 1.112 | **1.070** |
| earley-boyer | 1.100 | **1.064** |
| splay | 1.708 | **1.624** |

Six agents implemented in isolated git worktrees against a frozen base,
each on a disjoint target, with measurement reserved to one host and one
adjudicator. What that structure bought, beyond throughput:

**The largest single win came from a class of waste nobody had named.**
Production's tracing build decides at compile time not to link scalar
root frames -- conservative stack scanning covers them -- but the call
sites still built the frame, updated thread-local counters and ran the
deactivate check. splay creates four such frames per literal property
and 15.1 M literal properties. Erasing them at comptime shrank
`definePlainDataPropertyKnownFast` from 3576 to 3104 bytes of text and
its stack reservation from 672 to 288, and measured **+4.7% on splay,
+3.2% on raytrace, +1.6% on earley-boyer**. The lesson generalises past
this instance: a compile-time decision not to do something is not the
same as not paying for it.

**A refusal was as valuable as an implementation.** The carrier-epoch
proposal -- give each non-block carrier type a 16-bit mark epoch in its
existing alignment hole, so `clearMarks` becomes O(1) instead of walking
10,331 headers per cycle -- would have won 189 ms on earley-boyer. Before
building it, the lane measured the cardinality it would have to pay for:
29,033 carrier `headerMarked` calls per cycle. Against a 24.4 us budget
that leaves 0.84 ns per dispatch, below the abandon line, so it was
declined with the arithmetic recorded. The 189 ms is now documented as
not-cheaply-reducible rather than as an untried idea.

**Two real defects surfaced from writing checkers rather than chasing
them.** Hardening the structural audits found a synchronous major that
never opened its retirement transaction, and a free-chain head left stale
after decommit. Neither was reachable from any failing benchmark.

## 4m. What the design still owes (2026-08-27 survey)

Surveyed `docs/tracing-gc-design.md` for items named but not landed; the
full list with quotations is `docs/tracing-gc-backlog.md`. Two of them
turned out to be unblocked by work that has since happened, which is the
reason for surveying rather than remembering.

**Unblocked and now the priority.** §4.5's target object header -- eight
immutable bytes with **no refcount field**, mark and generation state in
side metadata -- was gated on "after the compatibility tracer and block
heap are independently proven". Both are now true: four gates green, and
turning the block heap off costs 8 points of geomean. The measurement in
§4j.3 says why this is the priority rather than one item among many:
marking costs **133 cycles and 5.92 L2 refills per object at IPC 0.94**,
against 124 instructions that would take 39 cycles at the run's own IPC.
Seventy percent of marking is waiting for memory, and six refills per
object is what a logical object split across a prefix, a struct, an
out-of-line property array and a shape costs to visit.

**Also unblocked, and now measured.** Stage 4's gate row for allocator
fragmentation and the committed-memory envelope was deferred as
"measurable only once the heap serves GC nodes, which needs §4.5's header
change". The heap has served GC nodes since the block-cell tranche. That
premise has expired: the Stage 4 table now records a measured fail, with the
allocator and same-domain collector quantities kept separate as defined in
the §1.3 correction above.

**Stage 5 evidence audited; gate fails.** The five-row re-audit is now in
`tracing-gc-design.md` Stage 5. The active old-to-young deletion probe and lane
pause distribution pass. Young-list scaling still has an unbounded
old-weak-holder component, conservative-only reachability is only an upper
bound without a false-promotion liveness oracle, and the ReleaseFast
committed/live readings all exceed §1.3's `1.3x` target. The mechanism remains
landed; the gate is not claimed. A follow-up ReleaseFast census priced the
candidate JSC-style new-active/old weak-holder partition before implementation:
all six fixed-work loads had zero weak holders and zero weak entries at every
minor (EB `2791`, pdfjs `152`, splay `8`; the other three had no minors), so the
old fraction is undefined rather than evidence of a cheap old population. The
split would remove no holder visits in this corpus and was not landed. This
does not repair the strict asymptotic row; it records a measured no-go for the
current performance tranche.

**Correctly deferred, but the old blocker sentence was wrong.** Worker-side
child enumeration now exists in `gc_parallel_mark.zig`: helpers call the shared
trace authority while the mutator is stopped, then quiesce before it resumes.
What does not exist is mutator-concurrent payload enumeration. §4j.3's
CPU-seconds anchor makes that a future pause experiment rather than a current
throughput item. The current §6.1 contract is stopped layout plus STW worker
affinity; the old concurrent-access trichotomy lives only in design Appendix A.

**Not yet startable.** Stage 7 wants all correctness gates, the declared
envelopes, no regression under the measurement contract, and a rollback
plan. The account is 1.112 against a 1.05 margin, so the answer is not
yet -- but the experimental build switch and the rollback plan are
buildable now and are not blocked by the number.

## 4o. Mark-prefetch scheduling is closed (2026-08-28)

Two superficially similar experiments tested different mechanisms and must
not be conflated. Lane-d's D4 left the LIFO frontier intact and peeked at a
deeper `top-k` entry. That target was speculative: `top-1` was consumed within
eight pops 83.35% of the time, while the depth-4 target was consumed in that
window only 0.0638% of the time. Lane-e instead used a **true-pop batch**:
remove N entries that are now certain to be processed, issue representation-
aware prefetches for all of them (prefix, object body, property values and
shape), then trace the batch. This is a real MLP experiment, not another
frontier-peeking experiment.

The quiet-window cycle verdict, with rc spread 0.14-0.50%, was negative in
all three tested batches. Values below are cycle improvement versus the
scalar (`N=1`) control; positive is better:

| true-pop batch | splay | earley-boyer | raytrace |
|---:|---:|---:|---:|
| 4 | -2.40% | -1.10% | +0.15% |
| 8 | -1.21% | -0.67% | +0.16% |
| 16 | +0.10% | -0.79% | +0.24% |

Larger batches show a monotonic tendency, but no batch produces a positive
three-workload verdict. More importantly, the cache-line evidence barely
moves: splay L2 refill falls from 1.950 to 1.686, while lane-b's layout change
reaches 1.665 on the same metric and also removes 23% on earley-boyer. The
instruction count is deliberately not used as evidence here; this path was
already shown to be cache-line bound.

Together, three independent observations close this line of attack:

1. speculative `top-k` prefetch does not reach the next object in time;
2. certain-to-run, true-pop batched and representation-aware prefetch still
   does not pay; and
3. 97.54% of consecutive real pops already reside in the same 64 KiB block.

The remaining stalls are therefore not pointer-chase latency that scheduling
can hide. They are the number of cache lines needed for one logical object,
split across its metadata, body, out-of-line properties and shape. Layout must
remove those lines. The experimental batch option and code remain as a
reproducible control, with batch size **1** as the default; no prefetch batch is
enabled in the shipped path. Revisit only if the representation changes enough
to invalidate these locality measurements, not by trying another stack order.

## 4p. Conservative-stack cost ledger and block-set filter (2026-08-28)

Earley-Boyer's conservative stack scan was reported as 211 ms per fixed-work
run. A full-run counter capture puts units under that number:

| quantity | measured value |
|---|---:|
| conservative scans | 18,367 (2 x 7,784 majors + 2,799 minors) |
| candidate machine words | 110,564,588 |
| average words per scan | 6,019.741 |
| words that resolve at least one GC object | 1,613,729 |
| validated-word hit rate | 1.459535% |
| rejected-word rate | 98.540465% |
| estimated major-scan words | 93,715,332 |

The reported 211 ms divided by the major population is about **2.2515 ns per
candidate word**. A separate instrumented run counted 298.409 ms for all major
and minor conservative phases, or 2.6989 ns per word. These are deliberately
kept as two denominators rather than blended: the first is the driver's
major-only report, the second includes minor scans.

The starting implementation was not literally “page hash plus a full bucket
walk with no prefilter”. It already had a monotone global address window and a
one-word TinyBloom-style OR filter for slab arenas and standalone pages. A
representative late 6,020-word EB scan split as follows:

| stage | words | share of all candidates | conditional result |
|---|---:|---:|---:|
| global bounds accepted | 222 | 3.6877% | bounds rejected 96.3123% |
| routed through block-superblock ranges | 56 | 0.9302% | 25.2252% of bounds-pass |
| non-block words reaching address Bloom | 166 | 2.7575% | -- |
| address Bloom accepted | 102 | 1.6944% | rejected 38.5542% of eligible |
| resolved at least one GC object | 84 | 1.3953% | 85 object hits; one word hit two |

The accepted paths were still expensive. The 222 bounds-pass words performed
4,995 top-level superblock range comparisons (22.5 each); the 56 routed words
then performed another 1,279 range comparisons while resolving their block
(22.84 each). The address side performed 204 arena hash probes and 102 page
hash probes. Only 32 page buckets existed; those walked 51 occupants and
resolved 30 objects. Rebuilding one scan's accelerator walked 430 arena keys,
77 standalone-page keys, and 13 superblocks.

A cycle attribution sample for `seedConservativeRoots` agrees with the branch
ledger (percentages sum to 100.36% from rounding):

| work | self-cycle share |
|---|---:|
| rebuild address filter and block ranges | 22.56% |
| load candidate word and loop | 14.12% |
| global bounds | 13.92% |
| first superblock-range classification | 7.84% |
| one-word address Bloom | 0.07% |
| arena set plus cell validation | 25.19% |
| block set/range plus cell validation | 7.37% |
| page set, bucket and occupant validation | 8.75% |
| spill/bounds setup | 0.54% |

This also explains why the previously rejected “cache the rebuilt scan
filter” experiment is not being retried. Its soundness depends on never
missing a dirty transition, and it measured neutral to -1.0%. The new work
targets the repeated block membership classification instead.

JSC's corresponding path has a stricter three-stage shape. It masks a word to
`MarkedBlock::blockFor`, rejects it with a register-local `TinyBloomFilter`,
then asks the exact `MarkedBlockSet` before dereferencing block metadata
(`ConservativeRoots.cpp:133-154,203-204`; `MarkedBlockSet.h:51-70`; the mask is
in `MarkedBlock.h:498-500`). Additions update both Bloom and set; removals may
leave harmless stale Bloom bits and periodically recompute after set shrink.
JSC does not expose per-stage rejection counters in this source, so no JSC
percentage is invented here.

The zjs block population now follows that mechanism. `BlockHeap` maintains a
monotone exact set of initialized 64 KiB block bases plus the OR-of-bases
TinyBloom. A conservative span snapshots the block Bloom, address Bloom and
bounds into locals, then performs mask -> Bloom -> exact set -> block metadata.
The duplicate sorted/coalesced superblock-range cache is gone; scan begin only
extends the cheap global bounds from live mappings. Publication reserves exact-
set capacity one 32-block superblock at a time and rolls the mapping back if
that reservation fails.

This intentionally complements, rather than waits for, lane-a's precise-root
work. Closing a root category reduces the number of spans that enter this
scanner; the filter reduces the cost of every candidate in each remaining
span. Neither optimization is used to justify the correctness of the other.

The audit recomputes both the expected exact membership and Bloom bits from
superblock geometry. Its negative test independently clears the Bloom and
removes an exact-set member; the checker must report `BlockScanFilterMismatch`
and `BlockIndexMismatch` respectively. This code is compiled only for the
experimental tracing collector. A quiet-window cycles/L2/IPC A/B remains the
performance verdict; instruction count is not evidence for this cache path.

The default-rc zero-cost check used ReleaseFast builds at `5779d3f1` before
this change and the candidate after it. Their `.text` sections are byte-for-
byte identical (SHA-256
`91fe1e71633a89689d35a1eda77fcbfc0917b0cdd678393c9132cc1f4369fb93`).
After stripping debug information, the complete 4,434,752-byte executables
are also identical (SHA-256
`a4a77b05ce0645ecec3671be3e95159ebde9668b49284e6fad2ea24a65aef128`).
The unstripped files differ only in non-allocated `.debug_str`/`.debug_line`
content caused by their different absolute worktree paths, not in any
allocated section.

## 5. Phase 3 — deferred, with their triggers

| Item | Trigger |
|---|---|
| Block heap serves GC nodes (§4.5 tranche) | Phase 2 lands; enables lazy sweep, versioned marks, retires the occupant table |
| Versioned/polarity marks (kills the `clearMarks` walk; JSC MarkedBlock.h:313) | block heap |
| Incremental/lazy sweep | block heap; or earlier if post-Phase-2 sweep share exceeds remark share |
| Parallel marking | pause rows green and marking throughput is the next bottleneck |
| Slot/card-granular remembered set | minors productive again AND a big-old-object append workload shows owner-granularity cost (JSC is also owner-granular; V8 cards are the model) |
| Minor-time weak processing (JSC eden reaps weak sets; our minors defer WeakRef clears and FinalizationRegistry enqueue to the next major) | only if promptness becomes an observable complaint — spec-legal as is |

## 6. Standing measurement rules for every phase

Fixed-work scripts, not the Octane composite (proven blind: identical
instructions/cycles/wall with 48% score delta). Matched-pair binaries from one
HEAD. Idle big cores, ABBA within a core. Pause numbers only from the
census-subtracted major-only ring. Any claim of the form "X exists only for Y"
gets verified by deletion before it is written down. A/B against a build with
a known defect proves nothing about the fix (the tombstone lesson: same change
measured -8% on a leaking build, 5-7x on the fixed one).

## §4n 测量仪器换代与本轮裁决(2026-08-28)

### 为什么换仪器

六条 codex lane 并行实现期间,**wall-clock A/B 不再可用**。同一次运行内 rc 参照臂
的极差:splay 105%、earley-boyer 92%——比任何被测效应大两个数量级。症状是候选臂
读出「tracing 比 refcounting 快 20%」这种不可能的数字。

三级修正,按有效性排序:

1. **rc 参照臂进交错轮转 + `rc-spread` 诊断列**。这一列的价值不在修正数字,在于
   告诉你哪一行不能用(> 15% 直接标 UNUSABLE)。没有它,噪声会被当成结论。
2. **核心隔离**:lane 编译 `taskset -c 0-14`,测量 `taskset -c 17`。splay 的 spread
   从 105% 降到 2.1%。**但对 24 秒的 EB 无效**(仍 92%)——taskset 分不了共享 LLC
   和内存带宽。
3. **持续筛选改用指令数**(`perf stat -e instructions`):同样负载下 rc-spread 只有
   **0.06-0.19%**,比 wall clock 稳定三个数量级。

**指令数只是筛选仪器,不是验收仪器。** 本战役追的是访存停顿,指令数看不见它。用法
是:指令数便宜地筛掉回归和零效应;**布局类改动增加指令不等于变坏**;裁决必须在
**lane 全部停工的安静窗口**里取 cycles + L2 refill + IPC。本轮安静窗口的 rc-spread
是 0.17-1.87%,数据可信。

big.LITTLE 坑:`perf stat` 输出两个 PMU,`armv8_pmuv3_0`(小核)恒为 `<not counted>`,
只有 `armv8_pmuv3_1` 有数;按 `,instructions` 匹配两行都不中(实际文本是
`/instructions/`),必须匹配 `pmuv3_1/instructions`。

### 本轮裁决

- **lane-c `3015ee38`(索引戳收进 `allocCell`)— 合入。** 起因是 lane-e 的新负向
  测试直接 `heap.allocCell()` 后 `heap.freeSmallCell(cell.ptr)` 打爆 assert。根因
  不是引擎回归,而是**不变量被拆在两个模块**:`freeSmallCell` 从 cell 前缀读回索引,
  写入它的却是 `gc.zig` 的分配钩子。修法是把戳移进 `allocCell`,让不变量在建立处成立。
- **lane-a(消除编译期已关闭仍在付费的记账,7 commit)— 合入。** 指令 geomean
  1.0974 vs base 1.1021,6 个基准中 5 个为正。
- **lane-d `c45891a5`(内联两槽属性)— conditional go,机制对定价不对。** 合到当前
  主线后在安静窗口取数:splay **+2.48%**,EB −0.91%,raytrace −0.33%,deltablue −0.35%。
  **四个基准的 L2 refill 几乎全部下降、IPC 全部上升**——内联确实减少了访存停顿,
  但新增指令跑在一条比它兑现收益频繁得多的路径上。返工要求:把「有没有内联槽」的
  判断做成免费的(复用已在 cache 的位 / 上移到分配点 / 只对已知 ≤2 槽的分配点内联),
  验收线是 splay 的 +2.48% 保住且另外三个不低于 −0.1%。
- **lane-b(§4.5 header 首刀)— 待它自补 L2/cycles 证据。** 指令 geomean 1.1057 vs
  base 1.1021(增 0.33%),同属布局换局部性,不能用指令数裁决。
- **lane-d D4(更深预取)— 自判否决,采纳。** 7,309,712 次真实 LIFO pop:连续
  block-cell 对 **97.54% 已天然同 64KiB block**;top-1 预取目标 83.35% 在八次 pop 内
  被消费,depth-4 目标仅 0.0638%。已转 lane-e,要求它把「不弹栈窥探第 k 项」与
  「批量 pop N 个再逐个处理」区分开——后者的 N 个是确定会被处理的,不存在目标上浮
  被取代的问题。

### 顺带暴露的问题

lane-e 给 `gate_smoke.sh` 加的 committed/live 列显示,**六个基准无一满足 §1.3 的
peak/live < 1.8**:deltablue 12.04x、pdfjs 5.26x、raytrace 4.72x、EB 3.72x、
regexp 3.49x、splay 3.43x。已转 lane-f,要求它先钉死「committed/live 与 §1.3 的
peak/live 是否同一个量」再谈达标——光是 growth=1.75 这一条,peak/live 的下限就已
接近 1.75,§1.3 的 1.8 是否自洽本身就是待答问题。

## §4o 官方读数:splay 是全部剩余差距(2026-08-28)

主线 `d036cd7d`,四门俱全(rc 单测 2375/0、trace 单测 2440/0、fixed-work 冒烟
all clean、**trace 构建 test262 0/49778 passed 44584**)。官方口径 fixed-work
geomean,单核 core 17,五组配对 ABBA 样本,rc-spread 0.6-1.6%:

| | deltablue | regexp | pdfjs | raytrace | earley-boyer | splay | geomean |
|---|---:|---:|---:|---:|---:|---:|---:|
| §4h.3 | 0.974 | 0.995 | 1.034 | 1.123 | 1.134 | 1.737 | 1.142 |
| **现在** | **0.967** | 1.026 | **1.019** | **1.056** | **1.064** | **1.537** | **1.0973** |

**结论:去掉 splay,其余五个的 geomean 是 1.0258——margin 1.05 已经达标。**
splay 若降到 1.05,全六是 1.0298。也就是说 **splay 一个基准承担了全部剩余的
4.7pp**,其余五个不但不欠账,还有 2.4pp 的余量。

这改变了优先级排序。此前六条 lane 按「机制」分工(布局 / 根 / 证据 / 包络),
现在应当按「是否能动 splay」重排:**任何不能动 splay 的改进,对合并门的贡献是
零**,因为门绑的是六基准 geomean 而其余五个已经在线内。

已知的 splay 事实,按证据强度排序:

1. **splay 违反弱分代假说**——历史实测「关掉 minor 快 21%」。这是目前已知最大的
   单一杠杆,且从未被做成自适应机制。
2. **它是访存受限而非指令受限**:cycles 1.537 对指令 1.271,比值 1.21;其余基准
   的 cycles/insn 比值在 1.0 附近。
3. **存活集极小**(一次快照约 141 KiB),而 committed/live 读数 3.4-3.8x 全部来自
   2 MiB superblock 粒度,不是 GC 超额(见 §1.3 修正)。
4. **rc 在 splay 上只花 1.86s**,是六个基准里 rc 最快的一个,所以分母小、比值放大。

lane-b 的紧凑 header(72→64 字节)在 splay 上已经做到 +1.96%,lane-d 的内联槽
做到 +3.14%,两条布局线都在正确方向上,但单靠布局把 1.537 拉到 1.05 需要 32%,
远超它们的量级。**自适应 minor 是唯一有已测量的 21% 量级证据的候选。**

## §4p 整体 review(2026-08-28,并行暂停,owner 令)

范围:f4d378d0 → c38a3c3d,55 个非 merge commit,72 文件 +10,036/−1,068。
四门 + test262 全绿,官方 geomean 1.142 → **1.0973**。以下按严重度列发现。

### R1. `object_slots2`(opcode 254)未门控进入 rc 构建 — 本次 review 最大发现

lane-d 的内联属性槽引入了新 opcode `object_slots2`,parser **无条件发射**
(parser.zig:7253 无 trace 门控),`op_object_slots2` 的两个分支都调用
`newPlainObjectReserved2Value` —— **rc 构建同样分配 96/112 字节 FAM 内联槽对象**。
三个后果:

1. **rc 行为被一条 GC lane 顺手改了**,未走 PERF-MECHANISM-LEDGER,未单独 A/B。
   补测(rc-current vs frozen-rc,六基准官方口径):geomean **0.9977**,splay
   0.981(rc 也快 1.9%),其余 ±1.3% 内。**无回归,但这是运气不是流程。**
2. **官方读数的解释要加脚注**:候选/frozen-rc 的 splay 1.537,换算成同源 rc
   对比是 1.537/0.981 = **1.567** —— 关键基准上真实 GC 代价比官方数字略差 3pp。
   六基准 geomean 层面污染仅 0.2pp,官方数字成立。
3. **合并 main 时的已知债**:main 的 opcode 声明源(F0a1,245/11 + comptime 账本
   `expected 245`)不含此 opcode;合并时账本断言会开火,须经声明源正式注册。
   这是断言按设计工作,但要有人知道它会响、为什么响。

处置建议(待 owner):机制保留(它是通用机制不是形态特判,且 rc 侧实测无害微赚),
但补 PERF-MECHANISM-LEDGER 条目 + 合并时走声明源注册;若 owner 认为 rc 不该
搭车,加 emit 门控一行即可。

### R2. 预取批量机制:三档全负,已删除

lane-e 的 mark_prefetch_batch(4/8/16)cycles 全负,结论是结构性的(访存停顿
藏不住,只能布局解决)。否定结论继续保留在 §4n;实现侧已删除 build 选项、生成
配置、`MarkStack.popBatch`、representation-aware batch prefetch 与三条批量 drain,
恢复 `popPrefetch` 单项预取。想复查的人从 git 历史拿,当前代码不再维护全负机制。

### R3. 文档漂移两处,已清理

- `docs/tracing-gc-backlog.md` 已按 A1-A4、B1/B2 和 C 节当前裁决刷新。
- design §6.1 已改为两个正交的 stopped-trace 轴:
  `sealed/stopped_dynamic` 布局与
  `parallel_stw/owner_stw/unsupported_legacy_callback` 亲和,由编译期描述符和
  trace authority 门禁、不占 per-object header。原
  `atomic_slots/snapshot/mutator_only` 三分法及 seqlock 协议移入 Appendix A,
  只有 mutator-concurrent payload traversal 被新证据重启时才生效。Stage 6 的
  过时 owner-remark 句也已修正:worker 枚举已经存在,形式是 parallel STW。

### R4. 保留但记账的项

- LANE_RULES.md 被跟踪进仓库:战役期间它是规则分发机制,保留;**合并 main 前
  必须移除**(连同任何 lane 私有文件)。
- 本战役新增约 12 个 verify* 检查器(表示不变量、构造根、发布 cell、循环链表、
  留任事务等),全部挂在 arena audit 下,是这一轮质量的主要来源;下一轮 review
  应抽查它们是否都有注入验证记录(本轮只验证了新增的大部分,没有逐一登记)。
- Stage 5 gate 维持 FAIL 不认领(三行:渐近伸缩性、false-promotion 无判定器、
  内存放大行已被 §1.3 拆分重定义)。
- lane-a 的 §7.1 对账发现关键边界:生产 Collector 的保守捕获只有一个布尔
  (`conservative_on = !host_quiescent`),**无法区分是哪类语义根产生了某个词**
  ——这就是逐类关闭保守扫描要先解决的形状。

### R5. review 结论

主线是健康的:正确性姿态(四门 + test262 + 注入验证过的检查器群)比战役开始时
强得多,官方读数干净且 rc 参照的污染已量化(0.2pp)。并行六 lane 的代价是
R1 这类「顺手改了共享代码」的流程洞和 R2/R3 的清理债——都可控,无一阻塞。
**剩余差距 100% 在 splay(同源口径 1.567),其余五基准 geomean 1.0258 已在
margin 内。**
