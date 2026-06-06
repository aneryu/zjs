# ADR 0001: Zig Kernel API, Runtime Boundary, and Runtime Plugin ABI

Status: Accepted

Date: 2026-06-05

## Context

ZJS is a QuickJS C to Zig rewrite. QuickJS remains the semantic reference, while
Zig should provide the portability, safety, and embedding ergonomics.

The project must keep the JavaScript/TypeScript engine core pure. Runtime
features, JSI-style embedding, FFI, event loop integration, `zjs`, and
`run-test262` must be layered above that core.

Previous public API discussions used an `Engine` facade. That direction is no
longer accepted. The future public surface should be a low-level Zig kernel API
with explicit lifecycle and ownership, not a convenience facade that hides
runtime/context/value costs.

`docs/engine-api-v1.md` is therefore legacy direction for future public API
work. This ADR supersedes it for kernel/runtime boundary decisions.

## How To Read This ADR

This ADR records the accepted architecture, not a claim that every API described
below is already complete.

Normative words such as "must" and "must not" define the target boundary for the
accepted design. The implementation is still staged. When deciding whether a
change is correct today, use the boundary rules first, then check the
implementation status near the end of this ADR for what is landed, in progress,
or deferred.

In particular:

- public kernel and runtime names may exist before their full ergonomic surface
  is complete;
- `src/internal_root.zig` may continue to expose internal modules to repository
  code and tests, but it is not the public embedding contract;
- `run-test262` may retain repository-internal test harness glue and explicitly
  listed harness-only shortcuts, but ordinary engine/runtime operations should
  use public kernel/runtime primitives;
- plugin ABI requirements describe the first synchronous dynamic plugin target,
  while async completion, hot reload, process-wide plugin identity, and Proxy
  install targets remain out of scope.

## Decision

### Core Boundary

- `src/core/` remains the engine implementation layer: values, strings, atoms,
  objects, runtime/context, GC, and internal semantic machinery.
- `src/core/` must not depend on host-runtime policy, JSI, FFI, CLI, test262
  harness, plugin loading, or event-loop policy. This does not prohibit
  `src/core/` from containing the engine's `JSRuntime` and `JSContext` types.
- `src/root.zig` re-exports the public kernel API and an explicit public
  runtime namespace. It must not expose `internal` as a public contract.
- `src/internal_root.zig` may aggregate core/frontend/bytecode/exec/builtins for
  repository-owned code, CLI migration work, and tests. New public embedding
  APIs should not be added there.
- `zjs` and `run-test262` are CLI/runtime users, not owners of core concepts.
- `run-test262` may keep test262 harness glue in `src/cli/run_test262.zig`, but
  test262-specific names and shortcuts must not enter the engine core.

### Public Zig Kernel API

Add a public kernel layer:

```text
src/kernel/
  root.zig
  binding.zig
  bytes.zig
  string.zig
  prop_name.zig
  ffi.zig
```

The kernel API is Zig-first. It should use slices, comptime type factories,
typed flags, explicit handles, and inline-friendly stubs. It is not a C ABI.

This file list names the public homes for the API families. It does not mean
each family has the same maturity level. For example, `Object`, `PropNameID`,
`JSString`, `JSBytes`, `binding.JSObject`, and `ffi` can land incrementally, but
their public spelling should stay within this namespace.

The C ABI exists only for dynamic plugin/dylib protocols. Even Zig-written
dynamic libraries must cross that boundary through C calling convention, with
generated Zig stubs/descriptors on both sides.

### Performance Priority

The API is designed for future runtime, JSI, and FFI performance first.
Boundary cleanliness is required, but it must not introduce unnecessary
indirection in hot paths.

Hot paths are operations expected to happen per property access, callback call,
argument conversion, byte/string view access, event-loop callback, or FFI call.
Hot paths should avoid:

- heap allocation;
- atom/string comparison after install;
- broad dynamic dispatch;
- extra `JSValue` wrappers;
- C ABI crossings inside same-build Zig code;
- hidden retain/free traffic.

Cold paths are setup and uncommon error paths: binding install, property-name
interning, class-id allocation, prototype construction, generated stub
registration, dynamic plugin loading, descriptor validation, and exception
materialization.

The intended tradeoff is:

```text
cold path:
- intern names
- allocate class ids
- build prototypes/functions
- validate plugin descriptors
- cache realm-local bindings

hot path:
- pass core JSValue by value
- dispatch by class id / PropNameID
- use generated typed stubs
- borrow JSString/JSBytes views
- allocate only on explicit conversion or error
```

Convenience APIs are acceptable only when they compile down to the same
low-level operations or are clearly marked as cold-path helpers.

### QuickJS Reference Shape

QuickJS is the semantic reference and also gives a useful API shape:

- `JSRuntime`, `JSContext`, `JSValue`, `JSAtom`, and `JSClassID` are explicit
  primitives.
- `JSValue` is passed as a low-level tagged value, with explicit duplication and
  release.
- Property names are interned atoms, so hot property paths do not compare
  strings.
- Host objects use class IDs and opaque payloads, with explicit finalizers and
  GC marking.
- There is no broad `Engine` object on the hot API path.

ZJS should keep that low-level performance shape, but express it with Zig
features: comptime type factories, slices, typed descriptors, generated stubs,
and structured ownership.

### No Engine Facade

Do not introduce a public `Engine` facade as the central API.

The public surface should expose the real primitives:

```zig
zjs.JSRuntime
zjs.JSContext
zjs.JSValue
zjs.Object
zjs.binding.JSObject(T, spec)
zjs.JSString
zjs.JSBytes
zjs.PropNameID
```

This keeps performance costs visible and avoids routing hot JSI/FFI paths
through a broad object facade.

`zjs.Object` is the low-level object handle already exposed by realm/global
helpers, host callback records, and `realm_global` options. Making it explicit
keeps those signatures nameable without promoting a high-level object facade or
requiring embedders to import `internal.core`.

`zjs.JSString` is the phase-1 public spelling for the string view because
`zjs.JSValue` is intentionally the same type as `core.JSValue`. A future nested
spelling such as `zjs.JSValue.String` is allowed only if it is implemented on
`core.JSValue` itself without changing `JSValue` layout or wrapping values.
`zjs.JSString` should remain as the stable alias if the nested spelling is
added.

### JSValue and Value Lifetime

`JSValue` is the public value representation and should remain a small tagged
value. Its layout is not frozen beyond the current phase.

Ownership is not encoded in separate `BorrowedValue` or `OwnedValue` public
types. Callback `this` and `args` are borrowed by contract. Values stored across
callbacks/ticks must be explicitly protected.

Use a consistent value-lifetime namespace. The desired public spelling is:

```zig
zjs.JSValue
zjs.JSValue.Scope
zjs.JSValue.Local
zjs.JSValue.Persistent
zjs.JSValue.Weak
```

If Zig's current type structure makes the nested spelling impractical without
moving these aliases into `core.JSValue`, expose equivalent root aliases first:

```zig
zjs.HandleScope
zjs.LocalHandle
zjs.JSValueHandle
zjs.WeakPersistentValue
```

Do not introduce an owning `Engine` type only to make lifetime names look
tidier. Naming must not change the value layout or add runtime checks in hot
paths.

`BorrowedValue` and `OwnedValue` may exist as internal generator annotations,
but should not be the default public callback surface.

### JSObject Binding API

The default object binding API is:

```zig
const FileObject = zjs.binding.JSObject(FileHandle, .{
    .name = "FileHandle",
    .storage = zjs.binding.Storage.externalPtr(.{ .owner = .js }),
    .properties = zjs.binding.Properties.static(.{
        zjs.binding.method("read", FileHandle.read),
        zjs.binding.method("close", FileHandle.close),
    }),
    .trace = FileHandle.trace,
    .deinit = FileHandle.deinit,
});
```

`JSObject(T, spec)` is a comptime type factory. Instances are still `JSValue`.

Install is explicit:

```zig
try FileObject.install(ctx);
const value = try FileObject.new(ctx, payload);
```

`new(ctx, payload)` must not perform lazy install. It may check installed state.
Generated hot paths may cache a realm-local binding:

```zig
const binding = try FileObject.binding(ctx);
const value = try binding.new(payload);
```

`Binding` is realm-local. It must not be used across contexts/realms or after
runtime destruction.

`install(ctx)` internally has two layers:

```text
runtime state:
- class id
- payload layout
- finalizer/tracer
- generated callback stubs
- static PropNameID values

realm state:
- prototype
- constructor
- method/getter/setter function objects
- optional namespace/global export
```

`install(ctx)` must not automatically export constructors to the global object.
Exports are explicit.

### Object Payload Storage

`JSObject(T, spec)` must make storage explicit:

```zig
.storage = zjs.binding.Storage.inlineValue
.storage = zjs.binding.Storage.externalPtr(.{ .owner = .js })
```

Use `.inline_value` for small value-semantic payloads. Prefer
`.external_ptr(.{ .owner = .js })` for runtime resources, FFI handles, sockets,
file descriptors, event-loop resources, and anything needing a stable address.

Payloads that hold JS values or other GC-visible resources must declare trace
and deinit behavior. Automatic tracing can be added later, but the first
implementation must not pretend it is fully automatic.

### Property Names

Expose `PropNameID` as a public newtype. It may wrap the internal atom id, but
must not expose atom-table details.

Static object properties are interned during install:

```text
install(ctx):
- intern static property names
- store PropNameID values

hot path:
- dispatch by PropNameID
- no string comparison
```

The first implementation only exposes long-lived/static prop names. Scoped
temporary prop names are deferred until dynamic property traps need them.

### Typed Callback Stubs

Default binding should use typed Zig signatures and generated stubs:

```zig
fn read(self: *FileHandle, dst: []u8) !usize
fn write(self: *FileHandle, data: []const u8) !usize
fn close(self: *FileHandle) void
```

Generic callbacks with `args: []const JSValue` remain as escape hatches, not as
the default high-performance API.

Normal return paths must not allocate error messages. Zig errors are converted
to JS exceptions only on the error path:

```text
error.OutOfMemory -> JS OOM
error.TypeError   -> TypeError
error.RangeError  -> RangeError
error.SyntaxError -> SyntaxError
other errors      -> Error(@errorName(err))
```

### String Representation

Core JS strings remain optimized for ECMAScript semantics:

```text
latin1
utf16
slice
rope
```

Do not make JS string UTF-8-only. UTF-8 is a runtime/JSI/FFI boundary concern,
not the canonical core representation.

Public string view API should distinguish type assertion, zero-copy view, and
owned conversion:

```zig
value.asString() ?zjs.JSString
string.units() ?zjs.JSString.Units
string.toOwnedUtf8(allocator) ![]u8
ctx.toString(value) !JSValue
```

Rules:

- `asString()` is a tag/type assertion. It must not run JS semantics, allocate,
  or require `ctx`.
- `units()` returns existing contiguous latin1/utf16 units only. It must not
  flatten, transcode, or allocate.
- `toOwnedUtf8()` is the explicit allocation/transcode path.
- `ctx.toString(value)` is ECMAScript `ToString` and may execute user code.

An ASCII metadata bit is acceptable only if layout measurements prove it does
not noticeably increase per-string memory cost. It should be stored in compact
string metadata, not in GC header flags.

UTF-8-backed JS strings are not first-implementation work. They may be added
later only after benchmarks prove the bridge-path value.

### Bytes and Backing Stores

Large binary or text payloads should use bytes, not JS strings.

Public names:

```zig
zjs.JSBytes
zjs.JSBytes.Store
```

`value.asBytes(ctx)` returns a byte-addressable JS view over ArrayBuffer,
TypedArray, or DataView when valid.

```zig
const bytes = try value.asBytes(ctx);
const ro = try bytes.slice();
const rw = try bytes.sliceMut();
```

Rules:

- `slice()` and `sliceMut()` return borrowed slices.
- Borrowed byte slices are valid only for the current callback/no-detach
  interval.
- Do not save raw `[]u8` across callbacks/ticks.
- Across async/tick, save `JSValue.Persistent` and call `asBytes(ctx)` again,
  or copy the bytes.
- The first implementation does not expose a general `pin()`.

Typed binding maps `[]const u8` and `[]u8` to JS bytes, not JS strings:

```text
[]const u8 -> readable JSBytes
[]u8       -> writable JSBytes
```

JS string UTF-8 callback arguments must be explicit:

```zig
fn open(path: zjs.JSString.Utf8) !File
```

`JSString.Utf8` is callback-scoped. It may be zero-copy for suitable backing or
may use a call-frame scratch buffer. It must not be saved across callbacks.

`JSBytes.Store` creates ArrayBuffer backing memory:

```zig
const store = zjs.JSBytes.Store.owned(bytes, .{
    .context = ctx_ptr,
    .deinit = deinitBytes,
});
const array_buffer = try ctx.arrayBuffer(&store);
```

The first implementation supports:

```text
Store.owned(bytes: []u8, context + deinit)
Store.shared(refcounted store)
```

Do not expose ordinary borrowed backing store as long-lived ArrayBuffer in the
first implementation. It is too easy to create dangling JS memory.

`Store.owned` is released immediately on ArrayBuffer detach, or on GC if still
attached. Shared stores are refcounted, are not detachable, and require an
explicit release/deinit hook. Static or host-owned backing may use an explicit
no-op hook, but the lifetime policy must not be implicit.

### Shared Bytes and Typed Arrays

The first implementation supports byte-level zero-copy only.

Do not automatically map arbitrary `[]T` or `[]const T` to typed arrays. Future
typed-array support should use an explicit API such as:

```zig
zjs.JSValue.TypedArray(T)
```

`[]u8` should not accept SharedArrayBuffer by default. Shared mutable bytes
must be an explicit opt-in type or descriptor because ordinary Zig `[]u8` does
not communicate concurrent mutation.

### FFI and Plugin ABI

Runtime/JSI/high-performance paths use same-build Zig kernel APIs.

Dynamic plugins use C ABI only as a loading and call boundary. The implementation
inside the plugin can be Zig. Generated descriptors and stubs provide Zig views
over C-compatible ABI records.

The dynamic ABI is not the same thing as the internal Zig API. The C ABI layer
is a narrow protocol for loading and calling code across dylib boundaries:

```text
host Zig runtime
  -> generated Zig caller stub
  -> extern C ABI descriptor/trampoline
  -> generated Zig callee stub
  -> plugin Zig implementation
```

A trampoline is a small generated adapter function. It has the ABI-safe calling
convention required at the dynamic boundary, unpacks descriptor records, and
then calls the strongly typed Zig implementation. Same-build runtime/JSI/FFI
code should not go through this trampoline path.

First dynamic ABI versions should be same-version checked, not long-term stable.
Descriptor validation must include at least:

- ABI version;
- target architecture and pointer width;
- `JSValue` layout/version hash;
- descriptor table size and feature flags;
- required callbacks and finalizers;
- ownership/lifetime flags for borrowed, owned, and shared memory.

Do not support arbitrary Zig structs across dylib boundaries. The first dynamic
plugin data model is limited to:

```text
JSValue
borrowed slices via extern descriptors
JSBytes.Store / backing stores
opaque host pointer + type id + finalizer/tracer
PropNameID
```

FFI string and bytes lifetimes must be explicit. Pointer/length returns must not
be guessed:

```zig
zjs.ffi.stringUtf8(.borrow)
zjs.ffi.stringUtf8(.copy)
zjs.ffi.cString(.borrow)
zjs.ffi.cString(.copy)
zjs.ffi.bytes(.copy)
zjs.ffi.bytes(zjs.ffi.Bytes.owned(.{ .deinit = free_bytes }))
zjs.ffi.bytes(.shared)
```

### Runtime Layer and Event Loop

The future runtime is built on top of the kernel API. It may provide modules,
timers, I/O, promises, event-loop integration, loaders, and CLI behavior, but
those policies must not move into `src/core/`.

The engine core may expose primitives needed by a runtime, such as job queues,
contexts, values, and host callback hooks. The runtime layer owns policy:

```text
core:
- JS semantics
- runtime/context storage
- value/object/string/atom machinery
- GC and job-queue primitives

kernel:
- public Zig primitives
- value/string/bytes views
- binding descriptors
- low-level ownership and handles

runtime:
- event loop
- timers and I/O
- module loading policy
- JSI/FFI integration
- platform-specific host services
```

This lets a future `zjs` runtime add substantial JSI and event-loop machinery
without making the engine core depend on that runtime.

First implementation step:

- `src/runtime/` may expose internal runtime policy helpers such as
  `runtime.EventLoop`.
- `zjs` may use those helpers instead of reaching directly into lower-level job
  pumps.
- `src/root.zig` remains kernel-focused; any `runtime` re-export must go
  through an explicit public runtime namespace, not expose `src/runtime/root.zig`
  as a broad public contract.
- `runtime.EventLoop` must not become an `Engine` facade. It is a policy owner
  for host scheduling and integration, while values, contexts, strings, bytes,
  and bindings stay on the kernel/core primitives.

## Runtime Plugin ABI

The runtime plugin ABI is the accepted design for the first dynamic host/runtime
plugin implementation. It deliberately excludes async completion, hot reload,
process-wide dylib caching, plugin identity registries, and Proxy install
targets. Those can be designed later if real use cases justify them.

The first version should be useful but small:

- load one dylib;
- validate one descriptor;
- install synchronous native functions into one ordinary target object;
- expose reference-only opaque host objects;
- keep the dylib alive while installed functions, wrappers, or pending wrapper
  finalizer jobs can still call plugin code.

### Public Runtime API

Expose a small public runtime namespace for runtime-owned policy and plugin
loading:

```zig
pub const runtime = @import("runtime/public.zig");
```

The public plugin API is:

```zig
var plugin = try zjs.runtime.Plugin.load(allocator, path);
defer plugin.deinit();

try plugin.install(ctx, target_value, .{});
```

`Plugin.load(allocator, path)`:

- copies `path` using the caller-provided allocator;
- opens the dylib;
- looks up the descriptor export;
- validates the descriptor;
- does not bind to a `JSRuntime` or `JSContext`;
- does not resolve property names, allocate class IDs, create function objects,
  or perform runtime-specific work;
- does not search plugin paths, read environment variables, canonicalize trust
  policy, or implement package management.

`plugin.install(ctx, target_value, options)` consumes the loaded plugin handle.
A loaded `Plugin` may be installed at most once. To install the same path again,
the caller must call `Plugin.load` again.

Install transfers the dylib handle and descriptor pointer from the loaded
`Plugin` into a runtime-owned `InstalledPlugin`. It does not reopen the path at
install time. This avoids load/install descriptor mismatch and keeps all
installed function pointers tied to the dylib handle that was validated by
`Plugin.load`.

The path itself is copied twice with different lifetimes. `Plugin.load` owns a
caller-allocator path copy so the loaded handle does not borrow the caller's
slice. Successful install copies that path into `ctx.runtime.memory` for the
runtime-owned `InstalledPlugin`, then transfers the dylib handle. After
successful install, `Plugin.deinit()` releases only the consumed shell and the
caller-side path copy. It must not close the transferred dylib handle. If install
fails before transfer, `Plugin.deinit()` closes the caller-owned dylib handle and
releases the caller-side path copy.

The target is a `core.JSValue`. Install validates that it is a plain ordinary
object with ordinary property storage. The first ABI rejects Proxy, module
namespace objects, arrays, functions, arguments objects, typed arrays, and other
exotic or built-in-specialized object classes. Callers that need a namespace
should pass a freshly created ordinary object or another ordinary object they
own.

The same dylib path may be loaded and installed multiple times, even into the
same runtime. Each load/install is independent. The first ABI does not provide a
runtime plugin identity registry, descriptor fingerprint cache, hot reload
semantics, or process-wide dylib cache.

### Descriptor ABI

Plugin descriptors keep `DescriptorHeader`. Header validation is part of the ABI
contract and must check:

- magic;
- ABI version;
- target architecture, OS, ABI, pointer width, and endian;
- `core.JSValue` size, alignment, and layout hash;
- descriptor size;
- required feature flags.

The descriptor ABI is append-only within this version: new fields must be added
at the end, and hosts must read only the fields they understand.

`feature_flags` means the features actually required by the plugin, not all
features supported by the compiling `zjs.ffi` package. Hosts reject descriptors
whose required features are unsupported.

The `zjs.ffi.Plugin(...)` helper must infer required features from entries:

- ordinary Zig-slice bindings require the binding ABI feature;
- host object descriptors require the opaque host object feature;
- prop-name descriptors require the static prop-name feature if they are used.

Manual feature overrides may exist only for advanced or future use cases.

Descriptors may be empty. An empty plugin is valid. Installing an empty plugin
still consumes the loaded `Plugin` handle, closes the loaded dylib during the
successful no-op install path, releases any runtime staging state, and leaves the
target unchanged.

In the first runtime `Plugin.install` ABI, host object descriptors require at
least one binding descriptor in the same installed descriptor. The descriptor ABI
can represent host object descriptors without bindings, but the runtime install
path rejects that shape because opaque wrappers are only created through
binding-local `HostServices.create_opaque_object`. Registering host object class
IDs without any installed binding would create runtime class/prototype state with
no reachable plugin owner.

Descriptor names are for diagnostics, profiling, debug labels, and runtime
identity within log messages. They are not automatically exposed to JavaScript.

### Binding Descriptors

The existing two-argument binding helper remains valid:

```zig
zjs.ffi.binding("add", add)
```

Add an options form with a separate helper name. Zig has no ordinary function
overloading or default parameters, so the API must not document an uncallable
three-argument `binding(...)` spelling:

```zig
zjs.ffi.bindingWithOptions("add", add, .{ .length = 2 })
```

`length` is explicit and defaults to zero. The runtime must not infer JavaScript
function length from the Zig function signature.

There is no separate `asyncBinding` helper in the first ABI. The first plugin
ABI is synchronous. Native code may block if the host chooses to allow that, but
it does not get deferred Promise or cross-thread completion services.

The JavaScript function `name` is the binding name. Internal diagnostic labels
may use `plugin_name.binding_name`.

### Install Semantics

`plugin.install(ctx, target_value, options)` installs binding functions as
ordinary data properties on the caller-provided ordinary target object.

Installed binding properties are:

```text
writable: true
enumerable: true
configurable: true
```

Install does not pollute the global object unless the caller explicitly passes a
global object as the target.

The target does not need to be empty. Install prechecks all binding names and
descriptor compatibility before mutating the target:

- `overwrite = false` is the default;
- with `overwrite = false`, any existing own property with a binding name makes
  install fail before mutation;
- inherited properties do not block installation;
- with `overwrite = true`, install may replace own properties according to
  ordinary object define-property rules, but incompatible non-configurable
  properties or other descriptor conflicts must be rejected before mutation;
- the target must be extensible when install needs to add new properties.

Because the first ABI rejects Proxy and exotic targets, install can use a simple
staging/commit model:

1. Validate descriptor and target.
2. Precheck all target property names.
3. Prepare all runtime records and function values in staging.
4. Define all data properties on the ordinary target while recording the names
   actually defined.
5. Commit staging ownership to installed artifacts only after every define
   succeeds.

On failure before commit, install first removes any ordinary target properties
defined by this install attempt, then releases all staging-owned runtime state.
Because first-version targets are ordinary objects, rollback must not execute
user traps. Install must not leave live plugin refs, rooted function values,
generation-specific hooks, callable half-installed functions, or dangling
callable external host records.

External host function records must either be registered only at commit or be
replaceable with an uncallable tombstone/safe record during rollback. A future
free-list may reuse tombstoned slots, but dangling callable external records are
forbidden.

### Host Native Functions

Host-native functions are externalized. Runtime/host/plugin functions are
registered through external host records and dispatched through the
`external_host` path.

Engine-native helpers that are part of VM semantics remain internal stable IDs.
This includes VM semantic helpers and hot built-in machinery where an external
ABI boundary would add cost without improving host/runtime separation.

The `zjs` CLI is a thin benchmark and smoke-test shell for comparing against
`qjs`. Its default JavaScript-visible host surface should stay minimal:

- `print(...args)`;
- `console.log(...args)`.

It must not imply a product runtime with QuickJS-compatible `std`/`os`, general
timers, Node, Deno, or browser APIs.

`run-test262` installs its own harness globals. It must not depend on the `zjs`
CLI profile.

### Call Frame, Services, and Status

`CallFrame` is the ABI object for one JavaScript-to-plugin call. It is not a VM
bytecode frame.

```zig
pub const CallFrame = extern struct {
    ctx: ?*anyopaque,
    services: ?*const HostServices,
    host_context: ?*anyopaque,
    this_value: core.JSValue,
    args: JSValueSlice,
    result: core.JSValue,
    error_status: Status,
    error_message: BorrowedBytes,
};
```

`ctx` identifies the current `JSContext`. `this_value` and `args` are borrowed
for the duration of the call. `result` is an owned return value when
`error_status == .ok`.

`host_context` is an opaque host field. Runtime code stores the current
`InstalledBinding` or equivalent internal context there. Plugins must not
dereference, compare, store, or interpret it. Services may use it to locate the
current installed plugin.

`HostServices` is an explicit service table with `size` and `feature_flags`. In
the first ABI it exposes only synchronous services needed by installed plugin
functions, such as creating and unwrapping opaque host object wrappers. Plugins
must not call `core.Object.create`, class table APIs, GC payload APIs, or other
engine internals directly.

The first ABI service table includes at least:

```text
create_opaque_object(frame, object, out) -> Status
unwrap_opaque_object(frame, value, expected_type_id, out) -> Status
get_prop_name(frame, index, out) -> Status
```

`create_opaque_object` creates an owned `JSValue` wrapper in `out`, increments
the installed plugin refcount for the wrapper payload, and rejects null native
pointers or `HostTypeId` values not declared by the installed plugin as
`type_error`. `unwrap_opaque_object` returns a call-duration borrowed
`OpaqueHostObject`; it does not transfer ownership or retain the native pointer.
`get_prop_name` returns an install-resolved `PropNameID` by descriptor index and
reports `range_error` when the plugin has no such resolved property name.

The service table is append-only. Plugins that need a service must check table
size, feature flags, and function pointer presence.

The first ABI uses this `Status` enum for call trampolines and service results:

```zig
pub const Status = enum(u32) {
    ok = 0,
    pending_exception = 1,
    out_of_memory = 2,
    type_error = 3,
    range_error = 4,
    unsupported = 5,
    syntax_error = 6,
    generic_error = 7,
    reference_error = 8,
    eval_error = 9,
    uri_error = 10,
    _, // ABI can carry unknown values; runtime maps them to generic_error.
};
```

Synchronous calls may provide an optional `error_message`. The status determines
the JavaScript error class; the message provides the error text. Error messages
are borrowed UTF-8 byte slices, are not NUL-terminated, and are valid only until
the call returns. The runtime must copy or consume the message before releasing
plugin-owned context memory. If message decoding or error construction fails, the
runtime may fall back to the status name.
An error message with `len != 0` and `ptr == null` is invalid and is ignored.

Unknown status values from a dynamic plugin are treated as `generic_error`.
`pending_exception` means the current `JSContext` already has a pending
exception. Runtime preserves that pending value and ignores `error_message` for
that call. If a plugin returns `pending_exception` without a pending exception on
the context, runtime treats it as `generic_error`.
The final call status is the returned `Status` when it is not `ok`; otherwise it
is `frame.error_status`. Raw `CallFrame` trampolines may return `ok` after
setting `frame.error_status` to report a failure.

### Value Ownership

The first plugin ABI may expose `core.JSValue`, but plugins are same-version ABI
artifacts. `core.JSValue` layout is not promised as a long-term binary-stable
plugin ABI.

Synchronous plugin calls follow these ownership rules:

- `this_value` is borrowed for the call duration;
- `args` is a borrowed slice for the call duration;
- `args[i]` values are borrowed for the call duration;
- `result` is an owned `JSValue` when status is `ok`;
- failed calls use `Status` and runtime error mapping;
- on failed calls, runtime ignores `result` and must not release it as an owned
  value.

Plugins must not store borrowed `args` or `this_value` after the call. To keep a
JavaScript value, plugin code must create an owned value on the runtime thread
and ensure it is traced and released by an appropriate runtime-owned object. The
first ABI does not expose a general `JSValue` root-token service.

### Installed Plugin Lifetime

Install transfers the loaded dylib handle into a runtime-owned `InstalledPlugin`:

```zig
const InstalledPlugin = struct {
    runtime: *JSRuntime,
    ref_count: usize,
    lib: std.DynLib,
    // Runtime-owned copy allocated with ctx.runtime.memory.
    path: []u8,
    descriptor: *const zjs.ffi.PluginDescriptor,
    // runtime-local class IDs, prop IDs, bindings, caches...
};
```

Each installed JavaScript function has an external host record whose pointer is
an `InstalledBinding`:

```zig
const InstalledBinding = struct {
    plugin: *InstalledPlugin,
    descriptor: *const zjs.ffi.BindingDescriptor,
};
```

`InstalledPlugin` uses a runtime-thread-only reference count. References are
held by all runtime artifacts that need the dylib to remain loaded:

- installed binding functions;
- live opaque wrappers;
- pending deferred wrapper finalizer jobs;
- committed runtime records that contain plugin function pointers.

The dylib must not be closed until the last dependent artifact releases its
reference. Runtime destruction is a hard cleanup path: remaining installed
artifacts are released even if normal GC did not collect everything first.
During runtime destruction, the runtime must not close an installed plugin dylib
while any live wrapper, installed function, committed runtime record, or pending
wrapper finalizer job can still call descriptor hooks. Pending wrapper finalizer
jobs that own `.js` payloads must either run their plugin finalizer before the
last plugin ref is released or be specified by a later ADR to follow a different
native cleanup policy. The first ABI uses the direct rule: run pending wrapper
payload finalizers before closing the dylib.

There is no runtime plugin identity registry, descriptor fingerprint cache, or
hot-reload model in the first ABI. Loading the same path twice creates two
independent installed plugin records if both handles are installed.

### Opaque Host Object References

The first host object surface is reference-only. JavaScript can hold and pass
opaque wrappers, but wrappers do not expose native fields, methods,
constructors, or raw pointers.

Each successful install that includes host object descriptors and at least one
binding registers new host object class IDs for that plugin's host object
descriptors. Class IDs are not reused across installs in the first ABI. Each
class gets an empty branded prototype. The prototype may expose only minimal
branding such as `Symbol.toStringTag` using the descriptor name.

The installed plugin owns those branded prototype values. Wrapper creation
borrows the plugin-owned prototype and the created wrapper retains it through the
ordinary object prototype slot. When the last installed-plugin reference is
released, runtime releases the prototype values and unregisters the dynamic class
IDs registered by that install.

Example JavaScript shape:

```js
const h = native.open("a.txt")
Object.keys(h)                    // []
Object.prototype.toString.call(h) // "[object FileHandle]"
native.read(h)
```

`OpaqueHostObject.ptr == null` is not a valid wrapper payload. Nullable native
references must be represented as JavaScript `null`.

Each wrapper stores a runtime-owned external class payload:

```zig
const OpaqueWrapperPayload = struct {
    plugin: *InstalledPlugin,
    descriptor: *const zjs.ffi.HostObjectDescriptor,
    object: zjs.ffi.OpaqueHostObject,
};
```

The payload is not stored inline in the wrapper allocation. Wrapper destruction
detaches the external payload into a deferred payload-finalizer job so the job can
keep tracing JavaScript values in the payload until it runs and releases the
payload.

All live wrappers hold an `InstalledPlugin` reference, regardless of ownership
mode.

### Host Object Ownership and Tracing

Host object descriptors support two ownership modes:

```zig
pub const HostObjectOwner = enum(u32) {
    host = 1,
    js = 2,
    _, // ABI can carry unknown values; validation rejects them.
};
```

Validation rules:

- unknown owner values are rejected;
- `HostTypeId` values must be unique within one plugin descriptor;
- `owner = .js` requires a finalizer;
- `owner = .host` must not provide a finalizer;
- both ownership modes may provide a tracer.

When a `.js` wrapper is collected, its deferred finalizer calls the descriptor
finalizer and then releases the wrapper's plugin reference. When a `.host`
wrapper is collected, the finalizer is not called; only wrapper/runtime state and
the plugin reference are released.

Host object finalizers return `void`. They do not propagate errors into the
runtime.

Host object tracers run synchronously during GC marking. A tracer may only mark
JavaScript values through the provided visitor. It must not allocate JavaScript
objects, execute JavaScript, call plugin bindings, release native resources,
modify the JavaScript object graph, or throw.

If wrapper destruction enqueues a deferred payload finalizer job, that pending
job must continue to trace the wrapper payload until the finalizer job runs and
releases the payload. This includes invoking the descriptor tracer for payloads
that may hold JavaScript values.

For `owner = .host` with a tracer, the host owns native lifetime but must keep
`OpaqueHostObject.ptr` trace-safe for as long as any wrapper or pending deferred
finalizer job may trace it. If the underlying native resource is released before
all wrappers are gone, the host must leave a stable tombstone/invalidation state
that the tracer can safely inspect. The first ABI does not provide an explicit
wrapper invalidation service.

Class finalizer/tracer records are runtime stubs. The stub reads the wrapper
payload, then dispatches to the descriptor hooks for that wrapper's
`InstalledPlugin`.

### Host Type IDs and Cross-Plugin Unwrap

The first ABI keeps cross-plugin unwrap by `HostTypeId` because it is valuable
and cheap.

Each opaque wrapper class record or payload metadata must carry a
runtime-internal opaque host object family marker. The marker is not a
JavaScript-visible property.

Unwrap uses:

```text
object is a ZJS opaque host object wrapper
payload.object.type_id == expected HostTypeId
```

It must not require class ID equality or plugin identity equality. This lets
separate plugins share a typed native reference by agreeing on a namespaced
`HostTypeId`.

`HostTypeId.named(name)` remains a 64-bit hash-based type ID in the first ABI.
The runtime accepts the collision risk and relies on namespaced type names and
diagnostics. There is no global type registry in the first version.
Duplicate `HostTypeId` values are allowed across independently installed
plugins, but not within one plugin descriptor because wrapper creation selects a
host object descriptor by type id.

Type errors and diagnostics should include the expected type ID, actual wrapper
type ID, and actual wrapper descriptor name when available. Debug builds may add
extra diagnostics for suspicious cross-plugin type-name mismatches, but the
runtime must not globally reject duplicate `HostTypeId` values in the first ABI.

### Deferred Work

Async plugin completion is not part of the first runtime plugin ABI. A later ADR
may add deferred Promise handles, a thread-safe completion queue, wake callbacks,
runtime destruction cancellation semantics, and async completion callback rules.
Those pieces must not be smuggled into the synchronous first implementation.

Hot reload, process-wide dylib caching, plugin identity/fingerprint registries,
Proxy/exotic install targets, explicit uninstall handles, and general JS value
root-token services are also deferred.

### Runtime Plugin ABI Consequences

The first plugin ABI is intentionally smaller than a complete runtime plugin
system. It favors a short synchronous implementation path and clear ownership
rules over supporting every runtime integration scenario up front.

Benefits:

- No cross-thread runtime lifetime model in the first implementation.
- No async allocator, wake callback, or completion queue.
- No hot-reload or descriptor fingerprint registry.
- No Proxy rollback semantics.
- Dylib lifetime is tied to runtime-owned installed functions, wrappers, and
  pending wrapper finalizer jobs.

Costs:

- Plugin async work must be designed later.
- A loaded plugin handle can install only once.
- Multiple loads of the same path are independent and not deduplicated.
- Each install creates fresh host object class IDs.
- Install targets must be ordinary objects.

### Runtime Plugin ABI Implementation Notes

The complete first synchronous plugin target includes:

- public `zjs.runtime.Plugin`;
- path-copying `Plugin.load(allocator, path)`;
- one-shot `plugin.install(ctx, ordinary_target, options)`;
- install transferring the loaded dylib handle into runtime-owned state;
- externalized host-native functions;
- descriptor validation and feature checks;
- explicit target install with overwrite prechecks;
- simplified staging/commit rollback for runtime-owned artifacts;
- opaque host object wrappers with owner/finalizer/tracer rules;
- cross-plugin unwrap by opaque wrapper family marker and `HostTypeId`;
- installed plugin refcounting across functions, wrappers, and pending wrapper
  finalizer jobs.

## Consequences

This design favors explicit cold-path setup and cacheable hot-path handles over
implicit convenience.

Benefits:

- Keeps the JS/TS engine core clean.
- Preserves JS string semantics and memory efficiency.
- Makes bytes the default zero-copy data path.
- Gives JSI/FFI generated stubs a direct fast path.
- Keeps C ABI limited to dynamic loading protocols.

Costs:

- Public API is lower-level than an `Engine` facade.
- Some common text APIs require explicit `String.Utf8`.
- Async zero-copy bytes require shared stores or later pinning support.
- Boundary cleanup requires adding explicit public primitives for real
  embedding operations instead of reusing internal shortcuts from CLI or
  harness code.

## Implementation Status

Current landed surface:

- `src/root.zig` exposes `kernel` and an explicit `runtime` namespace.
- `src/internal_root.zig` remains the repository-local aggregation point for
  internal modules.
- `src/kernel/root.zig` re-exports the low-level public primitives:
  `JSRuntime`, `JSContext`, `JSValue`, `Object`, handle aliases,
  `RuntimeMemoryUsage`, eval/context options, `PropNameID`, `JSString`,
  `JSBytes`, `binding`, and `ffi`.
- `JSValue.Scope`, `JSValue.Local`, `JSValue.String`, and `JSValue.Bytes` exist
  on the core value type, with root aliases for public spelling.
- `JSBytes.Store` supports owned and shared zero-copy ArrayBuffer backing stores
  with explicit deinit/release semantics.
- Public kernel/root APIs do not expose `NativePin` or general `JSRuntime`
  pinning methods. Core-internal pin helpers remain implementation/test
  machinery, while async zero-copy bytes use shared stores or future design.
- `PropNameID` exists for long-lived/static property names as an ABI-safe
  public token rather than a public `Atom` alias, and `binding.JSObject` stores
  static property names in runtime binding state before realm-local prototype
  installation.
- `JSString` distinguishes tag assertion, contiguous latin1/utf16 unit views,
  callback-scoped UTF-8 borrows, and owned UTF-8 conversion. Slice strings are
  covered as zero-copy `units()` views over existing backing storage.
- `binding.JSObject(T, spec)` exists with explicit storage, install/new/payload
  APIs, realm-local binding lookup, typed method stubs, `JSString.Utf8`, bytes
  arguments, trace hooks, and deinit hooks. Generated method stubs enforce the
  same realm-local prototype brand as `Binding.payload()`, so extracted methods
  do not accept same-runtime wrappers from another realm, and the method runtime
  record roots its realm prototype until the external host record is finalized.
  Binding payload validation treats persistent and weak value handles as
  GC-visible resources that require explicit hook policy rather than relying on
  implicit tracing. Typed method error paths map `TypeError`, `RangeError`,
  and `SyntaxError` to their JavaScript error constructors with empty messages,
  while custom Zig errors become `Error(@errorName(err))`.
- Public context/runtime helpers cover the current CLI migration needs:
  object creation, data property definition, external host function creation,
  string creation, semantic `ToString` to owned UTF-8 conversion, property
  lookup, own descriptor inspection, array inspection/indexed reads, semantic
  numeric conversion, callable/constructor/function-name inspection, public
  function calls, error creation/throwing, exception formatting and error-name
  matching, context policy setters, opcode profiling, memory usage, module
  evaluation helpers, realm creation/global access, explicit-realm script
  evaluation, shared `SharedArrayBuffer` backing-store refs, public
  `ArrayBuffer` detach, event-loop helpers, and worker/Atomics runtime cleanup
  wrappers.
- The core/runtime boundary has a production architecture regression test that
  scans `src/core/**/*.zig` and rejects imports or markers for runtime policy,
  CLI, kernel, plugin, or test262 layers.
- `zjs` and `run-test262` are built against the public `zjs` module for
  public kernel/runtime operations. `zjs` keeps the JavaScript-visible host API
  minimal: `print` and `console.log`; production tests pin `std`, `os`, and
  timer globals as absent from the default global object, including after
  installing `runtime.EventLoop`. The default `print`/`console` output
  functions are installed through `external_host` records; the legacy stable
  `output` host id remains only as an internal compatibility path.
- The synchronous runtime plugin path exists: `zjs.runtime.Plugin.load`,
  one-shot `install`, descriptor validation, external host records,
  `bindingWithOptions`, `CallFrame`, `HostServices`, `Status`, opaque host
  wrappers, same-runtime ordinary target validation, pending wrapper-finalizer
  root tracing, same-runtime opaque wrapper validation, cross-plugin unwrap by
  `HostTypeId`, rejection of host-object-only installs, rollback tombstones,
  empty-descriptor dynamic installs that consume and close the loaded no-op
  handle, plugin-owned host class prototypes with dynamic class cleanup,
  install-resolved `PropNameID` lookup through `HostServices`, and
  installed-plugin refcounting.
  Descriptor validation derives the base binding ABI feature from binding
  tables even for hand-written descriptors, so required feature checks do not
  rely only on the `zjs.ffi.Plugin(...)` helper.
  Plugin call status handling maps no-message status values through the
  matching JavaScript error classes, preserves `pending_exception`, maps unknown
  status values to generic errors, ignores `pending_exception` messages,
  copies valid borrowed error messages before throwing, falls back to
  status-derived ASCII messages for invalid UTF-8, ignores invalid message
  pointers, and treats `out_of_memory` as a non-allocating OOM path even when a
  plugin supplies an error message.
  Runtime destruction finalizes external host records before clearing persistent
  root slots so runtime-owned host records can release rooted values safely.
  Nullable native host references are represented as JavaScript `null` rather
  than opaque wrapper payloads. Opaque host object service failures populate
  copied JavaScript error messages with type-id diagnostics for invalid creation
  and unwrap mismatches.

Current boundary exception:

- `run-test262` still marks `$262.IsHTMLDDA` through a local object shortcut.
  This is intentionally harness/Annex-B-special and should not be promoted to a
  general public embedding API without a separate decision. Ordinary
  `run-test262` object, property, call, string, bytes, realm, module, event-loop,
  SAB broadcast, exception, and cleanup paths use public kernel/runtime helpers.
- `src/exec/call.zig` still contains QuickJS-shaped `std`/`os` host-function
  records and file payload support as legacy internal implementation code. The
  default public `zjs`/embedding global surface does not install those
  namespaces. Treat any future QuickJS-compatible `std`/`os` profile as explicit
  product-runtime work, not as part of the kernel boundary or the benchmark CLI
  contract.

Deferred design work:

- Full ergonomic expansion of `binding.JSObject`, including constructors,
  getters/setters, exports, richer descriptor metadata, and broader typed-array
  support.
- General `JSValue` root-token service for dynamic plugins.
- Async plugin completion, deferred Promise handles, wake callbacks, and
  cross-thread runtime lifetime rules.
- Hot reload, process-wide dylib caching, plugin identity/fingerprint
  registries, explicit uninstall handles, and Proxy/exotic install targets.
- Product-runtime APIs such as QuickJS-compatible `std`/`os`, Node, Deno, or
  browser compatibility profiles, including isolation or removal of the current
  legacy `std`/`os` host-call records if no compatibility profile keeps them.
  These are not implied by `zjs`.

## Non-Goals

- No public `Engine` facade.
- No UTF-8-only core JS string.
- No general borrowed ArrayBuffer backing in the first implementation.
- No arbitrary Zig struct transfer across dylib C ABI.
- No automatic `[]T` typed-array binding in the first implementation.
- No Node.js, Deno, browser, or test262-specific runtime policy in core.
- No async plugin completion in the first runtime plugin ABI.
