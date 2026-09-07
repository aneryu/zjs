# Embedding Cookbook

This cookbook shows the public Zig-native embedding shape. It is not a
`libquickjs` C API compatibility guide, and it does not use repository-internal
modules.

The examples below are covered by `src/tests/embedding_examples.zig`.

## Basic Script Eval

```zig
const std = @import("std");
const zjs = @import("zjs");

const rt = try zjs.JSRuntime.create(allocator);
defer rt.destroy();

const ctx = try zjs.JSContext.create(rt);
defer ctx.destroy();

const result = try ctx.eval("let x = 1 + 2; x;", .{});
```

A returned `JSValue` is a plain value; there is no release call. It stays
alive while it is reachable from a rooted place, and a local on the host's
own stack is one (the collector scans the native stack conservatively). See
Rooting Rules below for everything that is not a stack local.

## Eval With Output

```zig
var buffer: [128]u8 = undefined;
var output = std.Io.Writer.fixed(&buffer);

const result = try ctx.eval("print('ok');", .{
    .output = &output,
});
```

The default global host surface is intentionally small: `print` and
`console.log` are available, but Node/Deno/browser globals are not installed by
default.

## Host-Held Values

Use a handle scope for values that must stay alive during a bounded host call.
Use a persistent handle for values kept across callbacks, ticks, or host object
state.

```zig
const object = try ctx.eval("({ answer: 42 })", .{});

var scope: zjs.JSValue.Scope = rt.enterHandleScope();
defer scope.deinit();

const local: zjs.JSValue.Local = try scope.localDup(object);

var persistent: zjs.JSValue.Persistent = try rt.createPersistentValue(local.get());
defer persistent.deinit();

scope.deinit();

const answer = try ctx.getProperty(persistent.get(), "answer");
```

Do not store raw `JSValue` fields in long-lived host state unless they are
protected by a persistent handle or another documented public root.

## Native Functions

A native function is a plain Zig function; `zjs.native.managed` wraps it at
comptime into the thunk the VM dispatches like a builtin. `state` is an
opaque pointer the function reads back with `call.state(T)`; `finalize` is
the ownership hand-off for that state and runs once when the runtime is
destroyed.

```zig
const Combiner = struct {
    factor: i32,
    calls: usize = 0,
    saw_object_this: bool = false,
    finalized: *bool,

    fn call(c: *zjs.native.Call) anyerror!zjs.JSValue {
        const self = c.state(Combiner);
        self.calls += 1;
        if (c.this.isObject()) self.saw_object_this = true;
        if (c.argc < 2) return error.TypeError;
        const a = c.arg(0).asInt32() orelse return error.TypeError;
        const b = c.arg(1).asInt32() orelse return error.TypeError;
        if (a < 0) return error.RangeError;
        return zjs.JSValue.int32(self.factor * (a + b));
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.finalized.* = true;
    }
};

var finalized = false;
var state = Combiner{ .factor = 2, .finalized = &finalized };
_ = try ctx.defineFunction("hostCombine", zjs.native.managed(Combiner.call), .{
    .length = 2,
    .state = @ptrCast(&state),
    .finalize = Combiner.finalize,
});

const sum = try ctx.eval("hostCombine(19, 23) + 16", .{}); // 100
const method = try ctx.eval("({ combine: hostCombine }).combine(1, 2)", .{}); // 6, this = the object
const caught = try ctx.eval("try { hostCombine(-1, 0) } catch (e) { e.name }", .{}); // "RangeError"
```

What the example relies on:

- `c.arg(i)` is `undefined` past `argc` (JS semantics); `c.args()` is the
  argument window as a slice, borrowed for this call. `c.this` is the
  receiver, `c.ctx` a non-owning facade for the function's realm (do not
  destroy or store it), `c.output()` the host writer of the current
  invocation.
- Returning a Zig error becomes a catchable JS exception: `TypeError`,
  `RangeError`, `SyntaxError`, `ReferenceError`, `EvalError`, `URIError`
  map to that class; `error.JSException` means the function already threw
  (`c.throwTypeError("...")` / `c.throwError(name, message)` install the
  exception and return it); `OutOfMemory`, `Interrupted`, `Timeout`,
  `StackOverflow` are engine sentinels; any other error name becomes
  `Error: <name>`. A function that returns plain `JSValue` cannot fail.
- `defineFunction` installs the function on the global as a writable,
  non-enumerable, configurable property and returns it. `createFunction`
  builds the same function object without installing it -- attach it
  yourself with `ctx.defineDataProperty(obj, "method", fn_value, .{})` when
  the function is a method of a host object; it receives that object as
  `c.this`.
- `state` must stay valid until the runtime is destroyed; `finalize` runs on
  the runtime thread during `rt.destroy()` (destroying the context or
  collecting the function object does not run it). If `state` holds JavaScript
  values, keep them in `Persistent` handles and `deinit` them in `finalize`.

## Typed Leaf Functions

When a function only takes and returns primitives, register it as a leaf.
The signature is inferred from the Zig function type and must be one of the
FNABI v1 shapes (`fn (i32, i32) i32`, `fn (i32) i32`, `fn (f64) f64`,
`fn (f64, f64) f64`, `fn (f64) void`, `fn (bool) bool`, `fn () void`, and
with state `fn (*State, f64) void`, `fn (*State, i32) i32`); anything else
is a compile error. The VM checks the argument tags and boxes the result;
the target never sees a `JSValue`, must not allocate or call back into the
engine, and cannot throw.

```zig
fn add(a: i32, b: i32) i32 {
    return a +% b;
}

fn half(x: f64) f64 {
    return x / 2;
}

const TickState = struct {
    ticks: i64 = 0,
    step: i32 = 1,

    fn tick(self: *TickState, i: i32) i32 {
        self.ticks += 1;
        return i +% self.step;
    }
};

_ = try ctx.defineFunction("add", zjs.native.leaf(add), .{});     // add.length === 2
_ = try ctx.defineFunction("half", zjs.native.leaf(half), .{});
var counter = TickState{ .step = 10 };
_ = try ctx.defineFunction("tick", zjs.native.leafWithState(TickState.tick), .{
    .state = @ptrCast(&counter),
});

const sum = try ctx.eval("add(40, 2)", .{});          // 42
const ticked = try ctx.eval("tick(1) + tick(2)", .{}); // 23, counter.ticks == 2
```

Marshal rules: an `i32` parameter accepts an int32 (or a float64 holding an
in-range integer other than `-0`); an `f64` parameter accepts any number,
boolean, `null`, or `undefined` (NaN). Anything else -- `add("1", 2)`, a
missing `i32` argument, an object -- throws a `TypeError` at the call site
before the target runs. Leaf calls are not visible in `Error().stack`.

## Calling JavaScript From The Host

`ctx.callFunction(callee, args, .{ .this_value, .output })` is the one-shot
call. A host that calls the same function many times keeps a
`zjs.CallSite`: the callee class check, inline eligibility, and realm match
are done once in `init`, which also pins the callee and receiver; each
`call` pays only the interrupt poll, the frame push, and the dispatch loop.

```zig
const add_one = try ctx.eval("(function (x) { return x + 1; })", .{});
var site = try zjs.CallSite.init(ctx, add_one, .{});
defer site.deinit();

var total: i32 = 0;
var i: i32 = 0;
while (i < 1000) : (i += 1) {
    const result = try site.call1(zjs.JSValue.int32(i));
    total += result.asInt32() orelse return error.Unexpected;
}
// total == 500500

// Receiver override for one call.
const get_v = try ctx.eval("(function () { return this.v; })", .{});
var method_site = try zjs.CallSite.init(ctx, get_v, .{});
defer method_site.deinit();
const holder = try ctx.eval("({ v: 7 })", .{});
const seven = try method_site.callWithThis(holder, &.{});

// A thrown JS exception surfaces as error.JSException, pending on the context.
const thrower = try ctx.eval("(function () { throw new RangeError('boom'); })", .{});
var throw_site = try zjs.CallSite.init(ctx, thrower, .{});
defer throw_site.deinit();
try std.testing.expectError(error.JSException, throw_site.call0());
if (try ctx.pendingExceptionMatchesErrorName("RangeError")) {
    _ = ctx.takePendingException();
}
```

A site can also be used from inside a native function that JS called
(JS -> native -> the site -> JS), for example a host function that forwards
to a stored callback:

```zig
const Forwarder = struct {
    site: *zjs.CallSite,

    fn call(c: *zjs.native.Call) anyerror!zjs.JSValue {
        return c.state(Forwarder).site.call1(c.arg(0));
    }
};

var forwarder = Forwarder{ .site = &site };
_ = try ctx.defineFunction("viaSite", zjs.native.managed(Forwarder.call), .{
    .length = 1,
    .state = @ptrCast(&forwarder),
});
```

Callees that are not plain bytecode functions of the context's realm (bound
functions, proxies, native functions, generators, functions from another
realm) work through the same API on the general path. `call` / `call0..2` /
`callWithThis` and `callFunction` borrow `args` and the receiver for the
duration of the call; the result is a plain `JSValue`. Host -> JS -> native
-> JS recursion uses the C stack and is bounded by the runtime's native
stack limit.

## Reading And Writing One Property Repeatedly

`ctx.getProperty(obj, "field")` interns the name and walks the object every
time. A host that touches the same field in a loop keeps a
`zjs.PropertySite`: the name is interned and pinned once in `init`, and each
access is guarded by the receiver's shape identity, exactly like a
`get_field` inline-cache site inside the VM.

```zig
var field = try zjs.PropertySite.init(ctx, "field");
defer field.deinit();                       // before ctx/rt are destroyed

const record = try ctx.eval("({ x: 1, field: 3 })", .{});
var total: i64 = 0;
var i: usize = 0;
while (i < 1000) : (i += 1) {
    total += (try field.get(record)).asInt32() orelse return error.Unexpected;
}
try field.set(record, zjs.JSValue.int32(11));

// An already-interned name works too, and keeps its own pin.
const name = try zjs.host.PropName.internStatic(rt, "field");
defer name.release(rt);
var same = try zjs.PropertySite.initAtom(ctx, name);
defer same.deinit();
```

What is cached, and what is not: an own data slot, a data slot one prototype
link up (so `p.field` inherited from `P.prototype` is still one load), and a
native K3 getter on a class prototype (`world.time`). A non-object receiver,
a Proxy, an exotic own property, a JS accessor, or a receiver set that keeps
changing shape falls back to the ordinary walk -- a site is always correct,
and only sometimes fast.

Nothing invalidates a site by hand. A shape takes a fresh identity before
every mutation of the layout it guards, so adding a property to the
receiver, deleting the cached one, freezing it, or swapping its prototype
just makes the next access miss and re-capture:

```zig
try ctx.defineDataProperty(record, "later", zjs.JSValue.int32(1), .{});
// the next get() re-captures against the new layout and still answers 11
```

`set` is the strict assignment: a write the object refuses (read-only
property, non-extensible receiver, accessor without a setter) raises a
TypeError rather than dropping the write silently, and surfaces as
`error.TypeError` with the exception pending on the context. A site holds no
`JSValue`, so it roots nothing; the receiver and the value `get` returns
follow the ordinary rooting rules below.

## Rooting Rules

The collector is a tracing, non-moving collector with a conservative scan of
the host's native stack (native-boundary contract C2). The rules for a host
holding `JSValue`s are:

- **Native stack memory is scanned.** A `JSValue` in a local, in a stack
  array passed as `args`, or held in a local after `eval` / `callFunction`
  / `CallSite.call` returns is alive for as long as it is there. Arguments
  a native function receives (`c.argv`, `c.this`) are the VM's operand
  window and stay alive for the whole call; values the function creates are
  covered while they sit in its locals.
- **Heap memory is not scanned.** A `JSValue` array the host allocates on
  the heap (an `ArrayList` of callbacks, a struct field, a slice handed to
  `callFunction` from heap storage) must be pinned before anything can run
  GC -- and any call into the engine can. Pin each element in a
  `zjs.JSValue.Persistent`, or keep the values in a JS Array that is itself
  held by one `Persistent`.
- **Cross-call retention uses `Persistent`.** A callback stored for a later
  tick, a cached object, host object state, or anything referenced from a
  native function's `state` goes into a `Persistent` (or a `Weak` when the
  host must not keep the object alive) and is released with `deinit` before
  the runtime is destroyed. A `CallSite` pins its callee and receiver for
  you until `deinit`.
- A handle scope (`rt.enterHandleScope()` / `scope.localDup`) is the bounded
  form for a batch of values inside one host operation.

## Strings And Bytes

`asString()` is a tag check. It does not run JavaScript conversion. Use
`ctx.toOwnedUtf8` for ECMAScript `ToString` semantics.

```zig
const value = try ctx.eval("({ toString() { return 'path'; } })", .{});

const text = try ctx.toOwnedUtf8(value, allocator);
defer allocator.free(text);
```

Use `zjs.value.Bytes.Store` for ArrayBuffer backing memory that should be
transferred to the engine without copying.

```zig
const BytesState = struct {
    allocator: std.mem.Allocator,

    fn deinit(context: ?*anyopaque, bytes: []u8) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.allocator.free(bytes);
    }
};

var bytes_state = BytesState{ .allocator = allocator };
const backing = try allocator.alloc(u8, 4);
@memcpy(backing, &[_]u8{ 1, 2, 3, 4 });

var store = zjs.value.Bytes.Store.owned(backing, .{
    .context = &bytes_state,
    .deinit = BytesState.deinit,
});
errdefer store.release();

const array_buffer = try ctx.arrayBuffer(&store);

const bytes = try array_buffer.asBytes(ctx);
const writable = try bytes.sliceMut();
writable[0] = 9;
```

Borrowed byte slices are callback-local. Across callbacks or ticks, keep the JS
value in a persistent handle and call `asBytes(ctx)` again, or copy the bytes.
The store's `deinit` runs when the ArrayBuffer is collected (or at runtime
teardown), not when the host's last reference goes away.

## Construction With Limits

```zig
const rt = try zjs.JSRuntime.createWithOptions(allocator, .{
    .stack_size = 512 * 1024,
    .gc_threshold = 2 * 1024 * 1024,
});
defer rt.destroy();

rt.setMemoryLimit(64 * 1024 * 1024);
```

Memory limits and stack limits are reliability controls for trusted embeddings.
They are not a hostile-code sandbox.

## Interrupts

```zig
const State = struct {
    budget: usize,

    fn stop(_: *zjs.JSRuntime, ctx: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (self.budget == 0) return true;
        self.budget -= 1;
        return false;
    }
};

var state = State{ .budget = 10_000 };
rt.setInterruptHandler(State.stop, &state);
defer rt.setInterruptHandler(null, null);
```

The interrupt hook is cooperative. It is a progress guard for trusted code, not
a security boundary for untrusted JavaScript. JS loops and function entries
poll it; a native function call itself does not, and a `CallSite.call` polls
once on entry.

## Module Eval

```zig
const result = try ctx.eval(
    \\const value = await Promise.resolve(42);
    \\export { value };
    ,
    .{ .mode = .module },
);
```
