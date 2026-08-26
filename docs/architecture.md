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
| `host_function.zig` | native-function ABI (`NativeCProto`, records) |

Lifetime model: non-atomic reference counting for immediate free; cycle
removal for `Object` and `FunctionBytecode` graphs. There is no nursery,
moving, or concurrent collector. VM operand stacks and locals are carved from
a `VmStackArena` and released with the frame; they are not registered as
per-frame GC roots. Host values that outlive a call must use public handles,
not a raw `JSValue`.

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
- `plugin.zig`: dynamic native plugins (deprecated 2026-08-25 — frozen,
  correctness fixes only; removed at FNABI M3, see
  `docs/runtime-plugin-abi.md`)

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

## Stack Bytecode VM Status

Last updated: 2026-08-25. Merged from the former
`docs/stack_bytecode_vm_design.md` on 2026-08-25; external references cite
this chapter's § numbers. It records the current status of the stack
bytecode VM and answers whether it should migrate to register / accumulator
bytecode. The field-level QuickJS comparison lived in the frozen 2026-07-27
subsystem difference baseline
(`docs/qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md`, removed
2026-08-25; recover from git history).

### 1. Current Answer

zjs is already a bytecode interpreter:

- `parser.zig` parses and emits QuickJS-aligned stack bytecode;
- `bytecode.zig` performs resolve, stack-size, pc2line, and finalize;
- `zjs_vm.zig` / `tailcall_dispatch.zig` execute opcodes;
- `vm_*.zig` and `vm_property_*` own the concrete opcode families.

There is no evidence supporting a rewrite to a register/accumulator VM
(reaffirmed by [engine-evolution-plan.md](engine-evolution-plan.md) §17).
Forward-looking evolution — feedback slots, baseline JIT, dispatch-skeleton
alternatives — is owned by
[engine-evolution-plan.md](engine-evolution-plan.md); this chapter stays a
status record.

### 2. Current Carriers

Compile-time carriers:

- `FunctionDef`: variables, scopes, child functions, source/debug, and
  emitter state;
- lowered `Bytecode`: the pipeline's mutable code/metadata.

Post-publish production execution carrier:

- canonical GC-managed `FunctionBytecode`;
- 96-byte QuickJS-aligned core header;
- packed constant/var/closure/code data;
- optional 32-byte debug tail;
- zjs-only 8-byte call-facts/script-or-module tail.

Scripts, eval, nested functions, and module roots all execute canonical
`FunctionBytecode`. There is no separate `CodeBlock` and no property IC
slots.

### 3. Frame And Dispatch

Main entry points:

- `src/exec/frame.zig`: `Frame`, `FrameSlab`, and frame-owned windows;
- `src/exec/stack.zig`: operand stack;
- `src/core/runtime.zig`: per-runtime `VmStackArena`;
- `src/exec/inline_calls.zig`: same-loop `Machine` frame push/pop;
- `src/exec/tailcall_dispatch.zig`: threaded/tail-called opcode handlers;
- `src/exec/call_runtime.zig`: call/eval/generator/Atomics shared runtime
  glue.

The tail-call handler split is a current code-generation constraint, not a
file-organization preference: each opcode handler ends in a tail dispatch,
the hot arm completes inside the handler, and cold work that might emit an
ordinary call is outlined into `vm_*.zig` first. Folding those handlers
back into one large switch would grow the shared stack frame again; do not
merge them without a frozen binary, disassembly, and multi-build PMU
evidence.

Ordinary synchronous bytecode frames are preferentially carved from the
runtime arena as `[args | locals | operand | var-ref metadata]`.
Generator/async frames must survive suspend, so they own transferable
resident storage instead of borrowing the arena.

Live values in the VM stay alive via refcount-on-push and deterministic
frame teardown. `ValueRootFrame` is for host/builtin boundaries, not
generic root registration of every VM frame. Its `activate` / `deactivate`
interface owns the test-only LIFO link and restoration protocol; callers
provide only the root storage and keep its stack address valid for that scope.

### 4. Property Access

There is currently no inline cache:

- `src/core/ic.zig` does not exist;
- `FunctionBytecode` has no site/slot table;
- `zjs_enable_ic` does not exist.

`src/exec/property_direct.zig` (renamed from the historical
`property_ic.zig` on 2026-08-19) holds non-cached direct
shape/property/global fast paths. Every access checks the current
object/shape/property state; the retained `dataPropertyValueForFastPath`
adapter always misses, and the always-false `cachedSet*` zombie was
deleted.

### 5. Tail Calls

The VM executes `tail_call` / `tail_call_method` and replaces an inline
frame with `Machine.tailCallReuse`.

Since 0.2.0-dev, strict-mode plain-call tails (`return f(...)`, including
conditional-expression arms and unconditional-jump joins) are folded to
`tail_call` at compile time — ES2015 proper tail calls, a documented
divergence from the pinned QuickJS, which grows a frame for every call.
Sloppy code, method tails, `try`-protected calls, and eval-tails keep
QuickJS-aligned frame growth. `test262.conf` still skips
`tail-call-optimization` because method-position tails are out of scope.
Scope and overflow behavior: [LIMITATIONS.md](../LIMITATIONS.md).

### 6. zjs-Specific Call Machinery

To shrink the Zig frame/dispatch fixed cost, `FunctionBytecode` and
`Machine` currently also contain:

- simple-inline eligibility;
- empty/exact/padded/capture leaf classification;
- forwarded `Function.prototype.call` leaf;
- narrow leaf frame constructors and return epilogues;
- simple-field constructor body bypass and runtime memo.

These are not a property IC, but several of them also have no pinned
QuickJS counterpart. Until 2026-08-24 they were audit subjects under the
QuickJS-faithful policy, whose rule 1 was "a matching QuickJS mechanism" —
that rule is retired clause R1 of the
[charter transition](qjs_alignment_charter_transition.md) (its original
trigger was the simple-field constructor bypass listed above). Under the
succession regime (2026-08-25 rewrite of this section), the list stays an
accurate inventory, and keep-or-delete decisions are reviewed with:

1. the generality principle (K2): no shape-special-casing; generic
   mechanisms go through the PERF-MECHANISM-LEDGER audit;
2. observable / exception / OOM / interrupt / realm boundaries;
3. controlled instructions / allocations / time A/B;
4. focused + checkpoint / production gates.

They still must not keep expanding on microbenchmark results alone.

### 7. Current Capabilities

Landed:

- QuickJS-aligned stack opcode execution;
- stack-depth validation;
- pc2line / source-location diagnostics;
- canonical `FunctionBytecode`;
- same-loop bytecode call frames;
- explicit generator/async resident-frame ownership;
- direct and indirect eval entry;
- catch/finally and pending JS exception propagation;
- four zjs-only explicit-resource-management opcodes.

Opcode profiling (after the D0 fix):

- A profiling build (`zig build zjs-profile` /
  `-Dzjs_enable_opcode_profile=true`) wraps the whole hot dispatch table
  at comptime: every table dispatch is counted and delta-timed through
  `vm_profile.noteDispatch` (a scope cannot span an `always_tail` chain;
  the previous opcode's interval is closed by the next dispatch, and the
  last one by `flushPendingDispatch` before dump). `cold_table` and the
  property tail tables are not wrapped — they redispatch the same pc, and
  wrapping them would double-count.
- The default build's table is entry-for-entry equal to the unwrapped
  table; `--profile-opcodes` fail-closes on a non-profiling binary (exit
  2); `--perf-json` emits `opcode_profile_enabled` explicitly. The
  `perf-runtime-profiles` gate requires a minimum count (not only an
  upper bound); an all-zero profile cannot pass.

Not implemented:

- register / accumulator bytecode;
- baseline JIT;
- call or property inline cache (still true on `main`; no longer
  forbidden — Phase 0.5 feedback slots are approved and unlocked,
  [engine-evolution-plan.md](engine-evolution-plan.md) §3.4);
- JIT GC stack maps;
- moving nursery;
- concurrent collector;
- a public standalone `CodeBlock` / bytecode serialization API.

### 8. Near-Term Work

Keep stack bytecode. Prioritize:

- decompose call admission, frame publication, return, and RC fixed tax
  (the pinned qjs serves as the K3 correctness oracle and regression
  sentinel for this work, not as the performance target — see the
  [charter transition](qjs_alignment_charter_transition.md) §4);
- audit zjs-only leaf / body-bypass machinery;
- converge the direct-eval binding mechanism;
- strengthen generator / async / module exception and OOM ownership
  tests;
- improve source-location coverage;
- keep shrinking `call_runtime.zig` by ownership domain, without
  forcibly splitting shared state to hit a line-count target.

Re-evaluate the bytecode architecture only when the semantic gates are
stable, hot spots in call / property / array / string have been
converged with qjs mechanisms, and PMU evidence shows operand traffic /
dispatch as the main bottleneck.
