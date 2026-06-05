const std = @import("std");
const zjs = @import("zjs");

const InterruptState = struct {
    hits: usize = 0,

    fn stop(_: *zjs.JSRuntime, ctx: ?*anyopaque) bool {
        const self: *InterruptState = @ptrCast(@alignCast(ctx.?));
        self.hits += 1;
        return true;
    }
};

test "production embedding can own JSRuntime and JSContext directly" {
    var rt: zjs.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    var ctx: zjs.JSContext = undefined;
    try ctx.init(&rt, .{});
    defer ctx.deinit();

    const value = try ctx.eval("1 + 1", .{});
    defer value.free(&rt);
    try std.testing.expectEqual(@as(?i32, 2), value.asInt32());

    const object = try ctx.eval("({ answer: 42 })", .{});
    defer object.free(&rt);
    try std.testing.expect(object.isObject());

    const global = try ctx.globalObject();
    try std.testing.expect(global.is_global);
}

test "production embedding API applies limits and releases eval handles" {
    const rt = try zjs.JSRuntime.createWithOptions(std.testing.allocator, .{
        .stack_size = 128 * 1024,
        .gc_threshold = 32 * 1024,
    });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    try std.testing.expectEqual(@as(usize, 128 * 1024), rt.stackSize());
    try std.testing.expectEqual(@as(usize, 32 * 1024), rt.gcThreshold());

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try ctx.eval("print(1 + 2);", .{ .output = &output });
    defer result.free(rt);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n", output.buffered());
}

test "production embedding lifecycle deinitializes repeated script and module evals" {
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        const rt = try zjs.JSRuntime.create(std.testing.allocator);
        defer rt.destroy();

        const ctx = try zjs.JSContext.create(rt);
        defer ctx.destroy();

        const script_result = try ctx.eval(
            \\let values = [];
            \\for (let i = 0; i < 8; i++) values.push({ i });
            \\values.map(v => v.i).join(",");
        , .{ .discard_script_result = true });
        defer script_result.free(rt);
        try std.testing.expect(script_result.isUndefined());

        const module_result = try ctx.eval(
            \\const value = await Promise.resolve(42);
            \\export { value };
        , .{ .mode = .module });
        defer module_result.free(rt);
    }
}

test "production embedding memory limit reports allocation failure without leaking" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    defer rt.setMemoryLimit(null);

    try std.testing.expectError(error.OutOfMemory, ctx.eval("({ payload: new Array(32).fill('x') });", .{}));
}

test "production embedding interrupt handler aborts unbounded execution" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var state = InterruptState{};
    rt.setInterruptHandler(InterruptState.stop, &state);
    defer rt.setInterruptHandler(null, null);

    try std.testing.expectError(error.Interrupted, ctx.eval("while (true) {}", .{}));
    try std.testing.expect(state.hits > 0);
}

test "production embedding takeException captures exception snapshot without leaking" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    _ = ctx.eval("throw new Error('test exception snapshot');", .{}) catch |err| {
        try std.testing.expectEqual(error.JSException, err);
        const thrown = ctx.takePendingException();
        defer thrown.free(rt);
        try std.testing.expect(thrown.isObject());
    };
}
