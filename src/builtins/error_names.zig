const std = @import("std");

pub fn isErrorConstructorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Error") or isNativeErrorSubclassName(name);
}

pub fn isConstructErrorObjectName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Error") or
        std.mem.eql(u8, name, "AggregateError") or
        isSimpleNativeErrorConstructorName(name);
}

pub fn isNativeErrorSubclassName(name: []const u8) bool {
    return std.mem.eql(u8, name, "AggregateError") or
        std.mem.eql(u8, name, "SuppressedError") or
        isSimpleNativeErrorConstructorName(name);
}

pub fn isSimpleNativeErrorConstructorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "EvalError") or
        std.mem.eql(u8, name, "RangeError") or
        std.mem.eql(u8, name, "ReferenceError") or
        std.mem.eql(u8, name, "SyntaxError") or
        std.mem.eql(u8, name, "TypeError") or
        std.mem.eql(u8, name, "URIError");
}

test "error constructor name groups stay aligned" {
    const testing = std.testing;

    try testing.expect(isErrorConstructorName("Error"));
    try testing.expect(isErrorConstructorName("AggregateError"));
    try testing.expect(isErrorConstructorName("SuppressedError"));
    try testing.expect(isErrorConstructorName("TypeError"));
    try testing.expect(!isErrorConstructorName("DOMException"));

    try testing.expect(isConstructErrorObjectName("Error"));
    try testing.expect(isConstructErrorObjectName("AggregateError"));
    try testing.expect(isConstructErrorObjectName("TypeError"));
    try testing.expect(!isConstructErrorObjectName("SuppressedError"));

    try testing.expect(isNativeErrorSubclassName("AggregateError"));
    try testing.expect(isNativeErrorSubclassName("SuppressedError"));
    try testing.expect(isNativeErrorSubclassName("URIError"));
    try testing.expect(!isNativeErrorSubclassName("Error"));

    try testing.expect(isSimpleNativeErrorConstructorName("EvalError"));
    try testing.expect(!isSimpleNativeErrorConstructorName("AggregateError"));
    try testing.expect(!isSimpleNativeErrorConstructorName("SuppressedError"));
}
