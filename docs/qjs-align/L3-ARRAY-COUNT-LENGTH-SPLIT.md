# L3 — Array count/length split (undo the `array_count == length` fusion)

Status: BLUEPRINT (read-only ground-truth). Terminal-state design for a single-shot commit.
HEAD audited: `main @ 9df4dc4` (rounds 1-11 shipped). The task brief's `d3afe1e`
anchor is stale; every line number below was re-opened at 9df4dc4.

qjs reference: `/home/aneryu/quickjs/quickjs.c` (16-byte JSValue, NaN-boxing OFF on aarch64).

---

## 0. The one fact that reframes the whole change

In qjs the fast-array **dense element bound is ALWAYS `p->u.array.count`, never length.**
Every exotic fast-array path gates on `idx < p->u.array.count`:

- get element  — quickjs.c:8301 (`JS_GetPropertyInternal`)
- getOwnProperty — quickjs.c:8873 (`JS_GetOwnPropertyInternal`)
- delete       — quickjs.c:9375 (`delete_property`)
- GPN counting / fill — quickjs.c:8657 and 8754 (`JS_GetOwnPropertyNamesInternal`)

`length` lives **separately** in `prop[0].u.value` (class comment quickjs.c:125 `u.array | length`;
JSObject layout quickjs.c:1050-1072: `u1.size`=capacity, `u.values`, `count`).
`length` is consulted in only TWO places:
1. the value of the `.length` property itself, and
2. growth decisions in `set_array_length` (quickjs.c:9447-9455) and
   `add_fast_array_element` (quickjs.c:9548-9559).

The crucial qjs behaviors that prove `length > count` is the intended fast-array state:

- **`new Array(n)`** (quickjs.c:41678-41683) calls `JS_SetProperty(length, n)` →
  `set_array_length`. For a fresh fast array `count == 0`, so `len(n) < old_len(0)` is FALSE,
  the dense-free loop is skipped, `count` stays 0, and only `prop[0].u.value = n` is set
  (quickjs.c:9453-9455). Result: **fast_array=1, count=0, length=n, slots [0,n) are HOLES.**
  This is the 19.5x unblock.
- **`arr.length = bigger`** (quickjs.c:9447-9455): same path — fast_array stays, count
  unchanged, length grows. No sparse conversion.
- A brand-new `[]` (quickjs.c:5654-5673): fast_array=1, count=0, length=0.

**Consequence for zjs:** the dense readers in zjs were already written count-aware
(`denseArrayElement` gates on `array_count`, the slow fallbacks read `getProperty` which walks
the prototype). The fusion `array_count == arrayLength()` made the `[count, length)` branches
dead code, but the branches EXIST and are CORRECT. L3 is therefore mostly a **representation +
write-path** change, with a small set of read fast-paths to re-point. This de-risks it enormously.

---

## 1. TERMINAL REPRESENTATION DECISION

### Current zjs (verified at HEAD)

`Object` (src/core/object.zig:1156-1167) has NO length field:
```
array_values:   [*]JSValue = undefined,   // 1161
array_count:    u32 = 0,                  // 1162
array_capacity: u32 = 0,                  // 1163
```
`arrayLength()` (object.zig:2168-2170) returns `array_count` — **fused**.
`arrayLengthSlot()` (object.zig:2163-2166) returns `&self.array_count` (no external callers).
`setArrayLength` (object.zig:2172-2179) drops fast_array when `length > capacity` and writes count.
`array_capacity >= array_count` is asserted in `arrayElements()` (object.zig:3356).
ObjectFlags is a `packed struct(u32)` with `_padding: u14` free (object.zig:1082-1105) — NOT
enough for a u32 length, so length needs its own word.

### DECISION: dedicated `array_length: u32` Object field (NOT qjs's prop[0].u.value)

Add one field to `Object`:
```
array_values:   [*]JSValue = undefined,
array_count:    u32 = 0,
array_capacity: u32 = 0,
array_length:   u32 = 0,   // NEW — JS-observable .length; >= array_count
```

**Rationale (faithfulness vs zjs idiom):**

- qjs stores length in `prop[0].u.value` because qjs has no spare JSObject word and arrays
  always carry a `length` shape slot. zjs deliberately does NOT keep count/capacity in the
  shape — it keeps them as plain Object fields (object.zig:1161-1163). Putting length in a
  field is the **same idiom** zjs already uses for the rest of the array part, and keeps the
  whole array part contiguous and pointer-free of the property machinery.
- A field avoids touching property slots on every `.length` read/write — directly relevant to
  L2 (see §5). qjs's prop[0] approach would couple L3 to L2 hard.
- zjs's `.length` reads already special-case the array before consulting properties
  (`getProperty` object.zig:7048, `getOwnProperty` object.zig:6865-6867, `ownKeys` object.zig:9036),
  so there is no shape slot to read from anyway — length is synthesized from `arrayLength()`.
  A field is the minimal faithful mirror of "length is stored, distinct from count".
- The structural anchor is faithful: `array_count` ↔ `p->u.array.count`,
  `array_capacity` ↔ `p->u.array.u1.size`, `array_length` ↔ `p->prop[0].u.value` (semantically),
  with the same invariant set. The doctrine "mirror qjs structure" is satisfied at the
  semantic level; the field-vs-slot difference is the pre-existing zjs array idiom, not a new
  deviation.

### New invariants (assert these everywhere the old `capacity>=count` assert lives)

1. `array_capacity >= array_count` (unchanged; object.zig:3356, 3362).
2. `array_length >= array_count` (NEW — length never below the live dense extent).
3. Slots `[array_count, array_length)` are **HOLES**: `a[i]` there must resolve UP THE
   PROTOTYPE CHAIN, never return undefined-as-own; `i in a` / `hasOwn` / for-in / Object.keys
   must NOT see them.
4. `array_count` remains the sole bound for dense element access, enumeration, and the
   `array_values[0..count]` slice. `array_length` is ONLY the `.length` value + growth pivot.
5. A non-fast (sparse) array keeps `array_capacity == 0`, `array_count` MUST become 0 once
   sparse (today `setArraySparseLength` smears length into `array_count` — that is removed; see §2).

The invariant currently encoded as `setArrayLength` dropping fast_array on overflow
(object.zig:2174-2177) is DELETED: growing length above capacity no longer drops fast_array —
it just sets `array_length`. fast_array is dropped ONLY on a genuine non-tail `delete a[i]`
(`convertDenseArrayElementsToSparseProperties`, object.zig:9198, faithful to
`convert_fast_array_to_array` quickjs.c:9389).

---

## 2. WRITE-SIDE MACHINERY — the actual change surface (object.zig)

These are the functions whose `array_count`/`arrayLength()` conflation must be split. All live
in object.zig and are the heart of the change.

| fn | line | terminal behavior |
|---|---|---|
| `arrayLength()` | 2168 | return `self.array_length` (NOT array_count) when is_array, else 0 |
| `arrayLengthSlot()` | 2163 | return `&self.array_length` (no external callers; safe to re-point) |
| `setArrayLength` | 2172 | set ONLY `self.array_length = length`. **Remove** the capacity-overflow fast_array drop (2174-2177) and the `array_count == 0` assert — growing length above capacity is now legal & keeps fast_array. MUST NOT touch array_count. |
| `setArraySparseLength` | 3424 | set `array_length = length`; set `array_count = 0`; `fast_array = false`. (was smearing length into array_count — now length is its own field) |
| `truncateArrayElements` | 3188 | unchanged logic (frees `[new_len, count)`, lowers `array_count`); callers must ALSO call `setArrayLength` to lower length. After truncate, re-assert `array_length >= array_count`. |
| `convertDenseArrayElementsToSparseProperties` | 9198 | preserve length: it already saves `old_length = array_count` (9200) and restores it (9210); change to save/restore `array_length` instead, and materialize property slots for `[0, array_count)` only (the live elements). Holes in `[count, length)` become genuinely absent index properties on the sparse array — exactly qjs `convert_fast_array_to_array` (quickjs.c:9244-9283 copies only `u.array.count` slots). |
| `recomputeArrayStorageMode` | 9242 | `fast_array = capacity >= array_count` (unchanged — keys off count, correct). |
| `defineArrayLength` | 9115 | growth branch (9138) currently calls `convertDenseArrayElementsToSparseProperties` on `target_len > arrayLength()` — **DELETE that conversion**; growth now just `setArrayLength(target_len)` keeping fast_array (faithful to set_array_length quickjs.c:9447-9455). Truncation branch (9139-9156) keeps deleting index props ≥ target then `truncateArrayElements`+`setArrayLength`. |
| `setFastArrayCountAssumeCapacity` | 3549 | unchanged (sets count + fast_array). Callers that also change the LOGICAL length must set length too (shift/unshift/pop/splice — see array_ops below). |
| `appendUninitializedFastArraySlot` | 3511 | bumps count; callers append at count. |
| `takeLastFastArrayElement` / `shrinkFastArrayByOne` | 3438 / 3449 | lower count; the *pop* caller must ALSO lower length by 1 (pop reduces length). |
| `adoptDenseArrayElementsAssumingEmpty` | 3408 | set count=len, capacity=len, **length=len** (NEW), fast_array=true. |
| `appendDenseArrayIndex` | 8373 | the append precondition `index != self.arrayLength()` (8374) must become `index != self.array_count` — qjs `add_fast_array_element` appends at `count`, then bumps `length` to `count+1` only if `count+1 > length` (quickjs.c:9548-9559). After the append, `if (index >= array_length) array_length = index+1`. The existing `index != self.array_count` guard at 8382 is the real dense-append gate. |
| `appendDenseArrayValues` | 8389 | same: `start != array_count` is the real gate (8394 already checks it); after bulk append set `array_length = max(array_length, limit)`. The `start != arrayLength()` at 8391 must become `start != array_count`. |
| `appendDenseArrayLiteralIndex` | 8435 | `index != arrayLength()` (8436) → `index != array_count`; bump length after. |
| `appendDenseArrayInt32Range` / `...ValueRange` / `...MulAndMaskRange` | 8462 / 8484 / 8517 | each gates on `start != arrayLength()` AND `start != array_count`; collapse to `array_count` + bump length to `limit`. |
| `defineDenseArrayDataProperty` | 8587 | `appended = element_index == array_count` (8594) — correct; the `index >= arrayLength()` / `index != arrayLength()` length-writability checks (8597-8598) stay reading `array_length`; on append bump `array_length = max(array_length, index+1)`. |
| `defineDenseArrayDataPropertyUnchecked` | 8639 | same shape (8641 reads arrayLength for the assert; 8644-8645 `appended = == array_count`); bump length on append. |
| `initDenseArrayIndexZeroAssumingEmpty` / `initDenseArrayLiteralValuesAssumingEmpty` | 8422 / 8446 | empty-array fast inits; set length = count after fill. 8448 `arrayLength() != 0` → `array_count != 0` (must be empty dense to start). |
| `writeDenseArrayIndex` | 8360 | in-bounds overwrite (`index >= elements.len` bails, 8365) — keys off count via `arrayElements()`; unaffected, length unchanged. |
| `overwriteDenseArrayInt32MaskedIndexRange` | 8550 | mask check `>= array_count` (8561) — unaffected. |
| `deleteProperty` | 8958 | tail/non-tail delete already gated on `arrayElements().len`(=count) (8971); a tail delete lowers count but **delete does NOT change length** (qjs delete_property quickjs.c:9386 sets `count=idx`, leaves length) — so a `delete a[last]` correctly creates length>count i.e. a hole. NEEDS-CHECK: ensure the tail-delete path here lowers count without touching length (it goes through convert today; see correctness trap T2). |

**The single conceptual rule for all append/define sites:** the *storage* append index is
`array_count`; the *length* is bumped to `index+1` only when `index+1 > array_length`. That is
literally `add_fast_array_element` (quickjs.c:9548-9568).

---

## 3. EXHAUSTIVE READER AUDIT

Direct field access (`.array_count` / `.array_values` / `.array_capacity`) is **fully
encapsulated inside object.zig** — verified: zero external `.array_count` references
(grep over src/ minus object.zig/tests). Every other file goes through accessor methods. This
shrinks the blast radius to (a) object.zig internals (§2) and (b) external callers of
`arrayLength()` that must be classified as "length consumer" vs "dense-extent consumer".

### 3a. Core readers in object.zig — the ~11 hole-handling sites

| reader | line | class | terminal behavior |
|---|---|---|---|
| `denseArrayElement` | 9213 | UNAFFECTED (already correct) | `index >= self.array_count` (9217) → holes in `[count,length)` return `null` → `getProperty` falls to prototype walk (7076). **This is the load-bearing hole behavior and it already keys off count.** |
| `hasDenseArrayElement` | 9221 | UNAFFECTED | delegates to `isFastArrayIndexInBounds` → count. Hole → false (not own). |
| `isFastArrayIndexInBounds` | 3380 | UNAFFECTED | `index < self.array_count` — keep. |
| `fastArrayElementAt` / `...Slot` / `...Dup` asserts | 3384 / 3389 / 3394 | UNAFFECTED | all assert `isFastArrayIndexInBounds` (count). |
| `arrayElements()` / `arrayElementsMut` / `arrayElementsForCount` | 3354 / 3360 / 3544 | UNAFFECTED | slice `[0..array_count]`; the `capacity>=count` assert stays; ADD a debug assert `array_length >= array_count`. |
| `getProperty` (index path) | 7075 | UNAFFECTED | dense → 7075, else prototype walk (7076). Hole-correct. `.length` path (7048) reads `arrayLength()` → now the real length. |
| `getOwnProperty` | 6912 / 6865 | UNAFFECTED | dense own-descriptor via `denseArrayElement` (count); `.length` descriptor (6865-6866) via `arrayLength()` → real length. Hole → no own descriptor → falls through to `null` → ordinary [[Get]] climbs prototype. CORRECT. |
| `existsOwnProperty` | 6975 (dense at 7010) | UNAFFECTED | dense via `denseArrayElement` (count); `.length` present (6996). Hole → false. |
| `hasOwnProperty` | 6959 (dense at 6961) | UNAFFECTED | `denseArrayElement != null` (count). Hole → false. |
| `ownPropertyEnumerable` / `ownPropertyEnumerableKind` | 7023 / 6932 | UNAFFECTED | dense enumerable via `denseArrayElement` (count, 7034 / 6953); `.length` not-enumerable (7026 / 6945). Hole → not own. |
| `ownKeys` (the GPN walk) | 8981 (dense at 9003, 9010) | UNAFFECTED | enumerates `[0, arrayElements().len)` = `[0, count)` and appends `.length` (9036). **Holes are NOT enumerated** — exactly qjs quickjs.c:8657/8754 which use `u.array.count`. for-in / Object.keys / getOwnPropertyNames skip holes for free. |
| `hasPropertyIndexKeys` | 9917 | UNAFFECTED | walks shape index props not in dense (`hasDenseArrayElement`, count). |
| `convertDenseArrayElementsToSparseProperties` | 9198 | NEEDS-HOLE-HANDLING | materialize only `[0, count)` (already does — `arrayElements()` is count-bounded, 9201). Change save/restore of length from `array_count` to `array_length` (9200/9210). Holes stay absent (correct). |
| `deleteProperty` | 8958 | NEEDS-CHECK | tail vs non-tail; see T2. |
| `defineOwnProperty` array-index bump | 7754 / 8888 | NEEDS-HOLE-HANDLING | `if (index >= old_length) setArrayLength(index+1)` — `old_length = arrayLength()` (7751/8885) now the real length; setting an index ≥ length bumps length, leaving `[count,length)` holes if the index landed sparse. Reads `arrayLength()` correctly. |
| `defineArrayLength` | 9115 | NEEDS-HOLE-HANDLING | see §2 — drop sparse conversion on growth. |

### 3b. `arrayElements()` consumers (slices over dense storage) — UNAFFECTED

These read `arrayElements()` (count-bounded slice) — none assume length==count for the slice:
json.zig stringify (302, 775, 1465, 1831-1846), string_ops join (806, 825-826, 863, 4247,
4284-4314), iterator_ops (660), array_ops copyWithin/fill/indexOf/etc (1571, 1611, 1724, 2468,
2490, 2710, 2894, 2994, 3218, 3357, 3436, 4334, 4524, 4770, 4838, 5765, 5810-5811),
builtins/array indexSearch (819-823), typed_array (968), reflect_ops (197-208).
All slice `arrayElements()` for the dense region and either (a) bail to slow path when
`arrayLength() > elements.len` or (b) loop `getProperty` for `[count, length)`. **Already
hole-safe — they were written assuming count and length can diverge.** Examples verified:
- json simple-stringify (json.zig:1832): `if (object.arrayLength() > elements.len) return .fallback` → bails to hole-aware slow JSON path (holes→null).
- string_ops `qjsStringFromCodePointDenseArray` (string_ops.zig:826): `if (elements.len >= length)` fast branch only when fully dense; else shapeProps+`getProperty` walk (854+) which is prototype-aware.
- builtins/array `indexSearch` (array_ops.zig:820): `dense_len = min(elements.len, arrayLength())`; slow `getProperty` loop for the remainder (843).
- array_ops `qjsFastDensePrimitiveArrayJoin` (5810-5812): `if (length > elements.len) return null`.

### 3c. `arrayLength()` callers used as the ITERATION/LENGTH bound — re-point semantics

~150 call sites (full list from grep in working notes). They split into:
- **length-as-`.length`-value** (value_ops.zig:222-225, vm_arith.zig:653, vm_property_globals.zig:1194,
  zjs_vm.zig:2389 get_length fast path, binding/context.zig:427, root.zig:216): now return the
  REAL length. UNAFFECTED in code, semantics improve.
- **length-as-spec-iteration-bound** (`while index < arrayLength(): getProperty(index)` —
  value_ops.zig:1153, json.zig:302/775, string_ops.zig:806, array_ops.zig:4276, number.zig:242,
  collection/promise/construct builders): these iterate `[0, length)` reading `getProperty`,
  which is prototype-aware. Holes resolve correctly. UNAFFECTED.
- **length-as-dense-extent** (where code assumed count==length to scan `array_values` directly):
  these MUST be re-pointed to `array_count` / `arrayElements().len`. Verified offenders:
  - `vm_property_locals.zig:985` get_array_el int32 fast path: guards BOTH `index >= arrayLength()`
    (985) and `index >= elements.len` (987). The load-bearing bound is `elements.len`(count);
    the `arrayLength()` guard is harmless (count<=length) but should be dropped/kept as count.
  - `array_ops.zig:5810`, `json.zig:1832`, `string_ops.zig:826`: already use the
    `length vs elements.len` reconciliation (bail/fallback). Correct.

### 3d. Write/length-mutation callers that maintain count==length — NEEDS-FIX

- `vm_literal.zig:214` (length-write op): on growth calls `convertDenseArrayElementsToSparseProperties`
  → **DELETE the conversion**; just `truncateArrayElements`(no-op on growth)+`setArrayLength`.
  On shrink: `truncateArrayElements(new_len)`+`setArrayLength(new_len)` (keep).
- `vm_property_field.zig:394 setArrayLengthForPutFieldFastPath`: growth branch (415-416) bails;
  **change to set length larger** (keep fast_array, count unchanged) — the 19.5x. Shrink branch
  (407-414) frees props ≥ new_len and `truncateArrayElements`; then `setArrayLength(new_len)` (418).
- `builtins/array.zig:300-306` `new Array(n)`: currently `setArrayLength(n)` then
  `setArraySparseLength(n)` (forces sparse). **Terminal:** drop `setArraySparseLength`; just
  `setArrayLength(n)` on a fresh fast array → fast_array=1, count=0, length=n, holes. (Matches
  `new Array(n)` → set_array_length quickjs.c:9447-9455.)
- `array_ops.zig:3274 qjsFastDenseArrayShift`: `setFastArrayCountAssumeCapacity(len-1)` — shift
  removes element 0 and reduces LENGTH; after split must ALSO `setArrayLength(len-1)`. (It gates
  on full-dense via fastArrayValuesMut over count; today count==length so length tracked
  implicitly.)
- `array_ops.zig:3315 qjsFastDenseArrayUnshift`: `setFastArrayCountAssumeCapacity(new_length)` —
  must ALSO `setArrayLength(new_length)`. Gated on `length == fastArrayCount()` (3306), so only
  runs on a fully-dense array — set both.
- `array_ops.zig:3098 push` fast path: appends at `arrayLength()` via `appendDenseArrayValues`
  which bails unless `start == array_count`; on a holey array push falls to the slow path
  (correct). On a dense array works. Length bumped inside `appendDenseArrayValues` (see §2).
- pop fast path (array_ops.zig:3188/3196 `takeLastFastArrayElement`): pop lowers count by 1 and
  MUST lower length by 1 (pop reduces .length). NEEDS-FIX: caller must `setArrayLength(len-1)`.
- splice fast paths writing `setArrayLength` (array_ops.zig:344, 423, 1006; 3645/3657/.../3840
  ArraySpeciesCreate result; 4862, 4128, 4003) — these set length on result arrays; with split
  they produce pre-sized fast arrays (length=N, count filled as elements added). UNAFFECTED in
  shape; they gain the dense-prealloc win.
- `collection.zig:1023` / `closure.zig:867` (`expects.setArrayLength(arrayLength()-1)`): pop-style
  on internal arrays; must also shrink count via truncate OR is operating on a count==length
  array — verify each lowers count (these read element first then shrink; `setArrayLength` alone
  no longer drops the element from dense storage). NEEDS-FIX: pair with `truncateArrayElements`.

Reader count: **~17 core readers in object.zig + ~150 `arrayLength()` callers**; hole-handling /
NEEDS-FIX: **~11 object.zig sites + ~9 external write-path sites** (vm_literal, vm_property_field,
builtins/array ctor, shift, unshift, pop, collection pop, closure pop, defineArrayLength growth).
The large `arrayElements()` and `getProperty`-loop reader populations are UNAFFECTED because they
were authored count-aware.

---

## 4. CORRECTNESS TRAPS (ranked by blast radius)

**T1 — `a[i]` in `[count, length)` must climb the prototype chain (NOT undefined-as-own).**
This is THE load-bearing behavior. Already correct: `denseArrayElement` returns null for
`index >= array_count` (object.zig:9217) and `getProperty` then does
`proto.getProperty(atom_id)` (object.zig:7076). The trap is only if any re-point accidentally
makes a hole return undefined-as-own or makes `denseArrayElement` key off `array_length`. Guard:
`denseArrayElement`, `hasDenseArrayElement`, `isFastArrayIndexInBounds` MUST stay on `array_count`.
test: `Array.prototype[5]=7; var a=new Array(10); a[5]` must be 7, and `5 in a` must be false,
and `a.hasOwnProperty(5)` false.

**T2 — `delete a[i]` semantics.** qjs: tail delete `delete a[count-1]` sets `count=idx`, leaves
length (quickjs.c:9386) → creates a hole between new count and length; non-tail delete converts
to sparse (quickjs.c:9389). zjs `deleteProperty` (object.zig:8958-8978) currently converts to
sparse for ANY in-dense delete (8971-8974). Faithful terminal: a tail delete should lower count
WITHOUT converting (cheap hole) — but the simpler faithful-enough option is to keep the
convert-to-sparse for non-tail and special-case tail. MINIMAL terminal that preserves correctness:
keep the convert path (it's observationally identical — sparse array with the index absent), but
ensure length is preserved across the convert (the convert now saves/restores `array_length`).
Either way: after `delete a[i]`, `.length` is unchanged and `i in a` is false. test:
`var a=[1,2,3]; delete a[1]; a.length===3 && !(1 in a) && a[1]===undefined`.

**T3 — `arr.length = N` truncate/extend.** Extend (`N > length`): keep fast_array, set length=N,
count unchanged → `[count,N)` holes (set_array_length quickjs.c:9447-9455). Currently zjs forces
sparse (vm_literal.zig:214, defineArrayLength:9138) — DELETE those conversions. Truncate
(`N < length`): free dense `[N, count)`, count=min(count,N), then length=N; also delete index
props ≥ N (defineArrayLength:9139-9156 keeps this). test:
`var a=[1,2,3]; a.length=5; a.length===5 && !(3 in a) && a[3]===undefined; a.length=1; a[1]===undefined`.

**T4 — for-in / Object.keys / getOwnPropertyNames / JSON.stringify must skip/null holes.**
Enumeration (ownKeys object.zig:9003/9010) keys off count → holes excluded automatically
(matches qjs quickjs.c:8657/8754). JSON: array stringify reads `getProperty` over `[0,length)`
and emits `null` for undefined/hole (json.zig:1465+ slow path; simple path bails on holes at
1832). test: `Object.keys(new Array(3)).length===0`; `JSON.stringify(new Array(3))==='[null,null,null]'`.

**T5 — Array iteration callbacks skip holes; sort/copyWithin/fill over holey ranges.**
forEach/map/filter/etc iterate `[0,length)` and must skip holes (call `HasProperty` before the
callback). zjs builtins iterate via `getProperty`/`hasOwnProperty` — verify map/forEach use the
existence check on the spec path (array_ops generic loops at 4276 use `getProperty`; the dense
fast paths bail when `length > elements.len`). sort: dense sort runs only on `count==length`
(no holes); holey sort goes through the generic path. copyWithin/fill (array_ops 2490, fill):
dense fast path guarded by `arrayElements().len` reconciliation; holey ranges → slow path. test:
`var a=new Array(3); a[1]=9; var seen=[]; a.forEach((v,i)=>seen.push(i)); seen.join()==='1'`.

**T6 — pop/shift/unshift/length bookkeeping.** These mutate BOTH count and length; the fix is to
update `array_length` alongside `array_count` (shift/pop −1, unshift +k). Missing the length
update silently corrupts `.length`. (array_ops.zig:3274, 3315; pop callers; collection.zig:1023;
closure.zig:867.)

---

## 5. test262 RISK MAP

Watch (run the full 49775 + 1226 unit + 1226 force-GC; these are the hot dirs):
- `test262/test/built-ins/Array/length/` (define-own-prop-length-*, overflow/coercion order).
- `test262/test/built-ins/Array/prototype/` — every method over holey/sparse input: forEach,
  map, filter, reduce, indexOf, includes, join, fill, copyWithin, flat, sort, splice, slice,
  concat, push/pop/shift/unshift, at, find, keys/values/entries.
- `test262/test/built-ins/Array/` constructor (`new Array(n)` length, prop-desc, property-cast-*).
- `language/expressions/property-accessor`, `language/statements/for-in` (hole exclusion, order).
- `built-ins/Object/keys`, `Object/getOwnPropertyNames`, `Object/defineProperty` (array length
  & index), `Object/getOwnPropertyDescriptor` (holes → undefined descriptor).
- `built-ins/JSON/stringify` (array with holes → null).
- `language/expressions/in` and `Object/prototype/hasOwnProperty` (hole → false).
- `built-ins/Reflect/ownKeys`, `defineProperty`, `deleteProperty` over arrays.
Highest regression probability: anything asserting `delete a[i]` keeps `.length` (T2),
`new Array(n)` enumerability/holes (T1/T4), and `arr.length = bigger` not materializing own
indices (T3).

---

## 6. COUPLING TO L2 (property slot 40B → 16B)

**With the chosen field representation, L3's NORMAL path does NOT touch property slots.**
`.length` is a synthesized Object field (object.zig:6865-6867, 7048, 9036), not a real shape
slot, so growing/shrinking length writes only `array_length`. This is the deliberate advantage
of the field choice over qjs's prop[0].u.value: had we mirrored qjs literally, EVERY length
read/write would touch `prop[0]` and L3 would be hard-coupled to the L2 slot rewrite.

The ONE place L3 writes property slots is `convertDenseArrayElementsToSparseProperties`
(object.zig:9198): it materializes index data-property entries via `addProperty`
(`Descriptor.data(stored, true, true, true)`, 9205). That uses the L2 property-slot machinery
regardless of representation (qjs also writes slots in `convert_fast_array_to_array`). So:

- **Sequencing:** L3 and L2 meet ONLY at `convertDenseArrayElementsToSparseProperties` →
  `addProperty`/`appendPreparedPropertyEntry` (object.zig:9252/9257) and at the `defineArrayLength`
  truncation loop that `deleteProperty`s index slots (object.zig:9140-9148). Both are ordinary
  property-slot writes. If L2 changes the slot layout (40B→16B), these call sites are unchanged
  source-wise (they call `addProperty`/`deleteProperty`, not raw slot bytes).
- **Safe order:** L3 and L2 are **independent** and can land in either order. L3 adds an Object
  field (no slot interaction on the hot path); L2 reshapes the slot. The only shared code is the
  sparse-conversion property writes, which both treat as opaque `addProperty` calls. Recommend
  L3 FIRST (smaller, self-contained, unblocks the 19.5x) then L2 — but no hard dependency.
- If L2 were instead to choose to store array length in the slot (it should NOT), that would
  re-couple; flag this to the L2 agent: **keep array length OUT of the property slot; it is an
  Object field per L3.**

---

## 7. ONE-SHOT vs STAGED

**ONE-SHOT is feasible and is the right call.** Reasoning:

1. The reader surface is overwhelmingly already count-aware (§0, §3b): the `[count,length)`
   branches exist and are correct dead code today. Splitting the representation ACTIVATES them
   without rewriting them. There is no large population of readers that assume `count==length`
   and would silently break — they were authored against the divergent model.
2. The genuine edits are localized: ~11 object.zig functions (mechanical: re-point
   `arrayLength()`→`array_length` field, add length-bump-on-append, drop the two growth-time
   sparse conversions) + ~9 external write-path callers (shift/unshift/pop/length-write/ctor
   maintain length alongside count).
3. The change cannot be partially correct: a flag-gated half-state where some paths see split
   length and others see fused count would violate invariant 2/3 inconsistently and produce
   exactly the hole-vs-own bugs we are trying to avoid (T1). A staged rollout has NO coherent
   intermediate (you cannot have "holes representable in storage but length still == count").
   The terminal model is the only consistent model — doctrine "terminal-state, no flag-gated
   half-states" applies and a one-shot is provably the only coherent shape.
4. Correctness is gated by test262 0/49775 + 1226 + 1226; the change is mechanical enough to
   land and validate in one commit.

The ONLY judgment call inside the one-shot is T2 (tail-delete cheap-hole vs convert-to-sparse).
Recommend the conservative faithful-enough choice (keep convert-to-sparse for non-tail; make
tail delete lower count without convert) — both are observationally identical for correctness;
the cheap-tail-hole is the qjs-literal mirror (quickjs.c:9386) and slightly faster, so prefer it,
but it is not load-bearing for passing the suite.

---

## Appendix — verified anchors (HEAD 9df4dc4)

zjs/src/core/object.zig: Object fields 1161-1163; ObjectFlags 1082-1105 (_padding u14 at 1104);
arrayLengthSlot 2163; arrayLength 2168; setArrayLength 2172; arrayElementStorageMode 3350;
arrayElements 3354; isFastArrayIndexInBounds 3380; fastArrayElement* 3384-3406;
adoptDenseArrayElementsAssumingEmpty 3408; setArraySparseLength 3424; truncateArrayElements 3188;
setFastArrayCountAssumeCapacity 3549; getOwnProperty 6856 (.length 6865, dense 6912);
ownPropertyEnumerable* 6932/7023; existsOwnProperty 6975; hasOwnProperty 6959; getProperty 7045
(.length 7048, dense 7075, proto 7076); defineOwnProperty index-bump 7754/8888;
appendDense* 8360-8548; defineDenseArrayDataProperty* 8587/8639; setProperty .length 8667;
deleteProperty 8958; ownKeys 8981 (dense 9003/9010, length 9036);
defineArrayLength 9115; convertDenseArrayElementsToSparseProperties 9198;
denseArrayElement 9213; hasDenseArrayElement 9221; recomputeArrayStorageMode 9242;
hasPropertyIndexKeys 9917; arrayLengthValue 9836.
zjs external: builtins/array.zig:300-306 (new Array(n)); vm_literal.zig:211-217 (length write);
vm_property_field.zig:394-420 (put-field length fast path); vm_property_locals.zig:985-987
(get_array_el i32 fast path); array_ops.zig:3098 (push), 3263-3275 (shift), 3286-3329 (unshift),
3188/3196 (pop), 3635-3682 (ArraySpeciesCreate), 5802-5812 (dense join);
string_ops.zig:806/823-852 (fromCodePoint dense); json.zig:1825-1857 (simple stringify);
builtins/array.zig:815-856 (indexSearch).
quickjs.c: layout 1050-1072; class comment 125; array init 5654-5673/5695-5702; JS_NewArray 5841;
get element 8298-8307; getOwnProperty 8867-8883; GPN 8654-8697 & 8750-8769; delete 9371-9402;
set_array_length 9433-9521; expand_fast_array 9524-9538; add_fast_array_element 9542-9570;
js_allocate_fast_array 9575-9599; js_create_array 9601-9623; convert_fast_array_to_array 9244;
js_array_constructor 41669-41694.
