# Current source tour

This is a map of the tree as it exists now. QuickJS remains the semantic
reference. Validation commands live in [GUIDE.md](../GUIDE.md) Part B.6; this
page does not repeat them.

Start from the layer you are changing. Do not read `parser.zig`, `object.zig`,
or `bytecode.zig` from the first line to the last — those files are large
reference shapes, matching QuickJS’s own monoliths.

## Layers

```
embedder  →  src/root.zig  →  src/binding/  →  src/core/
CLI/tests →  src/internal_root.zig
compile   →  src/parser.zig  →  src/compiler/  →  src/bytecode.zig
execute   →  src/exec/  (VM, builtins, modules, promises)
host      →  src/runtime/  (event loop, plugins)
```

`src/core/` must not depend on CLI policy, test262 glue, plugins, or the event
loop. `tools/architecture/check_deps.js` enforces that boundary. Checkpoint
and the production gate both run it.

Three `src/` companions sit beside those layers:

- `simple_token.zig`: parser token kinds for QuickJS `simple_next_token`
  lookahead; used by `parser.zig` and the CLI.
- `config_signature.zig`: compile-time configuration-signature attestation
  (see [qcp1_switch_decision.md](qcp1_switch_decision.md)).
- `dossier_pad.zig`: layout-lineage padding instrument; `pad=0` emits
  nothing.

## Public entry — `src/root.zig`

Embedders import `zjs`. The stable surface is `JSRuntime`, `JSContext`,
`JSValue`, `zjs.value` handles, `zjs.host`, `zjs.runtime`, and `zjs.ffi`.
Contract: [public-api-contract.md](public-api-contract.md). Examples:
[embedding-cookbook.md](embedding-cookbook.md).

`src/internal_root.zig` aggregates CLI, test262, and in-repo tests. It is not
the public embedding contract.

`src/binding/` adapts core types into that public surface: context helpers,
strings, bytes, property names, host callbacks, native objects, and FFI
descriptors.

## Core — `src/core/`

Values, atoms, strings, objects, shapes, properties, arrays, GC, and
runtime/context storage.

| Enter here | Owns |
| --- | --- |
| `runtime.zig` / `context.zig` | `JSRuntime`, `JSContext`, roots, GC scheduling |
| `value.zig` | `JSValue` representation and refcount entry |
| `object.zig` / `shape.zig` / `property.zig` | objects, shapes, properties |
| `gc.zig` | registry, policy, external-memory accounting |
| `gc_address_registry.zig` | Page-radix address → allocation map for conservative lookup (tests/shadow/STW; production `rc` erases it) |
| `gc_space.zig` | Measured size-class table and publication histogram (tests/shadow/STW; no 64 KiB blocks) |
| `gc_sweep_model.zig` | Logical 64 KiB window sweep state machine and four debt quantities (tests/shadow/STW) |
| `gc_slot.zig` | Stage 2 Slot-under-RC mutation protocol (no atomics) |
| `gc_write_audit.zig` | Shadow runtime write audit of Slot-bypassing heap stores |
| `gc_trace_stw.zig` | Experimental STW mark/sweep over the compatibility heap (`-Dzjs_gc=trace_stw`) |
| `host_function.zig` | native-function ABI (`NativeCProto`, records) |

Lifetime model: non-atomic reference counting for immediate free; cycle
removal for `Object` and `FunctionBytecode` graphs. There is no nursery,
moving, or concurrent collector. VM operand stacks and locals are carved from
a `VmStackArena` and released with the frame; they are not individually linked
as per-frame roots. When tracing roots are live (`value_root_frames_enabled`),
the exec-owned `ActiveInvocationTrace` prefix exposes those semantic live
windows without teaching core the VM layout; default `rc` erases the call at
compile time. The same gated path snapshots `Atomics.waitAsync` waiter
Promises through `trace_atomics_wait_async`. Host values that outlive a call
must use public handles, not a raw `JSValue`.

`JSValue` has a single representation: a 16-byte struct of payload plus a
signed 8-byte tag. The alignment with QuickJS is semantic and ownership-level,
not a bit-level ABI match.

`object.zig` is the large object-model file. For property behavior start at
`shape.zig` and `property.zig`, then the call site in `src/exec/`.

## Parser — `src/parser.zig`

`parser.compile` is the compile wrapper. The lexer, TypeScript erasure, and
QuickJS-aligned parser/emitter live in this one file because QuickJS’s
`ParseState` is also a single compilation unit. TypeScript support is syntax
erasure, not a typechecker. `simple_token.zig` holds the token subset used
by that lookahead path.

## Compiler — `src/compiler/`

This is the only compiler (renamed from `compiler_v2` on 2026-08-19 by owner
ruling). The published configuration-signature string keeps `compiler=v2` —
"v2" is the compiler's attested identity, not the directory name. Temporary
bytecode uses `LabelId` / `LabelSlot` / `RelocEntry` until final layout.
`resolve_variables` and `resolve_labels` are separate stages. Production
layout is `-Dzjs_compiler_layout=short`; `plain` is an A/B diagnostic.

| File | Role |
| --- | --- |
| `labels.zig` | jump identity |
| `builder.zig` | temporary stream and binds |
| `resolve_variables.zig` | liveness / variable resolve |
| `resolve_labels.zig` | final layout and jump threading |
| `cfg.zig` | Debug/ReleaseSafe CFG oracles |

Normative contract: [compiler-contract.md](compiler-contract.md).

## Bytecode carrier — `src/bytecode.zig`

Compile-time `FunctionDef` / `Bytecode` and the GC-managed
`FunctionBytecode` that the VM runs. Opcode order matches QuickJS, plus four
explicit-resource opcodes at the tail. Some pipeline namespaces
(`pipeline_stack_size`, finalize, pc2line) still live in this file; they are
not separate `stack_size.zig` sources.

## Execution — `src/exec/`

Start at `zjs_vm.zig` (dispatcher), then `frame.zig` / `stack.zig` /
`inline_calls.zig`. Opcode families are `vm_*.zig`. Standard globals are
hand-installed in `standard_globals.zig`; native records live beside
`*_ops.zig` and dispatch through `builtin_dispatch.zig`. There is no
`src/builtins/` layer.

File and function naming conventions in `exec/`:

- `vm_X.zig` holds stack-VM opcode handlers and their helpers (they take
  the operand stack / frame); `X_ops.zig` holds value-level runtime and
  builtin implementations (they take runtime + values); `X_builtin_ops.zig`
  holds native-record tables. Import aliases must equal the file name minus
  `.zig` (one documented exception: `internal_builtins.zig` aliases each
  record file by its `NativeBuiltinDomain` name, because that file is the
  domain table).
- A `Vm` function suffix (`binaryVm`, `execVm`, …) marks the stack-VM entry
  variant of a value-level operation of the same name.
- The historical `qjs*` function prefix was removed on 2026-08-19 (owner
  ruling: mirroring quickjs.c is a transitional state, not the project's
  identity — names describe function, not provenance). Alignment evidence
  lives in `// quickjs.c:N` comments and commit messages, never in names.
- Throw helpers: `throw<Kind>Message` is the generic kind-plus-message
  entry; `throw<Reason><Kind>` (e.g. `throwTdzReferenceError`) is a
  scenario-specific helper. Mechanism-level throws (`throwValue`,
  `throwTop`, `throwStackOverflow`) carry no error-kind segment.
- Fast-path names: `*ForFastPath` is an ingredient or precondition check
  **used by** a fast path; `*Fast` / `fast*` is the fast **variant of** the
  operation itself.
- `X_builtin_ops.zig` exists only where `X_ops.zig` also exists (the
  native-record table split out of the value-level runtime file);
  single-file domains keep their records inside `X_ops.zig`, and
  `builtin_glue.zig` holds the deliberate cross-domain leftovers.

| Enter here | Owns |
| --- | --- |
| `zjs_vm.zig` | interpreter loop |
| `call.zig` / `call_runtime.zig` / `construct.zig` | calls and construct |
| `eval_entry.zig` | eval |
| `module.zig` / `module_graph.zig` | modules |
| `promise_ops.zig` | Promise abstract operations |
| `standard_globals.zig` | global bootstrap |

Promise object state is `src/core/promise.zig`. Job-queue primitives are
`src/core/jobs.zig`. There is no `src/exec/eval.zig` and no `src/exec/promise.zig`.

Strict-mode plain-call tails (`return f(...)`) fold to `tail_call` and reuse
the caller frame — ES2015 proper tail calls, a documented divergence from the
pinned QuickJS (see [LIMITATIONS.md](../LIMITATIONS.md)). All other calls emit
ordinary `call + return`; `test262.conf` still skips `tail-call-optimization`
because method-position tails are out of scope. Per-opcode profiling is a
working profiler on the
`zjs-profile` artifact: profiling builds call `noteDispatch` from `cont` /
`next` (`src/exec/vm_profile.zig`), `build.zig` ships `zjs-profile` plus
nine `perf-*-profile` steps with exact opcode pins, and
`src/tests/smoke_test.zig` asserts `--profile-opcodes` output. The default
`zjs` binary still fail-closes `--profile-opcodes`.

## Host runtime — `src/runtime/`

Only host policy that must stay out of core:

- `event_loop.zig`: timers, fd/signal handlers, job draining
- `plugin.zig`: dynamic native plugins

Atomics waiter cleanup is in exec and re-exported from `runtime/root.zig`.
There is no `cleanup.zig`, `modules.zig`, or `buffer.zig` in this directory.
Host functions register through `ExternalHostCall` on the public API
(`zjs.host.*`).

## Libraries, CLI, tests

- `src/libs/`: regexp, unicode, bigint, number formatting
- `src/cli/`: `zjs` and `run-test262`; `run_test262_options.zig` owns the
  latter's arguments, `run_test262_config.zig` owns configuration files and
  feature overrides, `run_test262_names.zig` owns allocated name sets and
  natural ordering, `run_test262_metadata.zig` owns frontmatter parsing,
  `run_test262_known_errors.zig` owns the expected-failure ledger, and
  `run_test262_source.zig` owns harness caching, local source overrides, and
  source assembly. `run_test262_host.zig` owns Test262 globals and the
  `$262.agent` coordinator. `run_test262_reporter.zig` owns synchronized
  stderr, failure buckets, directory summaries, and report files
- `src/tests/`: Zig unit and integration entrypoints
- `tests/fixtures/`: plugin fixtures and test262 overrides. CLI smoke
  coverage lives in `src/tests/smoke_test.zig` (inline scripts, `zig build
  smoke`), not in a fixture tree.

Layering rules: [api-boundary.md](api-boundary.md).
