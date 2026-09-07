# GC inventory (Stage 0 remainder)

Date: 2026-08-23. **Sections 1.1, 1.2, 3.7, 5, 6.1 and 7 rewritten 2026-09-06**
for the completion-plan end state (S0-S4 + R3); everything else is the
original Stage 0 census and still reads against the rc-era tree in places --
where it does, the current facts are
[`tracing-gc-completion-account.md`](tracing-gc-completion-account.md) and the
per-stage records in `tracing-gc-s2/s3/s4-spec.md` §7.
Branch: `gc/tracing` (census), `main` (rewrite).
Source of truth: current tree, not this file. Re-run the method in each
section if the named symbols have moved.

This is the Stage 0 inventory named in
[`tracing-gc-design.md`](tracing-gc-design.md) §13: heap edges, raw-pointer
exceptions, root providers, native boundaries, allocation sites, and
finalizable types. Companion contracts:
[`gc-invariants.md`](gc-invariants.md),
[`perf/gc-baseline.md`](perf/gc-baseline.md).

Risk labels:

| Label | Meaning |
|---|---|
| HIGH | Tracing cutover is wrong unless this is closed. Stage 1. |
| MED | Must be on the Stage 2 allowlist or a named Adapter. Not a silent miss. |
| LOW | Already classified; listed so the census is complete. |
| SHELL | API exists; the current collector does not consume it. |

## Method

Grep plus direct reads of the authority symbols. No comptime reflection was
used. Counts that are not a closed enum (ValueRootFrame activate sites) give
the search, the total, and the risk subset rather than a 180-row table.

Reproduction commands live under each section.

---

## 1. Heap edges

Authority for cycle collection:

- objects: `Object.traceChildEdgesFallible` (`src/core/object.zig`) plus each
  payload's `traceChildEdges` (beside its `destroy` in
  `src/core/object_payloads.zig` and `src/core/generator_state.zig`);
- other `gc.RefKind`s: `traceHeaderEdges` (`src/core/gc_trace_stw.zig`),
  which calls `Shape.traceChildEdgesNoFail`, `JSContext.traceChildEdgesNoFail`,
  `ModuleRecord.traceChildEdgesNoFail`, and inlines bytecode / var-ref walks.

There are no hot copies any more: the rc-era `markOrdinaryObjectHot` /
`markFastArrayHot` / `markShapeHot` arms in `object_gc.zig` were test-only
after the trial-deletion collector went and were deleted in TGC S0
(2026-09-03). `object_gc.zig` now holds only death-side helpers.

`JSValue.cycleMarkHeader` (`src/core/value.zig`) returns a header for every
tracer-owned tag. It was widened to BigInt in S1 and to the string family in
S2, so strings, ropes and BigInts are ordinary traced children now; the
rc-era statement that they are never children is void
(`tracing-gc-completion-account.md` §1).

### 1.0 Two entries corrected by measurement

Two rows below were first written as suspected missing edges. Both were
checked against the running engine and neither is a defect; acting on the
original readings would have introduced one.

**WeakMap/WeakSet values do not leak today.** The `MarkVisitor.visitWeakCollectionEntry`
no-op is correct for the current collector: marking a weak edge would promote a
weak reference to a strong one. Weak clearing is a separate phase
(`gcRemoveWeakObjects`), and it works — 20,000 self-referential cycles stored
only as WeakMap values, with their keys dying immediately, reclaimed 39,931
objects against 39,922 for the same cycles built without a WeakMap, leaving
5.6 KB of difference (the map itself and its table capacity). No leak.

What *is* true is that the ephemeron rule ("value is live only while the table
and key are live") has no representation in the mark phase, because the current
design does not need one. A tracing collector does: see the design document's
§9.1 fixed-point requirement. That is migration work, not a repair.

**`RequestEntry.module` is a documented borrow, not a missed edge.** Its own
comment states that `module` points into the same RealmContext-owned registry
as the containing record, that registry membership owns the base references,
and that request edges therefore neither retain nor trace — explicitly matching
QuickJS `JSReqModuleEntry.module`. The migration constraint to carry forward is
that this stays correct only while the registry keeps owning those records.

### 1.1 `gc.RefKind` (13, rewritten 2026-09-06)

Defined in `src/core/gc.zig` `RefKind`, a `u4` since S4-a: 0 `object`,
1 `function_bytecode`, 2 `var_ref`, 3 `realm_context`, 4 `module`, 5 `shape`,
6 `string`, 7 `big_int`, 8 `property_storage`, 9 `array_storage`,
10 `payload`, 11 `rope`, 12 `string_buffer`. **Every one of them is
tracer-owned**; there is no RC leaf and no cycle-candidate sub-range any
more. Kinds 8/9/10/12 are owned storage cells: leaves, no destructor, kept
alive only by their owner's `storageCell(...)` edge, and excluded from
`young_trigger_count` (`kindIsOwnedStorageCell`).

| Kind | Authority | Strong child edges | Weak / external | Risk |
|---|---|---|---|---|
| `object` | `Object.traceChildEdgesFallible` | shape, properties, payload family, dense elements, class-payload mark | weak identities, view lists, holder links — see 1.2 | MED (dynamic layout + class mark) |
| `function_bytecode` | `traceHeaderEdges` `.function_bytecode` — **no** `traceChildEdges` on the type | `FunctionBytecode.realm` (`RealmRef`); `cpoolSlice()` (`JSValue` FAM) | atoms (`func_name`, vardefs, closure names) are reported through `visitAtom` since S3, not counted; `byte_code` / debug FAM are non-GC | MED: authority is collector-local, unlike Object/Shape/Module |
| `var_ref` | `traceHeaderEdges` `.var_ref` — **no** `traceChildEdges` on the type | `VarRef.value` only | `pvalue` is a borrowed frame alias when `is_open`; tracing it would double-count the frame slot (comment in `traceHeaderEdges`) | HIGH for Slot rewrite: `pvalue` is not a heap Slot |
| `realm_context` | `JSContext.traceChildEdgesNoFail` | module registry, unhandled rejections, eval function, OOM error, class/native-error prototypes, cached function/promise protos, five initial shapes, `cached_values`, regexp legacy statics, `global`, `lexicals` | `host_event_loop` is **not** a child edge (it is a root; §3); runtime/construction list links are membership | MED: `traceRoots` and `traceChildEdges` are not the same set |
| `module` | `ModuleRecord.traceChildEdgesFallible` | retained export cells, `func_obj`, `module_ns`, `import_meta`, `eval_exception` | `RequestEntry.module` is a borrowed registry pointer, **not** traced; atoms go through `visitAtom` (S3) | HIGH: borrowed request graph is invisible to both cycle mark and `traceRoots` |
| `shape` | `Shape.traceChildEdgesFallible` | `proto: ?*Object` | `registry_hash_next` is hashed-shape membership, not a GC edge; property atoms are reported through `visitAtom` (S3); FAM props/buckets are non-GC | LOW after publish (hashed shapes are immutable) |
| `string` | `traceHeaderEdges` `.string` (flat body) | none; a flat body is a leaf | block cell or registered extent; the rc prefix is gone (S2) | LOW |
| `rope` (11) | `traceHeaderEdges` `.rope` | `StringRope.left` / `.right` as traced children, plus `storageCell` to the tail buffer when one exists | own kind since S4-a (it used to be discriminated by borrowing the prefix `mark` bit) | LOW |
| `string_buffer` (12) | none (leaf) | none | the extensible tail buffer behind a rope's dependent views (S2-i); named by no `JSValue`, so deliberately outside `isStringFamily` | LOW |
| `big_int` | `traceHeaderEdges` `.big_int` (leaf) | none (limbs are non-GC) | published through `addInitializedWithSizeNoFail` (`BigInt.register`); parser constant-pool literals are allocated **reserved** and registered with their FunctionBytecode | LOW |
| `property_storage` (8) | none (leaf) | none | minted by `Object.createPropertyStorageCell` via `Registry.createStorageCellPublished`; owner edge `storageCell(prop_values)` at the top of `tracePropertyEdgesFallible` | MED: mint and install must be adjacent |
| `array_storage` (9) | none (leaf) | none | `createArrayStorageCell/Slice`; also mapped-arguments var-ref slices. Exception: `initRegExpMatchArrayDenseElementsFromValue` keeps a native scratch buffer | MED: same adjacency rule |
| `payload` (10) | none (leaf) | none | a-class class payloads and four dependent slices (promise reactions, bound args, disposable resources, arguments var_refs); owner edge `storageCell(payload)` before the payload switch, `storageCell(aux)` on the bytecode arm | MED |

### 1.2 Object payload families

`class.PayloadKind` (`src/core/class.zig`) has 21 tags. `none` is the
no-payload / dense-array / inline-union case.

**Rewritten 2026-09-06 (S4-c/S4-d).** The families split in two. The *a
class* -- ordinary, arguments, object_data, bound_function, proxy, var_ref,
promise, disposable_stack, global, regexp, plus `FunctionRarePayload` and
`BytecodeFunctionAux` -- are `.payload` GC cells (kind 10), leaves with **no
destructor**: their eleven `destroy*Payload` arms and `destroyArrayElements`
were deleted, and their dependent slices are `.payload` cells too. The *b/c
class* -- buffer, typed_array, collection, iterator, weak_ref,
finalization_registry, std_file, generator, native `function`, dynamic and
host/plugin payloads -- keep `allocRuntime` backing, keep their `destroy`,
and set `needs_finalizer` at construction. Every family still has
`traceChildEdges` beside its data, except native `FunctionPayload`, which
exposes `traceNativeRealm`. The tables below list edges, not lifetimes;
"freed in `destroy`" in any row means the b/c class only.

Object-level edges traced **before** the payload switch
(`Object.traceChildEdgesFallible`):

| Edge | Kind | Notes | Risk |
|---|---|---|---|
| `shape_ref: *Shape` | strong | always present; tombstone `finalizingShape()` during class finalizer | MED (bare pointer; §2) |
| `prop_values[0..shape.prop_count]` data | strong `JSValue` | shape/value pair is one layout transaction | MED |
| property `.accessor` | strong getter/setter `JSValue` | `traceUnusualProperty` | LOW |
| property `.var_ref` | strong `VarRef` via `cell.valueRef()` = `JSValue.object(&header)` | slot stores `*VarRef`; destroy releases the cell | MED |
| property `.auto_init` | strong realm header | `RealmRef` packed into the slot | MED |
| `arrayElements()` | strong `JSValue` | dense `ObjectStorage.array` | MED (slice backing) |
| iterator-next cache | strong optional `JSValue` | `JSRuntime.cached_iterator_next_entries`; object-keyed, traced from the object | MED |
| bytecode captures | strong `VarRef` cells | `u.bytecode_function.captureSlots()` | MED |
| `function_bytecode` | strong FB header | `JSValue.functionBytecode` | LOW |
| `home_object` | strong `?*Object` | direct pointer or `BytecodeFunctionAux` | MED |
| `functionRarePayload()` | strong `JSValue`s | zjs-only aux | LOW |
| mapped-arguments `argumentsVarRefs()` | strong `VarRef` cells | class `mapped_arguments` | MED |
| `markClassPayload` | host/plugin | `class.Table.markPayload` → `PayloadMark` | HIGH if the hook reenters (§4) |

Per-payload (`traceChildEdges` unless noted):

| PayloadKind / type | Strong | Weak / external | Not an edge | Risk |
|---|---|---|---|---|
| `ordinary` `OrdinaryPayload` | 14 optional `JSValue`s (callsite, promise reaction/capability/combinator, error stack) | — | flags | LOW |
| `iterator` `IteratorPayload` | 8 optional `JSValue`s | `collection_cursor_held` pins Map/Set entry array by count, not by pointer | `atom_keys` go through `visitAtom` (S3) | MED (cursor is a live-count, not a Slot) |
| `collection` `CollectionPayload` | `entries[].key/value` | `weak_entries[]`: `visitWeakCollectionEntry` is a **no-op** in `MarkVisitor`; keys are weak identities; values are traced strongly from `entries[]` and cleared by `processWeak` at major finish | `bucket_heads`, `live_cursors` | MED for tracing (see note below); **not** a current leak |
| `buffer` `BufferPayload` | none | `first_view` / view list are weak reverse links | `bytes`, `shared_store` (atomic external RC), `external_memory` | MED: `SharedBufferStore` is process-allocator + `ExternalMemoryToken`, not a GC node |
| `typed_array` `TypedArrayPayload` | `buffer: ?JSValue` | `backing_payload`, `buffer_prev/next` weak view links | `data: ?[*]u8` cached host pointer | MED: `data` is not a GC edge; detach protocol must stay |
| `regexp` `RegExpPayload` | `source` / `compiled_bytecode` `?*String` are traced children since S2 | — | flags | LOW (an a-class `.payload` cell; no destructor) |
| `bound_function` `BoundFunctionPayload` | `target`, `this_value`, `args[]` | — | — | LOW |
| `proxy` `ProxyPayload` | `target`, `handler` | — | — | LOW |
| `arguments` `ArgumentsPayload` | `var_refs[]` as `JSValue` | — | — | LOW |
| `object_data` `ObjectDataPayload` | `data` | — | — | LOW |
| `weak_ref` `WeakRefPayload` | none | `weak_target_identity`; `weak_holder_link` | — | LOW (identity, not address) |
| `var_ref` `VarRefPayload` | `value` | — | flags | LOW (object-wrapped cell; distinct from `gc.RefKind.var_ref`) |
| `finalization_registry` `FinalizationRegistryPayload` | `realm`, `cleanup_callback`; cell `held_value` iff `keepsHeldValuesAlive()` | `target_identity`, `unregister_token_identity` | cell `state` | MED |
| `std_file` `StdFilePayload` | none | — | `?*std.c.FILE` host handle | LOW |
| `disposable_stack` `DisposableStackPayload` | each resource `value`/`method`; async dispose resolve/reject/error | — | — | LOW |
| `global` `GlobalPayload` | `uninitialized_vars: ?*Object` | — | — | LOW |
| `realm_record` `RealmRecordPayload` | `realm: RealmRef` | — | — | LOW |
| `promise` `PromisePayload` | `result`, reaction callback/arg, `reactions[]` | — | flags | LOW |
| `generator` `GeneratorPayload` | execution `this_value`, `current_function`, `yield_star_iterator`; suspended stack/locals/args/var_refs/open_var_refs unless `running_aliases`; `async_promise`; async-queue result/promise/resolve/reject | — | `running_aliases` means the live frame owns the slots | HIGH: suspended execution is a heap-resident precise root today; live aliases must stay mutator-only / STW |
| `function` (native) `FunctionPayload.traceNativeRealm` | `native.realm` | — | `call_cache` is comptime rodata; `rare` traced via `functionRarePayload()` | LOW |
| `FunctionRarePayload` | 12 optional `JSValue`s | — | builtin markers / magic | LOW |
| `.none` dense array | `arrayElements()` at Object level | — | `count/capacity/length` | LOW |
| `.none` / `.ordinary` empty `{}` | properties + shape only | — | `u.payload == null` | LOW |

`RegExpLegacyStatics` is realm-owned (`JSContext.regexp_legacy_statics`),
traced from the realm, not from an object payload.

### 1.3 Registry / runtime edges that are not `RefKind` children

| Location | What it is | Cycle-traced? | Risk |
|---|---|---|---|
| `JSContext.modules: module.Registry` | list of `ModuleRecord`, each a GC node; `Registry.traceChildEdgesFallible` visits every record | yes, from the realm | LOW |
| `ModuleRecord.requests[].module` | borrowed canonical-record pointer | **no** | HIGH |
| `JSRuntime.job_queue` | not a GC node; `Job.traceRoots` | no (root; §3) | MED |
| `JSRuntime.cached_iterator_next_entries` | `CachedIteratorNextEntry { object: *Object, value: ?JSValue }` | yes, from the object if the table is non-empty | MED: bare `*Object` key |
| `WeakReferenceHolderLink` | intrusive list of weak holders | membership only | LOW |
| `JSRuntime.borrowed_reference_holders` | O(1) index into the same | membership | LOW |

---

## 2. Bare pointer exceptions (Stage 2 allowlist)

Lint: `node tools/architecture/check_gc_slots.js` (checkpoint + production
gate). Heap `JSValue` / `*Object` / `*Shape` / `*VarRef` / `*FunctionBytecode`
/ `RealmRef` fields must be tagged `gc-slot: heap|immutable|weak` or listed in
`tools/architecture/gc-slots-allowlist.json`. The allowlist is shrinking-only
(`baseline_count` is the recorded seed). Bulk Slot APIs live in
`src/core/gc_slot.zig` with Stage 6 barrier comments on copy/move/resize/
destroy/property-install; they are not wired to `Object.prop_values` or dense
elements (§6.4). Shadow write audit (`src/core/gc_write_audit.zig`; the `--gc-shadow-check`
CLI flag was removed with the shadow collector on 2026-08-29, the audit is
now test-only via `root.zig`) records those lint-invisible stores at runtime; hits are
the Stage 6 barrier candidate list, not a failure. Plugin-opaque DSO payload
stores are outside the engine ABI and stay uninstrumented.

Migrated `gc-slot: heap` families (writes already go through
`Object.setOptionalValueSlot` / `GcBuffer.setSlice`, the Slot-under-RC
sequence): `IteratorPayload` (8), `ProxyPayload` (2), `ObjectDataPayload`,
`TypedArrayPayload.buffer`, `BoundFunctionPayload`, `ArgumentsPayload.var_refs`.

Inventory seed (tables below). Search: heap structs under `src/core/` and
`src/bytecode.zig`.

### 2.1 Mutable after publish (must become Slots or a named bulk API)

| Site | Type | Notes | Risk |
|---|---|---|---|
| `Object.shape_ref` | `*Shape` | shape transition publishes a new pointer with the slot-arm flags | MED |
| `Object.prop_values` | `[*]property.Entry` | `property.Slot` is a 16-byte untagged union (data `JSValue` / accessor / auto_init / `*VarRef`); active arm is a Shape flag | HIGH: union + FAM; compile-time Slot rewrite is insufficient |
| `ObjectStorage.array.values` | `[*]JSValue` | dense elements; resize/move is bulk | HIGH |
| `ObjectStorage.bytecode_function.function_bytecode` | `?*FunctionBytecode` | replaced only during construction / rare teardown | MED |
| `ObjectStorage.bytecode_function.var_refs` | `[*]?*VarRef` | sealed after capture install; empty sentinel is a dangling aligned pointer | MED |
| `ObjectStorage.bytecode_function.home_or_aux` | `?*anyopaque` | untagged `*Object` or tagged `*BytecodeFunctionAux` | MED |
| `BytecodeFunctionAux.home_object` | `?*Object` | | MED |
| `FunctionPayload.rare` | `?*FunctionRarePayload` | cold heap, not a GC node | LOW |
| `VarRef.value` | `JSValue` | closed binding / parked generator | MED |
| `VarRef.pvalue` | `*JSValue` | **borrowed frame alias when open**; not owned | HIGH |
| `Shape.proto` | `?*Object` | hashed shapes are immutable after publish; clones write proto before `addInitializedShape` | LOW if the immutability audit holds |
| `FunctionBytecode.realm` | `RealmRef` (`?*JSContext`) | set at publish | LOW if sealed |
| `FunctionBytecode.cpool` | `?[*]JSValue` | FAM; post-publish replacement needs a named op | MED |
| `JSContext.global` / `lexicals` | `?*Object` | mutated as the realm is filled | MED |
| `JSContext.cached_function_proto` / `cached_promise_proto` | `?*Object` | | MED |
| `JSContext.array_shape` and four sibling initial shapes | `?*Shape` | realm-owned, written during bootstrap | MED |
| `JSContext.class_prototypes` / `native_error_prototypes` / `cached_values` / `eval_function` / `preallocated_oom_error` | `JSValue` / `[]JSValue` | | MED |
| `GlobalPayload.uninitialized_vars` | `?*Object` | | MED |
| `CollectionPayload.entries` / `weak_entries` | slices of `JSValue` / identity+value | rehash is bulk | HIGH |
| `PromisePayload.reactions` | `[]JSValue` | growable | MED |
| `BoundFunctionPayload.args` | `[]JSValue` | | MED |
| `ArgumentsPayload.var_refs` | `[]JSValue` | | MED |
| `DisposableStackPayload.resources` | `[]DisposableResource` (`JSValue` pairs) | | MED |
| `GeneratorPayload` suspended storage | `[]JSValue` plus `[]*VarRef` / `[]?*VarRef` | `running_aliases` switches the owner | HIGH |
| `FinalizationRegistryPayload.cells[].held_value` | `JSValue` | strong only while active/pending | MED |
| `TypedArrayPayload.buffer` | `?JSValue` | | MED |
| `ModuleRecord.func_obj` / `module_ns` / `import_meta` / `eval_exception` / export `retained_cell` | `JSValue` | | MED |
| `JSRuntime.cached_iterator_next_entries[].object` | `*Object` | cache key | MED |
| `JSRuntime.current_exception` | `JSValue` | root, not a heap field of a GC node | see §3 |

### 2.2 Immutable after publish (declaration candidates)

| Site | Type | Evidence | Risk |
|---|---|---|---|
| `Shape` FAM `props()` / `hashBuckets()` after hash-cons | non-GC | hashed shapes are interned; mutation clones | LOW |
| `FunctionBytecode` code/vardef/closure FAM after `publishExecutionFlags` + `addInitializedWithSizeNoFail` | non-GC / atoms | two publication funnels | LOW if audit holds |
| `RegExpPayload.source` / `compiled_bytecode` | `?*String` | written then left | LOW |
| `FunctionPayload.native.call_cache` | `?*const InternalRecord` | comptime rodata | LOW |

### 2.3 Weak / external (must not become strong Slots)

| Site | Type | Notes | Risk |
|---|---|---|---|
| `WeakCollectionEntry.key_identity` | `usize` | identity, not address | LOW |
| `WeakRefPayload.weak_target_identity` | `?usize` | | LOW |
| `FinalizationRegistryCell.target_identity` / `unregister_token_identity` | `?usize` | | LOW |
| `WeakReferenceHolderLink.previous/next` | `?*Object` | holder list, not ownership | MED (bare `*Object` but not a strong edge) |
| `BufferPayload.first_view` + `TypedArrayPayload.buffer_prev/next` / `backing_payload` | payload pointers | reverse view list; buffer does not keep views alive | MED |
| `TypedArrayPayload.data` | `?[*]u8` | host view into buffer bytes; cleared on detach | MED |
| `BufferPayload.shared_store` | `?*SharedBufferStore` | atomic external RC | MED |
| `StdFilePayload.file` | `?*std.c.FILE` | | LOW |
| `ModuleRecord.requests[].module` | `?*ModuleRecord` | borrowed; both records stay alive via the realm registry | HIGH |
| `ModuleRecord.link_stack_prev` | `?*ModuleRecord` | transient Tarjan; valid only while `.linking` | MED |
| `Shape.registry_hash_next` | `?*Shape` | hash bucket chain | LOW |
| `JSContext.runtime_prev/next`, `construction_prev/next` | `?*JSContext` | membership | LOW |
| `ModuleRecord.registry_prev/next` | `?*ModuleRecord` | membership | LOW |

`property.Slot` itself is the load-bearing 16-byte untagged union. A
mechanical `*Object`/`JSValue` rewrite that ignores the Shape discriminant
is a correctness bug, not a style miss (design §2.1).

---

## 3. Root providers

### 3.1 `value_root_frames_enabled`

```zig
// 2026-09-03 current definitions (runtime.zig:497-501); the shadow collector
// and `gc.shadow_tracer_enabled` were removed on 2026-08-29.
pub const value_root_frames_enabled = true;
pub const value_root_link_containers_only = !builtin.is_test;
// Production therefore links only container/window frames; scalar
// `rootValues`/`rootObjects` sites are compiled out and rely on the
// conservative scan. See tracing-gc-completion-plan.md F8 and lane R3.
```

Default `rc` production still erases activate/deactivate at compile time. Tests
link every frame (no conservative scanner yet). Shadow CLI links only frames
with `slices.len != 0` — native JSValue/cell arrays and windows (design §7.1).
Scalar Zig locals stay unlinked there and wait for stack/register capture.

### 3.1.1 Activate-site census (177 engine sites, tests/ excluded)

Method: `rg '\.activate\((rt|ctx|&rt|ctx\.runtime)' src` excluding `src/tests`,
then classify by the frame the activate closes over.

| Class | Count | What it is | Production shadow |
|---|---:|---|---|
| `rootValues` scalar | 127 | pointers at Zig `JSValue` locals | skip (conservative) |
| manual scalar `.values` | 24 | same, spelled by hand | skip (conservative) |
| container `.slices` | 26 | mutable/borrowed/cells windows, including `ValueSliceRoot` / `ValueListRoot` / array literals | **link** |
| `RootedValueCopies` | 3 | heap copy of a `[]JSValue` (Array/Object builtins) | still `.values`; converting to `.slices` is a production codegen change (deferred) |

`call.zig` / `eval_ops.zig` mixed frames (scalar locals plus an args window)
count as container because of the window. Empty test frames in
`runtime.zig` are test-only LIFO checks.

Do not promote a scalar frame to a container to make the unexplained set
look smaller: that would retain objects a tracing collector should not keep
once conservative scanning exists.

### 3.2 `RootProvider` registration

Exactly one production registration:

| Symbol | File | When |
|---|---|---|
| `JSContext.rootProvider` → `traceRootProvider` → `JSContext.traceRoots` | `src/core/context.zig` | `publishLive` |
| `JSRuntime.registerRootProvider` / `unregisterRootProvider` | `src/core/runtime.zig` | the table itself |

`unregisterRootProvider` runs from context destroy. Tests also register
synthetic providers. No plugin or job queue registers a `RootProvider`.

### 3.3 `JSRuntime.traceRoots` / `traceActiveRoots`

`traceRoots(roots, visitor)` (`src/core/runtime.zig`) visits, in order:

1. the passed `ValueRootFrame` chain (`traceValueRootFrames`);
2. `current_exception`;
3. `local_root_slots` (`JSValue.Scope` / `Local`);
4. `persistent_root_slots` (`JSValue.Persistent`);
5. `deferred_class_payload_finalizers` (via `DeferredClassPayloadFinalizer.traceRoots`, which may call `class.PayloadMark`);
6. `deferred_weak_value_frees`;
7. `job_queue.traceRoots`;
8. every `root_providers` entry.

When `value_root_frames_enabled` (tests and `-Dzjs_gc=shadow`),
`traceActiveRoots` calls `traceRoots(self.active_value_roots, visitor)`,
then the exec Adapter at `active_invocation` (first word is
`ActiveInvocationTrace`), then `trace_atomics_wait_async` if exec installed
it (first `atomicsLinkAsyncWaiter`). That snapshot retains waiter Promises
under `atomics_waiter_mutex`, unlocks, then visits — never a visitor while
holding the mutex (design §7.1). Default `rc` still compiles to
`traceRoots(null, visitor)` so production `.text` is unchanged.

Covered via `JSContext.traceRoots` (provider): unhandled rejections, eval
function, OOM error, class/native-error prototypes, cached function/promise
protos, `cached_values`, regexp legacy statics, `global`, `lexicals`,
`host_event_loop`. When `value_root_frames_enabled`, also the module registry
and the five initial Shapes (already cycle-collector child edges; mirrored
onto the root Interface so a mark-from-roots tracer does not depend on
shading the realm node first). Default `rc` keeps those walks erased.

### 3.4 Not covered by `traceActiveRoots` (the Stage 1 holes)

| Set | Where it lives | Today | Risk |
|---|---|---|---|
| Linked `ValueRootFrame`s | `JSRuntime.active_value_roots` | compiled out in production; tests/shadow `traceActiveRoots` now pass the list | HIGH / SHELL in default `rc` |
| `pollGC` / cycle-collector `roots` argument | see §3.7 | discarded the whole way down | HIGH / SHELL |
| Active bytecode invocation | `JSRuntime.active_invocation: ?*anyopaque`, published by `src/exec/zjs_vm.zig`; decoded in `src/exec/inline_calls.zig` | tests/shadow: `ActiveInvocationTrace` prefix + `src/exec/active_invocation_trace.zig` walks live windows only; default `rc` erases the call | HIGH, gated Adapter landed (design §2.2 gap 2) |
| Weak slots | `weak_root_slots` | correctly omitted from strong tracing; swept in `gcRemoveWeakObjects` | LOW |
| Conservative native stack/registers | `src/core/gc_conservative.zig` (STW) | AArch64 Linux/macOS spills x0–x30 and q0–q31; x86_64 SysV/Windows spills rax–r15 and xmm0–xmm15. Stack high is `pthread_getattr_np` (Linux), `pthread_get_stackaddr_np` (Darwin), or `GetCurrentThreadStackLimits` (Windows). Lookup is the live page-radix address registry (`gc_address_registry.zig`), never a guessed dereference | MED remaining ABI: AArch64 Windows |
| Atoms that own GC values | `AtomTable` | unique-symbol atoms are kept by atom RC / dedicated tests, not by `traceRoots` | MED |

### 3.4.1 Active-invocation live windows (gated Adapter)

Authority: `src/exec/active_invocation_trace.zig`, invoked through
`ActiveInvocation.header: ActiveInvocationTrace` at offset 0 when
`value_root_frames_enabled`. Nested `runWithArgsState` is chained via
`ActiveInvocation.previous` (tracing builds only; default `rc` keeps those
fields as `void` so the publish path stays two pointers).

| Class | Owner | Live range | Not visited |
|---|---|---|---|
| arguments | `Frame.args` | typed window length (`FrameSlab` partition `arg_count`) | `Frame.storage_values` unused tail |
| original arguments | `Frame.cold.original_args` | typed window; absent when `cold == null` | unused slab capacity |
| locals | `Frame.locals` | typed window length (`local_count`) | unused slab capacity |
| operand stack | `Stack.liveValues()` | `top_ptr - values` (`Stack.len()`) | `Stack.backingValues()[len..capacity]` |
| VarRef cells | `Frame.var_refs` | every element is a live cell by construction | unused pointer-region bytes in the slab |
| open VarRef cells | `Frame.open_var_refs` | non-null slots only | nulls |
| this | `Frame.this_value` | always | — |
| current function | `Frame.current_function` plus `Frame.function` bytecode header | always | — |
| new.target | `Frame.cold.new_target` | only when `ownership.new_target != .aliases_function` | the alias (already `current_function`) |
| native caller / ctor fallback | `Entry.native_caller` | `teardown.has_native_caller` or `constructor_completion` | empty-leaf overlay (resume words, not a JSValue) |
| running generator object | `L0State.generator_state` | resume only | — |
| L0 frame + stack | `Machine.l0.level` | always, including when `depth > 0` | unused Entry chunk slots (`chunks` capacity) |
| inline frames | `Machine.top` → `Entry.prev` | live chain only | unused chunk entries |

Walks `Machine`, not `MachineBacktraceView`: a native fence freezes a view
but does not hide the Entry chain from marking.

**Suspended generator/async is not an invocation root.** Exact parked
state lives on the heap object:

- `GeneratorPayload` (`src/core/generator_state.zig`)
- `GeneratorExecutionState.this_value` / `current_function` / `yield_star_iterator`
- `SuspendedExecutionState.storage` (`SuspendedStackStorage.values` live
  prefix, `SuspendedFrameStorage` locals/args/var_refs/open_var_refs)
- `GeneratorPayload.traceChildEdges` walks those windows iff
  `!execution.suspended.running_aliases`; while `running_aliases` is true
  the live Frame/Stack owns the slots and the Adapter above walks them.
- `async_promise` and `async_queue[]` stay payload child edges.
- There is no stackful-fiber subsystem (design §7.2).

`createGeneratorShell` unpublished construction remains a ValueRootFrame /
RC window, not an `active_invocation` root.

### 3.5 Handle types (`JSValue.Scope` / `Local` / `Persistent` / `Weak`)

Aliases in `src/core/value.zig` → `HandleScope`, `LocalHandle`,
`JSValueHandle`, `WeakPersistentValue` in `src/core/runtime.zig`.

Production use of the **handle objects** is thin. Locals/persistents that
exist are in `local_root_slots` / `persistent_root_slots` and **are** visited
by `traceRoots`. Engine code overwhelmingly uses `ValueRootFrame` (erased)
plus RC instead of `HandleScope`.

| API | Production callers found | Notes |
|---|---|---|
| `HandleScope.enter` / `enterHandleScope` | tests + embedding examples (`src/tests/core.zig`, `embedding_examples.zig`, `engine_production.zig`) | not on the VM hot path |
| `createPersistentValue` / `createValueHandle` | binding test helper, `engine_production.zig`, `binding.zig` one site | |
| `createWeakPersistentValue` | `src/cli/run_test262_host.zig` (namespace keep-alive) + tests | `WeakPersistentCallback` runs during weak sweep (§4) |
| `NativePin` | public embedder view-pin in `src/root.zig`; `pinHeaderForNative` | RC + `gc.pinHeader`; not a tracing root |

### 3.6 `ValueRootFrame` construction / activate sites

Method: `rg '\.activate\((rt|ctx|&rt|ctx\.runtime)' src` excluding tests and
`profile.activate`.

- **178** activate call sites in engine/runtime/exec.
- **129** `rootValues(` helper uses (subset of the above).
- Files: `src/core/{runtime,object,array,function,promise,json}.zig`,
  `src/runtime/event_loop.zig`, and the `src/exec/*` modules listed by that
  grep. Largest cluster: `json_ops.zig` (37 activates).

These frames are real stack maps for a future tracer. In production they are
not linked and not consumed. Risk: HIGH / SHELL.

Job queue roots (`src/core/jobs.zig` `Job.traceRoots` / `Queue.traceRoots`):
eight payload tags — `generic`, `promise`, `promise_reaction`,
`promise_thenable`, `promise_settlement`, `dynamic_import`, `atomics_waiter`,
`finalization` — plus the job's `RealmRef`. Covered by `traceRoots`, not by
the cycle collector.

Event-loop roots: `src/runtime/event_loop.zig` `EventLoop.traceRoots` →
timers / rw / signal handlers, reached through `JSContext.host_event_loop`
inside the context provider.

### 3.7 `pollGC` roots chain (rewritten 2026-09-06)

The rc-era text here described a shell: `pollGC` discarded `roots`,
`destroyRuntimeCyclesWithValueRoots` discarded them again, and there was no
mark-from-roots phase for a `ValueRootFrame` to feed. All three premises are
void. The tracer marks from roots, `runObjectCycleRemoval` is the single
production entry into a major, and a `ValueRootFrame` keeps its contents
alive on its own -- there is no refcount underneath it to do the work.

What survives from that section is the production shape, not the defect:
**only container/window value-root frames are linked in production**
(`value_root_link_containers_only`); scalar `rootValues`/`rootObjects` are
compiled out, and the conservative native stack/register scan is the net for
every Zig local holding a heap reference across an allocation. Flipping that
flag is the tail of lane R1 and is gated on the residue analysis in
`tracing-gc-completion-account.md` §6 item 6, not on this census.

Two real defects found in this area during S4/R1 and fixed with regression
tests: the regexp match array's native fill had no root, and a
publishing-shape root frame was deactivated before its window closed.

## 4. Native boundaries

"In" means host/plugin code is entered from the engine. "Out" means that
callback may call back into the engine (reentry). Design §6.1: a reclaiming
tracer cannot run a reentrant plugin mark hook.

### 4.1 Named reentry-capable callbacks (must be listed)

Census note (2026-09-06): the rows and later sections naming
`src/runtime/plugin.zig`, `docs/runtime-plugin-abi.md`,
`hostCallExternalHostFunction`, and `ExternalCall` describe the 2026-08-23
tree. That loader, ABI document and external-host registry were deleted in
NB2 phase A3; every host function is now one `NativeEntry`
(`src/core/native_entry.zig`) created through `zjs.native` and dispatched by
`src/exec/vm_native.zig` / `builtin_dispatch.callRecordFromVmInRealm`. The
reentry facts are unchanged: managed native functions may call back into JS
(and do so through `zjs.CallSite`); typed leaf functions may not (contract
C5).

| Symbol | File | When | Reentry allowed? | Risk |
|---|---|---|---|---|
| `InstalledBinding.call` | `src/runtime/plugin.zig` | plugin function trampoline | **yes** — ABI: "Callback reentry is allowed" (`docs/runtime-plugin-abi.md` Installed Lifetime). `plugin.beginExecution` / `active_calls` pin the DSO | HIGH for safepoint; this is ordinary mutator code, not a tracer |
| `opaquePayloadMark` | `src/runtime/plugin.zig` | `class.Table.markPayload` during `Object.traceChildEdgesFallible` **and** `DeferredClassPayloadFinalizer.traceRoots` | ABI text for tracers: must not allocate, execute JS, call bindings, or throw. ABI lifetime text still allows callback reentry; **nothing in the engine enforces the tracer restrictions** | HIGH: this is the legacy reentrant tracer that **disables tracing mode** for that runtime (design §6.1, §15.11) |
| `opaquePayloadFinalizer` | `src/runtime/plugin.zig` | `Object.destroyFromHeaderSlow` detaches `.js` payloads into `DeferredClassPayloadFinalizer`; user callback runs after the collector phase is idle | **yes**; `.js` owner calls `descriptor.finalizer` | LOW: live-wrapper, queued-job, and active-job roots cover declared payload edges; nested GC remains pending until callback/morgue exit |
| `binding.zig` generated `payloadMark` | `src/binding/binding.zig` | same `markPayload` seam as plugins, when a host `Spec` has `trace` | host Zig `spec.trace`; can do anything Zig can do | HIGH if a spec traces by calling JS |
| `binding.zig` generated payload deinit / `payload_finalizer` | `src/binding/binding.zig` | object destroy / deferred | host deinit | MED |
| `callHostFunction` / `hostCallExternalHostFunction` | `src/exec/call.zig` | native / external host functions | **yes** — builtins and `ExternalCall` freely reenter | MED (mutator, not tracer) |
| `callNativeBuiltinRecordForVm` / `callNativeCallableObject` | `src/exec/call_runtime.zig` | VM native call | **yes** | MED |
| `Job.Func` / job runners | `src/core/jobs.zig`, exec runners | event-loop drain | **yes** (they *are* JS) | LOW as a tracer issue |
| `HostEventLoop` `runNextTimer` / `runNextRwHandler` / `runNextSignalHandler` | `src/core/context.zig` vtable; impl `src/runtime/event_loop.zig` | idle / poll | **yes** | MED |
| `JSRuntime.runInterruptHandler` | `src/core/runtime.zig`; polled from `JSContext` and `src/exec/regexp_adapter.zig` | every 10_000 ticks / regexp | host `InterruptHandler`; not specified no-alloc | MED for safepoint latency (design §7.4) |
| `WeakPersistentCallback` via `JSRuntime.clearWeakRootSlot(..., true)` | `src/core/runtime.zig`; called from `object_gc.sweepDeadWeakRootSlots` inside `gcRemoveWeakObjects` | **during cycle collection**, before trial RC | callback is `fn (*JSRuntime, ?*anyopaque) void` — **can reenter** | HIGH: GC-time host callback on the current collector |
| `host_function.ExternalFinalizer` / `NativeCleanupJob.run` | `runtime.zig` `enqueueDeferredNativeCleanup` | after GC, budgeted | native free; plugin binding teardown | MED |
| `ExternalByteStorageDeinit` / `SharedBufferStore.release` | `object_payloads.zig` | buffer destroy | must not call JS | MED (not enforced) |

### 4.2 Plugin ABI facts that tracing depends on

- Tracers run **synchronously during GC marking** (`runtime-plugin-abi.md`
  Opaque Host Objects).
- First ABI has **no** general root-token service; plugin-held `JSValue`s
  are raw values plus the optional tracer.
- `HostServices` on `CallFrame` currently exposes opaque-object create/unwrap
  and `PropNameID`, not eval/call. Reentry still happens because the
  trampoline is an ordinary native call: the plugin can call back through
  any engine API it captured, and the runtime does not hold a lock across
  it.

Until plugin-held JS values live in engine-managed persistent slots, or the
ABI grows a no-allocation / no-reentry tracer, a class whose `payload_mark`
is `opaquePayloadMark` (or any `binding.zig` `spec.trace` that is not
proven no-reentry) must refuse tracing-mode enablement for that runtime.

### 4.3 Outbound engine → host that is not a JS callback

`MemoryAccount` alloc hooks, `reportExternalAlloc`, DSO close, FILE close.
These must stay no-JS. Not tracing roots.

---

## 5. Allocation sites

Publication primitive: `gc.Registry.addInitializedWithSizeNoFail` /
`addInitializedShape` / `JSRuntime.registerObjectWithBytes`, and for owned
storage cells `Registry.createStorageCellPublished`.
`allocated = 1` in today's terms is `heap_accounted` plus intrusive-list
membership (block cells carry the fact in the block bitmaps instead).
`collectBeforeObjectAllocation` is the scheduling seam (design §4.4).

### 5.1 Funnel per `RefKind`

| Kind | Create / publish symbols | Prepared vs rooted (§4.6) | Risk |
|---|---|---|---|
| `object` | `Object.create` → `createPlainObject` or `createInternal`; specialized: `createArray*`, `createFromShape`, `createFromPropertyTemplate`, `createRegExp*`, `createArgumentsFromShape`, `createFinalizationRegistry`, `createWithOwnPropertyCapacity`. Publish: `registerObjectWithBytes` after the object and payload bytes exist | **Prepared** for the cell: shape + payload + property buffer are allocated first; `collectBeforeObjectAllocation` then `createNoTrigger`; fields are filled; then publish. Nested allocs before publish are already RC-owned. | MED: `createInternal` can allocate payloads that themselves trigger GC (`force_gc` / test `createRuntime`); the unpublished object is not yet in the list | 
| `object` generator | `createGeneratorShell` allocates **without** shape and **without** registry; `finishGeneratorShell` publishes; `destroyGeneratorShell` is the unpublished error path | **Unpublished construction** — the only explicit "not in the allocated registry until minimally traceable" path. Matches §4.6 rooted/unpublished form | HIGH: keep this as the pattern for mutator_only constructors |
| `shape` | `shape.Registry.createShape` / `createShapeWithPropertyCapacity` / transition clones (`src/core/shape.zig`); `addInitializedShape` | Prepared: FAM sized, fields written, then publish; proto retain after publish | LOW |
| `var_ref` | `VarRef.createClosed` / `createOpen`; `addInitializedWithSize` | Prepared: struct filled, then publish. `createOpen` stores a borrowed `pvalue` before publish | HIGH (`pvalue`) |
| `realm_context` | `JSContext.createWithPublication` → `initConstructing` (`addInitializedWithSize`) then optional `finishConstruction` / `publishLive` (RootProvider + live list) | Two-phase: GC-registered while `publication_state == .constructing`; `traceChildEdgesNoFail` / `traceRoots` no-op until `.live` | MED: constructing realms are in the cycle list but absent from live root traversal |
| `module` | `module.Registry.prepareFreshTarget`: `memory.create` + `replaceDefinitionNoFail` + `addInitializedWithSizeNoFail` + `link` | Prepared, no-fail after the single alloc | LOW |
| `function_bytecode` | compiler commit (`src/bytecode.zig` around `publishExecutionFlags` + `addInitializedWithSizeNoFail`); tests: `createFixture` + `publishFixtureNoFail`; `src/exec/small_inline.zig` one no-fail publish | **Prepared / sealed publication**: unpublished shell owns FAM; commit transfers atoms/cpool then publishes. Destroy unpublished via `destroyUnpublishedFixture` | MED: post-publish cpool writes must stay named |
| `string` / `rope` / `string_buffer` | `String.createAscii` / `createUtf8` / `createUtf16*` / `createLatin1*` / `createRope*` / `createSlice` / … (`src/core/string.zig`) | Block cell or registered extent since S2; no rc prefix; the extensible tail buffer (kind 12) is minted with the rope that reads it | LOW for HeapCensus / conservative lookup |
| `big_int` | `BigInt.create` / `createFromOwned` / `createInlineUninitialized` / `createMulInline`, published by `BigInt.register` (`addInitializedWithSizeNoFail`) | Prepared; parser constant-pool literals are `createFromOwnedReserved` (on no list, neither marked nor swept) until their FunctionBytecode publishes them; a builder that dies first calls `destroyIfReservedValue` | MED (the reserved window) |
| `property_storage` / `array_storage` / `payload` / `string_buffer` | `Registry.createStorageCellPublished` (single funnel) behind `Object.createPropertyStorageCell` / `createArrayStorageCell` / `mintPayloadCell` / `createPayloadSliceCell` | **Rooted by adjacency**: mint immediately before install, both `requestGCForAllocation` calls hoisted ahead of the first mint, growth leaves the old cell to the sweep, bulk writes call `rememberOwnerForBulkWrite` | HIGH if minting and installing drift apart |

Object `create*` wrappers (closed list from `src/core/object.zig`):
`create`, `createFinalizationRegistry`, `createWithOwnPropertyCapacity`,
`createGeneratorShell`, `createFromPropertyTemplate`, `createFromShape`,
`createArrayFromShape`, `createArrayFromInitialShape`, `createPlainObject`,
`createRegExpFromShape`, `createRegExpMatchArrayFromShape`,
`createRegExpMatchArrayFromPropertyTemplate`,
`createRegExpFromPropertyTemplate`, `createArgumentsFromShape`,
`createArray`, `createArrayWithOwnPropertyCapacity`. All except
`createGeneratorShell` publish before return.

### 5.2 Classification against §4.6 (rewritten 2026-09-06)

Almost every constructor is still "prepared": fallible backing first, the
cell initialised to a fully interpretable layout, then the registry link.
What has changed is what keeps the half-built graph alive. There is no
refcount on locals any more, so the three items this section listed as
missing are now the load-bearing mechanisms:

- publication traces the initial edges (`markPublishedYoungClassified`) and
  black allocation covers what is minted during marking; an *unpublished*
  owner (`alloc_info.heap_accounted == false`) must never be remembered or
  queued;
- generator shells and other unpublished types have an explicit construction
  root, and `seedRoots`'s construction-root arm retires the traced young
  header (S4-i) rather than leaving a claim unpaid;
- owned storage cells are rooted by **adjacency** rather than by a handle,
  which is why the mint/install rule in §5.1 is a correctness rule.

Hot common types (`createPlainObject`, `createArrayFromInitialShape`,
`createShape`, `VarRef.createClosed`, module `prepareFreshTarget`, FB sealed
publish) stay prepared. Do not force them onto rooted construction.

---

## 6. Finalizable types

### 6.1 Engine object destroy (rewritten 2026-09-06)

There is no Pass A / Pass B any more. S4-e deleted both passes together with
husks and `DeferredFreeStack`; the sweep is one pass over
`doomed & needs_finalizer` (`Block.takeDoomedFinalizerCell`), and everything
else -- ordinary objects, all owned storage cells, the whole string family,
BigInt -- is reclaimed by the block bitmaps with block-level accounting and
runs no destructor at all (deletion probe: 0 plain-object destructor calls
over 5.49M reclaims, `tracing-gc-s4-spec.md` §7, S4-d/S4-e).

What still has an engine-side `destroy`, i.e. the population a tracer's sweep
records must match:

- the b/c payload families of §1.2 (buffer, typed_array, collection,
  iterator, weak_ref, finalization_registry, std_file, generator, native
  `function`, dynamic and host/plugin payloads), reached through
  `destroyFromHeaderSlow`'s payload switch, which is gated by
  `payloadKindNeedsFinalizer` -- the same classification that sets the bit at
  construction;
- the non-block kinds `FunctionBytecode` / `VarRef` / `Shape` /
  `ModuleRecord` / `JSContext` `destroyFromHeader`;
- any object handed a weak identity, which keeps `needs_finalizer` so the id
  is returned inside the same destruction that frees the struct (§6.4).

### 6.2 Host / plugin finalizers

| Type | Hook | Queue | Reentry | Risk |
|---|---|---|---|---|
| Plugin opaque wrapper `.js` | `opaquePayloadFinalizer` → `DeferredClassPayloadFinalizer` → `descriptor.finalizer` | detach during object destroy; callback after collector phase idle | yes | LOW (see §4 and design §9.4) |
| Plugin opaque wrapper `.host` | wrapper/plugin release only; no user finalizer | synchronous object destroy | no user callback | LOW |
| Host `binding.zig` class with deinit | generated payload finalizer | synchronous object destroy | host-defined | MED/HIGH under tracing if it reenters |
| External host function record | `host_function.ExternalFinalizer` | `NativeCleanupJob` / `enqueueDeferredNativeCleanup` | native | MED |
| `SharedBufferStore` / `BufferPayload` external bytes | `ExternalByteStorageDeinit` | synchronous in `release` / `releaseStorage` | must not JS | MED |
| `StdFilePayload` | FILE close in destroy | synchronous | no JS | LOW |

`class.Table.Record` fields: `payload_finalizer`, `payload_mark`,
`legacy finalizer`, `binding_data_finalizer`. Production writers of
`payload_mark`: `opaquePayloadMark` (`plugin.zig`, two class-install sites)
and `binding.zig` `payloadMark` when `hasTraceHook()`.

`DeferredClassPayloadFinalizer` reserve/enqueue/drain is connected to plugin
`.js` wrapper construction and destruction. The temporary live-wrapper root,
queued job, and active dequeued job all enumerate the same payload tracer, so
the callback's declared subgraph remains live until callback return.

### 6.3 JS `FinalizationRegistry`

`FinalizationRegistryPayload` cells + `Job.Payload.finalization`. Cleanup
jobs are roots until run (`Job.traceRoots`). No ordering; no JS cleanup
guaranteed at shutdown (design §9.3). Risk: LOW relative to plugin
finalizers; semantics already match the target.

### 6.4 Weak-dead callbacks

`WeakPersistentCallback` during weak processing (§4). This is
finalization-shaped host code running inside the collector; it must not be
called from mark, and it belongs on the owner thread after the heap is
consistent, same as deferred payload finalizers.

Weak liveness itself is decided by mark bits at major finish. There is no
husk: `liveObjectFromWeakIdentity` resolving an id **is** the liveness test,
so the id is handed back inside the same destruction that frees the struct,
and an object with a weak identity keeps `needs_finalizer` for exactly that
reason (`runtime.zig` `registerWeakObjectIdentity`, `tracing-gc-s4-spec.md`
§7, S4-e).

### 6.5 External memory

| Token | Owner | Counted? |
|---|---|---|
| `gc.ExternalMemoryToken` on `BufferPayload` / `SharedBufferStore` | runtime via `reportExternalAlloc` | yes |
| inline buffer bytes | `reportExternalFreeUntracked` on destroy | yes |
| plugin DSO / class-generation pins | `InstalledPlugin` pin counts | not heap bytes |
| `NativePin` | `pin_entries` ledger (the authority; the header bit retired with `is_pinned` in S4-e) | not external bytes |

A small JS heap cannot silently hide tracked native storage here:
`JSRuntime.reportExternalAlloc` records a token, adds weighted allocation debt,
and queues an external/debt major that `pollGC` / `shouldRunMajorAt` services
(`src/core/runtime.zig`, `src/core/gc.zig`). Token and inline releases
symmetrically reduce the live external ledger; cumulative debt resets only
after a completed major. Ordinary ArrayBuffer backing also overlaps
`MemoryAccount`; shared and adopted backing does not.

---

## 7. Closed facts this census depends on

1. **Thirteen** `gc.RefKind`s (was eight; 8/9/10/11/12 added by S4-a..S4-c
   and S2-i), 21 `class.PayloadKind`s, 8 `Job.Payload` tags.
2. One `RootProvider` production registrant: `JSContext`.
3. Value-root frames are linked in production for containers/windows only
   (`value_root_link_containers_only`); scalar `rootValues`/`rootObjects`
   are compiled out. The shadow build and `-Dzjs_gc=shadow` no longer exist
   (the selector accepts `trace_stw` only).
4. `traceActiveRoots` passes `active_value_roots` and the exec Adapter; the
   tracer is the only collector, so there is no `rc` default arm to fall
   back to.
4b. Conservative native roots are **production** (`gc_conservative.zig`), not
    shadow-only: they are the net for every Zig local holding a heap
    reference across an allocation, and narrowing them is a correctness
    change until lane R1 lands. `-Dzjs_gc_roots_diag` is the precise-root
    diagnosis build. Generator/async is still not a fiber scan. The
    `--gc-shadow-check` CLI and its test262 census are gone with the shadow
    build.
5. `pollGC` marks from roots like any other entry; the rc-era
   `_ = roots;` shell described in §3.7 is void.
6. Plugin tracer symbol that blocks reclaiming tracing:
   `opaquePayloadMark` (`src/runtime/plugin.zig`), installed as
   `payload_mark` on opaque host classes. Measured 2026-08-23 under the
   then-current `-Dzjs_gc=shadow` build (that selector value no longer
   exists; the classification stands, the reproduction command does not):
   - DSO `zjs-runtime-plugin-fixture` has no tracer (`opaquePayloadMark`
     returns at `tracer orelse return`); allocated=251 unexplained=0.
     Classification: edge-free payload.
   - In-process host object with `tracer` holding a heap `JSValue`:
     `shadow_trace_calls=1` during `gc_shadow.run` (shadow walks
     `markClassPayload`); the child is reachable; unexplained=0.
     Classification: legacy reentrant tracer. Reclaiming tracing stays
     disabled for that class (design §6.1).
6b. Full test262 shadow census (ReleaseFast, 20 workers, 25.25s wall):
    prepared 49778, executed 44584 (5194 feature-skipped never create a
    runtime), unexplained_tests=0 unexplained_objects=0, five
    classification buckets all 0, census errors=0, max_allocated=8662,
    mean_ns=1.52ms max_ns=152ms. Strategy A (full run) chosen because a
    single in-process census on a harnessed test was 0.16–0.35ms and the
    full-suite mean stayed ~1.5ms.
6c. `Atomics.waitAsync` Adapter (2026-08-23): hanging waiter (no notify)
    after dropping the JS result object has the waiter Promise in the
    exact-reachable set (`gc_shadow.isExactReachable`). Not conservative-only.
7. **Void since S1/S2.** This item recorded why strings, ropes and BigInts
   stayed off `gc_obj_list` (the 4-byte rc prefix, the `cycleMarkHeader`
   gap, the conservative-lookup cost). All three obstacles were removed:
   BigInt publishes through `BigInt.register` (S1-c), the string family
   lives in block cells or registered extents with no prefix rc and its own
   kinds 6/11/12 (S2, S4-a, S2-i), and both are resolvable by the
   conservative path. Nothing is off the tracer by representation any more.
8. `createGeneratorShell` is the unpublished-construction prototype.

Stage 4 observation (2026-08-24, corrected 2026-09-06): `gc_space.zig`
classifies published sizes with a measured small-class table (16-128 linear;
max small class 128 from a 99% histogram p50=64/p95=96/p99=128, not 4 KiB).
`gc_sweep_model.zig` was deleted in the 2026-09-03 ablation (batch 3b) --
it drove an empty window map in production. `gc_block_heap.zig` is the 2 MiB
superblock / 64 KiB block allocator and is the production heap, not an
experiment: it carries four per-block bitmaps (alloc / mark / doomed /
`finalizerBits`) and publishes hot blocks back at minor end (S4-f). Strings
and ropes register extent intervals in `gc_address_registry`; there is no rc
prefix to widen, and there is no `rc` default to keep the old allocator.

When a later stage adds a Slot type or a root, update the corresponding
section in the same change.
