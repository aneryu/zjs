# L1.a — Object field relocations: 128B → ~92B (low-risk mechanical, gated)

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align @ 3be3ea4f). Goal: shrink `core/object.zig` Object from 128B toward qjs's 64B by relocating fields that are class-specific or relocatable, WITHOUT touching the GC node yet (that is a separate riskier step). This step alone targets ~128→~92B. This is the #1 ranked perf lever (audit: zjs Object 128B vs qjs JSObject 64B → RSS richards 2.44x / deltablue 2.40x; object-heavy benches spend 2x memory traffic + cross 2 cache lines per object vs qjs's 1).

## Context — current Object layout (128B, measured @sizeOf):
header@0(8B), gc@8(24B GcNode — LEAVE for now), class_payload@32(8B), owner_runtime@40(8B), shape_ref@48(8B), prototype@56(8B), cached_iterator_next@64(8B ?JSValue), properties@80(16B slice), property_capacity@96(8B), exotic@104(8B), length@112(4B), class_id@116(2B), flags@118(2B), class_payload_kind@120(1B).

qjs JSObject (64B) keeps NONE of: a runtime ptr, an inline iterator-next, an inline array length, a per-object exotic ptr, or an inline prop capacity — they live in the per-class union, the shared Shape, or a global class table.

## Do these relocations, each gated on `zig build test` staying 1192/0 + a smoke run, COMMIT after each (or as one commit if cleaner):
1. **`length` (4B @112)** — used only when `flags.is_array` (object.zig ~4249, ~7741). Move it into the array's class payload (ArrayPayload, object.zig:719 — it already has the elements slice; array length is the slice's logical count). Plain/closure/etc. objects never use `length`. Update all readers/writers of `object.length` to go through the array payload.
2. **`cached_iterator_next` (8B @64, ?JSValue)** — used only by iterator objects (cross-class but only iterators populate it). Move it into IteratorPayload (or the relevant class payload). If it is genuinely cross-class (multiple classes cache it), put it in a small payload allocated only for objects that use it. Verify which classes read/write it (grep cached_iterator_next) and relocate accordingly.
3. **`exotic` (8B @104, ptr to exotic methods)** — replace the per-object pointer with a `class_id` → global exotic-methods table lookup (qjs JSClass model: one global table indexed by class_id, not a per-object pointer). Add a comptime/global table mapping class_id → the exotic methods struct; replace `object.exotic` reads with `exoticMethodsFor(object.class_id)`.
4. **`property_capacity` (8B @96)** — qjs stores prop_size in the shared Shape, not per-object. If the capacity is derivable from the shape (shared shapes have a fixed prop_size) OR from `properties.len` + the allocator's size-class, drop the inline field and source it from there. If property_capacity can diverge from the shape per-object (e.g. dictionary-mode objects), keep it ONLY for those (a flag-gated payload) and drop it from the common path.
5. **`owner_runtime` (8B @40)** — qjs passes JSContext/JSRuntime explicitly. Drop the per-object runtime pointer; thread `*JSRuntime` to the (few) call sites that read `object.owner_runtime` — it is available at every hot site via ctx/frame/the GC (which holds the runtime). This is the most call-site-touching of the five; if it is read in too many awkward places, defer it and report.

After each relocation, re-check `@sizeOf(Object)` (a tiny probe test or a comptime log) and confirm it dropped. Target: 128 → ≤92B (all five) or as many as land cleanly.

## Gate (MUST pass; commit when green)
1. Build 3 flags 0 errors (`zig build zjs`, `-Dzjs_tailcall_dispatch=true`, `-Dzjs_recursive_dispatch=true`).
2. `zig build test --summary all` → 1192 passed; 0 failed.
3. Smoke (release recursive): a couple Octane benches run (`zig-out/bin/zjs /home/aneryu/javascript-zoo/bench/richards.js` prints a score; deltablue.js; raytrace.js).
4. **MEASURE:** report the new `@sizeOf(Object)`, and RSS on richards + deltablue (`/usr/bin/time -v zjs richards.js 2>&1 | grep Maximum` or read /proc) vs the c0be6fce/aligned baseline (/tmp/zjs-aligned) — expect RSS to drop proportionally to the object shrink. Also richards/deltablue best-of-3 score vs /tmp/zjs-aligned.
5. `zig fmt` touched files; `git add -A && git commit -m "perf(zjs): L1.a Object field relocations 128B->~92B (length/iter/exotic/capacity/runtime out of Object)"`.

## Constraints
- Correctness first — test262 0/49775 is the hard gate (I run the authoritative 3-flag test262 after; you run `zig build test` 1192/0 + smoke). The relocations must be semantically identity-preserving (same values, just stored elsewhere).
- Do NOT touch the GcNode (24B) or the FunctionPayload (648B) in THIS step — those are separate follow-up milestones.
- If a relocation is too entangled (esp. owner_runtime or property_capacity), land the ones that are clean, COMMIT them, and report which you deferred + why + the @sizeOf reached.
- This is a structural perf change: do NOT revert a relocation for a small/no perf delta — only correctness blocks. The compounding win comes from the full shrink + the later GcNode/FunctionPayload steps.
