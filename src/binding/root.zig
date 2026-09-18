//! Binding-layer aggregation: aliases for core/context types used by CLI,
//! test262, and in-repo tests. This root adds no wrapper ownership of its
//! own and must not depend on CLI.

const core = @import("../core/root.zig");

pub const JSRuntime = core.JSRuntime;
/// Read-only GC counter snapshot, as returned by `JSRuntime.gcStats()`.
pub const GCStats = core.GCStats;
/// Collection-pause percentiles, from `JSRuntime.gcPauseDistribution()`.
pub const GCPauseDistribution = core.GCPauseDistribution;
pub const context_mod = @import("context.zig");
pub const native = @import("native.zig");
pub const JSContext = context_mod.JSContext;
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
pub const FunctionCallOptions = core.FunctionCallOptions;
pub const ErrorOptions = core.ErrorOptions;
pub const ScriptEvalOptions = core.ScriptEvalOptions;
pub const SharedArrayBufferRef = core.SharedArrayBufferRef;
pub const OpcodeProfile = core.OpcodeProfile;
pub const default_stack_size = core.runtime.default_stack_size;
pub const default_gc_threshold = core.runtime.default_gc_threshold;

pub const JSString = core.JSValue.String;
pub const JSBytes = core.JSValue.Bytes;

pub const string = struct {
    pub const JSString = core.JSValue.String;
};

pub const bytes = struct {
    pub const JSBytes = core.JSValue.Bytes;
    pub const BytesError = core.JSValue.Bytes.Error;
};

pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile {
    return core.profile.activate(profile);
}

test {
    _ = JSString;
    _ = JSBytes;
    _ = Object;
    _ = RuntimeOptions;
    _ = RuntimeMemoryUsage;
    _ = ContextOptions;
    _ = EvalOptions;
    _ = EvalMode;
    _ = EvalTiming;
    _ = DataPropertyOptions;
    _ = PropertyAccessOptions;
    _ = PropertyDescriptor;
    _ = FunctionCallOptions;
    _ = ErrorOptions;
    _ = ScriptEvalOptions;
    _ = SharedArrayBufferRef;
    _ = OpcodeProfile;
}

test "JSValue lifetime names are aliases, not wrappers" {
    const std = @import("std");
    try std.testing.expect(!@hasDecl(JSValue, "Scope"));
    try std.testing.expect(!@hasDecl(JSValue, "Local"));
    try std.testing.expect(!@hasDecl(JSValue, "Persistent"));
    try std.testing.expect(!@hasDecl(JSValue, "Weak"));
    try std.testing.expectEqual(@sizeOf(core.JSValue), @sizeOf(JSValue));
    try std.testing.expect(!@hasDecl(@This(), "NativePin"));
    try std.testing.expect(!@hasDecl(@This(), "Atom"));
    try std.testing.expect(!@hasDecl(JSRuntime, "pinValueForNative"));
    try std.testing.expect(!@hasDecl(JSRuntime, "pinHeaderForNative"));
    try std.testing.expect(!@hasDecl(JSValue, "TypedArray"));
    try std.testing.expect(!@hasDecl(JSBytes.Store, "borrowed"));
    try std.testing.expect(!@hasDecl(JSBytes.Store, "fromBorrowed"));
}

test "binding JSString is the core JSValue string view" {
    const std = @import("std");
    try std.testing.expect(JSString == core.JSValue.String);
}

test "binding JSBytes is the core JSValue byte view" {
    const std = @import("std");
    try std.testing.expect(JSBytes == core.JSValue.Bytes);
}
