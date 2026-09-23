//! Host policy for source acquisition and import metadata. All returned byte
//! slices are owned by the caller and freed with the supplied allocator.
//! The optional userdata is borrowed and must outlive the receiving Context.
const std = @import("std");
const module = @import("module.zig");

pub const Loader = struct {
    ptr: ?*anyopaque = null,
    resolve: *const fn (?*anyopaque, std.mem.Allocator, ?[]const u8, []const u8, Resolution) error{ OutOfMemory, ModuleNotFound }![]u8,
    read: *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8, usize) std.Io.Dir.ReadFileAllocError![]u8,
    metadataUrl: *const fn (?*anyopaque, std.mem.Allocator, []const u8) error{OutOfMemory}![]u8,
    syntheticKind: *const fn (?*anyopaque, []const u8, ?[]const u8) ?module.SyntheticKind,

    pub const Resolution = enum { entry, static_import, dynamic_import };
};
