//! Public engine-facing types exposed through the js facade.
//!
//! See docs/fun_zjs_subtree_architecture.md §7.2.

const std = @import("std");
const zjs = @import("zjs_engine");

pub const Source = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const EvalKind = enum { script, module };

pub const Completion = union(enum) {
    normal: Value,
    exception: Exception,
};

pub const Exception = struct {
    message: []const u8,
    stack: ?[]const u8 = null,
};

pub const EvalError = error{
    OutOfMemory,
    HostError,
    ParserBug,
    BytecodeBug,
    InternalBug,
};

pub const Value = @import("value.zig").Value;

pub const Engine = struct {
    inner: zjs.Engine,

    pub fn init(allocator: std.mem.Allocator, host_arg: anytype) !Engine {
        _ = host_arg;
        return .{ .inner = try zjs.Engine.init(allocator, .{}) };
    }

    pub fn deinit(self: *Engine) void {
        self.inner.deinit();
    }

    pub fn eval(self: *Engine, source: Source, kind: EvalKind) EvalError!Completion {
        _ = self;
        _ = source;
        _ = kind;
        return error.InternalBug;
    }

    pub fn runJobs(self: *Engine) EvalError!void {
        try self.inner.runJobs();
    }
};

const Host = @import("host.zig").Host;
