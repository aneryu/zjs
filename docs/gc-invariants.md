# GC invariants

Rules the current collector holds and a change must either preserve or
consciously replace. Every entry cites where it lives so it can be re-read
against the code rather than trusted from here. Rewritten 2026-09-03 (the
previous version described the three-phase trial-deletion cycle collector,
deleted with the rc build on 2026-08-29) and again 2026-09-06 for the end
state of the completion plan (S0-S4 + R3). Facts and gate readings:
[`tracing-gc-completion-account.md`](tracing-gc-completion-account.md);
per-stage execution records: `tracing-gc-s2/s3/s4-spec.md` §7; remaining
ablation: [`tracing-gc-s5-spec.md`](tracing-gc-s5-spec.md).

## Ownership is all-tracing

The collector is a non-moving, generational (sticky mark bit), incrementally
marking stop-the-world tracer (`src/core/gc_trace_stw.zig`). It owns every
`gc.Header` kind. `gc.RefKind` is a `u4` with thirteen values: 0 `object`,
1 `function_bytecode`, 2 `var_ref`, 3 `realm_context`, 4 `module`, 5 `shape`,
6 `string`, 7 `big_int`, 8 `property_storage`, 9 `array_storage`,
10 `payload`, 11 `rope`, 12 `string_buffer` -- the string family joined in S2
(2026-09-03), the dynamic atom table in S3 (2026-09-04), and 8/9/10/11/12 are
the S4-a..S4-c and S2-i additions.

No kind carries a reference count any more: `RefCountHeader`/`StringHeader`
and the 4-byte string rc prefix, `headerRefCount`, `gc.retain`/`gc.release`,
the `refCountRemoved` predicate, `AtomTable.dup`/`free`,
`DynamicAtom.ref_count` (80B -> 72B, S3) and the object-side `weakref_count`
(S4-e) are all deleted, and so are `JSValue.dup`/`free` with their 903 / 2966
call sites. Adding either back is a bug, not a safety net. One counter that
is *not* gone and is not a heap count: an `AtomTable` entry keeps
`weakref_count`, the shell counter that lets a WeakRef observe an atom's
death (`atom.zig`).

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

Property storage, array storage, a-class payloads and the extensible string
tail buffer (kinds 8 / 9 / 10 / 12) are GC cells of their own since
S4-b/S4-c/S2-i. Each has exactly one mint funnel
(`Registry.createStorageCellPublished`, `Object.createPropertyStorageCell`,
`Object.mintPayloadCell`), is a leaf, has no destructor, and is kept alive
only by its owner's edge: `storageCell(prop_values)` at the top of
`tracePropertyEdgesFallible`, `storageCell(payload)` before the payload
switch in `Object.traceChildEdgesFallible` (plus `storageCell(aux)` on the
bytecode arm), and a rope's edge to its tail buffer
(`tracing-gc-s4-spec.md` §7, S4-b / S4-c). Three rules come with them:

- **Mint and install must be adjacent.** A bare cell in hand is unrooted
  under a precise scan and any allocation in between can collect it. Where
  two cells are minted for one object, both `requestGCForAllocation` calls
  move ahead of the first mint (S4-c).
- **Growth does not free the old cell**; the old one is left to the sweep,
  and the install is hoisted ahead of the allocating reserve
  (`ensurePropertyCapacity`).
- **Bulk writes remember the owner** (`rememberOwnerForBulkWrite`):
  `Shape.compactProperties`, dependent-slice growth,
  `adoptDenseArrayElements`.

The one deliberate exception is
`initRegExpMatchArrayDenseElementsFromValue`, which keeps a native scratch
buffer because its fill loop allocates on every step and a bare cell has no
precise root there.

The `slots2_payloads` side table is gone (S4-c): a slots2 object that gains a
payload spills its two inline property slots to a `.property_storage` cell
instead, and `verifyObjectPropertyStorageLayouts` audits the invariant
"slots2 and payload implies non-inline properties".

## Edge enumeration authority

The authority trace lives beside the data it describes:
`Object.traceChildEdgesFallible` (`object.zig`) for objects, and the
per-kind `traceChildEdges*` for shape, realm and module, dispatched from
`traceHeaderEdges` (`gc_trace_stw.zig:63`). There are no separate hot-arm
copies any more (the rc-era `object_gc.zig` hot arms were test-only and are
removed by S0). **Adding an edge means updating the authority and the
representation snapshot; a value kind that becomes tracer-owned must appear
in the authority's visitor in the same commit that makes the tracer
responsible for it.**

`JSValue.cycleMarkHeader` (`value.zig:480`) is the single definition of "which
tags carry a traceable header". Widening it (S1 for BigInt, S2 for strings)
is the moment a kind joins the tracer; nothing else may pre-empt it.

Atoms are edges too. Since S3 the dynamic atom table holds no count, so every
holder of a bare atom id must report it through `visitAtom` from the
authority that owns the holder (shape property atoms, FunctionBytecode names
and var-ref names, module records, and the compile-time `CompileAtomScope`).
An entry is live iff `mark_epoch == epoch`, or its body is marked, or
`host_pins != 0`, or it was black-allocated this cycle (`born_epoch ==
epoch`); anything else is unbound and swept
(`tracing-gc-s3-spec.md` §2.2/§2.4).

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

R1-a/c/d narrowed but did not close the precise-root gap: of the six
attributable windows only the regexp match array was a genuine missing root,
plus one real bug (a publishing-shape root frame deactivated too early); the
rest is LLVM stack-slot residue and callee-saved spill in the *caller*, which
no added root frame fixes. The R3 census therefore cannot be used as an R1
worklist (`tracing-gc-completion-account.md` §1 and §6 item 6).

`host_pins` on an atom entry is the ABI-side root the tracer cannot see
(`PropNameID.internStatic`/`release`, reused by `LengthIndexAtom` and
`temporaryStringAtom`). A native holder without a pin, a root provider or a
traced owner edge is a use-after-free after the next major.

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

## Weak semantics

There are no husks. S4-e deleted `lifetime.trace.flags.husk`,
`headerIsReclaimableWeakHusk`, `destroyDeadWeakHusk` and the husk case of
`Block.forgetDoomedCell`: weak liveness is decided by mark bits at major
finish (`processWeak`), and the weak-id map is then the *whole* liveness
test -- `liveObjectFromWeakIdentity` resolves an id iff the object is still
registered. Two rules follow (`runtime.zig` `registerWeakObjectIdentity` /
`takeWeakObjectIdentity`, `tracing-gc-s4-spec.md` §7, S4-e):

- the id is handed back inside the same destruction that frees the struct,
  before `unregisterObjectWithBytes`, so the map never names a corpse for
  even one poll;
- an object handed a weak identity keeps `needs_finalizer` set. Retracting
  the bit would strand a `weak_object_ids` / `weak_id_objects` pair naming
  freed memory, which is a resurrection, not a leak.

`visitWeakCollectionEntry` stays a no-op in the mark visitor: marking a weak
edge would promote it to a strong one. Clearing is a separate phase and runs
only at major finish.

## Minor collections

A minor clears marks on young objects only, re-seeds all roots (precise and
conservative), traces from the remembered set, and sweeps `alloc & ~mark`
within young blocks and young extents (`collectMinor`,
`gc_trace_stw.zig`). Old objects keep their marks between majors, which is
what makes the remembered set sufficient. Survivors are promoted after one
minor; there is no aging.

Minors do not run `processWeak`; WeakRef / FinalizationRegistry / WeakMap
clearing happens only at major finish. A minor may not run while a major's
retirement is not `clean` (`minorsAllowed`), nor while the morgue
(`doomed_pending`) is open.

**Trace-coupled retirement: one mark claim owes one retirement** (S4-i).
`beginMinorRetirement()` opens the window *before any shade*, symmetrically
with the two majors, because three entries claim a mark without going
through the frontier -- `Collector.storageCell`'s leaf claim (S4-g),
`shadeExact`'s synchronous shape/realm arm, and `seedRoots`'s
construction-root arm -- and all three fire during root seeding or the
remembered walk, i.e. before a frontier-coupled window would exist. The one
exception is `traceRememberedOwner`, which calls `traceHeaderEdges` rather
than `traceHeader`: it is the only entry that does **not** claim a mark, so
it is the only one that must not retire. `drain` cannot repair a missed
retirement, because both shade entries return early on `headerMarked`.

The failure this contract prevents is not a leak: a claim that retires
nothing leaves a young, listless, uncensused *live* cell; `closeYoungGeneration`
pulls the young structures out from under it, the next minor's whole-block
`clearYoungBlockMarksStw` (which does not filter by the young bit) clears its
mark, and `alloc & ~mark` condemns it while it is alive -- observed as
`TypeError: not a function` and SIGSEGV in ReleaseFast raytrace
(`tracing-gc-s4-spec.md` §7, S4-i).

`young_trigger_count` (S4-f) is the minor *trigger* population and excludes
owned storage cells (`kindIsOwnedStorageCell` = kinds 8/9/10/12);
`young_count` keeps its population meaning, the invariant checks count both,
and the stress arm still triggers on `young_count`.

Young symbol bodies are a **minor-only** root: `AtomTable.young_symbol_atoms`
holds ids (so a retired or unbound entry simply stops reporting),
`traceYoungSymbolBodies` reports them under `Collector.minor_mode`, and the
two promotion points clear the list. An old shape holds a young body through
a bare atom id, which no remembered record covers; hanging the list on the
major root set instead delays a holder-less symbol's death by a full cycle
(67 tests red) (`tracing-gc-s3-spec.md` §2.4/§7).

A minor ends by publishing hot blocks back to the allocator in bounded
rounds: `Heap.publishCompletedHotBlocksSlice` after `clearYoungBlocks`, with
`minor_hot_publish_superblock_budget = 8` and `Block.flag_hot_rejected`
caching `openBlock`'s "no run of >= 64 free cells" verdict. Before S4-f,
publication happened only at the end of a major's teardown, so holes punched
by minors never came back: regexp held 187.6 MB committed against ~5 MB live
(36.9x), and the fix took maxrss 188 -> 23 MB
(`tracing-gc-s4-spec.md` §7, S4-f).

## Death side

Condemnation happens at major finish from the block bitmaps
(`snapshotAllDoomed`) and the non-block lists, and at minor finish within
young blocks and extents. **The condemned predicate is a stamp, not a flag**:
S4-h retired `cycle_visited` and made `lifetime.mark_epoch`'s reserved value
`condemned_mark_epoch = 0xffff` the third state
(`gc.stampHeaderCondemned` / `gc.headerCondemned`; 4 write sites, 20 read
sites). It is sound because condemned and marked are mutually exclusive by
construction, `advanceHeaderMarkEpoch` scrubs at `0xfffe` so the reserved
value is never a live epoch (`headerMarked` is false for any corpse of any
kind), and for block cells and extents that field was dead storage anyway.
The doomed bitmap is *not* a usable predicate: the drain clears it as it
goes and the next `snapshotDoomed` overwrites it wholesale
(`tracing-gc-s4-spec.md` §7, S4-h).

Destruction is not per corpse any more. Ordinary object death is a bitmap
operation: the sweep walks only `doomed & needs_finalizer`
(`Block.takeDoomedFinalizerCell`), and the rest of the population is
reclaimed by `Registry.reclaimDoomedBlock` -> `Heap.reclaimDoomedCells` with
block-level accounting (`popcount(dead - finalizing) x (cell_size -
prefix)`). `destroyPlainObjectFast`, the eleven a-class `destroy*Payload`
arms and `destroyArrayElements` are deleted; the deletion probe reads 0
plain-object destructor calls over 5.49M reclaimed objects and cells
(`tracing-gc-s4-spec.md` §7, S4-d/S4-e).

`needs_finalizer` is set at construction and is lifetime-sticky (D-S4-4). It
covers the b/c classes only: external buffers, typed-array view chains,
WeakRef / WeakMap / WeakSet / FinalizationRegistry, `std_file`, iterators
holding a live collection cursor, generators with open cells, dynamic and
host/plugin payloads, and anything handed a weak identity. It lives in
`BlockFlags` and in a **fourth per-block bitmap** (`Block.finalizerBits`,
alongside alloc / mark / doomed, offset-derived so `Block` stays 112B);
extents carry a `needs_finalizer` column instead
(`tracing-gc-s4-spec.md` §2.1/§2.4).

There are no two passes. Pass A (resource strip) and Pass B (husk free:
`drainCycleDeferredFreesBudgeted`, `DeferredFreeStack`, the parked-corpse
chain and the block-clustered drain) were deleted in S4-e once both of their
reasons had gone -- no refcount decrements during destruction (S1), and no
husk keeping a corpse addressable. What is left is the one-pass release the
string family has used since S2, over the `doomed & needs_finalizer`
population.

STW and incremental majors still run two structurally identical destruction
routines (`destroyCondemned` and `destroyDoomedSlice`); collapsing them is
S5-b, not a semantic difference (`tracing-gc-s5-spec.md` §2).

## What the gates do and do not cover

- test262 and the unified suite have passed over real collector defects
  before (missing barrier, missing edge). Suite green is not evidence about
  the collector.
- `ZJS_GC_STRESS=1` collects at every safepoint; `ZJS_GC_VERIFY_MINOR=1`
  cross-checks every minor against a full trace (reporting `precise`
  disagreements only -- `=verbose` adds the expected `conservative_only`
  ones); `ZJS_MINOR_AUDIT=1` reports live objects holding edges into the
  condemned set. S0 wires these into the gates (`test-gc-stress`,
  `test262-stress`).
- The leak census only sees destroy-side misses.
- `--gc-stats` measures behaviour; numbers there are single-run readings, not
  verdicts.

## Representation

Object layout is the M-cut 64-byte cell with no intrusive link
(`gc-v2-m-cut-object-layout.md`); non-object kinds keep `TraceHeader.next_non_object`.
The 8-byte `Metadata` prefix and its bit positions are pinned by `comptime`
asserts in `gc.zig` and by the representation snapshot
(`src/gc-representation-trace-snapshot.txt`). The flags byte reached its end
state in S4-h:

```
BlockFlags(u8) = kind:u4 | young(0x10) | finalizing(0x20) | needs_finalizer(0x40) | reserved(0x80)
```

`mark` (S4-a), `is_pinned` (S4-e; the pin ledger was always the authority and
the bit only a cache) and `cycle_visited` (S4-h) are gone, and
`lifetime.flags` -- byte 7 -- is a whole free byte. The free-cell poison
`0x8600_0000` is unchanged; its bit 7 now lands in `reserved` and nobody
reads it, while the condemn stamp lives in the lifetime word which the free
path does not overwrite. Reordering `Object` fields or
`ObjectStorage` remains a representation change with its own measurement
burden, not part of a collector change.
