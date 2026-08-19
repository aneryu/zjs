# zjs — Embeddable JavaScript Engine Written in Zig

[![CI](https://github.com/aneryu/zjs/actions/workflows/ci.yml/badge.svg)](https://github.com/aneryu/zjs/actions/workflows/ci.yml)

**zjs is an embeddable JavaScript engine written in Zig and a rewrite of
[Bellard QuickJS](https://bellard.org/quickjs/).** It runs JavaScript inside Zig
applications through a Zig-native API. QuickJS is the semantic and
implementation reference: zjs follows its JavaScript behavior and core
mechanisms while exposing explicit runtime, context, value, and ownership
lifetimes.

The canonical project is [`aneryu/zjs`](https://github.com/aneryu/zjs). The
project targets trusted, embeddable JavaScript execution in Zig. It is not a
Node.js, Deno, Bun, browser, hostile-code sandbox, or drop-in `libquickjs` C API
replacement.

## zjs At A Glance

| Question | Answer |
| --- | --- |
| What is it? | An embeddable JavaScript engine, library, and CLI |
| What is it written in? | Zig 0.16.0 |
| What defines JavaScript behavior? | Bellard QuickJS is the semantic reference |
| How do Zig applications use it? | Through the `zjs` module's Zig-native embedding API |
| Does it support TypeScript? | Partial syntax erasure; it is not a type checker or full `tsc` replacement |
| What is the compatibility evidence? | The repository's pinned test262 profile and checked results |
| What is the license? | MIT, including the retained QuickJS attribution in [`LICENSE`](LICENSE) |

Use zjs when a Zig application needs an in-process JavaScript interpreter with
explicit ownership and runtime control. Choose another runtime when the
application needs Node.js packages and APIs, browser APIs, a security boundary
for untrusted code, the QuickJS C ABI, or complete TypeScript language support.

## Performance Compared With QuickJS

The public comparison uses **bench-v8** — the V8 benchmark suite version 7
that upstream QuickJS publishes its own scores with. The suite is vendored
in this repository (`tools/perf/bench_v8/`). Scores are the suite's
self-reported numbers (higher is better); the ratio is
`zjs score / QuickJS score`.

| Benchmark | zjs | QuickJS | zjs / QuickJS |
| --- | ---: | ---: | ---: |
| EarleyBoyer | 3,950 | 4,492 | 0.879 |
| Splay | 7,346 | 7,208 | 1.019 |
| DeltaBlue | 1,457 | 1,411 | 1.033 |
| Richards | 1,700 | 1,614 | 1.054 |
| Crypto | 2,346 | 2,198 | 1.068 |
| RayTrace | 3,687 | 3,367 | 1.095 |
| NavierStokes | 4,792 | 4,307 | 1.113 |
| RegExp | 976 | 854 | 1.144 |
| **Composite Score (version 7)** | **2,706** | **2,586** | **1.0464** |

The comparison used zjs commit `da875a7d`, Bellard QuickJS commit `04be246`,
and 8 pinned interleaved samples per engine (medians). Of the 8 benchmarks,
7 have a ratio at or above `1.0`.

Measurements were collected on an ARM Cortex-X925 Linux host with a pinned
CPU. The QuickJS reference used its upstream release build. Protocol,
machine details, current results, and reproduction notes are recorded in
[docs/perf/bench-v8-status.md](docs/perf/bench-v8-status.md) and
[STATUS.md](STATUS.md).

## Compatibility

The checked test262 profile records the current validation boundary:

| Prepared | Passed | Failed | Feature-skipped |
| ---: | ---: | ---: | ---: |
| 49,775 | **44,581** | **0** | 5,194 |

The feature-skipped set includes Intl, Temporal, ShadowRealm, and the other
groups listed in `test262.conf`. These numbers describe the configured profile,
not complete support for every ECMAScript or host feature. See
[COMPATIBILITY.md](COMPATIBILITY.md) for enabled areas and exact exclusions.

## Try The CLI

Requires [Zig 0.16.0](https://ziglang.org/download/).

Prebuilt nightly CLIs for Linux x86_64, macOS ARM64, and Windows x86_64 are
published on the [Nightly release](https://github.com/aneryu/zjs/releases/tag/nightly).
They are development snapshots; verify downloads against the attached
`SHA256SUMS` file.

```sh
git clone https://github.com/aneryu/zjs.git
cd zjs
zig build zjs-dev --summary all
./zig-out/bin/zjs-dev -e "console.log(1 + 2)"
```

The Debug CLI above is the shortest development path. Build the ReleaseFast
CLI with:

```sh
zig build zjs --summary all
./zig-out/bin/zjs -e "console.log(1 + 2)"
./zig-out/bin/zjs path/to/file.js
```

Missing or invalid arguments print usage and exit non-zero.

## Embed JavaScript In Zig

The public module is imported as `zjs`:

```zig
const std = @import("std");
const zjs = @import("zjs");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const result = try ctx.eval("let x = 1 + 2; x;", .{});
    defer result.free(rt);

    std.debug.assert(result.asInt32() == @as(?i32, 3));
}
```

See [docs/embedding-cookbook.md](docs/embedding-cookbook.md) for host
functions, handles, strings and bytes, memory limits, interrupts, modules, and
runtime plugins. The examples are covered by the embedding test target.

## Runtime And Ownership Boundary

The runtime is single-threaded. Host-owned `JSValue`s must remain in a
`JSValue.Scope` / local handle for the duration of a call, or in a
`JSValue.Persistent` handle when they cross callbacks, ticks, or host object
state. Embedders must release owning values with the runtime that created them.

Memory and interrupt limits are reliability controls for trusted embeddings;
they are not a security boundary for untrusted JavaScript. See
[LIMITATIONS.md](LIMITATIONS.md) and
[docs/security-boundary.md](docs/security-boundary.md).

## Vision And Roadmap

zjs aims to remain aligned with QuickJS for JavaScript semantics while making
JavaScript and TypeScript first-class, inspectable components of Zig
applications. Two major areas remain on the roadmap:

1. **Native TypeScript support — partial today.** zjs currently has partial
   TypeScript syntax-erasure support, but it does not yet cover the full
   TypeScript syntax surface. The roadmap is to expand direct parsing and
   execution of `.ts`, `.mts`, `.cts`, and `.tsx` sources without a separate
   transpilation step, with useful source locations and diagnostics. zjs is not
   intended to replace the TypeScript type checker or `tsc`.
2. **Chrome DevTools Protocol support — not implemented.** zjs does not
   currently expose a CDP inspector or debugger. The roadmap begins with
   runtime evaluation, breakpoints, stepping, call stacks, and scope inspection
   for DevTools-compatible clients.

These capabilities build around the QuickJS-aligned engine; they do not change
QuickJS's role as the reference for in-scope JavaScript behavior.

## Documentation

- [docs/embedding-cookbook.md](docs/embedding-cookbook.md): Zig-native embedding examples.
- [COMPATIBILITY.md](COMPATIBILITY.md): test262 validation boundary.
- [LIMITATIONS.md](LIMITATIONS.md): runtime and product boundaries.
- [docs/public-api-contract.md](docs/public-api-contract.md): public Zig API.
- [docs/architecture.md](docs/architecture.md): source and subsystem tour.
- [docs/README.md](docs/README.md): complete documentation map.
- [llms.txt](llms.txt): compact project facts and authoritative source map for
  retrieval tools.
- [CONTRIBUTING.md](CONTRIBUTING.md): contribution workflow.
- [GUIDE.md](GUIDE.md): engineering rules and validation commands.

QuickJS remains the reference when an in-scope JavaScript behavior differs.
Intentional divergences must be explicit, reviewed, and covered by tests.
