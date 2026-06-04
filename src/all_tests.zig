const std = @import("std");

const engine = @import("root.zig");

pub const internal = engine.internal;
pub const core = engine.internal.core;
pub const frontend = engine.internal.frontend;
pub const bytecode = engine.internal.bytecode;
pub const exec = engine.internal.exec;
pub const builtins = engine.internal.builtins;
pub const libs = engine.internal.libs;
pub const RuntimeError = engine.RuntimeError;
pub const HostError = engine.HostError;
pub const EngineError = engine.EngineError;
pub const JSRuntime = engine.JSRuntime;
pub const JSContext = engine.JSContext;
pub const JSValue = engine.JSValue;
pub const JSValueHandle = engine.JSValueHandle;
pub const LocalHandle = engine.LocalHandle;
pub const HandleScope = engine.HandleScope;
pub const WeakPersistent = engine.WeakPersistent;
pub const WeakPersistentValue = engine.WeakPersistentValue;
pub const NativePin = engine.NativePin;
pub const GCPolicy = engine.GCPolicy;
pub const GCStats = engine.GCStats;
pub const harness = engine.harness;
pub const Limits = engine.Limits;
pub const EngineOptions = engine.EngineOptions;
pub const EvalOptions = engine.EvalOptions;
pub const EvalTiming = engine.EvalTiming;
pub const ExternalHostCall = engine.ExternalHostCall;
pub const ExternalHostCallFn = engine.ExternalHostCallFn;
pub const ExternalHostFinalizer = engine.ExternalHostFinalizer;
pub const ExceptionInfo = engine.ExceptionInfo;
pub const Engine = engine.Engine;

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
    refAllDeclsRecursive(engine, .{});
    std.testing.refAllDecls(@import("tests/engine_production.zig"));
    std.testing.refAllDecls(@import("tests/core.zig"));
    std.testing.refAllDecls(@import("tests/bytecode.zig"));
    std.testing.refAllDecls(@import("tests/frontend.zig"));
    std.testing.refAllDecls(@import("tests/exec.zig"));
    std.testing.refAllDecls(@import("tests/builtins.zig"));


    // Relative imports for files that are not module roots
    std.testing.refAllDecls(@import("tests/gc_stress.zig"));
    std.testing.refAllDecls(@import("cli/zjs.zig"));
    std.testing.refAllDecls(@import("cli/run_test262.zig"));
}
