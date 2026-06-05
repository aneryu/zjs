pub const kernel = @import("kernel/root.zig");

pub const JSRuntime = kernel.JSRuntime;
pub const JSContext = kernel.JSContext;
pub const JSValue = kernel.JSValue;
pub const JSValueHandle = kernel.JSValueHandle;
pub const LocalHandle = kernel.LocalHandle;
pub const HandleScope = kernel.HandleScope;
pub const WeakPersistent = kernel.WeakPersistent;
pub const WeakPersistentValue = kernel.WeakPersistentValue;
pub const NativePin = kernel.NativePin;
pub const PropNameID = kernel.PropNameID;
pub const JSString = kernel.JSString;
pub const JSBytes = kernel.JSBytes;
pub const binding = kernel.binding;
pub const ffi = kernel.ffi;

test {
    _ = kernel;
}
