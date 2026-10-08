//! In-memory module source loader for module-graph tests. It implements the
//! engine's `ModuleSourceLoader` contract without filesystem access, so tests
//! exercise the same scheduler the bundled programs use.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;
const Loader = core.context.ModuleSourceLoader;

pub const Module = struct {
    /// Exact import specifier that names this module.
    specifier: []const u8,
    /// Canonical module name; also accepted as a specifier.
    path: []const u8,
    source: []const u8,
};

pub const MemoryModules = struct {
    modules: []const Module,
    resolve_calls: usize = 0,
    read_calls: usize = 0,
    /// When set, records whether any non-entry resolution saw this referrer.
    expected_referrer: ?[]const u8 = null,
    saw_expected_referrer: bool = false,
    vtable: Loader = undefined,

    /// Install on `ctx`. `self` must stay at this address while `ctx` uses it.
    pub fn install(self: *MemoryModules, ctx: *core.JSContext) void {
        self.vtable = .{
            .ptr = self,
            .resolve = resolve,
            .read = read,
            .metadataUrl = metadataUrl,
            .syntheticKind = syntheticKind,
        };
        ctx.module_source_loader = &self.vtable;
    }

    fn find(self: *const MemoryModules, name: []const u8) ?Module {
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.specifier, name) or std.mem.eql(u8, module.path, name)) return module;
        }
        return null;
    }

    fn from(ptr: ?*anyopaque) *MemoryModules {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn resolve(ptr: ?*anyopaque, allocator: std.mem.Allocator, referrer: ?[]const u8, specifier: []const u8, mode: Loader.Resolution) error{ OutOfMemory, ModuleNotFound }![]u8 {
        const self = from(ptr);
        if (mode == .entry) return allocator.dupe(u8, specifier);
        self.resolve_calls += 1;
        if (self.expected_referrer) |expected| {
            if (referrer) |actual| {
                if (std.mem.eql(u8, actual, expected)) self.saw_expected_referrer = true;
            }
        }
        const module = self.find(specifier) orelse return error.ModuleNotFound;
        return allocator.dupe(u8, module.path);
    }

    fn read(ptr: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) std.Io.Dir.ReadFileAllocError![]u8 {
        const self = from(ptr);
        const module = self.find(path) orelse return error.FileNotFound;
        if (module.source.len > limit) return error.StreamTooLong;
        self.read_calls += 1;
        return allocator.dupe(u8, module.source);
    }

    fn metadataUrl(_: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
        return allocator.dupe(u8, name);
    }

    fn syntheticKind(_: ?*anyopaque, path: []const u8, attribute: ?[]const u8) ?core.module.SyntheticKind {
        if (attribute) |kind| {
            if (std.mem.eql(u8, kind, "json")) return .json;
            if (std.mem.eql(u8, kind, "text")) return .text;
            if (std.mem.eql(u8, kind, "bytes")) return .bytes;
        }
        return if (std.mem.endsWith(u8, path, ".json")) .json else null;
    }
};
