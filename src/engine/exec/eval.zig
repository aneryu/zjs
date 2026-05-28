const frontend = @import("../frontend/root.zig");
const Runtime = @import("../core/runtime.zig").Runtime;

pub fn compileDirect(rt: *Runtime, source: []const u8) !frontend.parser.Result {
    return frontend.parser.parse(rt, source, .{ .mode = .eval_direct, .filename = "<eval>" });
}

pub fn compileIndirect(rt: *Runtime, source: []const u8) !frontend.parser.Result {
    return frontend.parser.parse(rt, source, .{ .mode = .eval_indirect, .filename = "<eval>" });
}
