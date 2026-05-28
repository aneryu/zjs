# zjs Integration Contract

> **2026-05 Note**: This document remains the source of truth for *what* stable
> embedding APIs and capabilities `fun` needs from `zjs` (Engine lifecycle,
> Source input, loader callbacks, host APIs, jobs, structured diagnostics, etc.).
> The *how* — import boundaries, `src/js` facade, `src/runtime/vm` as the sole
> deep-coupling layer, and Git subtree management — is now governed by
> `docs/fun_zjs_subtree_architecture.md` (sections 4, 7–9, 19–20). Read both
> documents together.

This document defines the **intended** integration boundary between `fun` (host
and runtime shell) and [`zjs`](https://github.com/aneryu/zjs) (language engine).

**Status**: This is a design contract and planning artifact, not a claim about
current implementation. The project is still in the M2 phase (embedding API
design) — no production dependency on `zjs` exists yet.

It separates:

- what `zjs` already exposes today;
- what `fun` should depend on;
- what needs to become a stable embedding API before direct file execution and
  the REPL are implemented.

## Integration Goal

`fun` should embed `zjs` as its JavaScript and TypeScript language engine.

`fun` owns:

- CLI and command UX;
- project config and package.json behavior;
- module resolution and file loading;
- host APIs such as console, process, timers, fs, fetch, and Bun-compatible
  APIs;
- package manager, test runner, bundler, cache, watch mode, and diagnostics.

`zjs` owns:

- JavaScript parsing and execution;
- TypeScript parsing, erasure/lowering, and future type warm-up metadata;
- JSX/TSX lowering when that scope is accepted;
- bytecode, built-ins, jobs/microtasks, errors, and ECMAScript semantics;
- test262-driven language compatibility.

The design goal is a narrow stable API. `fun` should not import random `zjs`
internal files or couple itself to current engine implementation details.

## Current zjs Surface (Design Baseline)

This section records the conceptual surface that informed the required stable
embedding API below. It is **not** a guarantee of the current `zjs` public API —
always re-audit against the live `zjs` tree before implementing the adapter in
`src/runtime`.

The design baseline showed an engine exposing:

- Explicit runtime/context and job-queue lifecycle (`init`, `deinit`, run-jobs).
- Multiple evaluation entry points (script, module, REPL-style).
- Structured error types alongside formatted output.
- Some CLI-oriented helpers for argv/globals and std-os exposure.
- Optional tracing and configuration (memory limits, stack size, etc.).

These capabilities directly shaped the "Required Stable API" concepts that follow
(Engine lifecycle, `CompileInput`, loader callbacks, host registration, structured
diagnostics, etc.).

Concrete module names, file paths, and exact API shapes from the May 2026
baseline are recorded only for historical reference (see below). They must not
be treated as the stable contract.

### May 2026 baseline evidence (historical only)

- At the time of writing, `zjs` exposed a module commonly referenced as
  `quickjs_zig_engine` (with build option `zjs_enable_ic`).
- Key types and functions observed: `Engine`, `Engine.init` / `initWithTrace`,
  `eval*` variants, `runJobs`, plus helpers such as
  `defineCliArgvGlobalsLazy` and `exposeStdOsGlobals`.
- The `zjs` CLI itself served as a useful behavioral reference for driving the
  engine end-to-end.

To inspect the live surface, clone the `zjs` repository and examine its public
module exports and engine entry points directly. Future updates to this document
should keep the conceptual requirements stable while moving any new concrete
evidence into a fresh historical note.

## Required Stable API

`fun` needs `zjs` to stabilize an embedding layer with the following concepts.

### Engine Lifecycle

Required:

- create an engine/runtime with allocator and options;
- destroy it deterministically;
- configure memory limit, stack size, blocking behavior, and optional tracing;
- run GC or expose a deliberate no-direct-GC policy;
- expose debug toggles such as inline-cache disablement in a controlled way.

Candidate shape:

```zig
pub const EngineOptions = struct {
    memory_limit: ?usize = null,
    stack_size: ?usize = null,
    can_block: bool = false,
    trace_writer: ?*std.Io.Writer = null,
    enable_type_warmup: bool = true,
};

pub const Engine = opaque_or_struct;

pub fn createEngine(allocator: std.mem.Allocator, options: EngineOptions) !Engine;
pub fn destroyEngine(engine: *Engine) void;
```

The actual names can differ. The important part is that `fun` can own the
engine lifecycle without touching `zjs` internals.

### Source Input

`fun` needs to pass more than bytes:

- source text;
- absolute or display path;
- source kind: JS, MJS, CJS, TS, MTS, CTS, JSX, TSX, JSON if supported;
- parse goal: script or module;
- package type context: `commonjs` or `module`;
- tsconfig / JSX options when relevant;
- sourcemap preference;
- optional cache key and content hash.

Candidate shape:

```zig
pub const SourceKind = enum {
    js,
    mjs,
    cjs,
    ts,
    mts,
    cts,
    jsx,
    tsx,
    json,
};

pub const ParseGoal = enum {
    script,
    module,
};

pub const CompileInput = struct {
    source: []const u8,
    path: []const u8,
    kind: SourceKind,
    goal: ParseGoal,
    package_type: PackageType = .none,
    jsx: JsxOptions = .{},
    ts: TypeScriptOptions = .{},
    source_map: SourceMapMode = .none,
};
```

`fun` should not turn TypeScript into JavaScript before this point. TypeScript
syntax should reach `zjs` so type warm-up can see it.

### Evaluation

Required:

- evaluate REPL input in a long-lived context;
- compile/evaluate one entry file for `fun <file> [...args]`;
- evaluate ESM module graphs with loader callbacks;
- return a structured result, not only a raw engine `Value`;
- preserve source locations and stack traces.

Candidate shape:

```zig
pub const EvaluationResult = union(enum) {
    value: ValueHandle,
    empty,
};

pub fn eval(engine: *Engine, input: CompileInput, host: *Host) EvalError!EvaluationResult;
pub fn runModule(engine: *Engine, entry: CompileInput, host: *Host) EvalError!EvaluationResult;
```

`ValueHandle` should be an embedding-safe handle or formatter. `fun` should not
need to know every internal `zjs` value representation to run a script.

### Loader Callbacks

`fun` owns host resolution and loading. `zjs` should be able to ask `fun` for a
module through a narrow callback:

```zig
pub const ResolveRequest = struct {
    specifier: []const u8,
    referrer: []const u8,
    import_kind: ImportKind,
};

pub const ResolveResult = struct {
    path: []const u8,
    kind: SourceKind,
    goal: ParseGoal,
};

pub const LoadRequest = struct {
    resolved_path: []const u8,
    kind: SourceKind,
};

pub const LoadResult = struct {
    source: []const u8,
    path: []const u8,
    kind: SourceKind,
};
```

Ownership must be explicit. Either `fun` owns loaded bytes until evaluation
finishes, or `zjs` copies them. Avoid ambiguous borrowed lifetimes.

### Host APIs

`fun` needs to register host behavior without forking `zjs` internals:

- `console`;
- `process` and argv/env/cwd;
- timers and event-loop integration;
- file APIs;
- fetch/network APIs later;
- Bun-compatible globals later;
- test runner globals later.

The contract should support:

- registering global objects/functions;
- registering native modules;
- attaching host userdata;
- converting JS values to/from host data;
- throwing host errors with structured diagnostics;
- finalizing host resources during GC or engine teardown.

The current `zjs` CLI helpers for argv and `std/os` globals are useful, but
`fun` needs a general host registration mechanism.

### Jobs and Event Loop

`fun` needs control over jobs and host event-loop turns:

- run microtasks after evaluation;
- detect unhandled rejections;
- integrate timers and IO readiness later;
- support blocking policy (`can_block`);
- avoid hidden CLI-only behavior.

Initial API can be simple:

```zig
pub fn runJobs(engine: *Engine) JobRunResult;
pub fn hasUnhandledRejection(engine: *Engine) bool;
pub fn takeUnhandledRejection(engine: *Engine) ?ErrorInfo;
```

Later, this should become event-loop aware.

### Errors and Diagnostics

`fun` must not parse human-formatted `zjs` error strings as its primary error
path.

Required structured diagnostics:

- error kind: syntax, reference, type, range, host, module resolution, OOM,
  interrupt, unhandled rejection;
- message;
- source path;
- line and column;
- stack frames;
- optional cause chain;
- exit-code mapping hint.

Source location quality matters because `fun` will own CLI diagnostics,
sourcemaps, test output, and bundler errors.

### TypeScript and Type Warm-Up

The `zjs` frontend should accept TS/TSX source kinds and produce normal JS
runtime semantics.

Type warm-up should be optional and observable only through performance or debug
metadata. It must not change program behavior.

Required controls:

- enable/disable type warm-up;
- expose debug counters or traces;
- invalidate hints when observed values disagree;
- keep source-map and stack location behavior stable after TS lowering.

Candidate metadata examples:

- numeric parameter/local hints;
- string hints;
- object shape hints;
- class instance shape preallocation;
- array element kind hints.

## fun Adapter Shape

Inside this repository the layering is:

- `src/js/` — stable public facade (all of `fun` imports this; never raw zjs paths).
- `src/runtime/vm/` — **唯一深耦合层**; the only place that may import zjs internals
  or own the `Engine` instance and implement the host vtable.
- `src/runtime/` (outside vm) — owns `Runtime`, scheduler, module loader, and
  public APIs; talks to the engine only through the `vm` bridge or `js` facade.

Suggested files (see `fun_zjs_subtree_architecture.md` §7 and §9 for the current
sketches):

- `src/js/{root,api,host,value,exception,source,module,internal}.zig`
- `src/runtime/vm/{VM,Global,JSValue,NativeFunction,Exception,Promise,Microtask,bindings}.zig`
- `src/runtime/Runtime.zig` + `src/runtime/modules/loader.zig` etc.

The rest of `fun` (tooling, higher runtime layers, tests outside js/) must not
import the zjs engine module directly. An import guard (subtree doc §20) enforces this.

## Integration Strategy

Preferred sequence:

1. Keep design in docs only.
2. Decide dependency mode: Zig package path dependency, git submodule, vendored
   workspace, or local path during early development.
3. Decide whether `zjs` should expose a new embed-oriented module/API before
   `fun` imports it, or whether `fun` should first wrap the current `Engine`
   API behind `src/runtime/zjs_adapter.zig`.
4. Add a minimal `zjs_adapter` that can create/destroy an engine without
   leaking `quickjs_zig_engine` imports outside `src/runtime`.
5. Wire no-argument `fun` to a REPL backed by a persistent `zjs` context.
6. Wire `fun <file.js> [...args]` using `fun` loader and diagnostics.
7. Add module loading through callbacks or agreed compile input.
8. Add TS source kinds after `zjs` frontend supports them.
9. Add type warm-up controls once basic TS execution is stable.

Do not start with package manager, bundler, or test runner integration. Those
surfaces depend on reliable execution and module loading.

## M2 Decision Queue

M2 should close the following decisions before implementation expands:

- Dependency mode: start with a local path dependency for fast joint
  development, then switch to a pinned package or submodule when the embedding
  API stabilizes.
- Public module name: either keep `quickjs_zig_engine` as the package import or
  add a smaller embed-oriented module name that hides CLI-only helpers.
- API layering: decide whether `fun` needs only high-level REPL/file execution
  APIs at first, or an explicit compile/evaluate split for future caching and
  bundling.
- Loader ownership: keep resolution and file loading in `fun`; only allow
  fallback `zjs` loading for standalone `zjs` CLI behavior.
- Diagnostic shape: require structured errors before `fun` reports stable
  runtime diagnostics; formatted strings are acceptable only as a temporary
  display fallback.
- Host API minimum: start with `console`, `process.argv`, `process.cwd()`,
  `process.env`, global timers, `node:fs`, and `node:fs/promises`. Fetch and
  Bun-specific APIs remain outside the runtime MVP.

## Validation Plan

For `fun`:

- `zig build test --summary all`;
- CLI fixture tests for no-argument REPL and `fun <file> [...args]`;
- missing-file, syntax-error, runtime-error, and unhandled-rejection fixtures;
- loader/resolver fixtures for relative paths and package type behavior;
- host API smoke tests for console, argv, env, cwd, timers, and fs as they land.

For `zjs`:

- keep using `zjs`'s own validation surface;
- focused smoke tests for changed frontend/runtime behavior;
- targeted test262 slices for semantic changes;
- full `test262-gate` when stabilizing engine behavior.

Integration validation should prove both sides:

- `fun` does not depend on private `zjs` internals;
- `zjs` can be embedded without invoking its CLI;
- errors and source locations survive the adapter boundary;
- jobs and unhandled rejections are observable by `fun`;
- TS source is passed to `zjs` before erasure.

## Open Questions

- Should `fun` consume `zjs` as a Zig package dependency, submodule, vendored
  workspace, or local path first?
- Should the stable module name stay `quickjs_zig_engine`, or should `zjs`
  expose a new embed-oriented module name?
- Should `zjs` expose a high-level `Engine` API only, or also a lower-level
  compile/evaluate split for caching and bundling?
- Should `fun` own all module resolution, or should `zjs` keep a fallback
  resolver for standalone use?
- What is the first TypeScript subset that `zjs` should accept?
- Should type warm-up metadata be generated during parsing, lowering, bytecode
  emission, or a separate analysis pass?
- How should host values and resources be represented so GC/finalization remains
  safe?

## Non-Goals

- Do not copy Bun's JavaScriptCore binding layer.
- Do not implement a separate TypeScript compiler in `fun`.
- Do not move package manager, bundler, or test runner logic into `zjs`.
- Do not make compatibility claims before fixture or conformance evidence
  exists.
- Do not couple `fun` commands to the current `zjs` CLI implementation.
