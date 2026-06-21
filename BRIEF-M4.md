# M4 — labeled-switch `continue :sw` per-handler-tail dispatch (read ALIGN-PLAN.md; builds on M2 @ 3be3ea4f)

Working dir: /tmp/wt-align/third_party/zjs. Target: src/exec/call_internal.zig `dispatchRecursive`. Goal: replace the central `while (true) { switch (opc) {...} }` with Zig 0.16's labeled-switch direct-threaded dispatch so EACH opcode handler ends with its OWN dispatch jump (`continue :sw <next opcode>`) instead of falling back to one central switch — this is qjs's DIRECT_DISPATCH / computed-goto equivalent. Zig docs present the VM interpreter loop as the motivating use of this feature.

## Why (measured)
On the pure-int loop the biggest hot branch in the current central switch is `b.hi` (3.24% self) = the opcode RANGE CHECK guarding the jump table, immediately before `br x8` (the indirect dispatch). qjs's computed-goto over a 256-entry table indexed by a u8 opcode needs NO range check. A labeled-switch that is EXHAUSTIVE over the u8 opcode space should let LLVM emit a bare jump table (no range check) AND a per-handler dispatch site.

## The transformation
Current shape (after M1/M2):
```
var ip: [*]const u8 = ...; const code_end = ...;
while (true) {
    if (ip == code_end) { ...fall-off... }
    const opc = ip[0]; ip += 1;
    switch (opc) {
        op.add => { ...; continue; },   // falls back to loop top = central re-dispatch
        ...
        else => ...,
    }
}
```
Target shape (labeled-switch, per-handler-tail dispatch):
```
var ip: [*]const u8 = ...; const code_end = ...;
sw: switch (ip[0]) {
    op.add => {
        ...handler...
        ip += n;
        if (ip == code_end) break :sw;   // or fold fall-off into a dedicated terminal opcode
        continue :sw ip[0];              // <-- per-handler dispatch jump
    },
    ... every opcode ...
    else => { ...cold/invalid... },
}
```
Key requirements:
1. **Exhaustive over u8** so no range check is emitted. If `op` is an enum(u8), switch all tags + `else`. If `op.*` are u8 constants, ensure the switch covers the full 0..255 via an `else` that routes unknown opcodes to the existing invalid/cold handler — but structure it so LLVM still builds a 256-entry jump table without a per-dispatch range compare. Verify in disasm that the `b.hi` range-check is GONE.
2. Every handler ends with `continue :sw ip[0]` (after advancing ip) — the per-handler dispatch. The fall-off-end check (`ip == code_end`) must still happen before each dispatch; fold it efficiently (e.g. a sentinel terminal opcode, or keep the cheap `ip==code_end` compare — both registers, no load).
3. PRESERVE everything from M1/M2: register-resident ip/code_end/sp/base/var_buf/arg_buf, the inlined hot opcode bodies (no bl), the noinline slow helpers, the enterStackBoundary/leaveStackBoundary GC-publish discipline (cold arms still publish before delegating + reload after, then `continue :sw ip[0]`).
4. The cold/delegating arms: after `enterStackBoundary; <delegate>; leaveStackBoundary;` they set `ip = function.code.ptr + frame.pc` (delegate may have jumped) then `continue :sw ip[0]`.

## Gate (MUST pass; commit when green)
1. Build 3 flags 0 errors (`zig build zjs`, `-Dzjs_tailcall_dispatch=true`, `-Dzjs_recursive_dispatch=true`).
2. Debug recursive assert script -> 179999400004, no panic; GC-stress (tiny threshold) -> same, no UAF, revert hack.
3. `zig build test --summary all` -> 1192 passed; 0 failed.
4. **DISASM CHECK (the whole point):** objdump dispatchRecursive — confirm the `b.hi` opcode range-check before the dispatch is GONE and each handler has its own dispatch (`ldrb`+jump-table+`br`) at its tail. Report before/after.
5. **MEASURE:** lv-int branches/instr/loads per-iter (target: branches drop from 108 toward qjs 26 — the range-check + central re-dispatch removed) + crypto best-of-5 vs /tmp/zjs-aligned (the M2 baseline). Report.
6. `zig fmt`; `git add -A && git commit -m "align(zjs): M4 labeled-switch continue:sw per-handler dispatch (direct threading)"`.

## Constraints
- Correctness first; the GC-publish discipline + dual-population assert must hold. Don't drop the fall-off-end check (crypto falls off non-return-terminated bodies).
- Do NOT touch tailcall/dispatchLoop dispatchers.
- If Zig's labeled-switch does NOT eliminate the range check / does NOT generate per-site dispatch (verify in disasm), REPORT that honestly with the disasm — a null/negative codegen result is a valid, important finding (the document warns "ideally through a jump table" is not guaranteed). In that case commit nothing and report; do not force a regression.
- If the full 297-arm conversion is too large to land cleanly, convert the HOT opcodes first (get_loc*/get_arg*/put_loc*/push*/int-arith/compare/if/goto/inc/dec/drop/dup) to `continue :sw` and leave the rest falling through to a trailing central switch, measure that, and report.
