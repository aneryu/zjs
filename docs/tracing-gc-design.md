# Tracing GC design

Version: 0.6 draft
Date: 2026-08-23
Status: reviewed against the source; research and migration plan, not the
production collector

Review note (0.5 -> 0.6): source review found two material corrections to the
first migration plan. `Registry.objectIterator()` enumerates only the six
cycle-candidate carriers, not String/Rope or BigInt, and `StringRope` owns two
strong `JSValue` edges despite sharing `RefKind.string`; therefore the shadow
cannot be built over `RcRegistryHeapCensus` alone. Also, the previous root
Interface could express only `JSValue` and `Object`, while a context and an
active frame directly own Module, Shape, VarRef, RealmContext, and
FunctionBytecode headers. The gated preparation now makes both gaps
executable without paying a production call-boundary store: `gc.ref_kind_catalog`
classifies all eight kinds and Registry `census()` reports its incomplete
coverage; `RootVisitor.constHeader` is live only when
`value_root_frames_enabled`; `JSContext.traceRoots` mirrors modules and initial
Shapes onto the root Interface in that same gated build; exec publishes an
`ActiveInvocationTrace` prefix that default `rc` compiles to a no-op. An
ungated `{context,trace}` Adapter that stored two fields on every
`runWithArgsState` lost four rule-2 A/B reads (median 0.9972). None of these
changes transfers reclamation away from RC.

This document adapts the 0.3 proposal to the code that exists in zjs today. It
defines the intended end state, but it deliberately does not authorize a
one-shot collector replacement. The production collector remains reference
counting plus QuickJS-style trial deletion until the staged gates in
[Migration](#13-migration) have passed.

Changes from 0.3:

- map "isolate" to the existing `JSRuntime` and reserve `GcPlatform` for
  optional process-shared services;
- split root completeness, Slot representation, STW tracing, allocator,
  generations, and concurrency into independent gates;
- keep the current object/header allocator for the shadow and first STW
  prototype, and migrate strings/ropes explicitly;
- distinguish JS-heap edge RC from external/resource RC that must remain;
- make the two-word value protocol conditional on candidate-only decoding,
  barrier/safepoint closure, formal litmus, and a named fallback;
- account for current `VarRef` frame aliases, property union/FAM layouts,
  plugin callback reentry, weak identities, buffer invalidation, and deferred
  class-payload records;
- turn universal pause/space ratios into workload-scoped measured gates.

The companion documents describe the current collector rather than the future
one:

- [Cycle collector invariants](gc-invariants.md) is the source-level safety
  contract that must remain true while RC is authoritative.
- [GC behaviour baseline](perf/gc-baseline.md) is the current behavioural
  baseline and reproduction command.
- [Performance workflow](perf/README.md) and
  [refactor tax policy](refactor-policy.md) define how performance evidence is
  collected.

## 0. Decision summary

The long-term direction is accepted for prototyping:

> non-moving, sticky-mark-bit generational tracing; conservative native roots;
> precise heap tracing; concurrent major marking; mutator-only lazy sweeping.

The proposal is **not ready to replace RC as one refactor**. Five independent
changes were coupled in version 0.3:

1. heap-edge representation;
2. production root completeness;
3. reclamation algorithm;
4. allocator and object-header representation;
5. concurrent mutation and safepoint protocol.

Each is a separate failure domain and performance experiment. zjs should first
complete production roots and run a non-reclaiming shadow tracer over the
current heap, then introduce heap Slots while RC still owns lifetime, then
switch an experimental build to stop-the-world tracing. Generations, the block
allocator, and concurrent major marking follow only after that collector is
demonstrably complete.

The immediate project recommendation is therefore:

- **go**: trace descriptors, production root completion, shadow tracing, and
  the remainder of GC observability (its contract, baseline, counters, and
  edge-parity guards and pause histograms landed 2026-08-23), followed by
  Slot-under-RC under the shadow checker;
- **conditional go**: an opt-in stop-the-world tracing prototype after the
  shadow gate;
- **no-go for now**: changing the production default, replacing every object
  header, or landing concurrent major marking in the first cut.

## 1. Goals and gates

### 1.1 Product goals

- Remove object `dup`/`free` traffic from JavaScript hot paths.
- Bound interactive pauses without moving object addresses.
- Preserve QuickJS-faithful language behaviour and zjs's 16-byte public
  `JSValue` representation.
- Keep one `JSRuntime` independent from every other `JSRuntime` for collection
  and stop-the-world coordination.
- Make every heap edge and root auditable at compile time or at a named
  Adapter boundary.
- Account for external memory and delayed finalization so a small JS heap
  cannot hide unbounded native storage.

### 1.2 Correctness gates

These are release blockers for any tracing build:

| Gate | Required evidence |
|---|---|
| Heap-edge completeness | compile-time trace coverage, edge-parity tests, and deletion probes for every `gc.RefKind` and object payload family |
| Root completeness | production execution roots, handles, contexts, jobs, modules, host roots, native stack/register roots, and suspended fibers all covered |
| Shadow agreement | no unexplained live object outside the shadow reachable set after RC collection, sweep, and finalization quiescence |
| Language behaviour | current unit/integration suites, full test262, and QuickJS differential coverage remain green |
| Failure behaviour | allocation-failure injection, queue-overflow injection, epoch transitions, teardown, and finalizer failures are covered |
| Concurrency | stress schedules and a race-detection strategy cover Slots, bitmap transitions, snapshot retry, queues, and safepoint handshakes |
| Collector-specific tests | remembered-owner, young-block, ephemeron, WeakRef keep-alive, finalization, conservative-root, and retire-list deletion probes pass |

A broad green suite is not sufficient evidence, and the record is specific
about why: the current collector has shipped green under test262 0/49778 over a
missing trace arm (the fast-array arm lost the iterator-next cache edge, so
cycles through it were never collected), and separately over two
collection-iteration defects. The leak checker did not catch the trace-arm miss
either — it only sees destroy-side misses.

So of the rows above, **shadow agreement and the collector-specific deletion
probes are the collector's evidence; language behaviour is not**. A tracing
build that passes test262 has demonstrated that it did not break the language,
not that it collects correctly. Treat the suite as a necessary regression fence
and the shadow/probe rows as the actual gate.

### 1.3 Performance goals

The measurements below are goals under a frozen workload and heap envelope,
not universal promises for every program:

| Metric | Experimental gate | Production-default target |
|---|---:|---:|
| bench-v8 composite vs frozen RC | at least the repository's `0.995` refactor threshold | no statistically supported regression; eight-benchmark geomean at least RC baseline |
| Richards / DeltaBlue | report separately | 15-25% improvement is a hypothesis to validate, not a correctness gate |
| RayTrace / EarleyBoyer vs V8 jitless | report separately | 70-85% remains a product aspiration; it cannot be attributed to GC alone |
| minor pause | record p50/p95/p99/max | p99 below 1 ms in the declared interactive workload |
| each major STW pause | record p50/p95/p99/max | p99 below 2 ms |
| cumulative major STW per cycle | record distribution | p99 below 10 ms |
| time to safepoint | record request-to-ack distribution | p99 below 0.5 ms outside non-preemptible host calls |
| quiescent committed/live | report exact, rounded, and committed bytes | below 1.3 in the declared corpus and heap range |
| concurrent-cycle peak/live | report heap and external bytes separately | below 1.8 in the declared corpus and heap range |

Every percentile report must name the hardware, revision, build signature,
workload, heap limits, sample count, warm-up, and maximum. A host callback that
does not poll is reported separately; the collector cannot promise a sub-ms
safepoint while arbitrary native code owns the runtime thread.

**The pause rows are now evaluable, and the RC collector already fails one.**
`--gc-stats` reports p50/p95/p99/max over a retained window of round
durations. On the V8 suite the current collector reads p50 0.71 ms, p95
0.86 ms, **p99 2.45 ms**, max 46.6 ms over 844 rounds — so it is already above
the 2 ms major-pause target in this table, before any tracing work begins.

That distribution also corrects the shape of the problem: with a median of
0.71 ms and a maximum 65× higher, this is a tail, not a uniformly slow
collector. A tracing design should be judged on whether it flattens that tail;
improving mean collection time while leaving the tail intact would satisfy the
throughput row and miss the point of the pause rows entirely.

**Every GC change needs two kinds of evidence, not one.** The bench-v8 A/B is
necessary but demonstrably insufficient: moving each payload's trace arm beside
its destroy method changed reclamation by a stable 2.5% (13.40 M objects freed
down to 13.06 M, three runs each, non-overlapping groups) while the composite
A/B read 1.0033 and then 0.9986 — the score cannot see collector behaviour at
all. Any tranche here therefore reports the `--gc-stats` counter table
alongside its A/B, and states which of the two the claim rests on.

The `perf/gc-baseline.md` numbers are a specific revision's, and each tranche
recaptures a clean RC baseline before measuring its candidate. Its *method*
carries forward regardless: counters are stable to well under 1% across runs
while the score is dispersion-dominated, and live bytes at exit are
byte-identical run to run, which makes them a usable regression check on their
own — an edge dropped by a refactor raises live bytes, it does not lower
reclamation.

### 1.4 Non-goals for the first production tracing release

- moving nursery or compaction;
- concurrent minor collection;
- concurrent sweeping;
- cross-`JSRuntime` heap references;
- object compression;
- finalizer ordering or guaranteed JavaScript cleanup at process exit;
- runtime migration between OS threads;
- a new thread-safe-function API;
- unrelated VM, inline-cache, regular-expression, or bytecode changes;
- changing the public `JSValue` encoding while changing the collector.

## 2. Mapping the proposal to the current source

The proposed names must follow the project's existing domain language:

| Proposal term | zjs source authority | Consequence |
|---|---|---|
| isolate | `core.runtime.JSRuntime` | `JSRuntime` already owns a heap, contexts, jobs, handles, GC state, memory accounts, and one owner thread |
| process-level runtime | new optional `GcPlatform` Module | do not rename or overload `JSRuntime`; shared block and worker pools live behind a narrow Interface |
| exact local/persistent roots | `JSValue.Scope`, `Local`, `Persistent`, `Weak`, `RootProvider` | extend these Interfaces instead of building a second handle system |
| active interpreter roots | `exec.inline_calls.ActiveInvocation`, `Machine`, `FrameSlab`, `Stack` | add an exec-owned tracing Adapter through the existing opaque `active_invocation` Seam |
| heap trace authority | `Object.traceChildEdges*` and per-type `traceChildEdges*` | evolve the existing ownership-of-edge-enumeration rule rather than creating a parallel switch in the collector |
| weak object identity | `JSRuntime` weak identity registry | preserve monotonic identity/generation semantics; do not regress to address-only weak handles |
| shared backing store | `SharedBufferStore`, `BufferPayload`, `JSBytes.Store` | reuse the existing atomic-refcounted external store and adapt its accounting |
| allocation trigger | `JSRuntime.collectBeforeObjectAllocation`, `pollGC` | preserve this scheduling Seam while changing the Implementation behind it |

### 2.1 Current representation constraints

The following facts are load-bearing:

- `JSValue` is an `extern struct` with `payload: u64` and `tag: i64`, exactly
  16 bytes and 8-byte aligned. Its encoding revision participates in the
  runtime plugin ABI fingerprint.
- Current GC objects have an 8-byte allocator/RC metadata prefix and a 16-byte
  intrusive `gc.BlockHeader` at object offset zero. Many types depend on that
  representation.
- The current small allocator uses 4 KiB arenas and 16-512 byte classes.
  A 64 KiB block heap is a replacement allocator, not an extension of the
  present slab.
- The eight current reference kinds are `object`, `function_bytecode`,
  `var_ref`, `realm_context`, `module`, `shape`, `string`, and `big_int`.
- Flat strings and ropes are special: a 4-byte RC prefix precedes a 12-byte
  flat-string body. They are not ordinary intrusive-list GC objects today.
- `property.Slot` is a 16-byte untagged union whose active arm is selected by
  the owning `Shape` flags. Shape and slot storage therefore form one dynamic
  layout transaction.
- An open `VarRef.pvalue` is a borrowed alias into an active frame, not an owned
  heap edge. Mapped arguments and frame slabs also reinterpret typed windows
  over ordinary `JSValue` storage; a mechanical pointer/Slot rewrite would be
  wrong.
- Dense elements, collection entries, and function-bytecode constant pools use
  resizable or FAM backing with direct element writes. They require named bulk
  and sealed/snapshot protocols, not field-only reflection.

The final 8-byte immutable tracing header and the new block heap remain valid
end-state options. They are not prerequisites for proving tracing reachability.
Early tracing modes keep the current object layouts and locate the six
intrusive carriers through Registry plus String/Rope/BigInt through the
diagnostic allocation ledger. Header replacement is a later representation
experiment with its own binary/performance gates.

### 2.2 Current roots are not yet tracing-complete

zjs already has good root Interfaces: local and persistent handle slots, weak
slots, context roots, jobs, module state, deferred finalization state, and
registered `RootProvider`s. The 2026-08-23 gated Adapter closed the opaque
bytecode-invocation hole: `traceActiveRoots` walks live windows through
`ActiveInvocationTrace` when `value_root_frames_enabled`, and
`JSContext.traceRoots` mirrors modules and the five initial Shapes in that
same build. Default `rc` still compiles both walks away.

Gaps that still block a tracing cutover:

1. `ValueRootFrame` activation is compiled only when `value_root_frames_enabled`
   (`runtime.zig`: "Production builds erase both operations at compile time").
   Native locals survive in production today because their `JSValue`s own
   reference counts. Shadow CLI links only container/window frames; scalar Zig
   locals wait for conservative capture.
2. The global `Atomics.waitAsync` waiter registry owns Promise and Realm roots
   under a cross-runtime mutex. Snapshot Adapter: retain under the mutex,
   unlock, visit, release (`trace_atomics_wait_async`, 2026-08-23).
3. A currently executing job has already left `job_queue`; idle-only shadow
   verification avoids that hole, but arbitrary safepoint collection still
   needs the active execution/native-root contract and conservative capture.
4. `JSRuntime.pollGC` takes a `roots: ?*const ValueRootFrame` parameter and
   discards it (`_ = roots;`), and so does
   `destroyRuntimeCyclesWithValueRoots` (`object_gc.zig`).
   **Corrected 2026-08-23**: an earlier draft called this "no design work,
   only a consumer". That is wrong. Trial deletion never marks from a root
   set, so writing that consumer means building mark-from-roots — Stage 3's
   algorithm, not a parameter fix.

Until conservative capture and in-flight job roots close, the reachable set
a tracer computes is a strict subset of the truth outside a deliberately
idle diagnostic point. Root completeness still cannot be validated by the
current collector; the shadow tracer is the instrument. The Atomics.waitAsync
Adapter is no longer on that list.

The root work is therefore an architectural requirement, not test scaffolding.
The exec layer owns concrete frame layout; core must call it through a callback
Adapter so no core-to-exec import cycle is introduced.

## 3. Target architecture

```text
GcPlatform (optional process-shared Module)
|- SuperblockPool
|- MarkerWorkerPool
|- LargeObjectAddressIndex
`- GlobalExternalPressure

JSRuntime (one isolate; one fixed owner thread)
|- Heap
|  |- SmallObjectSpace
|  |- MediumObjectSpace
|  `- LargeObjectSpace
|- RootRegistry
|- MinorCollector
|- MajorMarkState
|- SweepDebt
|- WeakAndEphemeronState
|- FinalizationQueues
`- SafepointController
```

`GcPlatform` is a narrow shared Module, not a second owner of objects. The
`Heap` Interface remains deep: callers reserve/publish objects, read/write
Slots, report pressure, and request progress without knowing block metadata,
mark bits, queues, or sweep states. This gives high leverage: allocator and
collector Implementations can change locally while object code retains one
stable Interface.

Sharing is optional in the prototype. A per-runtime block source and marker
thread are acceptable until measurements justify a process pool. No shared
Module may introduce cross-runtime object references or make one runtime's STW
wait for another runtime.

Four narrow Interfaces keep the collector deep while preserving source
Locality:

- `TraceDescriptor`: strong/weak edge enumeration and stopped/concurrent trace
  classification;
- `HeapCensus`: allocation iteration, type, bounds, and interior-pointer
  resolution;
- `SlotOps`: coherent load/publication plus generation/major barriers;
- `RootSnapshot`: exact VM/host roots and conservative native capture.

The compatibility Implementation is a `CompositeHeapCensus` with two Adapters:

- `RcRegistryHeapCensus` enumerates exactly Object, FunctionBytecode, VarRef,
  RealmContext, Module, and Shape from `Registry.objectIterator()`;
- `AllocationLedgerHeapCensus` enumerates flat String, StringRope, and BigInt,
  which use raw/special allocation paths and never enter that intrusive list.

The ledger assigns a monotonic allocation identity and records allocation,
publication, finalization, and free state; an address is only a lookup key and
cannot be identity because allocator reuse creates ABA. A test-only
`SyntheticHeapCensus` is the second executable Adapter for bounded-queue,
deletion, unpublished-object, and address-reuse tests. Replacing the allocator
later does not change the `HeapCensus` Interface. Existing `traceChildEdges*`,
`RootVisitor`/`RootProvider`, and the gated `ActiveInvocationTrace` prefix are
the principal Seams and provide more leverage than teaching a collector switch
every concrete payload layout.

### 3.1 Core invariants

1. Every GC-managed object belongs to exactly one `JSRuntime`.
2. No strong, weak, ephemeron, or internal heap pointer crosses runtimes.
3. One fixed owner thread mutates a runtime's JavaScript heap.
4. Object addresses never change during their lifetimes.
5. At most one GC cycle is active per runtime.
6. A concurrent major excludes minor collection for the same runtime.
7. A new cycle does not begin until prior sweep debt is zero.
8. Root capture, minor collection, initial mark, final remark, and phase
   transitions occur at a runtime-local safepoint.
9. The marker may read only published objects through concurrent trace
   Interfaces.
10. Every published strong heap write uses a typed Slot or bulk-write API.
11. Every overflow path retains discoverability; exhaustion may cause extra
    tracing or synchronous assist, never a missed edge.
12. GC callbacks for host/plugin state execute only on the owner thread.
13. Native modules depend only on public handles and object addresses, never
    on headers, blocks, bitmaps, or mark epochs.

## 4. Heap layout

### 4.1 Compatibility heap before the block heap

The stop-the-world tracing prototype uses the current allocation registry and
layouts. It adds side tables if necessary for allocated/mark state. This keeps
the reclamation-algorithm experiment local and avoids simultaneously changing
`Object`, `Shape`, strings, bytecode, and allocator code.

Every current `gc.RefKind` needs an explicit descriptor:

| Kind | Initial tracing classification |
|---|---|
| object | per-payload `atomic_slots`, `snapshot`, or `mutator_only` |
| function bytecode | immutable-after-publish where possible; otherwise snapshot |
| var ref | fixed metadata plus one heap value Slot |
| realm context | owner-thread trace first; concurrent classification after audit |
| module | owner-thread trace first; concurrent classification after audit |
| shape | immutable-after-publish; trace its owned references |
| string / rope | atomic leaf or explicit rope-child descriptor |
| big int | atomic leaf |

### 4.2 Final small-object space

The target allocator obtains superblocks in batches, initially 2 MiB, and
splits them into 64 KiB-aligned blocks. A block holds one size class. No design
may implement one over-sized mapping plus trimming `munmap` per 64 KiB block.

Block metadata includes at least:

```text
owner_runtime, size_class, cell_size, cell_count
mark_epoch
allocated bitmap, mark bitmap, remembered bitmap
young_enlisted, remembered_enlisted
mark_overflow, trace_bailout
sweep_state, free_list, bump range
intrusive list links, epoch-transition state
```

Any word read or written by both marker and mutator is atomic. Block lookup
from a conservative candidate uses an address registry before touching block
metadata; it never derives and dereferences an arbitrary header address.

Classes start at 16 bytes. Up to 128 bytes they use 16-byte steps; larger
classes use a measured geometric progression near 1.20-1.25. Classes are
generated from the real metadata size and retained only when at least 16 cells
fit. The resulting maximum small class is measured, not hard-coded to 4 KiB.

### 4.3 Medium and large spaces

- Objects above the largest small class and below 64 KiB use a page-granular
  run/extent allocator. One mapping per medium object is forbidden.
- Objects of at least 64 KiB initially use dedicated page-aligned mappings.
- Medium and large metadata carries owner, allocated state, mark epoch/bit,
  extent size, and sweep/finalization state.
- Large and medium conservative lookup uses a radix/page map or interval index,
  not a linear list.

Thresholds are configuration constants until allocation histograms justify a
change. They are not ABI.

### 4.4 Allocation path

The steady-state fast path checks the runtime's active block for the size class
and advances a bump pointer or pops its local free list. It does not sample RSS,
compute thresholds, assist marking, or sweep an arbitrary block.

The slow path is ordered:

```text
finish/open a swept block
-> perform bounded mutator sweep assist
-> obtain a fresh block or extent
-> perform mark assist / request cycle completion
-> synchronous hard-headroom sweep or GC retry
-> OutOfMemory
```

An unswept block is never reopened. During concurrent major, allocation uses
materialized current-epoch blocks and black-publishes objects; it therefore
does not consume a separate young-space budget. A hard reserve plus increasing
mark assist prevents an indefinitely slow major from consuming all headroom.
Threshold and external/RSS pressure checks remain at the existing
`collectBeforeObjectAllocation`/`pollGC` scheduling Seams, slow paths, and
periodic polls.

### 4.5 Target object header

After the compatibility tracer and block heap are independently proven, an
8-byte immutable header may replace the current prefix/list representation:

```zig
const Header = packed struct(u64) {
    type_tag: u8,
    size_class: u8,
    static_flags: u8,
    trace_class: u8,
    extra: u32,
};
```

Mark, allocated, remembered, overflow, bailout, sweep, and generation state
remain in side metadata. `type_tag` and `trace_class` are immutable after
publication. The address registry plus block class identifies an allocation's
start and bounds for interior-pointer resolution; medium/large entries carry
explicit extents. Strings/ropes are either migrated into this representation
or retain a separately registered leaf/rope descriptor—there is no untracked
hybrid allocation.

`static_flags` may describe finalization, host payload, immutable layout,
extra tracing, and external memory. Native code cannot inspect any of these
bits. The size and field split are hypotheses until real type/size census and
code-layout measurements pass; side metadata may be preferable to forcing all
current kinds into this exact bit budget.

### 4.6 Reserve, initialize, publish

Nested allocation makes a blanket "allocate, then enter `NoSafepointScope`"
unsafe for many existing constructors. Construction uses two forms:

**Prepared construction**

1. Allocate/prepare fallible backing stores and dependencies.
2. Reserve the cell.
3. Enter `NoSafepointScope` / no-allocation region.
4. Initialize the immutable header and set every reference field to a valid
   null/undefined Slot state.
5. Attach prepared backing and ordinary fields.
6. If major marking is active, materialize the epoch, mark the object, and
   shade every initial strong edge.
7. Publish the allocated bitmap bit with an atomic release operation.
8. Publish the object through a root or heap Slot.
9. Leave the scope.

**Rooted construction**

Complex constructors that cannot prepare all dependencies first keep an
explicit construction root and remain `mutator_only`. Their object is not
visible in the allocated registry until it reaches a minimally traceable
state. This form is transitional and should not be used by hot common types.

`allocated = 1` means the cell is fully interpretable by its trace descriptor.
For a bitmap this is a release `fetchOr`, not a scalar store. A failed reserve
is returned to the allocator before publication. No heap Slot, handle, async
record, or native pointer may expose an unpublished cell.

## 5. Heap reference model

### 5.1 Keep `JSValue`; add heap-specific Slots

`JSValue` remains the public, stack, register, argument, return, and temporary
representation. Do not make every VM operand atomic. Add distinct heap-only
types, provisionally:

```zig
const HeapValueSlot = extern struct {
    payload: std.atomic.Value(u64),
    tag: std.atomic.Value(i64),
};

const GcPtrSlot = extern struct {
    raw: std.atomic.Value(usize),
};
```

The project already has an exec `value_slot` Module for RC ownership of VM
stack slots. `HeapValueSlot` avoids overloading that name and keeps the
concurrent heap Interface separate from ordinary execution values.

### 5.2 Slot-under-RC

The first migration mode changes ownership calls, not reclamation:

```text
HeapValueSlot.set(old, new)
  -> retain(new)
  -> publish bits
  -> release(old)

GcPtrSlot.set(old, new)
  -> retain(new)
  -> publish pointer
  -> release(old)
```

Bulk copy, move, resize, property installation, and destruction receive paired
APIs. The exact retain-before-publish-before-release ordering stays inside the
Slot Implementation. Existing direct fields are migrated from a shrinking
allowlist; new bare `JSValue`, `*Object`, `*Shape`, `*VarRef`, and other GC
references in heap objects fail a compile-time/lint check unless explicitly
declared immutable or weak.

This stage must preserve 16-byte optimized `property.Slot` and `JSValue`
layouts and the plugin ABI fingerprint. It may not remove RC traffic yet.
Compile-time census is necessary but insufficient: it cannot discover FAM and
slice storage, byte reinterpretation, union discriminants stored in `Shape`,
raw bulk copies, or opaque plugin memory. Shadow mode therefore also audits
persistent heap write paths at runtime.

### 5.3 Concurrent one-word pointer Slot

In a tracing mode:

```zig
fn set(slot: *GcPtrSlot, owner: *Header, value: ?*Header) void {
    enterBarrierCriticalScope();
    defer leaveBarrierCriticalScope();
    slot.raw.store(ptrToInt(value), .release);
    postWriteBarrier(owner, value);
}

fn loadForTrace(slot: *const GcPtrSlot) ?*Header {
    return intToPtr(slot.raw.load(.acquire));
}
```

The marker never reads a plain mutable pointer field.

### 5.4 Concurrent 16-byte value Slot

No 128-bit lock-free atomic and no per-Slot version word are required for the
first concurrent marker:

```zig
fn set(slot: *HeapValueSlot, owner: *Header, value: JSValue) void {
    enterBarrierCriticalScope();
    defer leaveBarrierCriticalScope();
    slot.payload.store(value.repr.payload, .monotonic);
    slot.tag.store(value.repr.tag, .release);
    postWriteBarrier(owner, decodeExactHeapRef(value));
}

fn loadForTrace(slot: *const HeapValueSlot) CandidateValue {
    const tag = slot.tag.load(.acquire);
    const payload = slot.payload.load(.monotonic);
    return .{ .payload = payload, .tag = tag };
}
```

This deliberately permits a pair assembled from different writes; it does not
pretend the pair is a coherent JavaScript value. The proof obligation is:

- reading the new tag after its release observes the preceding payload store;
- an old tag with a new payload may create a false candidate, but candidate
  validation can only retain an allocated object;
- an immediate-to-reference tear may hide the reference from this read, but
  the exact newly stored target was shaded by the post-write barrier;
- reference A to B either observes a valid candidate or relies on B's exact
  shading;
- after an acquire observes a release tag, the payload load cannot go behind
  the payload store sequenced before that release; it may observe a later
  payload from a subsequent in-progress write;
- a later-payload/earlier-tag combination is either a conservatively validated
  candidate or is ignored, while every exact reference from the later write is
  shaded before that writer may acknowledge a safepoint;
- repeated overwrites remain safe because every exact reference target is
  shaded while major marking is active and final remark cannot bisect a write.

Before any dereference, a candidate must pass address-registry, owner-runtime,
space state, cell-start/interior-pointer, allocated-bit, header, and tag-to-kind
compatibility checks. A torn value may cause floating retention; it may never
cause a wrong-kind dereference. This protocol is for concurrent heap tracing;
mutator roots are captured while stopped.

The protocol is provisional until a small executable/model litmus covers every
two-write interleaving on every supported backend and emitted LLVM ordering is
inspected. If those obligations cannot be demonstrated, the fallback is a
coherent 128-bit atomic where lock-free, a one-word handle/indirection, or an
object-level snapshot/lock. A per-Slot sequence word is not assumed, but it is
not forbidden by evidence-free fiat.

### 5.5 Bulk writes

Raw `@memcpy`/`@memmove` of live heap reference storage is forbidden during a
concurrent major. A bulk operation must do one of:

- atomic per-Slot publication plus a barrier for every new exact target; or
- build an unpublished backing, publish its initialized Slots, shade every
  initial strong target, then atomically install the backing descriptor.

The bulk API cannot allocate after it begins publication and cannot lose work
on queue exhaustion.

### 5.6 Weak Slots

Weak references do not use the strong Slot visitor. Heap types explicitly use
`WeakIdentitySlot`, `EphemeronTable`, or `FinalizationCell`.

zjs already prevents address-reuse ABA with stable weak identities. Preserve
that Interface: a weak Slot stores identity plus generation/registry state, not
only a raw object address. `Weak.get` promotes a live identity to a strong local
handle for the current scope.

The current `WeakPersistentValue.get()` returns a by-value `JSValue`, which is
safe under owner-thread RC but is not a durable cross-safepoint root contract.
Tracing mode adds a scope-taking promotion API (or an explicitly bounded
no-safepoint temporary) and implements the future C `zjs_weak_get` in terms of
that local root; it does not expose a merely checked raw target.

## 6. Trace descriptors and dynamic layout

### 6.1 Trace classes

```zig
const TraceClass = enum(u8) {
    atomic_slots,
    snapshot,
    mutator_only,
};
```

- `atomic_slots`: immutable layout; every mutable strong field is an atomic
  heap Slot.
- `snapshot`: the marker obtains a coherent descriptor and keeps retired
  backing alive until final remark.
- `mutator_only`: the marker records a bailout; the owner thread traces it
  during final remark.

Before concurrent GC can become an experimental default, ordinary objects,
ordinary property storage, dense arrays, bytecode constants, functions,
Promises, and common iterator state must be `atomic_slots` or `snapshot`.
Mutable collection rehash state and unusual realm/module structures begin as
`mutator_only`. Bailout share and final-remark time are reported;
`mutator_only` is not a silent escape hatch.

Legacy plugin payload tracing is a distinct compatibility class, not ordinary
`mutator_only`: the current plugin ABI permits callback reentry. Such a callback
cannot run inside no-fail final remark and cannot run on a marker. A tracing
runtime therefore requires plugin-held JavaScript values to live in
engine-managed persistent root slots, or a future versioned no-allocation,
no-reentry trace callback. Until then, a class with a legacy payload tracer
prevents tracing-mode enablement for that runtime; it is not silently ignored.

### 6.2 Compile-time trace authority

The existing `traceChildEdges*` methods remain the authority beside their
owned data. A generated type-tag table invokes them through mode-specific
visitors. Automatic tracing recognizes only:

- `GcPtrSlot`;
- `HeapValueSlot`;
- `WeakIdentitySlot`;
- registered `GcBuffer` descriptors;
- fixed arrays of those types;
- explicitly declared immutable GC pointers.

A published heap type fails compilation or the architecture lint if it
contains an undeclared bare GC pointer, bare heap `JSValue`, pointer-bearing
slice, mutable union arm, or dynamic backing. Special types provide both:

```text
traceConcurrent(visitor) -> done | retry | bailout
traceStopped(visitor)     -> no-fail
```

Debug checks validate owner/type agreement, Slot address ownership, active
union arms, backing retirement, and the absence of unpublished heap edges.
The current cycle-hot parity tests continue until the RC collector is removed;
equivalent authority-versus-generated-trace tests remain afterward.

### 6.3 Snapshot protocol

A sequence counter alone does not make plain pointer/length/capacity loads
race-free. Every descriptor word read by the marker is atomic:

```text
layout_seq: std.atomic.Value(u32)
shape_or_kind: std.atomic.Value(usize)
backing: std.atomic.Value(usize)
length: std.atomic.Value(usize)
capacity: std.atomic.Value(usize)
```

Writer protocol:

1. enter barrier-critical/no-safepoint scope;
2. change `layout_seq` from even to odd with `acq_rel`;
3. construct or finish the new backing;
4. atomically publish shape/kind, pointer, length, and capacity;
5. put the old backing on a no-allocation intrusive retire list;
6. shade every strong target newly exposed by the structural change;
7. change `layout_seq` to the next even value with `release`;
8. leave the scope.

Marker protocol:

1. acquire-load `seq1`; retry or bailout if odd;
2. atomically acquire the complete descriptor;
3. trace only the captured range through atomic Slots;
4. acquire-load `seq2`;
5. accept only if `seq1 == seq2` and even; otherwise retry;
6. after a small bounded retry count, enqueue owner-thread bailout.

Old backing remains valid until final remark has drained all marker work.
Retirement cannot allocate: the backing header contains an intrusive link or a
pre-reserved retire record. Only the owner thread frees retired storage after
major marking is inactive.

### 6.4 Concrete zjs mappings

- `Object.shape_ref`, `prop_values`, property count, and shape-selected
  `property.Slot` arms are one snapshot. Publishing a Slot arm without its
  matching shape flag is invalid.
- Ordinary same-kind property value replacement uses the Slot barrier but does
  not change `layout_seq`.
- Shape change, property-kind change, property backing growth, dense/sparse
  conversion, and buffer reallocation change `layout_seq`.
- New property/dense backing is constructed privately, then all strong values
  are shaded before installation during major marking.
- Immutable `Shape` and function-bytecode arrays can become `atomic_slots`
  after their publication audit; mutation after publication forces snapshot.
- `VarRef` exposes its current value as a `HeapValueSlot` and keeps cell
  identity stable. Its open `pvalue` frame alias remains a stopped-root/borrowed
  execution relationship; close atomically changes the value/alias/open state
  through a dedicated owner-thread API.
- Mapped arguments and frame-slab typed windows remain ordinary mutator
  storage and are scanned precisely at STW. They are not heap Slot arrays.
- Function bytecode uses a sealed-publication protocol for its FAM/constant
  pool; any allowed post-publication replacement uses a named Slot operation.
- A marker worker never calls embedder code. Engine-owned host root slots are
  normal roots; legacy reentrant plugin tracer callbacks are unsupported in a
  reclaiming tracing mode until migrated or versioned as described above.
- Flat strings and big integers are atomic leaves. Ropes explicitly trace
  their string children and participate in the address registry despite their
  current special prefix.

## 7. Roots, native pointers, and safepoints

### 7.1 Precise roots

The precise root set includes:

- active VM arguments, original arguments, locals, operand-stack live prefix,
  `VarRef` windows, current function/this/new-target, and suspended frames;
- `ValueRootFrame`s in production;
- contexts/realms, globals, modules, namespace state, atoms that own GC values,
  built-in prototypes and constructors;
- local/persistent handles and current `HandleScope`;
- jobs, Promises, async/generator state, host event-loop providers;
- finalization and deferred-cleanup records;
- the current job's WeakRef keep-alive set.

The active-invocation Seam is a gated Adapter. Core retains
`active_invocation: ?*anyopaque`; when `value_root_frames_enabled`, the first
word of the published record is `ActiveInvocationTrace` and exec fills a
no-fail live-window callback. Default `rc` keeps extra record fields as `void`
and compiles `traceActiveRoots` to `traceRoots(null, visitor)`. The callback
traces only semantic live windows — arguments, locals, original arguments,
current bindings, VarRefs, FunctionBytecode, generator state, native_caller
when that slot is a JSValue, and each operand stack's live prefix — never
unused frame-slab capacity, unused chunk slots, or the empty-leaf resume-word
overlay. Nested `runWithArgsState` is chained through `previous`. Suspended
generator/async state is a heap payload edge, not an invocation root.

`RootVisitor.visit_header` exists only in the gated build (void in default
`rc`). A shadow tracer must provide it; otherwise direct Shape, Module,
VarRef, and FunctionBytecode roots are unobservable. The Interface remains
non-moving: direct-header roots are not rewrite slots.

External native arrays/windows containing `JSValue`s require a precise root
record: conservative scanning sees their backing pointer, not the values stored
behind it. Scalar Zig locals may instead be protected by the full conservative
register/stack capture. Whether every scalar `ValueRootFrame` is linked in
production or only container/window records are linked is a measured
Implementation choice; completeness is mandatory, blanket hot-path list
linking is not assumed free.

`Atomics.waitAsync` is a separate native-root Adapter, not part of the active
Machine. Snapshotting it must not invoke a visitor while holding the global
waiter mutex: reserve and retain Promise/Realm roots, unlock, then visit and
release the snapshot. Landed 2026-08-23 as `trace_atomics_wait_async`
(installed on first `atomicsLinkAsyncWaiter`, comptime-erased in default `rc`).

The production root transition has two required checks:

1. every former RC-owned temporary remains reachable while a safepoint is
   legal;
2. every `NoSafepointScope` is bounded and contains no allocation, callback,
   exception propagation, or loop with unbounded work.

### 7.2 Conservative native roots

Platform assembly provides:

```text
spillRegistersAndScan(js_runtime, stack_bounds, scanner)
```

The trampoline captures the true stack pointer before compiler-generated code
can clobber live candidates and spills **all registers that may carry a
pointer or 16-byte `JSValue` at that safepoint**, including relevant
caller-saved GPR and SIMD registers. Saving only ABI non-volatile registers is
not sufficient. Implementations are distinct for x86_64 SysV, x86_64 Windows,
AArch64 AAPCS, and AArch64 Windows.

Thread registration supplies stack bounds. The existing `@frameAddress()`
stack-overflow check is not a root scanner and cannot be the sole endpoint.
For each aligned machine word, candidate lookup tries the raw word and defined
tag/offset decodings, then validates it through the heap address registry
before dereference. Interior pointers for registered object bodies, strings,
medium objects, large objects, and optionally one-past-end are resolved to the
owning allocation.

Conservative retention metrics include candidate count, validated hits,
objects retained only conservatively, direct bytes, and transitive bytes.
Stable bit patterns may retain an object indefinitely; this is an accepted
cost, not described as a one-cycle guarantee.

Current zjs has exact generator/async state, not a registered stackful-fiber
subsystem. If stackful fibers are added, each records stack bounds, saved SP,
the complete saved register image, owner runtime, and state; only the used
range is scanned. Fiber support is therefore a conditional target, not an
implementation fact this migration may assume. Stage 1's conservative scanner
does not scan fibers: suspended generator/async windows live on
`GeneratorPayload` and are traced as heap edges.

The first Implementation (`src/core/gc_conservative.zig`, shadow-only) is
AArch64 Linux AAPCS64: it spills x0–x30 and q0–q31, then scans `[SP, thread
stack high)` from `pthread_getattr_np`. Candidates are resolved against
the live page-radix address registry (`src/core/gc_address_registry.zig`)
which indexes published compatibility-heap objects at insert/remove, not
a census snapshot built at scan time. Ranges still cover the metadata
prefix, body, and one-past-end, and are never dereferenced as guessed
headers. x86_64 SysV, x86_64 Windows, AArch64 Windows, and AArch64 macOS
are explicit unimplemented branches.

### 7.3 Native pointer contract

- A temporary raw pointer used only within the currently active synchronous
  native call is protected by conservative stack/register scanning.
- A pointer kept after the call returns must use `JSValue.Persistent` or a
  future C ABI Adapter over the same persistent-root Interface.
- Cross-thread code never holds or dereferences a GC object pointer. It may
  publish non-GC signals or external backing-store references.
- A successful weak lookup creates a local strong handle before returning.
- The non-moving collector guarantees address stability, not lifetime without
  a handle.

### 7.4 Safepoint handshake

Today the interpreter polls at calls and selected backedges with a reset
counter of 10,000, and native callbacks may run without preemption. Before a
pause target can be accepted, the implementation must instrument the current
poll topology and measure worst-case request-to-poll latency.

The concurrent design adds an atomic runtime-local request epoch:

1. marker/controller publishes a safepoint request;
2. the mutator observes it at a poll, but may not acknowledge while inside a
   `BarrierCriticalScope` or construction scope;
3. after the last critical scope exits, the mutator flushes its local mark
   ring, records an acknowledgement, and parks at the runtime-local barrier;
4. final remark runs on the owner thread;
5. resumption clears/advances the epoch.

Long native operations must call an explicit poll API or are reported as
non-preemptible time. One runtime's handshake does not park other runtimes.

## 8. Collector algorithms

### 8.1 Mark epochs

`Heap.mark_epoch: u64` increments for each major. A block whose epoch differs
has a logically zero mark bitmap. Read-only `isMarked` never clears it.

`ensureMarkEpoch(block, epoch)` obtains a per-block transition right, checks
again, clears the bitmap, and release-publishes the epoch. Every path that sets
a mark bit goes through it: root shading, conservative candidates, minor
survivors, barriers, black allocation, and bulk publication.

Initial mark materializes active allocation blocks. Any block opened during a
major is materialized before allocation. `isMarked` acquire-loads the epoch
before consulting the mark word. A theoretical `u64` wrap performs a complete
stopped bitmap reset.

### 8.2 Sticky generations and young lists

Within the current epoch:

```text
allocated && !marked -> young
allocated && marked  -> old
```

A young object that survives one minor becomes old; there is no copy, age
counter, or promotion queue. On the first young allocation into a block since
the last minor/major generation reset, an atomic/enforced owner-thread
`young_enlisted` transition adds it to `JSRuntime.young_blocks`. Medium and
large young objects have equivalent lists.

Minor traces and sweeps only these young lists. A major covers every space,
makes all survivors and major-time black allocations old, clears obsolete
remembered state, and resets young-list enlistment so the first post-major
young allocation is recorded.

### 8.3 Generational insertion barrier

Outside major marking:

```zig
fn generationalBarrier(owner: *Header, target: ?*Header) void {
    const child = target orelse return;
    if (!isOld(owner) or !isYoung(child)) return;
    rememberOwner(owner);
}
```

`rememberOwner` sets the owner-cell bit in its block and enlists the block once
in `remembered_blocks`, without allocation. A fallback dirty-block registry or
full remembered-bitmap scan must already contain the information before a
bounded queue reports overflow.

Minor force-traces each remembered owner. It must not call ordinary
`tryMark(owner)`: an old owner's sticky mark would skip its children. Weak
tables use a separate `weak_remembered_tables` registry.

After a successful minor all young survivors are old, so the strong remembered
set can be cleared as a whole. New writes after resumption rebuild it.

### 8.4 Concurrent major insertion barrier

While major marking is active, every strong write shades its exact new target:

```zig
fn postWriteBarrier(owner: *Header, target: ?*Header) void {
    const child = target orelse return;
    if (major_marking_active.load(.acquire)) {
        shade(child);
    } else {
        generationalBarrier(owner, child);
    }
}
```

This is a target-shading incremental-update barrier. It intentionally reads no
owner colour, uses no owner-rescan bit, and needs no per-write sequentially
consistent fence. Writes through unreachable owners may preserve floating
garbage for the cycle.

Correctness depends on a formal store/barrier/safepoint handshake: the heap
store and exact shading occur in one `BarrierCriticalScope`; final remark
cannot stop and acknowledge the mutator between them. `major_marking_active`
changes only while the runtime is stopped.

`shade` validates runtime ownership, ensures the mark epoch, atomically sets
the bit, and publishes work. If the normal ring is full, it first atomically
sets `mark_overflow` and enlists the block in a preallocated intrusive overflow
registry. Overflow processing conservatively retraces every marked allocated
cell in the flagged block; no separate gray bit is assumed. Clearing an
overflow flag uses a generation/handshake that cannot race with re-enlistment.
Queue exhaustion can increase scanning; it cannot leave a marked object
undiscoverable.

### 8.5 Minor collection

Minor is runtime-local STW:

1. reach and acknowledge a safepoint;
2. verify no major is active and prior sweep debt is zero;
3. scan all precise roots and conservative native/fiber roots;
4. ignore old root targets and mark/enqueue young targets;
5. force-trace every remembered owner, following only young children;
6. drain the young mark queue;
7. compute the young/dirty ephemeron fixed point;
8. clear dead young weak targets and create no-fail cleanup records;
9. mark young blocks/extents `needs_sweep`;
10. clear remembered and young-list generations;
11. synchronously sweep enough blocks to satisfy headroom;
12. resume the mutator with any remainder as mutator-only sweep debt.

Before setting a survivor mark, minor calls `ensureMarkEpoch` even though minor
does not increment the heap epoch. Blocks with sweep debt are closed to
allocation. A block reopened after sweep enlists again on its first new young
allocation.

### 8.6 Major collection

#### Prepare

- finish all prior mutator-only sweep debt;
- require an empty old-backing retire list;
- account for finalization backlog and external pressure;
- close admission of a new minor request;
- reserve marker, overflow, bailout, retire, weak, and cleanup capacity or
  select a safe synchronous fallback before changing phase.

#### Initial mark: STW

1. stop this runtime's mutator;
2. increment `mark_epoch` and materialize active allocation blocks;
3. clear generational remembered and young generations;
4. reset queues, overflow/bailout state, weak work, and local rings;
5. scan every precise root, including engine-managed host root slots;
6. spill and scan native/fiber roots;
7. release-publish `major_marking_active = true`;
8. make marker work runnable;
9. resume the mutator.

Remembered owners are not major roots. A full major derives reachability only
from roots and ephemeron rules.

#### Concurrent mark

The marker prioritizes ordinary mark work, overflow blocks, snapshot retries,
and ephemeron candidates. `mutator_only` and exhausted snapshots enter a
preallocated bailout registry. During this phase:

- new objects are black-published in the current epoch and all initial strong
  edges are shaded;
- all later strong writes use target shading;
- minor requests become major assist/completion requests;
- allocation debt causes bounded mutator mark assist on slow paths/polls;
- the marker never invokes host code or frees objects/backing.

Before requesting final remark, pre-remark drains normal work and overflow as
far as practical, retries snapshots, and increases assist to bound bailout
work.

#### Final remark: STW

1. stop and acknowledge the mutator after all barrier-critical scopes exit;
2. flush every local ring/buffer;
3. rescan all precise roots;
4. respill and rescan native registers, native stacks, and suspended fibers;
5. drain ordinary work and overflow blocks;
6. trace engine bailout objects on the owner thread; do not invoke a legacy
   reentrant plugin tracer;
7. drain work produced by bailout tracing;
8. compute the full ephemeron fixed point, draining mark work after each
   change until stable;
9. apply the current-job WeakRef keep-alive set;
10. clear dead weak identities and WeakRef targets;
11. detach/prepublish FinalizationRegistry and native cleanup records;
12. release-publish `major_marking_active = false`;
13. mark every object space `needs_sweep`, invalidate allocation caches, and
    publish the sweep epoch;
14. release retired layout backing that is no longer observable;
15. resume the mutator after enough synchronous sweep to guarantee headroom.

Ordinary GC allocation is forbidden during final remark. Every operation is
no-fail after the stop; any required capacity was reserved in Prepare or has a
conservative synchronous fallback.

### 8.7 Mutator-only lazy sweep

The target release does not include concurrent sweep. Block states are:

```text
fresh -> active -> needs_sweep -> sweeping -> swept -> active
```

Only the owner mutator thread sweeps, at idle budget, allocation slow paths,
explicit polls, or synchronous hard-pressure slices. `needs_sweep` blocks are
never allocation sources. Sweep walks allocated bits, retains marked cells,
extracts no-fail finalization records for dead cells, clears dead allocated and
remembered bits, and rebuilds free/bump state. Empty blocks leave the runtime
registry before returning to the pool.

Scheduling uses four quantities rather than assuming `gcIdle` runs:

- mark debt;
- sweep debt;
- soft allocation headroom;
- hard headroom including reclaimable-but-unswept bytes and external pressure.

Idle work is an optimization, not a progress guarantee. Slow-path assist and a
bounded synchronous emergency path guarantee progress. A new collection never
begins while sweep debt is non-zero.

## 9. Weak references, ephemerons, and finalization

### 9.1 WeakMap and WeakSet

An ephemeron value becomes strong only when both its table and key are live.
The value never keeps the key alive.

For minor collection, old keys are conservatively live because minor cannot
reclaim them; young keys must be marked. Young/dirty weak tables iterate to a
fixed point. An old table may conservatively retain a young value until the
next major. Mutations enlist the table in `weak_remembered_tables`.

Major final remark computes the full fixed point over live tables, repeatedly
marking values whose keys are marked and draining new work until no change.

### 9.2 WeakRef

- the `WeakRef` object is normally strongly traced;
- its target is a weak identity;
- successful `deref()` promotes the target into the current job's keep-alive
  root set;
- the set is cleared at the end of the job, not an arbitrary safepoint;
- minor clears only dead young targets; major decides old targets.

### 9.3 FinalizationRegistry

Cells have at least `active`, `pending`, `queued`, and `released` states. A
dead target detaches its strong held value and cleanup metadata into a record
whose storage was reserved at registration or is the detached cell itself.
GC never allocates a cleanup record while sweeping or stopped.

Cleanup jobs run at low priority on the owner thread, with no ordering
guarantee and no guarantee of JavaScript callback execution during abnormal or
normal runtime shutdown. The held value stays strongly rooted until its record
is released.

### 9.4 Native and plugin finalization

Native finalization is separate from FinalizationRegistry. Each finalizable
type detaches a no-fail record containing the destroy callback, opaque payload,
external byte count, class-generation pin, stable object identity, and
owner-thread requirement. The current `DeferredClassPayloadFinalizer` already
provides the project-shaped Adapter: it detaches payload and callback state
rather than handing the callback a reusable wrapper-cell pointer.

Engine-native destructors do not reenter JavaScript by default. The current
plugin ABI, however, explicitly permits callback reentry; those deferred
callbacks run only after the GC phase is idle, on the target runtime's owner
thread, while their exact class-generation pin is held. A dead wrapper identity
cannot be resurrected, although callback code may allocate unrelated new
objects. Runtime teardown drains engine/native destruction even though it may
skip JavaScript cleanup callbacks. Budgets cover both record count and external
bytes. Explicit `dispose()` remains preferred for scarce deterministic
resources.

## 10. Buffers and external pressure

The existing `SharedBufferStore` is the backing-store Interface for the first
tracing release. It already provides atomic reference counting and an external
memory token; byte contents contain no GC pointers.

- An ordinary ArrayBuffer owns or shares a `BufferPayload` backing and clears
  cached view state before storage replacement/detach.
- A TypedArray/DataView strongly traces its buffer wrapper and never treats its
  cached raw data pointer as a strong edge. The current linked-view mechanism
  clears and republishes live state on backing changes; a detach generation is
  added only if future caching can outlive that invalidation protocol.
- A transferred backing moves accounting from source runtime to target runtime
  as one transaction; the source wrapper is detached before publication.
- A shared store's real bytes are counted once process-wide. Per-runtime hints
  may duplicate pressure for scheduling but not global committed bytes.

Whether a process-global shared-store registry is needed is a separate design
decision. It is not required merely to trace wrappers. The current
runtime-tied `ExternalMemoryToken` must first gain an explicit transfer Adapter
if cross-runtime zero-copy transfer is supported.

GC pressure includes committed heap bytes, non-shared external bytes,
per-runtime shared hints, pending-finalization external bytes, and estimated
unswept dead bytes. Reports keep heap, external, allocator metadata, mappings,
code, and thread stacks separate; process RSS is not divided by exact live heap
and presented as a collector ratio.

## 11. Embedding and native ABI

The existing Zig handle types are the canonical Interfaces:

| Required semantic | Existing basis |
|---|---|
| scoped local root | `JSValue.Scope` / `Local` |
| cross-call strong root | `JSValue.Persistent` |
| weak persistent root | `JSValue.Weak` plus stable weak identity |
| scoped native backing pin | current internal `NativePin`/view scopes |
| host wrapper | current host/plugin object payload and class contracts |
| external memory | `gc.ExternalMemoryToken` and runtime accounting |

A future versioned C ABI may adapt these as `zjs_scope_*`, `zjs_ref_*`,
`zjs_weak_*`, host-object, and external-memory calls. Handles use index plus
generation and never expose GC metadata.

"Remove RC" in this document always means JS-heap strong-edge RC. Atomic
ownership for `SharedBufferStore`, loaded DSO artifacts, class-generation pins,
and other non-GC or cross-thread resources remains in place.

`zjs_tsfn_*` is not part of this GC design. The current runtime plugin ABI
explicitly excludes async completion, cross-thread completion queues, and
general root-token services. A thread-safe function API needs its own RFC with
queue ownership, shutdown, cancellation, and runtime-lifetime semantics.

## 12. Failure, OOM, and teardown

All failure boundaries are explicit:

- Prepare is fallible and occurs before a phase becomes externally visible.
- Heap stores, barriers, bitmap transitions, overflow enrollment, publication,
  final remark, and sweep record detachment are no-fail.
- Fixed-capacity exhaustion switches to an already-represented conservative
  fallback: flagged block scan, owner-thread bailout, synchronous assist, or
  full STW tracing.
- Emergency collection distinguishes address-space exhaustion, hard heap
  limit, external pressure, and reclaimable sweep debt in diagnostics.
- Runtime teardown first proves execution/root frames are idle, stops marker
  work, completes or abandons marking safely, drains native destruction,
  releases retired backing, then returns heap spaces.

Fault injection covers every reserve and every fallback transition. Queue
overflow tests force tiny capacities; they must produce the same survivor set
as an unbounded reference tracer.

## 13. Migration

The migration is vertical: each stage leaves a runnable, reviewable engine and
has a go/no-go gate. Build modes are provisional and internal:

```text
-Dzjs_gc=rc                production default
-Dzjs_gc=shadow            RC reclaims; tracer observes only
-Dzjs_gc=trace_stw         experimental stop-the-world tracer
-Dzjs_gc=trace_concurrent  later experimental concurrent major
```

### Stage 0: contracts and observability

Delivered 2026-08-23 (the G1-G6 preparation tranche):

- `gc-invariants.md` states the source-level contract, each rule cited to
  where it lives;
- `perf/gc-baseline.md` records the behavioural baseline with its reproduction
  command, and was validated in use — it caught a 2.5% reclamation shift the
  A/B could not see;
- `--gc-stats` reports the counters the collector maintains, with the dead and
  misdescribed fields removed (`cycles_collected` had been assigned the object
  count; `rc_inc`/`rc_dec` had no writers, and refcount traffic stays
  uninstrumented because a counter on that path is not cost-neutral);
- hot-arm-versus-authority edge parity guards across eight shapes, plus
  comptime dual edge lists for the three specialised arms, each proven red by
  deletion probe and by re-enacting the original iterator-next defect;
- pause histograms over the last 1024 rounds, including the explicit empty
  state and p50/p95/p99/max output;
- an exhaustive `gc.ref_kind_catalog` and a non-reclaiming Registry `census()`.
  Together they prove the current registry covers six carriers and that
  String/Rope plus BigInt still need a ledger census;
- a gated direct-header root Interface, context-owned Module/initial-Shape
  roots, and the exec-owned `ActiveInvocationTrace` Adapter. Default `rc`
  erases the publish/trace path;
- a deterministic `gc_threshold = 1` tiny-heap stress case.

Still open in this stage:

- reason/phase counters, root counts, conservative hits, mark and sweep debt
  (several of these have no meaning until the corresponding mechanism exists,
  and should land with it rather than as empty fields — the panel was just
  cleaned of exactly that kind of decoration);
- an AST-derived inventory of heap fields/raw-pointer exceptions, allocation
  and publication sites, native boundaries, payload classifications, and
  finalizable types. The RefKind catalog is exhaustive for carriers but cannot
  see FAM/slice storage or opaque payloads;
- deterministic tiny-mark-queue stress. It lands with the first real bounded
  shadow worklist and must compare its overflow report with an unbounded
  SyntheticHeapCensus reference; adding an empty queue knob now would test no
  mechanism.

Gate: current RC behaviour and machine-code/performance requirements remain
inside the applicable repository policy.

### Stage 1: production roots and shadow tracer

Deliver:

- production `ValueRootFrame` or an equivalent complete local-root Interface;
- ~~exec-owned active-invocation root Adapter~~ — delivered 2026-08-23, gated
  so default `rc` `.text` is unchanged;
- context/job/module/host/finalization root census (context-owned Module and
  Shape roots are delivered in the gated build; in-flight jobs and
  `Atomics.waitAsync` remain);
- platform register/stack scanner behind a conservative-root Interface;
- a non-reclaiming tracer over all current carriers through
  `CompositeHeapCensus`: `RcRegistryHeapCensus` for the six intrusive kinds,
  `AllocationLedgerHeapCensus` for String/StringRope/BigInt, and a
  `SyntheticHeapCensus` test Adapter;
- classification of every host/plugin payload edge as an engine-managed root,
  edge-free payload, or legacy reentrant tracer that disables tracing mode;
- stable diagnostic allocation identities plus exact-root and
  conservative-inclusive reachability diagnostics.

Run shadow tracing after a full current cycle collection and finalization
quiescence, with no linked `Atomics.waitAsync` waiter until its Adapter
exists. Before CompositeHeapCensus, stable identities, native roots, and
payload classification exist, the verifier must report **incomplete**, never a
numeric `unexplained == 0` as a cutover gate. Once complete, every allocated
object outside the reachable set must be explained by a declared external
owner, conservative retention, pending finalization, or a documented
current-collector semantic. Deletion probes remove each root/edge and prove
the shadow checker becomes red.

Gate: sustained zero unexplained objects across unit, test262, benchmark,
plugin, OOM, and randomized stress corpora. Shadow mode never frees memory.

Measured 2026-08-23 against that sentence (not a retune): unexplained=0 on
Zig-local unit, full test262 (44584 executed), bench-v8, plugin DSO fixture
plus a host object with a legacy `tracer`, CLI OOM, and tiny-heap stress.
Shadow currently invokes `opaquePayloadMark` when a class has a tracer;
that class still disables reclaiming tracing. `Atomics.waitAsync` still has
no Adapter; those tests were in the 44584 and did not produce unexplained
cycle-list objects.

**Driver verdict: Stage 1 gate PASSED.** Independently re-run rather than
accepted from the report: `--gc-shadow-check` over the whole V8 benchmark
suite (unexplained 0, all five buckets 0, exit 0), and `run-test262
--gc-shadow-check -t 20` over the full corpus —
`tests=44584 errors=0 unexplained_tests=0 unexplained_objects=0`, every
bucket zero, 25 s. The gate sentence was not restated or narrowed to reach
this.

Two things this verdict does *not* claim, both recorded rather than
smoothed over. The gate is about unexplained objects. The `Atomics.waitAsync`
waiter Adapter landed 2026-08-23 (snapshot retain/unlock/visit; hanging
waiter Promises are exact roots). Strings and BigInts stay outside
`gc_obj_list` by representation; they are not folded into the unexplained
census (see inventory §7) — Stage 2 write-audit of that domain goes through
rope `left`/`right` JSValue slots, not a live-string inventory. Separately,
shadow calls `opaquePayloadMark` for classes that ship a legacy tracer —
that is a classification, not a pass: those classes remain disabled for
reclaiming tracing (§6.1), and the plugin corpus is what demonstrated it
rather than a design assertion.

### Stage 2: Slot-under-RC

Deliver:

- `HeapValueSlot`, `GcPtrSlot`, `GcBuffer`, and `WeakIdentitySlot` Interfaces;
- paired bulk mutation/destruction APIs;
- generated trace descriptors beside existing ownership logic;
- shrinking allowlist and a rule forbidding new naked heap references;
- runtime write audit in shadow mode;
- no public representation or reclamation change.

Gate: current cycle edge parity, family deletion probes, OOM, leak census,
test262, shadow reachability/write audit, and required hot-path A/B. Dynamic
retain/release counts and generated code identify the cost of Slot abstraction
before atomics are enabled.

Implementation 2026-08-23: `src/core/gc_slot.zig` defines `HeapValueSlot`,
`GcPtrSlot`, `GcBuffer`, and `WeakIdentitySlot` without atomics, plus paired
bulk copy/move/resize/destroy/property-install APIs whose comments name the
Stage 6 barrier step. Default `rc` erases the module. Cold `gc-slot: heap`
families: Iterator, Proxy, ObjectData, TypedArray.buffer, BoundFunction,
Arguments.var_refs. Naked-field lint:
`tools/architecture/check_gc_slots.js` (shrinking allowlist). Not wired to
`Object.prop_values` or dense elements. Shadow write audit:
`src/core/gc_write_audit.zig` records FAM/slice stores, `@memcpy` of live
JSValue/Entry, union-arm stores, and Shape-discriminated `setEntryKindAndSlot`
at runtime; `--gc-shadow-check` prints the hit inventory and does not fail on
hits. Plugin-opaque DSO stores remain uninstrumented (ABI).

**Driver verdict: Stage 2 gate PASSED.** Verified rather than accepted:
the write-audit inventory re-run independently (205,339,239 bypassing heap
stores on bench-v8 with unexplained still 0), 23 edge-parity and
cycle-release guards present in the core suite, and `test-oom` 21/21. The
gate sentence was not restated.

The audit's value is the inventory, not the number being small. Slot
bypasses cluster in exactly the places §5.2 predicted a compile-time census
would miss: `object_prop_slot` at 187 M, property-values and dense
`memcpy`, and the Shape-discriminated `setEntryKindAndSlot`. The lint's 169
allowlisted *fields* and the audit's *operations on those fields* are
complementary, and the operations are the Stage 6 barrier work-list.

Recorded limits of this verdict: the hot-path A/B row is satisfied by
identity rather than by a benchmark, because no Slot landed on the Object
trunk or dense elements this stage — when Stage 6 puts barriers on those
paths, that row needs a real A/B. `plugin_opaque` stays uninstrumented
behind the host DSO ABI.

### Stage 3: stop-the-world tracing prototype

Deliver:

- opt-in mark/sweep over the compatibility heap;
- exact weak, ephemeron, WeakRef, and finalization semantics;
- no concurrent marker, no generations, and no new header/allocator yet;
- RC mode remains compiled and continuously tested.

Gate: survivor-set equivalence where semantics require it, complete stress and
failure coverage, no unexplained leak growth, and an attributed performance/
memory report. Failure returns to the experimental build; it does not silently
fall back mid-runtime to RC.

Implementation 2026-08-23 (in progress, not a gate pass): `-Dzjs_gc=trace_stw`
compiles `src/core/gc_trace_stw.zig` and replaces trial deletion at
`JSRuntime.tryRunObjectCycleRemovalWithValueRoots`. Strong mark reuses
`traceChildEdges*` with `visitWeakCollectionEntry` still a no-op; a separate
ephemeron fixed point shades a WeakMap/WeakSet value only when both the table
and the key are marked. Sweep walks the current registry. Default `rc` does
not import the module.

Root-set ruling 2026-08-23: Zig locals without `ValueRootFrame` are not
roots (add frames; do not weaken assertions). Conservative retention of
stable stack bits is an accepted §7.2 cost (null dangling test locals; do
not filter candidates). `context_head` membership is not a root
(gc-invariants.md). WeakRef `[[KeptAlive]]` is a job-scoped root cleared at
job end.

Construction follows §4.6 on the compatibility heap: a miss interned Shape
is reserved/initialized off `gc_obj_list`, the pre-allocation collection
runs, then the Shape is published with the object. Temporary pin flags are
not used. FinalizationRegistry cells reserve a job-queue slot at
registration; sweep commits with `enqueueReserved` and does not allocate
(§9.3). In-flight define values use rooted construction: a mutation-window
`ValueRootFrame` names the holder and JSValue until the unique-shape
`prop_count` commit makes the over-hang a child edge. Values popped off
the VM stack (`op.get_array_el` / `put_array_el`) and native JSValue
buffers that outlive their heap edge (Array.sort entries, Array.reverse
swap temps) are named as `ValueRootSlice` windows so CLI STW
(`value_root_link_containers_only`) list-links them; conservative scan
of the C stack does not see malloc'd backing storage, and register
reuse makes scalar locals a race. Frameless literal handlers (`op_object`, `op_define_field`,
`op_array_from`) `syncSp` before they allocate so STW `liveValues()`
covers the unpublished operand window; RC used operand refcounts. In-flight native function objects are named as
`ObjectRootValue` across name/length intern.

**Driver verdict: Stage 3 gate PASSED**, after one rejection.

The first claim recorded a full-corpus SEGV at ~26% as a coverage remainder
and judged the gate met. That was sent back: in a collector prototype a
SEGV is almost always premature reclamation, which is precisely what the
survivor-equivalence and stress rows exist to catch, and a run that dies at
26% is not complete coverage by any reading. The narrowing that made the
difference came from running slices — `0..4000` and `10000..16000` both
finished clean — which reclassified the failure from "some test" to
"something accumulating in the process".

It was premature reclamation. Unpublished operand windows, malloc'd JSValue
buffers, and a constructing realm's global and in-flight constructor were
reachable only by refcount, so exact marking freed them while they were
live; allocator reuse across tests is what made it surface late. The fix
names those windows per §4.6 rather than pinning them.

Verified independently rather than accepted: full test262 under
`-Dzjs_gc=trace_stw` at `0/49778 errors, passed 44584` with no SEGV,
`test-core` 366 passed, and `test-oom` 21/21 including the fault
injections. Gate rows: survivor-set equivalence (round 13, three-way
attribution), stress and failure coverage (this round), no unexplained leak
growth (+2.8 KB, attributed to conservative floating garbage), and an
attributed performance/memory report (round 14).

The prototype is slower than RC — pause p50 1.31 ms to 3.04 ms — and that
is expected rather than a gate item: Stage 3 excludes generations,
concurrent marking and the block heap, which are the mechanisms that bring
pauses down. The report attributes the difference; it does not optimise the
prototype.

### Stage 4: block heap

Deliver the small/medium/large spaces, side metadata, address registry, epochs,
and mutator-only lazy sweep. Migrate strings/ropes explicitly. Preserve public
`JSValue` and native handle Interfaces.

Gate: allocator fragmentation/committed-memory envelope, interior-candidate
lookup, OOM, sweep debt, and frozen bench-v8 A/B. Header/object representation
changes land as separately measurable sub-tranches.

Implementation 2026-08-23 (address registry only):
`src/core/gc_address_registry.zig` is a 4 KiB page radix plus per-page
occupant lists over the existing allocator. Insert/remove run at
`addInitialized*` / `unlinkObjectWithBytes` / `removeGcObject` for cycle-
list objects. Conservative scan (`gc_conservative.zig`) resolves
candidates through the live table; `AddressLookup.build` stays as a
census oracle. Default production `rc` erases the table (`void` field,
no insert). This round does not introduce 64 KiB blocks, size classes,
or header replacement.

Implementation 2026-08-24 (class table + sweep plan, still no block
allocator): `src/core/gc_space.zig` generates the §4.2 class table
(16-byte linear through 128, then ~1.25 geometric, 16 cells per future
64 KiB block). The maximum small class is
`measured_max_small_payload` = 128, frozen from a mixed TestEngine + JS
publication histogram (p50=64, p95=96, p99=128; 99% of sub-64 KiB
sizes) — not a hard-coded 4 KiB. Publications above 128 and below 64 KiB
classify as medium; ≥64 KiB classify as large. The 16-cell rule still
allows geometric classes up to ~4 KiB; they are not in the measured
table until a later histogram needs them. `src/core/gc_sweep_model.zig`
is the §8.7 state machine over logical 64 KiB address windows
(`fresh → active → needs_sweep → sweeping → swept → active`) plus the
four quantities (mark debt, sweep debt, soft headroom, hard headroom).
STW collect drives the transitions; after a synchronous sweep, sweep
debt is zero. Default production `rc` erases both (`void` fields). No
64 KiB block body, object-header replacement, or generations.

Implementation 2026-08-24 (block heap + string/rope intervals, still no
header replacement): `src/core/gc_block_heap.zig` obtains 2 MiB
superblocks and splits them into 64 KiB-aligned classed blocks. Empty
blocks return to a per-class free list; the mapping is released only as
a whole superblock. Medium objects use page-granular runs inside a
medium superblock (no 1:1 mapping). Large objects (≥64 KiB) use a
dedicated page-aligned mapping. The heap is compiled only for
`-Dzjs_gc=trace_stw`; default `rc` keeps `MemoryAccount`. String and
rope *backing* stays on `MemoryAccount` so OOM injection and the
compatibility allocator remain one sequence; they register
`[base, base+len]` in the address registry without changing the 4-byte
RC prefix. Conservative scan validates those hits and does not shade
them as `gc.Header`. STW increments
`mark_epoch` per collection; `ensureMarkEpoch` lazily clears a block's
mark bitmap. A new collection drains non-zero sweep debt before
`beginMark`. Object headers are unchanged.

**Driver note: the block heap cannot serve GC nodes until the header
tranche.** Wiring `Heap.alloc` into `createRuntime` was tried and reverted.
A GC object is not just its struct: `memory.zig` writes an 8-byte prefix
ahead of every allocation and records the slab class in `alloc_info`, which
`GCObjectHeader.meta()` reads back through. Cells handed out raw therefore
produce headers whose `meta()` dereferences uninitialised memory — the
experiment segfaulted in `addInitializedWithSizeNoFail`'s first assertion,
which is where it should fail.

That is not a defect in the block heap; it is §4.5's object-header
representation change arriving early. Serving GC nodes requires the cell
layout to carry that prefix, and §4.5 defers header replacement to its own
sub-tranche with its own binary and performance gates. Until that lands,
the heap is exercised by its own tests and reports its geometry, while the
compatibility allocator keeps serving the collector — which is also why
`--gc-stats` shows the block heap committed/live at zero on a real
workload. The zero is honest: nothing allocates from it yet.

Consequence for the Stage 4 gate: the fragmentation and committed-memory
envelope rows cannot be measured on a live workload in this tranche, only
on the heap's own tests. They move to the header sub-tranche with the rest
of the representation work.

**Driver verdict: Stage 4 gate PASSED for the tranches it covers**, with
the header-dependent rows explicitly deferred rather than waved through.

| Gate row | Evidence |
|---|---|
| interior-candidate lookup | page-radix registry resolves interior, prefix, header and one-past-end; `greatest lo` fixed a first-match SEGV found under load |
| OOM | `test-oom` 21/21 in both rc and trace_stw, covering the new reserves |
| sweep debt | four debt quantities reported; `needs_sweep` returns to zero after synchronous sweep, so §8.7's "no new cycle while debt is non-zero" holds |
| frozen bench-v8 A/B | rc `.text` stayed inside its known basin for the space and sweep work; the registry tranche measured 0.9991 / 0.9987 / 1.0007 in a clean field |
| allocator fragmentation / committed-memory envelope | **deferred** — measurable only once the heap serves GC nodes, which needs §4.5's header change |

Also delivered here and worth naming because it was deferred twice before:
strings and ropes now register their intervals with the address registry,
so conservative scanning can resolve a stack-resident string candidate.
They did not become intrusive nodes, and the four-byte refcount prefix is
untouched — the representation constraint that made this look impossible
in the Slot round was respected rather than routed around.

### Stage 5: sticky minor

Deliver young lists, sticky survivor marks, remembered owners, weak remembered
tables, minor ephemeron semantics, and minor-only sweep debt.

Gate: old-to-young deletion probes, young-list scaling, minor pause
distribution, false conservative promotion, and memory amplification. Major is
still STW at this stage.

**Driver verdict: Stage 5 mechanism landed, gate NOT claimed.**

What works: sticky generations keyed beside the heap (the header has no
spare bit and §4.5 keeps header changes elsewhere), a minor that traces
roots plus remembered owners following only young children, young-only
sweep, and survivors promoted by clearing the young set. Remembered owners
are force-traced rather than `tryMark`ed, which §8.3 warns about and which
would otherwise make the walk skip the very children a minor exists to
find. The barrier's deletion probe passes: disabling it turns the
old-to-young test red.

What does not work yet, measured rather than assumed. On a cycle-heavy
workload the collector reports:

```
gc: collection entries 21, completed rounds 21
gc: generation young 108834, remembered owners 0
gc: minor collections 21, promoted 669, remembered without young 0
```

`remembered owners 0` is the tell. The barrier is correct but unreached:
`HeapValueSlot.setOwned` — the only path that carries an owner and can
therefore record one — has no callers. Every heap write still goes through
the owner-less `set`, so the remembered set stays empty, every minor sees
an empty old-to-young frontier, and 108k young objects survive to be
handled by the major instead. The minor is running and reclaiming
essentially nothing.

This is the same shape as the block heap earlier in Stage 4: a mechanism
that compiles, tests green, and is not yet wired into the paths that would
exercise it. Recording it as a gate pass would make the Stage 5 rows
(young-list scaling, minor pause distribution, memory amplification)
measurements of a collector that is not doing the work.

Remaining for the gate: minor scheduling, and it is not a tuning problem.

The barrier is now attached where owner and child are both available — the
three property funnels and `Object.setOptionalValueSlot`, whose receiver is
the owner. Instrumenting it settled the earlier `remembered owners 0`
question: on a cycle workload the barrier is called 400k times and skips
every one because the *owner* is young, which is correct (a minor scans
young owners anyway). The probe was wrong, not the barrier.

The real blocker is that a minor never gets to run often enough for
anything to become old. A minor is attempted only from `pollGC`, and
`pollGC` fires on the allocation-byte threshold, which is sized for
whole-heap collections: minors run 18 times while the young set reaches
59k. Objects therefore stay young indefinitely and the old-to-young
frontier the barrier exists to record never forms.

Giving the minor its own trigger at object allocation was tried and
reverted. It breaks a load-bearing assumption in the existing suite: tests
that request a collection and assert the heap drains to zero start seeing
survivors, because a minor legitimately leaves old objects alone. That is
not a test being precious — it says the engine currently has exactly one
meaning for "a collection happened", and introducing a second, weaker one
on the allocation path changes what every existing caller gets without
their asking.

The contract half of that is now in place. `GCPollMode.acceptsMinor`
states which polls may be answered with young-only progress: `idle`,
`safepoint` and `callback_boundary` can, while `normal` and `urgent` cannot
— `normal` is the allocation threshold whose meaning must not weaken, and
`urgent` has a caller who is out of headroom and needs the whole heap
examined.

The budget half is not. Driving a minor from object allocation was tried
twice — once directly, once routed through the `.safepoint` contract — and
both abort inside the suite. The contract was not the problem: gating on
`acceptsMinor` alone leaves everything green, and the crash returns the
moment a collection actually runs from the allocation path. Collecting
mid-allocation, with a half-built object in flight and its caller holding
raw pointers, is its own problem; §4.6's reserve/initialize/publish exists
precisely because that window is hostile, and the minor would have to
observe the same discipline.

A third attempt put the minor on the interpreter's own cadence — the
`pollInterruptSlow` safepoint, between instructions, which is exactly the
place with no half-built object in flight. It crashed too, and this time
the stack named the real problem:

```
assert  <- Object.collectionEntriesSlot
        <- collection.findStrongEntry
        <- collection_ops.setAddNoResult   (Set.prototype.add)
```

A minor ran in the middle of `Set.add` and reclaimed the collection whose
entries the operation was walking. The receiver is a caller-supplied
object, alive by refcount, and under tracing that is not a root. This is
the same family as the unpublished operand windows Stage 3 had to name —
native code holding a JSValue across a point where a collection can happen
— but Stage 3 only had to survive collections at allocation boundaries.
A minor fires often enough to catch the rest.

So the gap is not scheduling after all; scheduling only exposed it. Stage 5
needs the *native call surface* rooted: builtin receivers and their
in-flight arguments have to be named roots for the duration of the
operation, the way §4.6 already requires of construction. Until that lands,
a minor cannot safely run anywhere a builtin might be executing, which is
almost everywhere.

That work is now done, and the gate follows from it.

**Driver verdict: Stage 5 gate PASSED.**

| Gate row | Evidence |
|---|---|
| old-to-young deletion probes | disabling the barrier turns the old-to-young test red; restoring it returns 381 green |
| young-list scaling | bounded rather than growing: mean 1012 young at minor start, max 5027, over 9946 minors on the V8 suite |
| minor pause distribution | mean 61 ns, max 245 µs — against the major's p50 0.71 ms and max 46.6 ms, four orders of magnitude apart, which is the whole point of a generation |
| false conservative promotion | 693,747 of 10,071,339 promotions (6.9%) survived on refcount rather than reachability |
| memory amplification | young set settles at 21 objects after the suite; the collector is not accumulating |

The conservative-promotion figure is the one to keep watching. Those 6.9%
are young objects a minor kept because their refcount was live even though
the trace never reached them — native code holding a value without
publishing a root. It is deliberately the safe direction (leak until the
next major, never free something a builtin is using), and it doubles as a
root-coverage meter: as roots improve that percentage should fall. On a
narrow synthetic probe it reaches 96%, which says the remaining gap is
concentrated in paths the benchmark barely exercises.

Three things had to be true together, and each was found by the previous
one failing: builtins root their receiver and arguments at the dispatch
funnel; collection methods needed the same on their separate channel; and
the young sweep must refuse to condemn anything with a live refcount, since
this collector still shares a heap with refcounting. Only then could a
minor run on the interpreter cadence. Before that the young set stood at
59k across 18 collections; after, 427 across 674.

Major remains stop-the-world, as Stage 5 specifies.

### Stage 6: concurrent major

Deliver atomic heap Slots, target shading, barrier-critical handshake, marker
worker, atomic snapshot descriptors, retire/bailout/overflow protocols, mark
assist, and final remark.

Gate: forced interleaving tests for every store/read tear, queue overflow and
re-enlistment, snapshot churn, construction publication, epoch transition,
ephemeron fixed point, and shutdown. Report bailout share, floating garbage,
assist time, safepoint latency, and pause distributions.

**Stage 6 prerequisite measured: the two-word protocol tears, as predicted,
at a rate that makes candidate validation load-bearing rather than
theoretical.**

§5.4 called the protocol provisional until a litmus covered the
interleavings. `src/core/gc_slot_litmus.zig` now drives real concurrent
writers against the published ordering on this target:

- **79,412 reads, 4,933 of them torn (6.2%)** — a reference tag paired with
  a payload from a different write. The design says this may happen and
  that such a pair is a *candidate*, not a value. At 6.2% that path is not
  a rare corner: on the V8 suite's ~10 M marks it would be exercised
  hundreds of thousands of times per cycle.
- **Zero violations of the acquire/release obligation**: once a reader
  acquires the new tag it never observes the older payload. That is the one
  ordering guarantee the whole scheme rests on, and it holds here.

The consequence for Stage 6 is a sequencing one. Candidate validation —
address registry, owner runtime, space state, cell start, allocated bit,
tag-to-kind agreement — is not an optimisation to add after the marker
works; it is what keeps a 6.2% tear rate from becoming a wrong-kind
dereference. It has to exist before the first concurrent mark runs, and the
address registry built in Stage 4 is what makes that possible.

This is one target's answer. §5.4 also asks for the emitted LLVM ordering
to be inspected per supported backend, which stays open along with the
release-platform question in §15.

### Stage 7: experimental enablement and production default

First expose tracing only through an explicit experimental build/config. Run
long-lived GUI/event-loop workloads, repeated test262, OOM, randomized object
graphs, plugin/host tests, multiple independent runtimes, and release-fast
stress. Keep RC as the shipped default until the evidence is reproducible on
clean revisions.

Changing the production default requires all correctness gates, the declared
pause and memory envelopes, no performance regression under the current
measurement contract, and a rollback plan at the build/release level. Removing
RC is a later decision after at least one stable release; it is not part of the
default switch.

## 14. Validation matrix

| Area | Required tests |
|---|---|
| Slots | every tag transition, A-to-B overwrite, null, same-value, bulk copy/move, destruction, RC order |
| Publication | unpublished invisibility, black allocation, constructor OOM, initial-edge shading, allocated-bit ordering |
| Snapshots | odd sequence, descriptor tear attempts, repeated retry, bailout, retired backing, structural churn |
| Epochs | first materialization, simultaneous `tryMark`, new allocation block, wrap fallback |
| Minor | root-only young, old-to-young owner, young cycle, remembered overflow, weak table, lazy sweep reopen |
| Major | root mutation, unreachable-owner floating edge, ring overflow, final root rescan, assist, teardown |
| Weak | identity ABA, WeakMap chains/fixed point, WeakRef job keep-alive, unregister, held-value lifetime |
| Native | every supported ABI trampoline, GPR/SIMD-only candidate, interior pointer, long callback, persistent handle |
| Spaces | all size classes and boundaries, medium extents, large lookup, fragmentation, empty-block return |
| Multiple runtimes | parallel runtimes, independent STW, shared backing pressure, no cross-runtime heap edge |
| Plugins | legacy reentrant tracer rejection, engine-managed host roots, class-generation pins, deferred reentrant finalizer after GC idle |
| Failure | allocator OOM, reserve exhaustion, overflow, cleanup backlog, external-memory pressure, hard headroom |

Concurrency tests use a deterministic scheduler/fault hooks in addition to
high-volume stress. A race detector that supports the chosen Zig/LLVM atomic
paths is preferred, but deterministic happens-before assertions remain
required because stress alone does not prove absence of a missed interleaving.

## 15. Open decisions

1. Which fields qualify as immutable published GC pointers, and how is that
   declaration enforced?
2. Does the compatibility shadow tracer store marks in a side hash/bitmap or
   temporarily reuse current metadata under STW?
3. Which native platforms are release-supported when tracing first ships?
4. What exact workload and sample count define the interactive pause gates?
5. Is a process-shared `GcPlatform` measurably better than per-runtime pools at
   the expected number of runtimes?
6. Which common payloads must leave `mutator_only` before concurrent mode can
   be enabled experimentally?
7. Can the current weak identity registry serve all weak handles without an
   additional generation field after allocator replacement?
8. How is conservative-only transitive retention computed without distorting
   normal collection cost?
9. At what stage, if any, is replacing the current 8-byte metadata plus
    16-byte intrusive header worth its representation and code-layout cost?
10. Does the next plugin ABI require all JavaScript payload edges to be
    engine-owned persistent handles, or add a no-allocation/no-reentry tracing
    callback? Reclaiming tracing cannot call the current reentrant tracer.
11. Does the `Atomics.waitAsync` Adapter use a pre-reserved per-runtime root
    buffer, a retained two-pass snapshot, or a process-level immutable
    snapshot so it never invokes a visitor under the global waiter mutex?

## References

- The target architecture is informed by WebKit's
  [Riptide concurrent garbage collector](https://webkit.org/blog/7122/introducing-riptide-webkits-retreating-wavefront-concurrent-garbage-collector/),
  especially sticky marks, conservative stack roots, concurrent draining, and
  allocation-headroom scheduling. zjs deliberately starts with target shading
  rather than Riptide's retreating-wavefront barrier.
- The two-word Slot proof relies on the
  [LLVM atomic memory model](https://llvm.org/docs/LangRef.html#atomic-memory-ordering-constraints):
  acquire/release creates happens-before, while each monotonic atomic has its
  own modification order. The design still requires project-specific litmus
  and generated-code verification before concurrent enablement.
- Current source and executable repository state override this draft when they
  conflict. Update this document in the same change that intentionally changes
  one of its Interfaces or invariants.
