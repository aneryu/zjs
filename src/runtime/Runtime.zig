//! Top-level runtime owning VM + scheduler + module loader.
//! See docs/fun_zjs_subtree_architecture.md §10.

const std = @import("std");
const vm_mod = @import("vm/root.zig");

const Runtime = @This();

allocator: std.mem.Allocator,
vm: vm_mod.VM,

pub const Options = struct {
    cwd: []const u8,
    argv: []const []const u8 = &.{},
    enable_node_compat: bool = true,
};

pub fn init(allocator: std.mem.Allocator, options: Options) !Runtime {
    _ = options;
    var rt = Runtime{ .allocator = allocator, .vm = undefined };
    rt.vm = try vm_mod.VM.init(allocator, .{ .runtime = &rt });
    return rt;
}

pub fn deinit(self: *Runtime) void {
    self.vm.deinit();
}
