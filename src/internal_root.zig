const kernel_api = @import("root.zig");

pub const kernel = kernel_api.kernel;

pub const RuntimeError = exec.exceptions.RuntimeError;
pub const HostError = exec.exceptions.HostError;
pub const JSRuntime = kernel_api.JSRuntime;
pub const JSContext = kernel_api.JSContext;
pub const JSValue = kernel_api.JSValue;
pub const Object = core.Object;
pub const Descriptor = core.Descriptor;
pub const Atom = core.Atom;
pub const JSValueHandle = kernel_api.JSValueHandle;
pub const LocalHandle = kernel_api.LocalHandle;
pub const HandleScope = kernel_api.HandleScope;
pub const WeakPersistent = kernel_api.WeakPersistent;
pub const WeakPersistentValue = kernel_api.WeakPersistentValue;
pub const NativePin = kernel_api.NativePin;
pub const PropNameID = kernel_api.PropNameID;
pub const JSString = kernel_api.JSString;
pub const JSBytes = kernel_api.JSBytes;
pub const binding = kernel_api.binding;
pub const ffi = kernel_api.ffi;
pub const GCPolicy = core.GCPolicy;
pub const GCStats = core.GCStats;

pub const EvalOptions = core.context.EvalOptions;
pub const EvalTiming = core.context.EvalTiming;
pub const ExternalHostCall = core.host_function.ExternalCall;
pub const ExternalHostCallFn = core.host_function.ExternalCallFn;
pub const ExternalHostFinalizer = core.host_function.ExternalFinalizer;

pub const core = @import("core/root.zig");
pub const frontend = @import("frontend/root.zig");
pub const bytecode = @import("bytecode/root.zig");
pub const exec = @import("exec/root.zig");
pub const builtins = @import("builtins/root.zig");
pub const libs = @import("libs/root.zig");
pub const runtime = @import("runtime/root.zig");

test {
    _ = core;
    _ = frontend;
    _ = bytecode;
    _ = exec;
    _ = builtins;
    _ = libs;
    _ = runtime;
}
