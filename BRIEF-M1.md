# M1 — register-resident hot state in dispatchRecursive (read ALIGN-PLAN.md first)

Working dir: /tmp/wt-align/third_party/zjs (branch off c0be6fce). Target file: src/exec/call_internal.zig `dispatchRecursive`. Goal: make the hot loop hold pc / code_end / sp / var_buf / arg_buf in REGISTERS exactly like qjs JS_CallInternal, so the per-opcode memory reloads disappear (163 L1-loads/iter -> toward qjs 71). Read ALIGN-PLAN.md for the full why + constraints.

## Do these, in order, MEASURING loads/iter after each (taskset -c 5 perf stat -e instructions,L1-dcache-loads zig-out/bin/zjs /tmp/lv-int.js):

### A1 — pc as an incrementing pointer `*ip++` (not `code[pc]` base+index)
This is ALREADY IMPLEMENTED + proven correct (−17% loads, full suite passes) in `/tmp/wt-q-ptr/third_party/zjs/src/exec/call_internal.zig`. Diff it vs this worktree's call_internal.zig (`git -C /tmp/wt-q-ptr diff c0be6fce -- third_party/zjs/src/exec/call_internal.zig`) and PORT it. Summary of what it does: replace `var pc: usize` + `code[pc..]`/`code[pc]` with `var ip: [*]const u8 = code.ptr + frame.pc`; opcode = `ip[0]; ip += 1`; operands via `ip[0..N]`; `ip += N`; `frame.pc = pc` -> `frame.pc = ipOff(ip, function.code.ptr)` (helper `inline fn ipOff(ip, base) usize = @intFromPtr(ip)-@intFromPtr(base)`); `pc = frame.pc` -> `ip = function.code.ptr + frame.pc`; jump arms set `ip = function.code.ptr + relativePc(ipOff(...), diff)`. Use `function.code.ptr` (not a hoisted local) at cold/jump sites so the base is not a separately-spilled hot live value.

### A2 — code_end in a register-resident local + pointer-form bounds check
`const code_end = code.ptr + code.len;` at entry. Loop-top bounds check becomes `if (ip == code_end) { ... fall-off-end ... }` (the c0be6fce fall-off-end handling). DO NOT delete the bounds check entirely — crypto genuinely falls off the end of some non-return-terminated bodies (proven: deleting it = InvalidBytecode). The pointer-form `ip == code_end` keeps both ip and code_end in registers (zero load) vs the baseline's `ldr [sp,#248]` reload.

### A4 — operand stack sp as a bare register-resident pointer (`*sp++`), length only at boundaries  ← THE BIG ONE
Today (c0be6fce) the hot loop uses `base: [*]JSValue` + `sp_len: usize` (register) and pushes via `base[sp_len]; sp_len += 1`. qjs uses a single `sp` pointer: push = `sp[0] = v; sp += 1`, pop = `sp -= 1; v = sp[0]`, top = `sp[-1]`. Convert the windowed-stack helpers (pushOwnedWindow/pushBorrowedWindow/pushSlotWindow/popWindow + the tryFast* helpers + every hot arm) to carry a `var sp: [*]core.JSValue = stack.values.ptr + stack.values.len` (the live top) instead of base+sp_len. The operand-stack LENGTH is then implicit (`sp - base`) and NOT maintained in memory on the hot path.
- enterStackBoundary (publish before cold op / GC / sub-call): `stack.values = base[0 .. (@intFromPtr(sp) - @intFromPtr(base)) / @sizeOf(core.JSValue)];` then the existing mutable-root + assert.
- leaveStackBoundary (reload after cold op, which may have realloc'd/grown the stack): `base = stack.values.ptr; sp = stack.values.ptr + stack.values.len;`.
- Keep `base` as a register local too (needed to compute the length at boundaries and for bounds asserts). So the hot state is {ip, code_end, sp, base, var_buf, arg_buf}.
- PRESERVE the GC-root publish discipline EXACTLY (ALIGN-PLAN constraints). Every arm that can allocate/GC/sub-call must enterStackBoundary before + leaveStackBoundary after. The dual-population assert must hold.

### A5 — var_buf / arg_buf as register-resident pointers
Today get_loc/put_loc/get_arg do `frame.locals[idx]` / `frame.args[idx]` which reload `frame.locals.ptr` / `frame.args.ptr` from the frame struct every access. Capture once at entry: `var var_buf: [*]core.JSValue = frame.locals.ptr; var arg_buf: [*]core.JSValue = frame.args.ptr;` and use `var_buf[idx]` / `arg_buf[idx]` in the hot get_loc*/put_loc*/get_arg* arms. CAUTION: if any cold arm can REALLOCATE frame.locals/args (e.g. eval growing the frame, var-ref boxing), it must refresh var_buf/arg_buf after (treat like the stack reload at leaveStackBoundary). Verify which paths can move frame.locals/args and refresh there; when unsure, refresh var_buf/arg_buf in leaveStackBoundary too (always safe, just a couple extra loads on cold paths).

## Gate (MUST pass before committing; commit when green)
1. Build all 3 flags, 0 errors: `zig build zjs` ; `zig build zjs -Dzjs_tailcall_dispatch=true` ; `zig build zjs -Dzjs_recursive_dispatch=true`.
2. DEBUG dual-population assert: `zig build zjs -Doptimize=Debug -Dzjs_recursive_dispatch=true` then `zig-out/bin/zjs -e 'var s=0;function f(a){var x=a*2;var arr=[a,x];arr[0]=x;return arr[0]+x} for(var i=0;i<300000;i++)s+=f(i); var m=new Map([[1,2]]);for(const[k,v]of m)s+=k+v; try{null.y}catch(e){s+=1} print(s)'` → MUST print 179999400004, no panic.
3. GC-stress: temporarily set the gc threshold tiny in src/core/runtime.zig, rebuild Debug recursive, run the same script, no UAF/panic; REVERT the threshold hack.
4. smoke (release recursive): `zig-out/bin/zjs /tmp/lv-int.js` → "loop 896" (or run a couple bench files: crypto.js prints a Crypto score, deltablue.js runs).
5. MEASURE + REPORT: loads/iter + instr/iter on /tmp/lv-int.js after the change (target: well below the 163/563 baseline, toward qjs 71/196), and crypto best-of-5 vs a freshly-built c0be6fce recursive baseline.
6. `zig fmt src/exec/call_internal.zig` then `git add -A && git commit -m "align(zjs): M1 register-resident hot state in dispatchRecursive (*pc++ ptr + code_end/sp/var_buf/arg_buf registers)"`.

## Constraints
- Correctness first. When an arm is unclear about GC/realloc safety, treat it as a boundary (publish + reload) — always safe, just not maximally fast.
- Do NOT touch the tailcall or dispatchLoop dispatchers (only call_internal.zig dispatchRecursive + its helpers).
- If you cannot make the full suite correct, COMMIT the largest correct subset (e.g. A1+A2+A5 without A4) and clearly report what's left + why, with the measured loads/iter at that point.
