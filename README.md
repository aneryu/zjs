# zjs

A Zig-native JavaScript engine, source-aligned with QuickJS.
Embed JS in Zig with an explicit runtime, context, and value API.

## Highlights

**Zig-first embedding.** Create a runtime, eval a script, free the result:

```zig
const zjs = @import("zjs");

const rt = try zjs.JSRuntime.create(allocator);
defer rt.destroy();
const ctx = try zjs.JSContext.create(rt);
defer ctx.destroy();
const result = try ctx.eval("let x = 1 + 2; x;", .{});
defer result.free(rt);
```

See [docs/embedding-cookbook.md](docs/embedding-cookbook.md) for host functions,
handles, and modules.

**test262.** The checked 2026-08-05 gate recorded **44,581 passes**, **0 known
failures**, and 5,194 feature skips (Intl, Temporal, ShadowRealm, and other
groups listed in `test262.conf`), out of 49,775 prepared cases. Details:
[COMPATIBILITY.md](COMPATIBILITY.md).

**Performance.** **1.01× Bellard QuickJS** on our 15-benchmark zoo (geomean,
2026-08-17). That is geomean parity, not 15/15. Per-benchmark numbers:
[docs/perf/zoo-status.md](docs/perf/zoo-status.md).

Authoritative rolling status (gates, latest reports, reproduction commands):
[STATUS.md](STATUS.md).

## Getting Started

Requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
zig build zjs-dev --seed 0 --summary all
zig-out/bin/zjs-dev -e "console.log(1 + 2)"
```

Engine contributors: [CONTRIBUTING.md](CONTRIBUTING.md). Validation commands:
[GUIDE.md](GUIDE.md) Part B.6.

## CLI

```sh
zig-out/bin/zjs -e "console.log(1 + 2)"
zig-out/bin/zjs path/to/file.js
zig-out/bin/zjs --print-config-signature
```

Missing or invalid arguments print usage and exit non-zero.

The ReleaseFast CLI is `zig-out/bin/zjs`; the Debug inner-loop binary is
`zig-out/bin/zjs-dev`. Production default:

```
zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md): how to change the engine.
- [GUIDE.md](GUIDE.md): Zig engineering rules and the validation command ladder.
- [docs/README.md](docs/README.md): documentation map.
- [docs/architecture.md](docs/architecture.md): current source tour.
- [COMPATIBILITY.md](COMPATIBILITY.md) / [LIMITATIONS.md](LIMITATIONS.md):
  validation and product boundaries.
- [docs/public-api-contract.md](docs/public-api-contract.md): public Zig API.

## Compatibility And Ownership

Compatibility is the local `test262.conf` profile plus focused Zig and smoke
tests. zjs is not a Node.js, Deno, or `libquickjs` C API replacement.

The runtime is single-threaded. Host-owned `JSValue`s must stay in a
`JSValue.Scope` / local handle for the duration of a call, or in a
`JSValue.Persistent` handle across callbacks and ticks. See
[docs/architecture.md](docs/architecture.md).

## Repository Layout

- `src/root.zig`: public embedder entry.
- `src/core/`: values, runtime, objects, GC.
- `src/parser.zig`: lexer, parser, TypeScript erasure.
- `src/compiler_v2/`: the compiler (labels, builder, resolve, layout).
- `src/bytecode.zig`: bytecode carrier and packing.
- `src/exec/`: VM, builtins, calls, modules, promises.
- `src/runtime/`: event loop and native plugins.
- `src/binding/`: public adapters and FFI descriptors.

The source tour is [docs/architecture.md](docs/architecture.md).
