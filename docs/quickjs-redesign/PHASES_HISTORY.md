# QuickJS Redesign Phases History

Last updated: 2026-04-27

This document consolidates the nine completed redesign phases into a single
historical summary. The original per-phase execution plans live in
`archive/phases/` for deep-dive reference. Active project state (current work,
follow-up queues, validation log, risks, and handoff notes) remains in
`TRACKING.md`, `ARCHITECTURE_REPAIR_PLAN.md`, `ERRORS_AND_LEARNINGS.md`, and
`matrices/`.

## Summary Table

| Phase | Scope | Status | Matrix | Closing validation |
|---|---|---|---|---|
| 1 Bootstrap And Source Baseline | Source tree, build wiring, source/status metadata | completed | none | `zig build test-quickjs-port --summary all` |
| 2 Core Runtime Foundations | Values, runtime, context, atoms, strings, classes, shapes, functions, modules, GC scaffolding | completed | `matrices/core-runtime-invariants.md` | Focused core fixtures pass |
| 3 Object And Property Semantics | Ordinary objects, descriptors, prototypes, own-keys, extensibility, array index/length | completed | `matrices/object-property-matrix.md` | Focused object/property fixtures pass |
| 4 Opcode And Bytecode Metadata | Opcode table, formats, constants, scopes, module bytecode, debug tables | completed | `matrices/opcode-execution-matrix.md` | Focused bytecode metadata fixtures pass |
| 5 Frontend And Bytecode Emitter | Lexer, parser, regexp literal, source positions, direct bytecode emission | completed | `matrices/frontend-coverage-matrix.md` | `quickjs_parser` is the only successful parse path |
| 6 Bytecode Execution | VM dispatch, frames, calls, exceptions, eval, modules, promises, jobs, iterators | completed | `matrices/opcode-execution-matrix.md` | Representative VM dispatch, Engine API, and job queue fixtures pass |
| 7 Builtins And Support Libraries | Regexp, Unicode, bignum, dtoa plus builtin constructors/prototypes | completed | `matrices/builtins-support-matrix.md` | Focused support library and builtin domain fixtures pass |
| 8 CLI Tooling And Validation | `zjs`, smoke runner, compare workflow, test262 runner | completed | `matrices/test262-runner-parity.md` | Full local test262 `0/48205 errors, passed 42200` |
| 9 Runtime Semantic Hardening | Remove transitional shortcuts; route host output through global lookup and generic call | completed | `matrices/runtime-semantic-hardening.md` | `zig build test --summary all` and full local test262 passed |

## Phase 1: Bootstrap And Source Baseline

**Scope.** Recreate the minimal source tree and build wiring needed to start
the rewrite without relying on deleted engine paths. Establish the QuickJS
source baseline, status metadata, and the first Zig test gate.

**QuickJS source owners.** `quickjs.c`, `quickjs.h`, `quickjs-opcode.h`,
`quickjs-atom.h`, `list.h`, `cutils.h`, `libregexp.c`, `libregexp-opcode.h`,
`libunicode.c`, `libunicode-table.h`, `libbf.c`, `libbf.h`, `dtoa.c`,
`run-test262.c`, `test262.conf`.

**Key target files.** `src/engine/root.zig`, `src/engine/source.zig`,
`src/engine/status.zig`, subsystem `root.zig` stubs under
`core`/`frontend`/`bytecode`/`exec`/`builtins`/`libs`, `src/tests/quickjs_port.zig`,
`build.zig`.

**Exit contract.**
- `src/engine/` tree exists without `src/engine/vm/`.
- `build.zig` has no stale deleted root references.
- `source.zig` records the QuickJS semantic baseline and status table.
- `zig build test-quickjs-port --summary all` passes.
- No Phase 1 root export pretends to evaluate JavaScript.

**Handoff.** `zjs`, `run-test262`, smoke, and VM-only build steps were
intentionally absent until lower layers existed, to avoid stale roots and
executable placeholders during bootstrap.

## Phase 2: Core Runtime Foundations

**Scope.** Port the runtime foundations required by every higher layer: value
tags, reference lifetime, runtime/context ownership, atoms, strings, classes,
shapes, function records, module records, exception slots, allocator
accounting, and GC scaffolding.

**QuickJS source owners.** `quickjs.h`, `quickjs.c` (runtime, context, atom,
string, class, shape, function, module, GC sections), `quickjs-atom.h`,
`list.h`, `cutils.h`.

**Key target files.** `src/engine/core/` (`value`, `list`, `gc`, `atom`,
`string`, `class`, `shape`, `function`, `module`, `runtime`, `context`,
`exception`, `memory`), `src/tests/core/all.zig`.

**Exit contract.**
- Runtime/context init-deinit is leak-free.
- QuickJS tag constants and invariants are locked by tests.
- `status.zig` marks completed core foundations as `validated`.
- No public API exposes raw reference payloads or `anyopaque`.

**Handoff.** Phase 2 provides the validated runtime foundation records. GC
cycle removal remained a scaffold by design; real object-graph marking and
payload traversal waited for Phase 3 object semantics and later work.

## Phase 3: Object And Property Semantics

**Scope.** Port ordinary object behavior before parser, VM, or builtins depend
on it: descriptors, prototype traversal, property flags, own-key order,
extensibility, array index rules, and array length behavior.

**QuickJS source owners.** `quickjs.c` object/shape/property/descriptor/
prototype/array helper sections, `quickjs.h` property flags.

**Key target files.** `src/engine/core/object.zig`,
`src/engine/core/property.zig`, `src/engine/core/descriptor.zig`,
`src/engine/core/array.zig`, `src/engine/core/shape.zig`.

**Exit contract.**
- Ordinary object and array property semantics pass focused tests.
- Builtins and VM can use shared object/property APIs without shortcuts.
- `status.zig` marks object/property/array core as `validated`.

**Handoff.** Phase 3 validates ordinary object descriptors, prototype lookup,
own-key order, extensibility, seal/freeze, array index detection, sparse
length truncation, dense/sparse storage mode tracking, and exotic dispatch
hook shape. Exotic object-specific behavior was deferred to later phases.

## Phase 4: Opcode And Bytecode Metadata

**Scope.** Lock opcode order, formats, stack metadata, bytecode ownership,
constant pools, scope records, module bytecode records, and debug/source
tables before building frontend or VM.

**QuickJS source owners.** `quickjs-opcode.h`, and `quickjs.c` bytecode/
function bytecode/closure variable/scope/debug metadata sections.

**Key target files.** `src/engine/bytecode/` (`opcode`, `format`, `function`,
`constant`, `scope`, `module`, `debug`).

**Exit contract.**
- Opcode table matches QuickJS.
- Bytecode structures are owned and freed deterministically.
- `status.zig` marks opcode and bytecode metadata as `validated`.

**Handoff.** Opcode metadata is generated at test/build time by parsing local
`quickjs/quickjs-opcode.h` via `src/engine/bytecode/opcode.zig`; the Zig tree
does not maintain a duplicated opcode table.

## Phase 5: Frontend And Bytecode Emitter

**Scope.** Port QuickJS frontend and emit bytecode directly. No AST
interpreter or standalone execution path is re-created.

**QuickJS source owners.** `quickjs.c` lexer/parser/scope/function parsing/
class parsing/destructuring/eval/module/bytecode emission sections,
`quickjs-opcode.h`.

**Key target files.** `src/engine/frontend/` (`token`, `lexer`, `parser`,
`regexp_literal`, `source_pos`), `src/engine/bytecode/emitter.zig`,
`src/engine/bytecode/scope.zig`, `src/engine/bytecode/function.zig`,
`src/engine/bytecode/module.zig`.

**Exit contract.**
- Parser/emitter fixtures pass without AST execution.
- Bytecode output uses Phase 4 opcode metadata.
- Source position and syntax-error metadata are tested.
- `status.zig` marks frontend and emitter subsystems as `validated`.

**Handoff.** Phase 5 validated parser/emitter metadata only. Generated
bytecode execution remained Phase 6 work tracked in
`matrices/opcode-execution-matrix.md`.

## Phase 6: Bytecode Execution

**Scope.** Implement the QuickJS-style VM and public `Engine.eval` path,
turning compiled bytecode into observable JavaScript while keeping JavaScript
exceptions in context exception state.

**QuickJS source owners.** `quickjs.c` VM dispatch/opcode handler sections and
call/construct/reference/exception/eval/iterator/module/promise/job queue
sections, `quickjs-opcode.h`.

**Key target files.** `src/engine/exec/` (`vm`, `frame`, `stack`, `call`,
`construct`, `property_ops`, `exceptions`, `iterator`, `eval`, `module`,
`promise`, `jobs`), `src/engine/root.zig`.

**Exit contract.**
- `Engine.eval` executes representative bytecode programs.
- JavaScript exceptions are not modeled as normal Zig errors internally.
- `runJobs` drains promise jobs deterministically.
- `status.zig` marks execution subsystems as `validated`.

**Handoff.** Phase 6 validates the VM execution skeleton and representative
opcode families. Broad semantic parity was expected to expand through Phase 7
builtin/support library work and Phase 8 smoke/compare/test262 gates.

## Phase 7: Builtins And Support Libraries

**Scope.** Port QuickJS core builtins and low-level support libraries so that
builtins use the same object/property/call/exception paths as user code.

**QuickJS source owners.** `quickjs.c` intrinsic registration and builtin
sections, `libregexp.c`, `libregexp-opcode.h`, `libunicode.c`,
`libunicode-table.h`, `quickjs.c` BigInt/bignum sections, `dtoa.c`.

**Key target files.** `src/engine/libs/` (`regexp`, `regexp_opcode`,
`unicode`, `unicode_tables`, `bignum`, `dtoa`) and `src/engine/builtins/*.zig`.

**Exit contract.**
- Support libraries have focused tests and leak-free teardown.
- Builtins route through shared object/property/call/exception paths and do
  not bypass them.
- `status.zig` marks completed builtin domains as `validated`.

**Handoff.** Phase 7 validated representative support-library and
builtin-domain behavior. Broad smoke/compare/test262 validation stayed Phase 8
work once CLI and validation tooling were wired into the redesigned engine.

## Phase 8: CLI Tooling And Validation

**Scope.** Rebuild `zjs`, the smoke runner, the compare workflow, and the
test262 runner on top of the redesigned engine. Complete only when no deleted
engine path remains in the tooling graph.

**QuickJS source owners.** `qjs.c`, `run-test262.c`, `test262.conf`.

**Key target files.** `src/cli/qjs.zig`, `src/cli/run_test262.zig`,
`src/tools/smoke_runner.zig`, `src/tools/test262_runner.zig`, `build.zig`,
and compare invocation under `tools/compare/` where needed.

**Exit contract.**
- `zjs -e "<script>"` and `zjs <file.js>` work through the rebuilt engine.
- Smoke runner honors `tests/zig-smoke/manifest.txt` plus golden output.
- `run-test262` matches QuickJS runner semantics for config, excludes, known
  errors, direct selection, harness loading, metadata, and workers.
- Final test262 gate has no new unexpected failures relative to the local
  QuickJS configuration.
- Host-visible output tracking transfers to the Phase 9 runtime semantic
  hardening matrix.

**Handoff.** Test262 execution runs in-process instead of spawning `zjs`
per test. Runner selection follows `run-test262.c`: namelists grow by
capacity, are sorted/deduped, feature skipping happens at execution,
and `-t` workers distribute tests by index stride. Harness includes are
cached per worker. Full local test262 runs in about 15 s with ReleaseFast,
most recently recording `0/48205 errors, passed 42200`. Host-visible output
hardening (`print` / `console.log`) was deferred to Phase 9.

## Phase 9: Runtime Semantic Hardening

**Scope.** Replace transitional runtime shortcuts left after Phase 8. First
target is host-visible output: `print(...)` and `console.log(...)` must
execute through global binding lookup, property access, callable values,
call frames, and the existing output sink instead of parser/emitter-recognized
host-output opcodes. Also finish BigInt, DataView, and String-wrapper
coercion hardening and clean documentation drift from Phases 1-8.

**QuickJS source owners.** `quickjs.c` (global object setup, property lookup,
function objects, call semantics), `qjs.c` (host `print` registration),
`quickjs-opcode.h` (call opcode shape).

**Out of scope.** Full native function ABI parity and full ECMAScript global
environment record semantics.

**Exit contract.**
- No dedicated `host_print` / `host_print_n` opcode or VM dispatch path
  remains.
- `print(...)` and `console.log(...)` use normal global/property lookup and
  generic call bytecode.
- Direct and indirect output calls preserve the existing smoke golden output.
- BigInt/DataView/String-wrapper coercion follow-up work is completed with
  focused regression coverage.
- Full local test262 gate is recorded at phase close.

**Closing evidence.**
- `zig build test --summary all`: 132/132 tests passed after aggregate runner
  self-test wiring.
- `zig build smoke --summary all`: 45/45 scripts.
- `zig build run-test262 --summary all`: ReleaseFast runner build passed.
- BigInt/DataView/String targeted test262 slices passed.
- DataView numeric/BigInt setter and ArrayBuffer slice regressions were fixed
  with focused exec coverage.
- `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 200`: `0/165 errors`.
- `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions 0 500`: `0/499 errors`.
- `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000`: `0/48205 errors, passed 42200`.
- `git diff --check`: passed.

## Follow-Up Work

After Phase 9 and Architecture Repair closure, remaining semantic-completion
work is tracked in `TRACKING.md` as WQ-012 through WQ-015:

- Builtin prototype and descriptor completion (Array/Object/String/Function/
  Promise/Collection and friends).
- Support library completion (RegExp, Unicode, BigInt/bignum, dtoa) beyond
  current focused fixtures.
- GC cycle and weak collection semantics.
- Capacity and OOM hardening replacing hidden fixed limits with
  allocator-backed fallible paths.

These follow-ups are not bounded by the phase structure above; consult
`TRACKING.md` and `ARCHITECTURE_REPAIR_PLAN.md` for current queue state.
