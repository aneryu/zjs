# L1.b — delete the 24B GcNode from Object (fold into header, single rc/mark) — GC-DELICATE

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align, builds on L1.c commit bb284594). Goal: remove the 24-byte `gc: GcNode` field from Object (the single biggest avoidable field). Audit: Object has `header@0(8B BlockHeader: size_class+kind+flags+rc)` AND a separate `gc@8(24B GcNode: prev+next+tmp_rc+color+pad)` — this DUPLICATES the refcount (BlockHeader.rc AND GcNode.tmp_rc) and the mark (BlockHeader.flags.mark AND GcNode.color), and adds a 24B intrusive cycle-collector node. qjs's GC link IS the 16B header list_head (the node), and the trial refcount/color live in the header. Target: 24B removed → Object drops ~24B toward 64B, AND fewer stores per allocation.

## Background to read FIRST
- core/gc.zig: the Z-GE trial-deletion cycle collector. Find every use of GcNode.prev/next (the intrusive worklist/roots list), GcNode.tmp_rc (the trial refcount the collector decrements during the mark/scan phase), GcNode.color (white/gray/black/purple cycle-collector color). Understand the collection algorithm's phases (decrement-ref / scan / collect) and exactly when tmp_rc and color are live.
- core/object.zig + the BlockHeader / allocation header: what `rc` and `flags` already hold.

## Do this (carefully, GC correctness is paramount)
1. **prev/next (the intrusive list, 16B):** fold the cycle-collector worklist/roots link into the allocation header (qjs model: the header's list link IS the GC node). If every GC-managed object already has a header with space (or can carry two pointers for the roots list), move the list link there. If a separate roots list is cheaper, ensure it doesn't reintroduce 24B per object.
2. **tmp_rc (the trial refcount):** the cycle collector needs a SEPARATE decrementable count during collection. Options (pick the one matching the algorithm): (a) reuse BlockHeader.rc directly with the qjs-style save/restore (the collector saves the real rc, works on it, restores) ; (b) store the trial count in a transient side-table/array indexed only for objects currently in the collector's worklist (so it costs 0 per-object in steady state) ; (c) pack it into spare header bits if the count range allows. Do NOT keep a permanent per-object 4-8B tmp_rc.
3. **color (cycle-collector color, 2-4 states):** pack into spare bits of BlockHeader.flags (mark + a 2-bit color), reusing the existing mark bit as one of the states. Drop GcNode.color.
4. Delete the `gc: GcNode` field from Object; update Object init/deinit and every GcNode reader.

## Gate (MUST pass; commit when green) — CORRECTNESS ONLY; GC correctness is the hard part
1. Build 3 flags 0 errors.
2. `zig build test --summary all` → 1192 passed; 0 failed.
3. **GC-STRESS (critical for this step):** set the gc threshold tiny (e.g. default_gc_threshold = 64 in core/runtime.zig), rebuild recursive, and run a cycle-heavy + alloc-heavy script that creates and drops reference CYCLES (so the cycle collector runs hard), e.g. `zig-out/bin/zjs -e 'for(var i=0;i<200000;i++){var a={},b={};a.b=b;b.a=a; a=null;b=null;} var s=0;for(var i=0;i<500000;i++){var o={x:i};s+=o.x;} print(s)'` → correct output, NO leak/UAF/panic. Also run splay.js (GC-pause-heavy) + a generator/closure test. Then REVERT the threshold hack.
4. (smoke) richards.js + deltablue.js at /home/aneryu/javascript-zoo/bench/ run + print scores.
5. `zig fmt`; `git add -A && git commit -m "perf(zjs): L1.b delete 24B GcNode — fold GC link into header, single rc/mark"`.

## Constraints
- CORRECTNESS / GC SOUNDNESS is the only gate and the whole risk. The cycle collector MUST still correctly collect reference cycles (the GC-stress cycle test above is the proof) and must not double-free or leak. If you cannot fold tmp_rc/color soundly without a permanent per-object field, do the SAFE partial (e.g. fold only prev/next + color, keep a minimal tmp_rc) and report the size reached + why.
- Do NOT judge or revert on performance — commit on correctness-green. Perf measured later.
- Do NOT touch the dispatcher or the FunctionPayload (already done).
- This is the riskiest field; if anything about the collector's invariants is unclear, prefer the conservative folding that provably preserves them over maximal shrink.
