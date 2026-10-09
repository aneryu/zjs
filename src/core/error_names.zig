//! Engine-core native error names and their kind tags.
//!
//! The taxonomy (`Error`, the simple `*Error` subclasses, `AggregateError`,
//! and `SuppressedError`) is engine metadata. This file imports only `std`.
//! `context.NativeErrorKind` re-exports the enum so realm prototype slots keep
//! that name. Exec consults `nativeErrorKind` instead of a second table.

const std = @import("std");

/// QuickJS `JSErrorEnum` subset. `count` is the length of a realm's
/// `native_error_proto[]`, not a constructor name.
pub const NativeErrorKind = enum(u8) {
    error_,
    eval_error,
    range_error,
    reference_error,
    syntax_error,
    type_error,
    uri_error,
    internal_error,
    aggregate_error,
    suppressed_error,
    count,
};

pub fn nativeErrorKind(name: []const u8) ?NativeErrorKind {
    const names = [_]struct { []const u8, NativeErrorKind }{
        .{ "Error", .error_ },
        .{ "EvalError", .eval_error },
        .{ "RangeError", .range_error },
        .{ "ReferenceError", .reference_error },
        .{ "SyntaxError", .syntax_error },
        .{ "TypeError", .type_error },
        .{ "URIError", .uri_error },
        .{ "InternalError", .internal_error },
        .{ "AggregateError", .aggregate_error },
        .{ "SuppressedError", .suppressed_error },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

pub fn isErrorConstructorName(name: []const u8) bool {
    return nativeErrorKind(name) != null;
}

test "error constructor name groups stay aligned" {
    const testing = std.testing;

    try testing.expect(isErrorConstructorName("Error"));
    try testing.expect(isErrorConstructorName("AggregateError"));
    try testing.expect(isErrorConstructorName("SuppressedError"));
    try testing.expect(isErrorConstructorName("TypeError"));
    try testing.expect(!isErrorConstructorName("DOMException"));

    try testing.expect(nativeErrorKind("Error") == .error_);
    try testing.expect(nativeErrorKind("AggregateError") == .aggregate_error);
    try testing.expect(nativeErrorKind("SuppressedError") == .suppressed_error);
    try testing.expect(nativeErrorKind("EvalError") == .eval_error);
    try testing.expect(nativeErrorKind("URIError") == .uri_error);
    try testing.expect(nativeErrorKind("InternalError") == .internal_error);
    try testing.expect(nativeErrorKind("DOMException") == null);
}
