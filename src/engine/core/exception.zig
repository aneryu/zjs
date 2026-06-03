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
