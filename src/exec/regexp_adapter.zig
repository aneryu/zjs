const core = @import("../core/root.zig");
const regexp_lib = @import("../libs/regexp.zig");
const regexp_bytecode = regexp_lib;
const std = @import("std");

pub const max_captures = regexp_bytecode.max_captures;
pub const max_exec_slots = regexp_bytecode.max_exec_slots;
pub const small_exec_slots = regexp_bytecode.small_exec_slots;
pub const flag_bits = regexp_bytecode.flags;
pub const Capture = regexp_bytecode.Capture;
pub const Match = regexp_bytecode.Match;
pub const ExecStatus = regexp_bytecode.ExecStatus;
pub const ExecResult = regexp_bytecode.ExecResult;
pub const ExecError = error{ OutOfMemory, BytecodeCorrupt, Timeout };

pub const Compiled = regexp_lib.Compiled;

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) !Compiled {
    return regexp_lib.compilePatternAndFlags(allocator, pattern, flags);
}

pub fn execOnStringFromIndex(rt: *core.JSRuntime, compiled: Compiled, string_value: core.JSValue, start_index: usize) ExecError!ExecStatus {
    var match: Match = undefined;
    return switch (try execIntoMatchOnStringFromIndex(rt, compiled, string_value, start_index, &match)) {
        .match => .{ .result = .match, .match = match },
        .no_match => .{ .result = .no_match },
        .out_of_range => .{ .result = .out_of_range },
        .not_available => .{ .result = .not_available },
    };
}

pub fn execIntoMatchOnStringFromIndex(
    rt: *core.JSRuntime,
    compiled: Compiled,
    string_value: core.JSValue,
    start_index: usize,
    out_match: *Match,
) ExecError!ExecResult {
    const string_object = string_value.asStringBody() orelse return .not_available;
    try string_object.ensureFlat(rt);

    const options = execOptions(rt);
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| try regexp_bytecode.execIntoMatchTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index, options, out_match),
        .utf16 => |units| try regexp_bytecode.execIntoMatchTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .utf16 = units }, start_index, options, out_match),
    };
}

pub fn execCaptureSlotsOnStringFromIndex(
    rt: *core.JSRuntime,
    compiled: Compiled,
    string_value: core.JSValue,
    start_index: usize,
    capture: []usize,
) ExecError!ExecResult {
    const string_object = string_value.asStringBody() orelse return .not_available;
    try string_object.ensureFlat(rt);

    return execCaptureSlotsOnResolvedStringFromIndex(rt, compiled, string_object.resolveData(), start_index, capture);
}

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
    try string_object.ensureFlat(rt);

    const options = execOptions(rt);
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| try regexp_bytecode.testMatchTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index, options),
        .utf16 => |units| try regexp_bytecode.testMatchTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .utf16 = units }, start_index, options),
    };
}

fn execOptions(rt: *core.JSRuntime) regexp_bytecode.ExecOptions {
    if (!rt.hasInterruptHandler()) return .{};
    return .{
        .@"opaque" = rt,
        .check_timeout = checkRuntimeTimeout,
    };
}

fn checkRuntimeTimeout(context: ?*anyopaque) bool {
    const rt: *core.JSRuntime = @ptrCast(@alignCast(context orelse return false));
    return rt.runInterruptHandler();
}

pub fn flagBitsFromBytecode(bytecode: []const u8) u16 {
    return regexp_bytecode.getFlags(bytecode);
}

pub fn appendCanonicalFlagsFromBits(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), bits: u16) !void {
    const order = [_]struct { byte: u8, bit: u16 }{
        .{ .byte = 'd', .bit = regexp_bytecode.flags.indices },
        .{ .byte = 'g', .bit = regexp_bytecode.flags.global },
        .{ .byte = 'i', .bit = regexp_bytecode.flags.ignore_case },
        .{ .byte = 'm', .bit = regexp_bytecode.flags.multiline },
        .{ .byte = 's', .bit = regexp_bytecode.flags.dot_all },
        .{ .byte = 'u', .bit = regexp_bytecode.flags.unicode },
        .{ .byte = 'v', .bit = regexp_bytecode.flags.unicode_sets },
        .{ .byte = 'y', .bit = regexp_bytecode.flags.sticky },
    };
    for (order) |entry| {
        if (entry.byte == 'u' and (bits & regexp_bytecode.flags.unicode_sets) != 0) continue;
        if ((bits & entry.bit) != 0) try buffer.append(allocator, entry.byte);
    }
}

pub fn flagsStringValueFromBytecode(rt: *core.JSRuntime, bytecode: []const u8) !core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendCanonicalFlagsFromBits(rt.memory.allocator, &buffer, flagBitsFromBytecode(bytecode));
    return (try core.string.String.createAscii(rt, buffer.items)).value();
}

test "JavaScript RegExp adapter compilation and execution" {
    var compiled = try compile(std.testing.allocator, "abc", "i");
    defer compiled.deinit(std.testing.allocator);
    const status = try regexp_bytecode.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xxAbCy" }, 0);
    try std.testing.expect(status.result == .match);
    try std.testing.expectEqual(@as(usize, 2), status.match.start);
    try std.testing.expectEqual(@as(usize, 5), status.match.end);
}

test "JavaScript RegExp adapter preserves multiple named capture groups" {
    var compiled = try compile(std.testing.allocator, "(?<a>.)(?<b>.)(?<c>.)(?<d>.)", "");
    defer compiled.deinit(std.testing.allocator);

    const status = try regexp_bytecode.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "wxyz" }, 0);
    try std.testing.expect(status.result == .match);
    try std.testing.expectEqual(@as(usize, 4), status.match.capture_count);

    const expected_names = [_][]const u8{ "a", "b", "c", "d" };
    for (expected_names, 0..) |name, i| {
        try std.testing.expectEqual(i, status.match.captures[i].start.?);
        try std.testing.expectEqual(i + 1, status.match.captures[i].end.?);
        try std.testing.expectEqualStrings(name, status.match.captures[i].name.?);
    }
}
