# Public API Contract

This document is the active public Zig API authority for embedders. Keep it in
sync with `src/root.zig`, `src/binding/`, `src/runtime/public.zig`, and
`reports/api/public-symbols.txt`.

## Public Entry

Embedders import the root module:

```zig
const zjs = @import("zjs");
```

The stable public groups are:

- `zjs.JSRuntime`, `zjs.JSContext`, `zjs.JSValue`;
- `zjs.value` for value constructors, handle aliases, string views, and byte
  views;
- `zjs.object` for low-level object helpers;
- `zjs.host` for host callbacks, native bindings, native classes, and property
  names;
- `zjs.context`, `zjs.module`, `zjs.job`, and `zjs.error` for explicit helper
  families;
- `zjs.runtime` for runtime policy helpers and dynamic plugins;
- `zjs.ffi` for dynamic plugin descriptors and C ABI structures.

The complete declaration snapshot is `reports/api/public-symbols.txt` and is
checked by `zig build architecture-check --summary all`.

## Compatibility Rules

- Do not remove a public symbol without a migration note and release decision.
- Do not add public aliases that imply a different ownership model.
- Do not expose repository-internal modules through `src/root.zig`.
- Additive aliases are allowed when they preserve layout, ownership, and
  semantics.
- New public helper families should have cookbook or production tests when they
  carry ownership, allocation, or runtime policy.

Current public spellings matter. For example, the public string/bytes spellings
are `zjs.value.String` and `zjs.value.Bytes`, with nested aliases on
`zjs.JSValue`. The public property-name token is `zjs.host.PropName`. Root
spellings such as `zjs.JSBytes` or `zjs.PropNameID` are intentionally not part
of the current contract.

## Runtime And Context

`JSRuntime` owns allocator-backed engine state, atom tables, GC state, public
handle scopes, memory limits, interrupt hooks, opcode profiling state, and
runtime cleanup.

`JSContext` owns a realm and exposes public helpers for:

- script and module eval;
- global object access;
- global host function installation;
- property get/set and own descriptor inspection;
- function calls;
- string conversion;
- ArrayBuffer and byte-store creation;
- throwing and formatting exceptions.

Returned owning values must be released with the same runtime unless ownership
is transferred into a documented public handle or engine object.

Some low-level runtime helper APIs still accept the public context's `.core`
field while the adapter layer is being completed. Do not add new public
core-typed APIs without documenting the migration shape.

## Values And Handles

`JSValue` is the public value representation and remains a small tagged value.
Its layout is not promised as a long-term binary-stable plugin ABI.

Callback `this` and argument values are borrowed for the duration of the call.
Host state that keeps JavaScript values across callbacks, ticks, or object
lifetimes must use one of the documented handle types:

```zig
zjs.JSValue.Scope
zjs.JSValue.Local
zjs.JSValue.Persistent
zjs.JSValue.Weak
zjs.value.Scope
zjs.value.Local
zjs.value.Persistent
zjs.value.Weak
```

Do not store raw `JSValue` fields in long-lived host state unless they are
protected by a persistent handle or another documented public root.

## Strings, Bytes, And Property Names

`zjs.value.String` is a JavaScript string view. Tag checks, contiguous
latin1/utf16 unit views, callback-scoped UTF-8 borrows, and owned UTF-8
conversion are distinct operations. `asString()` is a tag check; it does not run
ECMAScript `ToString`.

`zjs.value.Bytes` is the public byte view for ArrayBuffer and typed-array
backing memory. `zjs.value.Bytes.Store` supports owned and shared stores with
explicit deinit/release semantics. Borrowed byte slices are callback-local; keep
a JS value rooted and reacquire the view, or copy the bytes, when data must
survive across callbacks or ticks.

`zjs.host.PropName` is the public long-lived/static property-name token.
Embedding code should use it instead of exposing atom internals.

## Host Callbacks

Host callbacks are explicit:

```zig
zjs.host.Call
zjs.host.Function
zjs.host.Finalizer
zjs.host.FunctionOptions
```

Callback state pointers are embedder-owned. If the state references
runtime-owned JavaScript values, it must own public handles and release them
before the runtime is destroyed.

## Native Objects

`zjs.host.NativeBinding.JSObject(T, spec)` is the public native object binding
factory. It provides explicit storage, install/new/payload APIs, typed method
stubs, static property names, trace hooks, and deinit hooks.

Binding install is realm-local. Generated method stubs enforce the same
realm-local prototype brand as payload lookup, so extracted methods do not
accept wrappers from another realm merely because they share a runtime.

Payloads that contain persistent or weak handles are GC-visible resources and
must use explicit hook policy.

## Runtime Namespace

`zjs.runtime` exposes runtime policy helpers only:

- event-loop helpers;
- module file graph helpers;
- SharedArrayBuffer wake/cleanup helpers;
- ArrayBuffer detach helper;
- `zjs.runtime.Plugin` and `zjs.runtime.PluginInstallOptions`.

It must not become an `Engine` facade and must not re-export internal runtime
modules as public contract.

## Evidence

The current public API contract is covered by:

- `reports/api/public-symbols.txt`;
- `zig build architecture-check --summary all`;
- `docs/embedding-cookbook.md`;
- `src/tests/embedding_examples.zig`;
- public API contract and production failure-path tests in
  `src/tests/engine_production.zig`.
