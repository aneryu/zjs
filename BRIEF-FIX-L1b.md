# FIX-L1.b — restore qjs's intrusive list_head GC node (O(1) removal) — COPY qjs, do NOT invent

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align, current tip 04919169). DIAGNOSIS: commit 0ba89824 ("delete 24B GcNode") MISREAD the goal — it deleted qjs's intrusive doubly-linked `list_head` GC node and replaced it with a FLAT ARRAY `gc_objects: []*GCObjectHeader` (gc.zig ~:560). Now every object free calls `removeGcObject` (gc.zig:1223) → `gcObjectIndex` = a FULL LINEAR SCAN (gc.zig:1235) + `copyForwards` tail-shift (1226) = **O(n) per free × O(n) frees = O(n²)**. This HANGS splay (never finishes) and makes box2d do 3.4x the instructions. It is the EXACT INVERSE of qjs's design.

## What qjs does (the target — copy it faithfully)
quickjs.c: `JSGCObjectHeader { int ref_count; JSGCObjectTypeEnum gc_obj_type:4; uint8_t mark:4; uint8_t dummy1..3; struct list_head link; }` — the **`struct list_head link` (prev+next, 16B) IS the GC membership node, embedded in the header**. Add a GC object: `list_add_tail(&h->link, &rt->gc_obj_list)` (quickjs.c ~:6543) = O(1). Remove: `list_del(&h->link)` (quickjs.c ~:6548) = O(1) pointer splice. The cycle collector walks `gc_obj_list` via the embedded links. NO array, NO scan, NO shift.

## Do this
1. **Restore an intrusive doubly-linked list node in the GC object header** — `prev: ?*GCObjectHeader, next: ?*GCObjectHeader` (or a `list_head`-equivalent), 16B, embedded in the header that L1.b stripped (gc.zig:334-342 BlockHeader). Keep the L1.b WIN of folding rc+mark+color into spare header bits (that part was correct) — ONLY restore the list link.
2. **Replace the flat `gc_objects: []*GCObjectHeader` array + `removeGcObject`/`gcObjectIndex`/`copyForwards` (gc.zig:1223-1240) with O(1) intrusive list ops:** add-on-alloc = splice into the head/tail of the runtime's gc object list (O(1)); remove-on-free = unlink prev/next (`list_del`, O(1)). The cycle collector's iteration over candidates walks the list via next pointers. Delete `gc_objects`, `ensureGcObjectCapacity`, `gcObjectIndex`, `copyForwards`, `removeGcObject`'s scan.
3. This re-adds 16B to the object header (Object grows from ~68B back to ~84B) — that is CORRECT and qjs-faithful (qjs's 64B JSObject INCLUDES the 16B list_head; the 8B-header "savings" were illusory — they caused the O(n²)). Object ~84B is still far below the original 128B and now has O(1) GC.

## Gate (CORRECTNESS ONLY) — GC soundness is the point
1. Build 3 flags 0 errors. `zig build test --summary all` → 1192 passed; 0 failed.
2. GC-stress (tiny gc threshold 64): cycle test `zig-out/bin/zjs -e 'for(var i=0;i<200000;i++){var a={},b={};a.b=b;b.a=a;a=null;b=null;} var s=0;for(var i=0;i<800000;i++){var o={x:i};s+=o.x;} print(s)'` → correct, no leak/UAF. Revert threshold.
3. **THE FIX PROOF — splay must finish fast now:** `timeout 20 zig-out/bin/zjs /home/aneryu/javascript-zoo/bench/splay.js` MUST print a `Splay: <score>` (it currently HANGS >35s). Also box2d.js prints a score. Report splay + box2d scores vs the aligned baseline (/tmp/zjs-aligned ~Splay 665-2019, box2d 661).
4. `zig fmt`; commit `fix(zjs): restore intrusive list_head GC node — O(1) removal (was O(n^2) flat-array scan)`.

## Constraints
- COPY qjs's intrusive-list approach EXACTLY. Do NOT invent another membership structure. The whole bug was a reinvention; the fix is fidelity to qjs.
- The cycle collector (trial deletion) iteration must still visit all candidates — via the list links now, not the array.
- Correctness is the only gate; commit on green. The splay-finishes-fast check is the regression proof.
