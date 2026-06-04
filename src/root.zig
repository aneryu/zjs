const std = @import("std");
const engine_mod = @import("engine.zig");

pub const Engine = engine_mod.Engine;
pub const EngineOptions = engine_mod.EngineOptions;
pub const Limits = engine_mod.Limits;
pub const ValueHandle = engine_mod.ValueHandle;
pub const EvalResult = engine_mod.EvalResult;
pub const ExceptionInfo = engine_mod.ExceptionInfo;
pub const HostHooks = engine_mod.HostHooks;

pub const internal = struct {
    pub const core = @import("core/root.zig");
    pub const frontend = @import("frontend/root.zig");
    pub const bytecode = @import("bytecode/root.zig");
    pub const exec = @import("exec/root.zig");
    pub const builtins = @import("builtins/root.zig");
    pub const libs = @import("libs/root.zig");
    pub const cli_helpers = @import("cli/helpers.zig");
    pub const test262_helpers = @import("cli/test262_helpers.zig");
};

pub const RuntimeError = internal.exec.exceptions.RuntimeError;
pub const HostError = internal.exec.exceptions.HostError;
pub const EngineError = RuntimeError;

pub const JSRuntime = internal.core.JSRuntime;
pub const JSContext = internal.core.JSContext;
pub const JSValue = internal.core.JSValue;
pub const JSValueHandle = internal.core.runtime.JSValueHandle;
pub const LocalHandle = internal.core.LocalHandle;
pub const HandleScope = internal.core.HandleScope;
pub const WeakPersistent = internal.core.WeakPersistent;
pub const WeakPersistentValue = internal.core.WeakPersistentValue;
pub const NativePin = internal.core.NativePin;
pub const GCPolicy = internal.core.GCPolicy;
pub const GCStats = internal.core.GCStats;

pub const EvalOptions = internal.core.context.EvalOptions;
pub const EvalTiming = internal.core.context.EvalTiming;
pub const ExternalHostCall = internal.core.host_function.ExternalCall;
pub const ExternalHostCallFn = internal.core.host_function.ExternalCallFn;
pub const ExternalHostFinalizer = internal.core.host_function.ExternalFinalizer;

pub const harness = if (@import("builtin").is_test) struct {
    pub const Engine = @import("tests/exec.zig").helpers.TestEngine;
} else struct {};

test {
    _ = internal.core;
    _ = internal.frontend;
    _ = internal.bytecode;
    _ = internal.exec;
    _ = internal.builtins;
    _ = internal.libs;
    _ = engine_mod;
}


