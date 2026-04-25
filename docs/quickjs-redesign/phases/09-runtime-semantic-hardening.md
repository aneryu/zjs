# Phase 9: Runtime Semantic Hardening

Status: completed

## Purpose

Phase 9 replaces transitional runtime shortcuts left after Phase 8 with ordinary
QuickJS-style execution paths. The first target is host-visible output:
`print(...)` and `console.log(...)` must execute through global binding lookup,
property access, callable values, call frames, and the existing output sink
instead of parser/emitter-recognized host output opcodes.

This phase also cleans documentation drift after Phases 1-8 so tracking,
matrices, and subsystem status match the completed tooling work.

## QuickJS Source Owners

- `quickjs/quickjs.c`: global object setup, property lookup, function objects,
  and call semantics.
- `quickjs/qjs.c`: host-provided `print` registration and CLI-visible output.
- `quickjs/quickjs-opcode.h`: call opcode shape and bytecode execution
  metadata.

## In Scope

- Remove dedicated `host_print` / `host_print_n` bytecode names and handlers.
- Lower `print(...)` to global lookup plus generic call bytecode.
- Lower `console.log(...)` to global lookup, property read, and generic call
  bytecode.
- Preserve output sink plumbing through `Engine.evalWithOutput*` and `zjs`.
- Cover direct calls, multi-argument output, expression arguments, and indirect
  function calls.
- Move host-visible output tracking out of the Phase 8 runner matrix and into a
  Phase 9 runtime hardening matrix.
- Mark Phase 8 CLI tooling status as validated after the recorded 110/110
  aggregate gate and 45/45 smoke gate.

## Out Of Scope

- Full native function ABI parity.
- Full ECMAScript global environment record semantics.
- BigInt, DataView, and String-wrapper coercion gaps. These remain follow-up
  runtime hardening backlog, not Phase 9 exit blockers.

## Exit Checklist

- [x] No dedicated `host_print` / `host_print_n` known opcode or VM dispatch
  path remains.
- [x] `print(...)` uses normal global binding lookup and generic call bytecode.
- [x] `console.log(...)` uses normal global/property lookup and generic call
  bytecode.
- [x] Direct and indirect output calls preserve the existing smoke golden output.
- [x] `zig build test --summary all` passes.
- [x] `zig build smoke --summary all` passes 45/45 scripts.
- [x] `zig build run-test262 --summary all` passes.
- [x] Targeted JSON and language expression test262 slices pass.
- [x] Final local test262 gate is recorded when Phase 9 is closed.
- [x] `TRACKING.md`, `runtime-semantic-hardening.md`, and affected matrices are
  updated with exact validation evidence.

## Closing Evidence

- `zig build test --summary all`: 112/112 tests passed.
- `zig build smoke --summary all`: 45/45 scripts passed.
- `zig build run-test262 --summary all`: ReleaseFast runner build passed.
- `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 200`: `0/165 errors`.
- `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions 0 500`: `0/499 errors`.
- `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000`: `0/48205 errors, passed 42200`.
- `git diff --check`: passed.
