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
- `zjs.native` for native (host) functions callable from JavaScript:
  `managed`, `leaf`, `leafWithState`, `Call`, `Spec`, `Options`;
- `zjs.CallSite` for repeated native -> JS calls to one function;
- `zjs.PropertySite` for repeated host reads/writes of one property name;
- `zjs.value` for value constructors, handle aliases, string views, and byte
  views;
- `zjs.object` for low-level object helpers;
- `zjs.host` for native object bindings (`NativeBinding`, `NativeObject`),
  property names (`PropName`), and the CLI-shaped global helpers
  (`defineScriptArgs`, `defineArgvGlobals`, `evalGlobalScriptSource` /
  `evalGlobalScriptValue`);
- `zjs.context`, `zjs.module`, and `zjs.job` for explicit helper
  families;
- `zjs.runtime` for runtime policy helpers (event loop, module file graph,
  SharedArrayBuffer wake/cleanup, ArrayBuffer detach).

The intended groups above are the contract. The embedding snapshot test
lists every current public declaration on those groups. Update the list when
the surface changes.

Removed 2026-09-06 (NB2 phase A3, design ruling D8, no adapter): the host
callback family `zjs.host.Call` / `Function` / `Finalizer` /
`FunctionOptions`, `JSContext.defineGlobalFunction` /
`createExternalFunction`, the `zjs.ffi` plugin ABI, and
`zjs.runtime.Plugin` / `PluginInstallOptions` together with the
`src/runtime/plugin.zig` loader. The replacement is `zjs.native` below; the
dynamic-plugin successor is the FNABI (`docs/fun-native-plugin-design.md`),
which is built on `zjs.native` and lives in the `fun` repository.

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
- `zjs.native.NativeEntry` (and `zjs.native.JSContext` / `JSValue`) are
  re-exported by the native module because `Call.entry` is typed by it. The
  entry is VM-private and immutable; embedders read nothing from it and
  never construct one. Registration goes through `Spec` / `Options` only.

`JSValue` currently publishes 80 public declarations, including internal
helpers that are not part of the embedding contract (the value-representation
decoders such as `catchTarget` and `isTracerOwned`). That leak is known debt
(backlog H9); the count is pinned in the embedding surface test so that an
expansion is visible. Cookbook and embedding examples must not call those
internal names.

`JSRuntime` currently publishes 162 public declarations. Its count is pinned
beside the `JSValue` count in the embedding surface test, so any addition or
removal requires an explicit public-contract update.

## Runtime And Context

`JSRuntime` owns allocator-backed engine state, atom tables, GC state, public
handle scopes, memory limits, interrupt hooks, opcode-profiling state, the
native-entry arena (see Native Functions), and runtime cleanup. The profiling
types are public, but per-opcode counts are populated only in profiling
builds (`zig build zjs-profile` / `-Dzjs_enable_opcode_profile=true`);
default builds fail closed on `--profile-opcodes`.

`JSContext` owns a realm and exposes public helpers for:

- script and module eval;
- global object access;
- native function creation and installation (`createFunction` /
  `defineFunction`, taking a `zjs.native.Spec`);
- property get/set and own descriptor inspection (`zjs.PropertySite` for
  repeated access to one name);
- function calls (`callFunction`; `zjs.CallSite` for repeated calls);
- string conversion;
- ArrayBuffer and byte-store creation;
- throwing and formatting exceptions.

Values returned to the host are plain `JSValue`s. Under the tracing collector
there is no release call: a value is alive while it is reachable from a
rooted place, and the host's own native stack (locals, argument arrays,
`callFunction` arguments) is such a place through the conservative stack
scan. Values that the host stores in heap memory or keeps across calls must
go into a documented handle (see Values And Handles).

### JSContext host ownership

`JSContext.destroy` (and the binding facade's `destroy` / `deinit`) releases
**the caller's host reference**, matching QuickJS `JS_FreeContext`. It does
not destroy a realm by itself. Auto-init property slots, native-function
`RealmRef`s, function bytecode, jobs, and realm-record payloads hold their
own retains; those keep the `JSContext` allocated until they drop.

Who owns that host reference:

- `JSContext.create` / `createWithOptions` returns it to the caller. Destroy
  that returned context exactly once.
- `JSContext.createRealm` (and `$262.createRealm()`) transfers the child's
  create reference onto the realm-record `JSValue`. Free that value. Do not
  call `JSContext.destroy` on the child.
- `zjs.native.Call.ctx` is a non-owning facade (`JSContext.borrowCore`) for
  the callee's realm. It is valid for the duration of the call only; never
  `destroy` / `deinit` it and never store it.

`JSRuntime.contextForGlobal`, `firstContext`, and the `context_head` list are
lookups, not ownership transfers. Do not walk `context_head` or resolve a
global to a context and `destroy` it unless that pointer is the host
reference you created and still own. A second host `destroy` (the createRealm
child, or `destroy` twice on a `create` realm) undercounts remaining realm
edges. Cycle GC then hits `gcDecrefChildInline` (`rc > 0`) on `visitRealm`.

`RealmRef.retain` / `deinit` is the explicit extra host-reference pair
(`JS_DupContext` / `JS_FreeContext`). Use that when you need another owner,
not `contextForGlobal` plus `destroy`.

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

The rooting rules of the native boundary (design contract C2) are:

- a `JSValue` that lives in native stack memory -- a local, a stack array
  passed as `args`, a value returned from `eval` / `callFunction` /
  `CallSite.call` and held in a local -- is covered by the conservative
  native-stack scan for as long as it is there;
- a `JSValue` array that the host keeps in **heap** memory is not scanned.
  Pin every element in a `Persistent`, or keep the values in a JS Array that
  is itself pinned by one `Persistent`, before the host can trigger GC
  (any call into the engine can);
- cross-call retention (a callback stored for later, a cached object, host
  object state) uses `Persistent` (or `Weak` when the host must not keep the
  object alive).

## Ownership verbs

Public lifetime methods use three verbs:

- `deinit` destroys the receiver. Use it for handle scopes, persistent
  handles, weak handles, native pins, `CallSite`, and `PropertySite`.
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

## Native Functions (`zjs.native`)

A native function is a plain Zig function wrapped at comptime into a
`callconv(.c)` thunk; the thunk is the `target` of one immutable
`NativeEntry`, and the VM dispatches an embedder function exactly like a
builtin (`docs/perf/native-boundary-design.md` §3, §9). There is no
registry lookup, per-call arena, handle scope, or marshalling framework on
the call path.

Three generators produce a `zjs.native.Spec` (a comptime constant; it may sit
in a comptime table):

```zig
zjs.native.managed(f)        // f: fn (*zjs.native.Call) JSValue  or  fn (*Call) E!JSValue
zjs.native.leaf(f)           // f over primitives: fn (i32, i32) i32, fn (f64) f64, ...
zjs.native.leafWithState(f)  // f: fn (*State, f64) void, fn (*State, i32) i32
```

`JSContext.createFunction(name, spec, options)` creates the function object
in the context's realm (or `options.realm_global`) and returns it;
`JSContext.defineFunction(name, spec, options)` additionally installs it on
that realm's global as a writable, non-enumerable, configurable data
property. Both take `zjs.native.Options`:

- `length`: JS `length`. Defaults to the leaf's parameter count; `0` for
  managed functions;
- `state`: opaque pointer handed back as `Call.state(T)` (managed) or as the
  `*State` first parameter (`leafWithState`);
- `finalize`: `fn (*anyopaque) void`, run once with `state` when the
  **runtime** is destroyed (not when a context is destroyed, not when the
  function object is collected). Requires `state`;
- `with_prototype`: also create a `prototype` object whose `constructor`
  points back to the function;
- `realm_global`: the realm to create the function in.

### Managed calls

`zjs.native.Call` is built on the C stack by the thunk and never outlives
the call. It carries `ctx` (non-owning realm facade), `this`, `argv` /
`argc`, `entry`, and `func_obj` (the callee object), plus the helpers
`arg(i)` (`undefined` past `argc`), `args()`, `state(T)`, `runtime()`,
`global()`, `output()` (the host writer of the current invocation, if any),
and `throwError(name, message)` / `throwTypeError` / `throwRangeError`,
which install the JS exception and return `error.JSException`.

Error mapping at the seam (`builtin_dispatch.embedderErrorToValue`): a
function returning `JSValue` cannot fail; a function returning `E!JSValue`
may return any error set. `error.JSException` means "already thrown" and
propagates the pending exception. `OutOfMemory`, `Interrupted`, `Timeout`,
`StackOverflow`, `ProcessExit` and `UnhandledPromiseRejection` are engine
sentinels and are materialized by the engine. `TypeError`, `RangeError`,
`SyntaxError`, `ReferenceError`, `EvalError` and `URIError` become an error
of that class with an empty message; any other error name becomes
`Error: <name>`. If an exception is already pending when a non-sentinel
error is returned, the pending exception wins. A native function must never
unwind through the VM in any other way.

Managed calls are visible in `Error().stack` as `at name (native)`
(contract C7). A native call does not poll the interrupt handler by itself
(C8); JS loops and function entries do.

### Leaf calls

`leaf` / `leafWithState` accept only the FNABI v1 signature shapes
(`fn () void`, `fn (i32) i32`, `fn (i32, i32) i32`, `fn (f64) f64`,
`fn (f64, f64) f64`, `fn (f64) void`, `fn (bool) bool`,
`fn (*State, f64) void`, `fn (*State, i32) i32`); any other signature is a
compile error, never a silent generic fallback. The VM performs the canonical
marshal checks before the target runs: an `i32` parameter accepts an int32
(or a float64 holding an in-range integer other than `-0`), an `f64`
parameter accepts a number, boolean, `null`, or `undefined` (NaN); anything
else, including a missing `i32` argument, throws a `TypeError` at the call
site. The target never sees a `JSValue`, must not allocate, must not call
back into the engine, and cannot throw (contract C5); it does not appear in
`Error().stack`.

### Ownership and lifetimes

- `state` is embedder-owned and must stay valid until the runtime is
  destroyed (or, without `finalize`, until the last call has returned and
  the function can no longer be reached from JS). `finalize` is the
  ownership hand-off for `state`; it runs on the runtime thread during
  `JSRuntime.destroy` (destroying a context or collecting the function
  object does not run it). If `state` references
  runtime-owned JavaScript values, it must own public handles and release
  them before the runtime is destroyed.
- Each registration allocates one `NativeEntry` in the runtime's entry arena.
  Entries are immutable and are never freed before the runtime dies
  (contract C9); the function objects that reference them are ordinary
  GC-managed objects.
- `Call.ctx` is the realm the function was created in (contract C6), which
  may differ from the realm of the caller.
- Arguments are the VM's operand window and stay alive for the duration of
  the call; values the function creates are covered by the conservative
  stack scan while they live in locals; only cross-call retention needs a
  `Persistent` (contract C2, see Values And Handles).
- Entries and function objects are bound to their runtime; call them only
  on the runtime's thread (contract C10).

## Native -> JS Calls

`JSContext.callFunction(callee, args, .{ .this_value, .output, .realm_global })`
is the one-shot form: the callee, receiver, and `args` are borrowed for the
duration of the call, and the result is returned as a plain `JSValue`. A
thrown JS exception surfaces as `error.JSException` with the exception
pending on the context (`takePendingException`,
`pendingExceptionMatchesErrorName`); an out-of-memory exception surfaces as
`error.OutOfMemory`.

`zjs.CallSite` is the resolved-once form for a host that calls one JS
function repeatedly (event handlers, comparators, plugin callbacks):
`CallSite.init(ctx, callee, .{ .this_value, .output })` pins the callee and
receiver in the runtime's persistent root ledger and resolves the target
once; `call` / `call0..call2` / `callWithThis` pay only the per-call work
(one interrupt poll, frame push, dispatch loop); `deinit` releases the pins.
A site may be used from the embedder's own stack and from inside a native
function that JS called; callees that are not plain bytecode functions of
the context's Realm (bound functions, proxies, natives, generators, other
Realms) still work through the authoritative root path. Arguments passed to
`call` are borrowed for the duration of the call exactly as for
`callFunction`; the receiver given to `callWithThis` must stay reachable
from the host for that call. Host -> JS -> native -> JS recursion uses the
C stack and is bounded by the runtime's native stack limit.

## Host-Side Property Access

`JSContext.getProperty(obj, "field")` interns the name and walks the object
on every call; it stays the one-shot form. `zjs.PropertySite` is the
resolved-once form for a host that reads or writes ONE property name
repeatedly (an ECS system reading `entity.x`, a serializer walking records,
a plugin reading a config field):

```zig
var site = try zjs.PropertySite.init(ctx, "field");   // or initAtom(ctx, prop_name)
defer site.deinit();
const v = try site.get(obj);
try site.set(obj, zjs.value.int32(7));
```

`init` interns the name and pins it for the host; `deinit` releases the pin
and must run before the context (or its runtime) is destroyed. `initAtom`
takes a `zjs.host.PropName` the host already interned and takes its own pin,
so the caller may release its own id independently.

Internally a site is one `PropSiteCache` entry -- the same struct and the
same capture core the VM's W1 `get_field` / `put_field` sites use -- guarded
by the receiver's `Shape.identity`. A hit is an identity compare and an
indexed load for an own data slot, a class and holder re-check plus an
indexed load one prototype link up, or (for a native K3 getter on a class
prototype) a direct typed getter call. Everything else -- a non-object
receiver, a Proxy, an exotic own property, a JS accessor, a polymorphic
receiver set past the four-miss budget -- takes the ordinary property walk,
so a site is always correct and only sometimes fast.

Invalidation is implicit and needs no host action: `Shape.identity` is a
monotonic per-runtime counter that takes a fresh value at shape creation and
before every in-place mutation of the guarded state (property append,
property delete, flag update, prototype swap), and identities are never
reused, so a recycled Shape address can never re-match a stale site. Adding
a property to the receiver, deleting the cached one, freezing the object, or
swapping its prototype simply makes the next access guard-miss and
re-capture.

`get` returns the property value as a plain `JSValue` with the usual rooting
rules (Values And Handles). `set` is the strict `Set`: a write the object
refuses -- read-only own or inherited data property, non-extensible
receiver, accessor without a setter -- raises the TypeError instead of
silently dropping the write, surfacing as `error.TypeError` with the
exception pending on the context. A site holds no `JSValue` and is therefore
not a GC root of anything; it is bound to the context it was created for and
to the runtime's thread.

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
- ArrayBuffer detach helper.

It must not become an `Engine` facade and must not re-export internal runtime
modules as public contract. There is no in-tree dynamic plugin loader: the
FNABI loader (`docs/fun-native-plugin-design.md`) lives in the `fun`
repository and registers its functions through `zjs.native`.

## Evidence

The current public API contract is covered by:

- `docs/embedding-cookbook.md`;
- `src/tests/embedding_examples.zig`, including the public-surface name
  snapshot (active only when `zjs` is the true public facade), the native
  function contract test (arguments, receiver, error mapping, finalizer
  timing), the CallSite cookbook test, and the PropertySite cookbook test
  (own hit, shape-change re-capture, prototype holder, native getter,
  refused write, polymorphic retirement);
- public API contract and production failure-path tests in
  `src/tests/engine_production.zig`;
- `tools/perf/native_boundary/zjs_boundary_bench.zig`, the boundary
  microbench written against this surface only.
