# Handover — frame-model incremental gates (#4)

> Direction #4 from `DIVERGENCE-CATALOG.md` / the 2026-06-25 next-direction survey. The
> documented multi-week **monolithic frame collapse** (wide 27-field `Frame` → slim 9-field
> core + lazy cold side-struct; `FRAME-STRUCTURAL-ALIGN.md`) is NOT this handover. This is the
> **~4–5% of fib (~1.1B insn) that is faithfully shippable NOW** as small/medium gated slices —
> per-call work that fib (and every plain call) does but qjs gates away. Ship these first; they
> also pre-pave the monolithic rewrite (each isolates one per-call tax).

## Context (fib 3.6× qjs; perf record breakdown)

The call path is ~44% of fib: `Machine.pushFrame` 23%, `execCall` 19%, `teardownInlineEntry` 7%.
The **bulk** (pushFrame's wide `Frame.init` + the two-descriptor `FrameSlab`+`Stack` carve, ~30%)
needs the monolithic collapse. The slices below are the per-call features fib never uses but pays
for every call.

## Hard invariants (non-negotiable — from `FRAME-STRUCTURAL-ALIGN.md` facet 6)

1. **Refcount-only frame liveness.** `traceRoots` never walks the Entry/Frame chain
   (`runtime.zig`), so every borrow/own decision must keep refcounts balanced or **force-GC breaks
   with double-free / leak** (test262 0/49775 won't catch a leak; **force-GC is the load-bearing
   gate for C/D**).
2. **The ownership ledger flips in lockstep.** When a slice switches a value from owned→borrowed
   (var_refs, cur_func), the matching teardown free MUST be removed in the same commit, or vice
   versa. `Frame.deinitInlineCall` (frame.zig:500) frees by the per-slot ownership flags.
3. Each slice is its own commit, gated `test262 0/49775` + `zig build test` 1223 + **force-GC 1223**,
   with a fib `perf stat -e instructions` before/after. **Run `zig build zjs` before every perf**
   (gate builds overwrite `zig-out/bin/zjs` with the force-GC binary — see HANDOVER-perf-round2 hazard).

---

## Slice A — teardown gate for no-eval frames (small, ~437M, ~1.7% of fib)

`teardownInlineEntry` (inline_calls.zig:667-676) runs unconditionally every call:
```
entry.eval_snapshot.deinit(rt);   // EvalVarRefSnapshot.deinit (frame.zig:34): refs.deinit + freeAtomSlice
entry.stack.deinit(rt);
entry.frame.deinitInlineCall(...);
freeEvalResources(rt, entry);     // freeMergedSlices + freeEvalFunctionView
rt.vm_stack.restore(entry.arena_mark);
ctx.popActiveBacktraceFrame(...);
entry.profile_guard.deinit();     // already a no-op when profiling off (vm_call.zig:67)
```
For the common call, `eval_snapshot` is the empty default (setupInlineEntry only fills it when
`need_eval_var_refs`, :403-418) and `merged_*`/`eval_function_view` are empty — yet
`eval_snapshot.deinit` (a `refs.deinit` ValueRootBuffer loop) and `freeEvalResources` still run.

**Change.** Add a bool `simple_frame` to `Entry`, set in `setupInlineEntry` =
`!need_eval_var_refs and entry.eval_function_view == null` (i.e. `eval_names.len==0 && eval_refs.len==0`,
:364). In `teardownInlineEntry`, gate `eval_snapshot.deinit` + `freeEvalResources` behind
`if (!entry.simple_frame)`. (qjs's `done:` epilogue, quickjs.c:20698, only frees what the frame
actually allocated.)

**Invariant.** None of these own borrowed values — they free *eval-introduced* slices that simply
don't exist for a simple frame. Pure dead-work elision. Lowest risk in the set.

**Gate.** Run the eval-heavy test262 dirs (`language/eval-code`, `language/expressions/...`,
`with`) under force-GC mentally — but they take the `!simple_frame` path unchanged.

## Slice B — backtrace push/pop gate for simple frames (small, ~100–200M)

`pushActiveBacktraceFrame` (setupInlineEntry:301) / `popActiveBacktraceFrame` (teardown:674) thread
a parallel `ActiveBacktraceFrame` list every call — qjs spends zero (it reuses the
`prev_frame` chain, built only on throw; CALL-MACHINERY §6).

**Change (conservative).** Keep the push (the resolver/data are installed once at slot-acquire,
`acquireSlot` :214-217), but the per-call `previous` relink + pop is the tax. The minimal faithful
step here is bounded; the FULL fix (derive backtraces by walking the Entry chunk chain, deleting the
parallel list — FRAME-STRUCTURAL-ALIGN facet F) is **medium and couples to the recursive Path-B
boundary** (needs a thread-local current-entry pointer). **Recommend: do Slice A + C + D first;
revisit B only if its isolated payoff (~0.3–0.5%) justifies the backtrace-walk rework.**

**Invariant.** `snapshotBacktraceFrames` (on-throw) must still find every live frame; the
`backtrace_barrier` stop + lazy materialization must survive. Test: deep-stack `.stack` traces +
`Error().stack` across inline calls.

## Slice C — borrow closure captures instead of copy+retain (medium, ~263M, scales with captures)

`initFrameVarRefs` (vm_call.zig:152) carves a per-frame window and `.dup()`s every capture on entry;
`Frame.deinitInlineCall` `.free()`s each on exit — O(captures) refcount traffic/call. qjs:
`var_refs = p->u.func.var_refs` (quickjs.c:17844), a single O(1) pointer borrow, never freed. fib's
self-reference is itself 1 capture, so this is ~50 insn/call for fib and more for higher-order closures.

**Change.** When there is no eval-merge (`entry.eval_function_view == null`, i.e. the common path),
ALIAS `frame.var_refs = target.function_object.functionCapturesSlot().*` directly (the slice already
read at :286) and skip the per-element `.dup()` in `initFrameVarRefs` AND the per-element `.free()` in
teardown. Keep the eval-merge path (`mergeEvalBindings`, :549) owning its merged slice.

**Invariant (load-bearing).** The teardown free of `frame.var_refs` MUST be skipped in lockstep when
aliased (a `var_refs_borrowed` flag on the Frame, checked in `deinitInlineCall`/`releaseOwnedStorage`,
frame.zig). The frame's OWN open `var_refs` (the NULL-filled tail slice it closes — `closeOpenVarRefs`)
is a DIFFERENT array (`open_var_refs`) and stays owned/closed as today. Do not conflate the borrowed
captures with the frame's own open refs. **force-GC is the gate** (a missed skip-free = double-free;
a missed alias = leak).

## Slice D — lazy `this` + non-owning `current_function` (medium, ~263M)

setupInlineEntry eagerly coerces `this` every call (`coerceCallThis`, call_runtime.zig:295-310, via
the plain-undefined fast path + `take_receiver_as_this`, :311-356) and OWNS `current_function` via
`takeSourceSlot` (:344, transfers the ref + frees at deinit). qjs stores `this`/`new_target` NOT in
the frame (coerces lazily at `OP_push_this`, quickjs.c:17933) and `cur_func` is a non-owning cast-store
(:17843). fib reads neither `this` nor recoerces, so this is pure waste for pure-math callees.

**Change.** (1) Make `current_function` a non-owning borrow: drop `takeSourceSlot` (keep the slot in
the caller's still-live operand region; `cleanupSource` must not free the callable slot early) and
remove the unconditional `current_function` free in `Frame.deinitInlineCall` (frame.zig:503). (2) Defer
`this`: stop the eager coercion for the plain-undefined / no-`this`-read case; move the sloppy-undefined→
global / primitive→ToObject coercion to the `op.push_this` handler (zjs_vm.zig:2163). The eager path's
`boxed_this`/`take_receiver_as_this` branches collapse.

**Invariant (load-bearing).** The caller MUST keep the callable slot alive for the call duration (qjs
invariant) — couple to `cleanupSource`. The ownership ledger flips cur_func from always-free to
never-free in lockstep. `op.push_this` must do the exact sloppy coercion the eager path did (verify
sloppy-mode `this===globalThis`, strict `this===undefined`, primitive boxing). **force-GC + the
`this`-coercion test262 dirs** (`language/statements/function`, `built-ins/Function/internals/Call`).

---

## Order & expected total

A (lowest risk) → C → D → (B optional). Combined ~1.1B insn = **fib 26.3B → ~25.2B (3.64× → ~3.49×)**.
Modest on fib alone, but C scales with closure capture count and D with non-`this`-reading callees, and
**every plain call** pays A/C/D — so the broad-loop and Map/Set-per-op (7.6×, which the survey traced to
this same call path) effects are larger than the fib delta suggests.

## NOT in this handover (the real lever, separate project)

The monolithic frame collapse: slim 9-field hot `Frame` + lazy `FrameCold` side-struct, single out-filled
carve descriptor, raw-sp operand window, threaded post-call resume (no `machine.switched` per call). That
removes pushFrame's wide init + the two-descriptor carve (~30% of fib) and is the documented multi-week,
suspend-crossing-aware, step-by-step-gated project in `FRAME-STRUCTURAL-ALIGN.md` / `CALL-MACHINERY-QJS.md`.
Slices A–D above are deliberately the parts that do NOT require it.
