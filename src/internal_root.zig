const public_root = @import("root.zig");

pub const public_api = public_root;
pub const kernel = @import("kernel/root.zig");

pub const RuntimeError = exec.exceptions.RuntimeError;
pub const HostError = exec.exceptions.HostError;
pub const JSRuntime = kernel.JSRuntime;
pub const JSContext = kernel.JSContext;
pub const JSValue = kernel.JSValue;
pub const Object = kernel.Object;
pub const Descriptor = core.Descriptor;
pub const Atom = core.Atom;
pub const JSValueHandle = kernel.JSValueHandle;
pub const LocalHandle = kernel.LocalHandle;
pub const HandleScope = kernel.HandleScope;
pub const WeakPersistent = kernel.WeakPersistent;
pub const WeakPersistentValue = kernel.WeakPersistentValue;
pub const NativePin = core.NativePin;
pub const RuntimeMemoryUsage = kernel.RuntimeMemoryUsage;
pub const PropNameID = kernel.PropNameID;
pub const JSString = kernel.JSString;
pub const JSBytes = kernel.JSBytes;
pub const binding = kernel.binding;
pub const ffi = kernel.ffi;
pub const GCPolicy = core.GCPolicy;
pub const GCStats = core.GCStats;

pub const EvalOptions = core.context.EvalOptions;
pub const EvalTiming = core.context.EvalTiming;
pub const DataPropertyOptions = kernel.DataPropertyOptions;
pub const ExternalFunctionOptions = kernel.ExternalFunctionOptions;
pub const ExternalHostCall = kernel.ExternalHostCall;
pub const ExternalHostCallFn = kernel.ExternalHostCallFn;
pub const ExternalHostFinalizer = kernel.ExternalHostFinalizer;

pub const core = @import("core/root.zig");
pub const frontend = @import("frontend/root.zig");
pub const bytecode = @import("bytecode/root.zig");
pub const exec = @import("exec/root.zig");
pub const builtins = @import("builtins/root.zig");
pub const libs = @import("libs/root.zig");
pub const runtime = @import("runtime/root.zig");

test {
    const std = @import("std");

    try std.testing.expect(Object == kernel.Object);
    try std.testing.expect(@hasDecl(Object, "create"));
    try std.testing.expect(!@hasDecl(public_api.object.Object, "create"));

    _ = core;
    _ = frontend;
    _ = bytecode;
    _ = exec;
    _ = builtins;
    _ = libs;
    _ = runtime;
}
