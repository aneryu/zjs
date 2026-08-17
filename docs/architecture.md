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
compile   →  src/parser.zig  →  src/compiler_v2/  →  src/bytecode.zig
execute   →  src/exec/  (VM, builtins, modules, promises)
host      →  src/runtime/  (event loop, plugins)
```

`src/core/` must not depend on CLI policy, test262 glue, plugins, or the event
loop. `zig build architecture-check` enforces that boundary and the public
symbol snapshot in `reports/api/public-symbols.txt`.

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
| `host_function.zig` | native-function ABI (`NativeCProto`, records) |

Lifetime model: non-atomic reference counting for immediate free; cycle
removal for `Object` and `FunctionBytecode` graphs. There is no nursery,
moving, or concurrent collector. VM operand stacks and locals are carved from
a `VmStackArena` and released with the frame; they are not registered as
per-frame GC roots. Host values that outlive a call must use public handles,
not a raw `JSValue`.

`JSValue` has two representations. 64-bit default is 16-byte payload + signed
tag; `-Dzjs_nan_boxing=true` selects 8-byte encoding. `test-altrepr` guards
the opposite mode. That mode is a semantic/ownership guard, not a bit-level
QuickJS ABI.

`object.zig` is the large object-model file. For property behavior start at
`shape.zig` and `property.zig`, then the call site in `src/exec/`.

## Parser — `src/parser.zig`

`parser.compile` is the compile wrapper. The lexer, TypeScript erasure, and
QuickJS-aligned parser/emitter live in this one file because QuickJS’s
`ParseState` is also a single compilation unit. TypeScript support is syntax
erasure, not a typechecker.

## Compiler — `src/compiler_v2/`

This is the only compiler. Temporary bytecode uses `LabelId` / `LabelSlot` /
`RelocEntry` until final layout. `resolve_variables` and `resolve_labels`
are separate stages. Production layout is `-Dzjs_v2_layout=short`; `plain`
is an A/B diagnostic.

| File | Role |
| --- | --- |
| `labels.zig` | jump identity |
| `builder.zig` | temporary stream and binds |
| `resolve_variables.zig` | liveness / variable resolve |
| `resolve_labels.zig` | final layout and jump threading |
| `cfg.zig` | Debug/ReleaseSafe CFG oracles |

Normative contract: [compiler_v2_contract.md](compiler_v2_contract.md).

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

The default compiler emits ordinary `call + return`. `test262.conf` skips
`tail-call-optimization`. Per-opcode profiling build flags still exist; the
dispatcher does not populate counts. Do not treat `--profile-opcodes` as a
working profiler.

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
- `src/cli/`: `zjs` and `run-test262`
- `src/tests/`: Zig unit and integration entrypoints
- `tests/zig-smoke/`, `tests/fixtures/`: CLI smoke and snapshots

Layering rules: [api-boundary.md](api-boundary.md).
