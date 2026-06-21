# MASTER PLAN: align zjs dispatchRecursive's hot path to qjs JS_CallInternal

## Why
zjs is ~2.0x qjs INSTRUCTIONS and ~1.8-3.5x wall-time on compute benches (crypto, pure loop). Root cause (proven by perf + disasm): the recursive dispatcher (`src/exec/call_internal.zig` `dispatchRecursive`, flag `-Dzjs_recursive_dispatch=true`) RELOADS hot interpreter state from memory every opcode (measured: 163 L1-loads/iter vs qjs 71 on a pure-int loop), because the giant function is register-starved and LLVM spills the hot pointers (bytecode base `code`, `code_end`, `frame.locals.ptr`, the operand-stack length-in-memory).

qjs JS_CallInternal (DIRECT_DISPATCH=1) keeps everything in registers:
- `pc` is an incrementing POINTER (`*pc++`), kept in ONE register — no base+index, no `code` reload.
- NO per-opcode bounds check (uses computed-goto over a 256-entry table; well-formed bytecode + terminating opcode).
- `sp` is a register-resident `JSValue *` (`*sp++`, `*--sp`); the operand-stack LENGTH is NOT in memory; sp is published to `sf->cur_sp` ONLY at call/GC boundaries.
- `var_buf` / `arg_buf` are register-resident `JSValue *` pointers set once at frame entry (`var_buf[idx]`), never reloaded from the frame struct.
- Hot opcode bodies are INLINE; every slow path is a `no_inline` function (e.g. `js_binary_arith_slow`, `js_add_slow`) so the `bl` is only on the cold path and the live-value set in the hot loop stays small.
- This qjs build has NO inline cache (verified) — so IC is NOT in scope.

## The alignment goal (faithful to qjs)
Make `dispatchRecursive`'s hot loop hold its state in registers exactly like JS_CallInternal, so the per-opcode memory reloads disappear (target: L1-loads/iter on the pure-int loop drop from 163 toward qjs's 71). This is THE experiment: if Zig/LLVM can keep the state register-resident in this recursive function (like the C compiler does for qjs), zjs closes most of the gap; if it still spills, that residual IS the answer to "why qjs can, zjs can't".

## Milestones (each: build 3 flags 0-errors + smoke + commit; the human runs the authoritative test262 + Octane)
- **M1 — register-resident hot state** (this brief, BRIEF-M1.md): pc as `*ip++` pointer, code_end register, sp as bare register pointer (`*sp++`, length only at boundaries), var_buf/arg_buf register pointers. The big structural alignment.
- **M2 — noinline slow paths + inline-body audit**: ensure every hot opcode body is inline (int arith already is) and every slow/delegating path is a genuine `noinline` function (so the hot loop's live set stays small). Re-check the operand-stack push/pop expansion.
- **MEASURE + RESIDUAL** (human): full 15-Octane vs qjs (wall-time best-of-5, correct binaries) + per-opcode L1-loads/instructions/IPC; then objdump the residual to identify what still differs from qjs (candidate: NaN-box per-value decode tax, Zig codegen density) — answering "why qjs can, zjs can't".

## HARD constraints (do NOT violate)
- CORRECTNESS is the only hard gate. The GC-root publish discipline (the c0be6fce pure-publish model: enterStackBoundary/leaveStackBoundary in call_internal.zig) MUST stay complete — before ANY allocation/GC/sub-call, the live operand-stack length + base + var_buf must be published to the backing structs so the GC roots correctly; reload after. The dual-population Debug assert (assertStackWindowSynced) must hold under `-Doptimize=Debug -Dzjs_recursive_dispatch=true` + GC-stress (tiny gc threshold).
- Do NOT change observable semantics. All 3 dispatch flags must keep building (flag-off dispatchLoop, -Dzjs_tailcall_dispatch, -Dzjs_recursive_dispatch).
- Do NOT revert a change for being only a small perf win — stages compound; only correctness regressions block.
- Reference implementations to reuse: the `*pc++` pointer conversion is ALREADY implemented + proven correct (−17% loads, full suite passes) in `/tmp/wt-q-ptr/third_party/zjs/src/exec/call_internal.zig` — diff it against c0be6fce and adapt. The code_end-as-register pattern is in `/tmp/wt-q-tc/third_party/zjs/src/exec/tailcall_dispatch.zig`.

## Measurement (deterministic, for codex self-checks)
- pure-int loop = /tmp/lv-int.js. `taskset -c 5 perf stat -e instructions,L1-dcache-loads zig-out/bin/zjs /tmp/lv-int.js` ; per-iter = counts/1e8. Baselines: qjs 71 loads/196 instr ; recursive c0be6fce 163 loads/563 instr.
- crypto = /home/aneryu/javascript-zoo/bench/crypto.js (self-prints "Crypto: N", higher=faster); qjs ~2180, recursive ~640 in current machine state (drifts — always interleave vs a freshly-built baseline).
