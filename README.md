# zjs

[![CI](https://github.com/aneryu/zjs/actions/workflows/ci.yml/badge.svg)](https://github.com/aneryu/zjs/actions/workflows/ci.yml)

**zjs is a Zig rewrite of [QuickJS](https://bellard.org/quickjs/).** QuickJS is
the semantic and implementation reference: zjs follows its JavaScript behavior
and core mechanisms while exposing a Zig-native embedding API with explicit
runtime, context, value, and ownership lifetimes.

The project targets embeddable JavaScript execution in Zig. It is not a
Node.js, Deno, browser, hostile-code sandbox, or drop-in `libquickjs` C API
replacement.

## Performance Compared With QuickJS

The public comparison uses the 15-benchmark JavaScript Zoo suite. Scores are
throughput; the ratio is `zjs score / QuickJS score`, so values at or above
`1.0` indicate that zjs recorded the same or higher score in that benchmark.

| Benchmark | QuickJS | zjs | zjs / QuickJS |
| --- | ---: | ---: | ---: |
| earley-boyer | 4,435.0 | 3,856.5 | 0.870 |
| pdfjs | 7,186.0 | 6,581.5 | 0.916 |
| box2d | 7,227.0 | 6,867.0 | 0.950 |
| typescript | 21,929.5 | 21,188.5 | 0.966 |
| splay | 6,714.5 | 6,825.0 | 1.016 |
| deltablue | 1,405.0 | 1,436.5 | 1.022 |
| richards | 1,613.5 | 1,686.5 | 1.045 |
| gbemu | 12,536.0 | 13,355.5 | 1.065 |
| mandreel | 1,983.0 | 2,128.0 | 1.073 |
| crypto | 1,843.0 | 1,987.0 | 1.078 |
| raytrace | 3,313.5 | 3,593.5 | 1.085 |
| code-load | 31,953.5 | 35,050.0 | 1.097 |
| zlib | 3,948.5 | 4,347.5 | 1.101 |
| navier-stokes | 4,174.0 | 4,598.0 | 1.102 |
| regexp | 794.0 | 921.5 | 1.161 |
| **Throughput geomean** |  |  | **1.0335** |

The suite also reports two latency sub-scores outside the 15-row throughput
geomean:

| Latency sub-score | QuickJS | zjs | zjs / QuickJS |
| --- | ---: | ---: | ---: |
| SplayLatency | 15,215.5 | 15,148.5 | 0.996 |
| MandreelLatency | 13,223.5 | 15,826.0 | 1.197 |

The comparison used zjs commit `0280e278`, Bellard QuickJS commit `04be246`,
and 8 samples per benchmark. Of the 15 primary scores, 11 have a ratio at or
above `1.0`.

Measurements were collected on an ARM Cortex-X925 Linux host with pinned CPU
clusters. The QuickJS reference used its upstream release build. Protocol,
machine details, current results, and reproduction notes are recorded in
[docs/perf/zoo-status.md](docs/perf/zoo-status.md) and [STATUS.md](STATUS.md).

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
- [CONTRIBUTING.md](CONTRIBUTING.md): contribution workflow.
- [GUIDE.md](GUIDE.md): engineering rules and validation commands.

QuickJS remains the reference when an in-scope JavaScript behavior differs.
Intentional divergences must be explicit, reviewed, and covered by tests.
