# Agent Notes

This project is a Zig implementation of a Bun-like JavaScript and TypeScript
runtime. Keep work scoped to that runtime goal: fast CLI startup, JS/TS
execution, module loading, host APIs, and developer-facing tooling.

`fun` uses `zjs` (`https://github.com/aneryu/zjs`) as the JavaScript and
TypeScript language engine. `fun` is the product shell and host runtime around
that engine.

## Local Commands

- `zig build` / `zig build fun` — builds the `fun` executable (primary target).
- `zig build zjs` — builds the zjs CLI from the `third_party/zjs` subtree (after `git subtree add`).
- `zig build run -- --help` runs the CLI through the build graph.
- `zig build test` (and the finer `test-js`, `test-runtime`, `test-tooling`) run tests.
- `zig fmt build.zig src` formats Zig sources.
- `zig build docs-check` validates module layout + docs references (extended for the subtree tree).

The repository currently targets Zig `0.16.0`. See `docs/fun_zjs_subtree_architecture.md` §16 for the full recommended step matrix.

## Architecture (Subtree + Layered Facade)

`fun` uses `zjs` (https://github.com/aneryu/zjs) as the JavaScript and TypeScript
language engine. `fun` is the product shell and host runtime around that engine.

The authoritative structure is defined in `docs/fun_zjs_subtree_architecture.md`.
Key points (do not deviate without updating that document and this file):

- `src/main.zig` stays thin: argument parsing, process I/O, and command dispatch only.
- `src/root.zig` is the public module facade (Bun `bun.zig` role).
- `third_party/zjs/` is the **complete** zjs repository brought in via `git subtree`
  (full history, no squash in the first import). It is real source, not a read-only
  vendor. You may edit it and `git subtree push` changes back.
- `src/js/` is the **stable facade** that the rest of `fun` imports. It never exposes
  raw `zjs` internal paths to `runtime/*` (except through the narrow `internal.zig`
  for `vm/` only).
- `src/runtime/vm/` is the **唯一深耦合层** (sole deep-coupling layer). Only code
  under `src/runtime/vm/` (and test/bench/js) may directly understand zjs `Engine`,
  `Value`, `Context`, job queue, or host hook details.
- `src/runtime/` (outside vm) owns the event loop, module loader, Web/Node/Fun APIs,
  and scheduler. These layers talk to the engine **only** through `src/js` or the
  `vm/` bridge.
- `src/tooling/` owns CLI, resolver, bundler, package manager, test runner, etc.
  (the old flat `src/{cli,resolver,...}` directories have been migrated here).
- `src/primitives/`, `src/diagnostics/`, and `src/platform/` are the lowest layers
  (std + no fun runtime/tooling dependencies).
- `src/js_parser/` and `src/transpiler/` are now under `src/tooling/transpiler/`
  and remain thin adapters. Real TS/JS work lives in `zjs`.
- Tooling (`bundler`, `package_manager`, `test_runner`, `repl`, watcher, etc.)
  stay explicit placeholders until they have tests and real behavior.

**Dependency direction rules** (binding — see also `fun_zjs_subtree_architecture.md` §4):

```
src/primitives          -> std only
third_party/zjs/src/engine -> zjs internals + std/libc; NEVER fun/*
src/js                  -> third_party/zjs/src/engine + primitives + diagnostics
src/runtime/vm          -> src/js (+ internal.zig for zjs details)
src/runtime/{modules,api,scheduler} -> src/runtime/vm + platform + primitives
src/tooling             -> primitives + diagnostics + platform + runtime (or js facade)
src/tooling/cli         -> runtime + tooling
```

**Forbidden** (enforced by review + import guard):
- Any `third_party/zjs/*` import outside `src/js/`, `src/runtime/vm/`, `tests/js/`,
  `benches/js/`, `src/tooling/cli/zjs.zig`, `src/tooling/js_validation/`.
- `runtime/*` (except vm) or `tooling/*` reaching into raw zjs engine modules.
- `primitives/*` reaching into js/runtime/tooling.

`docs/README.md` is the entry point. Start there.
`docs/fun_zjs_subtree_architecture.md` (especially §3, §4, §7, §9, §17, §19–20) is
now the primary architecture reference.
`docs/roadmap.md` holds the status matrix and must be updated on structural changes.
`docs/zjs-integration.md` remains the embedding API contract (what fun needs from zjs).

Do not claim Bun/Node compatibility until covered by local tests.

## Subtree + Layering Rules (from fun_zjs_subtree_architecture.md)

The following tables are copied verbatim from the authoritative document and are
the review checklist for every PR that touches module boundaries.

### Allowed dependency direction

```
src/primitives
  -> std only

third_party/zjs/src/engine
  -> zjs 自己的内部模块
  -> std / libc where needed
  -> 不依赖 fun runtime
  -> 不依赖 fun tooling

src/js
  -> third_party/zjs/src/engine
  -> primitives
  -> diagnostics

src/runtime/vm
  -> src/js
  -> 必要时通过 src/js/internal.zig 访问 zjs internal
  -> 不允许 runtime 其他目录直接 import zjs internal

src/runtime/modules
src/runtime/api
src/runtime/scheduler
  -> src/runtime/vm
  -> platform
  -> primitives
  -> diagnostics
  -> 不直接 import third_party/zjs

src/tooling
  -> primitives
  -> diagnostics
  -> platform
  -> runtime when needed
  -> js facade when needed

src/tooling/cli
  -> runtime
  -> tooling
```

### Prohibited dependency direction

```
third_party/zjs/* -> src/runtime/*
third_party/zjs/* -> src/tooling/*
third_party/zjs/* -> src/js/*

src/runtime/modules/* -> third_party/zjs/src/engine/*
src/runtime/api/*     -> third_party/zjs/src/engine/*
src/tooling/cli/*     -> third_party/zjs/src/engine/*

src/primitives/* -> src/js/*
src/primitives/* -> src/runtime/*
src/primitives/* -> src/tooling/*
```

Only `src/runtime/vm/` is allowed to know zjs internal details. All other runtime
modules must go through abstractions provided by `vm` (native function registration,
JS value read/write, promise creation, exceptions, globals, etc.).

Add an explicit `//!` comment at the top of every new file under the directories
above stating which layer it belongs to and which document section governs it.

## Testing Expectations

- Add focused Zig tests for every parser, resolver, loader, or runtime behavior
  added.
- Use fixture-style integration tests once file execution starts working.
- For ECMAScript semantics, prefer test262-compatible behavior and keep any
  known deviations documented.
- Run `zig build test`, `zig fmt build.zig src`, and `zig build docs-check` before handing off code changes.
- When adding code under the new layout, also verify that the import guard (section 20 of the subtree architecture doc) would not flag the new file.

## Implementation Style

- Follow Zig stdlib patterns used by Zig `0.16.0`.
- Pass allocators explicitly and make ownership clear at API boundaries.
- Keep diagnostics deterministic and easy to snapshot in tests.
- Avoid hidden global runtime state unless it is deliberately part of the VM or
  module cache design.
