//! Helpers shared by more than one core integration file.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;

pub fn appendFinalizationRegistryCell(
    rt: *core.JSRuntime,
    registry: *core.Object,
    target: core.JSValue,
    held_value: core.JSValue,
    unregister_token: core.JSValue,
) !void {
    try registry.appendFinalizationRegistryCell(rt, target, held_value, unregister_token);
}

/// Zero a Zig pointer local that no longer holds a GC object, so a
/// conservative scan cannot treat leftover stack bits as a root (§7.2).
pub fn dropGcPtr(ptr: anytype) void {
    @memset(std.mem.asBytes(ptr), 0);
}

pub const BytesStoreState = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,

    pub fn deinit(context: ?*anyopaque, bytes: []u8) void {
        const self: *BytesStoreState = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.allocator.free(bytes);
    }
};
