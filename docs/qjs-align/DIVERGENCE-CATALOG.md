# qjs faithful-divergence catalog (2026-06-25 sweep)

Source: a 6-category measurement workflow (`qjs-divergence-sweep`, 28 faithful
divergences found) + manual verification. Ratios are `zjs_instructions /
qjs_instructions` on targeted loops, **measured on a clean `zig build zjs`
binary** (see the benchmarking-hazard note in `HANDOVER-perf-round2.md` — gate
builds overwrite `zig-out/bin/zjs` with a force-GC binary that inflates
allocation benchmarks 100×).

Anything not listed as a *structural divergence* is broad LLVM-vs-gcc per-opcode
tax (~2–2.5×) and is **not** a faithful target.

## 🧭 Next-direction survey (2026-06-25, `qjs-next-direction-survey`) — ranked roadmap

A second data-driven survey (re-measure + scope/ROI audit of each candidate) ranked the
remaining work and **inverted the going-in assumption** (count/length split was NOT the best ROI).
Ranked by `unlock × commonality / (risk × effort)`:

1. **String resolve-once cleanups — DONE** (`bfae525` indexOf/includes/split, `bd263cc`
   startsWith/endsWith/lastIndexOf, `77005ac` toUpperCase/toLowerCase resolve-once + narrow latin1
   buffer 3×→1.69×). Bucket complete. **Bonus** (`5da7105`): surfaced + fixed a pre-existing broad
   bug — `printString` (call.zig:3298) emitted latin1 bytes 0x80–0xFF raw, so `console.log("café")`
   / `String.fromCharCode(0xC9)` mis-printed everywhere; now UTF-8-encoded (matches qjs).
2. **Object descriptor-materialization skips** (hasOwnProperty 4.13×, Object.values 2.45×,
   entries 1.64× — all common). Materialize a full Descriptor (DupValue+destroy) per key when
   only existence/enumerability is needed. *Medium*, NOT a quick swap: `Object.hasOwnProperty`
   (object.zig:6890) is incomplete (misses array `length`, typed-array/string indices, module
   namespace) — needs an existence-only `getOwnProperty` variant covering every kind. qjs NULL-desc
   existence quickjs.c:8854, ENUM_ONLY inline quickjs.c:8629.
3. **Array count/length split — CONFIRMED BOUNDED** (3–4 days, 17 readers / 11 need hole-handling,
   all localized to object.zig/array_ops.zig/builtins/exec; flag-gated 5-stage plan with a staged
   reader audit). Unlocks `new Array(n)` 5–10× (375M→150M) + the map/filter/slice/Array.from
   dense-output cluster. Real MEDIUM risk (hole semantics in a[i]/for-in/Object.keys/length-write/
   JSON; test262 Array holes/sparse/length-write). The single biggest *bounded* structural unlock.
4. **Frame incremental gates — Slice A + C SHIPPED (round-4)**, Slice D deferred, B low-priority.
   `docs/qjs-align/HANDOVER-frame-incremental.md`. **Slice A** teardown gate for no-eval frames
   (`5545cef`, fib 26.16B→25.35B, *bigger than the ~437M estimate*). **Slice C** var_refs borrow
   (`698824e`, fib 25.35B→24.88B, gated on `simple_frame && !has_eval_call && global_vars.len==0 &&
   all-cells`; a 5-agent adversarial workflow proved the naive borrow UNSAFE on 4 paths first — see
   round-4 handover). **Slice D deferred** (cur_func is a MOVE not a dup = no refcount win; the
   plain-undefined-`this` fast path already skips coerceCallThis for fib → marginal fib payoff +
   this-coercion risk). The **bulk** (pushFrame 23% + teardown 7% = ~30% of fib) still needs the
   monolithic frame collapse (`FRAME-STRUCTURAL-ALIGN.md`) — fib is 3.46× after A+C.
5. **Map/Set per-op (get/set 7.63×, add/has 6.3×)** — NOT a hash-table gap (collection.zig already
   uses open-chained hashing); the cost is the general **call path** to reach the native op, so this
   is coupled to the frame/call-machinery, not a standalone fix.
6. **Regex `regex.test` 12.04× — the single largest raw gap** (4.8B vs qjs 404M), missed by the
   first sweep. DEEP (the whole ~9500-line libs/regexp engine + exec/regexp_fastpath; not incremental).
   Worth a dedicated future investigation.

`new Array(n)` and `s.replace` boxing corrections from the first sweep still stand (below).

## ✅ Shipped round-4 (each: test262 0/49775 + 1223 unit + 1223 force-GC)

| slice | commit | effect |
|---|---|---|
| frame teardown gate (Slice A) | `5545cef` | fib 26.16B→25.35B (3.64×→3.53×); every plain call |
| var_refs borrow (Slice C) | `698824e` | fib 25.35B→24.88B (3.53×→3.46×); scales w/ captures |
| Map/Set entries dense pair | `a5e6218` | Map.entries 4.41×→1.87× (js_create_array build) |
| Object.entries dense pair | `9252d94` | Object.entries 1.61×→1.44× (same dense build) |

> **Correction:** closure length/name laziness is NOT faithful — qjs `js_function_set_properties`
> (quickjs.c:5853) EAGERLY defines both; only `prototype` is autoinit. closure-per-iter 3.73× is
> broad tax, not a divergence. The reusable win from this round is the **dense small-array build**
> (`adoptDenseArrayElementsAssumingEmpty` = qjs `js_create_array`), applicable wherever a small
> known-length array is built per-element via `defineOwnProperty(atomFromUInt32)`.

## ✅ Shipped round-3 (each: test262 0/49775 + 1223 unit + 1223 force-GC)

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
