//! Owns the zjs Engine instance and implements the host hook vtable.
//!
//! See docs/fun_zjs_subtree_architecture.md §9.1–9.2.

const std = @import("std");
const js = @import("js");
const Runtime = @import("../Runtime.zig");

const VM = @This();

allocator: std.mem.Allocator,
runtime: *Runtime,
engine: js.Engine,

pub const Options = struct { runtime: *Runtime };

pub fn init(allocator: std.mem.Allocator, options: Options) !VM {
    var self = VM{ .allocator = allocator, .runtime = options.runtime, .engine = undefined };
    const host = js.host.Host{ .ptr = &self, .vtable = &host_vtable };
    self.engine = try js.Engine.init(allocator, host);
    return self;
}

pub fn deinit(self: *VM) void {
    self.engine.deinit();
}

pub fn evalModule(self: *VM, source: js.Source) !js.Completion {
    return self.engine.eval(source, .module);
}

pub fn runMicrotasks(self: *VM) !void {
    try self.engine.runJobs();
}

const host_vtable = js.host.Host.VTable{
    .resolveModule = resolveModule,
    .loadModule = loadModule,
    .enqueuePromiseJob = enqueuePromiseJob,
    .promiseRejectionTracker = promiseRejectionTracker,
    .nowNanoseconds = nowNanoseconds,
};

fn resolveModule(ptr: *anyopaque, specifier: []const u8, referrer: ?[]const u8, allocator: std.mem.Allocator) js.host.HostError!js.host.ResolvedModule {
    const self: *VM = @ptrCast(@alignCast(ptr));
    _ = self;
    _ = specifier;
    _ = referrer;
    _ = allocator;
    return error.Unsupported;
}

fn loadModule(ptr: *anyopaque, resolved: js.host.ResolvedModule, allocator: std.mem.Allocator) js.host.HostError!js.host.LoadedModule {
    _ = ptr;
    _ = resolved;
    _ = allocator;
    return error.Unsupported;
}

fn enqueuePromiseJob(ptr: *anyopaque, job: js.host.PromiseJob) js.host.HostError!void {
    _ = ptr;
    _ = job;
    return error.Unsupported;
}

fn promiseRejectionTracker(ptr: *anyopaque, rejection: js.host.PromiseRejection) void {
    _ = ptr;
    _ = rejection;
}

fn nowNanoseconds(ptr: *anyopaque) u64 {
    _ = ptr;
    return 0;
}
