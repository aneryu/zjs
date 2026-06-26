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

## ✅ Shipped round-8 — parallel worktree batch (branch `qjs-faithful-round8-batch`, integrated union gated test262 0/49775 + 1226 unit + 1226 force-GC)

A parallel batch: each slice implemented in an isolated worktree, self-gated + adversarially
verified, then cherry-picked + the integrated union re-gated whole.

| slice | commit | qjs anchor | effect |
|---|---|---|---|
| single backtrace chain (delete per-call ActiveBacktraceFrame, walk Machine Entry chain) | `29e93a6` | build_backtrace quickjs.c:7571 | perf-neutral; the one genuine structural piece of the frame-model rewrite (D) — see FRAME-MODEL-ONESHOT-BLUEPRINT.md |
| typed-array inline element READ (all 12 kinds) | `dce71dd` | JS_GetPropertyValue quickjs.c:9029 | Float64 3.68×→2.83×, Uint8 3.59×→2.75× |
| Array.prototype.slice dense bulk copy | `2886a1f` | js_array_slice fast case quickjs.c:42967 + js_create_array 9601 | **dense slice 6.87×→1.36×** (biggest single win); sparse/Symbol.species fall through to the slow loop |
| hasOwnProperty existence-only probe (NULL-desc) | `25b30aa` | JS_GetOwnPropertyInternal desc==NULL quickjs.c:8854 | 2.34×→2.13×; preserves TDZ ReferenceError + AUTOINIT no-materialize; Proxy keeps the descriptor/trap path |
| Object.assign single ENUM_ONLY walk | `23682e6` | js_object_assign→CopyDataProperties quickjs.c:16920 | collapses the two-pass per-key-Descriptor to one enumerable-snapshot pass for ORDINARY sources; Proxy/exotic keep the descriptor path; keys/values/entries untouched (qjs re-checks there, 40400) |

> **Correction (verifier):** Object.keys/values/entries + propertyIsEnumerable are ALREADY faithful —
> qjs builds a full per-key descriptor there on purpose (the "still enumerable" re-check at
> quickjs.c:40400, because a getter/Proxy in the loop can mutate the shape). Only hasOwnProperty
> (NULL-desc existence) and Object.assign (single ENUM_ONLY CopyDataProperties) are faithful skips.
> Object.keys 1.84× is a SEPARATE lever (GPN-walk/array-build), NOT this batch's.

### Shipped round-9 (parallel worktree batch, integrated + union-gated 0/49775 + 1226 + force-GC)
| slice | qjs anchor | effect |
|---|---|---|
| typed-array element WRITE all kinds | JS_SetPropertyValue quickjs.c:9947 | Float64 write 4.56×→2.89× |
| String padStart/padEnd narrow latin1 buffer | js_string_pad quickjs.c:46300 | 4.6×→4.2×; also added the JS_STRING_LEN_MAX RangeError (was unbounded) |

> **Integration-gate catch:** the TA-write fast path delegated to `typedArraySetElement` which checks
> in-bounds/immutable validity FIRST and silently no-ops on an OOB/immutable element — swallowing the
> `ToNumber(BigInt)`/`ToNumber(Symbol)` TypeError that IntegerIndexedElementSet requires BEFORE the
> validity check. Only the **integrated union test262** caught it (1/49775,
> `internals/Set/bigint-tonumber.js` makeImmutableArrayBuffer variant) — the worktree agents can't run
> test262 (no submodule). Fix: punt BigInt/Symbol values (throwing conversions) to the slow path;
> Number/String/Boolean/null/undefined have non-throwing conversions so validity-first is observably
> identical (they stay fast). **Lesson: ALWAYS re-run the full test262 gate on the integrated union;
> a slice green on its own base is not green in the union.**

### Shipped round-10 (parallel worktree batch of 6, integrated + union-gated 0/49775 + 1226 + force-GC)
The biggest raw gaps in the whole campaign — all faithful (qjs has a dense/memmove/raw-scan fast path zjs lacked):
| slice | qjs anchor | effect |
|---|---|---|
| TypedArray.set same-class @memmove | js_typed_array_set_internal quickjs.c:57584 | **322×→3.30×** (used @memmove not copyForwards — aliasing-safe) |
| Array.reverse dense in-place swap | js_array_reverse quickjs.c:42835 | **228×→1.19×** |
| TypedArray indexOf/lastIndexOf/includes raw scan | js_typed_array_indexOf quickjs.c:58072 | **indexOf 51.77×→1.07×, includes 34.67×→~1.3×**; deliberately does NOT reproduce qjs's Int8 lastIndexOf sign-extension bug (V8/Node agree) |
| TypedArray.fill coerce-once + memset/strided | js_typed_array_fill quickjs.c:57979 | **33.48×→3.86×** |
| String for-of single-byte/latin1 cache | js_new_string_char quickjs.c:3953 | 12.71×→~broad-tax floor |
| Object spread `{...o}` ENUM_ONLY snapshot | JS_CopyDataProperties quickjs.c:16920 | 2.50×→2.25×; **also fixed a real bug** — baseline diverged from qjs when a getter mutated a later key's enumerability/existence (now up-front snapshot, matches qjs) |

### Shipped round-11 (parallel worktree batch of 3, integrated + union-gated 0/49775 + 1226 + force-GC)
Surfaced by the 2026-06-26 audit's fresh-sweep (NOT in the prior catalog) + the remaining cheap leaves:
| slice | commit | qjs anchor | effect |
|---|---|---|---|
| Array.sort default cmp: cache ToString key once + skip-unmoved write | `c2c84dd` | js_array_sort ValueSlot.str quickjs.c:43398-43410 + pos==n write-skip 43476 | kills 2 ArrayList allocs **per comparison** (O(n log n)→O(n) ToString) + skips setValueProperty on non-moved entries; user-comparator path byte-identical |
| TypedArray.slice same-class @memcpy | `c2c84dd` | slice_memcpy quickjs.c:58519/58572 | raw byte-range copy (overlap-safe) before the element loop; differing class falls through |
| Array.unshift dense in-place bulk shift | `c2c84dd` | JS_CopySubArray fast_array quickjs.c:41624-41647 | fills the round-9/10 push/pop/shift gap; bails on !extensible/!length_writable/exotic/proxy/proto-indexed |
| String.repeat resolve-once borrowed-slice | `b1f6bc0` | js_string_repeat quickjs.c:46371 | drops the per-call appendRawString transcode-into-ArrayList; narrow-stays-narrow lazy-widen (pad template) |
| hoist frame-invariant generator stop-boundary guard out of get/put_loc hot path | `a6067f1` | get/put_loc carry ZERO per-op guards quickjs.c:18531-18596 | precompute the per-invocation `stop_before_pc` block-test once into a register bool; 9 hot sites now test a bool. idx-dependent lexical-sync guard + var-ref cell probe deliberately untouched |

> **round-11 corrections to the prior "next batch" list:** (a) **String.split simple-separator was ALREADY
> resolve-once** (splitReceiver fast path, string.zig:687-734) — no change needed. (b) **TypedArray
> copyWithin/subarray/join are NOT leaves** — copyWithin already does raw-byte copyForwards/copyBackwards,
> subarray already builds a view (no copy), and qjs's *own* join is per-element ("XXX: optimize" never done)
> so zjs's loop is already faithful. **slice was the only real remaining TypedArray leaf.** (c) **Object.keys/
> values descriptor build is FAITHFUL, not a skip** (see the 2026-06-26 audit corrections below) — dropped
> from the batch.

### 🔬 2026-06-26 full-HEAD audit corrections (stale-doc fixes — supersede entries above where they conflict)
A 11-agent audit (9 documented-frontier verifications + 2 fresh independent sweeps) re-confirmed each remaining
divergence against current HEAD. Key **doc-staleness fixes**:
1. **map/filter dense output is ALREADY CLOSED.** §🟥/"Medium-deep" claim that map/filter/forEach build output
   via per-element `defineOwnProperty(atomFromUInt32)` is **no longer true**: map uses
   `defineDenseArrayDataPropertyUnchecked`, filter uses `appendDenseArrayIndex` — both dense, both matching
   qjs `js_array_every`→`add_fast_array_element`. The count/length-split dependency is a **red herring** for
   sequential map/filter (count==length grows together); it only matters for `new Array(n)` pre-sized holes.
2. **Generator frame is PRESERVED across steps, NOT realloc'd.** The "frame re-allocated per step" claim is
   misleading — locals/args/var_refs are pointer-swapped and kept (vm_gen_async.zig:82-94). What remains is a
   throwaway entry-slab alloc/free per resume + a fresh `{value,done}` per step (both the same broad
   call/frame tax). Cheap faithful win left: skip the throwaway slab + a result-object-free generator-next step
   (analog to `fastMapSetForOfNext` be06930).
3. **This qjs build has NO inline cache** (zero `get_ic`/`ic_watchpoint` hits — property reads go through
   `find_own_property` proto-walk every access). So zjs's IC is a **superset** zjs added to claw back the
   LLVM-vs-gcc dispatch tax; INLINE-CACHE-PLAN's "align to get_ic" (S4 poly/mega) is **not a faithful target**.
   The one faithful IC item was **S3 global-lexical** — but **the stale "let g reads still name-lookup" claim was
   WRONG**: script top-level let/const reads were ALREADY a single `.global_decl` var_ref cell deref (da34bc1).
   **A4 (`45e9f55`, 2026-06-26) RETIRED the `global_lexical_sync_*` mirror entirely** — the remaining divergence
   was (1) top-level `class` routed via frame-slot+env+mirror instead of a cell (qjs define_var JS_VAR_DEF_LET) and
   (2) host `ctx.eval` running eval modes through the SCRIPT runner (is_eval_code=false/sync=true), creating a
   redundant ctx.lexicals property. Both fixed (class→cell; eval→is_eval_code=true/sync=false), mirror + the 7
   `localStoreNeedsSlowSync` per-op guards deleted (now unconditional fast paths). The "stable-cell READ IC" sub-item
   is MOOT — the read is already O(1) cell deref, not a name-lookup. Gate 0/49775 + 1227 + force-GC. Also fixed a
   pre-existing leak (function/class value reflected onto globalThis from a .global_decl cell).
4. **Builtin methods are ALREADY own-properties on each prototype** (function.zig:367 `defineMethodData`).
   "method on prototype" frontier is done; the residual is the proto-`get_field` IC tax (dispatch IC is
   own-data-only) + null-proto internal-array method resolution.
5. **Object.keys/values 1.85× is NOT faithfully eliminable.** qjs deliberately builds a full per-key descriptor
   (+value dup) at quickjs.c:40400 for the still-enumerable recheck. zjs's per-key build IS faithful; residual
   is GPN-walk + broad codegen. (Retracts the descriptor-skip framing at lines ~146-152.)
6. **The regex.test 12× bench (`/a+b/`) never reaches the bytecode engine** — it's intercepted by the hand-rolled
   recursive-descent fastpath (regexp_fastpath.zig:2575). So the 12× is call-machinery tax (shared) + recursion
   vs flat-loop codegen, NOT "a different algorithm." engine.zig **is** a faithful libregexp port. The one genuine
   structural engine divergence (only bites backtracking-heavy patterns): pushState heap-snapshots the FULL
   capture+stack per branch (O(n)) vs qjs SAVE_CAPTURE single-pair undo-log (O(1)).
7. **Anchor drift:** `primitiveObjectForAccess` is at object_ops.zig:**3082** (doc said 4702); property `Slot`
   union is property.zig:**134-185** (doc said 125-134); the keys/values anchors object.zig:618/638 are stale.
8. **Frame-model floor is ~1.3-1.5×, not 1.0×** — the ~30% pushFrame+teardown residual is mostly
   **non-faithfully-eliminable** (zjs's re-entrant dispatch must store this/new_target/storage as Frame fields;
   Zig has no variadic alloca). The slim-to-9 and borrow-cur_func pillars stay REJECTED.

### Next batch (ranked, faithful/bounded/independent — post round-11)
1. **Array count/length split** (A1) — the single biggest *bounded* structural unlock (new Array(n) 19.5×);
   deferred high-risk C.3, 17 readers/11 need hole-handling. Needs a立项 flag-gated 5-stage plan.
2. ~~S3 global-lexical stable-cell + retire the mirror~~ — **DONE (A4 `45e9f55`)**. The read was already a cell
   deref (stale catalog); A4 retired the mirror via class→cell + eval-runner-contract. Next faithful binding item:
   the compile-time `parent_has_eval` flag (lower the per-access parent-eval-shadow guard to a Bytecode flag).
3. **s.replace string-wrapper boxing 36.4×** — needs the string-wrapper exotic `own_keys` hook FIRST
   (mirror js_string_obj_get_length synthesis), then delete the per-index materialization loop (object_ops.zig:3101).
4. **Cheap generator-next**: skip the throwaway resume entry-slab + result-object-free next step.
5. **regex engine snapshot→undo-log** (self-contained in engine.zig; only helps backtracking-heavy patterns).

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
