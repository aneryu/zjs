# Architecture Notes

`fun` follows Bun's broad repository shape without copying Bun source code. The
goal is a genuinely usable Bun-like runtime with the same major product
boundaries: startup, CLI commands, module resolution/loading, runtime
execution, host APIs, and developer tooling.

Unlike Bun, `fun` uses [`zjs`](https://github.com/aneryu/zjs) as its language
engine. `zjs` owns JavaScript and TypeScript parsing/lowering, bytecode,
execution, ECMAScript built-ins, and future type warm-up metadata. `fun` owns
the product shell and host runtime around that engine.

## Bun v1.3.14 Reference Points

- Bun presents itself as an all-in-one JavaScript and TypeScript toolkit that
  ships as one executable and includes runtime, package manager, test runner,
  and bundler workflows.
- In Bun, `src/main.zig` handles process-level startup and then calls into the
  CLI layer.
- `src/bun.zig` is Bun's importable root module facade. It re-exports common
  runtime, platform, allocator, CLI, and system namespaces instead of making
  callers import deep files directly.
- The source tree is split by major runtime/tooling domains: `cli`,
  `js_parser`, `bundler`, `resolver`, `runtime`, `jsc`, `install`,
  `test_runner`, `shell`, and platform/system support.

Reference URLs:

- https://github.com/oven-sh/bun/tree/bun-v1.3.14
- https://github.com/oven-sh/bun/blob/bun-v1.3.14/README.md
- https://github.com/oven-sh/bun/blob/bun-v1.3.14/src/main.zig
- https://github.com/oven-sh/bun/blob/bun-v1.3.14/src/bun.zig
- https://github.com/oven-sh/bun/tree/bun-v1.3.14/src
- https://github.com/oven-sh/bun/tree/bun-v1.3.14/src/cli

## fun Layout (Historical Flat Scaffold)

> **2026-05 Update**: The project has adopted the Git-subtree layered architecture
> defined in [docs/fun_zjs_subtree_architecture.md](fun_zjs_subtree_architecture.md).
> The table below describes the **M0/M1 flat scaffold** that was used until the
> migration. All new code must follow the structure in the subtree document
> (`third_party/zjs/`, `src/js/`, `src/runtime/vm/`, `src/tooling/*`, `src/primitives/`,
> `src/diagnostics/`, `src/platform/`). The old flat directories under `src/` have
> been migrated.

| Bun area | fun area (pre-2026-05) | Purpose |
| --- | --- | --- |
| `src/main.zig` | `src/main.zig` | Thin process entry point and I/O setup. |
| `src/bun.zig` | `src/root.zig` | Public module facade re-exporting runtime layers. |
| `src/cli` | `src/cli` | Command parsing, help text, and command dispatch. |
| `src/bun_core`, `src/sys`, `src/platform` | `src/core` | Shared enums, file-kind detection, environment/platform primitives. |
| `src/js_parser` | `src/js_parser` | Temporary adapter/helper boundary; real JS/TS parsing belongs in `zjs`. |
| `src/js_printer`, transpiler paths | `src/transpiler` | Adapter for `zjs` frontend transforms if needed; not an independent TS compiler. |
| `src/resolver` | `src/resolver` | Import specifier classification and resolution. |
| runtime module loader paths | `src/loader` | File loading, module records, and loader cache later. |
| `src/runtime`, `src/jsc` | `src/runtime` | `zjs` embedding adapter and host API bridge (now split across `src/js` + `src/runtime/vm`). |
| `src/bundler` | `src/bundler` | Module graph and bundling pipeline later (now under `src/tooling/bundler`). |
| `src/install` | `src/package_manager` | Package manager commands later (now under `src/tooling/package_manager`). |
| `src/test_runner` | `src/test_runner` | Test runner commands later (now under `src/tooling/test_runner`). |
| `src/cli/repl*` | `src/repl` | REPL loop for the no-argument `fun` entry (now under `src/tooling`). |

## Current Boundary

> **Note (post-2026-05 migration)**: The structural skeleton now follows
> `fun_zjs_subtree_architecture.md`. The flat directories have been replaced by
> the layered tree (`primitives/`, `diagnostics/`, `js/`, `runtime/{vm,scheduler,modules,api}/`,
> `tooling/{cli,resolver,transpiler,...}/`, `platform/`). Most directories are
> still explicit stubs or minimal scaffolds. Real execution, host APIs, and
> zjs wiring are still ahead (M3+). The status matrix in `docs/roadmap.md` is
> the single source of truth for implemented vs. planned behavior.

The current code is still a scaffold. The accepted runtime MVP command surface
is deliberately small:

- `fun` enters a REPL.
- `fun <file> [...args]` executes a JavaScript ESM entry and passes remaining
  arguments through to `process.argv`.
- `--help`, `-h`, `--version`, and `-v` remain special flags.

`run`, `eval`, and `repl` are not MVP subcommands. They are ordinary file-path
arguments, so `fun repl` attempts to execute a file named `repl`.

Do not add compatibility claims until there are focused local tests proving the
behavior. The first real implementation tranche should be the accepted runtime
MVP in `docs/runtime-mvp.md`: direct file execution, a REPL, local ESM loading,
structured diagnostics, and a small Node-shaped host API subset.

TypeScript should not be pre-transpiled away in `fun`. `fun` should preserve
source kind and configuration so `zjs` can use TypeScript syntax for erasure,
lowering, and future type warm-up metadata.
