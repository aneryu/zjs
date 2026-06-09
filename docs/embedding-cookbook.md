# Embedding Cookbook

This cookbook shows the public Zig-native embedding shape. It is not a
`libquickjs` C API compatibility guide, and it does not use repository-internal
modules.

## Basic Script Eval

```zig
const std = @import("std");
const zjs = @import("zjs");

const rt = try zjs.JSRuntime.create(allocator);
defer rt.destroy();

const ctx = try zjs.JSContext.create(rt);
defer ctx.destroy();

const result = try ctx.eval("let x = 1 + 2; x;", .{});
defer result.free(rt);
```

Every returned `JSValue` that owns a reference must be released with the same
runtime unless it is transferred into a public handle.

## Eval With Output

```zig
var buffer: [128]u8 = undefined;
var output = std.Io.Writer.fixed(&buffer);

const result = try ctx.eval("print('ok');", .{
    .output = &output,
});
defer result.free(rt);
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
object.free(rt);

var persistent: zjs.JSValue.Persistent = try rt.createPersistentValue(local.get());
defer persistent.deinit();

scope.exit();

const answer = try ctx.getProperty(persistent.get(), "answer");
defer answer.free(rt);
```

Do not store raw `JSValue` fields in long-lived host state unless they are
protected by a persistent handle or another documented public root.

## Host Functions

```zig
const State = struct {
    value: i32,

    fn call(ptr: *anyopaque, call_info: zjs.host.Call) anyerror!zjs.JSValue {
        _ = call_info;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return zjs.JSValue.int32(self.value);
    }
};

var state = State{ .value = 42 };
try ctx.defineGlobalFunction("hostValue", 0, &state, State.call, null);

const result = try ctx.eval("hostValue()", .{});
defer result.free(rt);
```

The callback state pointer is embedder-owned. If it references runtime-owned JS
values, use public handles and destroy them before destroying the runtime.

## Strings And Bytes

`asString()` is a tag check. It does not run JavaScript conversion. Use
`ctx.toOwnedUtf8` for ECMAScript `ToString` semantics.

```zig
const value = try ctx.eval("({ toString() { return 'path'; } })", .{});
defer value.free(rt);

const text = try ctx.toOwnedUtf8(value, allocator);
defer allocator.free(text);
```

Use `JSBytes.Store` for ArrayBuffer backing memory that should be transferred to
the engine without copying.

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

var store = zjs.JSValue.Bytes.Store.owned(backing, .{
    .context = &bytes_state,
    .deinit = BytesState.deinit,
});
errdefer store.release();

const array_buffer = try ctx.arrayBuffer(&store);
defer array_buffer.free(rt);

const bytes = try array_buffer.asBytes(ctx);
const writable = try bytes.sliceMut();
writable[0] = 9;
```

Borrowed byte slices are callback-local. Across callbacks or ticks, keep the JS
value in a persistent handle and call `asBytes(ctx)` again, or copy the bytes.

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
a security boundary for untrusted JavaScript.

## Module Eval

```zig
const result = try ctx.eval(
    \\const value = await Promise.resolve(42);
    \\export { value };
    ,
    .{ .mode = .module },
);
defer result.free(rt);
```
