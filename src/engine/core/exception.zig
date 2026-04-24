const Value = @import("value.zig").Value;

pub const ExceptionSlot = struct {
    value: Value = Value.uninitialized(),

    pub fn hasException(self: ExceptionSlot) bool {
        return !self.value.isUninitialized();
    }

    pub fn set(self: *ExceptionSlot, rt: anytype, value: Value) void {
        self.clear(rt);
        self.value = value;
    }

    pub fn clear(self: *ExceptionSlot, rt: anytype) void {
        if (self.hasException()) {
            self.value.free(rt);
            self.value = Value.uninitialized();
        }
    }

    pub fn take(self: *ExceptionSlot) Value {
        if (!self.hasException()) return Value.undefinedValue();
        const result = self.value;
        self.value = Value.uninitialized();
        return result;
    }
};
