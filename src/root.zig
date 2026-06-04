pub const core = @import("core/root.zig");
pub const frontend = @import("frontend/root.zig");
pub const bytecode = @import("bytecode/root.zig");
pub const exec = @import("exec/root.zig");
pub const builtins = @import("builtins/root.zig");
pub const libs = @import("libs/root.zig");

pub const RuntimeError = exec.exceptions.RuntimeError;
pub const HostError = exec.exceptions.HostError;
pub const EngineError = RuntimeError;

pub const JSRuntime = core.JSRuntime;
pub const JSContext = core.JSContext;
pub const JSValue = core.JSValue;
pub const JSValueHandle = core.runtime.JSValueHandle;
pub const LocalHandle = core.LocalHandle;
pub const HandleScope = core.HandleScope;
pub const WeakPersistent = core.WeakPersistent;
pub const WeakPersistentValue = core.WeakPersistentValue;
pub const NativePin = core.NativePin;
pub const GCPolicy = core.GCPolicy;
pub const GCStats = core.GCStats;

pub const EvalOptions = core.context.EvalOptions;
pub const EvalTiming = core.context.EvalTiming;
pub const ExternalHostCall = core.host_function.ExternalCall;
pub const ExternalHostCallFn = core.host_function.ExternalCallFn;
pub const ExternalHostFinalizer = core.host_function.ExternalFinalizer;

pub const harness = if (@import("builtin").is_test) struct {
    pub const Engine = @import("tests/exec/exec_helpers.zig").TestEngine;
} else struct {};

test {
    _ = core;
    _ = frontend;
    _ = bytecode;
    _ = exec;
    _ = builtins;
    _ = libs;
}


