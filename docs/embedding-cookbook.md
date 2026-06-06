# Embedding Cookbook

## Basic Script Eval

```zig
const std = @import("std");
const zjs = @import("zjs");

const rt = try zjs.JSRuntime.create(std.heap.page_allocator);
defer rt.destroy();

const ctx = try zjs.JSContext.create(rt);
defer ctx.destroy();

const result = try ctx.eval("let x = 1 + 2; x;", .{});
defer result.free(rt);
```

## Eval With Output

```zig
var buffer: [128]u8 = undefined;
var output = std.Io.Writer.fixed(&buffer);

const result = try ctx.eval("print('ok');", .{
    .output = &output,
});
defer result.free(rt);
```

## Construction With Limits

```zig
const rt = try zjs.JSRuntime.create(allocator);
defer rt.destroy();

rt.setMemoryLimit(64 * 1024 * 1024);
rt.setStackSize(512 * 1024);
rt.setGCThreshold(2 * 1024 * 1024);
```

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
a security sandbox.
