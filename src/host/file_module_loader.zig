//! Filesystem policy for the bundled programs. Module records, evaluation,
//! continuations and Promise settlement belong to the engine.
const std = @import("std");
const builtin = @import("builtin");
const zjs = @import("zjs");
const Loader = zjs.core.context.ModuleSourceLoader;

pub const loader: Loader = .{
    .resolve = resolve,
    .read = read,
    .metadataUrl = metadataUrl,
    .syntheticKind = syntheticKind,
};

pub fn install(ctx: *zjs.core.JSContext) void {
    ctx.module_source_loader = &loader;
}

fn resolve(_: ?*anyopaque, allocator: std.mem.Allocator, referrer: ?[]const u8, specifier: []const u8, mode: Loader.Resolution) ![]u8 {
    if (mode == .entry) return std.fs.path.resolve(allocator, &.{specifier});
    if (std.mem.startsWith(u8, specifier, "node:")) return allocator.dupe(u8, specifier);
    if (std.fs.path.isAbsolute(specifier)) return std.fs.path.resolve(allocator, &.{specifier});
    if (!(std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../"))) {
        if (mode == .dynamic_import) return error.ModuleNotFound;
        return allocator.dupe(u8, specifier);
    }
    const base = std.fs.path.dirname(referrer orelse ".") orelse ".";
    return std.fs.path.resolve(allocator, &.{ base, specifier });
}

fn read(_: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

fn syntheticKind(_: ?*anyopaque, path: []const u8, attribute: ?[]const u8) ?zjs.core.module.SyntheticKind {
    if (attribute) |kind| {
        if (std.mem.eql(u8, kind, "json")) return .json;
        if (std.mem.eql(u8, kind, "text")) return .text;
        if (std.mem.eql(u8, kind, "bytes")) return .bytes;
    }
    return if (std.mem.endsWith(u8, path, ".json")) .json else null;
}

fn metadataUrl(_: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, name, ':') != null) return allocator.dupe(u8, name);
    const path = zjs.exec.module.syntheticModuleFilePath(name);
    if (builtin.os.tag == .windows) return std.fmt.allocPrint(allocator, "file://{s}", .{path});
    const io = std.Io.Threaded.global_single_threaded.io();
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_len = std.Io.Dir.cwd().realPathFile(io, path, &resolved) catch {
        // Pseudo filenames and missing files preserve the previous host URL
        // policy: absolute paths get a scheme; other names remain verbatim.
        if (std.mem.startsWith(u8, path, "/")) return std.fmt.allocPrint(allocator, "file://{s}", .{path});
        return allocator.dupe(u8, name);
    };
    return std.fmt.allocPrint(allocator, "file://{s}", .{resolved[0..resolved_len]});
}

pub const tests = if (@import("builtin").is_test) struct {
    pub fn case0() !void {
        try std.testing.expectError(error.ModuleNotFound, resolve(null, std.testing.allocator, "/a/main.js", "bare", .dynamic_import));
        const path = try resolve(null, std.testing.allocator, "/a/main.js", "./dep.js", .dynamic_import);
        defer std.testing.allocator.free(path);
        const expected = try std.fs.path.resolve(std.testing.allocator, &.{ "/a", "dep.js" });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, path);
    }
} else struct {};
