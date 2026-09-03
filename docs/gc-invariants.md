# GC invariants

Rules the current collector holds and a change must either preserve or
consciously replace. Every entry cites where it lives so it can be re-read
against the code rather than trusted from here. Rewritten 2026-09-03: the
previous version described the three-phase trial-deletion cycle collector,
which was deleted with the rc build on 2026-08-29. Target state and migration:
[`tracing-gc-completion-plan.md`](tracing-gc-completion-plan.md).

## Ownership is mixed today; the target is all-tracing

The collector is a non-moving, generational (sticky mark bit), incrementally
marking stop-the-world tracer (`src/core/gc_trace_stw.zig`). It owns every
`gc.Header` kind: `object`, `function_bytecode`, `var_ref`, `module`,
`shape`, `realm_context`, `big_int` (`JSValue.isTracerOwned`;
`refCountRemoved`, `gc.zig`). Only the string family (its own
`StringHeader`) still counts.

Shape (S1-a, 2026-09-03) keeps no count at all. `ShapeOwnership.shared` is a
sticky copy-on-write bit set on the second adoption (`Shape.markShared`); an
unshared shape has exactly one holder, so that holder's drop frees it at once
(`shape.Registry.dropUnshared` -- the qjs `js_free_shape` rc→0 leg without the
counter), while a shared shape is left to the sweep. Shape is deliberately
NOT `frontierEpochSafe`: `relocateShape` frees and re-creates the struct on
inline FAM growth, so shapes are shaded synchronously, never queued.

Realm (S1-b, 2026-09-03) keeps no count either. `RealmRef` is a plain traced
pointer; `JSContext.destroy` only drops the host create-ref root provider and
the realm dies in the next major that finds it unreachable (or in
`gc.deinit`). **Realm holders must be traced**: heap holders through their
owner's child edges (FunctionBytecode, native function payload, auto-init
slot, FinalizationRegistry, RealmRecord), native holders through a root
provider (`Job`, module-graph continuation/waiter lists, Atomics.waitAsync
waiters) or a pin (`OwnedBinding`). `EventLoop.realm` is borrowed from the
host's live `JSContext`. A new native holder without one of these is a
use-after-free after the next major.

Heap BigInt (S1-c, 2026-09-03) is a leaf on `gc_obj_list`: constructors
publish through `addInitializedWithSizeNoFail` (`BigInt.register`),
`cycleMarkHeader`/`isTracerOwned` accept tag −9 with a second compare, and the
doomed pass has a `.big_int` arm. Parser constant-pool literals are allocated
**reserved** (`createFromOwnedReserved`: on no list, neither marked nor
swept) and registered when their FunctionBytecode is published; a builder
that dies first destroys them by hand (`destroyIfReservedValue`). The qjs
rc==1 in-place BigInt add is gone with the count.

The remaining kind is still reference counted and the tracer must not
assume otherwise until the corresponding completion-plan stage lands:

| kind | count lives at | what the count means | plan |
|---|---|---|---|
| string / rope / symbol body | 4-byte prefix at payload−4 (`gc.StringHeader`) | liveness; the tracer never marks or sweeps strings | S2 |

Consequence: `JSValue.dup/free` are no-ops for tracer-owned tags and real for
the rest (`value.zig:495-505`). Adding a `dup/free` pair for an object tag is
noise; omitting one for a string tag is a leak or a use-after-free.

## Edge enumeration authority

The authority trace lives beside the data it describes:
`Object.traceChildEdgesFallible` (`object.zig`) for objects, and the
per-kind `traceChildEdges*` for shape, realm and module, dispatched from
`traceHeaderEdges` (`gc_trace_stw.zig:63`). There are no separate hot-arm
copies any more (the rc-era `object_gc.zig` hot arms were test-only and are
removed by S0). **Adding an edge means updating the authority and the
representation snapshot; a value kind that becomes tracer-owned must appear
in the authority's visitor before its `dup/free` is made a no-op.**

`JSValue.cycleMarkHeader` (`value.zig:480`) is the single definition of "which
tags carry a traceable header". Widening it (S1 for BigInt, S2 for strings)
is the moment a kind joins the tracer; nothing else may pre-empt it.

## Write barriers

Every store of a heap reference into a published owner goes through
`Registry.generationalBarrierValue(owner, value)` or, for bulk writes,
`rememberOwnerForBulkWrite(owner)` before the stores (`gc.zig:4777-5040`).
Outside marking the barrier is a generational remember-owner barrier; during
incremental marking it is a Dijkstra insertion barrier that shades the exact
new target (`gc_concurrent.zig` header comment). The two are alternatives,
never a sequence.

An unpublished owner (`alloc_info.heap_accounted == false`) must not be
queued or remembered: publication traces its initial edges
(`markPublishedYoungClassified`). Publication order is therefore
"initialise fields, then publish"; a write barrier that fires on an
unpublished owner is a bug in the caller, not in the barrier.

The barrier fast path is one 8-byte load of the owner's metadata ANDed with
`barrier_gate` (`barrierOwnerSkips`). The two skip bits (`young`,
`remembered`) are the only facts allowed to buy an exit; `comptime` asserts in
`gc.zig` pin their positions.

## Roots

Precise roots: `pin_entries`, value root frames, active jobs, interpreter
frames and operand stack (`active_invocation_trace.zig`), `runtime.traceRoots`,
root providers. **In production only container/window value-root frames are
linked** (`runtime.zig:501`); scalar `rootValues`/`rootObjects` are compiled
out, and the conservative native stack/register scan (`gc_conservative.zig`)
is the net for every Zig local that holds a heap reference across an
allocation. Until lane R1 lands, deleting or narrowing the conservative scan
is a correctness change, not an optimisation.

Conservative candidates are validated through the address registry and the
block geometry; a candidate is never dereferenced before validation. A kind
that becomes tracer-owned must be resolvable by that path (block cell or
registered extent) from the same commit.

Membership lists are not roots: `context_head`, `constructing_context_head`
and the root-provider table answer "which runtime owns this", not "is this
alive" (`runtime.zig`). A realm is a root only while its host create-ref is
unconsumed.

**Owner is the object whose trace visits the slot, not the object the
caller happens to hold.** A realm's lazily filled slots (initial shapes,
class prototypes, `cached_values[]`, cached function/promise protos) are
traced from the realm header; barriering the global object instead leaves
the realm old and unremembered and the next minor condemns the young value
(TGC S0 found this through `Object.setCachedRealmValue`). Barrier only
published owners: an unpublished realm remembered mid-construction gets its
uninitialised fields traced.

**Realm → Shape during incremental marking is shaded synchronously**
(`shadeForConcurrentMark`): neither kind can be queued, so the shape is
marked and its proto queued; failing the cycle there surfaced as a spurious
`OutOfMemory` in every `$262.createRealm()` test.

## Weak husks

An object stripped by its first destroy but kept allocated because WeakRefs
still name it is a husk (`lifetime.trace.flags.husk`). Block bitmaps condemn
by `alloc & ~mark` and re-condemn every husk each cycle;
`destroyFromHeaderSlow` returns early on a husk, and the last weak release
(`destroyDeadWeakHusk`) frees it. A cell freed that way while its block is
still on the doomed list must leave the doomed bitmap and the drain's cached
word (`Block.forgetDoomedCell`), otherwise the allocator hands the cell out
and the drain destroys the new object. Both rules go away with S4 (weak
semantics decided by mark bits at sweep, no husks).

## Minor collections

A minor clears marks on young objects only, re-seeds all roots (precise and
conservative), traces from the remembered set, and sweeps `alloc & ~mark`
within young blocks (`collectMinor`, `gc_trace_stw.zig:781`). Old objects
keep their marks between majors, which is what makes the remembered set
sufficient. Survivors are promoted after one minor; there is no aging.

Minors do not run `processWeak`; WeakRef / FinalizationRegistry / WeakMap
clearing happens only at major finish. A minor may not run while a major's
retirement is not `clean` (`minorsAllowed`), nor while the morgue
(`doomed_pending`) is open.

## Death side

Condemnation happens at major finish from the block bitmaps
(`snapshotAllDoomed`) and the non-block lists; destruction is sliced
(`destroyDoomedSlice`) with a time budget and runs `destroyFromHeader` on
every corpse. That per-corpse destructor exists because strings, shapes and
BigInts are counted and property/array storage is malloc-owned; S4 of the
completion plan turns ordinary-object death into a bitmap operation and
keeps destructors only for the `needs_finalizer` set (external buffers,
weak holders, generators with open cells, host/plugin payloads).

Pass A strips resources, Pass B frees husks (`drainCycleDeferredFreesBudgeted`,
`object_gc.zig`). Pass B is held back while class-payload finalizers are
pending. Both passes disappear with S4.

## What the gates do and do not cover

- test262 and the unified suite have passed over real collector defects
  before (missing barrier, missing edge). Suite green is not evidence about
  the collector.
- `ZJS_GC_STRESS=1` collects at every safepoint; `ZJS_GC_VERIFY_MINOR=1`
  cross-checks every minor against a full trace; `ZJS_MINOR_AUDIT=1` reports
  live objects holding edges into the condemned set. S0 wires these into the
  gates (`test-gc-stress`, `test262-stress`).
- The leak census only sees destroy-side misses.
- `--gc-stats` measures behaviour; numbers there are single-run readings, not
  verdicts.

## Representation

Object layout is the M-cut 64-byte cell with no intrusive link
(`gc-v2-m-cut-object-layout.md`); non-object kinds keep `TraceHeader.next_non_object`.
The 8-byte `Metadata` prefix and its bit positions are pinned by `comptime`
asserts in `gc.zig` and by the representation snapshot
(`src/gc-representation-trace-snapshot.txt`). Reordering `Object` fields or
`ObjectStorage` remains a representation change with its own measurement
burden, not part of a collector change.
