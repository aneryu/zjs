# Runtime Semantic Hardening Matrix

Purpose: track Phase 9 work that replaces transitional execution shortcuts with
ordinary QuickJS-style runtime semantics.

## Host-Visible Output

| Area | QuickJS owner | Zig owner | Required semantics | Current evidence | Status |
|---|---|---|---|---|---|
| Global binding lookup | `quickjs/quickjs.c` | `src/engine/exec/vm.zig`, `src/engine/exec/call.zig`, `src/engine/frontend/parser.zig` | `print`, `Math`, and `globalThis` resolve through global/property bytecode rather than parser-emitted marker values | `print(...)` lowers to `get_var` plus generic `call`; `Math` and `globalThis` marker constants were removed; frontend 37/37, exec 54/54, aggregate 164/164, smoke 45/45, built-ins/global 0/29, and Math 0/327 passed | validated |
| Property call | `quickjs/quickjs.c` | `src/engine/exec/vm.zig`, `src/engine/frontend/parser.zig` | `console.log(...)` resolves `console` then reads `log` before calling | frontend test covers `get_var`, `get_prop`, and `call`; exec gate 37/37 passed | validated |
| Multi-argument call | `quickjs/quickjs.c`, `quickjs/qjs.c` | `src/engine/exec/vm.zig`, `src/engine/exec/call.zig` | Call arguments preserve order and are joined by spaces for host output | exec tests cover ten-argument `console.log`, indirect multi-argument `print`, direct `exec.call` host invocation, and allocator-backed 40-argument VM calls | validated |
| Host output sink | `quickjs/qjs.c` | `src/engine/root.zig`, `src/engine/exec/call.zig`, `src/cli/qjs.zig` | Output remains supplied by `Engine.evalWithOutput*` / CLI writer, while VM output is a callable side effect | `exec.call` focused coverage, CLI checks, smoke 45/45, and compare 45/45 passed | validated |
| Console object | `quickjs/quickjs.c`, `quickjs/qjs.c` | `src/engine/exec/call.zig`, `src/engine/exec/vm.zig` | `console` is an ordinary global object and `log` is a callable property | property lookup, indirect `const log = console.log; log(...)`, and direct host global installation coverage passed | validated |
| Error propagation | `quickjs/quickjs.c` | `src/engine/exec/vm.zig` | Calling non-callable values raises an execution error instead of silently ignoring the call | generic call path returns `TypeError`/unsupported execution errors for non-callable values; aggregate gate passed | validated |
| Async/job output preservation | `quickjs/quickjs.c`, `quickjs/qjs.c` | `src/engine/exec/jobs.zig`, `src/engine/exec/vm.zig` | Existing async/promise smoke-visible output remains unchanged after output path replacement | `zig build smoke --summary all` passed 45/45 and compare passed 45/45 | validated |

## Completed Follow-Up Work

| Area | Completion evidence | Status |
|---|---|---|
| BigInt coercion and operator hardening | `BigInt.asIntN` / `BigInt.asUintN` now use a shared heap/short BigInt `ToBigInt` path for primitive and string-like inputs; GC-backed multi-limb `Tag.big_int` payloads now support BigInt literals, BigInt-returning operations, arbitrary-precision division/remainder, exponentiation, bitwise, and shift expression execution | completed |
| DataView coercion hardening | `new DataView`, DataView reads, and DataView writes now carry real argument counts, use `ToIndex`, honor byte offsets, lengths, widths, endianness, unsigned 32-bit writes, and BigInt64/BigUint64 setters, share object-owned ArrayBuffer byte storage across views, and delegate current Buffer/DataView opcode semantics to `builtins/buffer.zig` | completed |
| String wrapper coercion hardening | `new String(...)` now constructs a wrapper object with object-owned string data instead of private marker properties; current String wrapper/fromCharCode/charAt/method transitional opcode semantics delegate to `builtins/string.zig` | completed |
