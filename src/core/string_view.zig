const std = @import("std");
const unicode = @import("../libs/unicode.zig");
const string_mod = @import("string.zig");

pub fn JSString(comptime Value: type) type {
    return struct {
        js_value: Value,
        ptr: *const string_mod.String,

        const Self = @This();

        pub const Units = union(enum) {
            latin1: []const u8,
            utf16: []const u16,
        };

        pub const Utf8 = struct {
            bytes: []const u8,
            owned: ?[]u8 = null,
            allocator: ?std.mem.Allocator = null,

            pub fn init(allocator: std.mem.Allocator, string: Self) !Utf8 {
                switch (string.ptr.resolveData()) {
                    .latin1 => |latin1| {
                        if (isAscii(latin1)) {
                            return .{ .bytes = latin1 };
                        }
                        const owned = try string.toOwnedUtf8(allocator);
                        return .{
                            .bytes = owned,
                            .owned = owned,
                            .allocator = allocator,
                        };
                    },
                    .utf16 => {
                        const owned = try string.toOwnedUtf8(allocator);
                        return .{
                            .bytes = owned,
                            .owned = owned,
                            .allocator = allocator,
                        };
                    },
                }
            }

            pub fn fromValue(allocator: std.mem.Allocator, js_value: Value) !Utf8 {
                const string = Self.fromValue(js_value) orelse return error.TypeError;
                return init(allocator, string);
            }

            pub fn slice(self: Utf8) []const u8 {
                return self.bytes;
            }

            pub fn isBorrowed(self: Utf8) bool {
                return self.owned == null;
            }

            pub fn deinit(self: *Utf8) void {
                const owned = self.owned orelse {
                    self.bytes = &.{};
                    return;
                };
                const allocator = self.allocator.?;
                self.bytes = &.{};
                self.owned = null;
                self.allocator = null;
                allocator.free(owned);
            }
        };

        pub fn fromValue(js_value: Value) ?Self {
            if (!js_value.isString()) return null;
            const header = js_value.refHeader() orelse return null;
            if (header.kind != .string) return null;
            const string_ptr: *const string_mod.String = @fieldParentPtr("header", header);
            return .{
                .js_value = js_value,
                .ptr = string_ptr,
            };
        }

        pub fn value(self: Self) Value {
            return self.js_value;
        }

        pub fn units(self: Self) ?Units {
            return switch (self.ptr.resolveData()) {
                .latin1 => |latin1| .{ .latin1 = latin1 },
                .utf16 => |utf16| .{ .utf16 = utf16 },
            };
        }

        pub fn toUtf8(self: Self, allocator: std.mem.Allocator) !Utf8 {
            return Utf8.init(allocator, self);
        }

        pub fn toOwnedUtf8(self: Self, allocator: std.mem.Allocator) ![]u8 {
            const len = switch (self.ptr.resolveData()) {
                .latin1 => |latin1| utf8LenLatin1(latin1),
                .utf16 => |utf16| utf8LenUtf16(utf16),
            };
            const out = try allocator.alloc(u8, len);
            var offset: usize = 0;
            switch (self.ptr.resolveData()) {
                .latin1 => |latin1| {
                    for (latin1) |byte| offset += writeUtf8CodeUnit(out[offset..], byte);
                },
                .utf16 => |utf16| {
                    var index: usize = 0;
                    while (index < utf16.len) {
                        const unit = utf16[index];
                        if (isHighSurrogate(unit) and index + 1 < utf16.len and isLowSurrogate(utf16[index + 1])) {
                            const cp = surrogatePairCodePoint(unit, utf16[index + 1]);
                            offset += writeUtf8CodePoint(out[offset..], cp);
                            index += 2;
                            continue;
                        }
                        offset += writeUtf8CodeUnit(out[offset..], unit);
                        index += 1;
                    }
                },
            }
            std.debug.assert(offset == out.len);
            return out;
        }
    };
}

fn isAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte > 0x7f) return false;
    }
    return true;
}

fn utf8LenLatin1(bytes: []const u8) usize {
    var len: usize = 0;
    for (bytes) |byte| len += if (byte <= 0x7f) @as(usize, 1) else 2;
    return len;
}

fn utf8LenUtf16(units: []const u16) usize {
    var len: usize = 0;
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        if (isHighSurrogate(unit) and index + 1 < units.len and isLowSurrogate(units[index + 1])) {
            len += 4;
            index += 2;
            continue;
        }
        len += utf8LenCodeUnit(unit);
        index += 1;
    }
    return len;
}

fn utf8LenCodeUnit(unit: u16) usize {
    if (unit <= 0x7f) return 1;
    if (unit <= 0x7ff) return 2;
    return 3;
}

fn writeUtf8CodeUnit(out: []u8, unit: u16) usize {
    return writeUtf8CodePoint(out, unit);
}

fn writeUtf8CodePoint(out: []u8, code_point: u32) usize {
    if (code_point <= 0x7f) {
        out[0] = @intCast(code_point);
        return 1;
    }
    if (code_point <= 0x7ff) {
        out[0] = @intCast(0xc0 | (code_point >> 6));
        out[1] = @intCast(0x80 | (code_point & 0x3f));
        return 2;
    }
    if (code_point <= 0xffff) {
        out[0] = @intCast(0xe0 | (code_point >> 12));
        out[1] = @intCast(0x80 | ((code_point >> 6) & 0x3f));
        out[2] = @intCast(0x80 | (code_point & 0x3f));
        return 3;
    }
    out[0] = @intCast(0xf0 | (code_point >> 18));
    out[1] = @intCast(0x80 | ((code_point >> 12) & 0x3f));
    out[2] = @intCast(0x80 | ((code_point >> 6) & 0x3f));
    out[3] = @intCast(0x80 | (code_point & 0x3f));
    return 4;
}

fn isHighSurrogate(unit: u16) bool {
    return unicode.isHighSurrogateUnit(unit);
}

fn isLowSurrogate(unit: u16) bool {
    return unicode.isLowSurrogateUnit(unit);
}

fn surrogatePairCodePoint(high: u16, low: u16) u32 {
    return @intCast(unicode.codePointFromSurrogatePair(high, low));
}

test "JSValue.asString views latin1 units without allocation" {
    const core = @import("root.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const str = try core.string.String.createUtf8(rt, "hello");
    const value = str.value();
    defer value.free(rt);

    const view = value.asString().?;
    try std.testing.expectEqual(value, view.value());
    try std.testing.expectEqualStrings("hello", view.units().?.latin1);

    const utf8 = try view.toOwnedUtf8(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("hello", utf8);
}

test "JSString.units views sliced backing without flattening" {
    const core = @import("root.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const parent = try core.string.String.createUtf8(rt, "prefix-needle-suffix");
    const parent_value = parent.value();
    defer parent_value.free(rt);

    const slice = try core.string.String.createSlice(rt, parent, "prefix-".len, "needle".len);
    const slice_value = slice.value();
    defer slice_value.free(rt);

    const parent_units = parent_value.asString().?.units().?.latin1;
    const slice_units = slice_value.asString().?.units().?.latin1;
    try std.testing.expectEqualStrings("needle", slice_units);
    try std.testing.expect(slice_units.ptr == parent_units.ptr + "prefix-".len);

    var utf8 = try slice_value.asString().?.toUtf8(std.testing.allocator);
    defer utf8.deinit();
    try std.testing.expect(utf8.isBorrowed());
    try std.testing.expect(utf8.slice().ptr == slice_units.ptr);
}

test "JSString converts utf16 surrogate pairs to owned utf8" {
    const core = @import("root.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const str = try core.string.String.createUtf16(rt, &.{ 0xd83d, 0xde00 });
    const value = str.value();
    defer value.free(rt);

    const view = value.asString().?;
    const utf8 = try view.toOwnedUtf8(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualSlices(u8, "\xf0\x9f\x98\x80", utf8);
}

test "JSString.Utf8 borrows latin1 ascii without allocation" {
    const core = @import("root.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const str = try core.string.String.createUtf8(rt, "ascii/path.txt");
    const value = str.value();
    defer value.free(rt);

    const view = value.asString().?;
    const units = view.units().?.latin1;
    var utf8 = try view.toUtf8(std.testing.allocator);
    defer utf8.deinit();

    try std.testing.expect(utf8.isBorrowed());
    try std.testing.expect(utf8.slice().ptr == units.ptr);
    try std.testing.expectEqualStrings("ascii/path.txt", utf8.slice());
}

test "JSString.Utf8 transcodes latin1 non-ascii through scratch allocator" {
    const core = @import("root.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const str = try core.string.String.createUtf8(rt, "é");
    const value = str.value();
    defer value.free(rt);

    const view = value.asString().?;
    try std.testing.expectEqual(@as(u8, 0xe9), view.units().?.latin1[0]);
    var utf8 = try view.toUtf8(std.testing.allocator);
    defer utf8.deinit();

    try std.testing.expect(!utf8.isBorrowed());
    try std.testing.expectEqualSlices(u8, "\xc3\xa9", utf8.slice());
}

test "JSString.Utf8 transcodes utf16 through scratch allocator" {
    const core = @import("root.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const str = try core.string.String.createUtf16(rt, &.{ 0x0100, 0xd83d, 0xde00 });
    const value = str.value();
    defer value.free(rt);

    const view = value.asString().?;
    var utf8 = try core.JSValue.String.Utf8.init(std.testing.allocator, view);
    defer utf8.deinit();

    try std.testing.expect(!utf8.isBorrowed());
    try std.testing.expectEqualSlices(u8, "\xc4\x80\xf0\x9f\x98\x80", utf8.slice());
}

test "JSString.Utf8 rejects non-string values" {
    const core = @import("root.zig");
    try std.testing.expectError(error.TypeError, core.JSValue.String.Utf8.fromValue(std.testing.allocator, core.JSValue.int32(1)));
}

test "JSContext.toString performs ECMAScript ToString instead of tag assertion" {
    const core = @import("root.zig");
    const zjs = @import("../binding/root.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const wrapper: *zjs.JSContext = @ptrCast(ctx);
    const object = try wrapper.eval("({ toString() { return 'semantic-string'; } })", .{});
    defer object.free(rt);
    try std.testing.expect(object.asString() == null);

    const converted = try wrapper.toString(object);
    defer converted.free(rt);
    try std.testing.expectEqualStrings("semantic-string", converted.asString().?.units().?.latin1);
}
