const std = @import("std");

const exec = @import("../exec/root.zig");
const zjs = @import("../kernel/root.zig");

pub fn evalFileModuleGraphWithOutput(
    ctx: *zjs.JSContext,
    source_text: []const u8,
    output: *std.Io.Writer,
    filename: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
) !zjs.JSValue {
    return exec.module_graph.evalFileModuleGraphWithOutput(ctx.runtimePtr(), ctx, source_text, output, filename, io, allocator, max_source_size);
}

pub fn resolveModuleSpecifier(allocator: std.mem.Allocator, referrer_path: []const u8, specifier: []const u8) ![]const u8 {
    return exec.module.resolveModuleSpecifier(allocator, referrer_path, specifier);
}
