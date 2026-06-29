# Call-machinery faithful frontier (2026-06-29)

One session of disassembly + measurement that drove the "can zjs call-heavy code (fib/funcall)
**faithfully** match qjs?" question to ground. It **overturned a chain of stale "floor" claims** and
left a clear, evidence-backed frontier. Method: `taskset -c 8` (X925 big core @3.9 GHz),
`perf stat -e instructions:u`, differential per-call isolation.

## TL;DR

- **dispatch is already a faithful match** (HEAD is tail-call threaded; `next` = 4 insns ≈ qjs
  computed-goto 4-5). NOT a floor.
- **qjs C recursion is NOT free** — `JS_CallInternal` prologue spills 12 callee-saved via `stp×6` +
  alloca every call (~16 insns). zjs spills to Entry/arena; qjs spills to its stack frame. Neither is free.
- **The 642-insn/call gap is function decomposition** — qjs runs the whole call in ONE
  `JS_CallInternal`; zjs splits it across ~15 functions, each paying its own prologue/epilogue +
  cross-boundary spill. **This is removable (collapse to one function), NOT a Zig language floor.**
- **No Zig hard floor was found.** fib faithfully matching qjs is *theoretically reachable*; the only
  faithful path is a deep rewrite collapsing the call path to a qjs-style single recursive function.
- **IC/fusion beating qjs (e.g. array 1.27×) is "changing tracks", not a faithful match** — the user
  rejects it as cheating (qjs has neither). See [[qjs-faithful-align-program]] "反超 qjs 是红旗".

## Measured per-call (funcall differential = (call-insn − inline-insn) / 5M)

| engine | per-call insn | ratio | notes |
|---|---|---|---|
| qjs | **287** | 1.00× | single `JS_CallInternal` |
| C-recursion (Path B) | **707** | 2.46× | but runs the OLD `execCall` slow path — not the ceiling |
| loop-in-place (HEAD) | **894** | 3.11× | the canonical current dispatcher |

fib total insn: qjs 3.14e9 · loop-in-place 8.37e9 (2.66×) · C-recursion **6.04×** (deep recursion
regresses — each call a real C stack frame prologue; loop-in-place's Entry chain amortizes better).
The first-cut (below) moved HEAD loop-in-place fib 2.756→2.661×, funcall 2.418→2.345×.

## ① dispatch is faithfully aligned (disassembly)

HEAD `next` (`src/exec/tailcall_dispatch.zig`) fast path:
```asm
ldrb  w8, [x0]              ; opcode = pc[0]
ldr   x9, [x3, #88]         ; table base ← resident vm pointer (x3), ONE ldr, no adrp+add
ldr   x4, [x9, x8, lsl #3]  ; handler = tbl[opcode]
br    x4
```
qjs computed-goto: `ldrb;mov;ldr;br` (4), several sites + `add x0,#0x630` to re-derive base (5).
**zjs is not worse — cleaner at some sites.** The "107/111 adrp+add remat" in
[[dispatch-table-base-remat-rootcause]] was the dispatchLoop era, now replaced.

## ② qjs C recursion is non-zero-cost (disassembly)

`JS_CallInternal` prologue:
```asm
stp x29,x30,[sp,#-96]!   ; fp/lr
stp x19,x20,[sp,#16]     ┐ 6× stp = save 12 callee-saved registers
... x21..x28 ...         ┘ (+ 6× ldp on return)
sub sp,sp,#0x1d0         ; fixed 464 B frame
sub sp,sp,x1             ; alloca
```
~16 insns/call just for register spill/restore. **Refutes "C calling convention saves caller for
free".** qjs `stp`→its own frame; zjs `str`→Entry/arena. Same idea, neither免费.

## ③ The gap is function decomposition (perf symbol map)

- qjs funcall: **100% `JS_CallInternal`** (one symbol, one prologue, GCC whole-function regalloc).
- zjs funcall: **~15 functions** — op_call 18% · runWithArgsState 14% (32-param giant fn + the main
  dispatch loop, annotate hot = `str [sp,#1544..2072]` ≈2 KB frame) · pushFrame 11% ·
  setupSimpleInlineEntry 9% · op_return 7% · op_get_arg_short 7% · teardown/cleanup.
- Each function boundary = its own `stp/ldp` + cross-boundary spill — the tax qjs's single function
  doesn't pay. **No "C can, Zig can't" primitive was found.** The difference is implementation *shape*,
  collapsible in principle.

## ④ Path B (existing C-recursion dispatcher) — 707 is NOT the ceiling

`src/exec/call_internal.zig` (3040 lines, `dispatchRecursive` + `recurseInlineCall` native-recursion +
TCO trampoline) lives at git **`eebd7e0~1`**, flag `-Dzjs_recursive_dispatch=true`. Deleted 7 days ago
for **"WIP / dual-dispatcher maintenance burden", not performance**. Builds on zig 0.16 (worktree
`/tmp/zjs-pathb`), fib correct (2496120). **But perf shows funcall goes through `execCall` (22%) +
`callValueOrBytecodeClassModeDispatch` (8%) — the OLD generic resolution slow path** (call_internal.zig:2015
does execCall THEN recurseInlineCall). HEAD's op_call already inlines `resolveInlineTarget`
(`tailcall_dispatch.zig:365`, skips execCall). So **707 contains ~30% of resolution overhead HEAD
already fixed — it overstates the true C-recursion ceiling.** The extreme C-recursion (HEAD-inlined
op_call + native recursion) was never actually measured.

## ⑤ First-cut landed (loop-in-place lean, UNCOMMITTED)

`simple_inline_eligible: bool` precomputed into the Bytecode view:
- `src/bytecode/function.zig` — field on `Bytecode` struct + computed in `makeBytecodeView`:
  `func_kind==.normal && !is_class_constructor && !is_derived_class_constructor && !is_arrow_function
  && !is_strict_mode && !runtime_strict_mode && has_simple_parameter_list && !has_eval_call &&
  global_vars.len==0`
- `src/exec/inline_calls.zig:289` `isSimpleInlineFrame` — one byte test short-circuits the ~6
  scattered `FunctionBytecode` bool loads (the annotate `ldrb [fb,#559/561/563]` cluster that
  dominated op_call). Call-site conditions (this/args/captures/eval-locals) stay per-call.

**−35 insn/call, fib 2.756→2.661×, funcall 2.418→2.345×, test262 0/49775 (passed 44601).** This is the
*faithful* direction (zjs splits qjs's one packed `js_mode` byte into scattered bools; this re-packs an
eligibility bit). `=false` always falls back to the general path → zero correctness risk.

> The second cut (`resolveInlineTarget`, op_call's other fb-flag reads) needs a separate
> `fb.inline_admissible` precompute — resolveInlineTarget's admission is *wider* than eligible (allows
> arrow/strict to inline via the general path) and reads fb *before* `ensureCachedBytecodeView`.

## ⑥ DECISIVE verification — Zig single-function recursion has NO floor, crushes qjs

A 30-line standalone Zig interpreter (`/tmp/fib_collapse.zig`): 16 B JSValue (tag:i64), in-function
labeled-switch threaded dispatch (`sw: switch (code[pc]) { … continue :sw code[pc] }`), op_call recursing
into itself = the qjs `JS_CallInternal` shape. Same fib(30)×3, result correct (2496120):

| interpreter | fib per-call | vs qjs |
|---|---|---|
| Zig minimal single-function | **107.5** | **0.28×** |
| Zig + type checks + stack-overflow check + frame chain | **124.5** | **0.32×** |
| qjs (full) | 389.2 | 1.00× |
| zjs loop-in-place (w/ body) | ~1036 | 2.66× |

**Even loaded with qjs's full real per-call overhead** (add/sub/lt tag checks + `js_check_stack_overflow`
depth guard + frame-chain prev/cur_pc/cur_sp), **Zig single-function recursion is still 124.5/call =
0.32× qjs — 3× faster.** So:

- **zjs loop-in-place's 1036/call is 100% function decomposition (15 fns vs 1) + implementation bloat,
  NOT a Zig language / LLVM floor.** Same shape in Zig costs 124.
- **labeled-switch codegen is excellent in a lean small function** (124/call) — the frame-bloat / table-
  remat fears were artifacts of the giant `dispatchLoop`, not labeled-switch itself.
- **The "is there a Zig floor" question is answered: NO.** The extreme single-function-recursion ceiling
  IS measured now — and it's far below qjs.

## Faithful conclusion + next step

fib faithfully matching qjs is **not just reachable — likely to be exceeded.** No Zig floor; single-function
collapse is an ~8× lever. The **only faithful path** is the deep rewrite collapsing the call path to a
qjs-style single recursive function ([[frame-rewrite-one-shot]], multi-week, now backed by the ⑥ evidence).

**Honest bound:** the probe's fib body is simpler than zjs's real path (no 16 B JSValue dup/free, shape
lookup, GC write barrier). zjs's actual collapse won't hit 124 — but the 0.32× headroom is huge, those real
costs qjs pays too (it IS 389), and Zig codegen doesn't lose to qjs (probe proves it). So collapsed zjs lands
at qjs's order or below; matching/beating is very likely. The precise number still needs the real collapse.

**Next:** plan the collapse deep-rewrite blueprint (per [[frame-rewrite-one-shot]]: exhaust ground-truth +
write to terminal state in one shot, no flag-gated intermediate). NOT IC/fusion (changing tracks, user
rejected as cheating).

## Overturned stale claims (this session)

| claimed | reality |
|---|---|
| "fib residual = frame-build alloca-carve" | function decomposition; alloca-carve is a sliver of pushFrame |
| "monolithic ⊥ generator/async suspend" | qjs is the counterexample (monolithic + heap state split + `JS_CALL_FLAG_GENERATOR` re-entry) |
| "Zig+LLVM dispatch floor (labeled-switch remat)" | HEAD is tail-call threaded, 4 insns no remat, aligned to qjs |
| "no variadic alloca floor" | loop-in-place doesn't use alloca (uses arena carve) |
| "qjs C recursion saves caller for free" | `stp×6` saves 12 callee-saved every call |
| "fib unreachable, almost only JIT" | no evidence; gap is removable function decomposition |

See [[verify-before-floor-claims]] — the共同 failure was asserting "floor/unreachable" from
memory/doc transcription instead of objdump/perf.
