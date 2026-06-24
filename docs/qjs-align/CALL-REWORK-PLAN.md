# Call-Machinery Structural Rework: lean the per-call frame storage toward qjs's sf/alloca

## 0. Problem statement (reliably established)

zjs spends ~1568 instructions per JS->JS call; qjs spends ~104 (~15x). This is **not a single hot point**: three independent incremental attempts (a bump-slab, a Frame shrink 728->312B, and 3 `setupInlineEntry` leans) were ALL perf-neutral. The gap is the *whole machine*: a heap-chunked `Entry` that embeds, **by value**, a full `Bytecode` copy + a 528B `Frame` + a 48B `Stack` object, behind a 5-resource errdefer chain, versus qjs's ~72B `JSStackFrame` C-stack local + ONE alloca + borrowed argv/var_refs + a ~30-insn prologue.

This rework makes **each Entry slot as lean as qjs's `sf`** while KEEPING zjs's inline-Machine dispatcher (no C-recursion — a deliberate zjs design choice). It is **staged**, each stage **independently gated** (test262 0/49775 + 1223 unit + 1223 force-GC + pinned insn/call), and the **default build stays correct at every stage**.

## 1. The two models, field by field (validated against source)

**qjs `JSStackFrame`** (quickjs.c:407-420, ~72B, C-stack local `sf_s`):
`prev_frame, cur_func (JSValue), arg_buf (*), var_buf (*), var_refs (**), cur_pc (*), arg_count (int), js_mode (int), cur_sp (*)`. ONE alloca per call: `[arg_buf | var_buf | stack_buf | var_refs]` (17826-17871). `arg_buf` BORROWED from argv when `argc>=arg_count`. `var_refs` BORROWED from the function object. Epilogue (20699-20710): close var_refs if any, linear `JS_FreeValue(local_buf..sp)`, unlink. Teardown is otherwise free via C-stack unwind.

**zjs `Entry`** (inline_calls.zig:111-131), per inline-call level, in a chunked heap array (16 slots/chunk, 512 chunks):
- `function: *const Bytecode` — pointer (good, = cur_func target)
- **`eval_view: bytecode.Bytecode` — a FULL ~500B/39-field Bytecode copy embedded BY VALUE.** Only populated on the eval path, but its storage is in EVERY one of the 16 pre-allocated slots per chunk. **This is the #1 structural divergence.**
- `frame: Frame` — **528B** (frame.zig:173): 64B essential + 256B inline buffers + 16B ownership flags + 48B extra JSValue fields + 80B cold eval/sync slices.
- `eval_snapshot, stack: Stack (48B), catch_target, arena_mark, profile_guard, backtrace_frame, merged_var_ref_names, merged_var_refs`.

The dispatch loop already keeps `reg_ip/reg_base/reg_sp/reg_var_buf` register-resident (zjs_vm.zig:541-548) — the hot *loop* is aligned (per MEMORY). The gap is the per-call *prologue/epilogue*, i.e. the Entry/Frame/Stack machine.

## 2. Target model + zjs-faithful compromises

**Target (qjs-faithful):**
1. **sf-equivalent = lean Entry.** Each level keeps a slot (zjs's stand-in for the C-stack `sf`), but its body shrinks to qjs's essential ~72B: bytecode pointer, pc, this, current_function, new_target, arg_count, + slab-window views. The by-value `eval_view` is DELETED — eval reaches its merged var-ref view by pointer.
2. **alloca-equivalent = one `VmStackArena` carve** (`FrameSlab.carve`, frame.zig:50): `[args|original_args|locals|stack|var_refs|open_var_refs]` contiguous = qjs's single alloca. The arena mark/restore is the LIFO C-stack-unwind equivalent.
3. **operand stack = register window, no object.** The 48B `Stack` collapses to the slab's `stack` window + the already-register-resident `reg_sp`/`reg_base`. Push/pop = pointer arithmetic (qjs `*sp++`).
4. **argv/var_refs BORROWED** (already: `initArgumentsBorrowedSlots`; `var_refs` eager slice).
5. **ownership unified** — the 11 bool flags collapse once binding values + storage fate are encoded minimally.

**zjs-faithful compromises (deliberate, documented):**
- **The inline-Machine + chunked Entry STAYS.** zjs does not C-recurse per call (keeps one dispatch loop with register-resident hot state). Entry slots are heap-chunked, not alloca'd. This is the irreducible #1 difference.
- **Generators/async cannot be pure stack-sf:** `saveGeneratorExecutionState` (vm_gen_async.zig:64) heap-promotes the frame on suspension. The lean Entry keeps this; the slab is used only for the non-suspending span and detaches on yield.
- **Eval merged var-refs stay entry-owned heap slices** (they outlive setup); moved off the by-value `eval_view` but kept entry-owned and freed on teardown.
- **Tail-call frame-slot reuse** (`tailCallReuse`:586) needs the index-based Entry slot — kept.
- **Per-frame catch_target + unwind** (`unwindForError`:656) needs each level addressable — kept.
- **Backtrace** stays an embedded intrusive node pointing at the heap-stable `Entry.frame` (cheap once per-call rooting is gone).
- **Profiling** becomes compile-time-gated (zero per-call cost when off).

## 3. Honest irreducibility

A residual **~2.5x over qjs (target ~250-350 insn/call vs qjs 104) is IRREDUCIBLE without C-recursion**, which zjs deliberately avoids. qjs gets frame teardown for free via C-stack unwinding and writes 2 pointers for backtrace; zjs must run explicit per-frame teardown (refcount the live operand stack, close var-refs, restore arena mark, pop backtrace) because its frames are **heap-resident to survive suspension** (generators/async). The plan recovers **4.5-6x** (1568 -> ~250-350); the last ~2.5x is the documented cost of being a suspendable, non-C-recursive interpreter and is **not chased**.

## 4. Staged plan (each stage: self-contained, gated, default-correct)

**Gates for every stage:** `test262 0/49775` + `zig build test` (1223 unit) + `zig build test -Dzjs_force_gc=true` (1223 force-GC) + pinned `perf stat -e instructions` insn/call on `/tmp/call-bench.js` (+ generator & eval variants). For stages touching ownership/GC (S2, S3, S4), the **force-GC build + da34bc1 8-regression set** is load-bearing.

### S0 — Pin the measurement (no code change)
Create `/tmp/call-bench.js` (a non-fusable `f(s)=>s+1` called 1e8 times) + generator + eval variants. Record `taskset -c 5 perf stat -e instructions zjs /tmp/call-bench.js` / 1e8 = baseline (~1568); record qjs (~104). Run the full gate to record the green start. **0% perf; establishes the denominator** so perf-neutral stages are *detected*, not guessed.

### S1 — De-bloat Entry: `eval_view` by-value -> pointer
Delete `eval_view: bytecode.Bytecode` (the ~500B by-value copy). On the eval path, allocate a minimal overlay `{ base: *const Bytecode, var_ref_names: []Atom }` (or just the one field eval overrides) and point `entry.function` at it; common path keeps `entry.function = target.view` (already a pointer). `mergeEvalBindings` writes the overlay (entry-owned, freed by `freeMergedSlices`). **Files:** inline_calls.zig (Entry 111-131, setupInlineEntry 254-277, mergeEvalBindings 525-544, freeMergedSlices, teardownInlineEntry). **Verify:** gate + eval variant; `@sizeOf(Entry)` drops ~500B (chunk alloc 16x500B=8KB -> ~0.5KB). **Perf:** 5-15% from smaller acquireSlot init + Entry cache locality; primary value is unblocking S2/S3. Necessary structural refactor.

### S2 — Collapse the per-frame Stack object
Change `Entry.stack: Stack` (48B) -> `stack_window: []JSValue` (the carved slab window). Remove `reserveFrameCapacity` (no-op when slab carved). Teardown: linear free over `[base,sp)` (qjs epilogue) + the arena restore that already runs. Dispatch loop derives `reg_base/reg_sp` from `stack_window`; `syncDown` publishes sp-len back to the window length. Keep ONE thin heap-fallback for carve-miss behind a single bool (not a full Stack object). **Files:** stack.zig (reduce), inline_calls.zig (116, 367-372, 635, 644-648), zjs_vm.zig (84-94, 390-394, 446-458, 596-597). **Verify:** gate + **force-GC** (root-publish discipline: length published before any alloc; assertStackWindowSynced under Debug+GC-stress). **Perf:** -60 to -120 insn/call; first visibly-moving stage. ~1450 -> ~1100-1250.

### S3 — Delete 256B inline buffers; slab-only + single heap-fallback bit
Delete `inline_locals[8]/inline_args[4]/inline_original_args[4]/inline_var_refs[4]/inline_open_var_refs[12]` and their 5 inline-vs-heap branches. All storage from `FrameSlab.carve`; carve-miss falls to ONE heap path gated by a single `storage_on_heap` bool (replacing 5 `*_on_heap` flags). `open_var_refs` reads the slab tail (already carved, frame.zig:80-86). `var_refs` stays EAGER. Frame: 528B -> ~180-220B. **Files:** frame.zig (173-210, init/deinit paths), vm_call.zig (117-260), inline_calls.zig (360-426). **Verify:** gate + force-GC + forced-tiny-arena stress (both slab and heap fates). **Perf:** -40 to -80 insn/call + big cache win on deep chains. ~1100-1250 -> ~1000-1150.

### S4 — Lean prologue: compile-time profiling, simplified backtrace + binding writes
Make `enterCallProfile`/`profile_guard` compile-out to zero when profiling is off (comptime, not per-call RAII). Collapse the 4 binding-value ownership flags to the minimal set deinit reads (current_function .take, new_target .borrow, this owned only when boxed/method-taken). Keep `pushActiveBacktraceFrame`/pop (load-bearing, errdefer-ordered) — confirm it's 2 pointer writes, not a rooting scan. **Files:** vm_call.zig (57-102), inline_calls.zig (260-261, 328-342, 639), frame.zig (206-209, 452-457). **Verify:** gate + force-GC + **da34bc1 8-regression set** (deinit frees MUST match writes byte-identically). **Perf:** -30 to -60. ~1000-1150 -> ~900-1050.

### S5 — Hot-lane prologue consolidation
Restructure `setupInlineEntry` so the common shape (normal fn, argc>=arg_count, no eval, simple params) runs: one carve, `initArgumentsBorrowedSlots` (no copy), borrowed var_refs window, ~6 field writes, one memset locals=undefined, null open_var_refs (carve already does). Hoist ALL cold work (mergeEvalBindings, initOriginalArgsSnapshot, eval snapshot) behind existing conditionals; mark cold helpers `noinline` (keep hot live-register set small, ALIGN-PLAN M2). **Files:** inline_calls.zig (254-428), frame.zig (335-349, 50-96), vm_call.zig. **Verify:** gate + force-GC + da34bc1 set + all three bench variants; disasm prologue vs qjs JS_CallInternal (17826-17871), document residual. **Perf:** -50 to -150. ~900-1050 -> **~250-350 insn/call** (4.5-6x recovery). Residual ~2.5x = documented irreducible.

### S6 — Retire `original_args` snapshot (separate commit, post-S5)
Move unmapped-arguments to lazy construction in the arguments builtin from live `frame.args` (qjs model). Delete `original_args` + `original_args_on_heap` + the carve dimension + `initOriginalArgsSnapshot` (frame.zig:373-391). **Files:** frame.zig, inline_calls.zig (347, 354), arguments builtin. **Verify:** gate (unmapped-arguments + mutation test262 is the sharp edge) + force-GC. **Perf:** -20 to -50 for strict/complex-param only; Frame -16B; mostly cleanliness.

## 5. Must-preserve invariants
Generators/async heap promotion; eval merged var-refs entry-owned; `frame.var_refs` eager (never lazy); tail-call slot reuse (depth-constant); per-frame unwind + iterator-close-before-teardown; operand-stack refcount discipline (dup/move/borrow modes); GC-root publish (syncDown before any alloc); ownership flags match teardown frees exactly; setupInlineEntry errdefer ordering; VmStackArena LIFO mark/restore (per-Entry, not batched); Machine.deinit emergency drain; **test262 0/49775 + 1223 + force-GC green at every stage.**

## 6. Risks + mitigations
S4 flag-collapse double-free/leak -> force-GC + da34bc1 set, collapse one at a time, pure refactor. S2 root-publish break -> force-GC + assertStackWindowSynced, keep publish points. S2 stack-growth fallback -> keep carve-miss heap path, qjs requires fit-to-alloca. S1 overlay dangle -> entry-owned + force-GC. S3 slab/heap fate confusion -> single bit set at carve, tiny-arena stress. Perf-neutral stage -> S0 detects it; S1/S3 framed as enabling refactors. Generator regression -> bench variants every stage, promotion path untouched. Chasing last 2.5x -> STOP at ~250-350, do NOT C-recurse. Tail-call/unwind field drop -> only by-value bloat removed, never the slot/catch_target/backtrace/arena_mark.