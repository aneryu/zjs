# Where the pdfjs gap actually comes from

**Total to explain: 388.3 Mcycles/run** (zjs 795.5M − qjs 407.2M).

Decomposition of that total, computed at fixed IPC:
- zjs at its own IPC would need 2248.5 / 4.864 = **462.3 Mcyc** to retire qjs's instruction count → the pure IPC/stall term is 462.3 − 407.2 = **55.1 Mcyc/run (14%)**.
- The remaining **333.2 Mcyc/run (86%)** is zjs retiring 1620.7M more instructions per run.

So this is an instruction-count problem, and the answer must be an instruction-count answer.

---

## 1. Budget reconciliation

| # | Mechanism | zjs Mcyc/run | qjs Mcyc/run | **Excess** | % of 388.3 | Evidence |
|---|---|---|---|---|---|---|
| 1 | `Array.prototype.splice` runs the spec-literal per-element Has/Get/Set loop | 167.4 | 2.0 | **165.4** | 42.6% | measured (4 independent routes) |
| 2 | String `===`/`==` has no flat×flat arm; whole eq family exits to `op_compare_cold` | 48.7 | ~10.5 | **32** (28–38) | 8.2% | measured (gdb counts both engines) |
| 3 | Native-builtin call dispatch shell | 50.5 | 25.8 | **24.7** | 6.4% | measured (like-for-like samples) |
| 4 | `charCodeAt` re-descends the rope every call (never linearizes) | 15.35 | 5.54 | **9.8** | 2.5% | measured (2 domains agree) |
| 5 | `op_put_array_el` q-register spill/reload of the operand pair | 10.76 | ~5.4 | **5.4** | 1.4% | low confidence, not adversarially verified |
| 6 | `op_get_array_el` frame + out-of-line typed leg | 18.94 | ~18 | **1.0** | 0.3% | measured (claim 9 → corrected 1) |
| — | **Memory management (alloc + memcpy + refcount)** | 221.6+223.6 | 278.8+229.5 | **−7.9** | −2.0% | zjs is *faster*; refuted as a gap source |
| | **Named total** | | | **+230.4** | **59%** | |
| | **Unattributed residual** | | | **+157.9** | **41%** | broad per-opcode tax, no single mechanism |

Allocator/memcpy figures re-derived by me from `absolute.json` (N=8, ÷8): zjs `_int_malloc`+`malloc`+`malloc@plt`+`allocAlignedBytesNoTrigger` = 221.57 vs qjs `__js_malloc`+`_int_malloc`+`malloc`+`*usable_size`+`js_malloc_large`+`js_malloc_new_arena`+… = 278.76 Mcyc.

**Honest statement: identified mechanisms account for ~59% of the cycle gap, and one of them is 43% of it. 41% is a broad, diffuse per-opcode tax with no attributable mechanism.**

### Double-counting adjustments made

Four of the seven clusters independently discovered splice. Their corrected numbers were 200 / 158 / 170 / 78 Mcyc/run — all the *same* mechanism at different bucket boundaries. I unioned them at the symbol level rather than summing:

```
getDenseArrayElementValue 212.89×0.997   setOwnWritableDataProperty 108.78×1.0
qjsArraySpliceCall        184.20×1.000   getValueProperty            96.10×0.814
existsOwnProperty         179.52×0.989   propertyAtomFromLengthIndex 70.07×1.0
setValuePropertyWithThrow 168.85×0.956   getOwnProperty              58.73×0.944
+ ordinaryHasValueProperty/hasValueProperty/indexedExoticHasProperty/
  setValuePropertyOrThrow/getOwnDataPropertyValue/appendDenseArrayIndex/
  Slot.destroy/Object.setProperty/appendPreparedPropertyEntry(partial)
  = 1339 Mcyc over N=8 = 167.4 Mcyc/run
```
(fractions from the pure-JS-splice-shim ablation, which passes `tearDownPdfJS`'s hash on both engines). qjs side: `js_array_splice` 3.19 + `__memmove_sve` 7.09 + share of `js_create_array` 10.29 ≈ 16 Mcyc N=8 = 2.0/run.

Other de-duplications:
- `[[HasProperty]]` 4-function chain (32), generic `[[Set]]` gate order (5→ verifier corrected), `propertyAtomFromLengthIndex` (9), `getDenseArrayElementValue` sret (4) — **all subsets of #1**, not added.
- string-builtins' "String === has no flat path" (13) is a **subset of** cold-compare's #1 (28), not added.
- cold-compare's `valuesEqual` chain (3.5) and `compareStringValues` (10.5) are **subsets** of the same 32.
- `slice` (18 → 0.45), and even that 0.45 is generic dispatch — **not added**.

---

## 2. The headline mechanism

**`Array.prototype.splice` has no fast-array arm at all.**

- zjs `/home/aneryu/zjs/src/exec/array_ops.zig:2699` `qjsArraySpliceCall`; shift loops at **2773-2790** and **2796-2813**. Per shifted element: `propertyAtomFromLengthIndex` ×2 (2801/2803) → `hasValueProperty` (2805) → `getValueProperty` (2806) → `setValuePropertyOrThrow` (2808) + 2 `LengthIndexAtom.deinit`. Grepping 2699-2830 for `fastArrayCount`/`arrayElementStorageMode`/`copyForwards` finds nothing.
- qjs `/home/aneryu/quickjs/quickjs.c:43042-43046` gates on `JS_IsUndefined(ctor) && p->class_id==JS_CLASS_ARRAY && p->fast_array && final<=p->u.array.count && (get_shape_prop(p->shape)->flags & JS_PROP_WRITABLE) && can_extend_fast_array(p)`, then **quickjs.c:43064 / 43072** `memmove(arrp+start+item_count, arrp+final, (count32-final)*sizeof(arrp[0]))`. Even qjs's *slow* path batches through `JS_CopySubArray`'s fast-array loop (**quickjs.c:41625-41647**).

Driver: `Type1Font_flattenCharstring` (`/home/aneryu/javascript-zoo/bench/pdfjs.js:17786-17811`) does `charstring.splice(i,1,28,hi,lo)` per numeric operand. Measured **19,544 calls / 1,324,867 shifted elements per run**, mean receiver length 235, del=1 ins=2.84 (so always growing). ~631 instructions per shifted element in zjs (4-point slope, dead linear) vs ~2.15 in qjs (flat in L, proving the memmove arm is live).

The decisive test, run by two agents independently: replace `Array.prototype.splice` with a pure-JS dense shim; the hash still verifies on both engines.
- zjs gets **79.8 Minsn/run cheaper** — an interpreted JS loop beats zjs's native splice.
- qjs gets **1016.6 Minsn/run more expensive**.

Same shim, same workload, opposite sign. That is engine-symmetric proof and needs no symbol attribution.

Instruction-domain excess: **~830 Minsn/run = 51% of the 1620.7 Minsn/run instruction gap.**

This is *not* a complexity-class divergence — both engines are O(shift length) and both are quadratic over `flattenCharstring`. It is a ~300× per-element **constant factor** applied 1.32M times. That is a genuine counterexample to the project heuristic that only complexity-class gaps convert; here the constant is applied on 26% of all retired instructions.

Notably zjs already has the mirror mechanism for every sibling: `qjsFastDenseArrayShift` (array_ops.zig:3312), `qjsFastDenseArrayUnshift` (:3340, whose doc comment cites quickjs.c:41624-41647), `slice`'s dense bulk copy (:2496-2534, citing quickjs.c:9601). **splice is the single hole in an otherwise complete set.**

Second-order bug found while pricing it: because `setValuePropertyWithThrow` (object_ops.zig:3176-3245) has no dense in-range overwrite branch, the first generic in-range write **promotes moved indices into shape properties and permanently de-densifies the array**. Micro proof: dense 200-element array, `splice(50,1)` K times → K=1 gives 150 `defineNewOwnDataPropertyForSimpleSet`, K=5 gives 154 defines but 750 `setOwnWritableDataProperty`. qjs never converts (quickjs.c:9740-9748 routes `fast_array && idx<count` to `JS_SetPropertyValue`'s dense store). In pdfjs the arrays are already converted during setup (only 588 conversions/run), so this costs little *here* — but it is a live correctness-of-representation divergence.

---

## 3. The other survivors

### #2 — string equality never enters a fast arm (32 Mcyc/run)

- zjs `/home/aneryu/zjs/src/exec/tailcall_dispatch.zig:3610-3655`: `opCompare` accepts **int32×int32 only** for eq/neq/strict_eq/strict_neq. The float arm at 3634-3652 is relational-only.
- qjs `quickjs.c:20321-20325` (OP_CMP_EQ) and `20382-20386` (OP_CMP_STRICT_EQ): `tag1==JS_TAG_STRING && tag2==JS_TAG_STRING → js_string_eq`, **inline inside JS_CallInternal**. `js_string_eq` (quickjs.c:4605-4613) is len-compare / pointer-compare / one `js_string_memcmp`.

gdb counts on both engines, same workload:
- zjs `op_compare_cold` @0x11d2764: **1,005,378 cold entries/run** (4 at N=0). Tag histogram: strict_eq rope×string 528,271; eq string×string 250,750; strict_eq string×string 196,949 → 99.5% string-involved.
- qjs `js_string_eq.isra.0`: **982,714 calls/run**; `js_strict_eq2`: 44,102/run; `js_string_rope_compare`: **0**.

So both engines do ~1.0M string comparisons per run. qjs resolves ~96% inline; zjs resolves 0% inline and pays a 464-byte-frame cold handler (`sub sp,#0x1d0` + 6 `stp`) plus an out-of-line tower `valuesEqual → compareStringValues → compareResolved → mem.eql/mem.order`.

`compareStringValues` (`/home/aneryu/zjs/src/core/string.zig:1057-1097`) opens with **`sub sp,sp,#0x550`** — a 1360-byte frame for two `StringValueIterator`s (`nodes:[60]*StringRope` + `phases:[60]`, string.zig:955-956) — *before the length test*, on every string equality. qjs's equivalent 60-slot stack (`quickjs.c:4743`) lives only inside `js_string_rope_compare`, which is never called here.

Length-independence confirms it is a missing-fast-path, not a slow memcmp: excess is flat at ~277 insn across len 4→128.

Sub-mechanism, unpriced separately: `compareSameWidth` (string.zig:891-894) scans the bytes **twice** on mismatch (`std.mem.eql` then `std.mem.order`); `std.mem.order` carries 12.47 of the cluster's 124.19 Mcyc. qjs's single `memcmp` sign *is* the ordering (quickjs.c:4586-4603).

Enabler, not separately budgeted: 53% of cold compares have a **rope** LHS, because `token += c` on a local goes through `startAccumulatorRope` (`value_ops.zig:1253-1264`, no length threshold) where qjs's OP_add_loc arm calls `JS_ConcatStringInPlace` (quickjs.c:19766-19772 → 4671-4703) and keeps the local **flat**. A plain `tag==string && tag==string → memcmp` arm would therefore miss half the traffic unless it tolerates ropes or the accumulator policy is re-aligned.

### #3 — native builtin call dispatch (24.7 Mcyc/run, only 4.4 mechanized)

The brief's own framing was wrong and the verifier corrected it: comparing zjs `nativeMethodFastDispatch` (261.6 Mcyc) against qjs `js_call_c_function` (57.1) is apples-to-oranges, because qjs does the same work in three places. Line-attributing `JS_CallInternal`'s 2215 samples (load base 0xb85c79020000) recovers qjs's entry/class-dispatch share (quickjs.c:17749/17789/17815-17823, 130 samples) and its OP_call_method arm incl. the `JS_FreeValue` loop (quickjs.c:18226-18238, 61 samples). **Correct: zjs 516 samples vs qjs 264 = 1.96×, ~57 vs ~29 cyc per native call**, on ~0.886M native calls/run.

Both `perf.data` files have the same Mcyc-per-sample (zjs 0.78275, qjs 0.78293) — raw sample counts are directly comparable across engines. That is the cleanest tool for inlined-qjs-vs-outlined-zjs comparisons and should be reused.

Attributed sub-mechanisms are small:
- 9-field `NativeCallEnvironment` published through `rt.active_native_call` + a second backtrace chain (`builtin_dispatch.zig:380-397`, 37 insn) vs qjs's single `JSStackFrame sf_s` (quickjs.c:17583-17589 + 17687, 8 insn) → **2.9 Mcyc/run**. Note 57% of the cluster's samples sit on one instruction, `125dd04 ldr x8,[x23,#2080]`, which is a post-call cold-first-touch stall that would simply *migrate* to the arg-release loop's own `ctx->runtime` chase if the env were deleted.
- `stringCall` (`string_builtin_ops.zig:371-441`) fans every String.prototype method through one handler → **1.5 Mcyc/run** of magic re-dispatch (qjs also re-dispatches on magic inside bodies — `js_string_indexOf`/`includes`/`match`/`trim` all take a magic — so the divergence is fan-out 1-vs-8, not presence).
- The outlined ABI switch `callTypedInternalRecordDirect` is **at parity**: 58.06 vs qjs `js_call_c_function` 57.10 Mcyc, 8.19 vs 8.05 cyc/call, 0.14σ.

So ~20 of the 24.7 Mcyc is unexplained shell cost. This is the best-quantified but least-mechanized cluster.

### #4 — `charCodeAt` never linearizes (9.8 Mcyc/run)

- zjs `string_builtin_ops.zig:205` → `core/string.zig:1024-1052` `stringValueCodeUnitAtUnchecked`, a faithful copy of qjs's `string_rope_get` (quickjs.c:4724) — but qjs uses `string_rope_get` in **exactly one place**, quickjs.c:8249 (`JS_GetPropertyInternal`'s `s[i]`), never in charCodeAt.
- qjs `js_string_charCodeAt` calls `JS_ToStringCheckObject` (quickjs.c:45450) → `JS_ToStringInternal` case `JS_TAG_STRING_ROPE` (13597-13598) → `js_linearize_string_rope` (4828), whose already-linearized check (`r->right == empty` → `JS_DupValue(r->left)`, 4838-4844) is O(1), and which **mutates the node** (4851-4855). zjs has the caching flatten (`string.zig:148`) and does not use it here.

289,569 charCodeAt calls/run (counted identically under both engines). Receiver A/B shim on the real workload: zjs pays **+185.7 insn/call** for the receiver being the real rope; qjs pays **+12.5**. Depth ladder: qjs flat at +19 insn regardless of rope depth; zjs grows without bound (863 → 984.9 → 1233.9 insn/call at 600/12000/24000 chars).

---

## 4. Refutations — what died

These are as load-bearing as the confirmations. **Five separate "obvious" suspicions were killed, and three of them had the sign backwards.**

**Memory management is not the problem — zjs is faster.**
- Allocation *count* is identical: LD_PRELOAD gives zjs 248,741 vs qjs 243,901 libc mallocs/run (1.020×), 875.0 vs 866.4 MB/run, near-identical size histograms. Allocator cycles: zjs 221.6 vs qjs 278.8 Mcyc (N=8).
- Refcounting: `gc.zig:486 RefCountHeader.retain` is a plain `rc += 1` mirroring `quickjs.h:707`; recovering zjs's inlined retain/release via innermost-frame `addr2line` gives **0.924× in zjs's favour**.
- memcpy: 94% of zjs's `memcpyFast` comes from `concatFlatStringBodiesOwned`, 94% of qjs's `__memcpy_sve` from `JS_ConcatString2` — same operation, zjs 0.950×.
- Cycle collector: 1.010×, negligible on both.
- Finalizer path "1.69×" was a bucket-boundary artifact: the zjs bucket silently included inlined `JSValue.free`, `MemoryAccount.destroy`/`SmallObjectSlab.freeAtIndex` and `String.destroyFromHeader`, whose qjs counterparts (`JS_FreeValue`, `__js_free`, inline `js_free_string` at quickjs.c:6449-6459) were excluded. Symmetric baskets: **1.032×, 317 vs 307 samples, statistically zero.**
- `destroyOptionalVarRefCellSlice` is the identical O(closure_var_count) loop as quickjs.c:6254-6256.

**String concat is not a divergence, and may favour zjs.** The "1.59×" was rule-3 aggregation applied to zjs only: `JS_ConcatString1` is inlined into `JS_ConcatString2` and its memcpy lands in `__memcpy_sve`, which was excluded from qjs's side. Callgraph attribution puts qjs's run-phase concat at **~386 Minsn/run (~17% of qjs)** vs zjs's hard upper bound of 399 Minsn/run and realistic ~240. zjs's *entire* memcpy budget (126.1 Minsn/run) is below qjs's *concat-only* memcpy (144.2 Minsn/run) on an identical workload with identical rope thresholds (`string.zig:577-583` mirrors quickjs.c:216-218).

**`Array.prototype.slice` is fine.** `array_ops.zig:2496-2534` is an explicit mirror of quickjs.c:42967-42971 and it *is* taken: 1,835 calls / 173,715 elements per run, 0 holey receivers, 0 own `constructor`. In-situ differential on the real arrays: **zjs 17.85 vs qjs 19.18 insn/element — zjs is 0.93×.** The "545 insn/element" was an artifact of an injected workload allocating 74 MB/run extra and perturbing zjs's allocation-threshold GC.

**Property-hit paths are at parity.** Own-property read zjs 117.05 / qjs 108.05 insn (1.083×); 1-level prototype read 1.177×; existing-own write 1.012×. Statically, zjs `op_get_field2`'s own-hit path is 47 instructions vs qjs's 52 inside `JS_CallInternal`. `op_get_field2`'s 21 Mcyc/run is 17 cyc/op over 1.233M ops — a pointer chase both engines share.

**The confirmed 3.0–3.7× property-MISS tax is dead on pdfjs.** Reproduced (504.5 vs 159.1 insn/op) but `op_get_field_property_tail` = 0.75 Mcyc/run and `ordinaryDataPropertyLookup` = 0.33 Mcyc/run. pdfjs's field traffic is essentially all hits.

**"No inline caches" is not a defect.** qjs's `GET_FIELD_INLINE` (quickjs.c:19107-19159) has no IC either; it runs an uncached force-inlined `find_own_property` every access. `ic hits: 0 / ic misses: 0` is faithful.

**`op_get_array_el`'s frame: 9 → 1 Mcyc/run.** The qjs premise was false — quickjs.c:19434 is `GET_ARRAY_EL_INLINE`, whose inline arm handles **only** `JS_CLASS_ARRAY`; typed arrays fall to `JS_GetPropertyValue` via a real `bl` with its own 64-byte frame. And the dense leg, the one the claim priced, is *faster* in zjs (221.15 vs 223.99 insn/op). Every typed read in pdfjs is Uint8Array (float64 arm: **0** executions), so the only real excess is 655,788 × +9.12 insn = 6.0 Minsn/run.

**`propertyAtomFromLengthIndex` is a faithful mirror, not a divergence.** `object_ops.zig:1968` returns a tagged int with `owned=false`, `atomFromUInt32` is `n | tagged_int_bit`, `deinit` is a no-op. qjs does the identical thing (`__JS_AtomFromUInt32`, quickjs.c:2891-2893, used at 9122-9123, 10748, 10947). The residual is codegen (22 instructions with a 0xd0 frame to execute one `orr`) and it vanishes with the splice fast path.

**Ruled out as pdfjs drivers by measurement**: string↔number comparisons (0.4% of cold compares), undefined/null comparisons (0.44%), float-vs-int relational (0.5%), NaN (0), heap numbers (don't exist), `in`/`for..in`/`hasOwnProperty` (99.7% of `existsOwnProperty` arrives via splice), receiver sparseness (arrays are dense), eager rope creation in general (zjs 237,125 vs qjs 236,758 rope creations/run, 0.15% apart).

**Methodological refutations worth keeping:**
- Symbol-level *instruction*-event sampling is untrustworthy at this granularity: the profile credits `getDenseArrayElementValue` 96.9 insn/call for a function whose entire body is 29 instructions — a 6× over-attribution from skid, 90% piled on one pre-`ret` store. Only **group** totals survive.
- "Replace a builtin with a JS shim and difference the totals" is unsound as a *pricing* method (it perturbs downstream allocation/representation), though it is sound as a *sign* test and as a source of per-symbol collapse **fractions**. Two agents got 1009M, 2242M and 2245M Minsn/run for nominally the same splice differential.
- "Inject one extra call on a fresh copy" is contaminated when the copy takes a different representation path (17,478 vs 588 dense→sparse conversions).

---

## 5. Structural vs micro: reading 79.6 vs 46.3 insn/opcode

**First, the assumption is now verified, not assumed.** zjs's opcode profile at N=2 gives `strict_eq` 1,575,297 + `eq` 1,110,032 = 2,685,329 → **1,342,664.5 eq-family opcodes/run**. Independently, gdb on qjs counted **1,342,664 eq-family opcodes/run**. Exact match. Similarly `get_array_el` 3,479,498/2 = 1,739,749 matches the array agent's independent 1,739,750. The two engines execute the same bytecode stream, so 2248.5M / 48.6M = **46.3 insn/opcode for qjs is a valid figure**.

Now peel it:

| stage | zjs insn/opcode | qjs insn/opcode | ratio |
|---|---|---|---|
| as measured | 79.6 | 46.3 | 1.72× |
| minus splice (−830 Minsn zjs, −20 qjs) | 62.1 | 45.9 | **1.35×** |
| minus string-eq, charCodeAt, native dispatch | 55.6 | 43.8 | **1.27×** |

**The answer is (a) + (c), sitting on top of a real but secondary (b).**

- **(c) pdfjs hits one specific slow path other benchmarks avoid.** Splice alone is 43% of the cycle gap and 51% of the instruction gap, concentrated in **19,544 opcode executions per run out of 48.6M** — 0.04% of the opcode stream carrying a quarter of the instructions. This is why the average insn/opcode is so misleading: it is not a per-opcode tax, it is one native builtin body.
- **(a) two more real mechanisms** (string eq fast-arm absence, charCodeAt non-linearization) add another 42 Mcyc/run, both of them "zjs runs the general algorithm where qjs splits out the common case".
- **(b) a genuine broad tax exists but is smaller than it looks: ~1.27× per opcode, ~157.9 Mcyc/run.** Its shape is a flat tail with no single owner: `op_get_field2` 21.0, `op_get_array_el` 18.9, `opLoc` 14.7, `op_if_false8` 14.2, `op_call_method` 13.5, `opBinary` 13.0, `op_get_field` 12.8, `op_put_array_el` 10.8, `op_get_field2_primitive` 10.3 … Mcyc/run. Aggregate: zjs `exec.tailcall_dispatch.*` = **294.65 Mcyc/run vs qjs `JS_CallInternal` 215.95 = 1.364×**, and that comparison is *generous to zjs* because `JS_CallInternal` contains all of qjs's inlined opcode bodies while zjs's handlers additionally call out to the helper symbols counted separately. Subtracting the parts already named (`op_compare_cold` 20.8, the two array-el handlers 6.4, qjs's native-entry share ~18.6 the other way) leaves **~50-60 Mcyc/run of unattributed dispatch-layer tax**, with the remaining ~100 Mcyc/run spread across out-of-line helpers.

The one concrete lead into that residual, found incidentally and never priced: `findProperty` (`/home/aneryu/zjs/src/core/object.zig:11721-11735`) carries **three fail-closed guards** that `find_own_property` (quickjs.c:6135-6152, plain `while (h)`) does not have — a `steps < prop_count` loop bound, an `index >= prop_count` break, and an `index >= props.len` continue. The hottest IPs inside `existsOwnProperty` (0x114ea44/48/4c, 55 samples) are exactly that compound `cmp / ccmp / b.eq` pair. This is a per-probe tax on **every shape lookup in the engine**, and it is the best candidate for a chunk of the 1.27× residual.

---

## 6. Open questions requiring a serial timing run (priority order)

1. **Does the splice fix convert to wall time?** Predicted: zjs 795.5 → ~630 Mcyc/run, ratio 1.954 → ~1.55×. Run `perf stat -e cycles,instructions` on `/tmp/pdfjs-attrib/runN.js` vs the pure-JS-dense-shim variant (both pass the hash on both engines), N=0 and N=8, pinned, serial. This is an allocation/pointer-chase removal, the class that has historically realized 0.6–0.82 in this engine, so I expect high realization — but the project's own record says do not claim a score delta from an instruction delta. **This single run decides the whole priority ordering.**
2. **The residual ratio after splice.** Is the post-splice cycles ratio ~1.35× (matching instructions) or does the 1.135× IPC penalty still stack on top, giving ~1.53×? This determines whether attacking the residual per-opcode tax is worth it at all.
3. **String-eq flat arm A/B.** 32 Mcyc/run of instruction win, but 5.3 Mcyc/run of it sits on a store-to-load-forwarding stall (`stp q0,q1,[sp,#96]` / `ldp x25,x24,[sp,#96]` at 0x11d2800/0x11d2828, 32% of `op_compare_cold`), which is a stall and *should* convert. The rest is a short dependent chain over hot lines — the profile most likely to be absorbed. Also needs deciding: a plain `tag==string×2` arm covers only 47% of the traffic; the other 53% has a rope LHS and needs either a rope-tolerant leg or the `startAccumulatorRope` → `JS_ConcatStringInPlace` re-alignment (quickjs.c:19766-19772), which is its own timing question.
4. **charCodeAt linearization.** A build where `stringPrimitiveIndexRead` calls `StringRope.flattenInfallible` (mirroring `JS_ToString`). 9.8 Mcyc/run, and it is a pointer-chasing dependent-load chain — the profile that *has* converted in this engine (cycle share 2.5% vs instruction share 0.8%, i.e. low local IPC).
5. **Native-call env removal.** 2.9 Mcyc/run, but 57% of the samples are a post-call cold-first-touch that will migrate rather than vanish. Low expected realization (project history: 0.0–0.15 for predictable stack bookkeeping). Do this last.
6. **`op_put_array_el` q-spill (5.4 Mcyc/run)** — this is the only surviving number that was never adversarially attacked. Verify it before acting on it; the sibling `op_get_array_el` claim collapsed 9× under attack.

---

## 7. Cross-benchmark applicability

**pdfjs-specific (do not expect zoo-wide movement):**
- **splice** (165 Mcyc/run). Driven entirely by `Type1Font_flattenCharstring`. raytrace and earley-boyer do not do bulk mid-array splicing. It will move pdfjs from ~2.15× to ~1.55×; it will move essentially nothing else. Still worth doing first — it is 43% of this benchmark's gap and it closes an admitted hole in a family (`shift`/`unshift`/`slice`) that is otherwise complete.
- **charCodeAt rope descent** (9.8). Only fires when the receiver is an unlinearized rope of meaningful depth, i.e. PDF content-stream accumulation.

**Engine-wide (expect movement on raytrace / earley-boyer and beyond):**
- **String `===` flat arm** (32 here). Any benchmark that compares strings — earley-boyer is symbol/string-comparison heavy and is the most likely beneficiary. The mechanism (`opCompare` int32-only for the eq family) means *every* string comparison in *every* benchmark exits to a 464-byte-frame cold handler.
- **The accumulator-rope policy** (`value_ops.zig:1253-1264` vs quickjs.c:19766-19772). Affects any `s += c` string building; it is what makes 53% of pdfjs's compares rope-LHS and would otherwise poison the fast arm elsewhere too.
- **Native-builtin dispatch shell** (24.7 here, ~57 vs ~29 cyc per native call). Scales with native call volume in any workload. raytrace/earley make heavy `Math.*` / `String.*` / array-builtin calls.
- **`findProperty`'s three fail-closed guards** (unpriced). Every shape lookup, every benchmark. This is the highest-leverage *unpriced* lead in the whole investigation.
- **The `setValuePropertyWithThrow` dense de-densification bug** (object_ops.zig:3176-3245 has no dense in-range overwrite branch, vs quickjs.c:9740-9748). Costs little in pdfjs because the arrays convert during setup, but it is a representation divergence that will cost a lot in any benchmark that writes in-range dense elements through the generic path.

**Explicitly not worth pursuing anywhere** (refuted with numbers, do not re-litigate): allocator, refcounting, memcpy, cycle collector, finalizers, string concat, `Array.prototype.slice`, property-hit paths, the missing inline cache, `propertyAtomFromLengthIndex`, `op_get_array_el`'s frame, and the outlined native ABI switch.