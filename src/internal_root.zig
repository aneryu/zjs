const public_root = @import("root.zig");

pub const public_api = public_root;
pub const binding_root = @import("binding/root.zig");

pub const RuntimeError = exec.exceptions.RuntimeError;
pub const HostError = exec.exceptions.HostError;
pub const JSRuntime = binding_root.JSRuntime;
pub const JSContext = binding_root.JSContext;
pub const JSValue = binding_root.JSValue;
pub const Object = binding_root.Object;
pub const Descriptor = core.Descriptor;
pub const Atom = core.Atom;
pub const JSValueHandle = binding_root.JSValueHandle;
pub const LocalHandle = binding_root.LocalHandle;
pub const HandleScope = binding_root.HandleScope;
pub const WeakPersistent = binding_root.WeakPersistent;
pub const WeakPersistentValue = binding_root.WeakPersistentValue;
pub const NativePin = core.NativePin;
pub const RuntimeMemoryUsage = binding_root.RuntimeMemoryUsage;
pub const PropNameID = binding_root.PropNameID;
pub const JSString = binding_root.JSString;
pub const JSBytes = binding_root.JSBytes;
pub const binding = binding_root.binding;
pub const ffi = binding_root.ffi;
pub const GCPolicy = core.GCPolicy;
pub const GCStats = core.GCStats;

pub const EvalOptions = core.context.EvalOptions;
pub const EvalTiming = core.context.EvalTiming;
pub const DataPropertyOptions = binding_root.DataPropertyOptions;
pub const ExternalFunctionOptions = binding_root.ExternalFunctionOptions;
pub const ExternalHostCall = binding_root.ExternalHostCall;
pub const ExternalHostCallFn = binding_root.ExternalHostCallFn;
pub const ExternalHostFinalizer = binding_root.ExternalHostFinalizer;

pub const core = @import("core/root.zig");
pub const parser = @import("parser.zig");
pub const bytecode = @import("bytecode.zig");
pub const exec = @import("exec/root.zig");
pub const builtins = @import("builtins/root.zig");
pub const libs = @import("libs/root.zig");
pub const runtime = @import("runtime/root.zig");

test {
    const std = @import("std");

    try std.testing.expect(Object == binding_root.Object);
    try std.testing.expect(@hasDecl(Object, "create"));
    try std.testing.expect(!@hasDecl(public_api.object.Object, "create"));

    _ = core;
    _ = parser;
    _ = bytecode;
    _ = exec;
    _ = builtins;
    _ = libs;
    _ = runtime;
}
