# Runtime Plugin ABI

This document defines the first dynamic runtime plugin ABI. The ABI is useful
but intentionally small: load one dynamic library, validate one descriptor,
install synchronous native functions into one ordinary target object, expose
reference-only opaque host objects, and keep the library alive while installed
artifacts may still call plugin code.

The public entrypoint is:

```zig
var plugin = try zjs.runtime.Plugin.load(allocator, path);
defer plugin.deinit();

try plugin.install(ctx, target_value, .{});
```

## Scope

The first ABI includes:

- dynamic-library loading through `Plugin.load`;
- one-shot `plugin.install`;
- descriptor validation and feature checks;
- synchronous native bindings;
- explicit ordinary-object install target;
- install staging, commit, and rollback;
- external host records for installed functions;
- `zjs.ffi.CallFrame`, `zjs.ffi.HostServices`, and `zjs.ffi.Status`;
- opaque host object wrappers with finalizer and tracer rules;
- cross-plugin unwrap by `HostTypeId`.

Out of scope:

- async plugin completion;
- deferred Promise handles;
- cross-thread completion queues;
- hot reload;
- process-wide dynamic-library caching;
- plugin identity/fingerprint registries;
- explicit uninstall handles;
- Proxy or exotic install targets;
- general JS value root-token services.

## Load And Install

`Plugin.load(allocator, path)` copies `path`, opens the dynamic library, finds
the descriptor export, validates the descriptor, and returns a loaded handle. It
does not bind to a runtime or context and does not allocate runtime-specific
class IDs, property names, prototypes, or functions.

`plugin.install(ctx, target_value, options)` consumes the loaded handle. A
loaded `Plugin` may be installed at most once. To install the same file again,
call `Plugin.load` again.

Successful install transfers the dynamic-library handle and descriptor pointer
into runtime-owned `InstalledPlugin` state. After that transfer,
`Plugin.deinit()` releases only the consumed shell and caller-side path copy; it
must not close the transferred library handle.

If install fails before transfer, `Plugin.deinit()` closes the caller-owned
library handle and releases the caller-side path copy.

## Target Object

The install target must be an ordinary object from the same runtime. The first
ABI rejects Proxy, module namespace objects, arrays, functions, arguments
objects, typed arrays, and other exotic or built-in-specialized classes.

Install defines binding functions as ordinary data properties:

```text
writable: true
enumerable: true
configurable: true
```

`overwrite = false` is the default. With that default, any existing own property
with a binding name makes install fail before mutation. Inherited properties do
not block install. With `overwrite = true`, install may replace compatible own
properties according to ordinary object define-property rules.

Install must precheck compatibility before mutation, stage runtime records and
function values, define target properties, and commit ownership only after every
define succeeds. On failure before commit, rollback removes properties defined
by the failed attempt and releases all staging-owned runtime state.

Rollback must not leave live plugin references, rooted function values,
callable half-installed functions, or dangling callable external host records.

## Descriptor ABI

Plugin descriptors include a validated header. Header validation must check:

- magic;
- ABI version;
- target architecture, OS, ABI, pointer width, and endian;
- `core.JSValue` size, alignment, and layout hash (including the packed-value
  encoding revision when applicable);
- descriptor size;
- required feature flags.

The descriptor ABI is append-only within this version. Hosts read only fields
they understand.

`feature_flags` means features required by the plugin, not every feature known
to the compiling `zjs.ffi` package. Hosts reject descriptors whose required
features are unsupported.

The `zjs.ffi.Plugin(...)` helper should infer required features from entries:
binding descriptors require the binding ABI feature, opaque host object
descriptors require the opaque-host-object feature, and static prop-name
descriptors require the static prop-name feature.

Descriptors may be empty. Installing an empty plugin is a successful no-op that
still consumes and closes the loaded handle.

Host object descriptors require at least one binding descriptor in the same
installed descriptor. Opaque wrappers are created through binding-local
`HostServices.create_opaque_object`, so host-object-only installs would create
unreachable runtime class/prototype state.

Descriptor names are diagnostics and profiling labels. They are not
automatically exposed to JavaScript.

## Binding Descriptors

The base binding helper is:

```zig
zjs.ffi.binding("add", add)
```

The options form is:

```zig
zjs.ffi.bindingWithOptions("add", add, .{ .length = 2 })
```

Zig has no ordinary function overloading or default parameters, so do not
document an uncallable three-argument `binding(...)` spelling.

Function `length` is explicit and defaults to zero. Runtime must not infer
JavaScript function length from the Zig signature.

There is no separate async binding helper in the first ABI.

## Call Frame And Services

`zjs.ffi.CallFrame` is the ABI object for one JavaScript-to-plugin call. It is
not a VM bytecode frame. `this_value` and `args` are borrowed for the duration
of the call. `result` is an owned `JSValue` when the final status is `ok`.

`ctx` remains pointer-sized and opaque for ABI stability, but its referent is a
typed context view borrowed only for the duration of the callback. Zig plugins
must obtain that view through `frame.borrowContext()` or use the already-typed
`ZigCall.ctx`; they must not cast `frame.ctx` directly. The borrowed view is not
an owner: it must not be stored beyond the callback, released, or used to
recover an outer `zjs.JSContext` wrapper. This ABI does not provide a way to
retain the view, so code that needs context state after return must arrange a
separate explicitly owned host lifetime instead.

`host_context` is an opaque runtime-owned field. Plugins must not dereference,
compare, store, or interpret it.

`zjs.ffi.HostServices` is an append-only service table with `size` and
`feature_flags`. Plugins that need a service must check table size, feature
flags, and function pointer presence.

The first service table includes:

```text
create_opaque_object(frame, object, out) -> Status
unwrap_opaque_object(frame, value, expected_type_id, out) -> Status
get_prop_name(frame, index, out) -> Status
```

Plugins must not call engine internals directly to create objects, allocate
class IDs, mutate GC payloads, or resolve property names.

## Status And Errors

`zjs.ffi.Status` carries synchronous call and service results:

```zig
ok
pending_exception
out_of_memory
type_error
range_error
unsupported
syntax_error
generic_error
reference_error
eval_error
uri_error
```

Unknown status values from a dynamic plugin map to `generic_error`.

`pending_exception` means the current context already has a pending exception.
Runtime preserves that pending value and ignores `error_message`. If a plugin
returns `pending_exception` without an actual pending exception, runtime treats
it as `generic_error`.

Error messages are borrowed UTF-8 byte slices valid only until the call
returns. Runtime copies or consumes the message before releasing plugin-owned
context memory. Invalid UTF-8 falls back to a status-derived ASCII message.
`out_of_memory` uses a non-allocating OOM path even if a plugin supplies a
message.

On failed calls, runtime ignores `result` and must not release it as an owned
value.

## Installed Lifetime

Installed plugin state is runtime-owned and reference-counted on the runtime
thread. It separates artifact owners, registered class-definition generations,
and active callback pins. Artifacts that need the dynamic library to remain
loaded include:

- installed binding functions;
- live opaque wrappers;
- pending wrapper finalizer jobs;
- committed runtime class records that dispatch plugin-backed payload hooks.

Install, class-slot cleanup, unregistration, and unload must execute on the
owning Runtime thread. A checked foreign install/unload attempt returns
`error.WrongRuntimeThread` before consuming the loaded handle, allocating
Runtime storage, changing a realm slot, or publishing unload state. Plugin
trampolines, payload finalizers/tracers, and the eventual dynamic-library close
also run on that owner thread. Callback reentry is allowed; lifetime and class
generation pins, rather than a structural lock, reconcile it. Runtime never
holds a waiter or mutation mutex across JavaScript, GC, plugin, or DSO
callbacks.

Dropping the last artifact first prevents new binding/wrapper entries, clears
the plugin class prototype slot from every live or constructing realm, and
requests class unregistration. Existing calls, finalizers, tracers, and queued
payload callbacks retain their exact class generation until they return.
Unregistration publishes an empty class record before releasing its plugin
definition owner. Only after every definition and active callback pin drains
does runtime close the dynamic library, exactly once.

A binding record retired by its own trampoline is therefore destroyed only
after that trampoline and any borrowed error-message handling return. Likewise,
the last opaque wrapper may initiate unload from its deferred finalizer, but the
library stays open until the deferred callback returns and its class-generation
pin completes. Runtime destruction follows the same ordered path rather than
closing a library around outstanding hooks.

## Opaque Host Objects

Opaque host objects are reference-only. JavaScript can hold and pass wrappers,
but wrappers do not expose native fields, constructors, methods, or raw
pointers.

`OpaqueHostObject.ptr == null` is not a valid wrapper payload. Nullable native
references must be represented as JavaScript `null`.

Host object ownership modes:

```zig
host
js
```

Validation rules:

- unknown owner values are rejected;
- `HostTypeId` values must be unique within one plugin descriptor;
- `owner = .js` requires a finalizer;
- `owner = .host` must not provide a finalizer;
- both ownership modes may provide a tracer.

When a `.js` wrapper is collected, the deferred finalizer calls the descriptor
finalizer and releases the plugin reference. When a `.host` wrapper is
collected, only wrapper/runtime state and the plugin reference are released.

Tracers run synchronously during GC marking. They may only mark JavaScript
values through the provided visitor. They must not allocate JavaScript objects,
execute JavaScript, call plugin bindings, release native resources, modify the
JavaScript graph, or throw.

Wrapper destruction may enqueue a deferred payload-finalizer job. That pending
job must continue tracing the wrapper payload until it runs and releases the
payload.

## Cross-Plugin Unwrap

Unwrap checks that a value is a ZJS opaque host object wrapper and that
`payload.object.type_id == expected HostTypeId`. It does not require class ID
equality or plugin identity equality.

`HostTypeId.named(name)` remains a 64-bit hash-based type ID in the first ABI.
There is no global type registry. Duplicate IDs are allowed across independently
installed plugins but not within one descriptor.

Diagnostics should include expected type ID, actual wrapper type ID, and actual
wrapper descriptor name when available.
