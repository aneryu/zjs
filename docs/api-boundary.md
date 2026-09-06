# API Boundary

ZJS is a QuickJS C to Zig rewrite. ECMA-262 as validated by test262 is the
semantic authority; QuickJS is the comparison reference (owner ruling
2026-08-22). The
Zig surface should improve embedding ergonomics without moving host/runtime
policy into the JavaScript engine core.

This document is the active boundary guide for ordinary project documentation.

## Layers

`src/core/` is the engine implementation layer:

- runtime and context storage;
- tagged values, strings, atoms, objects, properties, arrays, and GC;
- ECMAScript semantic machinery and job-queue primitives;
- `NativeEntry` (`native_entry.zig`), the single immutable native-function
  record that builtins, host functions, and native accessors resolve to.

`src/root.zig` is the public Zig module imported by embedders as `zjs`. It
re-exports the low-level embedding API and the explicit `zjs.runtime`
namespace.

`src/binding/` contains the public adapter layer for value, string, bytes,
property-name, native-function (`native.zig`: `zjs.native`), native-object
(`binding.zig`), and context/CallSite (`context.zig`) surfaces. There is no
landed `src/kernel/` directory; earlier "kernel API" language maps to this
adapter layer plus `src/root.zig`.

`src/runtime/` owns host/runtime policy. On disk it holds the event loop
(`event_loop.zig`) and the facade files (`public.zig`, `root.zig`). Module
file graph helpers, Atomics waiter cleanup, and ArrayBuffer detach
integration are implemented in `src/exec/` and re-exported through
`runtime/root.zig`; they are runtime *surface*, not runtime-owned files.
The former dynamic plugin loader (`plugin.zig`, the `zjs.ffi` ABI) was
deleted 2026-09-06; its successor, the FNABI loader, lives in the `fun`
repository and is an embedder of `zjs.native` like any other.

`src/internal_root.zig` is repository-local aggregation for CLI, test262, and
internal tests. It is not the public embedding contract.

## Core Rules

- `src/core/` must not depend on CLI policy, test262 harness glue, plugin
  loaders, JSI/FFI policy, event-loop policy, or product-runtime APIs.
- Public embedding APIs are added through `src/root.zig`, `src/binding/`, or an
  explicit `zjs.runtime` entrypoint.
- New runtime features should depend on core primitives. Core must not depend
  on runtime features.
- `zjs` and `run-test262` are runtime users. They do not own core concepts.
- test262-only names and harness shortcuts must stay out of core.

`tools/architecture/check_deps.js` enforces the dependency boundary. Checkpoint
and the production gate both run it.

## Public Shape

The public API is Zig-first, not a C compatibility API. Prefer explicit
runtime/context/value primitives, slices, typed flags, comptime descriptors, and
generated stubs.

The central public primitives are:

```zig
zjs.JSRuntime
zjs.JSContext
zjs.JSValue
zjs.CallSite
zjs.native.managed / leaf / leafWithState
zjs.native.Call / Spec / Options
zjs.object.Object
zjs.value.String
zjs.value.Bytes
zjs.host.PropName
zjs.host.NativeBinding.JSObject(T, spec)
zjs.runtime
```

Do not introduce a public `Engine` facade as the central API. It hides lifetime
and dispatch costs that embedders need to control.

Root aliases are additive only. Do not document names as available until they
appear in `docs/public-api-contract.md`. JSContext host-reference ownership
(`create` vs `createRealm`, and the ban on `destroy` via `contextForGlobal` /
`context_head`) is documented there, not here.

## Performance Shape

QuickJS provides the reference performance shape:

- `JSRuntime`, `JSContext`, `JSValue`, atom-like property names, class IDs, and
  opaque payloads are explicit primitives.
- `JSValue` is passed as a low-level tagged value.
- Hot property and callback paths should not compare strings after setup.
- Host objects use explicit finalizers and GC marking.

ZJS keeps that low-level shape, expressed with Zig types and comptime factories.

Hot paths include property access, callback dispatch, argument conversion,
string/byte view access, event-loop callbacks, and JS <-> native calls. Hot
paths should avoid heap allocation, broad dynamic dispatch, extra value
wrappers, hidden retain/free traffic, and C ABI crossings inside same-build
Zig code.

Cold paths include binding install, name interning, class-id allocation,
prototype construction, descriptor validation, native function registration,
and exception materialization.

## Runtime Policy

The runtime layer may expose event loops, timers, I/O policy, module file graph
helpers, SharedArrayBuffer wake/cleanup hooks, and CLI integration (the
module-graph, wake/cleanup, and detach helpers are implemented in `src/exec/`
and re-exported). Those policies do not move into `src/core/`.

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
-- resolves to one immutable `NativeEntry` (`src/core/native_entry.zig`,
design `docs/perf/native-boundary-design.md` §3-§5). The entry is an
offset-pinned `extern struct` carrying the code pointer, the call kind
(`managed`, `leaf`, constructor, getter/setter, ...), the leaf signature id,
the arity, the optional `state` pointer, and JIT effect annotations. The VM
switches on the kind once per call and never branches on where the entry
came from: there is no registry, no id space, and no string lookup on the
call path. Builtin entries are comptime rodata; host entries are allocated
in the runtime's entry arena by `JSContext.createFunction` and are never
freed before the runtime dies (retiring one rewrites its kind to a tombstone
in place).

`zjs.native` (`src/binding/native.zig`) is the only public way to make an
entry: `managed(f)` wraps `fn (*zjs.native.Call) E!JSValue` into a
`callconv(.c)` thunk (the call receives the callee realm, `this`, and a view
of the VM operand window; Zig errors map to JS exceptions at the seam);
`leaf(f)` / `leafWithState(f)` infer an FNABI v1 primitive signature from
the Zig function type, and the VM marshals the arguments so the target never
sees a `JSValue`. `JSContext.defineFunction` / `createFunction` turn the
resulting `Spec` plus per-registration `Options` (`length`, `state`,
`finalize`, `with_prototype`, `realm_global`) into a function object. The
reverse direction, native -> JS, is `JSContext.callFunction` (one-shot) and
`zjs.CallSite` (resolved once, called repeatedly); both enter the same
resident dispatch loop a builtin callback uses. The rooting, exception,
realm, backtrace, interrupt, entry-lifetime, and thread contracts are
C1-C10 in the design document and are restated for embedders in
`docs/public-api-contract.md`.

## Current Exceptions

`run-test262` still marks `$262.IsHTMLDDA` through a local object shortcut. This
is harness and Annex-B specific; it is not a general embedding API.

The QuickJS-shaped `std`/`os` host-function records and their installers have
been deleted (recoverable from git history). The internal `HostFunction`
enum is reserved for engine-internal callables; host-provided functions are
`NativeEntry`s created through `zjs.native`, never members of that enum.
`src/core/` still carries the `std_file` class payload plumbing
(`class.ids.std_file`, `StdFilePayload`); nothing instantiates it from the
engine anymore.

## Non-Goals

- No public `Engine` facade.
- No UTF-8-only internal JavaScript string model.
- No automatic `std`/`os`, Node, Deno, browser, or timer profile in the default
  CLI/embedding global.
- No arbitrary Zig struct transfer across dynamic-library C ABI boundaries.
- No in-tree dynamic plugin loader; that is the FNABI's job in `fun`.
