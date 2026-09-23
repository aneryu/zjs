# zjs — JavaScript / TypeScript Engine Written in Zig

[![CI](https://github.com/aneryu/zjs/actions/workflows/ci.yml/badge.svg)](https://github.com/aneryu/zjs/actions/workflows/ci.yml)

**zjs is an embeddable JavaScript / TypeScript engine written in Zig.**
It provides a Zig-native embedding API and a standalone CLI for trusted code.
TypeScript sources run directly through native parsing, type erasure, and
supported syntax lowering; zjs does not perform type checking.

JavaScript semantics follow **ECMA-262**, validated by the repository's
test262 profile. QuickJS is a comparison reference and performance yardstick.
The implementation follows Zig's types, explicit lifetimes, and error handling.

The canonical project is [aneryu/zjs](https://github.com/aneryu/zjs).
It requires **Zig 0.16.0** and is MIT licensed, with retained
[QuickJS attribution](LICENSE).

## Try the CLI

```sh
git clone https://github.com/aneryu/zjs.git
cd zjs
zig build zjs -Doptimize=ReleaseFast --summary all
./zig-out/bin/zjs -e "console.log(1 + 2)"
./zig-out/bin/zjs path/to/file.js
./zig-out/bin/zjs path/to/file.ts
```

Omitting `-Doptimize=ReleaseFast` builds Debug. A file path evaluates as a
module; `-e` evaluates a script, and `-s` forces script mode. Missing or
invalid arguments print usage and exit non-zero.

[Nightly binaries](https://github.com/aneryu/zjs/releases/tag/nightly) are
available for Linux x86_64, macOS ARM64, and Windows x86_64. They are
development snapshots; verify downloads against the attached `SHA256SUMS`.

## Embed in Zig

The public module is imported as `zjs`:

```zig
const std = @import("std");
const zjs = @import("zjs");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const rt = try zjs.Runtime.create(allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const result = try ctx.eval("let x = 1 + 2; x;", .{});

    std.debug.assert(result.as(.int) == @as(?i32, 3));
}
```

The runtime belongs to one thread. Host values must be rooted for their use:
local handles cover a call/scope; persistent handles cover callbacks, ticks,
and host object state. See the [embedding cookbook](docs/embedding-cookbook.md)
for tested examples and the [public API contract](docs/public-api-contract.md)
for ownership rules.

## Supported scope

zjs targets in-process execution in Zig applications. It does not provide
Node.js/Deno packages and APIs, browser APIs, the `libquickjs` C ABI, or a
security boundary for hostile code. Memory limits and cooperative interrupts
are reliability controls for trusted embeddings.

TypeScript support includes `.ts`, `.mts`, and `.cts`, type erasure, and
runtime syntax such as enums and namespaces. Type checking, JSX, decorators,
and CommonJS-style TypeScript imports/exports are outside the current scope.
The [limitations](LIMITATIONS.md) document defines these boundaries and the
current debugger/CDP status.

## Validation and performance

[Compatibility](COMPATIBILITY.md) describes the selected test262 profile and
exclusions. [STATUS.md](STATUS.md) records dated validation results; a passing
profile does not imply support for every ECMAScript or host feature.

Historical QuickJS comparisons are available in Git history; their ratios
are specific to the recorded suite, machine, and binaries. For local
performance investigation, see [GUIDE](GUIDE.md#b8-performance-investigation) and the [verification policy](docs/verification-policy.md).

## Documentation

- [Embedding cookbook](docs/embedding-cookbook.md): host functions, values,
  memory limits, interrupts, and modules.
- [Architecture](docs/architecture.md): source ownership and layer boundaries.
- [Contributing](CONTRIBUTING.md): engineering and validation workflow.
- [Documentation index](docs/README.md): contracts, designs, and planned work.
- [llms.txt](llms.txt): compact retrieval index.
