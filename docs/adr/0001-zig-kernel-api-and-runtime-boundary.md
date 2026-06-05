# ADR 0001: Zig Kernel API and Runtime Boundary

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

## Decision

### Core Boundary

- `src/core/` remains the engine implementation layer: values, strings, atoms,
  objects, runtime/context, GC, and internal semantic machinery.
- `src/core/` must not depend on host-runtime policy, JSI, FFI, CLI, test262
  harness, plugin loading, or event-loop policy. This does not prohibit
  `src/core/` from containing the engine's `JSRuntime` and `JSContext` types.
- `src/root.zig` should eventually re-export the public kernel API and stop
  exposing `internal` as a public contract.
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
  ffi.zig       later
```

The kernel API is Zig-first. It should use slices, comptime type factories,
typed flags, explicit handles, and inline-friendly stubs. It is not a C ABI.

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
zjs.binding.JSObject(T, spec)
zjs.JSString
zjs.JSBytes
zjs.PropNameID
```

This keeps performance costs visible and avoids routing hot JSI/FFI paths
through a broad object facade.

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
and deinit behavior. Automatic tracing can be added later, but the first phase
must not pretend it is fully automatic.

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

First phase only exposes long-lived/static prop names. Scoped temporary prop
names are deferred until dynamic property traps need them.

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

UTF-8-backed JS strings are not first phase work. They may be added later only
after benchmarks prove the bridge-path value.

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
- First phase does not expose a general `pin()`.

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

First phase supports:

```text
Store.owned(bytes: []u8, context + deinit)
Store.shared(refcounted store)
```

Do not expose ordinary borrowed backing store as long-lived ArrayBuffer in the
first phase. It is too easy to create dangling JS memory.

`Store.owned` is released immediately on ArrayBuffer detach, or on GC if still
attached. Shared stores are refcounted and are not detachable.

### Shared Bytes and Typed Arrays

First phase supports byte-level zero-copy only.

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

Do not support arbitrary Zig structs across dylib boundaries. First phase
dynamic plugin data model is limited to:

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
- `src/root.zig` remains kernel-focused; `runtime` is not re-exported there
  until there is an explicit public runtime API decision.
- `runtime.EventLoop` must not become an `Engine` facade. It is a policy owner
  for host scheduling and integration, while values, contexts, strings, bytes,
  and bindings stay on the kernel/core primitives.

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
- Initial CLI migration remains incomplete until kernel APIs cover enough
  surface.

## Implementation Phases

Phase 1:

- Create `src/kernel/root.zig`.
- Re-export kernel public API from `src/root.zig`.
- Add `PropNameID` and static prop-name API.
- Add `JSString` view shell. Do not force `JSValue.String` until it can be
  implemented in `core.JSValue` without changing `JSValue` layout.
- Add `JSBytes` and `JSBytes.Store` shell.
- Do not migrate `zjs` or `run-test262` yet.

Phase 2:

- Add `binding.JSObject(T, spec)`.
- Add static typed callback stubs.
- Add `String.Utf8` callback scratch conversion.
- Add `JSBytes.Store.owned -> ArrayBuffer`.

Phase 3:

- Move runtime and CLI bindings onto kernel APIs.
- Gradually remove `internal` imports from `run_test262.zig`.

Phase 4:

- Add FFI descriptors and plugin C ABI stubs.
- Add dynamic plugin validation and version checks.

## Non-Goals

- No public `Engine` facade.
- No UTF-8-only core JS string.
- No general borrowed ArrayBuffer backing in phase 1.
- No arbitrary Zig struct transfer across dylib C ABI.
- No automatic `[]T` typed-array binding in phase 1.
- No Node.js, Deno, browser, or test262-specific runtime policy in core.
