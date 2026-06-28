# Tail-call dispatch one-shot rewrite — terminal-state blueprint

> Authority for the single-commit tail-call-dispatch rewrite that reduces the dispatchLoop
> stack frame from 3504B (additive non-coalescing per-arm spills) to ~max-handler (~250-400B,
> approaching/below qjs's 464B). Ground-truthed 2026-06-27 against the LIVE tree + the deleted
> `tailcall_dispatch.zig` (eebd7e0~1, 2004 lines, the resurrection base).
>
> DOCTRINE: written ALL AT ONCE to terminal state — NO flag-gated stages, NO `op_cold` big-switch
> fallback (that keeps the big frame). Correctness gate = test262 0/49775 + 1223 unit + 1223
> force-GC. Per [[frame-rewrite-one-shot]].
>
> NOT the same as `FRAME-MODEL-ONESHOT-BLUEPRINT.md` — that is the Frame-STRUCT model + backtrace
> (modest, residual 1.3-1.5x). THIS is the dispatch-STRUCTURE rewrite that fixes the frame SIZE.

---

## 0. The proof this works (bisection, 2026-06-27 — not speculation)

The 3504B frame is the **SUM of per-arm JSValue spills that do NOT coalesce** (each arm's spill
occupies its own slot). Proven by comptime-delete bisection (reliable; IR liveness archaeology
was not):

- delete 1 `array_el` fast path → **−80B**
- delete all 33 `if(comptime thread_dispatch)` fast paths → **−880B** (≈ sum of individuals)
- Phase 1 (shared InlineCallRequest slot) → **−320B**

All additive → removing an arm drops the frame by its spill → spills are NOT shared. Root (IR):
threaded `continue :sw` + refcount cleanup stretch each temp's lifetime from its arm to a common
function-tail return/cleanup region (`%.sroa.013` start@7661, ends@7766 AND @14933 — 36% span),
so hundreds of temps overlap → LLVM cannot coalesce.

**Why tail-call fixes it (the additive property IS the proof):** if each arm is a SEPARATE
function, its spill lives in THAT function's frame and dies at the handler's return (no
back-edge to stretch it). The stack at runtime = dispatcher frame + ONE live handler (tail-call
reuses the slot). So frame = **max single handler**, not **sum**. Measured handler-local
contribution: array_el 80B, local_fast 0B → max handler ≈ 80-150B.

**Verified preconditions (2026-06-27, no blocker):**
- lean: hot state fills 10 callee-saved (x19-x28); the prior design bundles all but pc/sp/var_buf
  into a `*Vm` pointer → 4 args (x0-x3), no arg spill. `reg_base` already eliminated (redundant
  with `stack.values.ptr`, −0B but −1 hot register, perf-neutral).
- max handler ≈ 80-150B; dispatcher ≈ 100-200B → terminal frame ≈ 250-400B.

---

## 1. Terminal design (from `tailcall_dispatch.zig` eebd7e0~1, completed)

### 1.1 Handler ABI
```
const Outcome = enum(u32) { fallthrough, returned, threw, tail, suspended, reenter };
const Handler = *const fn (pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome;
```
3 hottest as direct args (pc/sp/var_buf), everything else in `*Vm`. `callconv(.c)` so LLVM can't
clobber the tail-call ABI. **INVARIANT: a handler makes ZERO non-tail calls on its own frame** —
the op's real work is an OUTLINED helper called as the *last* action before the tail dispatch, OR
the helper runs and the handler tail-dispatches its result; either way the handler frame is just
its locals (small).

### 1.2 The `Vm` bundle (the lean — everything not pc/sp/var_buf)
From the prior design + current state: `function/frame/stack/machine, output, global, code_base,
code_len, code_end, stack_base, arg_buf, arg_count, catch_target, interrupt_poller,
allow_inline_calls, no_lexical_locals, return_value, pending_error, tail_request` + the
depth-conditional `entry_*` eval/generator state (moved into Vm, read on demand). `publish(pc,sp)`
= the syncDown analog (sp→stack.values.len, pc→frame.pc). `reloadSp()` re-derives sp after a cold
helper grows the stack.

### 1.3 Dispatch primitive
```
fn next(pc, sp, var_buf, vm) Outcome {
    if (@intFromPtr(pc) >= @intFromPtr(vm.code_end)) return @call(.always_tail, op_falloff, .{pc,sp,var_buf,vm});
    return @call(.always_tail, dispatch_table[pc[0]], .{pc, sp, var_buf, vm});
}
```
256-entry `dispatch_table` (comptime-built from the op→handler map).

---

## 2. The keystone correction over the prior dispatcher

The prior `tailcall_dispatch.zig` was a HYBRID: a few hot handlers + one `op_cold` →
`coldDispatch` big-switch fallback, flag-gated off, "only nested calls, default top-level never
used it." **The big `coldDispatch` switch keeps the 3504B frame** → the hybrid does NOT reduce the
frame. **TERMINAL RULE: there is NO big `op_cold`. EVERY opcode is its own handler.**

- **Hot handlers** (~14 frame-zero ops: get_loc/put_loc family, get_arg, push_*, dup/swap, the
  int32 arith/compare fast paths): inline fast path, zero-non-tail-call, then `next`. (These
  already contribute ~0-80B; local_fast measured 0B.)
- **Cold handlers** (~136 ops: the `switch (try helper())` arms): `vm.publish(pc,sp)` → call the
  op's EXISTING outlined helper (vm_property_field.field, arith_vm.compareVm, iter_vm.forOfStartVm,
  class_vm.defineClass, …) → translate its result union to an Outcome / advance pc → `next`. The
  helper is already a separate function (outlined), so the cold handler's own frame is just the
  call setup + result (small).

Each cold handler is MECHANICAL and near-identical (the §6 template). The ~136 cold handlers are
volume, not difficulty.

---

## 3. Call / return / tail-call / generator / eval re-entry (Outcome-driven driver)

The hot tail-call chain cannot itself make the non-tail `JS_CallInternal`-analog calls. Control
returns to a thin DRIVER (the `runWithArgsState` analog) via `Outcome`:

- **`.tail` (op.call .inline_call / tail_call / tail_call_method / eval-tail)**: handler sets
  `vm.tail_request`, returns `.tail`. Driver does `machine.pushCall` / `tailCallReuse`, rebuilds
  pc/sp/var_buf from the new top Entry (the `reloadInlineTopFrame` analog), re-enters `next`.
- **`.returned` (return / return_undef / return_async / falloff)**: handler sets
  `vm.return_value`. Driver: depth==0 → return; else `popReturn` + rebuild + re-enter `next`.
- **`.threw`**: handler sets `vm.pending_error`. Driver: `machine.unwindForError` (KEEP, §
  FRAME-MODEL §2.3) then either re-enter at the catch target or propagate.
- **`.suspended` (generator yield / await)**: handler runs the EXISTING
  `saveGeneratorExecutionState` path, returns `.suspended`; driver returns to the generator
  resume boundary. **All three arena-window admission gates + the suspend 6-field transfer stay
  byte-identical (FRAME-MODEL §4) — a generator never carries an arena window.**
- **`.reenter` (cold callee: native/generator/class-ctor/cross-realm)**: driver runs the cold
  call path (full prologue), re-enters.

The driver holds the re-entrant loop; the `Vm` struct is its single stack local (the only big-ish
frame is the driver's `Vm` + the FrameSlab carve — both already exist and are small/bounded).

---

## 4. What is KEPT verbatim (do not touch — FRAME-MODEL blueprint §2-6 still authoritative)

The ownership ledger (§3), suspend/arena bifurcation (§4, three gates), exception unwind (§2.3),
interrupt-poll sites (§2.4), the Frame+FrameCold struct (§1.2, NO field reshuffle), `reloadInline
TopFrame`'s reload set (minus reg_base), the outlined op helpers themselves (vm_*.zig — unchanged;
the handlers just CALL them). The rewrite changes the DISPATCH SHELL, not the op semantics.

---

## 5. Migration checklist (the volume)

1. **New `Vm` struct** (exec/tailcall_dispatch.zig, resurrected) holding §1.2 bundle.
2. **~14 hot handlers** — port from the prior dispatcher's hot handlers + current fast paths.
3. **~136 cold handlers** — one per `switch (try helper())` arm, via the §6 template.
4. **`dispatch_table`** — comptime op→handler map (256 entries, invalid→op_invalid).
5. **Driver** — rewrite `runWithArgsState`/`dispatchLoop` to the Outcome loop (§3); delete the
   `switch (opc) {...150 arms...}` body of the current `dispatchLoop`.
6. **reg_base** — already eliminated. **Stack object** — stays in `Vm` (helpers need `*Stack`);
   sp/var_buf are the raw register args; `publish`/`reloadSp` bridge.
7. **Backtrace** — the FRAME-MODEL §5 Entry-walk applies unchanged (the driver IS the L0 boundary).

## 6. Cold-handler template (mechanical, ~136×)
```
fn op_<name>(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (<helper>(vm.ctx, ...) catch |e| return vm.fail(e)) {
        .done => {},
        .continue_loop => {},   // helper re-entered catch; just re-dispatch
        // .inline_call/.tail_inline => { vm.tail_request = req; return .tail; }
    }
    const npc = vm.code_base + vm.frame.pc;      // helper advanced frame.pc
    return @call(.always_tail, next, .{ npc, vm.reloadSp(), var_buf, vm });
}
```

---

## 7. Risk + ordering

- **Highest risk**: the `.tail`/`.returned` driver re-entry must reproduce `reloadInlineTopFrame`
  exactly (pc/sp/var_buf/var_refs rebuild) or inline recursion corrupts. De-risk: port the EXACT
  reload arithmetic; full test262 (call regressions = mass failures, not 6 regexp).
- **callconv(.c) + always_tail**: if ANY handler emits a non-tail call on its frame, LLVM spills
  and the frame grows — the per-handler "zero non-tail call" invariant must hold (helpers are the
  tail-or-pre-dispatch action). Verify each handler's asm has no `bl` before the final `b`.
- **Ordering** (one commit, compiles at end): Vm struct → dispatch primitive + table → hot
  handlers → cold handlers (template) → driver (delete old switch) → backtrace re-point → gate.
- **Gate**: `zig build zjs` FIRST (stale-binary hazard), then test262 0/49775 + 1223 + force-GC +
  fib/property perf (must not regress; the 2-stack-arg overhead is gone since ≤4 args).

## 8. Ceiling (honest)
Frame: 3504B → ~250-400B (max handler + driver), approaching/below qjs 464B. Perf: the per-op tail
dispatch is `b` (no per-op税), but each cold handler reads state from `*Vm` (loads) where the
monolith had it in registers — net likely neutral-to-positive on the hot path (frame-zero hot
handlers keep pc/sp/var_buf in registers), needs the targeted perf gate to confirm. This is the
dispatch-structure lever the FRAME-MODEL rewrite explicitly did NOT cover.
