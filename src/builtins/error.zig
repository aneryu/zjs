//! Transitional compatibility shim. Error native records and JS-visible method
//! bodies live in `exec/error_ops.zig`.

const error_ops = @import("../exec/error_ops.zig");

pub const ErrorObject = struct {
    name: []const u8 = "Error",
    message: []const u8 = "",
};

pub const PrototypeMethod = error_ops.PrototypeMethod;
pub const StaticMethod = error_ops.StaticMethod;
pub const internal_entries = error_ops.internal_entries;

pub fn create(message: []const u8) ErrorObject {
    return .{ .message = message };
}
