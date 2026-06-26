# qjs faithful-divergence catalog (2026-06-25 sweep)

Source: a 6-category measurement workflow (`qjs-divergence-sweep`, 28 faithful
divergences found) + manual verification. Ratios are `zjs_instructions /
qjs_instructions` on targeted loops, **measured on a clean `zig build zjs`
binary** (see the benchmarking-hazard note in `HANDOVER-perf-round2.md` — gate
builds overwrite `zig-out/bin/zjs` with a force-GC binary that inflates
allocation benchmarks 100×).

Anything not listed as a *structural divergence* is broad LLVM-vs-gcc per-opcode
tax (~2–2.5×) and is **not** a faithful target.

## 🧱 2026-06-26 bottom-up re-audit (`zjs-bottomup-divergence-audit`, 11 readers + synth) — current HEAD = `eb85a49`

A fresh **bottom-up** audit (re-verify each layer against `quickjs.c` at current HEAD, NOT trusting
doc checkboxes) after L2/L3/A4 landed. Verdict tally: **DO_NEXT=3, BACKLOG=3, ALREADY_DONE=3, DEEP_DEFER=2, REJECT=0**.

**FOUNDATION IS SOUND — no latent gap.** The value/refcount+GC (F1), property/shape kind-derivation
(F2), array count/length split (F3) and recursive call-path (C1) auditors all confirm the bottom layer
is a faithful structural mirror of qjs at HEAD. Specifics verified: `Slot.destroy/dup`
(property.zig:281-314) is a per-arm match of `free_property` (quickjs.c:6097-6113); `destroyFromHeader`
(object.zig:1686-1736) matches `free_object` incl. the weakref/remove_cycles guard; the active union
arm derives EXCLUSIVELY from shape `Flags.kind` (no in-cell tag, `@sizeOf(Slot)==16` asserted);
`array_length` split is faithful (`denseArrayElement` holes-climb-proto, `ownKeys [0,count)`,
`appendDenseArrayIndex == add_fast_array_element`, `new Array(n)` born dense-holey). **The bottom layer
is safe to build on.**

### Genuinely-remaining faithful work (ranked, post-L2/L3/A4)

| # | slice | verdict | ROI/risk | zjs anchor | qjs anchor |
|---|---|---|---|---|---|
| 1 | **C2 — derived-class construct: drop eager `this`-instance + prototype lookup** → ✅ **SHIPPED 2026-06-26** | DONE | med/med | call_runtime.zig:1556-1571 + 1585-1600 (derived early-returns `callFunctionBytecodeConstruct(this=uninitialized, ctor_this=undefined)`; base keeps the eager `createConstructorInstance`); dispatch twins at 7058/7082 left for a follow-up (correct, not yet skipped) | quickjs.c:20837-20838 (derived: `JS_CallInternal(func,JS_UNDEFINED,new_target)` — NO `js_create_from_ctor`) vs 20842 (base: eager); `js_create_from_ctor` 20783 |
| 2 | **S2 — spread/rest fast path missing iterator-override guard** ⚠️ **CORRECTNESS BUG → ✅ SHIPPED 2026-06-26** | DONE | med/low | NEW `call_runtime.appendSpreadValuesEnumerate` (vm_literal.zig:323-330 now delegates); reused `arrayIteratorKind`/`isArrayIteratorNextFunction`/`iteratorTargetSlot` (the `fastArrayForOfNext` pattern) | quickjs.c:16814 `js_append_enumerate` (resolve @@iterator + construct iterator; dense copy only when default Array Iterator value-kind + builtin `next` + fast-array + **`len==count`**, else `general_case`) |
| 3 | **C3 — generator throwaway slab (A) + result-object-free for-of step (B)** → ✅ **BOTH SHIPPED 2026-06-26** | A+B DONE | med→**high** / med | A: zjs_vm.zig:617-676 (started resume skips slab+init). B: `fastGeneratorForOfNext` iterator_ops.zig + `qjsSyncGeneratorStep` call_runtime.zig + per-instance-next flag object_ops.zig:2483 | quickjs.c:17790-17810 (`JS_CALL_FLAG_GENERATOR`, slice A) + 16548-16571 (`JS_IteratorNext2` builtin fast path, slice B) |
| 4 | F3-residual — `qjsArraySearchCall` indexOf/includes density gate `count==length` skips dense prefix for holey-fast arrays | BACKLOG | low/low | string_ops.zig:4304-4319 (requires `arrayElements().len==length`); contrast faithful two-phase `indexSearch` builtins/array.zig:821-845 | quickjs.c:42426-42446 / 42476-42496 (scan dense `[n,count)` then generic `[count,len)`, NO count==len gate) |
| 5 | B1 — compile-time `parent_has_eval` flag (lower per-access parent-eval-shadow runtime guard to a Bytecode flag) | BACKLOG | low/med | vm_property.zig:1067 `frameClosureHasEvalParent` (4-5-load header chase paid by ALL global accesses) + vm_property_globals.zig:120; fast-lane sites zjs_vm.zig:1728,1779; flag → bytecode/function.zig:102 `Flags.reserved:u3`, set in pipeline/finalize.zig:111 | quickjs.c:33158 (`var_object_test` emitted ONLY if `var_object_idx>=0`, COMPILE-TIME) + 36064 (`add_eval_variables` only if `fd->has_eval_call`) |
| 6 | L1 — string-wrapper exotic `[[OwnPropertyKeys]]` (lazy synthetic index keys vs materialize N char props) | BACKLOG | low/med | object_ops.zig:3101-3104 (materialization loop); read-side gaps objectRestOwnKeys 2151-2161, findPropertyDescriptor 3991-3995; in-repo template `typedArrayOwnKeys` array_ops.zig:5035 | quickjs.c:8757-8769 (`JS_GetOwnPropertyNamesInternal` synthesizes index atoms) + `js_string_get_own_property` 45178 |
| 7 | C1-residual — recursive-path `var_refs`/arg per-element `.dup` vs qjs O(1) borrow | DEEP_DEFER / REJECT | none/med | vm_call.zig:171 + frame.zig:403; the faithful borrow is **ALREADY LANDED** on the hot inline path inline_calls.zig:403-407,493-498 | quickjs.c:17844/17841 (borrow) — but this is the **COLD** fallback only (generators/async/derived-ctor/cross-realm); the documented non-eliminable ~1.3-1.5× frame floor |
| 8 | S1 — `OP_get_field` doubled proto-walk (six probes vs qjs single `for(;;)`) | DEEP_DEFER | high/high | vm_property_field.zig:223-357 + object_ops.zig:2858-2880,4012-4028 (by-class-name `getPrototypeMethod` fallback) + property_ic.zig:584-616 | quickjs.c:19108-19160 / 8267-8358 — **root cause is foundational (catalogued C.2)**: builtin proto methods are NOT physical own-props on the receiver chain; NOT a bounded slice |
| 9 | L2(regex) — `pushState` O(n) heap-snapshot vs `SAVE_CAPTURE` O(1) undo-log | DEEP_DEFER | low/high | libs/regexp/engine.zig:143-210 (full-slice capture+stack snapshot); old opcode set decodeOp 992-1026 (`simple_greedy_quant=29`) | quickjs/libregexp.c:2805-2812 — **zjs ports a pre-2020 libregexp** (`simple_greedy_quant` doesn't exist in reference); undo-log is inseparable from a full ~2300-line re-port |

### ✅ S2 — CONFIRMED correctness bug, FIXED 2026-06-26
**Was:** `[...arr]` / `f(...arr)` silently **ignored a user-overridden `arr[Symbol.iterator]` or patched
`%ArrayIteratorPrototype%.next`** — the fast-array branch (vm_literal.zig:327) read `source.getProperty(i)`
directly, never touching the iterator protocol. Proof:
`Array.prototype[Symbol.iterator]=function*(){yield 99;yield 98}; print(JSON.stringify([...[1,2,3]]))`
→ zjs printed `[1,2,3]`, spec/qjs require `[99,98]`. test262 stayed 0/49775 only because its spread tests
cover custom iterables + error propagation, NOT "monkey-patch the Array iterator then spread a real array"
(a coverage blind spot). Per §0.4 **correctness is the only hard red line**, fixed first despite C2 being
more "bottom".

**Fix:** new `call_runtime.appendSpreadValuesEnumerate` mirrors qjs `js_append_enumerate` — always resolve
`@@iterator` + construct the iterator, then take the dense bulk copy ONLY when the constructed iterator is a
default Array Iterator (`value` kind) whose `next` is the builtin `js_array_iterator_next` AND its target is a
hole-free fast array (`length == count`); else step the iterator generically. Reads densely from the
*iterator's* target (the `fastArrayForOfNext` pattern), so it stays correct even when `@@iterator` was
repointed to another array's (possibly partially-consumed) iterator. Gate: 12/12 hand cases (incl. all 6
formerly-wrong), `zig build test` 1227, **test262 `0/49775` (6 known)**, force-GC 1227.

### ✅ C2 — derived-class construct, SHIPPED 2026-06-26
**Was:** every `new Derived()` / `super()` eagerly allocated a `this`-instance via
`createConstructorInstance` (Object.create + a `new_target.prototype` lookup) BEFORE running the
derived body, even though a derived ctor's real `this` is produced by `super()` (which constructs at the
base level via the threaded new.target). The eager instance was then freed/discarded.

**Verification (not a blind deletion):** a controlled experiment (set `constructor_this=undefined` for
all derived sites, keep behavior otherwise) produced byte-identical output across a 10-case derived-class
suite — proving the eager instance was NOT load-bearing (super() builds the object from new.target,
ignoring the threaded `super_this`). The audit's "dead eager alloc" framing was confirmed correct.

**Fix:** for `is_derived_class_constructor`, `constructValueOrBytecodeWithNewTarget` now early-returns
`callFunctionBytecodeConstruct(this=uninitialized, constructor_this=undefined)` — no instance, no
prototype lookup (qjs `JS_CallConstructorInternal` quickjs.c:20837); base/ordinary ctors keep the eager
`js_create_from_ctor` instance (20842). **Bonus correctness fix:** a derived ctor built via
`Reflect.construct(D, args, NewTarget)` with a side-effecting `NewTarget.prototype` getter now reads it
**once** (was **twice** — eager + base); empirically confirmed 2→1. Gate: 10/10 baseline-identical + 9
edge cases (native Array/Error inheritance, private fields, nested arrow-super, new.target, throw,
multi-instance), `zig build test` 1227, **test262 `0/49775` (6 known, clean rebuild)**, force-GC 1227.
Follow-up: the 2 dispatch twins (`qjsReflectConstructGenericCallable` 7058/7082) still allocate the
discarded instance for derived (correct, just not yet optimized — needs upstream `prototype`-ownership care).

### ✅ C3 slice A — generator resume throwaway slab, SHIPPED 2026-06-26
**Was:** a STARTED generator/async resume (generatorPc() != 0) ran the full `runWithArgsState` frame
setup — heap-alloc a fresh slab + initFrameLocals + initArguments(re-dup args) + initFrameVarRefs — then
`resumeExecutionStateRaw` (vm_gen_async.zig:157-173) immediately freed all of it and swapped in the
generator's PRESERVED buffers. Pure alloc+dup+free round-trip per resume step.

**Fix:** `runWithArgsState` skips the whole slab+init block when `is_started_resume and !need_original_args`;
the frame's storage/locals/args/var_refs stay empty defaults until resumeExecutionStateRaw installs the
preserved buffers. First creation (pc == 0) still builds the slab (it becomes the generator's frame). qjs
allocates the generator frame ONCE at creation and resumes on it (`JS_CALL_FLAG_GENERATOR`, quickjs.c:17790).

**Gate caught a regression the hand-tests + a read-only mapping agent missed** (lesson: full test262 is the
oracle for frame-lifetime changes): `initArguments` has TWO resume-relevant side effects beyond filling the
(replaced) frame.args — it rebuilds `original_args` (the UNMAPPED `arguments` snapshot, NOT preserved in the
generator) and sets `actual_arg_count` (read by the MAPPED `arguments`). First attempt skipped both →
**59 `language/arguments-object/*gen-meth*` regressions** (`arguments.length == 0`). Fix: gate on
`!need_original_args` so snapshot-needing generators (strict / non-simple params) keep the full path, and set
`frame.actual_arg_count = args.len` on the skip path (byte-identical to initArguments, same `args`). Re-gate
clean. **Perf:** generator-resume bench (1M resumes) 11.13B → 10.62B instructions (~4.6%, ~512 insns/resume).
Gate: 13 generator + 7 arguments-object hand cases, `zig build test` 1227, **test262 `0/49775` (6 known)**,
force-GC 1227.

**Slice B (result-object-free for-of step) — SHIPPED 2026-06-26.** The going-in fear (bigger/riskier than A)
held on shape but the win turned out **much larger** than "skip one object". Implementation:
- **Detection infra** (added): no `.generator` native-builtin domain exists and the generator `next` is a
  NAME-cascade dispatch (call_runtime.zig:733-742). Added a `generator_next` flag (object.zig, analog
  `array_iterator_next`). **KEY discovery**: zjs gives each generator instance its OWN `next`/`return`/`slice`
  via `defineValueProperty` (object_ops.zig:2483-2491) — `it.next !== %GeneratorPrototype%.next` — so the flag
  must go on the per-instance `next` (createGeneratorObject), NOT the prototype `next` (which the own prop
  shadows and which for-of never resolves). First flagged the prototype → fast path silently never triggered
  (perf got WORSE, 10.62B→10.94B); moving the flag to the per-instance next fixed it.
- **`qjsSyncGeneratorStep`** (call_runtime.zig): a parallel sync-generator step returning raw `(value, done)`
  with NO `createIteratorResult` object; unwraps the yield\*-passthrough case internally (done-then-conditional-
  value reads). Kept SEPARATE from the hot `qjsGeneratorNext` (untouched; both covered by test262).
- **`fastGeneratorForOfNext`** (iterator_ops.zig, wired into `forOfNext` after the Map/Set fast path): for a
  pristine sync-generator iterator, resume one step + push value/done straight onto the stack. All bails are
  BEFORE the resume (no double-advance). Overridden `gen.next` → unflagged → bails to generic.
- **Win = 3.7×** (for-of-over-generator bench 10.62B → **2.85B** instructions), far beyond "one object" because
  the fast step ALSO skips the whole `next()` call machinery + name-cascade dispatch — exactly what qjs
  `JS_IteratorNext2` does for builtin iterators (quickjs.c:16548). Gate: 13 generator + 7 args + for-of
  override/break/yield\*/throw/spread/destructure hand cases, `zig build test` 1227, **test262 `0/49775`
  (6 known)**, force-GC 1227.

> **Adjacent finding (separate future slice):** each generator instance eagerly allocates 3 own native
> functions — `next`, `return`, and a bogus **`slice`** (object_ops.zig:2483-2491) — a non-faithful divergence
> (qjs generators inherit next/return/throw from %GeneratorPrototype%, have no own copies and certainly no
> `slice`). Wasteful per-creation + the `slice` is almost certainly a leftover bug.

### Stale-doc corrections (supersede where they conflict)
- **F1/F2 (value-refcount+GC, property/shape kind) ALREADY_DONE & faithful** at HEAD — any checkbox treating L2's 16B untagged slot or its refcount/teardown as open is stale.
- **F3/L3 (array count/length split) ALREADY_DONE & faithful** — only residual is the narrow #4 density gate (low-ROI BACKLOG), not a hole in L3.
- **C1 (recursive call path) catalog premise FALSE/STALE**: there is NO per-call ~43-field Bytecode by-value memcpy — `ensureCachedBytecodeView` (function.zig:549-559) caches `*const Bytecode`; the only `nested.*` copy (call_runtime.zig:5108) is gated on `eval_var_ref_names.len>0` (qjs pays it too). The var_refs O(1) borrow is **already landed on the hot inline path** (inline_calls.zig:403-407,493-498, commit 698824e).
- **L1 headline (s.replace 36.4× via exotic ownKeys) STALE/FALSE as a hot-path claim** — method-call resolution goes get_field2 → getPrimitiveProperty → `getFastStringPrimitiveDataProperty` bitset (string_ops.zig:4601/4621) and returns String.prototype methods WITHOUT ever calling `primitiveObjectForAccess`; s.replace never pays the materialization. The loop is reached only on colder `Object.keys/values/entries(str)` / `getPrototypeOf(str)` / non-standard string GET/SET paths.
- **S1 root cause = the catalogued C.2 keystone** (PHASE3-leaves-and-levers.md:30-34, method_call_loop 7.06×) — "solve with null-proto-arrays or leave do_not_align"; confirmed still correct, NOT a newly-discovered bounded slice.
- **regex engine ports a PRE-2020 libregexp** (`grep -c simple_greedy_quant /home/aneryu/quickjs/libregexp.c == 0`) — any doc implying it tracks current libregexp structure is stale; snapshot→undo-log is entangled with a full re-port (DEEP_DEFER).

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
