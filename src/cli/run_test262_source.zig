//! test262 source, metadata, harness, and local-override assembly.
//! `HarnessCache` owns duplicated names and optional file contents until
//! `deinit`; assembled test sources are allocator-owned by the caller. Local
//! overrides are accepted only after the pinned upstream source hash matches,
//! so fixtures cannot silently mask upstream drift. Metadata reads use a
//! bounded prefix unless an override requires the verified full source.

const std = @import("std");
const runner_metadata = @import("run_test262_metadata.zig");
const TestMetadata = runner_metadata.TestMetadata;
const parseMetadataText = runner_metadata.parse;
pub const HarnessCache = struct {
    const Entry = struct {
        name: []const u8,
        bytes: ?[]const u8,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    harnessdir: ?[]const u8,
    entries: []Entry = &.{},
    capacity: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, harnessdir: ?[]const u8) HarnessCache {
        return .{
            .allocator = allocator,
            .io = io,
            .harnessdir = harnessdir,
        };
    }

    pub fn deinit(self: *HarnessCache) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.name);
            if (entry.bytes) |bytes| self.allocator.free(bytes);
        }
        if (self.capacity != 0) self.allocator.free(self.entries.ptr[0..self.capacity]);
        self.entries = &.{};
        self.capacity = 0;
    }

    fn get(self: *HarnessCache, basename: []const u8) !?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, basename)) return entry.bytes;
        }

        const bytes = try readHarnessFile(self.allocator, self.io, self.harnessdir, basename);
        try self.append(.{
            .name = try self.allocator.dupe(u8, basename),
            .bytes = bytes,
        });
        return bytes;
    }

    fn append(self: *HarnessCache, entry: Entry) !void {
        if (self.entries.len == self.capacity) {
            const next_capacity = if (self.capacity == 0) 16 else self.capacity * 2;
            const next = try self.allocator.alloc(Entry, next_capacity);
            @memcpy(next[0..self.entries.len], self.entries);
            if (self.capacity != 0) self.allocator.free(self.entries.ptr[0..self.capacity]);
            self.entries = next[0..self.entries.len];
            self.capacity = next_capacity;
        }
        const storage: []Entry = @constCast(self.entries.ptr[0..self.capacity]);
        storage[self.entries.len] = entry;
        self.entries = storage[0 .. self.entries.len + 1];
    }
};

pub fn makeHarnessPrelude(allocator: std.mem.Allocator, io: std.Io, harnessdir: ?[]const u8) ![]u8 {
    const eval_script_shim =
        "if (typeof $262 === \"object\" && typeof $262.evalScript !== \"function\") {\n" ++
        "  $262.evalScript = function(source) { return (0, eval)(source); };\n" ++
        "}\n";
    const sta = try readHarnessFile(allocator, io, harnessdir, "sta.js");
    defer if (sta) |bytes| allocator.free(bytes);
    const assert = try readHarnessFile(allocator, io, harnessdir, "assert.js");
    defer if (assert) |bytes| allocator.free(bytes);

    const sta_len = if (sta) |bytes| bytes.len else 0;
    const assert_len = if (assert) |bytes| bytes.len else 0;
    const total_len = sta_len + assert_len +
        @as(usize, if (sta != null) 1 else 0) +
        @as(usize, if (assert != null) 1 else 0) +
        eval_script_shim.len;
    const out = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    if (sta) |bytes| {
        @memcpy(out[offset..][0..bytes.len], bytes);
        offset += bytes.len;
        out[offset] = '\n';
        offset += 1;
    }
    if (assert) |bytes| {
        @memcpy(out[offset..][0..bytes.len], bytes);
        offset += bytes.len;
        out[offset] = '\n';
        offset += 1;
    }
    @memcpy(out[offset..][0..eval_script_shim.len], eval_script_shim);
    offset += eval_script_shim.len;
    return out[0..offset];
}

pub const Test262Override = struct {
    path: []const u8,
    upstream_commit: []const u8,
    upstream_sha256: []const u8,
    reason: []const u8,
};

pub const override_manifest = [_]Test262Override{
    .{
        .path = "test/built-ins/TypedArray/prototype/slice/speciesctor-return-same-buffer-with-offset.js",
        .upstream_commit = "4249661388e5d3f92a85186213da140a6481490f",
        .upstream_sha256 = "2136a50c608ac2dd74815ca4cb4ec6e0eb7bd54d1fc102bec5fe53b322563a6b",
        .reason = "Exclude immutable ArrayBuffer path until upstream covers the proposal interaction.",
    },
    .{
        .path = "test/built-ins/TypedArrayConstructors/internals/Set/BigInt/string-nan-tobigint.js",
        .upstream_commit = "4249661388e5d3f92a85186213da140a6481490f",
        .upstream_sha256 = "20bc0c56378a3c12e7fa38d920648d8f5b57c8e3ab2ea31737b7794ccce8dbfb",
        .reason = "Exclude immutable ArrayBuffer path until upstream covers the proposal interaction.",
    },
    .{
        .path = "test/staging/sm/Error/constructor-proto.js",
        .upstream_commit = "4249661388e5d3f92a85186213da140a6481490f",
        .upstream_sha256 = "e42a648845a28cbcf52adc3c0a437b6afe0a18d8ea0cef5821ba9dcdd3c08738",
        .reason = "Staging SpiderMonkey test has not been updated for Error.prototype.stack accessor.",
    },
    .{
        .path = "test/staging/sm/Error/prototype-properties.js",
        .upstream_commit = "4249661388e5d3f92a85186213da140a6481490f",
        .upstream_sha256 = "e91457931236bdc6fe42d96e96569fd9bfff1ee2c0592aca19c3dc2a4886b5b2",
        .reason = "Staging SpiderMonkey test has not been updated for Error.prototype.stack accessor.",
    },
    .{
        .path = "test/staging/sm/Error/prototype.js",
        .upstream_commit = "4249661388e5d3f92a85186213da140a6481490f",
        .upstream_sha256 = "ee62fb50ca1cee2a3a6de258af03b38a8750dde2e0485101f997db2bd730f770",
        .reason = "Staging SpiderMonkey test has not been updated for Error.prototype.stack accessor.",
    },
};

pub fn readTestSource(allocator: std.mem.Allocator, io: std.Io, test_path: []const u8) ![]u8 {
    if (test262Override(test_path)) |override| {
        try verifyTest262OverrideUpstream(allocator, io, override);
        const override_path = try test262OverridePath(allocator, test_path);
        defer allocator.free(override_path);
        return std.Io.Dir.cwd().readFileAlloc(io, override_path, allocator, .limited(16 * 1024 * 1024));
    }
    return std.Io.Dir.cwd().readFileAlloc(io, test_path, allocator, .limited(16 * 1024 * 1024));
}

pub fn test262Override(test_path: []const u8) ?Test262Override {
    const relative_path = test262RelativePath(test_path) orelse return null;
    for (override_manifest) |override| {
        if (std.mem.eql(u8, override.path, relative_path)) return override;
    }
    return null;
}

fn verifyTest262OverrideUpstream(allocator: std.mem.Allocator, io: std.Io, override: Test262Override) !void {
    const upstream_path = try test262UpstreamPath(allocator, override.path);
    defer allocator.free(upstream_path);
    const upstream_source = try std.Io.Dir.cwd().readFileAlloc(io, upstream_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(upstream_source);
    const actual_sha256 = computeSha256Hex(upstream_source);
    if (!std.mem.eql(u8, override.upstream_sha256, &actual_sha256)) {
        std.debug.print(
            "test262 override source drifted: {s}\nexpected upstream {s} sha256 {s}\nactual sha256 {s}\nreason: {s}\n",
            .{ upstream_path, override.upstream_commit, override.upstream_sha256, actual_sha256, override.reason },
        );
        return error.Test262OverrideSourceDrift;
    }
}

fn computeSha256Hex(bytes: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return hex;
}

pub fn test262OverridePath(allocator: std.mem.Allocator, test_path: []const u8) ![]const u8 {
    std.debug.assert(test262Override(test_path) != null);
    const relative_path = test262RelativePath(test_path).?;
    return try std.fs.path.join(allocator, &.{ "tests/fixtures/test262-overrides", relative_path });
}

pub fn test262UpstreamPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ "test262", relative_path });
}

fn test262RelativePath(test_path: []const u8) ?[]const u8 {
    const config_prefix = "test262/";
    if (std.mem.startsWith(u8, test_path, config_prefix)) return test_path[config_prefix.len..];
    if (std.mem.startsWith(u8, test_path, "test/")) return test_path;
    return null;
}

pub fn makeTestSourceFromBytes(allocator: std.mem.Allocator, harness_cache: *HarnessCache, harness_prelude: []const u8, test_source: []const u8, metadata: TestMetadata) ![]u8 {
    const strict_prefix = "\"use strict\";\n";
    const async_harness = "doneprintHandle.js";
    const strict_len: usize = if (metadata.hasFlag("onlyStrict")) strict_prefix.len else 0;
    if (metadata.hasFlag("raw")) {
        const out = try allocator.alloc(u8, strict_len + test_source.len + 1);
        var offset: usize = 0;
        if (strict_len != 0) {
            @memcpy(out[offset..][0..strict_prefix.len], strict_prefix);
            offset += strict_prefix.len;
        }
        @memcpy(out[offset..][0..test_source.len], test_source);
        offset += test_source.len;
        out[offset] = '\n';
        return out;
    }

    var includes_len: usize = 0;
    const include_async_harness = needsAsyncHarness(metadata, test_source) and !metadata.includes.contains(async_harness);
    if (include_async_harness) {
        if (try harness_cache.get(async_harness)) |bytes| includes_len += bytes.len + 1;
    }
    for (metadata.includes.items) |include_name| {
        if (try harness_cache.get(include_name)) |bytes| includes_len += bytes.len + 1;
    }
    const total_len = strict_len + harness_prelude.len + includes_len + test_source.len + 1;
    const out = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    if (strict_len != 0) {
        @memcpy(out[offset..][0..strict_prefix.len], strict_prefix);
        offset += strict_prefix.len;
    }
    @memcpy(out[offset..][0..harness_prelude.len], harness_prelude);
    offset += harness_prelude.len;
    if (include_async_harness) {
        if (try harness_cache.get(async_harness)) |bytes| {
            @memcpy(out[offset..][0..bytes.len], bytes);
            offset += bytes.len;
            out[offset] = '\n';
            offset += 1;
        }
    }
    for (metadata.includes.items) |include_name| {
        if (try harness_cache.get(include_name)) |bytes| {
            @memcpy(out[offset..][0..bytes.len], bytes);
            offset += bytes.len;
            out[offset] = '\n';
            offset += 1;
        }
    }
    @memcpy(out[offset..][0..test_source.len], test_source);
    offset += test_source.len;
    out[offset] = '\n';
    offset += 1;
    return out[0..offset];
}

fn needsAsyncHarness(metadata: TestMetadata, test_source: []const u8) bool {
    _ = test_source;
    return metadata.hasFlag("async");
}

fn readHarnessFile(allocator: std.mem.Allocator, io: std.Io, harnessdir: ?[]const u8, basename: []const u8) !?[]u8 {
    const dir = harnessdir orelse return null;
    const path = try std.fs.path.join(allocator, &.{ dir, basename });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
}

pub fn loadMetadataFromFile(allocator: std.mem.Allocator, io: std.Io, test_path: []const u8) !TestMetadata {
    const bytes = try readMetadataPrefix(allocator, io, test_path);
    defer allocator.free(bytes);
    return parseMetadataText(allocator, bytes);
}

fn readMetadataPrefix(allocator: std.mem.Allocator, io: std.Io, test_path: []const u8) ![]u8 {
    if (test262Override(test_path) != null) return readTestSource(allocator, io, test_path);

    const max_metadata_probe = 64 * 1024;
    const file = try std.Io.Dir.cwd().openFile(io, test_path, .{});
    defer file.close(io);
    const buffer = try allocator.alloc(u8, max_metadata_probe);
    errdefer allocator.free(buffer);
    const len = try file.readPositionalAll(io, buffer, 0);
    if (len == buffer.len) return buffer;
    const exact = try allocator.dupe(u8, buffer[0..len]);
    allocator.free(buffer);
    return exact;
}
