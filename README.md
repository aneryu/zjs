# zjs

`zjs` is a source-aligned Zig rewrite of QuickJS. QuickJS remains the semantic
reference, while this repository keeps the active validation profile in the
root `test262` checkout and fixture snapshots under `tests/fixtures/`.

This is a Production v1 Candidate. It has reached production-grade maturity for its targeted validation profile and embedded runtime use cases, but it is not a general-purpose drop-in replacement for Node.js or Deno outside its specified API surface.

## Status

The active local test262 gate is expected to pass with an empty known-error
file:

```sh
zig build test262-gate --summary all
```

The gate uses `test262.conf` and writes the latest bucket/failure
reports under `reports/test262-latest/`. Skips and excludes in that config are
part of the current compatibility boundary.

## Requirements

- Zig 0.16.0
- A POSIX-like shell for helper scripts

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
zig build test-oom --summary all
zig build test-oom-exhaustive --summary all
zig build gc-stress --summary all
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

The engine-only Production v1 roadmap and contract are tracked in
[docs/production-grade-plan.md](docs/production-grade-plan.md),
[docs/engine-api-v1.md](docs/engine-api-v1.md),
[docs/compatibility-v1.md](docs/compatibility-v1.md), and
[docs/release-checklist.md](docs/release-checklist.md).

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

Every host-owned `Value` must either remain inside an active `ValueRootFrame`
for the duration of a call or be stored in a `PersistentValue` handle. A
`PersistentValue` duplicates the value, registers nested symbol roots, and must
be destroyed before `Runtime.destroy`.

GC may run only at audited safe points where VM temporaries are rooted.
Low-level allocation marks GC as pending but does not directly collect.

FinalizationRegistry cleanup jobs are best-effort but not silently dropped on
allocation failure. If cleanup job enqueueing fails, the registry cell remains
pending and is retried by a later GC pass.

## Performance

The checked-in performance reports under `reports/perf/` are historical
artifacts from the previous local QuickJS comparison toolchain.

- 72 compatible cases, 1 unsupported case, 0 skipped cases.
- Geometric mean `zjs/qjs` ratio: `1.0158`, roughly parity with the local C
  QuickJS baseline for this external-process benchmark.
- 24 cases currently favor `zjs`, 41 favor C QuickJS, and 7 are near ties.

Wins in that report include `global_read_loop`, `regexp_test_cached`,
`array_map_callback`, and `map_string_keys`. Slower areas in that report
include dense array write/read, integer sums, monomorphic/prototype property
reads, URI decoding, and some function-call loops.

See [docs/perf/README.md](docs/perf/README.md) for historical performance
context. The current repeatable diagnostic benchmark entry is:

```sh
zig build perf-benchmark --summary all
```

## Repository Layout

- `src/engine/root.zig`: public engine entrypoint.
- `src/engine/core/`: values, runtime/context, atoms, strings, objects,
  properties, arrays, GC, and core ownership.
- `src/engine/frontend/`: lexer, parser, source positions, and frontend
  parsing.
- `src/engine/bytecode/`: bytecode, constants, scopes, module metadata,
  inline-cache slots, and pipeline passes.
- `src/engine/exec/`: bytecode execution, calls, eval, exceptions, modules,
  promises, and job queue.
- `src/engine/builtins/`: ECMAScript built-in objects and constructors.
- `src/engine/libs/`: regexp, unicode, bignum, dtoa, and support libraries.
- `src/cli/`: `zjs` and test262 CLI entrypoints.
- `src/tools/`: smoke runner, test262 runner, and shared validation tooling.
- `src/tests/`: Zig unit and integration test entrypoints.
- `tests/zig-smoke/`: JavaScript smoke fixtures and golden output.
- `test262/`: local test262 checkout used by the gate.
- `tests/fixtures/`: vendored fixture snapshots used by opcode and runner
  tests.

See [GUIDE.md](GUIDE.md) for engineering rules and validation workflow details.
