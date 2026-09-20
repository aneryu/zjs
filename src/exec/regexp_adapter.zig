//! Runtime-aware adapter over the allocation-only regular-expression library.
//!
//! It bridges flat JS string storage, runtime stack-overflow/timeout checks,
//! capture slots, and canonical flags to `libs/regexp.zig`. Compiled handles
//! and caller-provided capture buffers retain their existing library ownership.

const core = @import("../core/root.zig");
const regexp_lib = @import("../libs/regexp.zig");
const regexp_bytecode = regexp_lib;
const std = @import("std");

pub const max_captures = regexp_bytecode.max_captures;
pub const max_exec_slots = regexp_bytecode.max_exec_slots;
pub const small_exec_slots = regexp_bytecode.small_exec_slots;
pub const Flags = regexp_bytecode.Flags;
pub const ExecResult = regexp_bytecode.ExecResult;
pub const ExecError = error{ OutOfMemory, BytecodeCorrupt, Timeout };

pub const Compiled = regexp_lib.Compiled;

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) !Compiled {
    return regexp_lib.compilePatternAndFlags(allocator, pattern, flags);
}

pub fn compileWithRuntime(rt: *core.JSRuntime, pattern: []const u8, flags: []const u8) !Compiled {
    return regexp_lib.compilePatternAndFlagsWithOptions(rt.memory.allocator, pattern, flags, .{ .host = runtimeHost(rt) });
}

pub const runtimeHost = core.regexp.libraryHost;

/// Execute against the flat string payload already retained by the caller.
/// QuickJS carries the same `JSString *`/buffer from `js_regexp_exec` into
/// `lre_exec`; keeping the resolved width here avoids re-decoding a JSValue on
/// every iteration of global match/replace loops.
pub fn execCaptureSlotsOnResolvedStringFromIndex(
    rt: *core.JSRuntime,
    compiled: Compiled,
    string_data: core.string.String.ResolvedData,
    start_index: usize,
    capture: []usize,
) ExecError!ExecResult {
    const options = execOptions(rt);
    return switch (string_data) {
        .latin1 => |bytes| try regexp_bytecode.execCaptureSlotsSliceTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index, options, capture),
        .utf16 => |units| try regexp_bytecode.execCaptureSlotsSliceTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .utf16 = units }, start_index, options, capture),
    };
}

pub fn captureSlotValue(value: usize) ?usize {
    return regexp_bytecode.captureSlotValue(value);
}

pub fn groupName(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8 {
    return regexp_bytecode.groupName(bytecode, one_based_capture_index);
}

pub fn testOnStringFromIndex(rt: *core.JSRuntime, compiled: Compiled, string_value: core.JSValue, start_index: usize) ExecError!?bool {
    const string_object = string_value.asStringBody() orelse return null;

    const options = execOptions(rt);
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| try regexp_bytecode.testMatchTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index, options),
        .utf16 => |units| try regexp_bytecode.testMatchTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .utf16 = units }, start_index, options),
    };
}

fn execOptions(rt: *core.JSRuntime) regexp_bytecode.ExecOptions {
    return .{ .host = runtimeHost(rt) };
}

pub fn flagsFromBytecode(bytecode: []const u8) Flags {
    return regexp_bytecode.getFlags(bytecode);
}

/// The `flags` getter's canonical spelling: alphabetical, `u` suppressed
/// under `v`.
pub fn appendCanonicalFlags(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), flags: Flags) !void {
    const order = [_]struct { byte: u8, field: std.meta.FieldEnum(Flags) }{
        .{ .byte = 'd', .field = .indices },
        .{ .byte = 'g', .field = .global },
        .{ .byte = 'i', .field = .ignore_case },
        .{ .byte = 'm', .field = .multiline },
        .{ .byte = 's', .field = .dot_all },
        .{ .byte = 'u', .field = .unicode },
        .{ .byte = 'v', .field = .unicode_sets },
        .{ .byte = 'y', .field = .sticky },
    };
    inline for (order) |entry| {
        if (@field(flags, @tagName(entry.field)) and !(entry.byte == 'u' and flags.unicode_sets))
            try buffer.append(allocator, entry.byte);
    }
}

pub fn flagsStringValueFromBytecode(rt: *core.JSRuntime, bytecode: []const u8) !core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendCanonicalFlags(rt.memory.allocator, &buffer, flagsFromBytecode(bytecode));
    return (try core.string.String.createAscii(rt, buffer.items)).value();
}

test "JavaScript RegExp adapter compilation and execution" {
    var compiled = try compile(std.testing.allocator, "abc", "i");
    defer compiled.deinit(std.testing.allocator);
    var slots: [max_exec_slots]usize = undefined;
    const result = try regexp_bytecode.execCaptureSlotsSliceTrustedWithOptions(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xxAbCy" }, 0, .{}, &slots);
    try std.testing.expect(result == .match);
    try std.testing.expectEqual(@as(usize, 2), regexp_bytecode.captureSlotValue(slots[0]).?);
    try std.testing.expectEqual(@as(usize, 5), regexp_bytecode.captureSlotValue(slots[1]).?);
}

test "JavaScript RegExp adapter preserves multiple named capture groups" {
    var compiled = try compile(std.testing.allocator, "(?<a>.)(?<b>.)(?<c>.)(?<d>.)", "");
    defer compiled.deinit(std.testing.allocator);

    var slots: [max_exec_slots]usize = undefined;
    const result = try regexp_bytecode.execCaptureSlotsSliceTrustedWithOptions(std.testing.allocator, compiled.bytecode, .{ .latin1 = "wxyz" }, 0, .{}, &slots);
    try std.testing.expect(result == .match);
    try std.testing.expectEqual(@as(usize, 5), compiled.captureCount());

    const expected_names = [_][]const u8{ "a", "b", "c", "d" };
    for (expected_names, 0..) |name, i| {
        const capture_index = i + 1;
        try std.testing.expectEqual(i, regexp_bytecode.captureSlotValue(slots[2 * capture_index]).?);
        try std.testing.expectEqual(i + 1, regexp_bytecode.captureSlotValue(slots[2 * capture_index + 1]).?);
        try std.testing.expectEqualStrings(name, compiled.groupName(capture_index).?);
    }
}
