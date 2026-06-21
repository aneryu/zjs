# L4 — shrink closure var-ref (160B → toward qjs's 48B JSVarRef aliasing the live slot)

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align, builds on L2 commit 105d5607). Audit lever #4 (Medium-High). Goal: cut the per-captured-variable cost in closures.

## The divergence (audit)
zjs: a closure-captured variable (var-ref) is a ~160B JSObject + payload (2 allocs + a shape), and reading a captured var goes through a ≤16-deep CELL CHAIN (~25-40 instructions per captured-var read). qjs: a JSVarRef is ~48B and, while the enclosing frame is alive, it ALIASES the live stack slot directly (pvalue points at the frame slot); it is "closed" (boxed, value copied into the ref) only when the frame is about to be popped while a closure still references it. So qjs captured-var read = ~3-4 instructions (load *pvalue).

## Do this (read exec/frame.zig var_refs + how closures create/read/write captured vars first)
1. Make the var-ref a SMALL dedicated struct (a JSVarRef equivalent), NOT a full JSObject + payload + shape. It needs: a `value` slot and a `pvalue: *JSValue` that points either at the live frame slot (open) or at its own `value` (closed). ~16-32B, allocated from the slab (L2).
2. **Open var-ref aliases the live frame slot:** while the defining frame is on the stack, `pvalue` points at `frame.locals[idx]` (or the operand-stack slot). Read/write captured var = `*pvalue` — direct, no cell-chain. (Requires the frame's local slots to be address-stable while open — the explicit VM stack from M1 + the slab should give stability; if the operand stack can move, point pvalue at a stable locals region, not a movable one.)
3. **Close on frame exit:** when a frame is popped and a closure still holds a ref to one of its slots, copy the slot value into the var-ref's own `value` and repoint `pvalue` at it. Maintain a per-frame list of open var-refs to close (qjs's sf->var_refs / the close-on-leave pass).
4. **Eliminate the cell chain:** today reads walk a ≤16-deep chain — replace with the single `*pvalue` deref. Update all captured-var read/write sites (get_var_ref / put_var_ref opcodes + closure creation in exec/* and the bytecode that builds closures).
5. If the audit's "3 separable fixes / Fix C is cheap" applies, do the cheap one first (e.g. just shrinking the ref struct + slab-allocating it, before the full open/close aliasing) and COMMIT, then the aliasing.

## Gate (MUST pass; commit when green) — CORRECTNESS ONLY
1. Build 3 flags 0 errors.
2. `zig build test --summary all` → 1192 passed; 0 failed.
3. Closure-correctness smoke (capture, mutation-through-closure, escape, recursion, loop-capture): `zig-out/bin/zjs -e 'function mk(){var c=0;return {inc:function(){return ++c},get:function(){return c}}} var o=mk();o.inc();o.inc();var fns=[];for(var i=0;i<3;i++){(function(j){fns.push(function(){return j})})(i)} function counter(){var n=0;return function(){return n++}} var k=counter();k();k(); print(o.get()+"|"+fns.map(function(f){return f()}).join(",")+"|"+k())'` → expect `2|0,1,2|2`. Plus earley-boyer.js + raytrace.js run.
4. GC-stress (tiny threshold): closures holding cycles + dropped — cycle collector must reclaim var-refs; no leak/UAF. Revert threshold.
5. `zig fmt`; commit `perf(zjs): L4 small var-ref aliasing live slot (was 160B JSObject)`.

## Constraints
- CORRECTNESS is the only gate — closure capture/escape/mutation semantics MUST stay identical (the open/close aliasing is the risk: a closed ref must keep the value alive after the frame pops; an open ref must see live mutations to the frame slot). When unsure, KEEP the ref open or box eagerly (safe, just slower).
- Do NOT judge/revert on perf — commit on correctness-green.
- Do NOT touch the dispatcher / value repr / Object fields / allocator (done).
- If the full aliasing is too risky, land the SIZE shrink (small slab-allocated ref struct, no cell chain) with eager boxing, COMMIT, report — that alone removes the 2-alloc+shape+chain cost even without live-slot aliasing.
