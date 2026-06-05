const core = @import("../core/root.zig");

pub const JSRuntime = core.JSRuntime;
pub const JSContext = core.JSContext;
pub const JSValue = core.JSValue;

pub const JSValueHandle = core.JSValueHandle;
pub const LocalHandle = core.LocalHandle;
pub const HandleScope = core.HandleScope;
pub const WeakPersistent = core.WeakPersistent;
pub const WeakPersistentValue = core.WeakPersistentValue;
pub const NativePin = core.NativePin;

pub const prop_name = @import("prop_name.zig");
pub const string = @import("string.zig");
pub const bytes = @import("bytes.zig");
pub const binding = @import("binding.zig");
pub const ffi = @import("ffi.zig");

pub const PropNameID = prop_name.PropNameID;
pub const JSString = string.JSString;
pub const JSBytes = bytes.JSBytes;

test {
    _ = PropNameID;
    _ = JSString;
    _ = JSBytes;
    _ = binding;
    _ = ffi;
}

test "JSValue lifetime names are aliases, not wrappers" {
    const std = @import("std");
    try std.testing.expect(JSValue.Scope == HandleScope);
    try std.testing.expect(JSValue.Local == LocalHandle);
    try std.testing.expect(JSValue.Persistent == JSValueHandle);
    try std.testing.expect(JSValue.Weak == WeakPersistentValue);
    try std.testing.expectEqual(@sizeOf(core.JSValue), @sizeOf(JSValue));
}
