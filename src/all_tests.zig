const std = @import("std");

const engine = @import("engine/root.zig");

pub const core = engine.core;
pub const frontend = engine.frontend;
pub const bytecode = engine.bytecode;
pub const exec = engine.exec;
pub const builtins = engine.builtins;
pub const libs = engine.libs;
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
    std.testing.refAllDecls(@import("tests/core/all.zig"));
    std.testing.refAllDecls(@import("tests/bytecode/all.zig"));
    std.testing.refAllDecls(@import("tests/frontend/all.zig"));
    std.testing.refAllDecls(@import("tests/builtins/all.zig"));
    std.testing.refAllDecls(@import("tests/tools/all.zig"));
    std.testing.refAllDecls(@import("tests/exec/core_native.zig"));
    std.testing.refAllDecls(@import("tests/exec/builtins_async.zig"));
    std.testing.refAllDecls(@import("tests/exec/engine_smoke.zig"));
    std.testing.refAllDecls(@import("tests/exec/collection_typedarray.zig"));

    // Relative imports for files that are not module roots
    std.testing.refAllDecls(@import("tests/gc_stress.zig"));
    std.testing.refAllDecls(@import("cli/zjs.zig"));
    std.testing.refAllDecls(@import("cli/run_test262.zig"));
}
