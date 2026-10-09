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
    if (std.mem.startsWith(u8, specifier, "file://")) {
        const path = try pathFromFileUrl(allocator, specifier);
        defer allocator.free(path);
        return canonicalPath(allocator, try std.fs.path.resolve(allocator, &.{path}));
    }
    if (mode == .entry) return canonicalPath(allocator, try std.fs.path.resolve(allocator, &.{specifier}));
    if (std.mem.startsWith(u8, specifier, "node:")) return allocator.dupe(u8, specifier);
    if (std.fs.path.isAbsolute(specifier)) return canonicalPath(allocator, try std.fs.path.resolve(allocator, &.{specifier}));
    // QuickJS policy (js_default_module_normalize_name): a specifier without
    // a leading `./` or `../` is used verbatim, as a path relative to the
    // working directory, for static and dynamic imports alike.
    if (!(std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../"))) {
        return allocator.dupe(u8, specifier);
    }
    const base = std.fs.path.dirname(referrer orelse ".") orelse ".";
    return canonicalPath(allocator, try std.fs.path.resolve(allocator, &.{ base, specifier }));
}

/// The module registry is keyed by this path, so every relative or absolute
/// spelling of one file (`./x.mjs`, its absolute path, a symlink) maps to the
/// same key. Specifiers without `./`, `../` or `/` are kept verbatim (QuickJS
/// policy, LIMITATIONS.md), so they do not share it. Use
/// the real path when the file exists, relative to the real working
/// directory when it lies below it (keeping names in messages short). A
/// missing file keeps its spelling and fails later in `read`. Takes
/// ownership of `path`.
fn canonicalPath(allocator: std.mem.Allocator, path: []u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_len = std.Io.Dir.cwd().realPathFile(io, path, &resolved) catch return path;
    defer allocator.free(path);
    var canonical = resolved[0..resolved_len];
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer)) |cwd_len| {
        const cwd = cwd_buffer[0..cwd_len];
        if (canonical.len > cwd.len + 1 and std.mem.startsWith(u8, canonical, cwd) and std.fs.path.isSep(canonical[cwd.len])) {
            canonical = canonical[cwd.len + 1 ..];
        }
    } else |_| {}
    return allocator.dupe(u8, canonical);
}

fn read(_: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return readFile(io, path, allocator, limit);
}

/// The whole file at `path`, at most `limit` bytes (a file of exactly `limit`
/// bytes is allowed; a longer one is `error.StreamTooLong`). Read until end of
/// file rather than trusting the reported size, which is 0 for `/proc` files.
pub fn readFile(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: usize) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = builtin.os.tag != .windows });
    defer file.close(io);
    var reader = file.readerStreaming(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(limit +| 1)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

fn syntheticKind(_: ?*anyopaque, path: []const u8, attribute: ?[]const u8) ?zjs.core.module.SyntheticKind {
    if (attribute) |kind| {
        if (zjs.core.module.SyntheticKind.fromName(kind)) |parsed| return parsed;
    }
    return if (std.mem.endsWith(u8, path, ".json")) .json else null;
}

fn metadataUrl(_: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    // `resolve` keeps a scheme only on `node:` specifiers; any other name is
    // a path, even one with a `:` in it.
    if (std.mem.startsWith(u8, name, "node:")) return allocator.dupe(u8, name);
    const path = zjs.exec.module.syntheticModuleFilePath(name);
    if (builtin.os.tag == .windows) return fileUrlFromPath(allocator, path);
    const io = std.Io.Threaded.global_single_threaded.io();
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_len = std.Io.Dir.cwd().realPathFile(io, path, &resolved) catch {
        // Pseudo filenames and missing files preserve the previous host URL
        // policy: absolute paths get a scheme; other names remain verbatim.
        if (std.mem.startsWith(u8, path, "/")) return fileUrlFromPath(allocator, path);
        return allocator.dupe(u8, name);
    };
    return fileUrlFromPath(allocator, resolved[0..resolved_len]);
}

/// The local path a `file:` URL names -- the inverse of `fileUrlFromPath`,
/// so `import(import.meta.url)` loads the module itself. Only an empty or
/// `localhost` authority is local; a query or fragment is not part of the
/// path. A malformed escape or an encoded NUL names no file.
fn pathFromFileUrl(allocator: std.mem.Allocator, url: []const u8) error{ OutOfMemory, ModuleNotFound }![]u8 {
    var rest = url["file://".len..];
    if (std.mem.startsWith(u8, rest, "localhost/")) rest = rest["localhost".len..];
    if (rest.len == 0 or rest[0] != '/') return error.ModuleNotFound;
    if (std.mem.indexOfAny(u8, rest, "?#")) |end| rest = rest[0..end];
    // Windows: `file:///C:/x` names `C:/x`.
    if (builtin.os.tag == .windows and rest.len >= 3 and rest[2] == ':') rest = rest[1..];

    const path = try allocator.alloc(u8, rest.len);
    errdefer allocator.free(path);
    var len: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (len += 1) {
        if (rest[i] == '%') {
            if (i + 3 > rest.len) return error.ModuleNotFound;
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch return error.ModuleNotFound;
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch return error.ModuleNotFound;
            path[len] = hi * 16 + lo;
            i += 3;
        } else {
            path[len] = rest[i];
            i += 1;
        }
        if (path[len] == 0) return error.ModuleNotFound;
    }
    return allocator.realloc(path, len);
}

/// `file://` + the path, percent-encoding every byte a URL path may not
/// carry verbatim (space, `#`, `?`, `%`, controls, non-ASCII UTF-8 bytes).
fn fileUrlFromPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var url: std.ArrayList(u8) = .empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, "file://");
    for (path) |byte| {
        const verbatim = std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-._~!$&'()*+,;=:@", byte) != null;
        if (byte == '\\' and builtin.os.tag == .windows) {
            try url.append(allocator, '/');
        } else if (verbatim) {
            try url.append(allocator, byte);
        } else {
            try url.print(allocator, "%{X:0>2}", .{byte});
        }
    }
    return url.toOwnedSlice(allocator);
}

pub const tests = if (@import("builtin").is_test) struct {
    pub fn case0() !void {
        for ([_]Loader.Resolution{ .static_import, .dynamic_import }) |mode| {
            const bare = try resolve(null, std.testing.allocator, "/a/main.js", "bare", mode);
            defer std.testing.allocator.free(bare);
            try std.testing.expectEqualStrings("bare", bare);
        }
        const path = try resolve(null, std.testing.allocator, "/a/main.js", "./dep.js", .dynamic_import);
        defer std.testing.allocator.free(path);
        const expected = try std.fs.path.resolve(std.testing.allocator, &.{ "/a", "dep.js" });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, path);
    }

    pub fn case1() !void {
        const allocator = std.testing.allocator;
        const original = "/tmp/a b/%c3/\xc3\xa9#?.mjs";
        const url = try fileUrlFromPath(allocator, original);
        defer allocator.free(url);
        const back = try pathFromFileUrl(allocator, url);
        defer allocator.free(back);
        try std.testing.expectEqualStrings(original, back);

        const local = try pathFromFileUrl(allocator, "file://localhost/x/y.mjs?q#f");
        defer allocator.free(local);
        try std.testing.expectEqualStrings("/x/y.mjs", local);

        for ([_][]const u8{ "file://host/x.mjs", "file://", "file:///x%2", "file:///x%+1", "file:///x%00" }) |bad| {
            try std.testing.expectError(error.ModuleNotFound, pathFromFileUrl(allocator, bad));
        }
    }
} else struct {};
