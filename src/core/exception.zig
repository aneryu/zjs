//! Single-owner pending-exception storage for a realm context.
//!
//! `set` transfers one owned JSValue into the slot after clearing any previous
//! exception; `clear` releases it and `take` transfers it back to the caller.
//! The uninitialized sentinel means empty and is never a GC edge. This mirrors
//! QuickJS `JSContext.current_exception` near quickjs.c. The leaf belongs
//! to core context state and may not depend on higher engine layers.

const JSValue = @import("value.zig").JSValue;
const JSRuntime = @import("runtime.zig").JSRuntime;

/// Install `value` and clear both the uncatchable and out-of-memory flags.
/// Every ordinary throw goes through here so a previous termination or OOM
/// flag cannot survive on the new exception.
pub fn install(rt: *JSRuntime, value: JSValue) void {
    clear(rt);
    rt.current_exception = value;
}

pub fn take(rt: *JSRuntime) JSValue {
    if (rt.current_exception.is(.uninitialized)) return JSValue.undefinedValue();
    const result = rt.current_exception;
    clear(rt);
    return result;
}

pub fn clear(rt: *JSRuntime) void {
    rt.current_exception = JSValue.uninitialized();
    rt.current_exception_uncatchable = false;
    rt.current_exception_out_of_memory = false;
}

pub fn setUncatchable(rt: *JSRuntime, uncatchable: bool) void {
    rt.current_exception_uncatchable = uncatchable;
}

pub fn markOutOfMemory(rt: *JSRuntime) void {
    rt.current_exception_out_of_memory = true;
}

pub const ExceptionSlot = struct {
    value: JSValue = JSValue.uninitialized(),

    pub fn hasException(self: ExceptionSlot) bool {
        return !self.value.is(.uninitialized);
    }

    pub fn set(self: *ExceptionSlot, rt: anytype, value: JSValue) void {
        self.clear(rt);
        self.value = value;
    }

    pub fn clear(self: *ExceptionSlot, _: anytype) void {
        if (self.hasException()) {
            self.value = JSValue.uninitialized();
        }
    }

    pub fn take(self: *ExceptionSlot) JSValue {
        if (!self.hasException()) return JSValue.undefinedValue();
        const result = self.value;
        self.value = JSValue.uninitialized();
        return result;
    }
};
