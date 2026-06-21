# L2 — direct per-runtime small-object slab allocator (kill vtable indirect + atomic-per-alloc)

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align, builds on L3 commit e488c5ee). Audit lever #2 (co-highest impact, measured objloop 3.26x instr / 3.31x wall vs qjs). Goal: replace the hot allocation path's generic-allocator indirection with a direct small-object slab, mirroring qjs.

## The divergence (audit, objdump-confirmed)
Every Object/payload/property-buffer/string allocation currently goes through: the std.mem.Allocator VTABLE (`blr` indirect call to .alloc), PLUS a nullable trigger_gc indirect check, PLUS an atomic mutex tryLock/unlock into smp_allocator, PLUS ~30 instr of MemoryAccount bookkeeping — PER ALLOCATION. qjs uses a ~10-instr lock-free slab: size-class free-lists over 4KiB arenas, a direct (monomorphic) call, no atomics (single-threaded runtime), no vtable. Files: core/memory.zig ~:89-156, core/runtime.zig ~:738-743, and the GC alloc/free in core/gc.zig.

## Do this
1. Implement a **per-JSRuntime small-object slab**: size classes (e.g. 16,24,32,48,64,80,96,128,...512B like qjs `block_sizes`), each a free-list of blocks carved from 4KiB (or larger) arenas. Allocation = pop the size-class free-list head (or carve from the current arena / grab a new arena); free = push onto the free-list. NO atomics / mutex (the JS runtime is single-threaded, like qjs — confirm and drop the smp_allocator path for runtime-internal JS-object allocs). Large allocs (>512B) fall back to the page/general allocator.
2. **Route the hot allocations through it via a MONOMORPHIC inline call** (not the std.mem.Allocator vtable): Object, the class payloads (ArrayPayload/FunctionPayload/etc.), the property buffer, shape buffers, and small strings. The call site must be a direct call to the slab method, so LLVM can inline the fast path (free-list pop) — NO `blr` through a vtable on the hot path.
3. **Remove the per-alloc overhead**: comptime-gate the MemoryAccount/trace/profile counters OFF in release builds (or reduce them to a single plain add folded into the slab); call `trigger_gc` DIRECTLY (not through a nullable function-pointer indirect) — the GC-trigger check should be a plain `if (bytes_since_gc > threshold)` inline, not an indirect call. Drop the atomic mutex per alloc.
4. **GC integration MUST stay sound**: the GC sweep must free slab blocks back to the correct size-class free-list (not the general allocator). Every GC-managed object's header must let the sweep find its size class (the BlockHeader already has size_class — use it). Allocation must register the object with the GC (cycle-collector roots/list) exactly as before. Do NOT change WHAT the GC collects, only WHERE memory comes from.

## Gate (MUST pass; commit when green) — CORRECTNESS ONLY; this touches alloc + GC so GC-soundness is the risk
1. Build 3 flags 0 errors.
2. `zig build test --summary all` → 1192 passed; 0 failed.
3. **GC-STRESS (critical):** tiny gc threshold (default_gc_threshold = 64 in runtime.zig), rebuild recursive, run the cycle+alloc stress: `zig-out/bin/zjs -e 'for(var i=0;i<200000;i++){var a={},b={};a.b=b;b.a=a;a=null;b=null;} var s=0;for(var i=0;i<800000;i++){var o={x:i,y:[i,i+1]};s+=o.x+o.y[0];} print(s)'` → correct output, NO leak/UAF/double-free/panic. Run splay.js (alloc/GC-pause heavy) + earley-boyer.js. REVERT the threshold hack.
4. **Leak check:** run a bounded alloc loop and confirm RSS stabilizes (no unbounded growth = slab free-list is recycling): `var a=[];for(var i=0;i<2000000;i++){a.push({x:i});if(a.length>1000)a.shift();}print(a.length)` → RSS must plateau.
5. richards.js / deltablue.js run + print scores.
6. `zig fmt`; `git add -A && git commit -m "perf(zjs): L2 direct small-object slab allocator (no vtable/atomic per alloc)"`.

## Constraints
- CORRECTNESS / GC-SOUNDNESS / NO-LEAK is the only gate and the whole risk — a slab bug = corruption/UAF/leak. The GC-stress cycle test + the leak/RSS-plateau test are the proofs; both MUST pass. When unsure about a path's GC interaction, route it through the EXISTING allocator (safe) and slab only the clearly-hot monomorphic Object/payload allocs; report what you slabbed vs left.
- Do NOT judge/revert on perf — commit on correctness-green.
- Do NOT touch the dispatcher / value repr / the already-done Object fields.
- This is a large self-contained subsystem; if the full slab is too big to land safely at once, land the slab for the single hottest alloc class (Object + ArrayPayload) with sound GC + no leak, COMMIT, and report coverage. Partial-but-sound beats broad-but-buggy.
