# Runtime Semantic Hardening Matrix

Purpose: track Phase 9 work that replaces transitional execution shortcuts with
ordinary QuickJS-style runtime semantics.

## Host-Visible Output

| Area | QuickJS owner | Zig owner | Required semantics | Current evidence | Status |
|---|---|---|---|---|---|
| Global binding lookup | `quickjs/quickjs.c` | `src/engine/exec/vm.zig`, `src/engine/frontend/parser.zig` | `print` resolves as a normal global property before call execution | `print(...)` lowers to `get_var` plus generic `call`; frontend gate 21/21 and aggregate gate 112/112 passed | validated |
| Property call | `quickjs/quickjs.c` | `src/engine/exec/vm.zig`, `src/engine/frontend/parser.zig` | `console.log(...)` resolves `console` then reads `log` before calling | frontend test covers `get_var`, `get_prop`, and `call`; exec gate 37/37 passed | validated |
| Multi-argument call | `quickjs/quickjs.c`, `quickjs/qjs.c` | `src/engine/exec/vm.zig` | Call arguments preserve order and are joined by spaces for host output | exec tests cover ten-argument `console.log` and indirect multi-argument `print`; CLI check passed | validated |
| Host output sink | `quickjs/qjs.c` | `src/engine/root.zig`, `src/engine/exec/vm.zig`, `src/cli/qjs.zig` | Output remains supplied by `Engine.evalWithOutput*` / CLI writer, while VM output is a callable side effect | CLI checks, smoke 45/45, and compare 45/45 passed | validated |
| Console object | `quickjs/quickjs.c`, `quickjs/qjs.c` | `src/engine/exec/vm.zig` | `console` is an ordinary global object and `log` is a callable property | property lookup and indirect `const log = console.log; log(...)` exec/CLI coverage passed | validated |
| Error propagation | `quickjs/quickjs.c` | `src/engine/exec/vm.zig` | Calling non-callable values raises an execution error instead of silently ignoring the call | generic call path returns `TypeError`/unsupported execution errors for non-callable values; aggregate gate passed | validated |
| Async/job output preservation | `quickjs/quickjs.c`, `quickjs/qjs.c` | `src/engine/exec/jobs.zig`, `src/engine/exec/vm.zig` | Existing async/promise smoke-visible output remains unchanged after output path replacement | `zig build smoke --summary all` passed 45/45 and compare passed 45/45 | validated |

## Follow-Up Backlog

| Area | Reason deferred | Status |
|---|---|---|
| BigInt coercion hardening | Broader runtime conversion work, not required to remove output opcodes | backlog |
| DataView coercion hardening | Requires ToIndex/ToNumber coverage beyond Phase 9 output path | backlog |
| String wrapper coercion hardening | Requires object-to-primitive/string wrapper parity beyond Phase 9 output path | backlog |
