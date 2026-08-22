//! Single-owner pending-exception storage for a realm context.
//!
//! `set` transfers one owned JSValue into the slot after clearing any previous
//! exception; `clear` releases it and `take` transfers it back to the caller.
//! The uninitialized sentinel means empty and is never a GC edge. This mirrors
//! QuickJS `JSContext.current_exception` near quickjs.c:528. The leaf belongs
//! to core context state and may not depend on higher engine layers.

const JSValue = @import("value.zig").JSValue;

pub const ExceptionSlot = struct {
    value: JSValue = JSValue.uninitialized(),

    pub fn hasException(self: ExceptionSlot) bool {
        return !self.value.isUninitialized();
    }

    pub fn set(self: *ExceptionSlot, rt: anytype, value: JSValue) void {
        self.clear(rt);
        self.value = value;
    }

    pub fn clear(self: *ExceptionSlot, rt: anytype) void {
        if (self.hasException()) {
            const old_value = self.value;
            self.value = JSValue.uninitialized();
            old_value.free(rt);
        }
    }

    pub fn take(self: *ExceptionSlot) JSValue {
        if (!self.hasException()) return JSValue.undefinedValue();
        const result = self.value;
        self.value = JSValue.uninitialized();
        return result;
    }
};
