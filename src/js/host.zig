//! Host hook types (vtable for module loader, promise jobs, rejection tracker, time).
//! See docs/fun_zjs_subtree_architecture.md §8.

const std = @import("std");

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resolveModule: *const fn (*anyopaque, []const u8, ?[]const u8, std.mem.Allocator) HostError!ResolvedModule,
        loadModule: *const fn (*anyopaque, ResolvedModule, std.mem.Allocator) HostError!LoadedModule,
        enqueuePromiseJob: *const fn (*anyopaque, PromiseJob) HostError!void,
        promiseRejectionTracker: *const fn (*anyopaque, PromiseRejection) void,
        nowNanoseconds: *const fn (*anyopaque) u64,
    };
};

pub const HostError = error{ OutOfMemory, ModuleNotFound, PermissionDenied, Unsupported, RuntimeError };

pub const ResolvedModule = struct { specifier: []const u8, path: []const u8, kind: ModuleKind };
pub const LoadedModule = struct { source: []const u8, path: []const u8, kind: ModuleKind, owned: bool = false };
pub const PromiseJob = opaque {};
pub const PromiseRejection = opaque {};
pub const ModuleKind = enum { esm, commonjs, json, wasm, builtin };
