# Project Plan and Tradeoffs

This document records the confirmed planning direction for `fun`.

`fun` is intended to become a genuinely usable Bun-like JavaScript and
TypeScript runtime. It uses Bun as a product and repository-architecture
reference, but it uses `zjs` as the JavaScript and TypeScript language engine
instead of copying Bun's JavaScriptCore-based runtime design.

## Confirmed Direction

- Product target: a practical Bun-like runtime, not a toy runner.
- Language engine: [`zjs`](https://github.com/aneryu/zjs).
- Current phase: subtree architecture skeleton + layered build graph complete
  (2026-05 migration). Active work is now Phase 2–4 of
  `fun_zjs_subtree_architecture.md` (wiring the `src/js` facade to the real zjs
  Engine, implementing `runtime/vm`, first host APIs, and direct file execution).
- TypeScript handling: belongs in `zjs`, including TypeScript parsing,
  erasure/lowering, and future type warm-up metadata.
- `fun` owns host/runtime product surfaces: CLI, resolver, loader, config,
  package.json integration, Node/Bun-style APIs, package manager, test runner,
  bundler, cache, watch mode, diagnostics, and developer experience.

See `docs/zjs-integration.md` for the detailed embedding contract.

## Current Status

M2 (zjs Embedding API Design) is the current planning focus. No code
that depends on `zjs` has been written yet.

- M0 scaffold is complete and testable.
- M1 architecture contract is complete: ownership boundaries, the `zjs`
  language-engine decision, TypeScript-in-`zjs`, and type warm-up constraints
  are documented.
- M2 is actively being designed. The goal is to settle the stable `zjs`
  embedding API shape, dependency mode, and adapter boundary before `fun`
  starts depending on `zjs` in `build.zig`.
- The next implementation work after M2 should stay narrow: diagnostics,
  direct file execution, REPL evaluation, loader file reads, relative/absolute
  ESM resolution, and compile-input assembly.
- Tooling surfaces such as package manager, bundler, and test runner remain
  explicit placeholders until direct file execution and module loading execute
  through `zjs`.

## Current Implementation Status {#current-implementation-status}

**Single source of truth** for scaffold vs. planned design. This table is the
authoritative view of what actually exists in the tree right now.

**State vocabulary** (use exactly these):
- `Thin shell` — minimal entry point only
- `Scaffold + tests` — real behavior with tests, intentionally limited
- `Explicit placeholder` — returns clear `NotImplemented` error + has tests
- `Not created` / `Not started` — design exists, implementation does not

**Maintenance**: Update this table + the Decision Log whenever implementation
crosses a milestone boundary, a major placeholder is filled, **or a structural
reorganization per fun_zjs_subtree_architecture.md occurs**. Last major review:
2026-05 subtree architecture alignment + flat-to-layered migration.

| Area / Module                               | State                          | Primary Doc                                      | Notes |
|---------------------------------------------|--------------------------------|--------------------------------------------------|-------|
| `src/main.zig`                              | Thin shell                     | architecture.md, fun_zjs_subtree_architecture.md | Still thin |
| `src/root.zig`                              | Public facade                  | architecture.md                                  | Re-exports new layered modules; all old tests preserved |
| **New layered structure (2026-05)**         |                                |                                                  | |
| `third_party/zjs/`                          | Prepared (empty until subtree) | fun_zjs_subtree_architecture.md §5, §17 (Phase 1) | Run `git subtree add` to populate full zjs (engine + cli + tests) |
| `src/primitives/`                           | Scaffold structure             | fun_zjs_subtree_architecture.md §3               | Low-level (allocators, collections, ModuleKind, etc.). Migrated `core` logic here |
| `src/diagnostics/`                          | Scaffold structure             | fun_zjs_subtree_architecture.md §3, runtime-mvp | Spans, reports, SourceMap etc. (stubs only) |
| `src/js/` (facade)                          | Scaffold structure             | fun_zjs_subtree_architecture.md §7               | Stable entry for all of fun; wraps zjs_engine |
| `src/runtime/vm/` (唯一深耦合层)           | Scaffold structure             | fun_zjs_subtree_architecture.md §9               | **Only** place allowed deep zjs knowledge (Engine ownership, host hooks) |
| `src/runtime/` (scheduler, modules, api, napi) | Scaffold structure          | fun_zjs_subtree_architecture.md §10–12           | Event loop, loader, Web/Node/Fun APIs (all stubs) |
| `src/tooling/` (cli, resolver, transpiler, bundler, package_manager, test_runner, ...) | Scaffold structure | fun_zjs_subtree_architecture.md §3 | All old flat tooling migrated here |
| `src/platform/`, `src/common/`              | Scaffold structure             | fun_zjs_subtree_architecture.md §3               | OS abstractions (stubs) |
| **Legacy flat dirs (migrated)**             |                                |                                                  | |
| `src/cli`, `src/core`, `src/resolver`, `src/loader`, `src/js_parser`, `src/transpiler`, `src/bundler`, `src/package_manager`, `src/test_runner`, `src/repl` | Migrated (deleted after 2026-05 restructure) | (historical) | Logic moved; old names still re-exported from `root.zig` for compat during transition |
| **Behavior areas**                          |                                |                                                  | |
| CLI parsing + help (`tooling/cli`)          | Scaffold + tests               | runtime-mvp.md                                   | Full MVP command model preserved |
| ModuleKind / specifier classification       | Scaffold + tests               | architecture.md                                  | Now in primitives + tooling/resolver |
| `zjs` dependency / embedding                | Phase 1 prepared; wiring in Phase 2–3 | fun_zjs_subtree_architecture.md + zjs-integration.md | No engine calls yet outside the prepared facade |
| `src/diagnostics` (real reports)            | Not created                    | runtime-mvp.md                                   | Planned M3 |
| Execution + host APIs (`console`, timers, fs, ...) | Not started                | runtime-mvp + subtree arch §10–12                | Core of M4; must go through vm |
| TypeScript execution                        | Not started                    | roadmap (M5)                                     | Via zjs frontend once wired |
| Full tooling (bundler, package manager, test runner) | Explicit placeholders     | roadmap (M7)                                     | Deferred |

See `docs/runtime-mvp.md` for the precise MVP acceptance criteria.

## Product Direction

The long-term product is a single binary for JavaScript and TypeScript
development:

- `fun` starts an interactive REPL.
- `fun <file> [...args]` executes JS files and passes script arguments through
  to `process.argv`.
- TypeScript source kinds are recognized from the start, but TS execution waits
  for the `zjs` frontend path.
- Later tooling can include tests, package management, bundling, watch mode,
  formatting hooks, project initialization, and deploy/build workflows.

The accepted runtime MVP is recorded in `docs/runtime-mvp.md`. It does not
include `fun eval`, `fun run`, or an explicit `fun repl` subcommand.

The standard for success is "useful Bun-like runtime", not "Bun-compatible by
claim". Compatibility claims require tests and documented behavior.

## Repository Roles

### fun

`fun` is the product shell and host runtime:

- CLI command model and UX.
- Project configuration and package.json handling.
- Module resolution and loading.
- Host APIs such as `console`, `process`, timers, file APIs, fetch, and later
  Bun-compatible APIs.
- Test runner, package manager, bundler, cache, and watch mode.
- Source maps, diagnostics, stack formatting, and exit-code mapping.
- Stable embedding boundary into `zjs`.

### zjs

`zjs` is the language engine:

- JavaScript and TypeScript frontend.
- TypeScript syntax erasure/lowering.
- JSX/TSX lowering when that scope is accepted.
- Type warm-up metadata derived from TypeScript annotations and obvious static
  shapes.
- Bytecode generation and execution.
- ECMAScript built-ins and semantic correctness.
- test262-driven compatibility work.

`zjs` should remain a language engine. It should not absorb the package
manager, bundler product UX, Node/Bun host API surface, or project-management
features unless those are needed as engine embedding hooks.

## Top-Level Pipeline

The intended runtime pipeline is:

```text
fun CLI
  -> command model
  -> project config / package.json
  -> resolver
  -> loader
  -> zjs compile input
  -> zjs JS/TS frontend
  -> zjs type warm-up metadata
  -> zjs bytecode/runtime execution
  -> fun host APIs / diagnostics / exit code
```

This means `fun` should pass source kind, entry path, loader metadata, tsconfig
or JSX settings, sourcemap preferences, and host API bindings to `zjs`.

It should not pre-transpile TypeScript into JavaScript in a way that hides type
information from `zjs`.

## TypeScript and Type Warm-Up

TypeScript is part of the `zjs` language frontend.

The first TypeScript goal is runtime execution, not typechecking:

- parse `.ts`, `.tsx`, `.mts`, and `.cts`;
- remove or lower syntax with no runtime meaning;
- reject unsupported syntax with clear diagnostics;
- preserve source locations for stack traces and sourcemaps;
- produce normal JavaScript bytecode semantics.

Type warm-up is a later optimization path. It can use source-level type
annotations and static shapes to create execution hints, for example:

- numeric hints from `number` parameters and locals;
- string hints from `string` annotations;
- object shape hints from annotated object literals or interface-like data;
- array element hints from typed arrays or obvious element annotations;
- class instance shape preallocation from field declarations.

These hints must not change JavaScript runtime semantics. They are speculative
optimization inputs and must be invalidated when runtime values disagree.

`zjs` should not become a full TypeScript typechecker unless explicitly
re-scoped. Type warm-up uses available type syntax as optimization metadata, not
as a compile-time correctness gate.

## Current Source Ownership

Current `fun` scaffold ownership:

- `src/main.zig`: process entry point, stdio setup, top-level dispatch only.
- `src/root.zig`: public facade for importing runtime layers.
- `src/cli`: command parsing and CLI-facing messages.
- `src/core`: shared primitives such as source-kind detection and future
  environment/platform helpers.
- `src/resolver`: import specifier classification and path/package resolution.
- `src/loader`: file reads, module records, source cache, and JSON loading.
- `src/runtime`: `zjs` embedding adapter and host API bridge.
- `src/js_parser`: should become a compatibility/adaptation layer only if
  `fun` needs source-kind or diagnostics helpers; the real JS/TS parser belongs
  in `zjs`.
- `src/transpiler`: should not grow into an independent TypeScript compiler.
  Keep it as a future wrapper for invoking `zjs` frontend transforms, or remove
  it when the embedding boundary is clearer.
- `src/bundler`, `src/package_manager`, `src/test_runner`, `src/repl`: product
  tooling boundaries. `src/repl` is part of the runtime MVP; bundler, package
  manager, and test runner remain deferred.

## Major Tradeoffs

| Topic | Decision | Why | Cost / risk | Revisit when |
| --- | --- | --- | --- | --- |
| Product target | Real Bun-like runtime | Keeps ambition high enough to guide architecture | Larger scope than a simple JS runner | If first usable runtime takes too long |
| Engine | Use `zjs` | Keeps the stack Zig-native and builds on existing QuickJS-faithful work | `fun` depends on `zjs` maturity and embedding API quality | If `zjs` cannot support required host integration |
| Bun relation | Bun-inspired, not JSC/Bun clone | Bun's product shape is useful; its engine stack is not the chosen path | Some Bun behavior will require deliberate compatibility work | Once compatibility suites exist |
| TypeScript location | `zjs` frontend | Preserves type information for warm-up before erasure | `zjs` scope grows beyond pure JS parsing | If TS work starts slowing ECMAScript parity work |
| Type checking | Not in scope | Runtime should stay fast and predictable | Users may expect TS diagnostics | If a separate checker integration is requested |
| Type warm-up | Optimization metadata, not semantics | Uses TS information without changing JS behavior | Needs invalidation and careful testing | After basic TS execution works |
| Module loading | `fun` owns loading and resolution | Host/runtime product behavior belongs above the engine | Needs clean compile input contract with `zjs` | When package exports/imports are implemented |
| Package manager | Deferred | Running JS/TS is a prerequisite for useful tooling | Delays all-in-one product feel | After `fun <file>` and package resolution work |
| Bundler | Deferred but expected | Bun-like product needs it eventually | Large graph/chunking/sourcemap scope | After module graph and TS frontend are stable |
| Tests | Fast fixtures first, test262 through `zjs` | Separates product behavior from language semantics | Two validation surfaces must stay aligned | When `fun` embeds `zjs` for real (see docs/testing.md) |

## Milestones

### M0: Scaffold

Status: complete.

- Zig build and test pipeline exists.
- Runtime source directories exist.
- CLI commands parse and return explicit placeholder messages.
- Bun architecture mapping is documented.

### M1: Architecture Contract

Status: complete.

Goal: finish the design before large implementation work.

Acceptance:

- `fun`/`zjs` ownership boundaries are documented.
- `zjs` embedding API requirements are listed.
- TypeScript-in-`zjs` and type warm-up are recorded as explicit decisions.
- The old open-ended engine-selection framing is removed from active planning.

### M2: zjs Embedding API Design

Status: structural skeleton complete (2026-05). The `src/js` facade + `src/runtime/vm`
boundary and `third_party/zjs` subtree prep are in place per
`fun_zjs_subtree_architecture.md`. Real engine wiring, host hooks, and the first
usable `fun <file>` path are the next implementation work. See sections 7–9 and
Phase 2–4 of the subtree architecture document.

Goal: define the stable boundary `fun` needs from `zjs`.

Required capabilities:

- create and destroy runtime/context;
- evaluate REPL input in a persistent context;
- compile and run an entry module for `fun <file> [...args]`;
- provide source path, source kind, and tsconfig/JSX options;
- register host functions and host modules;
- pump jobs and microtasks;
- surface structured errors, stack traces, and source locations;
- expose allocator and GC lifecycle expectations;
- expose optional type warm-up metadata controls.

Acceptance:

- A design note describes the API shape and ownership model.
- `fun` does not depend on random `zjs` internals.
- The first integration path can be tested without implementing package
  manager, bundler, or test runner behavior.

### M3: CLI, Diagnostics, Loader, Resolver

Goal: the accepted MVP command contract is represented locally. `fun` maps to
REPL, `fun <file> [...args]` can read a file, classify it, resolve simple
relative imports, and build a `zjs` compile input.

Acceptance:

- CLI parses no-argument REPL and file execution with script args.
- `run`, `eval`, and `repl` are ordinary file-path arguments, not subcommands.
- CLI returns stable exit codes for success, usage errors, and runtime errors.
- Loader reads local files with allocator ownership documented.
- Resolver supports relative and absolute specifiers with tests.
- Fixture tests cover missing file, unsupported extension, and simple import
  paths.

### M4: First zjs Execution Integration

Goal: execute simple JS through `zjs` from `fun`.

Acceptance:

- `fun` evaluates REPL input through a persistent `zjs` context.
- `fun examples/hello.js` executes a file.
- Runtime errors produce stable diagnostics.
- Host `console.log`, basic `process`, global timers, `node:fs`, and
  `node:fs/promises` work through the `fun` host API bridge as documented
  subset APIs.

### M5: TypeScript Runtime Frontend

Goal: execute simple TypeScript through `zjs` without a separate `fun`
transpiler.

Acceptance:

- `fun examples/hello.ts` executes through the `zjs` TS frontend.
- Type annotations are erased or lowered without changing runtime semantics.
- Unsupported TS syntax fails with clear diagnostics.
- Type warm-up metadata can be disabled for debugging.

### M6: Module Graph and Package Resolution

Goal: run a small multi-file project.

Acceptance:

- ESM imports work for local files.
- JSON loading has explicit behavior.
- Simple package entry resolution is documented and tested.
- Module cache behavior is deterministic.
- `zjs` receives module records through a stable loader callback or compile
  input API.

### M7: Bun-Like Tooling Expansion

Goal: fill the product surfaces after direct file execution, REPL evaluation,
and local module loading are real.

Candidate order:

1. `fun test`
2. basic bundler command
3. package manager experiments
4. watch/cache optimization

Package manager work should wait until there is a clear lockfile, registry, and
cache plan.

## Near-Term Backlog

- Keep `docs/zjs-integration.md` aligned with the actual `zjs` public API as it
  stabilizes.
- Decide how `fun` consumes `zjs`: Zig package dependency, git submodule,
  vendored workspace, or local path during early development.
- Decide whether the public embedding module should stay
  `quickjs_zig_engine` or move to a new embed-oriented module name.
- Decide whether M2 requires changes in `zjs` first, or whether `fun` should
  start with a temporary adapter over the current `Engine` API.
- Add `src/diagnostics` for structured errors, spans, and exit-code mapping.
- Add fixture test infrastructure for CLI-level behavior (see docs/testing.md for the target shape).
- Implement loader file reads and update `fun <file> [...args]` to build a
  compile input.
- Keep `src/transpiler` empty or adapter-only until the `zjs` frontend API is
  defined.

## Open Questions

- Should `fun` and `zjs` remain separate repositories permanently, or should
  `zjs` become a vendored/submodule dependency inside `fun`?
- What exact `zjs` public API should be stabilized for host embedding?
- Should `zjs` parse TS directly in its existing frontend, or should TS be a
  sibling frontend that lowers into the same bytecode pipeline?
- What is the first TypeScript subset for execution?
- What exact behavior should each MVP host API expose before it is documented:
  `console`, `process`, timers, `node:fs`, and `node:fs/promises`?
- How much Node compatibility is required before package manager work begins?
- What is the first compatibility target for `fun`: local fixtures, selected
  Bun tests, selected Node tests, or a product-specific smoke suite?

## Decision Log

- 2026-05 (subtree architecture alignment): Adopted the full Git subtree +
  layered facade design from `docs/fun_zjs_subtree_architecture.md` as the
  authoritative contract for the repository. Performed the flat-to-layered
  migration (`src/js/`, `src/runtime/vm/`, `src/tooling/*`, `src/primitives/`,
  `src/diagnostics/`, `src/platform/`, `third_party/zjs/` prep). Updated
  AGENTS.md, all cross-references, build graph, and status matrix. This is a
  foundational structural change (Phase 0–1 of the migration plan in the
  subtree document). Old flat directories were removed after verification.
- 2026-06 (docs automation & structure): Added `zig build docs-check` as a
  first-class, required gate (wired into build.zig, AGENTS.md, docs/README.md,
  and root README.md). Created minimal `CONTRIBUTING.md` at project root.
  Enhanced `docs/testing.md` with concrete planned fixture directory layout for
  M3+. Completed final date standardization. This is a major step toward 10/10
  sustainable documentation discipline.
- 2026-05 (docs improvement pass): Removed self-referential "10/10 quality" claim
  from `docs/README.md`. Sanitized `zjs-integration.md` "Current zjs Surface"
  section to isolate concrete internal paths and module names into a clearly
  labeled historical baseline note, making portability descriptions accurate.
  Clarified M2 status language throughout `roadmap.md` (now explicitly "planning
  focus — no implementation started" rather than "active"). Added this entry.
- 2026-05 (docs cleanup): Added `docs/README.md`, portable evidence rules in
  `zjs-integration.md`, and a living "Current Implementation Status" matrix in
  this file. Strengthened "current scaffold vs planned design" language across
  architecture documents.
- 2026-05-28: Use Bun v1.3.14 as an architecture and product reference, not as
  source code to copy.
- 2026-05-28: Keep `src/main.zig` thin and route reusable code through
  `src/root.zig`.
- 2026-05-28: Add explicit boundaries for CLI, core, parser/transpiler adapter,
  resolver, loader, runtime, bundler, package manager, test runner, and REPL.
- 2026-05-28: Set product target to a genuinely usable Bun-like runtime.
- 2026-05-28: Choose `zjs` as the language engine instead of leaving the engine
  backend open.
- 2026-05-28: Put TypeScript frontend handling in `zjs`, not in a separate
  `fun` transpiler.
- 2026-05-28: Treat type warm-up as `zjs` optimization metadata. It must not
  change JavaScript runtime semantics.
- 2026-05-28: Defer package manager, bundler, and test runner implementation
  until file execution through `zjs` is real.
- 2026-05-28: Add `docs/zjs-integration.md` as the design contract for the
  `fun` to `zjs` embedding boundary.
- 2026-05-28: Mark M1 complete and make M2 the active planning target. The next
  decisions are `zjs` dependency mode, public embedding module shape, and
  whether `fun` starts with a temporary adapter or waits for `zjs` API changes.
- 2026-05-28: Accepted the runtime MVP scope in `docs/runtime-mvp.md`: `fun`
  enters REPL, `fun <file> [...args]` executes JS ESM, `run`/`eval`/explicit
  `repl` are not commands, and the first host API surface is a small
  Node-shaped subset.
