# Handover — qjs-faithful call/dispatch alignment (2026-06-24)

Branch `qjs-faithful-call-recursion`. 5 commits, each gated green (test262 0/49775
+ `zig build test` 1223 + force-GC 1223; perf via targeted benchmarks).

## What shipped (5 commits, default path)

| commit | change | effect |
|---|---|---|
| `13f031a` | thread `get_arg0..3` (+`reg_arg_buf` register) + inline the decomposed call setup/teardown helpers (initFrameLocals/initFrameVarRefs/resolveInlineTarget/freeSourceSlot/releaseValueSliceNoReset/deinitInlineCall/popTeardown/fastHostOutputCall/isCurrentSuperConstructor) + lazy-heap `Machine.chunks` (kill 4 KiB by-value memcpy) | fib 1800→1428 insn/call |
| `022736d` | thread `add_loc` (clone of inc_loc) + `dup`/`swap` | accumulator loops; fib→1398 |
| `039b582` | thread `get_array_el` dense read (`fastDenseArrayElementValue`) | dense_array 1.99→1.58× |
| `26c399e` | thread `put_array_el` in-bounds dense store (`setFastArrayElementDup`) | a[i]=v register-resident |
| `c44858d` | thread `get_length` for plain arrays (`arrayLength()` direct) | a.length register-resident |

**The pattern** (proven repeatable): a dispatch arm running `syncDown + noinline-helper +
Stack-object push/pop` where qjs inlines the op register-resident on raw `*sp`. Fix =
add an `if (comptime thread_dispatch) <label>: { ...register-resident...; continue :sw opc; }`
fast lane, breaking to the existing slow arm on any non-fast / edge case. Templates:
`get_loc` (~zjs_vm.zig:1067), `get_arg` (~1113), `lt` (~1472), `inc_loc` (~2142).

## Verified-away FALSE structural diffs (do NOT re-attempt these)

Two "big structural wins" from the design (`FRAME-STRUCTURAL-ALIGN.md`) were **disproven by
reading the actual source** — both would have been wasted effort:

1. **"Borrow cur_func" (stage 2): NOT a real diff.** `current_function = takeSourceSlot(callable)`
   is a MOVE (`v=slot.*; slot.*=undefined; return v`), not a dup — zero refcount change. zjs
   frees the callable once at teardown; qjs frees it once in the caller after return
   (`for(i=-1..) JS_FreeValue(call_argv[i])`, quickjs.c:18197). **Same refcount cost**, just a
   different free location. No round-trip to remove.
2. **Frame slim (B3): low benefit + high complexity.** The teardown cost (~12% of fib) is the
   NECESSARY value frees (`current_function`, `args`) that qjs also does — not field
   proliferation (the empty-field guards are cheap branches). AND most cold fields
   (`storage_*`, `original_args`, `global_lexical_sync_*`) CROSS generator/async suspend
   (vm_gen_async.zig:84-167), so a `FrameCold` side-struct cannot be freed at teardown for a
   suspended generator — the migration is much more than "move + lazy-free". `new_target` is
   26 refs / 15 files. Not worth it.

**Lesson (cost us 2 bugs this session): when threading an opcode, read the FULL push/helper
chain's refcount + error semantics, not just the top function.** Bugs caught:
- threaded `dup` first omitted the retain — `pushAssumeCapacity` internally does
  `if (v.requiresRefCount()) v.dup()`; missing it under-refs → premature free (caught by
  force-GC + the Proxy descriptor test).
- `reg_var_ref_buf` (audited as a win) was DROPPED: `frame.var_refs` reallocs mid-frame on
  closure capture (unlike `frame.args`), so caching its ptr → stale use-after-free (Proxy crash).
- `put_array_el`: only the non-erroring `setFastArrayElementDup` in-bounds store is threaded;
  the append/grow path can OOM-error and the threaded lane can't sync the operand stack for a
  fallible call — that stays on the slow arm.

## Current state (targeted measurements vs `/home/aneryu/quickjs/qjs`, perf stat instructions)

fib 3.64× · array-read 3.53× · array-write 2.22× · array-length 2.20×.
(Per project owner: **do NOT use the perf-self-check / microbench-suite geomean as a qjs
comparison** — it's ~tied and hides real gaps. Use targeted benchmarks: `/tmp/fib.js`,
`/tmp/arr.js`, `/tmp/arrwrite.js`, `/tmp/arrlen.js`.)

## Remaining frontiers — both DEEP, treat as focused fresh projects (not marathon-tail)

The quick-win line (pure threading, no refcount risk) is **exhausted**. The call-machinery gap
is verified near-floor: ~9% arena-carve (Zig has no `alloca` — faithfully required), ~12%
necessary frees, the rest diffuse + marginal (<3% each). The two real remaining gaps:

1. **Full frame-model rewrite** — alloca-equivalent single contiguous frame + raw `sp` (eliminate
   the per-call `Stack` object, B5) + lean ~9-field `sf` + the generator-suspend handling. This
   is the only thing that meaningfully closes the call gap, but it is multi-week and must handle
   suspend-crossing + the borrowed-args/var_refs lifetime. High risk.
2. **lever ② — global var_ref lowering** (`GLOBAL-VARREF-PLAN.md`). qjs's OP_get_var/put_var is a
   register-resident var_ref deref; zjs does a global-object IC lookup. fib hits get_var 2×/call;
   the measured **global-WRITE gap is ~14.5×** (much bigger than the call gap for global-heavy
   code). v2 patch proven ~1.85×, blocked on **33 scope-correctness regressions** (TDZ / eval /
   with / named-fn-expr / generator-try-finally — multi-root-cause, da34bc1 history). Threading
   the IC-hit alone does NOT help (the IC lookup IS the cost — tried, no gain). Needs the
   parser/scope lowering, staged per-root-cause, every stage test262 0/49775.

**Deferred small items** (audit `wlobhulpc`): `get_array_el2/el3` (different stack shapes),
`drop` (catch-offset handling).

## Pointers
- qjs source: `/home/aneryu/quickjs/quickjs.c` (quickjs-ng 2026-06-04). Binary: `/home/aneryu/quickjs/qjs`.
- Ironclad qjs call dissection: `docs/qjs-align/CALL-MACHINERY-QJS.md`.
- Structural design (note: B3/borrow-cur_func DISPROVEN above): `docs/qjs-align/FRAME-STRUCTURAL-ALIGN.md`.
- Global var_ref plan: `docs/qjs-align/GLOBAL-VARREF-PLAN.md`.
- Gates: `zig build test262-gate` (0/49775), `zig build test`, `zig build test -Dzjs_force_gc=true`.
