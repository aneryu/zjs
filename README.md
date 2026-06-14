# zjs

`zjs` is a source-aligned Zig rewrite of QuickJS. QuickJS remains the semantic
reference, while this repository keeps the active validation profile in the
root `test262` checkout and fixture snapshots under `tests/fixtures/`.

This is a Production v1 Candidate. It has reached production-grade maturity for
its targeted validation profile and Zig-native embedded runtime use cases, but
it is not a general-purpose drop-in replacement for Node.js, Deno, or the
QuickJS C API outside its specified API surface.

## Status

The active local test262 gate is expected to pass with no unexpected errors and
no checked-in known failures. The current `test262_errors.txt` boundary is
empty.

```sh
zig build test262-gate --summary all
```

The gate uses `test262.conf` and writes the latest bucket/failure reports under
`reports/test262-latest/`. Skips and excludes in that config are part of the
current compatibility boundary.

`zig build engine-production-gate --summary all` is the engine semantic and
architecture gate. A Production v1 release requires this gate to pass from a
clean checkout; the full release checklist also requires ReleaseSafe testing,
diff hygiene, and performance evidence when runtime-sensitive code changed.

## Requirements

- Zig 0.16.0
- A POSIX-like shell for helper scripts
- Bun, only for the optional multi-case performance self-baseline workflow

## Build

```sh
zig build zjs --summary all
zig build run-test262 --summary all
```

The main CLI is installed as `zig-out/bin/zjs`; the test262 runner is installed
as `zig-out/bin/run-test262`.

Useful build steps:

```sh
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build smoke --summary all
zig build test-oom --summary all # OOM 注入门禁（corpus×注入+恢复金丝雀），阶段收口档位执行 / OOM injection gate (corpus x injection + recovery canaries), phase-close tier
zig build gc-stress --summary all
zig build perf-self-check --summary all
zig build engine-production-gate --summary all
```

`-Dzjs_enable_ic=false` disables shape-keyed inline caches for diagnosis.

## CLI

```sh
zig-out/bin/zjs -e "console.log(1 + 2)"
zig-out/bin/zjs path/to/file.js
zig-out/bin/zjs --leak-check -e "let x = { ok: true }"
zig-out/bin/zjs --perf-json path/to/file.js 2> perf.json
```

Missing or invalid arguments print usage and exit non-zero.

## Compatibility

Read [COMPATIBILITY.md](COMPATIBILITY.md) for the current validation boundary
and [LIMITATIONS.md](LIMITATIONS.md) for runtime limitations.

Read [docs/embedding-cookbook.md](docs/embedding-cookbook.md) for public
Zig-native embedding examples: runtime/context lifecycle, host functions,
handle scopes, persistent values, byte stores, limits, interrupts, and module
evaluation.

Read [docs/public-api-contract.md](docs/public-api-contract.md) for the current
public Zig API contract, [docs/api-boundary.md](docs/api-boundary.md) for the
core/runtime boundary, and
[docs/runtime-plugin-abi.md](docs/runtime-plugin-abi.md) for the dynamic runtime
plugin ABI.

The full direct test262 invocation is:

```sh
./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test 0 100000
```

For parser, runner, execution, or semantic changes, run a focused test262 slice
before the full gate.

## Garbage Collection And Host Ownership

zjs uses non-atomic reference counting for immediate lifetime management and a
cycle-removal pass for `Object` and `FunctionBytecode` graphs. The runtime is
single-threaded; JS values must not be shared across threads.

Every host-owned `JSValue` must either remain inside an active
`JSValue.Scope` / local handle for the duration of a call, or be stored in a
`JSValue.Persistent` handle when it crosses callbacks, ticks, or host object
state. Persistent handles duplicate the value, register nested symbol roots,
and must be destroyed before `JSRuntime.destroy`.

GC may run only at audited safe points where VM temporaries are rooted.
Low-level allocation marks GC as pending but does not directly collect.

FinalizationRegistry cleanup jobs are best-effort but not silently dropped on
allocation failure. If cleanup job enqueueing fails, the registry cell remains
pending and is retried by a later GC pass.

## Performance

The repeatable performance gate is a ZJS self-baseline regression check, which
does not require a C QuickJS binary:

```sh
zig build perf-self-check --summary all
```

See [docs/perf/README.md](docs/perf/README.md) for performance workflow details.
A smaller single-script diagnostic benchmark is also available:

```sh
zig build perf-benchmark --summary all
```

## Repository Layout

- `src/root.zig`: public engine entrypoint.
- `src/core/`: values, runtime/context, atoms, strings, objects,
  properties, arrays, GC, and core ownership.
- `src/frontend/`: lexer, parser, source positions, and frontend
  parsing.
- `src/bytecode/`: bytecode, constants, scopes, module metadata,
  inline-cache slots, and pipeline passes.
- `src/exec/`: bytecode execution, calls, eval, exceptions, modules,
  promises, VM opcode shards, and job queue.
- `src/runtime/`: host/runtime policy helpers for event loop, cleanup,
  module file graphs, plugins, and buffer operations.
- `src/builtins/`: ECMAScript built-in objects and constructors.
- `src/libs/`: regexp, unicode, bignum, dtoa, and support libraries.
- `src/cli/`: `zjs` and test262 CLI entrypoints.
- `src/tests/`: Zig unit and integration test entrypoints.
- `test262/`: local test262 checkout used by the gate.
- `tests/fixtures/`: vendored fixture snapshots used by opcode and runner
  tests.

See [GUIDE.md](GUIDE.md) for engineering rules and validation workflow details.
