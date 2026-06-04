const std = @import("std");
const engine = @import("quickjs_zig_engine");

const InterruptState = struct {
    hits: usize = 0,

    fn stop(_: *engine.core.JSRuntime, ctx: ?*anyopaque) bool {
        const self: *InterruptState = @ptrCast(@alignCast(ctx.?));
        self.hits += 1;
        return true;
    }
};

test "production embedding can own JSRuntime and JSContext directly" {
    var rt: engine.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    var ctx: engine.JSContext = undefined;
    try ctx.init(&rt, .{});
    defer ctx.deinit();

    const value = try ctx.eval("1 + 1", .{});
    defer ctx.freeValue(value);
    try std.testing.expectEqual(@as(?i32, 2), value.asInt32());

    const object = try ctx.eval("({ answer: 42 })", .{});
    var handle = try ctx.takeValueHandle(object);
    defer handle.deinit();
    try std.testing.expect(handle.get().isObject());

    const global = try ctx.globalObject();
    try std.testing.expect(global.is_global);
}

test "production embedding API applies limits and releases eval handles" {
    var js = try engine.Engine.initWithOptions(.{
        .allocator = std.testing.allocator,
        .limits = .{
            .stack_bytes = 128 * 1024,
            .gc_threshold_bytes = 32 * 1024,
        },
    });
    defer js.deinit();

    try std.testing.expectEqual(@as(usize, 128 * 1024), js.runtime.stackSize());
    try std.testing.expectEqual(@as(usize, 32 * 1024), js.runtime.gcThreshold());

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var result = try js.evalHandleWithOptions("print(1 + 2);", .{ .output = &output });
    defer result.deinit();

    try std.testing.expect(result.get().isUndefined());
    try std.testing.expectEqualStrings("3\n", output.buffered());
}

test "production embedding lifecycle deinitializes repeated script and module evals" {
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        var js = try engine.Engine.init(std.testing.allocator);
        defer js.deinit();

        var script_result = try js.evalHandle(
            \\let values = [];
            \\for (let i = 0; i < 8; i++) values.push({ i });
            \\values.map(v => v.i).join(",");
        );
        defer script_result.deinit();
        try std.testing.expect(script_result.get().isUndefined());

        var module_result = try js.evalModuleHandle(
            \\const value = await Promise.resolve(42);
            \\export { value };
        );
        defer module_result.deinit();
    }
}

test "production embedding memory limit reports allocation failure without leaking" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    js.runtime.setMemoryLimit(js.runtime.memory.allocated_bytes);
    defer js.runtime.setMemoryLimit(null);

    try std.testing.expectError(error.OutOfMemory, js.eval("({ payload: new Array(32).fill('x') });"));
}

test "production embedding interrupt handler aborts unbounded execution" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var state = InterruptState{};
    js.runtime.setInterruptHandler(InterruptState.stop, &state);
    defer js.runtime.setInterruptHandler(null, null);

    try std.testing.expectError(error.Interrupted, js.eval("while (true) {}"));
    try std.testing.expect(state.hits > 0);
}

test "production embedding takeExceptionInfo captures exception snapshot without leaking" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    _ = js.eval("throw new Error('test exception snapshot');") catch |err| {
        try std.testing.expectEqual(error.Test262Error, err);
        var info = try js.takeExceptionInfo();
        defer info.deinit();
        try std.testing.expect(info.value.get().isObject());
    };
}
