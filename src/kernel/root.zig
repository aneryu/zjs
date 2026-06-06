const core = @import("../core/root.zig");

pub const JSRuntime = core.JSRuntime;
pub const JSContext = core.JSContext;
pub const JSValue = core.JSValue;
pub const Object = core.Object;

pub const JSValueHandle = core.JSValueHandle;
pub const LocalHandle = core.LocalHandle;
pub const HandleScope = core.HandleScope;
pub const WeakPersistent = core.WeakPersistent;
pub const WeakPersistentValue = core.WeakPersistentValue;
pub const RuntimeOptions = core.RuntimeOptions;
pub const RuntimeMemoryUsage = core.RuntimeMemoryUsage;
pub const ContextOptions = core.ContextOptions;
pub const EvalOptions = core.EvalOptions;
pub const EvalMode = core.EvalMode;
pub const EvalTiming = core.EvalTiming;
pub const DataPropertyOptions = core.DataPropertyOptions;
pub const PropertyAccessOptions = core.PropertyAccessOptions;
pub const PropertyDescriptor = core.PropertyDescriptor;
pub const ExternalFunctionOptions = core.ExternalFunctionOptions;
pub const FunctionCallOptions = core.FunctionCallOptions;
pub const ErrorOptions = core.ErrorOptions;
pub const ScriptEvalOptions = core.ScriptEvalOptions;
pub const SharedArrayBufferRef = core.SharedArrayBufferRef;
pub const ExternalHostCall = core.ExternalHostCall;
pub const ExternalHostCallFn = core.ExternalHostCallFn;
pub const ExternalHostFinalizer = core.ExternalHostFinalizer;
pub const OpcodeProfile = core.OpcodeProfile;
pub const default_stack_size = core.runtime.default_stack_size;
pub const default_gc_threshold = core.runtime.default_gc_threshold;

pub const prop_name = @import("prop_name.zig");
pub const string = @import("string.zig");
pub const bytes = @import("bytes.zig");
pub const binding = @import("binding.zig");
pub const ffi = @import("ffi.zig");

pub const PropNameID = prop_name.PropNameID;
pub const JSString = string.JSString;
pub const JSBytes = bytes.JSBytes;

pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile {
    return core.profile.activate(profile);
}

test {
    _ = PropNameID;
    _ = JSString;
    _ = JSBytes;
    _ = Object;
    _ = binding;
    _ = ffi;
    _ = RuntimeOptions;
    _ = RuntimeMemoryUsage;
    _ = ContextOptions;
    _ = EvalOptions;
    _ = EvalMode;
    _ = EvalTiming;
    _ = DataPropertyOptions;
    _ = PropertyAccessOptions;
    _ = PropertyDescriptor;
    _ = ExternalFunctionOptions;
    _ = FunctionCallOptions;
    _ = ErrorOptions;
    _ = ScriptEvalOptions;
    _ = SharedArrayBufferRef;
    _ = ExternalHostCall;
    _ = ExternalHostCallFn;
    _ = ExternalHostFinalizer;
    _ = OpcodeProfile;
}

test "JSValue lifetime names are aliases, not wrappers" {
    const std = @import("std");
    try std.testing.expect(JSValue.Scope == HandleScope);
    try std.testing.expect(JSValue.Local == LocalHandle);
    try std.testing.expect(JSValue.Persistent == JSValueHandle);
    try std.testing.expect(JSValue.Weak == WeakPersistentValue);
    try std.testing.expectEqual(@sizeOf(core.JSValue), @sizeOf(JSValue));
    try std.testing.expect(switch (@typeInfo(PropNameID)) {
        .@"struct" => true,
        else => false,
    });
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(PropNameID));
    try std.testing.expect(!@hasDecl(@This(), "NativePin"));
    try std.testing.expect(!@hasDecl(@This(), "Atom"));
    try std.testing.expect(!@hasDecl(JSRuntime, "pinValueForNative"));
    try std.testing.expect(!@hasDecl(JSRuntime, "pinHeaderForNative"));
    try std.testing.expect(!@hasDecl(JSValue, "TypedArray"));
    try std.testing.expect(!@hasDecl(JSBytes.Store, "borrowed"));
    try std.testing.expect(!@hasDecl(JSBytes.Store, "fromBorrowed"));
    try std.testing.expect(!@hasDecl(ffi, "asyncBinding"));
}
