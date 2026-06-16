const ffi = @import("zjs").ffi;

fn add(call: ffi.ZigCall) !i32 {
    if (call.args.len != 2) return error.TypeError;
    const lhs = call.args[0].asInt32() orelse return error.TypeError;
    const rhs = call.args[1].asInt32() orelse return error.TypeError;
    return lhs + rhs;
}

const FixturePlugin = ffi.Plugin("runtime-plugin-fixture", .{
    ffi.bindingWithOptions("add", add, .{ .length = 2 }),
});

export fn zjs_plugin_descriptor() callconv(.c) ?*const ffi.PluginDescriptor {
    return FixturePlugin.descriptor();
}
