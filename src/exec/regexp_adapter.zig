//! Runtime-aware adapter over the allocation-only regular-expression library.
//!
//! It bridges flat JS string storage, runtime stack-overflow/timeout checks,
//! capture slots, and canonical flags to `libs/regexp.zig`. Compiled handles
//! and caller-provided capture buffers retain their existing library ownership.

const core = @import("../core/root.zig");
const regexp_lib = @import("../libs/regexp.zig");
const std = @import("std");

pub const max_captures = regexp_lib.max_captures;
pub const max_exec_slots = regexp_lib.max_exec_slots;
pub const small_exec_slots = regexp_lib.small_exec_slots;
pub const flag_bits = regexp_lib.flags;
pub const Capture = regexp_lib.Capture;
pub const Match = regexp_lib.Match;
pub const ExecStatus = regexp_lib.ExecStatus;
pub const ExecResult = regexp_lib.ExecResult;
pub const ExecError = error{ OutOfMemory, BytecodeCorrupt, Timeout };
pub const Header = regexp_lib.Header;

pub const Compiled = regexp_lib.Compiled;

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) !Compiled {
    return regexp_lib.compilePatternAndFlags(allocator, pattern, flags);
}

pub fn compileWithRuntime(rt: *core.JSRuntime, pattern: []const u8, flags: []const u8) !Compiled {
    return regexp_lib.compilePatternAndFlagsWithOptions(rt.memory.allocator, pattern, flags, .{
        .@"opaque" = rt,
        .check_stack_overflow = lreCheckStackOverflow,
    });
}

fn lreCheckStackOverflow(opaque_ptr: ?*anyopaque, alloca_size: usize) bool {
    // qjs:quickjs.c:48000 lre_check_stack_overflow -> js_check_stack_overflow(ctx->rt, alloca_size)
    const runtime: *core.JSRuntime = @ptrCast(@alignCast(opaque_ptr orelse return false));
    return runtime.checkNativeStackOverflow(alloca_size);
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
        .latin1 => |bytes| try regexp_lib.execCaptureSlotsSliceTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index, options, capture),
        .utf16 => |units| try regexp_lib.execCaptureSlotsSliceTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .utf16 = units }, start_index, options, capture),
    };
}

pub fn captureSlotValue(value: usize) ?usize {
    return regexp_lib.captureSlotValue(value);
}

pub fn groupName(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8 {
    return regexp_lib.groupName(bytecode, one_based_capture_index);
}

pub fn testOnStringFromIndex(rt: *core.JSRuntime, compiled: Compiled, string_value: core.JSValue, start_index: usize) ExecError!?bool {
    const string_object = string_value.asStringBody() orelse return null;
    try string_object.ensureFlat(rt);

    const options = execOptions(rt);
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| try regexp_lib.testMatchTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index, options),
        .utf16 => |units| try regexp_lib.testMatchTrustedWithOptions(rt.memory.allocator, compiled.bytecode, .{ .utf16 = units }, start_index, options),
    };
}

fn execOptions(rt: *core.JSRuntime) regexp_lib.ExecOptions {
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
    return regexp_lib.getFlags(bytecode);
}

pub fn appendCanonicalFlagsFromBits(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), bits: u16) !void {
    const order = [_]struct { byte: u8, bit: u16 }{
        .{ .byte = 'd', .bit = regexp_lib.flags.indices },
        .{ .byte = 'g', .bit = regexp_lib.flags.global },
        .{ .byte = 'i', .bit = regexp_lib.flags.ignore_case },
        .{ .byte = 'm', .bit = regexp_lib.flags.multiline },
        .{ .byte = 's', .bit = regexp_lib.flags.dot_all },
        .{ .byte = 'u', .bit = regexp_lib.flags.unicode },
        .{ .byte = 'v', .bit = regexp_lib.flags.unicode_sets },
        .{ .byte = 'y', .bit = regexp_lib.flags.sticky },
    };
    for (order) |entry| {
        if (entry.byte == 'u' and (bits & regexp_lib.flags.unicode_sets) != 0) continue;
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
    const status = try regexp_lib.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xxAbCy" }, 0);
    try std.testing.expect(status.result == .match);
    try std.testing.expectEqual(@as(usize, 2), status.match.start);
    try std.testing.expectEqual(@as(usize, 5), status.match.end);
}

test "JavaScript RegExp adapter preserves multiple named capture groups" {
    var compiled = try compile(std.testing.allocator, "(?<a>.)(?<b>.)(?<c>.)(?<d>.)", "");
    defer compiled.deinit(std.testing.allocator);

    const status = try regexp_lib.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "wxyz" }, 0);
    try std.testing.expect(status.result == .match);
    try std.testing.expectEqual(@as(usize, 4), status.match.capture_count);

    const expected_names = [_][]const u8{ "a", "b", "c", "d" };
    for (expected_names, 0..) |name, i| {
        try std.testing.expectEqual(i, status.match.captures[i].start.?);
        try std.testing.expectEqual(i + 1, status.match.captures[i].end.?);
        try std.testing.expectEqualStrings(name, status.match.captures[i].name.?);
    }
}

test "JavaScript RegExp adapter is repeatable across matches" {
    var compiled = try compile(std.testing.allocator, "a+", "");
    defer compiled.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const hit = try regexp_lib.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xxaaa" }, 0);
        try std.testing.expect(hit.result == .match);
        try std.testing.expectEqual(@as(usize, 2), hit.match.start);
        try std.testing.expectEqual(@as(usize, 5), hit.match.end);

        const miss = try regexp_lib.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xyz" }, 0);
        try std.testing.expect(miss.result == .no_match);
    }

    const empty = try regexp_lib.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "" }, 0);
    try std.testing.expect(empty.result == .no_match);
}

test "JavaScript RegExp adapter greedy class8 loop backtracks" {
    {
        var compiled = try compile(std.testing.allocator, "[a-z]+a", "");
        defer compiled.deinit(std.testing.allocator);
        const hit = try regexp_lib.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "bbba" }, 0);
        try std.testing.expect(hit.result == .match);
        try std.testing.expectEqual(@as(usize, 0), hit.match.start);
        try std.testing.expectEqual(@as(usize, 4), hit.match.end);

        const miss = try regexp_lib.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "bbb" }, 0);
        try std.testing.expect(miss.result == .no_match);
    }
    {
        var compiled = try compile(std.testing.allocator, "[aeiou]*", "");
        defer compiled.deinit(std.testing.allocator);
        const empty = try regexp_lib.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xyz" }, 0);
        try std.testing.expect(empty.result == .match);
        try std.testing.expectEqual(@as(usize, 0), empty.match.start);
        try std.testing.expectEqual(@as(usize, 0), empty.match.end);
    }
    {
        var compiled = try compile(std.testing.allocator, "[^#?]*x", "");
        defer compiled.deinit(std.testing.allocator);
        const hit = try regexp_lib.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "abcx" }, 0);
        try std.testing.expect(hit.result == .match);
        try std.testing.expectEqual(@as(usize, 0), hit.match.start);
        try std.testing.expectEqual(@as(usize, 4), hit.match.end);
    }
    {
        var compiled = try compile(std.testing.allocator, "[^a]+\u{1F600}", "u");
        defer compiled.deinit(std.testing.allocator);
        const input = [_]u16{ 'x', 0xd83d, 0xde00 };
        const hit = try regexp_lib.exec(std.testing.allocator, compiled.bytecode, .{ .utf16 = &input }, 0);
        try std.testing.expect(hit.result == .match);
        try std.testing.expectEqual(@as(usize, 0), hit.match.start);
        try std.testing.expectEqual(@as(usize, 3), hit.match.end);
    }
}
