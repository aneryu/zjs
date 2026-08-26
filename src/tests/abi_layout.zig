//! FNABI golden layout tests (FN-M0I acceptance, design §33).
//!
//! Four guarantees, each mechanized:
//!   1. Golden numbers — every public ABI struct's size and per-field offsets
//!      are pinned to explicit constants; any layout drift fails here first.
//!   2. No implicit padding — fields are provably contiguous through the tail
//!      (design §11.4: compiler-inserted padding positions must be explicit
//!      reservedN fields).
//!   3. Header freshness — the checked-in src/abi/fun_native_abi.h is
//!      byte-identical to what the schema renders.
//!   4. C/Zig round-trip — the generated header is compiled back via @cImport
//!      and every struct's size/alignment/field offsets must match the Zig
//!      schema, so a wrong C spelling cannot survive CI.
//! Plus the Value ABI binding: the ABI-side JSValue mirror is pinned to
//! src/core/value.zig reality (16-byte extern tagged, abi_encoding_revision).

const std = @import("std");
const abi = @import("../abi/fun_native_abi.zig");
const value = @import("../core/value.zig");
const c = @cImport(@cInclude("abi/fun_native_abi.h"));

fn expectNoImplicitPadding(comptime T: type) !void {
    comptime var expected: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        try std.testing.expectEqual(expected, @offsetOf(T, f.name));
        expected += @sizeOf(f.type);
    }
    try std.testing.expectEqual(expected, @sizeOf(T));
}

fn expectGolden(comptime T: type, comptime size: usize, comptime offsets: []const usize) !void {
    try std.testing.expectEqual(size, @sizeOf(T));
    const fields = @typeInfo(T).@"struct".fields;
    comptime std.debug.assert(fields.len == offsets.len);
    inline for (fields, offsets) |f, off| {
        try std.testing.expectEqual(off, @offsetOf(T, f.name));
    }
}

fn expectSameLayoutAsC(comptime Z: type, comptime C: type) !void {
    try std.testing.expectEqual(@sizeOf(Z), @sizeOf(C));
    try std.testing.expectEqual(@alignOf(Z), @alignOf(C));
    inline for (@typeInfo(Z).@"struct".fields) |f| {
        try std.testing.expectEqual(@offsetOf(Z, f.name), @offsetOf(C, f.name));
    }
}

test "FNABI golden layouts (sizes and field offsets)" {
    try expectGolden(abi.ZjsJSValue, 16, &.{ 0, 8 });
    try expectGolden(abi.FunUtf8RefV1, 16, &.{ 0, 8, 12 });
    try expectGolden(abi.FunFunctionDescriptorV1, 24, &.{ 0, 4, 6, 8, 10, 12, 16 });
    try expectGolden(abi.FunExportDescriptorV1, 48, &.{ 0, 4, 8, 24, 26, 28, 32, 40, 44 });
    try expectGolden(abi.FunPluginDescriptorV1, 120, &.{ 0, 4, 6, 8, 10, 12, 16, 24, 32, 48, 64, 80, 88, 92, 96, 104, 112 });
    try expectGolden(abi.FunPluginInitContextV1, 40, &.{ 0, 4, 8, 16, 24, 32 });
}

test "FNABI structs contain no implicit padding (design §11.4)" {
    inline for (abi.public_structs) |T| {
        try expectNoImplicitPadding(T);
    }
}

test "checked-in C header matches the schema (regenerate: zig run src/abi/gen_header.zig)" {
    try std.testing.expectEqualStrings(abi.c_header_text, @embedFile("../abi/fun_native_abi.h"));
}

test "C/Zig layout round-trip through the generated header" {
    try expectSameLayoutAsC(abi.ZjsJSValue, c.zjs_JSValue);
    try expectSameLayoutAsC(abi.FunUtf8RefV1, c.FunUtf8RefV1);
    try expectSameLayoutAsC(abi.FunFunctionDescriptorV1, c.FunFunctionDescriptorV1);
    try expectSameLayoutAsC(abi.FunExportDescriptorV1, c.FunExportDescriptorV1);
    try expectSameLayoutAsC(abi.FunPluginDescriptorV1, c.FunPluginDescriptorV1);
    try expectSameLayoutAsC(abi.FunPluginInitContextV1, c.FunPluginInitContextV1);
}

test "C header constants match the schema tables" {
    try std.testing.expectEqual(@as(u64, abi.plugin_abi_major), c.FUN_PLUGIN_ABI_MAJOR);
    try std.testing.expectEqual(@as(u64, abi.plugin_abi_minor), c.FUN_PLUGIN_ABI_MINOR);
    try std.testing.expectEqual(@as(u64, abi.fast_call_abi), c.FUN_FAST_CALL_ABI);
    try std.testing.expectEqual(@as(u64, abi.async_epoch_bits), c.FUN_ASYNC_EPOCH_BITS);
    try std.testing.expectEqual(@as(u64, abi.status.internal), c.FUN_STATUS_INTERNAL);
    try std.testing.expectEqual(@as(u64, abi.export_kind.const_utf8), c.FUN_EXPORT_CONST_UTF8);
    try std.testing.expectEqual(@as(u64, abi.call_kind.async_entry), c.FUN_CALL_ASYNC);
    try std.testing.expectEqual(@as(u64, abi.marshal_policy.canonical), c.FUN_MARSHAL_CANONICAL);
    try std.testing.expectEqual(@as(u64, abi.signatures[0].id), c.FUN_SIG_VOID_TO_VOID);
    try std.testing.expectEqual(@as(u64, abi.signatures[abi.signatures.len - 1].id), c.FUN_SIG_ASYNC_VALUE4);
}

test "signature ids are dense, unique, and start at 1 (0 reserved)" {
    var seen = [_]bool{false} ** (abi.signatures.len + 1);
    for (abi.signatures) |s| {
        try std.testing.expect(s.id >= 1 and s.id <= abi.signatures.len);
        try std.testing.expect(!seen[s.id]);
        seen[s.id] = true;
    }
}

test "Value ABI: the ABI mirror is pinned to src/core/value.zig reality (design §11.3)" {
    // Representation-contract v1 hard promise: 16-byte extern tagged, align 8.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(value.JSValue));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(value.JSValue));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(value.JSValue, "repr"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(value.JSValue.Repr, "payload"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(value.JSValue.Repr, "tag"));
    try std.testing.expectEqual(u64, @FieldType(value.JSValue.Repr, "payload"));
    try std.testing.expectEqual(i64, @FieldType(value.JSValue.Repr, "tag"));

    // ABI mirror equality (schema + C header sides).
    try std.testing.expectEqual(@sizeOf(value.JSValue), @sizeOf(abi.ZjsJSValue));
    try std.testing.expectEqual(@alignOf(value.JSValue), @alignOf(abi.ZjsJSValue));
    try std.testing.expectEqual(@offsetOf(value.JSValue.Repr, "payload"), @offsetOf(abi.ZjsJSValue, "payload"));
    try std.testing.expectEqual(@offsetOf(value.JSValue.Repr, "tag"), @offsetOf(abi.ZjsJSValue, "tag"));

    // The encoding revision that feeds the plugin ABI fingerprint (§11.3):
    // bumping it is a Value ABI event; this pin makes the bump reviewable.
    try std.testing.expectEqual(@as(u64, 1), value.JSValue.abi_encoding_revision);
}
