# API Boundary

ZJS is a QuickJS C to Zig rewrite. QuickJS remains the semantic reference. The
Zig surface should improve embedding ergonomics without moving host/runtime
policy into the JavaScript engine core.

This document is the active boundary guide for ordinary project documentation.

## Layers

`src/core/` is the engine implementation layer:

- runtime and context storage;
- tagged values, strings, atoms, objects, properties, arrays, and GC;
- ECMAScript semantic machinery and job-queue primitives.

`src/root.zig` is the public Zig module imported by embedders as `zjs`. It
re-exports the low-level embedding API and the explicit `zjs.runtime`
namespace.

`src/binding/` contains the public adapter layer for value, string, bytes,
property-name, host-callback, native-object, and FFI descriptors. There is no
landed `src/kernel/` directory; earlier "kernel API" language maps to this
adapter layer plus `src/root.zig`.

`src/runtime/` owns host/runtime policy such as event-loop helpers, module file
graph helpers, cleanup helpers, ArrayBuffer detach integration, and dynamic
runtime plugins.

`src/internal_root.zig` is repository-local aggregation for CLI, test262, and
internal tests. It is not the public embedding contract.

## Core Rules

- `src/core/` must not depend on CLI policy, test262 harness glue, dynamic
  plugin loading, JSI/FFI policy, event-loop policy, or product-runtime APIs.
- Public embedding APIs are added through `src/root.zig`, `src/binding/`, or an
  explicit `zjs.runtime` entrypoint.
- New runtime features should depend on core primitives. Core must not depend
  on runtime features.
- `zjs` and `run-test262` are runtime users. They do not own core concepts.
- test262-only names and harness shortcuts must stay out of core.

`zig build architecture-check --summary all` enforces the dependency boundary
and the public API symbol snapshot.

## Public Shape

The public API is Zig-first, not a C compatibility API. Prefer explicit
runtime/context/value primitives, slices, typed flags, comptime descriptors, and
generated stubs.

The central public primitives are:

```zig
zjs.JSRuntime
zjs.JSContext
zjs.JSValue
zjs.object.Object
zjs.value.String
zjs.value.Bytes
zjs.host.PropName
zjs.host.NativeBinding.JSObject(T, spec)
zjs.ffi
zjs.runtime
```

Do not introduce a public `Engine` facade as the central API. It hides lifetime
and dispatch costs that embedders need to control.

Root aliases beyond the current public snapshot are additive only. Do not
document names as available until they appear in `reports/api/public-symbols.txt`.

## Performance Shape

QuickJS provides the reference shape as well as the semantic reference:

- `JSRuntime`, `JSContext`, `JSValue`, atom-like property names, class IDs, and
  opaque payloads are explicit primitives.
- `JSValue` is passed as a low-level tagged value.
- Hot property and callback paths should not compare strings after setup.
- Host objects use explicit finalizers and GC marking.

ZJS keeps that low-level shape, expressed with Zig types and comptime factories.

Hot paths include property access, callback dispatch, argument conversion,
string/byte view access, event-loop callbacks, and FFI calls. Hot paths should
avoid heap allocation, broad dynamic dispatch, extra value wrappers, hidden
retain/free traffic, and C ABI crossings inside same-build Zig code.

Cold paths include binding install, name interning, class-id allocation,
prototype construction, descriptor validation, dynamic plugin loading, and
exception materialization.

## Runtime Policy

The runtime layer may expose event loops, timers, I/O policy, module file graph
helpers, dynamic plugins, SharedArrayBuffer wake/cleanup hooks, and CLI
integration. Those policies do not move into `src/core/`.

The `zjs` CLI is a thin benchmark and smoke-test shell. Its default
JavaScript-visible host surface is intentionally small:

- `print(...args)`;
- `console.log(...args)`.

It does not imply QuickJS-compatible `std`/`os`, Node, Deno, browser, or timer
profiles. Any future product-runtime profile must be explicit.

`run-test262` installs its own harness globals and may retain harness-only
shortcuts. Ordinary object, property, call, string, bytes, realm, module,
event-loop, exception, and cleanup paths should use public kernel/runtime
helpers.

## Current Exceptions

`run-test262` still marks `$262.IsHTMLDDA` through a local object shortcut. This
is harness and Annex-B specific; it is not a general embedding API.

The QuickJS-shaped `std`/`os` host-function records and their installers have
been deleted (recoverable from git history). Host-provided native functions go
through the `external_host` id and the per-runtime `ExternalRecord` registry;
the internal `HostFunction` enum is reserved for engine-internal callables.
`src/core/` still carries the `std_file` class payload plumbing
(`class.ids.std_file`, `StdFilePayload`); nothing instantiates it from the
engine anymore.

## Non-Goals

- No public `Engine` facade.
- No UTF-8-only internal JavaScript string model.
- No automatic `std`/`os`, Node, Deno, browser, or timer profile in the default
  CLI/embedding global.
- No arbitrary Zig struct transfer across dynamic-library C ABI boundaries.
- No async runtime plugin completion in the first plugin ABI.
