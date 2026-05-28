# fun

`fun` is a Bun-like JavaScript and TypeScript runtime written in Zig. It uses
Bun's all-in-one developer experience as the product reference and uses
[`zjs`](https://github.com/aneryu/zjs) as the language engine.

The repository is currently at the scaffold stage. The CLI entry points and
host-side ownership boundaries exist, but module loading, `zjs` embedding, host
APIs, package management, bundling, and execution are intentionally not
implemented yet.

Current planning status:

- The architecture contract is settled: `fun` owns the product shell and host
  runtime, while `zjs` owns JavaScript and TypeScript language semantics.
- The active design work is the `zjs` embedding boundary needed before
  file execution and the REPL become real execution paths.
- The accepted runtime MVP command contract is `fun` for REPL and
  `fun <file> [...args]` for file execution. `fun eval`, `fun run`, and
  explicit `fun repl` are not MVP commands.
- Package manager, bundler, and test runner work remain deferred until basic
  execution and module loading are validated.

## Current Commands

```sh
zig build
zig build run -- --help
zig build test
zig build docs-check   # documentation discipline gate
```

The generated binary is installed at `zig-out/bin/fun`.

## Initial Runtime Shape

- `src/main.zig` owns the thin process entry point and I/O setup.
- `src/root.zig` exposes the importable runtime facade.
- `src/cli` owns command parsing and command-facing diagnostics.
- `src/core` owns shared runtime primitives such as source file classification.
- `src/resolver` and `src/loader` own host-side module resolution and loading.
- `src/runtime` is intended to become the `zjs` embedding adapter and host API
  bridge.
- `src/js_parser` and `src/transpiler` are temporary adapter/helper boundaries;
  JavaScript and TypeScript parsing/lowering should live in `zjs`.
- `src/repl` is the MVP interactive shell boundary; it is still a placeholder
  in the scaffold.
- `src/bundler`, `src/package_manager`, and `src/test_runner` are Bun-inspired
  tooling boundaries that remain deferred placeholders.
- `build.zig` builds both the executable and importable `fun` module.

See `docs/README.md` for the full documentation index, recommended reading
order, and maintenance rules. Key documents:
- `docs/architecture.md` — Bun v1.3.14 reference mapping and current layout
- `docs/roadmap.md` — milestones, tradeoffs, and the live "Current Implementation Status" matrix
- `docs/zjs-integration.md` — the `fun` ↔ `zjs` embedding contract (design baseline)
- `docs/runtime-mvp.md` — the narrow accepted MVP scope and acceptance criteria

## Direction

The runtime should grow in small, validated layers:

1. CLI command model and diagnostics.
2. `zjs` embedding API design and dependency mode.
3. REPL and direct file command contract: `fun` and `fun <file> [...args]`.
4. Structured diagnostics, local-file loading, and relative ESM resolution.
5. Execution through `zjs` for REPL input and simple `.js` files.
6. TypeScript execution through the `zjs` frontend, with future type warm-up.
7. Compatibility test suites such as focused fixtures, selected Bun/Node tests,
   and test262 through `zjs`.
