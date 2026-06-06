const frontend = @import("../frontend/root.zig");
const JSRuntime = @import("../core/runtime.zig").JSRuntime;

pub fn compileDirect(rt: *JSRuntime, source: []const u8) !frontend.parser.Result {
    return frontend.parser.parse(rt, source, .{ .mode = .eval_direct, .filename = "<eval>" });
}

pub fn compileIndirect(rt: *JSRuntime, source: []const u8) !frontend.parser.Result {
    return frontend.parser.parse(rt, source, .{ .mode = .eval_indirect, .filename = "<eval>" });
}
