//! One testing runtime, context, and global with host builtins installed.
//!
//! `init` rolls the runtime and context back if a later step fails.
//! `run` is the fixed-buffer `Stack` + `runWithArgs` tail.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;
const bytecode = zjs.bytecode;
const test_engine = @import("test_engine.zig");

pub const BareRuntime = struct {
    rt: *core.JSRuntime,
    ctx: *core.JSContext,
    global: *core.Object,

    pub const Options = struct {
        ensure_realm_payload: bool = false,
    };

    pub const Run = struct {
        value: core.JSValue,
        output: []const u8,
    };

    pub fn init(options: Options) !BareRuntime {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        errdefer rt.destroy();
        const ctx = try core.JSContext.create(rt, .{});
        errdefer ctx.destroy();
        const global = try core.Object.create(rt, core.class.ids.object, null);
        if (options.ensure_realm_payload) {
            _ = try global.ensureRealmPayload(rt);
        }
        try test_engine.installHostGlobalsBare(ctx, global);
        return .{ .rt = rt, .ctx = ctx, .global = global };
    }

    pub fn deinit(self: *BareRuntime) void {
        self.ctx.destroy();
        self.rt.destroy();
    }

    pub fn run(self: *BareRuntime, function: *const bytecode.FunctionBytecode, out_buf: []u8) !Run {
        var stack = zjs.exec.stack.Stack.init(self.rt, self.ctx.stackLimit());
        defer stack.deinit(self.rt);
        var output = std.Io.Writer.fixed(out_buf);
        const value = try zjs.exec.zjs_vm.runWithArgs(.{
            .ctx = self.ctx,
            .stack = &stack,
            .function = function,
            .initial_this_value = self.global.value(),
            .output = &output,
            .global = self.global,
            .break_var_ref_cycles_on_exit = true,
        });
        return .{ .value = value, .output = output.buffered() };
    }
};
