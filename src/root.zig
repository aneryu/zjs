const std = @import("std");

pub const kernel = @import("kernel/root.zig");
pub const runtime = @import("runtime/public.zig");

pub const JSRuntime = kernel.JSRuntime;
pub const JSContext = kernel.JSContext;
pub const JSValue = kernel.JSValue;
pub const Object = kernel.Object;
pub const JSValueHandle = kernel.JSValueHandle;
pub const LocalHandle = kernel.LocalHandle;
pub const HandleScope = kernel.HandleScope;
pub const WeakPersistent = kernel.WeakPersistent;
pub const WeakPersistentValue = kernel.WeakPersistentValue;
pub const RuntimeOptions = kernel.RuntimeOptions;
pub const RuntimeMemoryUsage = kernel.RuntimeMemoryUsage;
pub const ContextOptions = kernel.ContextOptions;
pub const EvalOptions = kernel.EvalOptions;
pub const EvalMode = kernel.EvalMode;
pub const EvalTiming = kernel.EvalTiming;
pub const DataPropertyOptions = kernel.DataPropertyOptions;
pub const PropertyAccessOptions = kernel.PropertyAccessOptions;
pub const PropertyDescriptor = kernel.PropertyDescriptor;
pub const ExternalFunctionOptions = kernel.ExternalFunctionOptions;
pub const FunctionCallOptions = kernel.FunctionCallOptions;
pub const ErrorOptions = kernel.ErrorOptions;
pub const ScriptEvalOptions = kernel.ScriptEvalOptions;
pub const SharedArrayBufferRef = kernel.SharedArrayBufferRef;
pub const ExternalHostCall = kernel.ExternalHostCall;
pub const ExternalHostCallFn = kernel.ExternalHostCallFn;
pub const ExternalHostFinalizer = kernel.ExternalHostFinalizer;
pub const OpcodeProfile = kernel.OpcodeProfile;
pub const default_stack_size = kernel.default_stack_size;
pub const default_gc_threshold = kernel.default_gc_threshold;
pub const PropNameID = kernel.PropNameID;
pub const JSString = kernel.JSString;
pub const JSBytes = kernel.JSBytes;
pub const binding = kernel.binding;
pub const ffi = kernel.ffi;
pub const activateOpcodeProfile = kernel.activateOpcodeProfile;

test {
    _ = kernel;
    _ = runtime;
}

test "public root exposes only the explicit runtime surface" {
    try std.testing.expect(!@hasDecl(@This(), "internal"));
    try std.testing.expect(!@hasDecl(@This(), "core"));
    try std.testing.expect(!@hasDecl(@This(), "exec"));
    try std.testing.expect(!@hasDecl(@This(), "builtins"));
    try std.testing.expect(!@hasDecl(@This(), "Engine"));
    try std.testing.expect(!@hasDecl(@This(), "BorrowedValue"));
    try std.testing.expect(!@hasDecl(@This(), "OwnedValue"));
    try std.testing.expect(!@hasDecl(@This(), "Atom"));
    try std.testing.expect(!@hasDecl(@This(), "ClassId"));
    try std.testing.expect(!@hasDecl(@This(), "NativePin"));
    try std.testing.expect(!@hasDecl(JSRuntime, "pinValueForNative"));
    try std.testing.expect(!@hasDecl(JSRuntime, "pinHeaderForNative"));

    try std.testing.expect(@hasDecl(runtime, "EventLoop"));
    try std.testing.expect(@hasDecl(runtime, "EventLoopOptions"));
    try std.testing.expect(@hasDecl(runtime, "EventLoopRunResult"));
    try std.testing.expect(@hasDecl(runtime, "runUntilIdle"));
    try std.testing.expect(@hasDecl(runtime, "cleanupAtomicsWaitersForContext"));
    try std.testing.expect(@hasDecl(runtime, "wakeAtomicsWaitersForRuntimes"));
    try std.testing.expect(@hasDecl(runtime, "cleanupWorkersForRuntime"));
    try std.testing.expect(@hasDecl(runtime, "detachArrayBuffer"));
    try std.testing.expect(@hasDecl(runtime, "evalFileModuleGraphWithOutput"));
    try std.testing.expect(@hasDecl(runtime, "resolveModuleSpecifier"));
    try std.testing.expect(@hasDecl(runtime, "Plugin"));
    try std.testing.expect(@hasDecl(runtime, "PluginInstallOptions"));
    try std.testing.expect(Object == kernel.Object);

    try std.testing.expect(!@hasDecl(runtime, "event_loop"));
    try std.testing.expect(!@hasDecl(runtime, "plugin"));
    try std.testing.expect(!@hasDecl(runtime, "modules"));
    try std.testing.expect(!@hasDecl(runtime, "cleanup"));
    try std.testing.expect(!@hasDecl(runtime, "buffer"));
    try std.testing.expect(!@hasDecl(runtime, "Engine"));
    try std.testing.expect(!@hasDecl(runtime, "BorrowedValue"));
    try std.testing.expect(!@hasDecl(runtime, "OwnedValue"));
}
