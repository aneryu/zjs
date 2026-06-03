pub fn toString(value: bool) []const u8 {
    return if (value) "true" else "false";
}
