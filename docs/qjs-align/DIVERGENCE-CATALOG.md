# qjs faithful-divergence catalog (2026-06-25 sweep)

Source: a 6-category measurement workflow (`qjs-divergence-sweep`, 28 faithful
divergences found) + manual verification. Ratios are `zjs_instructions /
qjs_instructions` on targeted loops, **measured on a clean `zig build zjs`
binary** (see the benchmarking-hazard note in `HANDOVER-perf-round2.md` — gate
builds overwrite `zig-out/bin/zjs` with a force-GC binary that inflates
allocation benchmarks 100×).

Anything not listed as a *structural divergence* is broad LLVM-vs-gcc per-opcode
tax (~2–2.5×) and is **not** a faithful target.

## ✅ Shipped this round (each: test262 0/49775 + 1223 unit + 1223 force-GC)

| slice | commit | effect |
|---|---|---|
| method-dispatch array cascade hoist | `b20d5b4` | `o.m()` 4.43×→2.30×, `p.step()` 4.85×→2.74× |
| lazy `function.prototype` (autoinit) | `18a2610` | closure-per-iter 5.68×→3.90× (cycle collector gone) |
| `typeof` interned-atom result | `40b928f` | `typeof===` 3.45×→2.27× |
| inline float64 arith fast path | `a7b7256` | float add/sub/mul/div/mod 3.4–5.1×→2.3–2.5× (+ Math loops) |
| Array indexOf/includes/lastIndexOf dense scan | `69e2183` | indexOf 13.56×→1.35×, includes 5.81×→0.94× |
| iterator-result predefined value/done atoms | `9e4029e` | per-step intern dropped (generators/iterators) |
| instanceof ordinary check (no Descriptor, direct proto walk) | `d3edbc6` | 3.64×→3.39× (residual is broad tax — see note) |
| string-method resolution → comptime atom-id bitset | `e30ecef` | per-access name+eql chain dropped (charCodeAt 3.63×→3.36×) |
| **Map/Set for-of result-object-free fast step** | `be06930` | **Map.values 21.22×→1.78×, Set 19.8×→1.81×** |
| Map/Set for-of entries (key_value) extension | `d65b42b` | Map entries 6.63×→4.25× |
| string indexOf — flat slice once + first-char skip | `bfae525` | indexOf/includes/split 5.78×→2.45× |

## ⏭ Tractable next (bounded, localized — good follow-ups)

- **cloneShape single-block copy** (~~4.5×~~): ATTEMPTED + REVERTED. The verbatim-copy
  fast path (memcpy props + hash, re-dup atoms only) was implemented and verified correct
  (test262 0/49775), but showed **zero measurable benefit** — the clone is always a tiny
  fraction of any realistic delete/defineProperty/setProto loop; the 4.5× is dominated by
  object *creation* (the property adds), not cloneShape. Not worth the branch complexity.
  Re-attempt only if a profile shows cloneShape as a real bottleneck (e.g. delete-churn on
  large shared shapes). The faithful target stands (qjs js_clone_shape quickjs.c:5268).
- **Existence/enumerable-only own-property probe** (hasOwnProperty 2.44×, Object.keys/
  values/entries 1.81×, Object.assign 2.92×). These materialize a full Descriptor
  (DupValue + destroy) per key when only "does it exist" / "is it enumerable" is needed.
  qjs uses a NULL-desc existence branch (quickjs.c:8854) and inline enumerable filtering
  (quickjs.c:8629). Fix: a shape-flag probe that returns presence/enumerability without
  building a Descriptor. (Object.assign also calls qjsObjectAssignKeys twice — collapse to
  one ENUM_ONLY walk, quickjs.c:16942.) zjs anchors: object.zig:618/638, object_ops.zig:5016/5055.
- **String-method name resolution → atom identity** (3.63×; every `s.method()`).
  `isStandardStringPrototypeMethodAtom` (string_ops.zig:4652) does `name()` + a 33-way
  `std.mem.eql` chain per access. Fix: compare the interned atom id by integer identity
  (precompute the String.prototype method atom ids once), not name bytes.
- **String indexOf flat slice + first-char skip** (5.78×): SHIPPED `bfae525` (→2.45×).
  The `resolveData()`-once + first-char-skip pattern is reusable for the remaining string
  searches: `stringLastIndexOfUnits` (the reverse loop still uses per-char `codeUnitAt`),
  startsWith/endsWith, and any `codeUnitAt`-per-char scan.
- **String toUpperCase/toLowerCase narrow flat buffer** (3.1×). Decodes per-char via
  resolveData (now reusable to fix) AND builds a UTF-16 buffer even for ASCII. qjs
  (quickjs.c:46510) uses a pre-sized narrow buffer that widens only on a >0xFF unit. Fix:
  resolve source once (as indexOf now does) + accumulate latin1, widening lazily.

## 🔶 Medium-deep (need new fast-path machinery, but self-contained)

- **Built-in-iterator for-of fast path** — Map/Set key/value SHIPPED (`be06930`,
  `fastMapSetForOfNext`). REMAINING: (a) Map `entries` / key_value kind (6.6×) still builds a
  pair array via the generic path — extend the fast step with a reserve-then-build-pair (the
  pair components are GC-safe via the collection; reserve the 2 stack slots BEFORE the
  createArray so no GC sits between pair creation and push). (b) **generator for-of** (17.8×):
  the generator `next` resume builds a result object AND the generator frame is re-allocated
  per step — the result-object part could get a similar fast step, but the frame realloc is
  the deep frame frontier. qjs `JS_IteratorNext2` quickjs.c:16548.
- **Array.from / map / filter / slice fast-array output & source** (Array.from 15.5×,
  map 2.2×, filter 4.0×, slice 3.0×). Output arrays are built with per-element
  `defineOwnProperty(atomFromUInt32(i))` (shape append per element); qjs writes dense fast
  arrays (`add_fast_array_element`). Fix: pre-size a fast array of known length and write
  dense slots. (filter/forEach also carry the deep per-callback frame tax — see below.)

## 🟥 Deep frontiers (multi-session; partly NOT faithfully eliminable)

- **`new Array(n)` born slow** (19.5× and a force-multiplier for fill/slice/indexed/indexOf
  on the result). qjs `set_array_length` (quickjs.c:9447) keeps `fast_array` with
  `length > count` tail holes. **zjs FUSES `array_count == length`** (object.zig:2163
  `arrayLength()` returns `array_count`; no separate length field) — so `new Array(n)` cannot
  be fast without the **array count/length split** (the deferred high-risk C.3 item: every
  reader of array_count/length must treat `[count,length)` as holes). The sweep agent rated
  this "small" — it is NOT; it is the count/length split. This split also unblocks the
  map/filter/slice fast-array output above.
- **Frame-model rewrite** (forEach 5.6×, `new ClassC` 3.42×, filter 4.0× — all per-callback /
  per-constructor frame alloc+teardown: `runWithArgsState` + `Frame.deinit` churn). qjs uses a
  single-alloca borrowed frame (JS_CallInternal). The documented multi-week frontier
  (`CALL-MACHINERY-QJS.md`, `FRAME-STRUCTURAL-ALIGN.md`); also gates fib 3.6×.
- **String representation** (per-char `resolveData` indirection underlies indexOf/toUpperCase/
  charCodeAt). A flat-slice-once discipline (or a hot flat cache) would help a whole category.
- **`s.replace` primitive-string boxing** (36.4×, grows with string length). The sweep agent
  rated this "small" (drop the per-index materialization loop in `primitiveObjectForAccess`,
  object_ops.zig:4702) — but that helper feeds `Object.keys/values/entries("abc")` etc., and
  zjs has NO exotic `[[OwnPropertyKeys]]` for string wrappers, so the materialized index
  properties ARE load-bearing for enumeration. A faithful fix needs exotic ownKeys for
  string-wrapper objects first (then the loop can go), OR a separate non-enumerating box for
  the method-call path. NOT a quick win.
- **Broad dispatch tax** (~2–2.5× residual everywhere): jump-table-base not hoisted +
  LLVM-vs-gcc op-body codegen. Not a structural divergence (`DISPATCH-TAX-FINDINGS.md`).

## Notes / corrections to the sweep agent's tractability calls

- `new Array(n)` (#1) and `s.replace` boxing (#7) were rated "small" but both depend on a
  deeper change (count/length split; string-wrapper exotic ownKeys). Verified before acting.
- instanceof's `@@hasInstance` GetProperty+call (the bulk of its 3.64×) is **broad tax**: qjs
  `JS_IsInstanceOf` (quickjs.c:8133) also does `GetProperty(@@hasInstance)` + `JS_CallFree` of
  the default. Only the inner `JS_OrdinaryIsInstanceOf` was a real divergence (now aligned).
