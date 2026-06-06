const std = @import("std");

const kernel_api = @import("root.zig");

pub const public_api = kernel_api;
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
pub const NativePin = core.NativePin;
pub const RuntimeOptions = kernel_api.RuntimeOptions;
pub const RuntimeMemoryUsage = kernel_api.RuntimeMemoryUsage;
pub const ContextOptions = kernel_api.ContextOptions;
pub const GCPolicy = core.GCPolicy;
pub const GCStats = core.GCStats;
pub const harness = struct {
    pub const Engine = @import("tests/exec.zig").helpers.TestEngine;
};
pub const EvalOptions = kernel_api.EvalOptions;
pub const EvalMode = kernel_api.EvalMode;
pub const EvalTiming = kernel_api.EvalTiming;
pub const DataPropertyOptions = kernel_api.DataPropertyOptions;
pub const PropertyAccessOptions = kernel_api.PropertyAccessOptions;
pub const PropertyDescriptor = kernel_api.PropertyDescriptor;
pub const ExternalFunctionOptions = kernel_api.ExternalFunctionOptions;
pub const FunctionCallOptions = kernel_api.FunctionCallOptions;
pub const ErrorOptions = kernel_api.ErrorOptions;
pub const ScriptEvalOptions = kernel_api.ScriptEvalOptions;
pub const SharedArrayBufferRef = kernel_api.SharedArrayBufferRef;
pub const ExternalHostCall = kernel_api.ExternalHostCall;
pub const ExternalHostCallFn = kernel_api.ExternalHostCallFn;
pub const ExternalHostFinalizer = kernel_api.ExternalHostFinalizer;
pub const OpcodeProfile = kernel_api.OpcodeProfile;
pub const default_stack_size = kernel_api.default_stack_size;
pub const default_gc_threshold = kernel_api.default_gc_threshold;
pub const PropNameID = kernel_api.PropNameID;
pub const JSString = kernel_api.JSString;
pub const JSBytes = kernel_api.JSBytes;
pub const binding = kernel_api.binding;
pub const ffi = kernel_api.ffi;
pub const activateOpcodeProfile = kernel_api.activateOpcodeProfile;

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
