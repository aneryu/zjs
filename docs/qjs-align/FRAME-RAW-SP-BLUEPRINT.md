# Raw-`sp` frame-model rewrite — blueprint (2026-06-27)

> **⏫ UPDATE (same day): tail-call dispatch is the UNIFIED fix for the whole dispatch-codegen
> frontier — both the frame AND the jump-table-base rematerialization.** Measured: a monolithic
> threaded `switch` over 20 arms (each with a `[4]i64` aggregate) needs a **640 B union frame** (LLVM
> won't coalesce arm aggregates across the labeled switch); splitting into 20 tail-called handler
> functions gives **112 B each, and since tail calls reuse the frame (`br` not `bl`) the live stack
> depth is ONE handler (112 B), not the union** — a 5.7× cut, the same mechanism that makes qjs's
> per-op frames tiny. AND tail-call keeps the dispatch table base resident as a parameter (0/24
> `adrp` vs 25/25 for the monolithic switch, validated separately). So **"shrink the frame to qjs
> level" and "fix the table-base rematerialization" are ONE rewrite: tail-call threaded dispatch**
> (each opcode a fn, `@call(.always_tail)` threading the hot state + table). The raw-`sp`/lean-state
> work below is the PREREQUISITE (the hot state must be ≤8 values to fit aarch64's 8 arg registers,
> else it spills on every dispatch). Vehicle = tail-call; raw-`sp` = its enabler.


Goal: shrink `dispatchLoop`'s stack frame from **3952 B** to qjs `JS_CallInternal`'s **~464 B**
(the remaining 8.5×). Established by measurement (DISPATCH-TAX-FINDINGS.md) that this is the ONLY
lever — outlining is exhausted (cold helpers already `noinline`; the lone oversight, the 3 async
entries, is fixed for −304 B), and cold-context→frame is worth only 112 B. The 3840 B residual is
**carriers + per-arm temporaries created by the `*Stack` object**, removable only by going raw-`sp`.

## Ground-truth: why zjs's frame is 9× qjs's

**qjs (terminal target).** ONE `alloca(local_buf)` holds, contiguously:
`arg_buf | var_buf | stack_buf | var_refs` (quickjs.c:17846-17864). `sp` is a raw `JSValue*` into
`stack_buf`; `var_buf`/`arg_buf` are raw pointers into the same block. No separate stack object, no
separate growth logic — the alloca is sized once (`b->stack_size` is a compile-time max). Carriers:
`pc, sp, var_buf, arg_buf, var_refs, ctx, b` ≈ 7, all fit in callee-saved → not spilled → 464 B.

**zjs (current).** Three SEPARATE dynamically-managed buffers:
- `frame.locals: []JSValue` — the locals (separate alloc)
- `frame.storage_values: []JSValue` — frame value storage
- `stack.values: []JSValue` — the operand stack, owned by a `Stack` object that ALSO carries
  `memory`, `capacity`, `limit`, `arena_window` and does growth (`reserveCapacityUpTo`) + borrow.

`dispatchLoop` therefore carries `reg_base`/`reg_sp` (into `stack.values`), `reg_var_buf` (into
`frame.locals`), `reg_arg_buf` (into `frame.args`), PLUS the `stack` and `frame` object pointers
(for `syncDown` write-back + cold-arm `stack.push/pop` + helper calls) — ~10 carriers that saturate
the 10 callee-saved registers, so temporaries + the dispatch table base spill → 3952 B frame +
107/111 `adrp` table-base rematerializations.

## Terminal state (qjs-faithful)

One contiguous per-frame buffer `[ args | locals | operand-stack ]` sized to a compile-time max
(`function.stack_size`, already known), owned by the frame. `sp` is a raw `[*]JSValue` into the
operand-stack region; `var_buf`/`arg_buf` are raw pointers into the same buffer. The `Stack` object
is DELETED. Operand-stack overflow is a compile-time-bounded check (qjs trusts `stack_size`), not a
runtime grow. `dispatchLoop` carries `pc(sp-as-reg_ip), sp, var_buf, arg_buf, var_refs, ctx,
function, frame` — qjs's ~8, fitting callee-saved → frame collapses toward 464 B AND the table base
goes resident (fixes the dispatch-tax frontier #1 as a side effect).

## Blast radius (measured)

`stack.values/push/pop/peek/capacity` across **15+ files, hundreds of refs**: vm_value.zig 157,
iterator_ops 102, vm_property_field 47, vm_call 44, object_ops 42, vm_property_ref 41,
vm_gen_async 32, vm_arith 31, call_runtime 28, vm_literal 27, … Every operand-stack op in the VM.

## Hard parts (must be designed before any edit — these are where a naive rewrite breaks)

1. **Growth → fixed buffer.** Today `stack.push` can grow. qjs never grows (alloca sized to
   `stack_size`). Must verify every bytecode's `stack_size` is a correct compile-time max (the
   compiler computes it; confirm no path exceeds it) — else operand-stack overflow corrupts memory.
2. **Generator/async suspend.** `saveGeneratorExecutionState` (vm_gen_async.zig:64) transfers
   buffer OWNERSHIP into the generator object (`stack.values`, `frame.locals`, etc.) on yield and
   restores on resume. With a single contiguous buffer this becomes one buffer transfer, but the
   `cur_sp`/`cur_pc` save+restore must be re-expressed. test262 generator/async is the oracle.
3. **The inline-call Machine.** zjs is non-recursive: `Machine` pushes `Entry{frame, stack}` per JS
   call instead of recursing. Each Entry's buffer must become the contiguous model; `pushFrame`/
   `teardownInlineEntry`/`tailCallReuse` move args between caller operand-stack and callee buffer.
4. **Arena-window borrow** (`stack.arena_window`) — the borrowed-stack fast path for non-generator
   frames; must map onto the contiguous model or be retired.

## Staged execution (each stage a COMPLETE terminal sub-state, test262 0/49775 — no flag gates)

Per the project's "one-shot to terminal, no intermediate flag-gated phases" rule, stage by
SUBSYSTEM not by feature-flag — each stage fully replaces one mechanism end-to-end:

- **S0 (ground-truth lock).** Confirm `stack_size` is an exhaustive compile-time max for every
  opcode path (audit the bytecode compiler's stack accounting); @panic-probe any overflow path.
- **S1.** Allocate the contiguous `[args|locals|stack]` buffer in the frame; make `var_buf`/
  `arg_buf`/`sp` raw pointers into it. Keep a thin `Stack` shim over the same memory so the 15
  files compile unchanged. Verify test262 (no behavior change — pure representation).
- **S2.** Replace `stack.push/pop/peek` call-sites file-by-file with raw-`sp` ops (the shim makes
  each file independently convertible). vm_value.zig first (157 refs), then by descending count.
- **S3.** Delete the `Stack` object + growth path; operand overflow = bounded check. Re-express
  generator suspend as single-buffer transfer. Drop `reg_base`/`stack`/`reg_code_end`/`catch_target`
  carriers from `dispatchLoop`.
- **S4.** Verify: frame ≈ qjs, table base resident (`adrp` count → ~4/111), test262 0/49775 +
  force-GC, fib/eloop/arr perf vs qjs.

## Status

NOT STARTED — this document is the required ground-truth + design. Execution is a multi-week
focused project (hundreds of refs + suspend/growth semantics across the core VM). The async-entry
`noinline` fix (−304 B, test262-clean) is landed in the working tree as the down payment.
