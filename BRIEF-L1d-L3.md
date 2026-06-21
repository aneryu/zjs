# L1.d + L3 — finish Object shrink (owner_runtime + property_capacity) + inline fast-array u.array

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align, builds on L1.b commit 0ba89824). Object is now ~84B (was 128B; relocated length/iterator/exotic, deleted GcNode). Two more pieces toward qjs's 64B + the fast-array repr.

## Part A — finish the Object field shrink (→ ~68B, qjs parity)
1. **owner_runtime (8B)** — qjs JSObject has NO per-object runtime pointer (it threads *JSRuntime/JSContext on the call path). Remove `owner_runtime` from Object; thread `*JSRuntime` to the (few) sites that read `object.owner_runtime` — it is available at every site via ctx / the frame / the GC (which holds the runtime). If a site genuinely cannot get the runtime cheaply, report it and leave the field.
2. **property_capacity (8B)** — qjs stores prop_size in the shared Shape, not per-object. Derive capacity from the shape (shared shapes have a fixed prop_size) or from `properties.len` + the slab size-class. Keep an inline capacity ONLY for dictionary-mode objects (flag-gated, off the common path). Drop it from the common Object.

## Part B — inline fast-array u.array + strip the element path (audit lever #3: 12.4x → ~4 checks)
Audit: a JS array = Object + a SEPARATE 40B ArrayPayload (elements slice+cap+realm) + the elements buffer = 3 allocs and a class_payload double-deref; the element read path is ~12 guarded steps incl a per-read atomFromUInt32 + an objectFindPropertyFast shape-hash guard (call_internal.zig ~:559). qjs: u.array is inline in the JSObject union (u1.size, u.values:JSValue*, count) — one alloc, and the fast path is just: tag==object, idx is int, fast_array bit set, idx<count → values[idx].dup().
1. **Fold array metadata inline:** add `array_count: u32` + `array_values: [*]JSValue` as Object fields used only when the object is a fast array (qjs u.array). Eliminate the separate 40B ArrayPayload allocation and the `class_payload` double-deref for fast arrays. (These two fields fit in the space freed by Part A / the relocated fields; net Object size should stay ≤ ~76B even with them, and arrays save the 40B payload alloc.)
2. **Add a `fast_array` bit** (in Object.flags) that is SET for a contiguous dense int-keyed array and CLEARED the moment the array goes sparse / gets a hole / gets an accessor / becomes a proxy / changes storage mode. Hoist all the proxy/exotic/storage-mode checks into this single bit.
3. **Strip the element get/set fast path** (in exec/call_internal.zig get_array_el/put_array_el arms + exec/vm_property_field.zig / array_ops.zig) to qjs's ~4 checks: `value.isObject()`, `index.asInt32()` ok, `obj.flags.fast_array`, `idx < array_count` → `array_values[idx]` (.dup() on read). DROP the per-read `atomFromUInt32` (no atom needed for a fast int index) and the `objectFindPropertyFast` shape-hash guard on the fast-array path. The slow path (sparse/proxy/OOB/accessor) keeps the existing general property machinery.
4. Update array creation/grow/push/length to maintain array_count + array_values + the fast_array bit. Grow reallocates array_values (a single buffer), keeping it contiguous.

## Gate (MUST pass; commit when green) — CORRECTNESS ONLY, do NOT judge/revert on perf
1. Build 3 flags 0 errors.
2. `zig build test --summary all` → 1192 passed; 0 failed.
3. Array correctness smoke: `zig-out/bin/zjs -e 'var a=[1,2,3];a.push(4);a[10]=5;delete a[1];a.length=2; var b=[];for(var i=0;i<1000;i++)b[i]=i*i; var s=0;for(var i=0;i<b.length;i++)s+=b[i]; print(a.join(",")+"|"+s+"|"+[3,1,2].sort().join(""))'` (exercises push, hole→sparse transition, delete, length-set, dense fill, sort). Plus crypto.js + navier-stokes.js run.
4. Commit each part separately if cleaner: `git commit -m "perf(zjs): L1.d drop owner_runtime + property_capacity from Object (~68B)"` then `git commit -m "perf(zjs): L3 inline fast-array u.array + strip element path"`. `zig fmt` first.

## Constraints
- CORRECTNESS is the only gate (the array hole/sparse/accessor/proxy transitions are the risk — the fast_array bit MUST clear on every transition out of dense-contiguous-int, or you'll read stale/wrong elements). When unsure, clear the fast_array bit (safe, falls to slow path).
- Do NOT judge/revert on perf — commit on correctness-green.
- Do NOT touch the GcNode (done), FunctionPayload (done), the dispatcher, or the allocator (separate L2 step).
- If Part B (inline array) is too entangled to land cleanly, do Part A (the 2 field drops) + COMMIT, then attempt Part B and report how far you got.
