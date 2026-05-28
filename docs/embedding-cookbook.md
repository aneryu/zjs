# Embedding Cookbook

## Basic Script Eval

```zig
const std = @import("std");
const engine = @import("quickjs_zig_engine");

var js = try engine.Engine.init(std.heap.page_allocator);
defer js.deinit();

var result = try js.evalHandle("let x = 1 + 2; x;");
defer result.deinit();
```

## Eval With Output

```zig
var buffer: [128]u8 = undefined;
var output = std.Io.Writer.fixed(&buffer);

var result = try js.evalHandleWithOptions("print('ok');", .{
    .output = &output,
});
defer result.deinit();
```

## Construction With Limits

```zig
var js = try engine.Engine.initWithOptions(.{
    .allocator = allocator,
    .limits = .{
        .memory_bytes = 64 * 1024 * 1024,
        .stack_bytes = 512 * 1024,
        .gc_threshold_bytes = 2 * 1024 * 1024,
    },
});
defer js.deinit();
```

## Module Eval

```zig
var result = try js.evalModuleHandle(
    \\const value = await Promise.resolve(42);
    \\export { value };
);
defer result.deinit();
```

## Interrupts

```zig
const State = struct {
    budget: usize,

    fn stop(_: *engine.core.Runtime, ctx: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (self.budget == 0) return true;
        self.budget -= 1;
        return false;
    }
};

var state = State{ .budget = 10_000 };
js.runtime.setInterruptHandler(State.stop, &state);
defer js.runtime.setInterruptHandler(null, null);
```

The interrupt hook is cooperative. It is a progress guard for trusted code, not
a security sandbox.
