const core = @import("../../core/root.zig");
const regexp = @import("engine.zig");
const regexp_bytecode = regexp;
const regexp_compile = regexp;
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

pub const Compiled = struct {
    bytecode: []u8,

    pub fn deinit(self: *Compiled, allocator: std.mem.Allocator) void {
        allocator.free(self.bytecode);
        self.bytecode = &.{};
    }

    pub fn captureCount(self: Compiled) usize {
        return regexp_bytecode.captureCount(self.bytecode);
    }

    pub fn registerCount(self: Compiled) usize {
        return regexp_bytecode.registerCount(self.bytecode);
    }

    pub fn allocCount(self: Compiled) usize {
        return regexp_bytecode.allocCount(self.bytecode);
    }

    pub fn groupName(self: Compiled, one_based_capture_index: usize) ?[]const u8 {
        return regexp_bytecode.groupName(self.bytecode, one_based_capture_index);
    }

    pub fn flagBits(self: Compiled) u16 {
        return regexp_bytecode.getFlags(self.bytecode);
    }
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) !Compiled {
    return compileRaw(allocator, pattern, flags);
}

fn compileRaw(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) !Compiled {
    if (regexp_compile.compile(allocator, pattern, flags)) |bytecode| {
        return .{ .bytecode = bytecode };
    } else |err| switch (err) {
        error.Unsupported => return error.Unsupported,
        error.InvalidPattern => return error.InvalidPattern,
        else => |alloc_err| return alloc_err,
    }
}

pub fn execOnString(compiled: Compiled, string_value: core.JSValue) ExecError!?Match {
    const header = string_value.refHeader() orelse return null;
    if (!string_value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);

    const status = switch (string_object.resolveData()) {
        .latin1 => |bytes| try regexp_bytecode.exec(std.heap.page_allocator, compiled.bytecode, .{ .latin1 = bytes }, 0),
        .utf16 => |units| try regexp_bytecode.exec(std.heap.page_allocator, compiled.bytecode, .{ .utf16 = units }, 0),
    };
    return switch (status.result) {
        .match => status.match,
        else => null,
    };
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
        .latin1 => |bytes| try regexp_bytecode.execIntoMatchWithOptions(rt.memory.allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index, options, out_match),
        .utf16 => |units| try regexp_bytecode.execIntoMatchWithOptions(rt.memory.allocator, compiled.bytecode, .{ .utf16 = units }, start_index, options, out_match),
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

    const options = execOptions(rt);
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| try regexp_bytecode.execCaptureSlotsSliceWithOptions(rt.memory.allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index, options, capture),
        .utf16 => |units| try regexp_bytecode.execCaptureSlotsSliceWithOptions(rt.memory.allocator, compiled.bytecode, .{ .utf16 = units }, start_index, options, capture),
    };
}

pub fn captureSlotValue(value: usize) ?usize {
    return regexp_bytecode.captureSlotValue(value);
}

pub fn testOnStringFromIndex(rt: *core.JSRuntime, compiled: Compiled, string_value: core.JSValue, start_index: usize) ExecError!?bool {
    const string_object = string_value.asStringBody() orelse return null;
    try string_object.ensureFlat(rt);

    const options = execOptions(rt);
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| try regexp_bytecode.testMatchWithOptions(rt.memory.allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index, options),
        .utf16 => |units| try regexp_bytecode.testMatchWithOptions(rt.memory.allocator, compiled.bytecode, .{ .utf16 = units }, start_index, options),
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

pub fn flagsToBits(flags: []const u8) u32 {
    return compileFlagsToBits(flags) | if (hasFlag(flags, 'v')) regexp_bytecode.flags.unicode else 0;
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
        if ((bits & entry.bit) != 0) try buffer.append(allocator, entry.byte);
    }
}

pub fn flagsStringValueFromBytecode(rt: *core.JSRuntime, bytecode: []const u8) !core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendCanonicalFlagsFromBits(rt.memory.allocator, &buffer, flagBitsFromBytecode(bytecode));
    return (try core.string.String.createAscii(rt, buffer.items)).value();
}

fn compileFlagsToBits(flags: []const u8) u32 {
    var bits: u32 = 0;
    for (flags) |flag| {
        bits |= switch (flag) {
            'g' => regexp_bytecode.flags.global,
            'i' => regexp_bytecode.flags.ignore_case,
            'm' => regexp_bytecode.flags.multiline,
            's' => regexp_bytecode.flags.dot_all,
            'u' => regexp_bytecode.flags.unicode,
            'y' => regexp_bytecode.flags.sticky,
            'd' => regexp_bytecode.flags.indices,
            'v' => regexp_bytecode.flags.unicode_sets | regexp_bytecode.flags.unicode,
            else => 0,
        };
    }
    return bits;
}

fn hasFlag(flags: []const u8, needle: u8) bool {
    return std.mem.indexOfScalar(u8, flags, needle) != null;
}

test "JavaScript RegExp adapter compilation and execution" {
    var compiled = try compile(std.testing.allocator, "abc", "i");
    defer compiled.deinit(std.testing.allocator);
    const status = try regexp.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xxAbCy" }, 0);
    try std.testing.expect(status.result == .match);
    try std.testing.expectEqual(@as(usize, 2), status.match.start);
    try std.testing.expectEqual(@as(usize, 5), status.match.end);
}
