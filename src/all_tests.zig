const std = @import("std");

const kernel_api = @import("root.zig");

pub const kernel = kernel_api.kernel;
pub const core = @import("core/root.zig");
pub const frontend = @import("frontend/root.zig");
pub const bytecode = @import("bytecode/root.zig");
pub const exec = @import("exec/root.zig");
pub const builtins = @import("builtins/root.zig");
pub const libs = @import("libs/root.zig");
pub const runtime = @import("runtime/root.zig");
pub const RuntimeError = exec.exceptions.RuntimeError;
pub const HostError = exec.exceptions.HostError;
pub const JSRuntime = kernel_api.JSRuntime;
pub const JSContext = kernel_api.JSContext;
pub const JSValue = kernel_api.JSValue;
pub const JSValueHandle = kernel_api.JSValueHandle;
pub const LocalHandle = kernel_api.LocalHandle;
pub const HandleScope = kernel_api.HandleScope;
pub const WeakPersistent = kernel_api.WeakPersistent;
pub const WeakPersistentValue = kernel_api.WeakPersistentValue;
pub const GCPolicy = core.GCPolicy;
pub const GCStats = core.GCStats;
pub const harness = struct {
    pub const Engine = @import("tests/exec.zig").helpers.TestEngine;
};
pub const EvalOptions = core.context.EvalOptions;
pub const EvalTiming = core.context.EvalTiming;
pub const ExternalHostCall = core.host_function.ExternalCall;
pub const ExternalHostCallFn = core.host_function.ExternalCallFn;
pub const ExternalHostFinalizer = core.host_function.ExternalFinalizer;

fn refAllDeclsRecursive(comptime Container: type, comptime visited: anytype) void {
    @setEvalBranchQuota(200000);
    if (!@import("builtin").is_test) return;

    // Avoid infinite recursion on cycles
    inline for (visited) |V| {
        if (V == Container) return;
    }

    const new_visited = visited ++ .{Container};

    inline for (comptime std.meta.declarations(Container)) |decl| {
        _ = &@field(Container, decl.name);
        const DeclType = @TypeOf(@field(Container, decl.name));
        switch (@typeInfo(DeclType)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => {
                refAllDeclsRecursive(DeclType, new_visited);
            },
            .type => {
                const T = @field(Container, decl.name);
                switch (@typeInfo(T)) {
                    .@"struct", .@"union", .@"enum", .@"opaque" => {
                        refAllDeclsRecursive(T, new_visited);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

test {
    refAllDeclsRecursive(kernel_api, .{});
    std.testing.refAllDecls(@import("tests/engine_production.zig"));
    std.testing.refAllDecls(@import("tests/core.zig"));
    std.testing.refAllDecls(@import("tests/bytecode.zig"));
    std.testing.refAllDecls(@import("tests/frontend.zig"));
    std.testing.refAllDecls(@import("tests/exec.zig"));
    std.testing.refAllDecls(@import("tests/builtins.zig"));
    std.testing.refAllDecls(runtime);

    // Relative imports for files that are not module roots
    std.testing.refAllDecls(@import("tests/gc_stress.zig"));
    std.testing.refAllDecls(@import("cli/zjs.zig"));
    std.testing.refAllDecls(@import("cli/run_test262.zig"));
}
