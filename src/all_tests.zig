const std = @import("std");

const kernel_api = @import("root.zig");

pub const public_api = kernel_api;
pub const kernel = @import("kernel/root.zig");
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
pub const Object = kernel_api.object.Object;
pub const JSValue = kernel_api.JSValue;
pub const JSValueHandle = kernel_api.value.Persistent;
pub const LocalHandle = kernel_api.value.Local;
pub const HandleScope = kernel_api.value.Scope;
pub const WeakPersistent = kernel_api.value.Weak;
pub const WeakPersistentValue = kernel_api.value.Weak;
pub const NativePin = core.NativePin;
pub const RuntimeOptions = kernel_api.RuntimeOptions;
pub const RuntimeMemoryUsage = kernel_api.RuntimeMemoryUsage;
pub const ContextOptions = kernel_api.context.Options;
pub const GCPolicy = core.GCPolicy;
pub const GCStats = core.GCStats;
pub const harness = struct {
    pub const Engine = @import("tests/exec.zig").helpers.TestEngine;
};
pub const EvalOptions = kernel_api.context.EvalOptions;
pub const EvalMode = kernel_api.context.EvalMode;
pub const EvalTiming = kernel_api.context.EvalTiming;
pub const DataPropertyOptions = kernel_api.context.DataPropertyOptions;
pub const PropertyAccessOptions = kernel_api.context.PropertyAccessOptions;
pub const PropertyDescriptor = kernel_api.context.PropertyDescriptor;
pub const ExternalFunctionOptions = kernel_api.host.FunctionOptions;
pub const FunctionCallOptions = kernel_api.context.FunctionCallOptions;
pub const ErrorOptions = kernel_api.context.ErrorOptions;
pub const ScriptEvalOptions = kernel_api.context.ScriptEvalOptions;
pub const SharedArrayBufferRef = kernel_api.object.SharedArrayBufferRef;
pub const ExternalHostCall = kernel_api.host.Call;
pub const ExternalHostCallFn = kernel_api.host.Function;
pub const ExternalHostFinalizer = kernel_api.host.Finalizer;
pub const OpcodeProfile = kernel_api.OpcodeProfile;
pub const default_stack_size = kernel_api.default_stack_size;
pub const default_gc_threshold = kernel_api.default_gc_threshold;
pub const PropNameID = kernel_api.host.PropName;
pub const JSString = kernel_api.value.String;
pub const JSBytes = kernel_api.value.Bytes;
pub const binding = kernel_api.host.NativeBinding;
pub const ffi = kernel_api.ffi;
pub const activateOpcodeProfile = kernel_api.activateOpcodeProfile;
pub const value = kernel_api.value;
pub const host = kernel_api.host;
pub const object = kernel_api.object;
pub const context = kernel_api.context;
pub const module = kernel_api.module;
pub const compile = kernel_api.compile;
pub const @"error" = kernel_api.@"error";
pub const job = kernel_api.job;

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
