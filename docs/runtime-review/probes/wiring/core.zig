const std = @import("std");
const provider = @import("engine_hooks");
pub const Hooks = struct { invoke: *const fn (*Runtime) usize };
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    hooks: *const Hooks,
    value: usize,
    pub fn create(allocator: std.mem.Allocator, value: usize) !*Runtime {
        const rt = try allocator.create(Runtime);
        rt.* = .{ .allocator = allocator, .hooks = provider.get(), .value = value };
        return rt;
    }
    pub fn destroy(rt: *Runtime) void {
        const allocator = rt.allocator;
        allocator.destroy(rt);
    }
};
