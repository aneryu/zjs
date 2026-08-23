# GC inventory (Stage 0 remainder)

Date: 2026-08-23
Branch: `gc/tracing`
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
- other `gc.RefKind`s: `markChildrenCold` (`src/core/object_gc.zig`), which
  calls `Shape.traceChildEdgesNoFail`, `JSContext.traceChildEdgesNoFail`,
  `ModuleRecord.traceChildEdgesNoFail`, and inlines bytecode / var-ref walks.

Hot copies (must stay in lockstep with the authority; guarded in
`src/tests/core.zig`): `markOrdinaryObjectHot`, `markFastArrayHot`,
`markShapeHot`.

`JSValue.cycleMarkHeader` (`src/core/value.zig`) only returns a header for
tags in `[Tag.module, Tag.object]`. Strings, ropes, and BigInts are never
trial-deletion children even when a payload holds them.

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

### 1.1 `gc.RefKind` (8)

Defined in `src/core/gc.zig` `RefKind`. Cycle-candidate range is
`object..shape`; `string` / `big_int` sit above it and are RC leaves.

| Kind | Authority | Strong child edges | Weak / external | Risk |
|---|---|---|---|---|
| `object` | `Object.traceChildEdgesFallible` | shape, properties, payload family, dense elements, class-payload mark | weak identities, view lists, holder links — see 1.2 | MED (dynamic layout + class mark) |
| `function_bytecode` | `markChildrenCold` `.function_bytecode` — **no** `traceChildEdges` on the type | `FunctionBytecode.realm` (`RealmRef`); `cpoolSlice()` (`JSValue` FAM) | atoms (`func_name`, vardefs, closure names) are atom-table RC, not GC edges; `byte_code` / debug FAM are non-GC | MED: authority is collector-local, unlike Object/Shape/Module |
| `var_ref` | `markChildrenCold` `.var_ref` — **no** `traceChildEdges` on the type | `VarRef.value` only | `pvalue` is a borrowed frame alias when `is_open`; tracing it would double-count the frame slot (comment in `markChildrenCold`) | HIGH for Slot rewrite: `pvalue` is not a heap Slot |
| `realm_context` | `JSContext.traceChildEdgesNoFail` | module registry, unhandled rejections, eval function, OOM error, class/native-error prototypes, cached function/promise protos, five initial shapes, `cached_values`, regexp legacy statics, `global`, `lexicals` | `host_event_loop` is **not** a child edge (it is a root; §3); runtime/construction list links are membership | MED: `traceRoots` and `traceChildEdges` are not the same set |
| `module` | `ModuleRecord.traceChildEdgesFallible` | retained export cells, `func_obj`, `module_ns`, `import_meta`, `eval_exception` | `RequestEntry.module` is a borrowed registry pointer, **not** traced; atoms are atom RC | HIGH: borrowed request graph is invisible to both cycle mark and `traceRoots` |
| `shape` | `Shape.traceChildEdgesFallible` | `proto: ?*Object` | `registry_hash_next` is hashed-shape membership, not a GC edge; property atoms are atom RC; FAM props/buckets are non-GC | LOW after publish (hashed shapes are immutable) |
| `string` | `markChildrenCold` `.string` is empty | flat `String`: none. `StringRope.left` / `.right` (`src/core/string.zig`) are owned `JSValue` children **not walked by the cycle collector** (`JS_MarkValue` drops strings) | 4-byte `StringHeader` prefix; not on `gc_obj_list` | HIGH for tracing: ropes must gain an explicit child descriptor; they are not in the current registry census |
| `big_int` | `markChildrenCold` `.big_int` is empty | none (limbs are non-GC) | `BigInt.create*` never calls `addInitialized*`; RC-only, off the cycle list | LOW for edges; MED for `HeapCensus` (kind exists, objects are not in the intrusive registry) |

### 1.2 Object payload families

`class.PayloadKind` (`src/core/class.zig`) has 21 tags. `none` is the
no-payload / dense-array / inline-union case. Every allocating family has
`destroy` + `traceChildEdges` beside each other except native
`FunctionPayload`, which exposes `traceNativeRealm` instead.

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
| `iterator` `IteratorPayload` | 8 optional `JSValue`s | `collection_cursor_held` pins Map/Set entry array by count, not by pointer | `atom_keys` atom RC | MED (cursor is a live-count, not a Slot) |
| `collection` `CollectionPayload` | `entries[].key/value` | `weak_entries[]`: `visitWeakCollectionEntry` is a **no-op** in `MarkVisitor`; keys are weak identities; values are RC-owned and freed in `destroy` / weak sweep | `bucket_heads`, `live_cursors` | MED for tracing (see note below); **not** a current leak |
| `buffer` `BufferPayload` | none | `first_view` / view list are weak reverse links | `bytes`, `shared_store` (atomic external RC), `external_memory` | MED: `SharedBufferStore` is process-allocator + `ExternalMemoryToken`, not a GC node |
| `typed_array` `TypedArrayPayload` | `buffer: ?JSValue` | `backing_payload`, `buffer_prev/next` weak view links | `data: ?[*]u8` cached host pointer | MED: `data` is not a GC edge; detach protocol must stay |
| `regexp` `RegExpPayload` | none for cycle GC | — | `source` / `compiled_bytecode` `?*String` (string leaves) | MED for tracing: those strings must be traced even though `cycleMarkHeader` drops them |
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

## 2. Bare pointer exceptions (Stage 2 allowlist seed)

Search: heap structs under `src/core/` and `src/bytecode.zig` that store
`*Object`, `*Shape`, `*VarRef`, `*FunctionBytecode`, `RealmRef`/`?*JSContext`,
or heap `JSValue` without going through a handle/Slot type. FAM slices of
those types are included. Stack/`JSValue` public representation is out of
scope (design §5.1).

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
pub const value_root_frames_enabled = builtin.is_test or gc.shadow_tracer_enabled;
pub const value_root_link_containers_only = gc.shadow_tracer_enabled and !builtin.is_test;
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
| container `.slices` | 26 | mutable/borrowed/cells windows, including `ValueSliceRoot` / `CellSliceRoot` / `ValueListRoot` / array literals | **link** |
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
`traceActiveRoots` calls `traceRoots(self.active_value_roots, visitor)` and
then the exec Adapter at `active_invocation` (first word is
`ActiveInvocationTrace`). Default `rc` still compiles to
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
| Conservative native stack/registers | `src/core/gc_conservative.zig` (shadow-only) | AArch64 Linux spills x0–x30 and q0–q31 and scans `[SP, pthread stack high)`; lookup is census ranges, never a guessed dereference | MED remaining ABIs |
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

### 3.7 Part B: `pollGC` roots chain is a shell

This is the Stage 1 "costs no design work, only a consumer" item
(design §2.2 gap 3). The chain:

| Frame | What it does with `roots` |
|---|---|
| `JSRuntime.pollGC` (`runtime.zig`) | `_ = roots;` then `tryRunObjectCycleRemovalWithValueRoots(null)` |
| `tryRunObjectCycleRemovalWithValueRoots` | forwards `roots` to `Object.destroyRuntimeCyclesWithValueRoots` |
| `destroyRuntimeCyclesWithValueRoots` (`object_gc.zig`) | `_ = roots;` then `gcRemoveWeakObjects` + three-phase trial deletion over the **heap list only** |

There is no mark-from-roots phase in the current collector. Trial deletion
starts from every cycle-candidate header and walks `traceChildEdges*`. A
`ValueRootFrame` cannot keep an object alive unless that object's RC is
already > 0, which is the RC-owned stack `JSValue`, not the frame.

Existing tests (`src/tests/core.zig` "GC keeps rooted unique symbol atoms",
"GC keeps rooted function bytecode symbol constants") pass `ValueRootFrame`s
into `runObjectCycleRemovalWithValueRoots` and stay green because the
`JSValue` they point at still holds a refcount. They do not prove the
collector reads the frame.

Wiring `pollGC` to pass `roots` into `tryRunObjectCycleRemovalWithValueRoots`
would only move the discard one frame down. Building a fake consumer that
increments trial RC from a frame would be a second collector, not "a
consumer". **Stopped here. No pollGC code change in this tranche.**

A red test of the form "object held only by ValueRootFrame survives pollGC"
cannot be true in production (`value_root_frames_enabled` is false) and
cannot be true of the current algorithm even in tests without adding a
root-shading phase the RC collector does not have.

---

## 4. Native boundaries

"In" means host/plugin code is entered from the engine. "Out" means that
callback may call back into the engine (reentry). Design §6.1: a reclaiming
tracer cannot run a reentrant plugin mark hook.

### 4.1 Named reentry-capable callbacks (must be listed)

| Symbol | File | When | Reentry allowed? | Risk |
|---|---|---|---|---|
| `InstalledBinding.call` | `src/runtime/plugin.zig` | plugin function trampoline | **yes** — ABI: "Callback reentry is allowed" (`docs/runtime-plugin-abi.md` Installed Lifetime). `plugin.beginExecution` / `active_calls` pin the DSO | HIGH for safepoint; this is ordinary mutator code, not a tracer |
| `opaquePayloadMark` | `src/runtime/plugin.zig` | `class.Table.markPayload` during `Object.traceChildEdgesFallible` **and** `DeferredClassPayloadFinalizer.traceRoots` | ABI text for tracers: must not allocate, execute JS, call bindings, or throw. ABI lifetime text still allows callback reentry; **nothing in the engine enforces the tracer restrictions** | HIGH: this is the legacy reentrant tracer that **disables tracing mode** for that runtime (design §6.1, §15.11) |
| `opaquePayloadFinalizer` | `src/runtime/plugin.zig` | deferred class-payload job (`DeferredClassPayloadFinalizer.run`) after GC idle | **yes**; `.js` owner calls `descriptor.finalizer` | HIGH if ever invoked from a STW/final-remark path; today it is queued |
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
`addInitializedShape` / `JSRuntime.registerObjectWithBytes`.
`allocated = 1` in today's terms is `heap_accounted` plus intrusive-list
membership. `collectBeforeObjectAllocation` is the scheduling seam
(design §4.4).

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
| `string` / rope | `String.createAscii` / `createUtf8` / `createUtf16*` / `createLatin1*` / `createRope*` / `createSlice` / … (`src/core/string.zig`). **Not** `addInitialized*` | RC prefix only; never on `gc_obj_list` | HIGH for HeapCensus / conservative lookup |
| `big_int` | `BigInt.create` / `createFromOwned` / `createInlineUninitialized` / `createMulInline`. **Not** `addInitialized*` | RC header; off the cycle list | HIGH for HeapCensus |

Object `create*` wrappers (closed list from `src/core/object.zig`):
`create`, `createFinalizationRegistry`, `createWithOwnPropertyCapacity`,
`createGeneratorShell`, `createFromPropertyTemplate`, `createFromShape`,
`createArrayFromShape`, `createArrayFromInitialShape`, `createPlainObject`,
`createRegExpFromShape`, `createRegExpMatchArrayFromShape`,
`createRegExpMatchArrayFromPropertyTemplate`,
`createRegExpFromPropertyTemplate`, `createArgumentsFromShape`,
`createArray`, `createArrayWithOwnPropertyCapacity`. All except
`createGeneratorShell` publish before return.

### 5.2 Classification against §4.6

Almost every current constructor is "prepared" in the RC sense: fallible
backing is allocated first, the cell is initialized to a fully interpretable
layout, then the registry link is taken. Nested JS objects created *during*
construction are kept alive by RC on locals / `ValueRootFrame` (erased in
production), not by a construction root handle.

What tracing will need that does not exist yet:

- a `NoSafepointScope` around the init+publish window;
- black-allocation / initial-edge shading;
- for generator shells (and any future unpublished type), an explicit
  construction root once RC no longer keeps detached `JSValue` edges alive.

Hot common types (`createPlainObject`, `createArrayFromInitialShape`,
`createShape`, `VarRef.createClosed`, module `prepareFreshTarget`, FB sealed
publish) can stay prepared. Do not force them onto rooted construction.

---

## 6. Finalizable types

### 6.1 Engine object destroy (Pass A resource strip)

Every payload `destroy` in §1.2 runs from `destroyDetachedClassPayload` /
object teardown. Cycle collection: Pass A strips, Pass B frees husks
(`object_gc.zig`); if class-payload finalizers were deferred, Pass B waits
(`hasPendingDeferredClassPayloadFinalizers`).

This is ordinary ownership release, not host finalization. Listed so a
tracer's sweep records match destroy:

payloads in §1.2, plus `FunctionBytecode` / `VarRef` / `Shape` /
`ModuleRecord` / `JSContext` `destroyFromHeader`, plus string/rope/BigInt RC
zero paths.

### 6.2 Host / plugin finalizers (deferred)

| Type | Hook | Queue | Reentry | Risk |
|---|---|---|---|---|
| Plugin opaque wrapper `.js` | `opaquePayloadFinalizer` → `descriptor.finalizer` | `DeferredClassPayloadFinalizer` | yes, after GC idle | HIGH (see §4) |
| Plugin opaque wrapper `.host` | wrapper/plugin release only; no user finalizer | same destroy path | no user callback | LOW |
| Host `binding.zig` class with deinit | generated payload finalizer | object destroy or deferred | host-defined | MED |
| External host function record | `host_function.ExternalFinalizer` | `NativeCleanupJob` / `enqueueDeferredNativeCleanup` | native | MED |
| `SharedBufferStore` / `BufferPayload` external bytes | `ExternalByteStorageDeinit` | synchronous in `release` / `releaseStorage` | must not JS | MED |
| `StdFilePayload` | FILE close in destroy | synchronous | no JS | LOW |

`class.Table.Record` fields: `payload_finalizer`, `payload_mark`,
`legacy finalizer`, `binding_data_finalizer`. Production writers of
`payload_mark`: `opaquePayloadMark` (`plugin.zig`, two class-install sites)
and `binding.zig` `payloadMark` when `hasTraceHook()`.

### 6.3 JS `FinalizationRegistry`

`FinalizationRegistryPayload` cells + `Job.Payload.finalization`. Cleanup
jobs are roots until run (`Job.traceRoots`). No ordering; no JS cleanup
guaranteed at shutdown (design §9.3). Risk: LOW relative to plugin
finalizers; semantics already match the target.

### 6.4 Weak-dead callbacks

`WeakPersistentCallback` during `gcRemoveWeakObjects` (§4). This is
finalization-shaped host code running **inside** the collector's only
fallible phase. Tracing must not call it from mark/sweep; it belongs on the
owner thread after the heap is consistent, same as deferred payload
finalizers.

### 6.5 External memory

| Token | Owner | Counted? |
|---|---|---|
| `gc.ExternalMemoryToken` on `BufferPayload` / `SharedBufferStore` | runtime via `reportExternalAlloc` | yes |
| inline buffer bytes | `reportExternalFreeUntracked` on destroy | yes |
| plugin DSO / class-generation pins | `InstalledPlugin` pin counts | not heap bytes |
| `NativePin` | extra RC + pin flag | not external bytes |

A small JS heap can still hide unbounded native storage here; pressure
already feeds `pollGC` / `shouldRunMajorAt` (`src/core/memory.zig`).

---

## 7. Closed facts this census depends on

1. Eight `gc.RefKind`s, 21 `class.PayloadKind`s, 8 `Job.Payload` tags.
2. One `RootProvider` production registrant: `JSContext`.
3. `value_root_frames_enabled = builtin.is_test or gc.shadow_tracer_enabled`.
4. `traceActiveRoots` passes `active_value_roots` and the exec Adapter when
   `value_root_frames_enabled`; default `rc` still calls `traceRoots(null, visitor)`.
4b. Conservative native roots are shadow-only (`gc_conservative.zig`).
    Generator/async is not a fiber scan.
5. `pollGC` and `destroyRuntimeCyclesWithValueRoots` both `_ = roots;` —
   empty shell, not wired in this tranche.
6. Plugin tracer symbol that blocks reclaiming tracing:
   `opaquePayloadMark` (`src/runtime/plugin.zig`), installed as
   `payload_mark` on opaque host classes.
7. Strings/ropes/BigInts are RC objects off `gc_obj_list`.
8. `createGeneratorShell` is the unpublished-construction prototype.

When a later stage adds a Slot type or a root, update the corresponding
section in the same change.
