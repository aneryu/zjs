const ffi = @import("zjs").ffi;

const FixturePlugin = ffi.Plugin("runtime-empty-plugin-fixture", .{});

export fn zjs_plugin_descriptor() callconv(.c) ?*const ffi.PluginDescriptor {
    return FixturePlugin.descriptor();
}
