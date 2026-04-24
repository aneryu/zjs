pub const ErrorObject = struct {
    name: []const u8 = "Error",
    message: []const u8 = "",
};

pub fn create(message: []const u8) ErrorObject {
    return .{ .message = message };
}
