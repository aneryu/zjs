# FIX-L2 — re-implement the slab FAITHFULLY to qjs (O(1) free + arena page-release) — COPY qjs

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align, builds on the FIX-L1.b commit). DIAGNOSIS of the current slab (commit 105d5607, memory.zig): it has TWO codex divergences from qjs that caused code-load -65% + RSS going UP:
1. **free() is O(arena-count):** `rawFree` (memory.zig:366) calls `owns()` (memory.zig:106-115) which LINEAR-SCANS the whole arena list to decide slab-vs-persistent ownership. On code-load (hundreds of arenas) this is O(n²) and pure memory-stall (perf: freeAlignedBytes 65% self, the owns() loop; IPC 4.0→1.8).
2. **never releases pages:** arenas are bump-only and only freed at runtime deinit → transient parse/compile garbage stays resident (code-load RSS 34.4→35.6MB). Plus size-class round-up (68B→80B class) + one 4KiB arena per size class over-provisions.

## What qjs does (quickjs.c js_def_malloc / the slab at ~:1600-1640 — copy it)
- **O(1) free via pointer arithmetic, no ownership scan:** qjs recovers the arena from the block pointer directly: `ar = (JSMallocArena *)((uintptr_t)b - block_size * block_idx - sizeof(JSMallocArena))` — i.e. the arena header sits at a known offset before the block, computable from the block address + its size class. No list walk. (To know slab-vs-large without a scan: tag the allocation — e.g. a header byte/bit on each block, or align arenas so the arena header is findable by masking the block address to the arena base. qjs stores enough in the block/arena header to recover the arena and its size class in O(1).)
- **arena page-release:** qjs tracks `n_used_blocks` per arena; on free, decrement; **when `n_used_blocks == 0`, `list_del` the arena and `js_free`/munmap it back to the OS** (quickjs.c ~:1627-1631). This is the mechanism that keeps RSS from being a high-water-mark.

## Do this (faithful port)
1. **Make free O(1):** give each slab block a way to find its arena + size-class WITHOUT scanning — either (a) a small per-block/per-arena header recovered by pointer arithmetic / address masking (arenas allocated aligned so `arena_base = block_ptr & ~(arena_size-1)`), or (b) a per-block tag. Remove the `owns()` linear scan from the free hot path. Replace `rawFree`'s ownership test with the O(1) recovery.
2. **Release empty arenas:** track `used_blocks` (or `n_used`) per arena; free() decrements it; when it reaches 0, unlink the arena from its size-class arena list and return its pages to the OS (the page allocator / munmap). This fixes the RSS high-water-mark.
3. **Reduce over-provision (optional but helps RSS):** if 1-arena-per-size-class wastes too much, allow arenas to be reused/shared or sized appropriately; at minimum ensure empty arenas are released (step 2). Keep size classes but confirm the round-up is qjs-comparable.
4. Keep the alloc fast path O(1) (free-list pop / bump) — that part was fine.

## Gate (CORRECTNESS + the regression PROOFS)
1. Build 3 flags 0 errors. `zig build test --summary all` → 1192 passed; 0 failed.
2. GC-stress (tiny threshold 64): `zig-out/bin/zjs -e 'for(var i=0;i<200000;i++){var a={},b={};a.b=b;b.a=a;a=null;b=null;} var s=0;for(var i=0;i<800000;i++){var o={x:i,y:[i,i+1]};s+=o.x+o.y[0];} print(s)'` → correct, no leak/UAF. Revert threshold.
3. **REGRESSION PROOFS:** (a) code-load must recover: `zig-out/bin/zjs /home/aneryu/javascript-zoo/bench/code-load.js` score should be back near /tmp/zjs-aligned (~2000-2200), NOT the broken ~550-700. (b) RSS must plateau / drop: `/usr/bin/time -v zig-out/bin/zjs -e 'var a=[];for(var i=0;i<2000000;i++){a.push({x:i});if(a.length>1000)a.shift();}print(a.length)' 2>&1 | grep Maximum` — RSS should be bounded (free-list recycle + arena release). Report code-load score + the RSS plateau number.
4. `zig fmt`; commit `fix(zjs): faithful qjs slab — O(1) ptr-arith free + empty-arena page release (was O(arena) scan + no release)`.

## Constraints
- COPY qjs's slab approach EXACTLY (O(1) arena recovery + n_used_blocks page-release). Do NOT invent. The bug was a reinvention; the fix is fidelity.
- GC-soundness + no-leak is the hard gate (a slab bug = UAF/corruption/leak). When unsure, keep the safe path and slab only the clearly-hot monomorphic allocs; report coverage.
- Correctness is the only gate; commit on green. The code-load-recovers + RSS-plateaus checks are the regression proofs.
