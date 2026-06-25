# Frame-model one-shot rewrite — terminal-state blueprint (campaign item D)

> Authority for the single-commit frame-model rewrite. Ground-truthed against the LIVE tree
> on 2026-06-25 (frame.zig 861 lines, inline_calls.zig 758, zjs_vm.zig 2563, context.zig 955,
> vm_gen_async.zig 575, stack.zig 137). Supersedes `FRAME-STRUCTURAL-ALIGN.md` (whose anchors
> have drifted and whose facets E/F reference a deleted mechanism — see §8).
>
> DOCTRINE: faithful = mirror qjs structure with a `quickjs.c:N` anchor; perf is the RESULT,
> not the target; correctness (test262 0/49775 + 1223 unit + 1223 force-GC) is the only hard
> gate. The rewrite is written ALL AT ONCE to the terminal state — no flag-gated stages.
>
> qjs reference = `/home/aneryu/quickjs/quickjs.c`, 16-byte JSValue on this aarch64 host
> (NaN-boxing is off — `JS_NAN_BOXING` is inside `#ifndef JS_PTR64`).

---

## 0. The single most important ground-truth correction

The "make recursion the default" facet (FRAME-STRUCTURAL-ALIGN E/F) targets a **deleted
mechanism**. There is NO `Path B`, NO `build.zig:11 zjs_recursive_call` (build.zig:11 is the
JSValue-layout comment; the IC flag is `zjs_enable_ic`), NO `zjs_recursive_call` /
`callInlineRecursive` / `dispatchRecursive` symbol anywhere in the tree, and NO
`stack.pushOwnedAssumeCapacity(ret); continue` at `zjs_vm.zig:1855`.

The REAL return/resume is **loop-in-place**, and it is ALREADY the qjs-faithful threaded
resume — it just runs through a `machine.switched`-gated cold prologue on the FIRST inline
push from L0, and threads (skips the prologue) on every inline→inline call AND return once
`inline_invariants_set` is true. Concretely (all verified live):

- `machine.switched` (decl `inline_calls.zig:160`) set at `inline_calls.zig:259` (pushFrame)
  and `:706` (popTeardown); consumed/reset at `zjs_vm.zig:792-793`; also reset in
  `reloadInlineTopFrame` at `zjs_vm.zig:135`.
- `reloadInlineTopFrame` (`zjs_vm.zig:105-140`) reloads function/stack/frame/catch_target +
  6 registers (reg_ip, reg_code_end, reg_base, reg_sp, reg_var_buf, reg_arg_buf) from
  `machine.topEntry()`, advances reg_ip AND `frame.pc += 1` (`:138`), and returns the next
  opcode WITHOUT the cold prologue.
- The three return arms (`op.@"return"` 1389-1401, `op.return_undef` 1402-1411,
  `op.return_async` 1412-1421) each: `syncDown` → if depth==0 return → `popReturn` → if
  `depth>0 and inline_invariants_set` call `reloadInlineTopFrame` + `continue :sw opc`.
- The call arms (`op.call*` 1934-1958, `op.call_method` 2002-2028) each: `syncDown` →
  `call_vm.call` → on `.inline_call`: `machine.pushCall` → if `inline_invariants_set` poll +
  `reloadInlineTopFrame` + `continue :sw opc`, else bare `continue` (first L0→L1 push, the
  prologue establishes the invariants).
- qjs anchor: `OP_call` (quickjs.c:18182) does `sf->cur_pc=pc` (18190) →
  `ret_val=JS_CallInternal(...)` (18191) → `sp-=call_argc+1; *sp++=ret_val` (18199-18200) →
  `BREAK` (18202). `OP_return` (18266) does `ret_val=*--sp; goto done`; `done:` (20700)
  closes var_refs, frees locals/args, `rt->current_stack_frame = sf->prev_frame` (20710),
  `return ret_val`. zjs's `reloadInlineTopFrame + continue :sw` IS the structural analog of
  qjs's `BREAK` after `JS_CallInternal` returns.

**Therefore the terminal "recursion-default" is NOT a from-scratch Zig-recursive rewrite.**
It is the EXISTING loop-in-place, with three already-landed pillars (threaded return, threaded
call resume, inline_invariants_set gating) kept, and the remaining structural tax removed:
the Frame hot/cold split, the parallel-backtrace deletion, the descriptor double-copy
collapse, and confirming the interrupt poll has moved to entry + backward-branch (it has —
`zjs_vm.zig:858`). The dispatch/return/resume control flow itself does NOT change shape.

---

## 1. Terminal Frame model

### 1.1 Live struct (frame.zig:225-269, the BEFORE)

15 fields + a `FrameCold` (already present, frame.zig:255-269):
`function, pc, this_value, current_function, new_target, actual_arg_count, locals, args,
var_refs, var_refs_borrowed, open_var_refs, storage_values, storage_on_heap, cold,
this_value_owned`.

### 1.2 Terminal hot core — KEEP the existing 15-field shape; DO NOT collapse to 9

**Decision (overrides FRAME-STRUCTURAL-ALIGN facet A).** The "slim to 9 fields, move
this_value/new_target/storage_*/this_value_owned to FrameCold" pillar is REJECTED for this
one-shot. Three independent reasons, all ground-truthed:

1. **The banner on FRAME-STRUCTURAL-ALIGN.md itself disproves it** (lines 1-6, verified):
   "Frame slim (B3) has low benefit (teardown cost is the NECESSARY value frees, not field
   proliferation) + high complexity (most cold fields cross generator suspend). Do NOT
   re-attempt." The authoritative current doc is `HANDOVER-frame-incremental.md`.
2. **Generator suspend collides with moving this_value/new_target to cold.** `vm_gen_async.zig`
   suspend (`:84-94`) and resume (`:158-162`) read/reset `frame.storage_values`,
   `frame.storage_on_heap`, `frame.locals`, `frame.args`, `frame.var_refs` directly — and
   `frame.cold` must already survive suspension (it holds sync/eval/ctor state). Moving more
   hot fields into cold widens the suspend-crossing surface for zero structural-faithfulness
   gain (qjs's `this_obj`/`new_target` are C-local PARAMETERS, not sf fields — but zjs needs
   them stored because its dispatch loop is re-entrant, not a C-recursion with live locals).
3. **The var_refs borrow safety is COUPLED to current_function being OWNED** (see §3). Slimming
   that out would break the borrow invariant.

So `FrameCold` STAYS exactly as it is (frame.zig:255-269); the hot core STAYS 15 fields. The
ONLY structural change to the Frame struct itself is: nothing — it is already correct. The
one-shot's frame-model work is the **return/resume confirmation (§2), the parallel-backtrace
deletion (§5), and the descriptor collapse (§7)** — NOT a field reshuffle.

### 1.3 Field → fate table

| Field | qjs mirror (quickjs.c) | Fate | Why |
|---|---|---|---|
| `function: *const Bytecode` | `sf->cur_func->b` (17843) | KEEP hot | const after setup; readers want `.code`/`.var_count` |
| `pc: usize` | `sf->cur_pc` (413) | KEEP hot, mirrored to reg_ip | hottest field (208 sites); syncDown publishes reg_ip→pc |
| `this_value: JSValue` | C-local `this_obj` (17933) | KEEP hot | 12 readers across 11 exec files; coercion already eager via coerceCallThis |
| `this_value_owned: bool` | (implicit) | KEEP hot | gates `this_value.free` at frame.zig:612/600/585 |
| `current_function: JSValue` | `sf->cur_func` (409, non-owning) | KEEP hot, KEEP OWNED | 55 readers; owned-ness is load-bearing for var_refs borrow (§3) |
| `new_target: JSValue` | `sf->new_target` param | KEEP hot, borrowed (never freed) | 8 readers; correct as-is |
| `actual_arg_count: usize` | `sf->arg_count` (416) | KEEP hot | argc; formal count read from `function.arg_count` |
| `locals: []JSValue` | `sf->var_buf` (411) | KEEP hot | 2nd hottest (127 sites) |
| `args: []JSValue` | `sf->arg_buf` (410) | KEEP hot | 42 sites; ALWAYS freed at frame.zig:618 (ownership via cleanup_source, §3) |
| `var_refs: []JSValue` | `sf->var_refs` (412) | KEEP hot; borrowed-or-owned | alias when `var_refs_borrowed` |
| `var_refs_borrowed: bool` | (implicit borrow) | KEEP hot | sole `=true` writer inline_calls.zig:482; gate frame.zig:624/634 |
| `open_var_refs: []?*VarRef` | NULL-fill+close of `var_refs` cells | KEEP hot | not in qjs sf; faithful to zjs VarRef open-cell design |
| `storage_values: []JSValue` | alloca backing (17846) | KEEP hot | entire slab; crosses generator suspend |
| `storage_on_heap: bool` | (implicit) | KEEP hot | gates the heap-fallback free at frame.zig:626 |
| `cold: ?*FrameCold` | (none — derived on demand in qjs) | KEEP, unchanged | null on plain call; lazy via ensureCold |

`FrameCold` (frame.zig:255-269) — UNCHANGED. All 13 cold fields stay; all accessed via
`ensureCold` on write and accessor methods (`evalVarRefs()`, `constructorThisValue()`, etc.)
returning empty defaults on read when `cold==null`.

---

## 2. Return/resume — already recursion-default loop-in-place; what's confirmed, what moves

### 2.1 What SURVIVES a call (carried live across the threaded resume)

The 6 dispatch registers are reloaded by `reloadInlineTopFrame` (`zjs_vm.zig:129-134`) from
the new top Entry and survive in the threaded `continue :sw` path without the cold prologue:
`reg_ip, reg_code_end, reg_base, reg_sp, reg_var_buf, reg_arg_buf`. On the CALLER side after
the callee returns, the caller's registers are re-derived by `reloadInlineTopFrame` from the
caller's Entry (the return arms call it). This is the zjs analog of qjs keeping `sp`/`pc` as
live C-locals across `JS_CallInternal` — zjs re-derives them from the Entry instead of holding
them in CPU registers across a C call, which is the irreducible structural difference.

### 2.2 The complete return/resume site set (the write checklist for this subsystem)

Return arms (all KEEP — already threaded): `zjs_vm.zig:1389, 1402, 1412`.
Fallthrough-return (implicit return when a callee runs off the end with no `return` opcode):
`zjs_vm.zig:851-857` — `if (frame.pc >= function.code.len) { if (depth==0) break;
finishFunctionReturn(peek orelse undefined); popReturn; continue; }`. **This MUST stay
consistent with the explicit-return arms** (it does today; verified).
Call arms with `.inline_call` threaded resume: `zjs_vm.zig:1940` (op.call*), `:2010`
(op.call_method).
Tail-call frame reuse (`tailCallReuse`, no popReturn): three dispatch sites `zjs_vm.zig:1973`
(op.tail_call), `:1986` (op.eval non-%eval% tail), `:2042` (op.tail_call_method); def
`inline_calls.zig:668`. Tail-call `.return_value` (depth==0 return else popReturn):
`zjs_vm.zig:1964/1965`, `:2034/2035`.
op.call_constructor (`zjs_vm.zig:2520`): NON-INLINE, always recurses via `call_vm.constructor`
(faithful to qjs `OP_call_constructor` 18203 → `JS_CallConstructorInternal`). KEEP.
popReturn `inline_calls.zig:728-732`; popTeardown `:702-707`; pushCall `:639-656`; pushFrame
`:253-260`.

### 2.3 Exception model (the verifier-corrected unwind path)

`dispatchLoop` (`zjs_vm.zig:718`) is a SEPARATE function from the hot loop body. Errors
propagate via Zig error-union OUT of `dispatchLoop` to the outer re-entrant loop in
`runWithArgsState` (`zjs_vm.zig:666-675`): `dispatchLoop(&loop_state) catch |err| { if
(machine.depth>0 and machine.unwindForError(...)) continue; return err; }` (call at `:672`).
The per-arm `catch` blocks at the call arms (`zjs_vm.zig:1942`, `:2012`) handle ONLY
pushCall-SETUP failure (via `handleCatchableRuntimeError` → `tryCatchInFrame`, single-frame);
a callee-BODY exception escapes `dispatchLoop` to `:672`. `machine.unwindForError`
(`inline_calls.zig:740-757`) walks `machine.depth`, closing iterators + popTeardown +
`tryCatchInFrame` per level. **KEEP UNCHANGED** — this is correct and faithful (qjs's
`exception:` label walks `prev_frame`, quickjs.c:20660).

### 2.4 Interrupt poll — already moved (CONFIRM, do not re-move)

qjs polls once at function entry (`js_poll_interrupts`, quickjs.c:17787), never per-return.
Live zjs poll sites (5, all correct): prologue entry `zjs_vm.zig:858`; backward-branch arms
`zjs_vm.zig:1618` and `:1661` (gated on `interrupt_poller.active`, after syncDown); call-entry
threaded resume `zjs_vm.zig:1951` and `:2021`. The return arms do NOT poll. **No change** —
the poll is already at entry + backward-branch + call-entry, faithful.

### 2.5 What stays cold (never threaded)

`resolveInlineTarget` (`inline_calls.zig:75`) admits ONLY: `func_kind == .normal`
(`:79`), not a class/derived-class constructor (`:80`), same-realm (`:82`). Everything else —
generators, async, class constructors, cross-realm, C/native functions, eval-with-bindings —
stays on the cold path (machine.pushCall sets `switched=true`, full prologue re-entry). The
first L0→L1 inline push is also cold (establishes `inline_invariants_set`). This admission gate
is the keystone that keeps generators off the borrowed-slab path (§4).

---

## 3. Ownership ledger — terminal borrowed-vs-owned table (KEEP AS-IS; the lockstep proof)

### 3.1 The table

| Value | Terminal state | Setup site | Free site(s) | Gate |
|---|---|---|---|---|
| `current_function` | **OWNED** (take via `takeSourceSlot`, free unconditionally) | inline_calls.zig:347 | **THREE**: frame.zig:613 (deinitInlineCall), :601 (deinit), :586 (releaseCallBindings) | none — always freed |
| `this_value` | OWNED iff boxed/taken, else borrowed | inline_calls.zig:350/354/357 | frame.zig:612, :600, :585 | `this_value_owned` |
| `new_target` | BORROWED (never freed) | inline_calls.zig:348 | none (frame.zig:588/603 `_ = new_target`) | none |
| `var_refs` (borrowed) | BORROWED alias of `functionCapturesSlot().*` | inline_calls.zig:481-482 | skipped | `var_refs_borrowed` at frame.zig:624/634 |
| `var_refs` (owned) | OWNED per-element dup | vm_call.zig initFrameVarRefs | frame.zig:624 releaseValueSliceNoReset | `!var_refs_borrowed` |
| `args` (moved) | OWNED (transferred from source) | inline_calls.zig:458 (cleanup_source=.non_args) | frame.zig:618 (ALWAYS) | via cleanup_source, NOT a frame flag |
| `original_args` (cold) | OWNED values | frame.zig:552 | freeCold (values) before storage free | `cold != null` |

### 3.2 The cur_func decision: KEEP OWNED — and WHY the "borrow cur_func" facet is rejected

FRAME-STRUCTURAL-ALIGN says "make cur_func a NON-OWNING cast-store." The banner already
disproves it as a non-diff (`takeSourceSlot` is a MOVE not a dup — same refcount as qjs).
Ground-truth adds a STRONGER reason: **the var_refs borrow safety depends on cur_func staying
owned/alive.** The live comment at `inline_calls.zig:480-481` states the alias is safe because
"The function object stays alive via `frame.current_function`, so the cells outlive the frame."
If cur_func became a non-owning borrow, the borrowed var_refs alias could dangle if the
caller's operand slot were reclaimed first. So cur_func OWNED is load-bearing, not incidental.
**Do NOT touch cur_func ownership in this rewrite.** The three `current_function.free` sites
(frame.zig:586/601/613) stay; `takeSourceSlot` at inline_calls.zig:347 stays.

### 3.3 The lockstep invariant (one-shot hazard)

Any flag-vs-free desync = double-free (force-GC panic) or leak (force-GC "not reclaimed").
Since this rewrite KEEPS the ledger as-is, the only risk is accidental breakage. The pairs
that must remain in lockstep:
- `var_refs_borrowed = true` (inline_calls.zig:482, sole writer) ⇔ skip free at frame.zig:624
  AND frame.zig:634 (`if (var_refs_borrowed) &.{} else var_refs`). Two skip sites, one writer.
- `this_value_owned` set at inline_calls.zig:351/355/358 + default `true` (frame.zig:253) ⇔
  free at frame.zig:612/600/585.
- `current_function` taken at inline_calls.zig:347 ⇔ freed at ALL THREE of frame.zig:586/601/613.
  The L0 path (frame.zig:601 `deinit`, frame.zig:586 `releaseCallBindings`) and the inline path
  (frame.zig:613 `deinitInlineCall`) are TWINS — any cur_func change touches all three.

### 3.4 The var_refs realloc escape the borrow gate depends on never firing

`ensureVarRefsCapacity` (frame.zig:848) reallocs `frame.var_refs` to a NEW heap slice + sets
`storage_on_heap`. If it fired on a borrowed frame, it would silently leak (new owned copy,
`var_refs_borrowed` still true → teardown skips free). The borrow gate
(`inline_calls.zig:387-391`) is built so it can't: `borrow_var_refs` requires `simple_frame ∧
!has_eval_call ∧ global_vars.len==0 ∧ frame_var_refs.len>0 ∧ allVarRefCells`. The
`ensureVarRefsCapacity` callers — slot_ops.zig:272/287/361/514, object_ops.zig:430/447,
call_runtime.zig:7735-7739 (write+grow), vm_property_ref.zig:146, plus the closure-capture
readers object_ops.zig:431/437-438/448/593 — are borrow-safe ONLY because: (a) the grow path
requires var-ref names beyond captures (excluded by the gate's binding shape), and (b)
`ensureVarRefCell` (slot_ops.zig short-circuits on already-cell slots). **The one-shot must not
weaken the borrow gate; these callers stay as-is.**

---

## 4. Suspend + raw-sp bifurcation — the hot/cold gate (already faithful; preserve all 3 gates)

### 4.1 The bifurcation is ALREADY present and faithful — do NOT invent a new gate

qjs bifurcates the same way: a normal call uses `alloca` (quickjs.c:17846); a generator/async
resume reuses the persisted heap frame and restores `sp = sf->cur_sp` (quickjs.c:17790-17803,
`JS_CALL_FLAG_GENERATOR`). zjs's `arena_window` Stack is the alloca-backed window; the heap
Stack is the cold/generator buffer.

### 4.2 The hot-vs-cold predicate (three gate sites, each with its own upstream gate)

A frame uses a borrowed arena-window operand stack (HOT) iff it passed an admission gate that
excludes generators/async/class-ctors. THREE `initArenaWindow` sites, each gated:

1. **Inline call**: `inline_calls.zig:423` `Stack.initArenaWindow(&rt.memory, rt.stack_size,
   slab.stack)`. Upstream gate: `resolveInlineTarget` `inline_calls.zig:79` `if (fb.func_kind
   != .normal) return null` — generators/async NEVER reach setupInlineEntry.
2. **L0 entry**: `zjs_vm.zig:625`. Upstream gate: `zjs_vm.zig:577`
   `use_inline_frame_storage = entry_generator_state == null and !is_generator and !is_async`;
   when false, `stack_count` is passed as 0 → `slab.stack.len == 0` (`zjs_vm.zig:624`) → the
   entry_stack stays a heap Stack, not arena-window.
3. **C-reentry / recursive host call**: `call_runtime.zig:5152`. Upstream gate:
   `call_runtime.zig:5146` `arena_eligible = fb.func_kind == .normal and generator_state ==
   null`.

### 4.3 The suspend safety interlock (preserve)

`saveGeneratorExecutionState` (`vm_gen_async.zig:64`) asserts `!stack.arena_window` at `:74`
(suspend) and `:131` (resume). This is PROVABLY true given the three gates: a generator/async
frame can never carry an arena-window stack. The suspend transfers SIX fields to the generator
object (`vm_gen_async.zig:84-94`): `storage_values`, `storage_on_heap`(set false), `locals`,
`args`, `var_refs`, plus the stack `{values,capacity}`. Resume reverses (`:158-162`).
`frame.cold` is NOT transferred — it stays on the Frame across suspension (holds sync/eval/ctor
state). **One-shot rule: any change to how entry_stack/frame_storage are constructed must move
all three gates AND the suspend/resume transfer in lockstep, or the assert fails / a borrowed
window dangles into the generator.**

### 4.4 Raw-sp is already live; syncDown already collapses to the pc save

The dispatch loop already runs raw `reg_base`/`reg_sp` (`zjs_vm.zig:845-850`) with no per-op
bounds checks. `syncDown` (`zjs_vm.zig:84-94`, 153 call sites) publishes `reg_ip→frame.pc` and
`reg_base..reg_sp → stack.values`. The cold handlers (236 `stack: *Stack` signature sites
across ~23 exec files — vm_value ~48, iterator_ops ~25, object_ops ~15, vm_gen_async ~15,
vm_call ~13, etc.) all run AFTER a syncDown, so they never assume live registers. **Migration
rule for ALL of them: none.** They mutate `stack.values` in place; the loop keeps `reg_sp`
authoritative and re-derives it on cold re-entry. The full raw-sp signature collapse (passing
`[*]JSValue` instead of `*Stack`) is the expensive long-tail and is OUT OF SCOPE — it is not
required for the frame-model rewrite and carries high regression risk for ~5% gain.

---

## 5. Backtrace + exception — delete the parallel list, walk the Entry chain

This is the ONE genuinely structural deletion in the rewrite. qjs has NO parallel backtrace
structure: `build_backtrace` (quickjs.c:7571) walks the SAME `rt->current_stack_frame ->
prev_frame` chain qjs uses for actual call frames, stopping at `JS_MODE_BACKTRACE_BARRIER`
(7572). zjs currently maintains a REDUNDANT singly-linked `ActiveBacktraceFrame` list in
parallel with the Machine Entry chain.

### 5.1 Sites to DELETE

- `context.zig:427` — `current_backtrace_frame: ?*ActiveBacktraceFrame` field
- `context.zig:796-799` — `pushActiveBacktraceFrame`
- `context.zig:801-805` — `popActiveBacktraceFrame`
- `inline_calls.zig:304` — push in setupInlineEntry; `:305` errdefer pop
- `inline_calls.zig:722` — pop in teardownInlineEntry
- `zjs_vm.zig:555-560` — L0 `active_backtrace_frame` local + push + defer pop
- `inline_calls.zig:119` (`Entry.backtrace_frame` field) + `:216-219` (init in acquireSlot) —
  KEEP the resolver/data SEED only if the rewrite chooses to reuse `resolveActiveBacktraceFrame`
  per-Entry; otherwise delete.

### 5.2 Sites to REWRITE (both consumers)

- `context.zig:807-833` `snapshotBacktraceFrames` — walk `machine.depth` via
  `machine.entryAt(i)` (deepest→0) then the L0 frame, instead of the `current_backtrace_frame`
  chain. Read `cur_func`/`pc`/`js_mode` per frame; stop at `function.backtrace_barrier`.
- `context.zig:857-869` `dupActiveBacktraceFrame` — currently calls
  `frame.resolver(frame.data)` on an `ActiveBacktraceFrame`. After deletion this resolver
  input is gone; rewrite to resolve from an `*Entry`/`*Frame` directly. (The persistent-array
  path `dupBacktraceFrame` at `context.zig:844-855` stays.)
- `vm_exception_ops.zig:337-356` `resolveActiveBacktraceFrame` — the per-frame resolver
  (reads `function, pc, name, filename, line/col, current_function, backtrace_barrier` from a
  `*Frame`). KEEP the body; re-point its caller to the Entry walk.

### 5.3 The ONE new piece: thread-local current-entry pointer

The Machine Entry chain covers inline frames; the L0 recursive-entry boundary
(`runWithArgsState`, `zjs_vm.zig:508-676`) is the qjs `rt->current_stack_frame` analog. To let
the walk chain stack-local L0 entries (when L0 re-enters the VM, e.g. a native callback calling
back into bytecode), store a current-entry pointer. Lowest-coupling option: a `JSContext` field
`current_entry: ?*inline_calls.Entry` (forward-decl Entry), set/restored at the L0 boundary
and at pushCall/popReturn. Init null at `Machine.init`; `snapshotBacktraceFrames` walks
`machine.depth/entryAt` then the L0 frame (no synthetic wrapper).

### 5.4 External readers (must keep working)

Two direct callers of `ctx.snapshotBacktraceFrames`: `array_ops.zig:326` (CallSite/Error.stack)
and `string_ops.zig:655`. Both must produce the same backtrace after the rewrite.

### 5.5 syncDown-before-unwind (preserve)

Every exception path syncs the registers to `frame.pc`/`stack.values` BEFORE unwinding so the
backtrace pc + catch-marker search read live state. The call-arm catch sites
(`zjs_vm.zig:1942`, `:2012`) follow `syncDown` (`:1935`, `:2003`). `tryCatchInFrame`
(`call_runtime.zig:230`) calls `closeFrameDestructuringIteratorsForAbruptCompletion` →
`popCatchMarker` → `pushError` → `frame.pc=target`, in that order. KEEP.

---

## 6. Complete affected-site index (de-duplicated write checklist)

Transform rules: **KEEP** = no change, listed for exhaustiveness (a one-shot must touch nothing
it doesn't understand); **DELETE** = remove; **REWRITE** = change body; **VERIFY** = confirm
post-rewrite behavior unchanged. All paths under `/home/aneryu/zjs/src/`.

### 6.1 DELETE (parallel backtrace, §5.1)

| File:line | Site | Rule |
|---|---|---|
| core/context.zig:427 | `current_backtrace_frame` field | DELETE |
| core/context.zig:796-799 | `pushActiveBacktraceFrame` | DELETE |
| core/context.zig:801-805 | `popActiveBacktraceFrame` | DELETE |
| exec/inline_calls.zig:304-305 | push + errdefer pop in setupInlineEntry | DELETE |
| exec/inline_calls.zig:722 | pop in teardownInlineEntry | DELETE |
| exec/zjs_vm.zig:555-560 | L0 active_backtrace_frame + push + defer pop | DELETE |
| exec/inline_calls.zig:119, 216-219 | Entry.backtrace_frame field + seed | DELETE (or keep seed if reused) |

### 6.2 REWRITE (backtrace walk, §5.2-5.3)

| File:line | Site | Rule |
|---|---|---|
| core/context.zig:807-833 | snapshotBacktraceFrames | REWRITE to walk machine.depth/entryAt + L0 |
| core/context.zig:857-869 | dupActiveBacktraceFrame | REWRITE to resolve from *Entry/*Frame |
| core/context.zig (new) | `current_entry: ?*Entry` field | ADD |
| exec/vm_exception_ops.zig:337-356 | resolveActiveBacktraceFrame | KEEP body; re-point caller |
| exec/zjs_vm.zig:508-676 | runWithArgsState L0 boundary | ADD current_entry set/restore |
| exec/inline_calls.zig (pushCall/popReturn) | machine top change | ADD current_entry maintenance |

### 6.3 KEEP/VERIFY — return/resume (§2)

| File:line | Site | Rule |
|---|---|---|
| exec/zjs_vm.zig:105-140 | reloadInlineTopFrame | KEEP |
| exec/zjs_vm.zig:791-867 | dispatch prologue (switched + 6-reg reload + fallthrough + poll) | KEEP/VERIFY |
| exec/zjs_vm.zig:851-857 | fallthrough-return (implicit) | VERIFY consistent with return arms |
| exec/zjs_vm.zig:1389,1402,1412 | three return arms | KEEP |
| exec/zjs_vm.zig:1940,2010 | call-arm `.inline_call` threaded resume | KEEP |
| exec/zjs_vm.zig:1964/1965,2034/2035 | tail-call `.return_value` | KEEP |
| exec/zjs_vm.zig:1973,1986,2042 | tailCallReuse dispatch sites | KEEP |
| exec/zjs_vm.zig:2520 | op.call_constructor (non-inline) | KEEP |
| exec/zjs_vm.zig:666-675 | outer unwind loop (unwindForError at :672) | KEEP |
| exec/zjs_vm.zig:858,1618,1661,1951,2021 | 5 interrupt poll sites | KEEP/VERIFY |
| exec/inline_calls.zig:160,259,706 | machine.switched decl+set | KEEP |
| exec/inline_calls.zig:253-260,639-656,702-707,713-724,728-732,740-757 | push/pushCall/popTeardown/teardown/popReturn/unwindForError | KEEP (minus the two backtrace lines) |

### 6.4 KEEP/VERIFY — ownership ledger (§3)

| File:line | Site | Rule |
|---|---|---|
| exec/inline_calls.zig:347 | current_function = takeSourceSlot | KEEP OWNED |
| exec/frame.zig:586,601,613 | three current_function.free | KEEP (lockstep) |
| exec/inline_calls.zig:348 | new_target borrow | KEEP |
| exec/frame.zig:588,603 | new_target never freed | KEEP |
| exec/inline_calls.zig:350/354/357 | this_value set + owned flag | KEEP |
| exec/frame.zig:585,600,612 | this_value free (gated) | KEEP |
| exec/inline_calls.zig:387-391 | borrow_var_refs gate | KEEP (do not weaken) |
| exec/inline_calls.zig:481-482 | var_refs alias + var_refs_borrowed=true | KEEP |
| exec/frame.zig:624,634 | two var_refs skip-free sites | KEEP (lockstep) |
| exec/frame.zig:618 | args ALWAYS freed | KEEP (cleanup_source=.non_args ownership) |
| exec/frame.zig:848 + callers (slot_ops 272/287/361/514, object_ops 430/447, call_runtime 7735, vm_property_ref 146) | ensureVarRefsCapacity realloc escape | KEEP; borrow gate must keep it from firing on borrowed frames |
| exec/frame.zig:615,630 | closeOpenVarRefs BEFORE storage free | KEEP ordering |

### 6.5 KEEP/VERIFY — suspend + bifurcation (§4)

| File:line | Site | Rule |
|---|---|---|
| exec/inline_calls.zig:79 | resolveInlineTarget func_kind gate | KEEP (keystone) |
| exec/inline_calls.zig:423 | initArenaWindow (inline) | KEEP |
| exec/zjs_vm.zig:577,624,625 | use_inline_frame_storage gate + L0 initArenaWindow | KEEP |
| exec/call_runtime.zig:5146,5152 | arena_eligible gate + C-reentry initArenaWindow | KEEP |
| exec/vm_gen_async.zig:74,131 | !arena_window asserts | KEEP |
| exec/vm_gen_async.zig:84-94,158-162 | suspend/resume 6-field transfer | KEEP |
| exec/call_runtime.zig:5074-5765 | generator-resume driver + qjsAsyncFunctionStart | VERIFY entry construction unchanged |
| exec/stack.zig:6-14,20-28,30-43 | Stack struct + initArenaWindow + deinit arena-skip | KEEP |

### 6.6 KEEP/VERIFY — cold-write census (the complete ensureCold set, §1.2)

All cold-field writes go through `ensureCold` (frame.zig:273). Complete set (the verifier's
missed sites folded in): frame.zig:385, :401, :552; slot_ops.zig:158, :161, :164, :201;
object_ops.zig:2661, :2673; vm_property_globals.zig:863; call_runtime.zig:4647 (the
eval_var_refs_republished writer). **Rule: KEEP — all already correct.** Since the Frame
hot/cold split is NOT being changed (§1.2), no cold-write migration is needed; this census
exists so the one-shot does not accidentally break the lazy-alloc discipline.

### 6.7 KEEP — Frame struct + carve + L0 twins

| File:line | Site | Rule |
|---|---|---|
| exec/frame.zig:225-269 | Frame + FrameCold struct | KEEP (no field reshuffle, §1.2) |
| exec/frame.zig:51-98,100-148 | FrameSlab.carve + allocHeap single carve | KEEP (faithful to qjs alloca) |
| exec/frame.zig:611-627 | deinitInlineCall (inline teardown) | KEEP |
| exec/frame.zig:590-609 | deinit (L0 teardown twin) | KEEP |
| exec/frame.zig:574-589 | releaseCallBindings (L0 twin) | KEEP |
| exec/frame.zig:629-655 | releaseOwnedStorage | KEEP |
| exec/zjs_vm.zig:550-628 | L0 frame_storage setup | KEEP |
| exec/zjs_vm.zig:554 | `defer frame_storage.deinit` | KEEP |
| core/runtime.zig:1172 | traceRoots (refcount-only liveness; never walks Entry chain) | VERIFY still true after backtrace deletion |

### 6.8 Descriptor collapse (the one micro-structural change, §7)

| File:line | Site | Rule |
|---|---|---|
| exec/frame.zig:51-98 | FrameSlab.carve returns by value (88B) | REWRITE to out-pointer fill |
| exec/inline_calls.zig:389-422 region | FrameStorageWindows re-bundle | COLLAPSE into single out-filled view |

Note: the verifier flagged this region is "ALREADY via out-pointer (FrameStorageWindows
descriptor)" — confirm before rewriting; if the double-copy is already gone, this is a no-op
VERIFY, not a REWRITE.

---

## 7. One-shot ordering within the single commit

Since there are no gated stages, edit in this order so the tree compiles at the end (Zig
compiles the whole module graph; intermediate states need not compile, but ordering minimizes
churn-conflicts and keeps each edit's invariant local):

1. **context.zig** — add `current_entry: ?*Entry` field; rewrite `snapshotBacktraceFrames` +
   `dupActiveBacktraceFrame` to walk the Machine/Entry chain + L0; delete
   `current_backtrace_frame` + push/popActiveBacktraceFrame. (Backtrace is self-contained;
   doing it first means the Entry-side deletions in step 2 have a landing target.)
2. **inline_calls.zig** — delete the two backtrace lines (`:304-305`, `:722`); maintain
   `current_entry` in pushCall/popReturn; (optionally) drop the Entry.backtrace_frame seed.
3. **zjs_vm.zig** — delete the L0 `active_backtrace_frame` (`:555-560`); set/restore
   `current_entry` at the L0 boundary. Everything else in zjs_vm.zig (return/resume/poll) is
   KEEP/VERIFY.
4. **vm_exception_ops.zig** — re-point `resolveActiveBacktraceFrame`'s caller to the Entry walk
   (body unchanged).
5. **frame.zig / call_runtime.zig / vm_gen_async.zig / stack.zig** — VERIFY ONLY (no edits if
   §1.2 holds and the descriptor is already out-pointer). Run the gate.

Invariants to hold THROUGHOUT (any break = test262/force-GC fail):
- Refcount-only frame liveness: `traceRoots` (runtime.zig:1172) must NOT gain a frame/Entry
  walk; the backtrace deletion must not make GC depend on the Entry chain.
- closeOpenVarRefs BEFORE storage free (frame.zig:615 before :617/:618/:624/:626; :630 first in
  releaseOwnedStorage).
- Ownership lockstep (§3.3): the three cur_func frees, the two this_value gates, the two
  var_refs skip sites stay paired.
- Suspend !arena_window asserts (vm_gen_async.zig:74/131) and the three admission gates stay
  coupled.
- catch-marker discipline (popCatchMarker before pushError, call_runtime.zig:268-269) and
  abrupt-completion iterator close before popTeardown (inline_calls.zig:181/745) stay ordered.

---

## 8. Stale anchors to fix in FRAME-STRUCTURAL-ALIGN.md

| Wrong reference (in FRAME-STRUCTURAL-ALIGN.md) | Reality |
|---|---|
| facet E "make Path B (build.zig:11 zjs_recursive_call) the default" | NO Path B; build.zig:11 = JSValue-layout comment; the flag is `zjs_enable_ic`. The return/resume IS already loop-in-place + threaded. Replace with: "the threaded resume (machine.switched + reloadInlineTopFrame + inline_invariants_set) is already the recursion-default; no flag flip." |
| facet E `stack.pushOwnedAssumeCapacity(ret); continue; (zjs_vm.zig:1855)` | That line/idiom does not exist at 1855. The real return-value push is `popReturn` (inline_calls.zig:731 `pushOwnedAssumeCapacity`). The threaded resume is `reloadInlineTopFrame + continue :sw opc` at zjs_vm.zig:1397/1407/1417 (returns), 1952/2022 (calls). |
| facet E/F `callInlineRecursive` / `callInlineRecursive returns` | Symbol does not exist (deleted). The return arms ARE the resume. |
| facet E poll "from the prologue (zjs_vm.zig:911)" | Poll is at zjs_vm.zig:858 (prologue entry), already moved; backward-branch polls at 1618/1661 (doc said 1595/1638). |
| facet F "inline_calls.zig:302-303,675; context.zig:797-806" | Live: push/errdefer inline_calls.zig:304-305; teardown pop :722; context push/pop :796-805. |
| facet A "9-field hot core replacing 27-field frame.zig:225-251" | Frame is 15 fields at frame.zig:225-253 (FrameCold 255-269), not 27. The 9-field slim is REJECTED (§1.2); the banner already disproves it. |
| facet A "move this_value/new_target/storage_* to FrameCold" | REJECTED — collides with generator suspend (vm_gen_async.zig:84-94) and the var_refs-borrow coupling (§3.2). |
| "borrow cur_func / drop takeSourceSlot at inline_calls.zig:345, free at frame.zig:503" | takeSourceSlot is at :347; the THREE frees are frame.zig:586/601/613, not :503. KEEP OWNED (non-diff per banner + load-bearing for var_refs borrow). |
| INVARIANTS "traceRoots ... runtime.zig:1166" | traceRoots is runtime.zig:1172. |
| INVARIANTS "closeOpenVarRefs ... frame.zig:573 before releaseValueSlice" | closeOpenVarRefs def is frame.zig:679; the ordered calls are frame.zig:615 (deinitInlineCall) and :630 (releaseOwnedStorage). |
| facet C "frame.zig:76 stack = slab_values[cursor..]" / "zjs_vm.zig:850-851,901-903" | Carve is frame.zig:51-98; the 6-reg reload is zjs_vm.zig:845-850. |
| "qjs cur_func quickjs.c:17869,17805" | cur_func cast-store is quickjs.c:17843; prev_frame link 17869-17870. |
| "op.push_this handler zjs_vm.zig:2163" | op.push_this is zjs_vm.zig:2246 → pushThisVm (vm_value.zig:155). |
| JSStackFrame "107B" | ~72B (9×8B fields; frame.zig:251 comment says 72B, correct). |

Add a banner pointing to THIS doc as the authority for the one-shot.

---

## 9. Honest risk + ceiling

### 9.1 Irreducible residual (~1.3-1.5x qjs, NOT 1.0x)

Even with the rewrite landed and the existing threaded resume intact, zjs stays above qjs's
~271 insn/call because: (a) Zig has no variadic alloca, so the VmStackArena
carve+Mark{chunk,used}+explicit restore is a few insn/call qjs gets free from C-stack unwind
(quickjs.c:20710) — structurally permanent. (b) zjs re-derives the 6 dispatch registers from
the Entry on each threaded resume (`reloadInlineTopFrame`) where qjs holds `sp`/`pc` as live
C-locals across `JS_CallInternal` — the re-derivation is the price of a re-entrant dispatch
loop vs a C recursion. (c) Zig codegen vs hand-tuned C + computed-goto: `continue :sw` lowers
to a labeled switch, not `goto *table[*pc++]`; slice {ptr,len} fatness adds a constant factor.
(d) The growable-Stack bifurcation means the inline path carries a {ptr,len} window descriptor
qjs's bare `sp` register does not. NET: ~1.3-1.5x is the realistic floor; closing the last
0.3x is Zig-codegen work (custom dispatch lowering, fully raw-sp everywhere) with diminishing
returns and rising regression risk. **fib's 3.00x is dominated by the per-call cold re-entry
that the EXISTING threaded resume already removes for deep recursion — the remaining lever from
THIS rewrite is modest** (descriptor collapse + parallel-backtrace deletion), so do not expect
fib to drop below ~1.5x from the frame-model rewrite alone.

### 9.2 Top 3 things most likely to break the one-shot

1. **Backtrace walk regression** (the only real structural change). Deleting the parallel list
   and rewriting `snapshotBacktraceFrames` to walk the Entry chain risks: missing the L0 frame
   (incomplete backtrace), walking past a `backtrace_barrier` (wrong/over-long trace), or
   dangling the `current_entry` pointer across re-entrant L0 calls (use-after-free). test262
   has many Error.stack / CallSite tests via array_ops.zig:326 + string_ops.zig:655.
   *De-risk:* keep `resolveActiveBacktraceFrame`'s body unchanged; walk depth→0 then L0; null
   `current_entry` at Machine.init; verify the two external callers byte-for-byte.
2. **Ownership lockstep desync from an incidental edit.** Since the ledger is KEEP, the risk is
   an accidental touch — e.g. "simplifying" one of the three cur_func frees, or the two
   var_refs skip sites. *De-risk:* the 1223 force-GC run is the canary; any double-free panics
   immediately, any leak reports "not reclaimed."
3. **Suspend gate coupling.** If the descriptor collapse (§6.8) changes how the L0 entry_stack
   / frame_storage are built, it can silently flip a generator onto an arena-window stack →
   `vm_gen_async.zig:74` assert fires on the next yield. *De-risk:* keep all three gates
   (inline_calls.zig:79, zjs_vm.zig:577, call_runtime.zig:5146) untouched; if §6.8 is already a
   no-op (descriptor already out-pointer), skip it entirely.

### 9.3 Post-hoc global gate (the only correctness authority)

After the single commit: `zig build zjs` FIRST (avoid the stale-binary hazard — a gate build,
especially force-GC, overwrites zig-out/bin/zjs), then `test262 0/49775` + `1223 unit` + `1223
force-GC`. Perf is measured separately with targeted benchmarks + `perf stat instructions`
(fib in a function-isolating wrapper), never a microbench-suite geomean. Green gate + no perf
regression on the targeted set = the rewrite is faithful; any single-metric "win" that drops a
test or force-GC is reverted whole.
