# Block-clustered deferred drain and hot reuse

Status: **approved for joint implementation (owner ruling 2026-08-28).**

Owners: lane-d (Pass-B drain and completion proof), lane-f (hot publication,
lazy interval preparation, and allocation). This is one mechanism with two
implementation owners, not two independently priceable optimizations.

## 1. Decision summary

Do **not** replace `cycle_deferred_frees` with per-entry block records and do
not sort the parked headers before draining. The current producer already
creates an implicit block-clustered suffix:

1. `destroyDoomedSlice` consumes `doomed_blocks` one block at a time;
2. it consumes each block's doomed cell indices monotonically;
3. each object parks itself by pushing onto the global LIFO; and
4. Pass B reverses the block order and the order within each block, but does
   not interleave the blocks.

The missing JSC property is therefore not grouping itself. It is recognizing
the existing run boundary and keeping the rest of the lifecycle adjacent:

```text
global Pass A and finalizer gate (required by zjs)
    -> drain one existing block run
    -> publish that completed partial block at the hot-list head
    -> on the next block acquisition, lazily build its intervals
    -> allocate immediately from the prepared block
```

The first implementation should preserve the global stack, teach the drain
about its block-cell suffix, and emit one `onBlockPassBComplete(block)` event
after the last parked header in a run has been handled (physically freed or
retained as a weak husk). The publication event is mechanism; free-percent and
maximum-interval thresholds are policy.

## 2. Source evidence and prior price

### 2.1 What JSC actually fuses

JSC does not eagerly build every free list at the end of marking:

- `BlockDirectory::findBlockForAllocation` claims a block from
  `canAllocateBits` (`WebKit/Source/JavaScriptCore/heap/BlockDirectory.cpp`,
  lines 111--124).
- `LocalAllocator::tryAllocateIn` calls `block->sweep(&m_freeList)` and then
  allocates from that free list immediately (`LocalAllocator.cpp`, lines
  235--266).
- `MarkedBlock::Handle::specializedSweep` walks the block in address order,
  invokes destructors where required, coalesces dead cells into intervals,
  initializes the free list, and returns with those same block lines freshly
  touched (`MarkedBlockInlines.h`, lines 345--398).

This is the useful reference: laziness is also cache-temperature scheduling.
It is not permission to copy JSC's exact destructor timing. zjs must retain its
global two-pass rule because an unprocessed destructor, Shape teardown, or
deferred payload finalizer may still dereference a resource-stripped sibling.

The closest sound zjs analogue is therefore:

```text
JSC: allocation claim -> destruct + build intervals -> allocate
zjs: all resource destructors -> finalizer gate
     -> physical-free one block -> hot publish
     -> allocation claim -> build intervals -> allocate
```

### 2.2 Current zjs order already has block runs

The proof is structural, not a frequency-table inference:

- `gc_trace_stw.zig:1227--1267` finishes the block-backed object pass before
  entering any standalone-kind bucket.
- `Block.takeDoomedCell` serves one bitmap word from a register and advances
  monotonically through a block.
- `Object.destroyFromHeader` parks the current object only after its resources
  are stripped.
- `DeferredFreeStack.push` prepends that header. A slice boundary may stop in
  the middle of a block, but the next slice resumes that same doomed bitmap
  before moving to another block.
- standalone objects and the later realm/module/function-bytecode/var-ref
  phases are pushed after the block pass. They form a prefix at drain time;
  they cannot split the earlier block-cell suffix unless a destructor performs
  an unexpected nested park. The arena checker in section 7 must prove that
  final condition.

Consequently, changing the queue representation alone has no locality win to
sell. It would merely make an implicit run explicit.

### 2.3 Arithmetic before code

The refreshed splay account gives:

| quantity | current evidence |
|---|---:|
| trace cycles | 10.216 G |
| trace L2D refills | 248.59 M |
| `drainCycleDeferredFreesBudgeted` | 0.314 G cycles (3.07%) |
| nearby fixed-work parked-entry census | 11.306 M entries |
| approximate drain cost | 27.8 cycles / entry |

The refreshed `perf record` sampled cycles, not L2D refills by symbol. It does
**not** prove a per-symbol refill share, so this design will not manufacture
one. Two transparent scenarios frame what must be measured later:

- at whole-program refill intensity, the drain corresponds to about
  `248.59M * 3.07% = 7.63M` refills, or 0.675 refill per parked entry;
- a one-cold-header-line-per-entry scenario is 11.31 M refills, or 4.55% of
  the whole run.

These are pricing scenarios, not observations. A later mechanism record must
sample the L2D-refill event by symbol or add a cold run-topology diagnostic.

The proposed alternatives have very different write prices:

- carrying one extra 8-byte block pointer per parked entry writes about
  **90.4 MB/run**, and loads it again during drain;
- the current endpoint has 4,843 initialized blocks and 29 majors, so even the
  deliberately loose upper bound of one run per initialized block per major is
  only 140,447 run boundaries. Per-entry tagging performs roughly eighty times
  more bookkeeping than there are possible block boundaries, before counting
  the non-block prefix;
- block identity is already derivable from an exact block-cell address by the
  64 KiB mask. No pointer needs to travel with the entry.

This rejects the proposed per-entry block pointer. If the arena checker finds
that the structural run proof is false, the fallback is a compact per-run
descriptor spliced once per completed Pass-A block, not an entry side table.

## 3. Proposed pipeline

### 3.1 Lane-d: consume the implicit block suffix

`drainCycleDeferredFreesBudgeted` retains its current global count/head batch
publication. It gains two modes:

1. **generic prefix:** retain the current kind switch for standalone objects,
   realm contexts, modules, function bytecode, and var refs;
2. **block suffix:** after the first exact block-cell marker, use the proven
   `block cell => Object` route, keep the current block base in a register, and
   compare the masked address of the captured `next` header to detect the end
   of the run.

The drain must capture `next` and its block identity before physically freeing
the current allocation. When a run boundary is observed, the old block has no
remaining parked entry and the drain calls:

```zig
rt.gc.block_heap.onBlockPassBComplete(block);
```

The callback also fires when the budget reaches zero exactly at a run
boundary. It does not fire when a 4,096-entry budget splits a block; the next
slice resumes from the same block and completes it later.

This direct block suffix also replaces an every-entry `GcKind` switch with the
already-proven block-object route. It does not claim a new ordering win: the
ordering was already present.

The production suffix performs no route-marker load after entry and carries no
per-entry unpublished counter. The existing budget counter is also the run
settlement cursor: `head`/`count` are published only at a real block boundary
and once at a partial-batch tail. The topology proof is invalidated once when
the Pass-A producer sequence opens, and only when `ZJS_GC_ARENA_AUDIT` is
enabled; parking a production corpse performs no checker-only store.

### 3.2 Lane-f: publish unprepared, prepare on acquisition

`onBlockPassBComplete` is a one-way completion event. Its mechanism checks are:

- Pass A has consumed the block's doomed bits;
- the just-finished run contains the last deferred header for this block;
- the global finalizer gate was satisfied before Pass B began;
- the alloc bitmap and `allocated_count` reflect every physical free in the
  run; and
- the block is neither decommitted nor on an incompatible owner list.

An empty block has already entered the ordinary `free_blocks` lifecycle and is
not a hot partial block. An allocator-current block keeps its existing local
free representation and is not republished. A private, non-empty partial block
is passed to the independent admission policy. An admitted block is pushed at
the head of `hot_blocks[size_class]` as **hot-unprepared**; publication does not
scan the bitmap or build intervals.

`openBlock` pops the newest hot-unprepared block, clears its block-list link,
then scans the alloc bitmap and builds address-ordered intervals. The first
interval becomes `bump..interval_end`; later interval heads use the existing
free-poison representation. Allocation immediately consumes that prepared
block. “Immediately” here means the next acquisition for this size class, not
preempting a still-usable active block; this matches JSC's LocalAllocator
boundary and preserves bump order.

### 3.3 Policy is not lifecycle

The completion event must not know the selected free-percent `P` or
maximum-interval `K`. A policy helper decides whether a safe private partial
block is worth putting on the hot-unprepared list.

To keep interval rebuilding lazy, the publication-side filter should be cheap
(for example, `free_cells / cell_count >= P`). `openBlock` performs the exact
bitmap reconstruction and may reject a block whose maximum interval is below
`K`, then continue to the next hot candidate. Counters must expose such false
positives; a policy with many of them is wrongly priced even though the
lifecycle is correct.

A rejected non-empty partial block is **not** an aged free block. It must be a
named cold-partial state owned either by a dedicated cold-partial index or by a
documented next-major census. It remains non-active, non-hot, non-doomed, and
non-decommittable. It may be reconsidered after later deaths; only
`allocated_count == 0` permits transition to `free_blocks` and aged decommit.

## 4. State and ownership model

The names below describe physical ownership. They do not revive the retired
five-state `gc_sweep_model` as production authority.

| state | owner/link | alloc bitmap | legal next state |
|---|---|---|---|
| doomed Pass A | `doomed_blocks` | old dead cells still allocated | parked run |
| parked run | global deferred stack, implicit contiguous block run | old dead cells still allocated | Pass-B completion |
| active partial | `active[class]` | canonical | active, empty |
| cold partial | cold-partial owner or next-major census | canonical ordinary or cold-prepared interval table | hot-unprepared, empty |
| hot-unprepared | `hot_blocks[class]` LIFO | canonical; no interval promise | preparing, withdrawn cold partial |
| preparing | private to `openBlock` | canonical | active interval, cold partial on K reject |
| active interval | `active[class]` | canonical | active interval, empty |
| empty swept | `free_blocks[class]` | zero | active after reset/recommit |

The global `doomed_pending` transaction stays open until every kind bucket,
doomed block, deferred entry, and queued/active finalizer is empty. Per-block
publication shortens the reuse clock; it does not close the global transaction.

## 5. Optional second-stage fusion inside Pass B

The first safe version may continue calling the existing physical free for
each corpse. That establishes block completion and allocation adjacency with
minimal representation risk.

If the mechanism counters show that per-cell allocator linking remains a
material part of the 27.8 cycles/entry, a second stage may add a trace-only
block-sweep free:

1. debit `MemoryAccount` and clear the cell's alloc bit/count;
2. do not write an individual returned-cell link for a private block;
3. let `openBlock` build the complete interval representation once from the
   canonical alloc bitmap.

This path is legal only for a private block. An allocator-current block must
continue updating its live free representation because the mutator may use its
other holes between destruction slices. The trace-only route must retain
diagnostic accounting, weak-husk behavior, trailing-allocation byte accounting,
and class-definition release. It must not silently change the RC denominator.

This optional fusion is the part that can directly reduce the remaining drain
instructions/stores. The basic run recognition itself should be priced as a
publication-timing change, not falsely credited with cache grouping that the
current LIFO already provides.

## 6. Representation rules

No field is added to each parked entry. The initial design should also avoid
growing `Block`; its size and offsets remain under existing comptime asserts.

`next_free` has three mutually exclusive interpretations and the flag/checker
contract must make them explicit:

| block ownership | `next_free` meaning |
|---|---|
| empty `free_blocks` or hot-unprepared list | next block address |
| active interval allocator | returned-cell index |
| ordinary active or cold partial | no block-link authority; cell holes remain in `free_list`/the alloc bitmap |

A hot-unprepared block must not simultaneously advertise a prepared interval.
Popping it clears the block-list interpretation before interval construction
writes any cell link. `resetBlock` is legal only after every list flag/link and
every doomed/parked obligation is gone.

An exact-`K` rejection after `openBlock` has rebuilt intervals retains that
valid table as **cold-prepared** state: it has no list owner and is not installed
as `active[class]`, but its bitmap, `bump..interval_end`, `free_list`, and
`next_free == free_nil` remain mutually consistent. This is distinct from
hot-unprepared, whose allocator fields carry no promise while its block-list
link owns `next_free`. If a hot-unprepared candidate survives until the next
major without being opened, withdrawal rebuilds its intervals before returning
it to census-owned cold state.

## 7. One arena invariant checker

The implementation must extend the arena audit as one whole-machine checker,
not add one test per transition. It must prove:

1. the deferred stack has an optional generic prefix followed by a block-cell
   suffix;
2. equal block bases are contiguous within that suffix (no block appears in
   two runs);
3. every block-cell deferred header is an Object with `finalizing` set and an
   allocated cell bit;
4. a block is published only after its run is absent from the deferred stack
   and its doomed bitmap/cursor are empty;
5. hot-unprepared, active, cold-partial, doomed, and empty-free ownership are
   mutually exclusive and their intrusive-link interpretations match flags;
6. every hot-unprepared block is non-empty, non-decommitted, non-young, and
   absent from `active`, `free_blocks`, and `doomed_blocks`;
7. interval reconstruction covers exactly the zero bits of the alloc bitmap,
   produces strictly address-ordered non-overlapping intervals, and preserves
   the free-poison contract;
8. only an empty swept block may age/decommit or be reset; and
9. closing `doomed_pending` still implies all global morgue representations and
   queued/active finalizers are empty; and
10. an object covered by either a queued or currently executing class-payload
    finalizer root cannot occupy a released cell in any published block.

Property 10 is the written lane-d/lane-e contract. A queued job and the job
temporarily removed from that queue while its callback executes are one root
lifetime: the latter must remain visible to root tracing and to the publication
gate. Consequently, `onBlockPassBComplete` is legal only after that lifetime
has ended. The implementation must include an adversarial `.js`-finalizer
probe whose wrapper and payload neighbour share a block; it forces collection,
block publication and subsequent allocation, then proves the callback never
observes the neighbour through a cell that has already been reused.

The checker is the proof that no unexpected nested park invalidated the
implicit-run design. A failure there reopens the per-run-descriptor fallback;
it must not be hidden with a release-only assumption.

The proof-valid bit is producer-sequence state, not entry state. Sliced Pass A
may park many entries before Pass B starts, but Pass B can only remove a prefix;
therefore one audit-only invalidation before the producer opens and one proof
before the first consumer slice covers every later 4,096-entry slice.

The checker did expose one non-reentrant producer mismatch during repricing:
the synchronous major/minor paths appended standalone objects before block
objects, whose LIFO reversal produced a block prefix followed by a generic
suffix. Those paths now condemn block Objects before the same-kind list
population, matching the incremental major without changing destructor-kind
order. This was repaired at the producer; the nested-park descriptor fallback
remains unimplemented and reserved for an actual reentrancy failure.

## 8. Mechanism counters and falsification

Diagnostics are cold/opt-in and must not become production per-corpse work.
Before cycles adjudication, collect:

- block-backed versus generic deferred entries;
- block-run count and run-length histogram;
- same-block successor ratio and runs split by the 4,096-entry budget;
- completed runs offered/admitted/rejected by `P`;
- hot candidates opened, exact-`K` rejects, and interval bitmap words/link
  writes;
- acquisitions served by hot blocks and the number of intervening block
  acquisitions between publication and use; and
- L2D-refill samples attributed to the drain, because the current refreshed
  account has only whole-program L2D totals.

The design is falsified before a cycles window if block entries are not a
contiguous suffix, typical runs are too short, exact-`K` rejects dominate, or
published blocks are rarely the next acquisition for their class.

After mechanism validation, driver prices one combined candidate. Required
observations are splay and earley-boyer cycles/wall, L2D refills, page faults,
committed bytes, superblock count, and major-pause p99. The previous hot-reuse
prototype's `-39%` faults / `-58%` committed / `132 -> 56` superblocks is a
mechanism baseline, not permission to keep its `-0.96%` splay and `-1.61%` EB
cycles. The current campaign rule applies: a meaningful splay win may spend at
most 0.3% in another fixed-work benchmark unless owner explicitly changes the
gate.

## 9. Alternatives rejected for the first implementation

| alternative | decision | reason |
|---|---|---|
| per-entry block pointer | reject | 90.4 MB/run extra writes; identity is derivable and ordering already grouped |
| hash buckets at park time | reject | allocation/state footprint for a property the producer already guarantees |
| sort/radix-bucket before drain | reject | touches every cold corpse twice before doing useful work |
| immediate struct free in Pass A | reject | violates zjs cross-object, Shape, weak-husk, and finalizer ordering |
| rebuild intervals at publication | reject initially | unclaimed blocks pay work and cool before allocation; misses JSC's lazy timing |
| publish only after global parked-empty | reject as timing | safe but loses the freshest-block-first handoff; retain only as a global completion assertion |

## 10. Review boundary and implementation split

No code should be changed until owner approves these decisions:

1. retain the global deferred stack and elevate its implicit block suffix;
2. publish hot-unprepared at each proven run completion;
3. rebuild intervals in `openBlock`, not at publication;
4. give K-rejected non-empty partial blocks an explicit non-decommittable owner;
5. keep thresholds as separately measurable policy; and
6. default every new route to trace-only.

After approval, lane-d owns drain mode selection, run-boundary completion, the
deferred-stack checker, and any trace-only no-link Pass-B specialization.
Lane-f owns hot/cold partial membership, lazy interval preparation, allocation
handoff, decommit/reset invariants, and threshold diagnostics. The combined
candidate is reviewed and measured as one commit chain.
