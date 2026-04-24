# Phase 6: Bytecode Execution

Status: completed

## Goal

Implement the QuickJS-style bytecode VM and public `Engine.eval` execution path.
This phase turns compiled bytecode into observable JavaScript behavior while
keeping JavaScript exceptions in context exception state.

## QuickJS References

- `quickjs/quickjs.c` VM dispatch and opcode handler sections.
- `quickjs/quickjs.c` call, construct, reference, exception, eval, iterator, module, promise, and job queue sections.
- `quickjs/quickjs-opcode.h`

## Target Files

- `src/engine/exec/vm.zig`
- `src/engine/exec/frame.zig`
- `src/engine/exec/stack.zig`
- `src/engine/exec/call.zig`
- `src/engine/exec/construct.zig`
- `src/engine/exec/property_ops.zig`
- `src/engine/exec/exceptions.zig`
- `src/engine/exec/iterator.zig`
- `src/engine/exec/eval.zig`
- `src/engine/exec/module.zig`
- `src/engine/exec/promise.zig`
- `src/engine/exec/jobs.zig`
- `src/engine/root.zig`
- `src/tests/exec/all.zig`

## Coverage Matrix

Opcode-level execution tracking lives in
`../matrices/opcode-execution-matrix.md`. Phase 6 cannot complete until every
reachable opcode has a handler or a tested lowering/removal path.

## Work Breakdown

- [x] Implement stack and frame layout with explicit ownership and stack limits.
- [x] Implement opcode dispatch and representative primitive op handlers.
- [x] Implement call, construct, return, argument, `this`, and bound function behavior.
- [x] Implement references and property operations through `exec/property_ops.zig`.
- [x] Implement exception throw, catch, finally, stack traces, and context exception transfer.
- [x] Implement iterator open/next/close behavior.
- [x] Implement `super`, private fields, and home-object execution semantics.
- [x] Implement direct and indirect eval paths through `exec/eval.zig`.
- [x] Implement module linking, cyclic dependency handling, namespace objects, and evaluation.
- [x] Implement promise job queue, `runJobs`, and unhandled rejection hooks needed by QuickJS core.
- [x] Expose working `Engine.init`, `Engine.eval`, `Engine.runJobs`, and `Engine.takeException`.

## Validation

```bash
zig fmt .
zig build test --summary all
```

Representative execution tests should cover:

- Arithmetic, comparisons, conversions, and control flow.
- Function calls, closures, constructors, and `this`.
- Object property get/set/delete/define paths.
- Exceptions and finally.
- Iterators and for-of behavior.
- Classes, `super`, and private fields.
- Eval and module basics.
- Promise job ordering.
- Stack-limit failures.

## Exit Checklist

- [x] `Engine.eval` executes representative bytecode programs.
- [x] All reachable opcode rows in `../matrices/opcode-execution-matrix.md` are `validated`.
- [x] JavaScript exceptions are not modeled as normal Zig errors internally.
- [x] `runJobs` drains promise jobs deterministically.
- [x] `status.zig` marks execution subsystems as `validated`.
- [x] `TRACKING.md` records validation evidence and remaining broad test262 risks.

## Handoff Notes

Phase 6 validates the VM execution skeleton and representative opcode families.
Broad semantic parity is still expected to expand through Phase 7 builtin/support
library work and Phase 8 smoke/compare/test262 gates.
