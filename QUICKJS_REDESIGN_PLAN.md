# QuickJS Zig Core Engine Design

## Project Goal

This project will rebuild the QuickJS core JavaScript engine in Zig 0.16.0 from the current clean `src/engine/` state. The goal is a complete QuickJS core engine implementation, not an MVP, not a compatibility patch over the deleted Zig VM, and not a simplified interpreter.

The semantic authority is the local QuickJS source at commit `64e64ebb1dd61505c256285a699c65c42941c5ed`. The primary reference files are:

- `quickjs/quickjs.c`
- `quickjs/quickjs.h`
- `quickjs/quickjs-opcode.h`
- `quickjs/quickjs-atom.h`
- `quickjs/list.h`
- `quickjs/cutils.h`
- `quickjs/libregexp.c`
- `quickjs/libregexp-opcode.h`
- `quickjs/libunicode.c`
- `quickjs/libunicode-table.h`
- `quickjs/libbf.c`
- `quickjs/libbf.h`
- `quickjs/dtoa.c`
- `quickjs/run-test262.c`
- `quickjs/test262.conf`

Completeness means the selected QuickJS core engine scope has no intentional semantic gaps under the local `quickjs/test262.conf` baseline. It does not mean implementing `qjsc`, `quickjs-libc`, QuickJS std/os modules, or a full QuickJS C ABI.

## Current Repository State

- `src/engine/` has been cleared. There is no active Zig engine, parser, compiler, VM, CLI adapter, test262 runner, or Zig test tree.
- `build.zig` still references deleted paths such as `src/engine/root.zig`, `src/cli/qjs.zig`, `src/tools/test262_runner.zig`, and `src/tests/*`. Treat this as stale wiring to replace, not as active design.
- Retained assets are `quickjs/`, `tests/zig-smoke/`, `tools/compare/`, `SPEX.md`, this design document, and the long-running redesign docs under `docs/quickjs-redesign/`.
- `AGENTS.md` and `quickjs-zig-plan.md` still describe the previous VM-era layout. They are historical context only and are not the source of truth for the rebuild.

## Design Principles

- Follow `SPEX.md`: internal code must be Zig-style, allocator ownership must be explicit, errors must be explicit, and C ABI concepts must stay at narrow boundaries.
- QuickJS C source defines JavaScript semantics. Zig APIs may be safer and more explicit, but observable JS behavior must match QuickJS.
- Build from the bottom up. Do not implement frontend, VM execution, CLI, or test262 runner before the lower layers they depend on are stable.
- Use structured Zig types for internal interfaces. Avoid long-lived `[*c]T`, raw pointer plus length APIs, and public `anyopaque` payload exposure.
- Prefer focused subsystem tests at each layer. Do not defer all validation to full smoke or test262 runs.
- Do not restore the old AST interpreter, deleted VM namespace, VM-only tests, or legacy facade aliases.
- The plan is source-aligned, not directory-name-driven. Zig files may be smaller and safer than the C source, but every semantic owner must have an explicit QuickJS source owner and a validation gate.
- Temporary incomplete behavior is allowed only inside an unfinished phase and must be visible in `status.zig`. A phase cannot be marked complete while public execution paths still return not-implemented placeholders for that phase.
- Long-running progress must be recorded in `docs/quickjs-redesign/TRACKING.md` and in the active phase subdocument. Do not rely on chat history as the only project memory.

## Documentation Set

This root document is the architecture contract. Detailed execution state lives in the redesign documentation set:

| Document | Purpose |
|---|---|
| `docs/quickjs-redesign/README.md` | Index, document ownership, and update rules for the redesign docs. |
| `docs/quickjs-redesign/TRACKING.md` | Current phase board, validation log, decision log, risk log, and handoff notes. |
| `docs/quickjs-redesign/ERRORS_AND_LEARNINGS.md` | Durable failure records, root causes, fix evidence, and reusable lessons. |
| `docs/quickjs-redesign/errors/README.md` | Storage rules for long-form per-error records. |
| `docs/quickjs-redesign/phases/01-bootstrap-source-baseline.md` | Phase 1 bootstrap, build wiring, source baseline, and status table plan. |
| `docs/quickjs-redesign/phases/02-core-runtime-foundations.md` | Phase 2 value/runtime/context/refcount/atom/string/class/shape foundations. |
| `docs/quickjs-redesign/phases/03-object-property-semantics.md` | Phase 3 ordinary object, descriptors, prototypes, property operations, and array core. |
| `docs/quickjs-redesign/phases/04-opcode-bytecode-metadata.md` | Phase 4 opcode table, bytecode ownership, function/module/debug metadata. |
| `docs/quickjs-redesign/phases/05-frontend-bytecode-emitter.md` | Phase 5 lexer/parser and direct parse-to-bytecode emitter. |
| `docs/quickjs-redesign/phases/06-bytecode-execution.md` | Phase 6 VM execution, frames, calls, exceptions, eval, modules, promises, jobs. |
| `docs/quickjs-redesign/phases/07-builtins-support-libraries.md` | Phase 7 builtins and regexp/unicode/bignum/dtoa support libraries. |
| `docs/quickjs-redesign/phases/08-cli-tooling-validation.md` | Phase 8 `zjs`, smoke, compare, and test262 tooling. |
| `docs/quickjs-redesign/matrices/core-runtime-invariants.md` | Phase 2 runtime invariant coverage matrix. |
| `docs/quickjs-redesign/matrices/object-property-matrix.md` | Phase 3 object/property behavior matrix. |
| `docs/quickjs-redesign/matrices/frontend-coverage-matrix.md` | Phase 5 syntax/frontend/emitter coverage matrix. |
| `docs/quickjs-redesign/matrices/opcode-execution-matrix.md` | Phase 4/6 opcode metadata and execution coverage matrix. |
| `docs/quickjs-redesign/matrices/builtins-support-matrix.md` | Phase 7 builtin and support library coverage matrix. |
| `docs/quickjs-redesign/matrices/test262-runner-parity.md` | Phase 8 test262 runner parity matrix. |
| `docs/quickjs-redesign/templates/error-record.md` | Template for detailed failure and learning records. |

Tracking rules:

- At the start of implementation work, update the active phase in `TRACKING.md`.
- Every merged or meaningful work slice must update the active phase checklist and add validation evidence.
- Every architecture decision that changes ownership, dependency direction, scope, or QuickJS source mapping must be recorded in the decision log.
- Every known failing validation command must be recorded with exact command, exit status, and whether it is expected for the current phase.
- Every completed work slice must update the relevant matrix row before the phase status is advanced.
- Every reusable failure must create or update an entry in `ERRORS_AND_LEARNINGS.md`.
- A fix is not complete until its error record links the reproduction, root cause, regression test, matrix rows, and validation evidence.
- A phase can move to `completed` only when its phase subdocument exit checklist and this root document's `Phase Exit Criteria` are both satisfied.

## Target Architecture

- `src/engine/root.zig`: canonical public module entrypoint. It re-exports the new QuickJS core API and must not expose deleted runtime namespaces.
- `src/engine/source.zig` and `src/engine/status.zig`: source baseline and port coverage metadata.
- `src/engine/core`: value, runtime, context, GC/refcount, atom, string, class, shape, object, descriptors, prototypes, property operations, and array core behavior.
- `src/engine/frontend`: lexer and parser following QuickJS parse structure. This layer feeds bytecode compilation directly and must not recreate the old interpreter AST model.
- `src/engine/bytecode`: opcode metadata, function bytecode, constants, closure variables, scopes, bytecode emitter output, and bytecode serialization helpers if needed.
- `src/engine/exec`: bytecode VM, stack frames, call/construct, references, property ops, exceptions/finally, iterators, `super`, private fields, eval, modules, promises, and job queue.
- `src/engine/builtins`: ECMAScript builtin objects and constructors.
- `src/engine/libs`: regexp, unicode, bignum, and dtoa ports.
- `src/cli`: `zjs` CLI and test262 CLI entrypoints after the engine path exists.
- `src/tools`: Zig smoke runner and Zig test262 runner. The top-level `tools/compare/` JavaScript tooling remains in place and should only be updated to invoke the rebuilt `zjs`.

## Project Directory Layout

Target tree:

```text
src/
  engine/
    root.zig
    source.zig
    status.zig
    core/
      root.zig
      value.zig
      list.zig
      gc.zig
      atom.zig
      string.zig
      class.zig
      shape.zig
      object.zig
      property.zig
      descriptor.zig
      array.zig
      function.zig
      module.zig
      runtime.zig
      context.zig
      exception.zig
      memory.zig
    frontend/
      root.zig
      token.zig
      lexer.zig
      parser.zig
      regexp_literal.zig
      source_pos.zig
    bytecode/
      root.zig
      opcode.zig
      format.zig
      function.zig
      constant.zig
      scope.zig
      module.zig
      debug.zig
      emitter.zig
    exec/
      root.zig
      vm.zig
      frame.zig
      stack.zig
      call.zig
      construct.zig
      property_ops.zig
      exceptions.zig
      iterator.zig
      eval.zig
      module.zig
      promise.zig
      jobs.zig
    builtins/
      root.zig
      object.zig
      function.zig
      array.zig
      string.zig
      number.zig
      boolean.zig
      symbol.zig
      bigint.zig
      math.zig
      date.zig
      json.zig
      regexp.zig
      error.zig
      promise.zig
      map.zig
      set.zig
      weakmap.zig
      weakset.zig
      array_buffer.zig
      typed_array.zig
      data_view.zig
      reflect.zig
      proxy.zig
      iterator.zig
      atomics.zig
    libs/
      root.zig
      regexp.zig
      regexp_opcode.zig
      unicode.zig
      unicode_tables.zig
      bignum.zig
      dtoa.zig
  cli/
    qjs.zig
    run_test262.zig
  tools/
    smoke_runner.zig
    test262_runner.zig
  tests/
    all.zig
    quickjs_port.zig
    core/
      all.zig
    frontend/
      all.zig
    bytecode/
      all.zig
    exec/
      all.zig
    builtins/
      all.zig
    tools/
      all.zig
```

Repository assets that stay outside `src/`:

- `quickjs/`: upstream semantic reference and local comparison oracle.
- `tests/zig-smoke/`: smoke JS scripts and golden outputs.
- `tools/compare/`: JavaScript comparison tooling. Do not move this into `src/tools`.

## File Responsibilities

- `src/engine/root.zig` exposes only the public engine API and re-exports stable namespaces and public types such as `Engine`, `Runtime`, `Context`, `Value`, `Opcode`, and `FunctionBytecode`. It should be small and contain no implementation logic.
- `source.zig` records the QuickJS commit, included reference files, and excluded components.
- `status.zig` is a compile-time subsystem coverage table used by tests and reviews. It must not contain runtime logic.
- Each subdirectory has a `root.zig` that re-exports only stable module-level APIs. Internal helpers stay in their implementation files.
- `core/memory.zig` centralizes runtime allocator accounting and allocation helpers. Other modules receive allocators or runtime/context references explicitly.
- `core/exception.zig` owns context exception-state helpers. It does not format CLI output.
- `frontend/parser.zig` should not expose a general-purpose AST interpreter. Its output is compiler-facing parse structures or direct bytecode compilation state.
- `bytecode/emitter.zig` is the only layer that turns frontend/compiler state into `FunctionBytecode`.
- `bytecode/module.zig` owns compiled module metadata. `core/module.zig` owns runtime module records and lifecycle state. `exec/module.zig` owns linking and evaluation.
- `core/function.zig` owns function-object payloads and native/bytecode callable records. `bytecode/function.zig` owns compiled bytecode storage. `exec/call.zig` owns invocation semantics.
- `exec/vm.zig` owns the dispatch loop; large semantic helpers belong in sibling files such as `property_ops.zig`, `iterator.zig`, `module.zig`, `promise.zig`, and `jobs.zig`.
- `exec/exceptions.zig` owns execution-time throw/catch/finally behavior. `core/exception.zig` owns only context exception-slot storage and value transfer helpers.
- `exec/eval.zig` owns direct and indirect eval execution paths after parser and bytecode support exist.
- Builtin files register their domain intrinsics and implement domain operations, but object semantics must flow through `core/object.zig` and `exec/property_ops.zig`.
- `libs/*` ports low-level QuickJS support libraries and must not depend on builtins or VM execution.
- `src/cli/*` contains command-line parsing and process I/O only. Engine semantics stay in `src/engine`.
- `src/tools/test262_runner.zig` owns reusable test262 runner behavior; `src/cli/run_test262.zig` owns only CLI argument parsing and process exit behavior.

## QuickJS Source Mapping

The Zig layout intentionally avoids an extra `quickjs/` layer under `src/engine`. The repository name and module already define the project context; the source mapping below keeps the correspondence to QuickJS explicit without adding redundant nesting.

| QuickJS source | Zig destination | Responsibility |
|---|---|---|
| `quickjs/quickjs.h` | `src/engine/core/value.zig`, `core/object.zig`, `core/class.zig`, `core/descriptor.zig`, `root.zig` | Public constants, value tags, property flags, class IDs, and public API shape |
| `quickjs/quickjs.c` runtime/context sections | `src/engine/core/runtime.zig`, `core/context.zig`, `core/memory.zig`, `core/exception.zig` | Runtime allocation, context state, exceptions, allocator accounting, stack limits |
| `quickjs/quickjs.c` atoms/strings/classes/shapes/objects | `src/engine/core/atom.zig`, `core/string.zig`, `core/class.zig`, `core/shape.zig`, `core/object.zig`, `core/property.zig`, `core/array.zig` | Core object model and property semantics |
| `quickjs/quickjs.c` function and module records | `src/engine/core/function.zig`, `core/module.zig`, `bytecode/function.zig`, `bytecode/module.zig`, `exec/call.zig`, `exec/module.zig` | Function object payloads, compiled functions, module records, and module evaluation |
| `quickjs/quickjs.c` parser/compiler sections | `src/engine/frontend/*`, `src/engine/bytecode/emitter.zig`, `bytecode/function.zig`, `bytecode/scope.zig`, `bytecode/debug.zig` | Parse-to-bytecode frontend, scope handling, and source/debug metadata |
| `quickjs/quickjs.c` VM/op handlers | `src/engine/exec/*` | Bytecode execution, calls, exceptions, eval, modules, jobs, promises |
| `quickjs/quickjs.c` intrinsic registration and builtin functions | `src/engine/builtins/*` | Builtin object domains and intrinsic setup |
| `quickjs/quickjs-opcode.h` | `src/engine/bytecode/opcode.zig`, `bytecode/format.zig` | Opcode order, format metadata, stack effects |
| `quickjs/quickjs-atom.h` | `src/engine/core/atom.zig` | Predefined atom ordering and atom names |
| `quickjs/cutils.h` | `src/engine/core/memory.zig`, `core/list.zig`, `libs/*` where needed | Utility behavior that must be rewritten as Zig helpers rather than copied as C-style macros |
| `quickjs/list.h` | `src/engine/core/list.zig` | Intrusive list primitives |
| `quickjs/libregexp.c`, `quickjs/libregexp-opcode.h` | `src/engine/libs/regexp.zig`, `libs/regexp_opcode.zig`, `builtins/regexp.zig` | RegExp engine and JS RegExp integration |
| `quickjs/libunicode.c`, `quickjs/libunicode-table.h` | `src/engine/libs/unicode.zig`, `libs/unicode_tables.zig` | Unicode tables and helpers |
| `quickjs/libbf.c`, `quickjs/libbf.h` | `src/engine/libs/bignum.zig`, `builtins/bigint.zig` | BigInt arithmetic support |
| `quickjs/dtoa.c` | `src/engine/libs/dtoa.zig` | Number parsing/formatting support |
| `quickjs/qjs.c` | `src/cli/qjs.zig` | CLI behavior, adapted to the Zig public API |
| `quickjs/run-test262.c`, `quickjs/test262.conf` | `src/tools/test262_runner.zig`, `src/cli/run_test262.zig` | test262 config, selection, harness loading, known errors, and runner CLI |

## Code Structure Rules

- Dependency direction is one-way: `core` -> `libs` where needed, `frontend` -> `core`, `bytecode` -> `core`, `exec` -> `core` and `bytecode`, `builtins` -> `core`, `exec`, and `libs`, CLI/tools -> public engine API.
- Avoid module cycles. If two domains need shared behavior, move the shared behavior down to the lowest valid layer.
- Public functions that allocate or return owned data must document allocator source, owner, release API, and error cleanup behavior.
- Internal APIs should use slices and typed structs. Do not keep C-style pointer plus length APIs past the boundary where data enters Zig code.
- `anyopaque`, `extern struct`, and `callconv(.c)` belong only in explicitly documented boundary helpers. Core engine internals use Zig structs/enums/unions.
- Root files should re-export; they should not become dumping grounds for implementation.
- Tests should mirror subsystem ownership. A behavior owned by `core/object.zig` belongs in core tests even if a builtin also exercises it.
- QuickJS reference comments should point to source functions or files, not stale line numbers unless the test also locks the relevant constant or layout.
- Every implementation file that ports C behavior should name the QuickJS source function or data table it corresponds to in a short top-level source map comment.
- Avoid placeholder APIs that look final. If a function is intentionally incomplete during a phase, name the status explicitly in `status.zig` and cover the expected failure in that phase's tests.

## Port Status Contract

`src/engine/status.zig` tracks subsystem coverage with these states:

- `not_started`: directory or API may exist, but no semantic claim is made.
- `in_progress`: implementation exists but may contain guarded incomplete paths.
- `validated`: subsystem has source mapping, focused Zig tests, allocator/leak checks where relevant, and representative smoke or compare coverage once the CLI exists.
- `out_of_scope`: intentionally excluded by this plan, with a reason.

Rules:

- `validated` is allowed only when no public path in that subsystem returns a not-implemented error for in-scope QuickJS behavior.
- `out_of_scope` is allowed only for `qjsc`, `quickjs-libc`, std/os modules, full C ABI, and other exclusions listed in `Out Of Scope`.
- Phase tests must fail if an in-scope subsystem is marked `validated` without a source mapping entry.
- Reviews should read `status.zig` first to see which gaps are real phase gaps and which are accidental regressions.

## Public API

- `Engine`
  - `init(allocator, options) !Engine`
  - `deinit() void`
  - `eval(source, filename, mode) !Value`
  - `runJobs() !void`
  - `takeException() Value`
- `EvalMode`
  - `script`
  - `module`
  - `global`
- `Runtime` and `Context`
  - Own atom table, class table, GC/refcount state, shape cache, job queue, exception state, stack limit, interrupt state, random state, and module state.
- `Value`
  - Represents QuickJS tag/value semantics behind typed accessors.
  - Reference payloads remain encapsulated; public APIs do not expose raw `anyopaque`.
- `Bytecode`, `FunctionBytecode`, and `Opcode`
  - Opcode order and metadata must align with `quickjs/quickjs-opcode.h`.
  - Zig structs/enums may differ from C layout unless a test explicitly requires layout parity.

Ownership and error rules:

- `Engine.eval` borrows `source` and `filename` for the call duration.
- The `Value` returned by `Engine.eval` is caller-owned under QuickJS refcount semantics and must be released through the matching context/runtime API.
- `Engine.takeException` transfers the current exception value to the caller, clears the context exception slot, and returns `Value.undefined` if no exception is pending.
- Zig errors represent infrastructure failures: OOM, stack overflow, internal invariant failure, and host I/O.
- JavaScript exceptions are represented through context exception state and exception values. Public calls may return a Zig error only to signal that JS execution ended with an exception that the caller should retrieve.
- During an unfinished phase, temporary incomplete behavior may return an internal not-implemented error only if `status.zig` marks the subsystem `in_progress`. The final public engine must not expose not-implemented behavior for in-scope QuickJS core semantics.

## Module Design

Core runtime modules:

- `value`: QuickJS tags, primitive constructors, predicates, conversion helpers, duplication/free hooks, and refcount dispatch.
- `list`: intrusive list primitives used by runtime, GC, job queues, and module lists.
- `gc`: GC object headers, refcount headers, cycle removal scaffolding, mark/sweep hooks, and zero-ref lists.
- `atom`: predefined atoms, dynamic atoms, atom hash table, integer atoms, symbol/private atom kind handling, and atom lifetime.
- `string`: 8-bit/16-bit strings, ropes if needed, string allocation, string comparison, and atom string backing.
- `class`: class IDs, class definitions, finalizers, exotic methods, and class prototype slots.
- `shape`: shape hash, property shape entries, hash transitions, prototype-linked shape behavior.
- `object`: object allocation, property storage, descriptors, prototypes, own property names, extensibility, seal/freeze, array fast path, typed array backing hooks, and exotic dispatch entrypoints.
- `function`: function object records, native callable records, bytecode callable records, bound function records, constructor flags, home object links, and callable lifetime.
- `module`: runtime module records, import/export entries, namespace object backing state, module status, and lifecycle lists.
- `runtime` and `context`: runtime allocation, context allocation, intrinsic bootstrap state, exception state, stack limits, job queues, module registry, interrupt hooks, random state, and allocator accounting.

Frontend and bytecode modules:

- `lexer`: tokenization aligned with QuickJS, including numeric/string/template literals, regexp lexing hooks, private names, keywords, and module context.
- `parser`: QuickJS parse structure for script, module, function, class, destructuring, async/generator, import/export, and eval-specific parsing.
- `bytecode/scope`: scope resolution, variable bindings, closure capture metadata, eval-specific binding metadata, and module binding metadata.
- `bytecode/emitter`: bytecode emission, constant pool management, class bytecode, destructuring emission, short-circuit control flow, and opcode fixups.
- `bytecode/function`: function bytecode ownership, parameter metadata, local variables, closure variables, bytecode buffers, and GC integration hooks.
- `bytecode/module`: compiled module records, requested modules, import/export metadata, and module function bytecode.
- `bytecode/debug`: source location tables and debug/source metadata needed for errors and stack traces.

Execution modules:

- `vm`: opcode dispatch loop, stack values, frames, call/construct paths, returns, jumps, arithmetic, comparisons, and conversions.
- `property_ops`: get/set/delete/define/super/private-field operations shared by VM and builtins.
- `exceptions`: throw, catch, finally, stack traces, error object integration, and context exception state.
- `eval`: direct eval, indirect eval, global eval, strict-mode interactions, and caller-scope capture rules.
- `jobs`: promise jobs, host jobs, job queue scheduling, `runJobs`, and unhandled rejection hooks.
- `modules`: module linking/evaluation, namespace objects, import/export bindings, cyclic dependencies, and top-level await support if present in the QuickJS baseline.

Builtins and libraries:

- Implement builtin domains as separate modules under `builtins` with narrow registration functions.
- Port `libregexp.c`, `libunicode.c`, `libbf.c`, and `dtoa.c` into `libs` with Zig ownership and error handling.
- Builtins must use the same ordinary/exotic object and property paths as VM execution. Do not implement builtin-only object shortcuts that bypass core semantics.

## Implementation Phases

### Phase 1: Bootstrap And Source Baseline

- Recreate the source tree exactly as defined in `Project Directory Layout`, starting with `src/engine/root.zig`, `src/engine/source.zig`, `src/engine/status.zig`, and empty subsystem `root.zig` files.
- Replace stale `build.zig` wiring with only roots that exist.
- Add a QuickJS source baseline module recording commit, included files, excluded components, source mappings, and subsystem status.
- Add `status.zig` coverage states and tests that prevent accidental `validated` claims without source mappings.
- Add `src/tests/quickjs_port.zig`.
- Add `zig build test-quickjs-port --summary all`.
- Initial tests assert the QuickJS commit, source registry, and out-of-scope components.

### Phase 2: Core Runtime Foundations

- Port `core/value.zig`, `core/list.zig`, `core/gc.zig`, `core/atom.zig`, `core/string.zig`, `core/class.zig`, `core/shape.zig`, `core/function.zig`, `core/module.zig`, `core/runtime.zig`, `core/context.zig`, `core/exception.zig`, and `core/memory.zig`.
- Require leak-free init/deinit tests with `std.testing.allocator`.
- Lock QuickJS constants, tag values, atom order, class IDs, and key layout assumptions with tests.

### Phase 3: Object And Property Semantics

- Port ordinary object allocation, prototypes, property descriptors, flags, property lookup, property definition, set/delete/has semantics, own property enumeration, extensibility, seal, freeze, and array length/index behavior across `core/object.zig`, `core/property.zig`, `core/descriptor.zig`, and `core/array.zig`.
- Add tests for descriptor flags, prototype lookup, non-extensible objects, sparse arrays, array length truncation, property order, accessor descriptors, and cycle-safe prototype handling.

### Phase 4: Opcode And Bytecode Metadata

- Port opcode enum, formats, stack effects, names, and metadata from `quickjs/quickjs-opcode.h` into `bytecode/opcode.zig` and `bytecode/format.zig`.
- Define `FunctionBytecode`, constant pools, closure variable metadata, scope metadata, module bytecode structures, and debug/source tables in `bytecode/function.zig`, `bytecode/constant.zig`, `bytecode/scope.zig`, `bytecode/module.zig`, and `bytecode/debug.zig`.
- Add tests for representative numeric opcode values, formats, stack effects, function bytecode ownership, module metadata ownership, and source-position tables.

### Phase 5: Frontend And Bytecode Emitter

- Port lexer/parser following QuickJS `quickjs.c` into `frontend/token.zig`, `frontend/lexer.zig`, `frontend/parser.zig`, `frontend/regexp_literal.zig`, and `frontend/source_pos.zig`.
- Compile directly to bytecode; do not introduce a standalone AST interpreter.
- Cover script/module/eval, scopes, closures, functions, classes, destructuring, spread/rest/default, async/generator syntax, import/export, private names, and regexp literals.
- Add bytecode emission in `bytecode/emitter.zig`; add parser and bytecode fixtures, including class accessor/method cases, destructuring cases, eval cases, and module import/export cases.

### Phase 6: Bytecode Execution

- Implement VM stack, frames, opcode dispatch, call/construct, closure execution, references, property ops, exception/finally, iterators, `super`, private fields, eval, modules, promises, and jobs in the `exec` files defined by the directory layout.
- Route execution-time errors through `exec/exceptions.zig` and context exception state; do not encode JavaScript exceptions as ordinary Zig control flow beyond the public API boundary.
- Add tests for arithmetic, control flow, closures, classes, exceptions, eval, module basics, promise job ordering, iterator behavior, and stack-limit handling.

### Phase 7: Builtins And Support Libraries

- Port support libraries first where builtins depend on them: regexp, unicode, bignum, and dtoa under `src/engine/libs`.
- Port Object, Function, Array, String, Number, Boolean, Symbol, BigInt, Math, Date, JSON, RegExp, Error, Promise, Map, Set, WeakMap, WeakSet, ArrayBuffer, TypedArray, DataView, Reflect, Proxy, Iterator, and Atomics.
- Add targeted tests for each builtin domain and representative smoke/test262 behavior before broad sweeps.

### Phase 8: CLI And Tooling

- Rebuild `zjs -e "<script>"` and `zjs <file.js>`.
- Rebuild smoke runner against `tests/zig-smoke/manifest.txt`.
- Keep top-level `tools/compare/` and update its `zjs` invocation only if needed.
- Rebuild `run-test262` with behavior aligned to `quickjs/run-test262.c` and `quickjs/test262.conf`, including config parsing, excludes, known-error files, direct file/dir selection, harness loading, metadata parsing, and worker execution.

## Phase Exit Criteria

Each phase is complete only when all relevant criteria below are true:

| Phase | Required evidence |
|---|---|
| 1 | Source tree exists, stale build roots are removed, `test-quickjs-port` passes, and `status.zig` marks only bootstrap metadata as validated. |
| 2 | Runtime/context init-deinit is leak-free, QuickJS value/atom/class constants are locked by tests, and no old VM imports exist. |
| 3 | Ordinary object and array property semantics pass focused tests for descriptors, prototypes, extensibility, deletion, enumeration, and array length. |
| 4 | Opcode order and bytecode metadata match QuickJS tables, bytecode allocations are owned and freed deterministically, and module/debug metadata tests pass. |
| 5 | Parser and emitter cover script/module/eval/class/function/destructuring/import-export fixtures without introducing an interpreter AST execution path. |
| 6 | VM executes representative bytecode programs through public `Engine.eval`, handles JS exceptions through context exception state, and drains jobs through `runJobs`. |
| 7 | Builtins use shared object/property paths, support libraries have focused tests, and smoke/compare coverage exists for each completed domain. |
| 8 | `zjs`, `smoke`, compare, and `run-test262` use the rebuilt engine and no command depends on deleted engine paths. |

## Validation Strategy

Bootstrap gate:

```bash
zig fmt .
zig build test-quickjs-port --summary all
```

CLI and smoke gate:

```bash
zig build qjs --summary all
zig build smoke --summary all
```

Compare gate:

```bash
QJS=/Users/aneryu/zjs/quickjs/build/qjs \
QJS_ZIG=/Users/aneryu/zjs/zig-out/bin/zjs \
bun tools/compare/run_compare.js --functional-only
```

Runner and aggregate gate:

```bash
zig build run-test262 --summary all
zig build test --summary all
```

Final test262 gate:

```bash
./zig-out/bin/run-test262 -c quickjs/test262.conf -m -t 1 quickjs/test262/test
```

Rules:

- A gate is required only after its source root and build step exist.
- Every ported subsystem must have focused Zig tests before being used by higher layers.
- Do not report interrupted or partial sweeps as final validation.
- New, changed, fixed, or interrupted validation results must be linked to `ERRORS_AND_LEARNINGS.md`.

## Deleted Legacy Logic

- Do not restore `src/engine/vm/`.
- Do not restore the deleted AST interpreter or VM-only tests.
- Do not recreate legacy facade aliases.
- Do not use stale `build.zig` paths as implementation targets.
- Do not debug historical leaks or compatibility failures from deleted code.

## Out Of Scope

- `qjsc`
- `quickjs-libc`
- QuickJS std/os modules
- Full QuickJS C ABI compatibility
- The deleted Zig VM/interpreter architecture

## Assumptions

- `SPEX.md` is mandatory for implementation style.
- Local `quickjs/test262.conf` is the future test262 baseline.
- Local `quickjs/build/qjs` is the comparison oracle.
- The implementation can be disruptive and does not need to preserve the previous Zig engine design.
- Complete implementation means complete QuickJS core engine behavior within the selected scope, not a quick MVP.
