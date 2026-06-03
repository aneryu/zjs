pub const ErrorObject = struct {
    name: []const u8 = "Error",
    message: []const u8 = "",
};

pub const PrototypeMethod = enum(u32) {
    to_string = 1,
    stack_getter = 2,
    stack_setter = 3,
};

pub fn create(message: []const u8) ErrorObject {
    return .{ .message = message };
}
