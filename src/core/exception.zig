//! Pending exception of a runtime (`JSRuntime.exception`).
//!
//! `install` transfers one owned JSValue into the slot after clearing any
//! previous exception; `clear` releases it and `take` transfers it back to the
//! caller. The uninitialized sentinel means empty and is never a GC edge. This
//! mirrors QuickJS `JSRuntime.exception.value`.

const JSValue = @import("value.zig").JSValue;

pub const Pending = struct {
    value: JSValue = JSValue.uninitialized(),
    /// QuickJS `current_exception_is_uncatchable`. Interrupt termination owns
    /// a real pending InternalError but bytecode catch markers must not consume
    /// it.
    uncatchable: bool = false,
    /// The pending exception is the engine's own out-of-memory InternalError.
    /// Allocation failure is deliberately catchable (see
    /// `exception_ops.runtimeErrorInfo`), so the native seam turns it into a
    /// JS exception; this flag lets `nativeHostError` restore
    /// `error.OutOfMemory` when no handler catches it.
    out_of_memory: bool = false,

    pub fn isSet(self: Pending) bool {
        return !self.value.is(.uninitialized);
    }

    /// Every ordinary throw goes through here, so a previous termination or
    /// OOM flag cannot survive on the new exception.
    pub fn install(self: *Pending, value: JSValue) void {
        self.* = .{ .value = value };
    }

    pub fn take(self: *Pending) JSValue {
        if (!self.isSet()) return JSValue.undefinedValue();
        const result = self.value;
        self.* = .{};
        return result;
    }

    pub fn clear(self: *Pending) void {
        self.* = .{};
    }
};
