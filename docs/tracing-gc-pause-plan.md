# Tracing GC: pause-first execution plan

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
3. **Memory envelope.** §1.3: quiescent committed/live < 1.3, cycle peak/live
   < 1.8. Phase 1 spends some of this budget deliberately.

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
growth factor by construction, so the §1.3 cap of 1.8 rules 2.0 out.

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
