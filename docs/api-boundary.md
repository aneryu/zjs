# API Boundary

zjs is a JavaScript / TypeScript engine written in Zig. ECMA-262 governs
JavaScript semantics; QuickJS is a comparison reference. The Zig embedding
surface exposes engine primitives while keeping host policy outside core.

## Layers

`src/core/` is the engine implementation layer:

- runtime and context storage;
- tagged values, strings, atoms, objects, properties, arrays, and GC;
- ECMAScript semantic machinery and job-queue primitives;
- `NativeEntry` (`native_entry.zig`), the single immutable native-function
  record that builtins, host functions, and native accessors resolve to.

`src/root.zig` is the single Zig module imported as `zjs`. Embedders use
`Runtime`, `Context`, `Value`, and `Call`. The same file
re-exports engine layers for the CLI, test262, and in-tree tests.

`src/js_context.zig` is the host `Context` facade. `src/native.zig` builds
the comptime thunk used by `Context.defineFunction`. There is no landed
`src/kernel/` directory; earlier "kernel API" language maps to these files
plus `src/root.zig`.

`src/host/` is the internal `zjs_host` module used by the two bundled
programs and their tests. Event scheduling, file source policy, and host
output live there. It imports the engine; the engine does not import or
re-export it. Module graph semantics, Atomics waiter cleanup, and ArrayBuffer
detach stay in `src/exec/`. The former dynamic plugin loader (`plugin.zig`, the `zjs.ffi` ABI) was
deleted 2026-09-06; its successor, the FNABI loader, lives in the `fun`
repository and is an embedder of `Context.defineFunction` like any other.

## Core Rules

- `src/core/` must not depend on CLI policy, test262 harness glue, plugin
  loaders, JSI/FFI policy, event-loop policy, or product-runtime APIs.
- Public embedding APIs are added through `src/root.zig`, `src/js_context.zig`,
  or `src/native.zig`. Layer re-exports on `src/root.zig`
  (`core`, `exec`, `parser`, `JSRuntime`, …) are for in-tree hosts, not a
  second embedder surface.
- New runtime features should depend on core primitives. Core must not depend
  on runtime features.
- `zjs` and `run-test262` are runtime users. They do not own core concepts.
- test262-only names and harness shortcuts must stay out of core.

## Public Shape

The public API is Zig-first, not a C compatibility API. Prefer explicit
runtime/context/value primitives, slices, typed flags, comptime descriptors, and
generated stubs.

The central public primitives are:

```zig
zjs.Runtime
zjs.Context
zjs.Value
zjs.Call
Context.defineFunction
Context.defineScriptArgs
```

Do not introduce a public `Engine` facade as the central API. It hides lifetime
and dispatch costs that embedders need to control.

Root aliases are additive only. Do not document names as available until they
appear in `docs/public-api-contract.md`. JSContext host-reference ownership
(`create` vs `createRealm`, and the ban on `destroy` via `contextForGlobal` /
`context_head`) is documented there, not here.

## Performance Shape

The engine exposes these primitives and cost boundaries:

- `JSRuntime`, `JSContext`, `JSValue`, atom-like property names, class IDs, and
  opaque payloads are explicit primitives.
- `JSValue` is passed as a low-level tagged value.
- Hot property and callback paths should not compare strings after setup.
- Host objects use explicit finalizers and GC marking.

Hot paths include property access, callback dispatch, argument conversion,
string/byte view access, event-loop callbacks, and JS <-> native calls. Hot
paths should avoid heap allocation, broad dynamic dispatch, extra value
wrappers, hidden rooting/allocation work, and C ABI crossings inside same-build
Zig code.

Cold paths include binding install, name interning, class-id allocation,
prototype construction, descriptor validation, native function registration,
and exception materialization.

## Runtime Policy

The bundled host owns event loops, timers, and filesystem policy. The engine
retains generic host progress/source contracts, module graph semantics,
SharedArrayBuffer wake/cleanup hooks, and ArrayBuffer detach. Concrete host
capabilities do not move into `src/core/`.

The `zjs` CLI is a thin benchmark and smoke-test shell. Its default
JavaScript-visible host surface is intentionally small:

- `print(...args)`;
- `console.log(...args)`.

It does not imply QuickJS-compatible `std`/`os`, Node, Deno, browser, or timer
profiles. Any future product-runtime profile must be explicit.

`run-test262` installs its own harness globals and may retain harness-only
shortcuts. Ordinary object, property, call, string, bytes, realm, module,
event-loop, exception, and cleanup paths should use public binding/runtime
helpers.

## Native Functions

Every native callable -- engine builtin, embedder function, native accessor
-- resolves to one immutable `NativeEntry` ([`src/core/native_entry.zig`](../src/core/native_entry.zig)). The entry is an
offset-pinned `extern struct` carrying the code pointer, the call kind
(`managed`, `leaf`, constructor, getter/setter, ...), the leaf signature id,
the arity, the optional `state` pointer, and JIT effect annotations. The VM
switches on the kind once per call and never branches on where the entry
came from: there is no registry, no id space, and no string lookup on the
call path. Builtin entries are comptime rodata; host entries are allocated
in the runtime's entry arena by `Context.createFunction` and are never
freed before the runtime dies (retiring one rewrites its kind to a tombstone
in place).

`Context.defineFunction` / `createFunction` is the only public way to make an
entry: a plain `fn (*Call) E!Value` is wrapped at comptime into a
`callconv(.c)` thunk (the call receives the callee realm, `this`, and a view
of the VM operand window; Zig errors map to JS exceptions at the seam).
Leaf signatures stay engine-private. Per-registration `FunctionOptions`
carry `length`, `state`, `finalize`, `with_prototype`, and `realm_global`.
The reverse direction, native -> JS, is `Context.callFunction`. Host-side
property access is `Context.getProperty` / `defineDataProperty`. The
rooting, exception, realm, backtrace, interrupt, entry-lifetime, and thread
contracts are C1-C10 in the design document and are restated for embedders
in `docs/public-api-contract.md`.

## Current Exceptions

`run-test262` still marks `$262.IsHTMLDDA` through a local object shortcut. This
is harness and Annex-B specific; it is not a general embedding API.

The QuickJS-shaped `std`/`os` host-function records and their installers have
been deleted (recoverable from git history). Host-provided functions use
`NativeEntry`s. Bundled output uses static entries; embedders register through
`Context.defineFunction`. The old output-id dispatch table in exec is gone.
Class slot 65 remains reserved for the removed legacy stdio class. File
handles and close policy belong to the embedding host.

## Non-Goals

- No public `Engine` facade.
- No UTF-8-only internal JavaScript string model.
- No automatic `std`/`os`, Node, Deno, browser, or timer profile in the default
  CLI/embedding global.
- No arbitrary Zig struct transfer across dynamic-library C ABI boundaries.
- No in-tree dynamic plugin loader; that is the FNABI's job in `fun`.
