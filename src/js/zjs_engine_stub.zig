//! Graceful stub used when third_party/zjs has not yet been populated via git subtree.
//!
//! See docs/fun_zjs_subtree_architecture.md §5 and third_party/zjs/README.md
//! for the exact one-command initialization.

const std = @import("std");

pub const Engine = struct {
    pub fn init(_: std.mem.Allocator, _: anytype) !Engine {
        @compileError("zjs engine not available. Run the subtree import command in third_party/zjs/README.md first.");
    }
    pub fn deinit(_: *Engine) void {}
    pub fn runJobs(_: *Engine) !void {}
};

// Minimal placeholders so the rest of the facade can type-check even without the real engine.
pub const core = struct {
    pub const Runtime = opaque {};
    pub const Context = opaque {};
    pub const Value = u64; // placeholder
};
pub const frontend = struct {
    pub const parser = struct {
        pub const Mode = enum { script, module };
    };
};
pub const exec = struct {
    pub const jobs = struct {
        pub const Queue = struct {
            pub fn init(_: anytype) Queue {
                return .{};
            }
            pub fn deinit(_: *Queue) void {}
        };
    };
};
