# L2 — Property slot 40B tagged-union → 16B untagged (kind derived from shape flags)

Status: BLUEPRINT (read-only ground-truth). HEAD = `main @ d3afe1e` (rounds 1-11 shipped).
qjs reference: `/home/aneryu/quickjs/quickjs.c` (16B JSValue, NaN-boxing OFF on aarch64).

This change makes zjs's per-property value cell faithful to qjs `JSProperty`
(quickjs.c:947-963): a **16B untagged union** whose kind is **not** stored in the
cell but **derived from the owning shape's per-property flags** via the qjs
`JS_PROP_TMASK` bits (quickjs.c:968-972 / quickjs.h:303-307).

---

## 0. THE PARKED ATTEMPT (`stash@{0}`) — single most valuable input

`git stash list` →
```
stash@{0}: On qjs-faithful-align-s1: messy-rank4-incomplete   <-- THIS ONE
```
Base commit = `da34bc1` (qjs-faithful-align-s1, "bytecode-parser-align + top-level
let single-cell"). **That base is months behind current HEAD `d3afe1e`** — HEAD has
since rewritten large parts of object.zig (propFlagsAt/propAtomAt now exist,
Accessor reverted to JSValue, var_ref destroy got a cycle-collector guard, etc.).

What codex actually built (and it is GOOD — re-usable design, not a dead end):

1. `property.zig` — `Kind = enum(u2){ data, accessor, var_ref, auto_init }` packed
   into `Flags: packed struct(u6){ writable, enumerable, configurable, kind:Kind,
   deleted }`. `Slot = union { data, accessor, auto_init, var_ref }` — a **bare
   (untagged) union with NO `.deleted` arm**. `Slot.destroy(self, flags, rt)` and
   `Slot.dup(self, flags)` take the flags and `switch (flags.kind)`.
2. `Accessor` was shrunk from `{ getter: JSValue, setter: JSValue }` (32B) to
   `{ getter: ?*gc.Header, setter: ?*gc.Header }` (16B) with `getterValue()` /
   `setterValue()` accessors and `syncGetterFromVisitedValue()` /
   `syncSetterFromVisitedValue()` round-trip helpers for the GC visitor.
3. A `comptime` assert that `@sizeOf(Slot) == 16` **only under ReleaseFast/Small**
   (bare unions still carry a hidden safety tag under Debug/ReleaseSafe).
4. `descriptor.fromSlot(flags, slot)` rewritten to `switch (flags.kind)`.
5. ~all object.zig sites converted from `switch (entry.slot)` to deriving kind from
   `self.propFlagsAt(index)` then `switch (flags.kind)`.

### WHY IT STALLED (failure mode)

Three compounding causes, in order of importance:

- **(A) It was bundled into a single rank-4 mega-commit (80 files, object.zig
  ±1819 lines) on a divergent base.** The stash is the WHOLE s1 keystone campaign
  (value/atom/string/symbol/gc/shape/frame), not an isolated L2 slice. It cannot be
  rebased onto HEAD; HEAD already absorbed most of those other changes
  independently. The L2 slice was never separable, so "didn't converge" =
  the surrounding 79 files moved out from under it.
- **(B) The test-infra cascade (the documented one).** The shared-engine test
  harness `src/tests/exec.zig:455-535` snapshots & restores the global object's
  property cells, and it stores the **value slots and the shape flags in two
  separate arrays** (`shared_engine_baseline_properties` = slots only, line 458-461;
  `shared_engine_baseline_shape_props` = flags, line 463-470), restoring them in
  two separate passes (slots line 533, shape props line 537). It calls
  `entry.slot.dup()` / `entry.slot.destroy(rt)` **with no flags** (lines 460, 519,
  529, 533) and `entry.slot = .deleted` (line 520). Every one of those breaks under
  the untagged model because dup/destroy now NEED the kind, and `.deleted` is no
  longer a union arm. This harness is shared by all 1226 exec unit tests, so a
  single mistake there fails a huge swath of tests at once with no local blame —
  "messy state, didn't converge." It is mechanical to fix but must be done in the
  same shot with the right discipline (see §4).
- **(C) A correctness regression baked into the stash's old base.** Stash
  `Slot.destroy` for `.var_ref` is `self.var_ref.valueRef().free(rt)` with **no
  cycle-collector guard**. HEAD property.zig:162-165 has the guard
  `if (rt.gc.phase == .remove_cycles and cell.header.flags.cycle_visited and
  !cell.header.flags.cycle_preserved) return;`. Reviving the stash verbatim would
  reintroduce a GC-cycle UAF. (Not the stall cause, but proof the stash is stale.)

**Takeaway:** the stash's *representation design is correct and should be reused*;
its *packaging and base* are the failure. Re-do L2 as an isolated slice on HEAD,
fixing the test harness in the same shot.

---

## 1. THE KIND-MIGRATION (5 zjs kinds → qjs flag-derived model)

### Current HEAD (the redundancy we are removing)

The kind is stored **TWICE** today:
- in the `Slot` union(enum) **tag** (property.zig:134-143), AND
- partially in the shape `Flags` (`accessor: bool`, `deleted: bool`,
  property.zig:7-13) — these bits already exist and are already authoritative for
  `accessor`/`deleted` in fast paths (e.g. `findPropertyProbeTrusted`
  object.zig:9437-9438 reads `flags.deleted`; `findOwnDataPropertyFast`
  object.zig:9446 reads `flags.accessor`).

So `deleted` is written to BOTH places today — `deleteOrdinaryPropertyAt`
object.zig:8941-8947 sets `entry.slot = .deleted` AND `entry_flags.deleted = true`.
This double-bookkeeping is exactly what L2 collapses.

### qjs target (quickjs.c / quickjs.h)

| flags bits (`JS_PROP_TMASK`, quickjs.h:303-307) | meaning              | quickjs.c JSProperty arm (947-963) |
|--------------------------------------------------|----------------------|------------------------------------|
| `JS_PROP_NORMAL  (0<<4)`                          | data property        | `JSValue value`                    |
| `JS_PROP_GETSET  (1<<4)`                          | accessor             | `struct{JSObject *getter,*setter}` |
| `JS_PROP_VARREF  (2<<4)`                          | aliased cell         | `JSVarRef *var_ref`                |
| `JS_PROP_AUTOINIT(3<<4)`                          | lazy builtin         | `struct{uintptr_t realm_and_id; void*opaque}` |

`deleted` in qjs is **not a TMASK kind**: a deleted prop is a `JSShapeProperty`
with `atom == JS_ATOM_NULL` (quickjs.c:972: "JS_ATOM_NULL = free property entry"),
tracked via `deleted_prop_count` and a free-list. The cell value is irrelevant.

### zjs new flag layout (terminal state) — property.zig

Mirror the stash, packed into the existing `u6` shape flag (shape.zig:23
`flags: u6`, already plumbed everywhere as `u6`):

```zig
pub const Kind = enum(u2) { data, accessor, var_ref, auto_init }; // == JS_PROP_TMASK ordering

pub const Flags = packed struct(u6) {
    writable: bool = false,      // bit 0  (JS_PROP_WRITABLE analog)
    enumerable: bool = false,    // bit 1
    configurable: bool = false,  // bit 2
    kind: Kind = .data,          // bits 3-4  (== JS_PROP_TMASK >> 4, two bits)
    deleted: bool = false,       // bit 5
    // helper ctors: data/accessorFlags/varRef/autoInit/withKind/asDeleted
    // predicates: isData/isAccessor/isVarRef/isAutoInit
};
```

Discriminator moves: the `Slot` union(enum) tag is **deleted**; the kind now lives
in `Flags.kind` on the **shape** (read via `self.propFlagsAt(index)`,
object.zig:9392-9393 — already the single chokepoint). `Flags.accessor: bool`
(today) is subsumed by `kind == .accessor`; keep an `isAccessor()` predicate so the
~12 existing `flags.accessor` readers (object.zig:7188, 7690, 7702, 8719, 8945,
9446, 9456; property_ic.zig:127, 142, 466; call_runtime.zig:3576, 3592) change to
`flags.isAccessor()` instead of a raw field.

### Handling `deleted` (no flag-vs-sentinel ambiguity)

`deleted` stays a **flag bit** (`Flags.deleted`), NOT a kind and NOT a Slot arm.
- A deleted entry keeps its shape prop (zjs does NOT compact, matching qjs's
  free-property model: `markPropertyDeleted` shape.zig:339-345 just sets flags +
  bumps `deleted_prop_count`).
- Its value cell becomes a harmless `.{ .data = JSValue.undefinedValue() }` (the old
  `entry.slot = .deleted` site object.zig:8942 → `entry.slot = .{ .data =
  JSValue.undefinedValue() }`). Because lookups already gate on `flags.deleted`
  (findProperty object.zig:9475, findPropertyProbeTrusted object.zig:9438,
  existsOwnProperty object.zig:7000), a deleted entry's slot is never read by kind.
- `Slot.destroy`/`dup` short-circuit on `flags.deleted` (stash property.zig:
  `if (flags.deleted) return;`) so the undefined data value is a no-op to free.

---

## 2. THE 16B UNTAGGED LAYOUT — confirm all arms ≤ 16B

Arm-size audit at HEAD:

| arm        | HEAD type                       | HEAD size | terminal type                 | terminal size |
|------------|---------------------------------|-----------|-------------------------------|---------------|
| `data`     | `JSValue` (value.zig:124 extern)| 16B       | `JSValue`                     | 16B           |
| `accessor` | `Accessor{getter,setter:JSValue}`| **32B**  | `Accessor{getter,setter:?*gc.Header}` | **16B** |
| `auto_init`| `AutoInitRef{rt:*JSRuntime,id:u32}`| 16B     | unchanged                     | 16B           |
| `var_ref`  | `*VarRef`                       | 8B        | unchanged                     | 8B            |
| (tag)      | union(enum) hidden tag          | +8B       | **removed (bare union)**      | 0             |

HEAD `@sizeOf(Slot)` = max-arm 32B (Accessor) + 8B enum tag = **40B**.
Terminal `@sizeOf(Slot)` = max-arm 16B, bare union, no tag = **16B**. ✓

**The ONE arm that exceeds 16B is `accessor`.** Resolution (faithful to qjs
`struct{JSObject *getter,*setter}` = 2 pointers = 16B): store the getter/setter as
**`?*gc.Header`** (object header pointers, `null` == undefined), not `JSValue`.
qjs stores raw `JSObject*` (NULL if undefined) — getters/setters are always objects
(callable) or absent, so a header pointer is faithful and lossless. Add:
```zig
pub const Accessor = struct {
    getter: ?*gc.Header = null,   // qjs JSObject *getter; NULL if undefined
    setter: ?*gc.Header = null,   // qjs JSObject *setter; NULL if undefined
    pub fn getterValue(self) JSValue { return if (self.getter)|h| .object(h) else .undefinedValue(); }
    pub fn setterValue(self) JSValue { ... }
    pub fn fromOwnedValues(g, s) Accessor { ... }      // asserts isObject()/isUndefined()
    pub fn fromBorrowedValues(g, s) Accessor { ... }    // +retain
    pub fn retain/destroy/dup(...)                       // refcount on the 0-2 headers
    pub fn syncGetterFromVisitedValue(self,v) void { self.getter = ...; }  // GC bridge
    pub fn syncSetterFromVisitedValue(self,v) void { ... }
};
```
(This is exactly the stash's `Accessor`, property.zig stash lines 95-156 — reuse it.)

### Zig encoding decision: **bare `union` (NOT `extern union`, NOT `[16]u8`)**

- `union { data: JSValue, accessor: Accessor, auto_init: AutoInitRef, var_ref: *VarRef }`
  with no enum tag. Field access is by-name (`slot.data`, `slot.accessor`) — Zig
  allows reading any arm of a bare union without a tag check.
- In ReleaseFast/ReleaseSmall the bare union is exactly 16B (no tag). Assert it
  there only (stash's comptime guard):
  ```zig
  comptime { const m = @import("builtin").mode;
      if (m == .ReleaseFast or m == .ReleaseSmall) std.debug.assert(@sizeOf(Slot) == 16); }
  ```
- Under Debug/ReleaseSafe Zig adds a hidden safety tag (so accessing a non-active
  arm panics). This is **desirable** — it catches kind/flag desync during the unit +
  force-GC gate before it ever reaches ReleaseFast. The 16B win is realized in the
  shipping build; the safety net stays in test builds. (Do NOT use `extern union`
  to force 16B in Debug — that throws away the safety tag that catches the exact
  bug class that stalled codex.)
- Reject the `[16]u8 + typed accessors` option: it defeats Zig's type system and the
  safety tag, and the by-name union already gives the faithful representation.

`@sizeOf(Object)` is UNAFFECTED — `properties: []property.Entry` is a heap slice
(object.zig:1160). Only the per-property heap allocation shrinks 40→16B (2.5×).
`Object.post_a_object_size_baseline = 192` (object.zig:2137) is unchanged.

---

## 3. EXHAUSTIVE CASCADE AUDIT (every construct / pattern-match site @ HEAD)

Two mechanical breakages everywhere:
- **(i)** any `switch (entry.slot)` / `slot.X` that relied on the tag must derive
  kind first: `const flags = self.propFlagsAt(index); switch (flags.kind) {...}`.
- **(ii)** any `entry.slot == .deleted` / `== .var_ref` / `== .auto_init` **tag
  comparison** (illegal on a bare union) must become `flags.deleted` /
  `flags.kind == .var_ref` / `flags.isAutoInit()`.
- **(iii)** any `entry.slot = .deleted` (tag-only construction) →
  `entry.slot = .{ .data = JSValue.undefinedValue() }` + set `flags.deleted`.
- **(iv)** `Slot.destroy`/`Slot.dup` callers must pass `flags`.

### src/core/property.zig — the definition (REWRITE)
- `Flags` (7-38): add `Kind`, repack as §1.
- `Accessor` (40-43): → 2× `?*gc.Header` as §2.
- `Slot` (134-185): drop `.deleted` arm; bare union; `destroy(self, flags, rt)`,
  `dup(self, flags)`, `dataValueForFastPath` (145-148) keep but gate on flags
  (callers pass kind) — note this is the HEAD fast-path accessor.
- **PRESERVE** the var_ref cycle guard (162-165) — the stash dropped it (§0-C).
- `Entry` (207-209): default `slot = .{ .data = JSValue.undefinedValue() }` (was
  `.deleted`).

### src/core/descriptor.zig — `fromSlot` (53-91)
`switch (slot)` → `switch (flags.kind)`; `.deleted` arm folds into a
`if (flags.deleted) return .{};` prelude. (Reuse stash descriptor.zig verbatim,
minus its accessor `.getter`→`.getterValue()` already present there.)

### src/core/object.zig — THE BULK (53 property-slot sites). Enumerate:
- GC trace visitor (6072-6092): `switch(entry.slot)` over an iterated
  `self.properties` — **MOST DANGEROUS**. It takes `&stored_accessor.getter` as a
  mutable `*JSValue` (6079-6080); with `?*gc.Header` that pointer no longer exists.
  Rewrite per stash (object.zig stash 6024-6044): derive `flags = propFlagsAt(index)`,
  `switch(flags.kind)`, and for accessor use the getterValue→visit→sync round trip
  (`var g = entry.slot.accessor.getterValue(); visit(&g);
  entry.slot.accessor.syncGetterFromVisitedValue(g);`). **Loop must carry `index`**
  (currently `for (self.properties)` — needs `0..` to index `propFlagsAt`).
- `countSlotFunctionBytecodeRefs` (6802-6808): `switch(slot)` → needs flags param.
- `getOwnProperty` (6856-6910): reads `entry.slot == .auto_init` (6881),
  `entry.slot.auto_init` (6882), `after_materialize.slot == .auto_init` (6891),
  `Descriptor.fromSlot(...,entry.slot)` (6908-6910). All flag-derive.
- `existsOwnProperty` (6975-7004): `entry.slot == .var_ref` (7003),
  `entry.slot.var_ref` (7004).
- `getProperty` (7045-7069): `switch(entry.slot)` (7051) — the hot read path.
- materializeAutoInit family (7090-7202): writes `self.properties[index].slot =
  .{ .data = ... }` (7181), `.{ .accessor = ... }` (7189),
  `entry.slot.auto_init` (7196), `self.properties[index].slot == .auto_init` (7199).
  These WRITES must also flip `flags.kind` on the shape in lockstep
  (data→`.data`, accessor→`.accessor`) — see §4 discipline.
- `getOwnDataPropertyValue/Lookup/ValueAt` (7682-7720): three `switch(...slot)`
  (7691, 7703, 7716).
- `replaceAutoInitProperty...` (8048-8070): `self.properties[index].slot !=
  .auto_init` (8065), writes `.{ .auto_init = ... }` (8070).
- `defineEmptyArray...` (8273-8277): writes `.{ .auto_init = ... }` (8277).
- `setProperty` (8660-8725): `entry.slot.accessor.setter` (8687),
  `entry.slot == .var_ref` (8692-8693), `inherited.slot.accessor` (8719),
  writes `entry.slot = .{ .data = ... }` (8703).
- `setOwnWritableDataProperty` (8728-8761): `switch(entry.slot)` (8741), writes
  (8761).
- `setOwnDataPropertyAtForLexicalSync[Owned]` (8769-8816): two `switch(entry.slot)`
  (8775, 8807).
- `setOrDefineOwnDataPropertyForSimpleSet` (8820-8849): `switch(entry.slot)` (8833),
  write (8849).
- `deleteOrdinaryPropertyAt` (8937-8956): `entry.slot = .deleted` (8942) →
  `.{ .data = undefined }`; flags already set (8943-8947). **Canonical (iii) site.**
- `appendPreparedPropertyEntry` (9257-9306): `self.properties[old_len] = .{ .slot =
  slot }` (9282), `destroyPropertySlot(rt, atom, ...slot)` (9261, 9287) — now needs
  flags; `self.properties[old_len] = .{}` (9288) default-init OK.
- `replaceProperty` (9358-9382): `mergeDescriptor(propFlagsAt, ...slot, desc)`
  (9360), `self.properties[index].slot == .var_ref` (9362),
  `self.properties[index].slot.var_ref` (9363), write `.{ .slot = next_slot }`
  (9377), `destroyPropertySlot(...old_slot)` (9380).
- `findOwnDataPropertyFast` (9443-9451) & `findWritableOwnDataPropertyFast`
  (9453-9461): `switch(...slot)` (9447, 9458) — hot.
- `convertDenseArrayElementsToSparseProperties` (9198-9211): **L3 COUPLING** (§6) —
  builds `.data` slots from dense elements via `addProperty`. No tag read, but it
  constructs slots; safe under new model (goes through slotFromDescriptor).
- `flagsFromDescriptor` (9576-9582) & `slotFromDescriptor` (9584-9593): construct
  flags+slot from a Descriptor. `flagsFromDescriptor` must now also set
  `Flags.kind` (data/accessor); `slotFromDescriptor` builds the matching arm.
  **This pair is the single canonical flags⇄slot constructor — keep them paired.**
- `destroyPropertySlot` (9604-9616): signature gains `flags`; inner
  `switch(slot){.data...}` (9606-9613) for the Private_brand special-case stays but
  guards on `flags.kind == .data`; trailing `slot.destroy(rt)` → `slot.destroy(flags,
  rt)`.
- `isCompatible` (9753-9780): already takes `(current_flags, current_slot, desc)` —
  good. Replace `current_slot != .accessor` (9775), `current_slot.accessor` (9776-7),
  and `switch(current_slot)` (9766) with flag-derived reads.
- `mergeDescriptor` (9782-9834): already takes `(current_flags, current_slot, desc)`.
  Three `switch(current_slot)` (9784, 9812, 9822/9826) → `switch(current_flags.kind)`.
- Misc tag-reads: 1053, 1298, 2127, 5359 (`.var_ref =>`), 1902/1929 + registry-style
  auto_init handling, 1693 (`destroyPropertySlot(... entry.slot)` in destructor loop
  — needs flags), 9094 (`isCompatible(propFlagsAt, ...slot, desc)`).

### src/exec/property_ic.zig (the inline cache — hot)
- `installOwnDataIc...` lookup (124-153): `switch(object.properties[index].slot)`
  (128, 145); reads `prop_flags.accessor`/`.deleted` (126-127) — keep as predicates.
- `fastOwnOrdinaryDataPropertyLookupForObject` (464-472): `propFlagsAt(index).accessor`
  (466) + `switch(...slot)` (467-471). The `.deleted => .missing` arm must move to a
  `flags.deleted` check (deleted is no longer a slot arm).
- `DataSlot{ entry: *core.property.Entry }` (63-64) — pointer to entry; fine, but
  consumers reading `entry.slot` must have flags in hand.

### src/exec/call_runtime.zig (global var/lexical var_ref machinery)
- `globalLexicalCell` (3564-3572): `switch(env.properties[index].slot){.var_ref...}`
  → `if (flags.kind == .var_ref)`.
- `globalObjectVarRefCell` (3576-3582), `ensureGlobalObjectVarRefCell` (3596...),
  and 3663/3725/3770: same `.var_ref` tag-reads → flag-derive. These already read
  `propFlagsAt` (3576, 3592) so flags are in scope.

### src/exec/vm_property_globals.zig
- 213 (`switch(global.properties[index].slot)`), 237 (`switch(entry.slot)`),
  241-242 (`old_slot = entry.slot; entry.slot = .{ .data = value }`), 474, 954, 959.
  All flag-derive; the write at 242 must keep shape `kind == .data` consistent.

### src/exec/object_ops.zig
- 1123 (`switch(proto.properties[property_index].slot)`), 3017
  (`switch(object.properties[index].slot)`). Flag-derive.

### src/exec/vm_property.zig
- 6 slot-tag reads (per grep) — flag-derive. (Mostly accessor/var_ref dispatch.)

### src/builtins/registry.zig (auto-init tagging during builtin install)
- `bindAutoInitNativeRecordByAtom` (1245), `tagAutoInitArrayBuiltinByAtom` (1261),
  and 1283/1305/1327/1347/1369/1391/2862: all `switch(entry.slot){.auto_init|.data}`
  — flag-derive (`flags.isAutoInit()` then read `entry.slot.auto_init`). 1070 reads
  `entry.slot` into a helper.
  (Note: registry's `JSCFunctionListEntry`-style **table** `.slot` fields are a
  DIFFERENT type — not property.Entry — and are out of scope.)

### src/builtins/json.zig
- 2 slot reads — flag-derive.

### src/exec/zjs_vm.zig
- 1241 `reg_sp[0] = slot.dup()` — confirm whether this `slot` is a property.Slot
  (needs flags) or a frame value (out of scope); inspect at implement-time.

### src/binding/ffi.zig
- grep flagged it; the property-slot reads there must flag-derive (verify scope at
  implement-time — likely descriptor-level, low risk).

### NOT in the cascade (filename false-positives — do NOT touch for L2):
- `src/exec/slot_ops.zig` — frame local/arg/var_ref **stack** slots, not property
  cells.
- All `Object.xxxSlot()` inline-payload accessors (object.zig 1453-3816) — these are
  `JSObject.u`-style class payload fields, unrelated to property.Entry.

**Cascade scale:** ~53 sites in object.zig + ~30 in property_ic/call_runtime/
vm_property*/object_ops + ~12 in registry/json + the test harness. Call it
**~110-130 edited sites across ~12 source files + 4 test files**, but ALL reducible
to the 4 mechanical rules above once the typed API (§4) lands.

---

## 4. WHY IT STALLED → THE AVOID-THE-STALL DISCIPLINE

Root failure (§0): tag→flag derivation scattered across ~120 call sites, each
re-deriving kind by hand, on a divergent base, with a shared test harness that
snapshots slots and flags into separate arrays. Discipline to converge in one shot:

1. **One flag-derivation chokepoint.** `propFlagsAt(index)` (object.zig:9392) is
   already the sole reader of `shape_ref.props[index].flags`. Every kind decision
   must go through it. Add a thin typed API on `Object` so call sites NEVER touch the
   raw union by tag:
   - `fn propKindAt(self, index) Kind` → `propFlagsAt(index).kind`
   - `fn propSlotAt(self, index) *property.Entry` (raw pointer for writers)
   - convenience: `fn asDataAt(index) ?JSValue`, `fn asAccessorAt(index) ?Accessor`,
     `fn isAutoInitAt(index) bool`, `fn isVarRefAt(index) bool` — each does the
     `propFlagsAt` + arm read internally, returns `null` on mismatch.
   Call sites switch on `propKindAt(index)` or call the typed getter; they never
   write a bare `switch (entry.slot)` again.

2. **Slot writes are paired with flag writes — always — through ONE function.**
   `slotFromDescriptor` + `flagsFromDescriptor` (object.zig:9576-9593) are already the
   paired constructor. Add the symmetric **mutator** that updates an existing entry:
   `fn setEntryKindAndSlot(self, rt, index, new_flags, new_slot)` which
   `destroyPropertySlot(old_flags, old_slot)` → writes slot → writes
   `rt.shapes.updatePropertyFlags(...)`. Funnel materializeAutoInit (7181/7189),
   setProperty (8703), the var_ref→data promotion (9367-9369), and replaceProperty
   (9377-9379) through it. This guarantees kind-flag and slot-arm never desync (the
   Debug safety tag then catches any stray un-funneled write immediately).

3. **`Slot.destroy(flags, rt)` / `Slot.dup(flags)` take flags by signature.** No
   flag-less overload exists, so the compiler forces every caller to have the kind.
   This is what flushes out the test-harness sites (exec.zig:460/519/529/533) at
   compile time rather than at runtime.

4. **Fix the test harness in the SAME shot, by interleaving its two passes.**
   `src/tests/exec.zig`:
   - Snapshot: still snapshot slot (458-461) and shape props (463-470) separately,
     but when restoring, **pair them**: dup the slot using
     `baseline_shape_props[idx].flags` (the kind), not a flag-less `slot.dup()`.
   - line 520 `entry.slot = .deleted` → `entry.slot = .{ .data =
     JSValue.undefinedValue() }` (flags already restored by `restorePropertyLayout`
     at 537).
   - Provide a test-only helper `core.property.Entry.dupWithFlags(slot, flags)` /
     `destroyWithFlags(slot, flags, rt)` so the harness reads the flags array it
     already has. The harness already keeps `shared_engine_baseline_shape_props`
     (flags) right next to `shared_engine_baseline_properties` (slots) — they index
     1:1, so pairing is a one-line change per loop.

5. **Keep `dataValueForFastPath` (property.zig:145) as the hot read.** It is the only
   place the VM peeks a slot without going through propFlagsAt; gate it on
   `flags.kind == .data` at its (single) caller, or pass the already-known flags.

---

## 5. test262 / test-infra RISK

- **Shared exec harness (`src/tests/exec.zig:455-535`)** — THE documented "deep
  test-infra cascade." Slots + flags snapshotted into two parallel arrays, restored
  in two passes; `entry.slot.dup()`/`destroy()` flag-less; `entry.slot = .deleted`.
  All 1226 exec unit tests run through it. Fix per §4-4. **Highest risk.**
- **`src/tests/core.zig`** direct slot reads: `holder.properties[0].slot.data`
  (2589-2623), `holder.properties[0].slot.auto_init` (4205-4392). On a bare union
  these STILL COMPILE (by-name arm access), and the stash kept them verbatim
  (stash core.zig 2596-2631, 4214-4410). **They keep working** — the Debug safety tag
  asserts the arm matches the flags the test set up, which it does. Low risk, but if
  any test reads `.slot.data` on an entry whose flags say accessor/var_ref, it will
  now panic in Debug (previously the union(enum) would also panic — same behavior).
- **Size/GC-accounting tests** (`core.zig` 1775, 3016/3054 `@sizeOf(core.Object)`;
  `post_a_object_size_baseline` 2137): `@sizeOf(Object)` is **unchanged** (Entry is
  heaped, object.zig:1160). `expected_gc_bytes` uses `@sizeOf(Object)+@sizeOf(Shape)`,
  not Entry, so it's unaffected. **No size-baseline churn** (this is a relief — the
  Entry shrink is invisible to the Object-size asserts). The only new assert is the
  ReleaseFast-only `@sizeOf(Slot)==16` in property.zig.
- **gc_stress / oom_cap / builtins tests**: grep found no direct property-slot tag
  reads (builtins.zig:2661 `entries_slot.*[old_len].destroy` is a CollectionEntry,
  not a property Slot). Low risk, but the force-GC gate (1226 force-GC) is where the
  cycle-collector var_ref guard (§0-C) MUST be preserved — re-verify property.zig:163
  guard survives.
- **test262 (0/49775)**: representation-only change; no observable-semantics delta if
  the kind-flag/slot-arm pairing is exact. The risk is a missed write site that
  leaves flags saying `.data` while the slot holds an accessor (or vice-versa) →
  wrong-arm read. The Debug/ReleaseSafe safety tag converts that latent bug into a
  loud panic in the unit+force-GC gate **before** test262 (which runs ReleaseFast),
  which is exactly the safety the `[16]u8`/`extern union` options would throw away.

---

## 6. COUPLING TO L3 (arrays: length + dense elements)

Where L2 and L3 meet:
- **Array `length` is NOT a property slot** — it's inline `array_count: u32`
  (object.zig:1162, `arrayLengthSlot` 2163-2165, `setArrayLength` 2172-2178). So L3's
  length handling does **not** touch the property cell representation. No coupling
  there.
- **Dense → sparse conversion IS the meeting point.**
  `convertDenseArrayElementsToSparseProperties` (object.zig:9198-9211) walks
  `arrayElements()` and calls `addProperty(rt, atom, Descriptor.data(stored, ...))`
  for each — i.e. it **creates `.data` property slots** from dense elements. It goes
  through `slotFromDescriptor`/`flagsFromDescriptor` (the §4-2 paired constructor),
  so once L2's constructor sets `Flags.kind = .data` correctly, this path is
  automatically correct. It is called from `deleteProperty` (8972),
  `defineDenseArrayDataProperty`, and the sparse-define paths.
- **Reverse coupling (L3 touching L2):** if L3 changes dense-element storage
  (e.g. `array_values: [*]JSValue`, object.zig:1161) or adds a length-as-VARREF
  exotic, it would route through the SAME `addProperty`/`slotFromDescriptor` and the
  SAME `propFlagsAt`-derived kind. L3 does not store length in a slot today, and
  there is no sparse-conversion that bypasses `slotFromDescriptor`.

**Sequencing verdict: L3-first is SAFE for L2.** L3 only ever *constructs* `.data`
slots via the paired constructor; it never pattern-matches a slot by tag and never
reads accessor/var_ref/auto_init arms. So whether dense elements live inline or are
sparse-converted, L2's untagged-union change is orthogonal: L2 changes how a slot is
*represented and discriminated*, L3 changes *which* slots exist and *when* dense
storage is used. The only shared code is `convertDenseArrayElementsToSparseProperties`
+ `slotFromDescriptor`, and both are kind-agnostic constructors. Doing L3 first leaves
those constructors intact; L2 then rewrites their internals once. (And vice-versa:
L2-first would not disturb L3's dense path either — they are genuinely decoupled
except through the one constructor.)

---

## 7. ONE-SHOT vs STAGED VERDICT

**Verdict: ONE-SHOT is feasible AND required — but only with the §4 typed-API
discipline and the test-harness fix in the same commit.** No flag-gated half-state.

Reasoning:
- The representation is binary: a tagged union and an untagged-flag-derived union
  cannot coexist behind a flag without keeping BOTH the tag and the kind-flag in
  lockstep everywhere — which is *more* code than just doing it, and is precisely the
  double-bookkeeping (`deleted` in slot AND flags) we are removing. A staged/flagged
  L2 would be self-contradictory.
- The cascade (~120 sites) is large but **100% mechanical** under the 4 rules, and
  the stash proves the design compiles and runs — codex got the engine code
  essentially done; it stalled on *packaging* (mega-commit on a stale base) and the
  *test harness*, not on any irreducible design problem.
- The Zig safety tag (Debug/ReleaseSafe bare-union check) turns the one residual risk
  (a missed kind/slot write-pairing) into a loud, localizable panic in the
  unit+force-GC gate, so convergence is observable rather than the silent
  "messy state" of the stash.
- Codex's stall does NOT argue for staging; it argues for (a) isolating L2 from the
  s1 mega-commit, (b) basing on current HEAD, (c) landing the typed API + harness fix
  atomically. That is a clean one-shot on a fresh worktree.

**Recommended execution:** fresh worktree off HEAD `d3afe1e`; reuse the stash's
property.zig/descriptor.zig representation (porting forward the var_ref cycle guard,
§0-C); add the §4 typed API to Object; mechanically convert the ~120 sites; fix
`src/tests/exec.zig` harness in the same shot; gate with full test262 (0/49775) +
1226 unit + 1226 force-GC. Single commit.

---

## APPENDIX — verified anchors at HEAD (d3afe1e)

- qjs `JSProperty` union: quickjs.c:947-963 · `JSShapeProperty.flags` quickjs.c:968-972
- qjs TMASK: quickjs.h:303-307 (`NORMAL 0<<4 / GETSET 1<<4 / VARREF 2<<4 / AUTOINIT 3<<4`)
- qjs `JS_ATOM_NULL = free property entry`: quickjs.c:972
- zjs `Flags` packed(u6): property.zig:7-38 · `Accessor` (2×JSValue=32B): property.zig:40-43
- zjs `Slot` union(enum) (40B, tag): property.zig:134-185 · `Entry`: property.zig:207-209
- zjs var_ref destroy cycle guard (PRESERVE): property.zig:162-165
- zjs `JSValue` extern (16B): value.zig:124 · `Object.properties` heap slice: object.zig:1160
- zjs `propFlagsAt`/`propAtomAt` (the chokepoint): object.zig:9387-9394
- zjs `descriptor.fromSlot`: descriptor.zig:53-91
- zjs deleted write (slot+flag dup): object.zig:8941-8947
- zjs `slotFromDescriptor`/`flagsFromDescriptor`: object.zig:9576-9593
- zjs `destroyPropertySlot`/`isCompatible`/`mergeDescriptor`: object.zig:9604/9753/9782
- zjs GC trace slot visitor (most dangerous): object.zig:6072-6092
- zjs dense→sparse (L3 coupling): object.zig:9198-9211 · array length inline: object.zig:1162,2163-2178
- TEST HARNESS cascade: src/tests/exec.zig:455-535 (snapshot 458-470, restore 519-535)
- test direct slot reads (still compile): src/tests/core.zig:2589-2623, 4205-4392
- parked attempt: `git stash show -p stash@{0}` (base da34bc1, 80 files)
