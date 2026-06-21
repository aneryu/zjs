# A1 — dispatch labeled-switch (Route A): align to qjs computed-goto

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align tip 38ad2546). #1 ranked alignment lever. The dispatcher is the ONLY hot subsystem still structurally DIVERGENT from qjs and it runs once per EVERY opcode.

## The divergence (measured)
zjs dispatchRecursive (call_internal.zig, the loop ~899-917) is a central `while(true){ if(ip==code_end)...; opc=ip[0]; switch(opc){ ...250 handlers... } }`. Every handler `b`-branches back to ONE shared dispatch block that does PER OPCODE: fall-off-end check `cmp ip,code_end; b.eq` (qjs has NONE), opcode fetch `ldrb`, RANGE CHECK `cmp #0xfa; b.hi` (qjs has NONE — full 256-entry table), table-base `adrp+add` recompute (qjs holds it in a callee-saved reg), a 16-bit-offset jump-table `adr+ldrh+add x8,x8,x9,lsl#2`, `br`. = 12 instr/op vs qjs computed-goto 5 instr/op (2.4x). One shared `br` site = one BTB slot for all 250 opcodes (worse prediction on irregular code).

qjs: `#define SWITCH(pc) goto *dispatch_table[opcode=*pc++]; #define BREAK SWITCH(pc)` (quickjs.c:17767-17784, DIRECT_DISPATCH=1) — each handler ends with its OWN dispatch goto (per-handler br site, per-site BTB), no range check (table padded to 256 with case_default), table base loop-invariant.

## The fix — Zig 0.16 labeled-switch (Route A, KEEP everything in one function)
Convert the central `while+switch` to a labeled-switch so each arm ends with its OWN dispatch `continue :sw`:
```
var ip: [*]const u8 = ...; const code_end = ...; (keep register-resident sp/base/var_buf/arg_buf as now)
sw: switch (ip[0]) {
    op.get_loc0 => { ...handler...; ip += 1; continue :sw ip[0]; },
    op.add      => { ...handler...; ip += 1; continue :sw ip[0]; },
    ... every one of the ~250 opcodes, each ending with `ip += <n>; continue :sw ip[0];` ...
    else => unreachable,   // verifier guarantees opc < op count -> NO range check emitted
}
```
Key requirements (this is exactly what makes it qjs-computed-goto-equivalent):
1. **`else => unreachable`** so LLVM drops the `cmp #0xfa; b.hi` range check (the bytecode verifier already guarantees a valid opcode). Confirm in objdump the `b.hi` is gone.
2. **Each arm ends with `continue :sw ip[0]`** (after advancing ip by its operand size) — Zig 0.16 lowers each `continue :sw` to its own jump-table `br` at the arm tail = per-handler dispatch site (computed-goto). Confirm in objdump there are now MANY `br` sites (one per arm), not one shared block.
3. **Fall-off-end:** the `ip == code_end` check — either keep it as a cheap `if (ip == code_end) break :sw;` at each dispatch (2 registers, no load — acceptable), OR (cleaner, qjs-style) ensure every function's bytecode ends with an explicit return opcode at build time so the check is unnecessary; if a build-time guarantee already exists or is easy, drop the check, else keep the cheap register compare. Do NOT regress correctness (crypto falls off non-return-terminated bodies today).
4. **Table base loop-invariant:** the labeled-switch should let LLVM keep the jump-table base in a register across iterations (verify the per-op `adrp` recompute is gone or hoisted).
5. PRESERVE all current state: register-resident ip/code_end/sp/base/var_buf/arg_buf, the inlined hot opcode bodies (no bl), the noinline slow paths, the enterStackBoundary/leaveStackBoundary GC-publish discipline (cold arms still publish before delegating + reload after, then `continue :sw ip[0]`).
DO NOT use the tailcall_dispatch.zig route (Route B) — it sends cold ops across a callconv(.c) boundary that spills; Route A (labeled-switch in one function) avoids that and keeps property/call/alloc handlers cheap.

## Gate (CORRECTNESS first, then the alignment proof)
1. Build 3 flags 0 errors (`zig build zjs`, `-Dzjs_tailcall_dispatch=true`, `-Dzjs_recursive_dispatch=true`).
2. `zig build test --summary all` → 1192 (or 1194) passed; 0 failed.
3. GC-stress (tiny threshold 64): the cycle+alloc script → correct, no leak/UAF; revert. splay.js + crypto.js + richards.js run.
4. **ALIGNMENT PROOF (objdump /tmp/... dispatchRecursive):** the `cmp #0xfa; b.hi` range check is GONE; the `cmp ip,code_end` per-op end-check is gone or cheap; each opcode arm has its own dispatch `br` at its tail (not one shared block); table base no longer `adrp`-recomputed per op. Report before/after dispatch instruction count (target ~12→~5-6/op).
5. **PERF:** empty-loop micro `function b(){var s=0;for(var i=0;i<100000000;i++)s=(s+i)&1023;return s} b()` instructions+cycles/iter (target 509→~300-350 instr, 70→~45-50 cyc, toward qjs 196/33). Report crypto + a couple Octane scores vs /tmp/zjs-memfixed.
6. `zig fmt`; commit `perf(zjs): A1 dispatch labeled-switch — per-handler computed-goto (align qjs DIRECT_DISPATCH)`.

## Constraints
- CORRECTNESS first (test262 is the hard gate, I run it after; you run unit 1192/0 + GC-stress + smokes). The labeled-switch must preserve exact semantics incl. jumps/exceptions/fall-off.
- Do NOT judge/revert on perf — commit on correctness-green; perf is the alignment proof, measured.
- This is a large mechanical change (~250 arms). If a clean full conversion is too big, convert the HOT arms first (get_loc*/get_arg*/put_loc*/push*/arith/compare/if/goto/inc/dec/drop/dup + field/array fast paths) to `continue :sw` and leave the rest going through a trailing central switch (still a win), COMMIT, and report coverage + measured delta.
