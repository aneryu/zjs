# Public API Contract

This document is the active public Zig API authority for embedders. Keep it in
sync with `src/root.zig`, `src/binding/`, and `src/runtime/public.zig`. The
name lists in `src/tests/embedding_examples.zig` are the executable check:
adding or removing a public name must update those arrays in the same
commit. They are not a freeze of the API, and they are not the removed
`check_public_api.zig` / `architecture-update-api-snapshot` tool.

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
- `zjs.context`, `zjs.module`, and `zjs.job` for explicit helper
  families;
- `zjs.runtime` for runtime policy helpers and dynamic plugins;
- `zjs.ffi` for dynamic plugin descriptors and C ABI structures.

The intended groups above are the contract. The embedding snapshot test
lists every current public declaration on those groups. Update the list when
the surface changes.

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

## Known surface deviations

These names are on the public module today and are recorded rather than
hidden:

- `zjs.RuntimeMemoryUsage` is a root export. Embedders read it from
  `JSRuntime.memoryUsage()`.
- `zjs.opcode_profile_build_enabled` reports whether the binary was built
  with per-opcode profiling. The CLI uses it to fail closed on
  `--profile-opcodes`.
- `zjs.ffi.PropNameID` is reachable through the plugin ABI even though the
  embedder root does not export `zjs.PropNameID`. Host Zig code should keep
  using `zjs.host.PropName`.

`JSValue` currently publishes 88 public declarations, including internal
helpers such as `freeObjectAssumeObject` and
`freeObjectAssumeObjectDuringActiveBytecode`. That leak is known debt
(backlog H9). Cookbook and embedding examples must not call those internal
names.

## Runtime And Context

`JSRuntime` owns allocator-backed engine state, atom tables, GC state, public
handle scopes, memory limits, interrupt hooks, opcode-profiling state, and
runtime cleanup. The profiling types are public, but per-opcode counts are
populated only in profiling builds (`zig build zjs-profile` /
`-Dzjs_enable_opcode_profile=true`); default builds fail closed on
`--profile-opcodes`.

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

## Ownership verbs

Public lifetime methods use three verbs:

- `deinit` destroys the receiver. Use it for handle scopes, persistent
  handles, weak handles, and native pins.
- `take` transfers ownership out of the receiver. `JSValue.Persistent.take`
  removes the persistent root and returns the rooted `JSValue`.
- `release` decrements a reference count or drops a borrowed pin. Keep this
  spelling on `zjs.value.Bytes.Store`, `zjs.object.Buffer.BorrowGuard`, and
  `zjs.host.PropName`.

`HandleScope.deinit` is idempotent: an early `scope.deinit()` before a
`defer scope.deinit()` is the supported way to close a scope early.

`JSValue.Persistent.destroy(rt)` is a by-value compatibility wrapper. It
asserts that `rt` matches the handle's runtime, then drops the root. Prefer
`deinit` on a mutable handle. It is not a transfer (`take`) and is not
equivalent to `deinit` as a method signature.

`NativePin` exposes only `deinit`. The previous `NativePin.release`
self-destruct spelling is gone.

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

- `docs/embedding-cookbook.md`;
- `src/tests/embedding_examples.zig`, including the public-surface name
  snapshot (active only when `zjs` is the true public facade);
- public API contract and production failure-path tests in
  `src/tests/engine_production.zig`.
