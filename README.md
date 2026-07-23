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
zig build test262-gate --seed 0 --summary all
```

The gate uses `test262.conf` and writes the latest bucket/failure reports under
`reports/test262-latest/`. Skips and excludes in that config are part of the
current compatibility boundary.

For day-to-day optimization and repair work, prefer the fast tier:

```sh
mise run quick-check
```

`quick-check` builds the Debug `zjs-dev` and runs the CLI smoke fixtures. Add a
focused Zig test or test262 slice for the changed semantic area. The checkpoint
gate adds the unified Debug suite, architecture checks, and `test262-smoke`;
neither iteration tier replaces the full release gates.

`zig build engine-production-gate --seed 0 --summary all` is the engine
semantic and architecture gate. A Production v1 release requires this gate to
pass from a clean checkout; the full release checklist also requires
ReleaseSafe testing, diff hygiene, and performance evidence when
runtime-sensitive code changed.

## Requirements

- Zig 0.16.0
- mise, for the stable-seed quick/checkpoint/watch task wrappers
- A POSIX-like shell for helper scripts
- Bun, only for the optional multi-case performance self-baseline workflow

## Build

```sh
zig build zjs --seed 0 --summary all
zig build zjs-dev --seed 0 --summary all
zig build run-test262 --seed 0 --summary all
zig build run-test262-dev --seed 0 --summary all
```

The ReleaseFast CLI is installed as `zig-out/bin/zjs`, its Debug inner-loop
counterpart as `zig-out/bin/zjs-dev`, and the test262 runners as
`zig-out/bin/run-test262` (ReleaseFast) and `zig-out/bin/run-test262-dev`
(Debug smoke/checkpoint runner).

Useful build steps:

```sh
mise run quick-check
mise run checkpoint-check
zig build test --seed 0 --summary all
zig build test -Doptimize=ReleaseSafe --seed 0 --summary all
zig build smoke-dev --seed 0 --summary all
zig build smoke --seed 0 --summary all
zig build test262-smoke --seed 0 --summary all
zig build test-oom --seed 0 --summary all # OOM 注入门禁（corpus×注入+恢复金丝雀），阶段收口档位执行 / OOM injection gate (corpus x injection + recovery canaries), phase-close tier
zig build test -Dzjs_force_gc=true --seed 0 --summary all
zig build perf-self-check --seed 0 --summary all
zig build engine-production-gate --seed 0 --summary all
```

Focused subsystem steps are available as `test-core`, `test-parser`,
`test-bytecode`, `test-exec`, `test-builtins`, `test-runtime`, and
`test-runner`. For an edit/rebuild loop, `mise run quick-watch` keeps the Debug
quick-check compiler alive with Zig incremental compilation enabled.

The one-shot commands above pin CLI `--seed 0` so Zig 0.16 build-runner
traversal stays reproducible and cacheable. Zig test runners also use seed `0`
by default; pass `-Dzjs_test_seed=<u32>` for an explicit randomized validation
run.

`-Dzjs_enable_ic=false` disables shape-keyed inline caches for diagnosis.

## CLI

```sh
zig-out/bin/zjs -e "console.log(1 + 2)"
zig-out/bin/zjs path/to/file.js
zig-out/bin/zjs --leak-check -e "let x = { ok: true }"
zig-out/bin/zjs --perf-json path/to/file.js 2> perf.json
```

Missing or invalid arguments print usage and exit non-zero.

## Documentation

Read [docs/README.md](docs/README.md) for the active documentation map.
Completed roadmaps, snapshot ledgers, and one-off audits are intentionally not
kept in the active tree; recover them from git history when needed.

Key authorities:

- [GUIDE.md](GUIDE.md): engineering rules and validation workflow.
- [COMPATIBILITY.md](COMPATIBILITY.md): current validation boundary.
- [LIMITATIONS.md](LIMITATIONS.md): runtime and product-scope limitations.
- [docs/architecture.md](docs/architecture.md): current architecture snapshot.
- [docs/public-api-contract.md](docs/public-api-contract.md): public Zig API
  contract.
- [docs/embedding-cookbook.md](docs/embedding-cookbook.md): Zig-native
  embedding examples.

## Compatibility

Read [COMPATIBILITY.md](COMPATIBILITY.md) for the current validation boundary
and [LIMITATIONS.md](LIMITATIONS.md) for runtime limitations.

The full direct test262 invocation is:

```sh
./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test 0 100000
```

For parser, runner, execution, or semantic changes, run
`zig build test262-smoke --seed 0 --summary all` plus a focused test262 slice
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

Each FinalizationRegistry owns its construction RealmRef. Cleanup work enters
the runtime's unified ECMAScript FIFO with that Realm; invoking the callback
may then switch to the callback function's own Realm. Cleanup is never silently
dropped on allocation failure: cells remain pending in stable order and a later
GC pass retries them without duplicating already-published jobs.

## Performance

The repeatable performance gate is a ZJS self-baseline regression check, which
does not require a C QuickJS binary:

```sh
zig build perf-self-check --seed 0 --summary all
```

See [docs/perf/README.md](docs/perf/README.md) for performance workflow details.
A smaller single-script diagnostic benchmark is also available:

```sh
zig build perf-benchmark --seed 0 --summary all
```

## Repository Layout

- `src/root.zig`: public engine entrypoint.
- `src/core/`: values, runtime/context, atoms, strings, objects,
  properties, arrays, GC, and core ownership.
- `src/parser.zig`: lexer, parser, source positions, and compile entry.
- `src/bytecode.zig`: bytecode, constants, scopes, module metadata,
  inline-cache slots, and pipeline passes.
- `src/exec/`: bytecode execution, standard-global bootstrap and built-in
  behavior, calls, eval, exceptions, modules, promises, VM opcode shards, and
  job queue.
- `src/runtime/`: host/runtime policy helpers for event loop, cleanup,
  module file graphs, plugins, and buffer operations.
- `src/libs/`: regexp, unicode, bignum, dtoa, and support libraries.
- `src/cli/`: `zjs` and test262 CLI entrypoints.
- `src/tests/`: Zig unit and integration test entrypoints.
- `test262/`: local test262 checkout used by the gate.
- `tests/fixtures/`: vendored fixture snapshots used by opcode and runner
  tests.

See [GUIDE.md](GUIDE.md) for engineering rules and validation workflow details.
