# Floor re-examination (2026-07-05)

Per the `verify-before-floor-claims` discipline: the alloc/string benchmarks
(objalloc 2.63× / objprop 2.68× / template 2.85× / charcode 3.00×) — all WORSE
than fib's 2.02× — were long declared "floor" (distributed per-alloc overhead
irreducible / LLVM layout noise / floor band). A 4-way disassembly re-examination
(workflow `wsxok9keg`) tested each against the discipline: a real floor must come
with a **qjs-side equivalent-cost proof** (read quickjs.c, count its instructions,
show qjs pays the same); otherwise it is a removable deviation.

**Verdict: all four categories partially-bustable to bustable — NONE a real floor.**

## Busted floors (with qjs counter-proof) + landed knives

### F1 — per-alloc GC page-state (`08f6189`, objalloc 2.63→2.42×)
`refreshSpacePageState` (gc.zig) recomputed ~8 derived page-accounting fields
(empty/full/allocating/decommitted/evacuation-candidate page counts + fragmentation)
for old_space AND large_space **on every alloc AND every free** = 134 insns /
16 shift-mul / 11 stores, 9.67% of objalloc. **qjs proof:** js_def_malloc
(quickjs.c:2160) updates only `malloc_count++` + `malloc_size+=` (2 scalars);
add_gc_object (6540) is mark+type+list_add_tail; js_trigger_gc (1780) is one
threshold compare — qjs has NO per-alloc page-count/fragmentation fields at all.
This was pure zjs eager-consistency. Fix: lazy — drop the refresh from
recordSpaceAlloc/recordSpaceFree; consumers recompute on read (sweepSomePages
gained a refresh it was missing); spacePageStateMatches recomputes-on-read.
Oracle: force-GC alloc-stress (objalloc/array/churn) byte-identical to qjs.

### F2 — property-read union spill (`1f6eef7`, objprop 2.68→2.51×)
op_get_field was 26% of objprop, dominated by `findOwnDataValueFast`'s 3-way
tagged union `{value,missing,slow}` — spilled to stack (str q0 + strb tag +
reload, double 16B round-trip), keeping the hit value off registers and forcing
requiresRefCount into a spilled `1<<tag&mask` bit-test. **qjs proof:** quickjs.c:
19131 `val = JS_DupValue(pr->u.value)` keeps the found value in a register, no
union; JS_DupValue (quickjs.h:707) is one `(unsigned)tag>=JS_TAG_FIRST` compare.
Fix: return `?JSValue` + `slow:*bool` second channel (non-null=value / null+!slow=
missing / null+slow=cold) — 3-outcome semantics preserved exactly.

### F3 — string concat intermediate buffer (`578c6e9`, template 2.85→2.55×)
`qjsStringConcat` accumulated into an intermediate `std.ArrayList(u8)` then copied
into the result — an extra alloc/free + full-length memcpy. **qjs proof:**
JS_ConcatString1 (quickjs.c:4646) does one js_alloc_string + per-part memcpy
(single alloc). Fix: common flat-latin1 path is single-alloc measure-then-copy
(createLatin1Parts); wide/rope/symbol fall back to the ArrayList path.

## Remaining bustable knives (not yet landed)

- **string_prototype_realm_slot** (charcode 3.00×, the worst): charcode's
  `constructorPrototypeFromGlobalAtom` is 13.5% — three findProperty walks per
  string method call (global → String → .prototype). qjs uses
  `ctx->class_proto[JS_CLASS_STRING]` direct pointer (7995). Cache String/Number/
  Boolean.prototype in RealmValueSlot like array_prototype — and it is MORE
  spec-correct (primitive method lookup uses intrinsic %String.prototype%, not
  globalThis.String).
- **gate-arrayindex-in-defineOrdinaryOwnProperty** (objalloc): arrayIndexFromAtom
  called unconditionally per field but result only used for dense arrays; gate on
  is_array (qjs JS_CreateProperty 10137 `if(p->is_exotic)`).
- **fast-reject-nonindex-in-arrayIndexFromAtom**, **trim-per-alloc-heap-counters**
  (objalloc secondary).

## Not a floor to bust elsewhere / dropped
- fn_array 2.34× is a loop/arith frontier (binaryVm 36%, no gc/shape symbols),
  not the alloc sublayer.
- Shape append/transition is already qjs-form (add_shape_property ≈ appendProperty,
  deliberate per bd50aeb/audit-2026-07-02).
- The per-value JSValue.free opcode_profile/gc.phase guards are real zjs-only
  instructions but well-predicted (near-zero time) and shared engine-wide
  (correctness-coupled) — not a scoped win.

## Method note
The durable lesson: "floor" claims must be re-verified per category by
disassembly + a qjs equivalent-cost proof, never accepted from memory/doc
restatement. The biggest directional finding of the whole alignment program:
the call machinery (fib 2.02×) was polished for many rounds while the alloc/
string categories (2.4-3.0×) — the actual worst — sat behind unverified floor
claims.
