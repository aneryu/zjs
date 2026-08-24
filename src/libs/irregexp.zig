//! Zig boundary over the standalone V8 Irregexp C ABI.
//!
//! Compiled blobs are zjs-owned (`IRRX` header + V8 bytecode). The JS object
//! layer still stores that blob as a latin1 `JSString`. Flag parsing and
//! character-class helpers stay in `regexp.zig`; this module owns compile and
//! exec for the production JS path.
const std = @import("std");
const unicode = @import("unicode.zig");
const regexp_properties = unicode.regexp_properties;
const regexp_lib = @import("regexp.zig");

pub const max_captures = regexp_lib.max_captures;
pub const max_exec_slots = regexp_lib.max_exec_slots;
pub const small_exec_slots = regexp_lib.small_exec_slots;
pub const flags = regexp_lib.flags;
pub const Capture = regexp_lib.Capture;
pub const Match = regexp_lib.Match;
pub const ExecStatus = regexp_lib.ExecStatus;
pub const ExecResult = regexp_lib.ExecResult;
pub const Input = regexp_lib.Input;
pub const CheckTimeout = regexp_lib.CheckTimeout;
pub const ExecOptions = regexp_lib.ExecOptions;
pub const CompileError = regexp_lib.CompileError;
pub const CompileOptions = regexp_lib.CompileOptions;
pub const parseFlagBits = regexp_lib.parseFlagBits;

const no_slot_value = std.math.maxInt(usize);
const irrx_magic: u32 = 0x58525249;
const irrx_version: u16 = 1;
const header_len: usize = 32;

const c = struct {
    pub const OK: c_int = 0;
    pub const NO_MATCH: c_int = 1;
    pub const SYNTAX: c_int = 2;
    pub const OOM: c_int = 3;
    pub const TIMEOUT: c_int = 4;
    pub const STACK: c_int = 5;
    pub const CORRUPT: c_int = 6;

    pub const LATIN1: c_int = 0;
    pub const UTF16: c_int = 1;

    pub const CompileOut = extern struct {
        blob: ?[*]u8,
        blob_len: usize,
        error_message: ?[*:0]const u8,
    };

    pub const InterruptFn = ?*const fn (?*anyopaque) callconv(.c) c_int;

    pub extern fn zjs_irregexp_compile(
        pattern: [*]const u8,
        pattern_len: usize,
        pattern_is_utf16: c_int,
        v8_flags: u32,
        out: *CompileOut,
    ) c_int;
    pub extern fn zjs_irregexp_free(blob: ?[*]u8) void;
    pub extern fn zjs_irregexp_exec(
        blob: [*]const u8,
        blob_len: usize,
        subject: *const anyopaque,
        subject_len: usize,
        subject_width: c_int,
        start_index: usize,
        registers: [*]i32,
        register_count: usize,
        interrupt: InterruptFn,
        interrupt_opaque: ?*anyopaque,
    ) c_int;
};

const v8_flag = struct {
    pub const global: u32 = 1 << 0;
    pub const ignore_case: u32 = 1 << 1;
    pub const multiline: u32 = 1 << 2;
    pub const sticky: u32 = 1 << 3;
    pub const unicode: u32 = 1 << 4;
    pub const dot_all: u32 = 1 << 5;
    pub const has_indices: u32 = 1 << 7;
    pub const unicode_sets: u32 = 1 << 8;
};

pub const Compiled = struct {
    bytecode: []u8,

    pub fn deinit(self: *Compiled, allocator: std.mem.Allocator) void {
        allocator.free(self.bytecode);
        self.bytecode = &.{};
    }

    pub fn captureCount(self: Compiled) usize {
        return captureCountFromBytecode(self.bytecode);
    }

    pub fn registerCount(self: Compiled) usize {
        return registerCountFromBytecode(self.bytecode);
    }

    pub fn allocCount(self: Compiled) usize {
        return allocCountFromBytecode(self.bytecode);
    }

    pub fn groupName(self: Compiled, one_based_capture_index: usize) ?[]const u8 {
        return groupNameFromBytecode(self.bytecode, one_based_capture_index);
    }

    pub fn flagBits(self: Compiled) u16 {
        return getFlags(self.bytecode);
    }
};

const BlobHeader = struct {
    flags: u16,
    capture_count: usize,
    register_count: usize,
    name_count: usize,
    latin1_off: u32,
    latin1_len: u32,
    uc16_off: u32,
    uc16_len: u32,
};

fn parseHeader(bytecode: []const u8) ?BlobHeader {
    if (bytecode.len < header_len) return null;
    if (std.mem.readInt(u32, bytecode[0..4], .little) != irrx_magic) return null;
    if (std.mem.readInt(u16, bytecode[4..6], .little) != irrx_version) return null;
    const latin1_off = std.mem.readInt(u32, bytecode[16..20], .little);
    const latin1_len = std.mem.readInt(u32, bytecode[20..24], .little);
    const uc16_off = std.mem.readInt(u32, bytecode[24..28], .little);
    const uc16_len = std.mem.readInt(u32, bytecode[28..32], .little);
    if (latin1_len != 0 and @as(usize, latin1_off) + latin1_len > bytecode.len) return null;
    if (uc16_len != 0 and @as(usize, uc16_off) + uc16_len > bytecode.len) return null;
    return .{
        .flags = std.mem.readInt(u16, bytecode[6..8], .little),
        .capture_count = std.mem.readInt(u16, bytecode[8..10], .little),
        .register_count = std.mem.readInt(u16, bytecode[10..12], .little),
        .name_count = std.mem.readInt(u16, bytecode[12..14], .little),
        .latin1_off = latin1_off,
        .latin1_len = latin1_len,
        .uc16_off = uc16_off,
        .uc16_len = uc16_len,
    };
}

pub fn getFlags(bytecode: []const u8) u16 {
    const header = parseHeader(bytecode) orelse return 0;
    return header.flags;
}

fn captureCountFromBytecode(bytecode: []const u8) usize {
    const header = parseHeader(bytecode) orelse return 0;
    return header.capture_count;
}

pub fn captureCount(bytecode: []const u8) usize {
    return captureCountFromBytecode(bytecode);
}

fn registerCountFromBytecode(bytecode: []const u8) usize {
    const header = parseHeader(bytecode) orelse return 0;
    return header.register_count;
}

pub fn registerCount(bytecode: []const u8) usize {
    return registerCountFromBytecode(bytecode);
}

fn allocCountFromBytecode(bytecode: []const u8) usize {
    return captureCountFromBytecode(bytecode) * 2 + registerCountFromBytecode(bytecode);
}

pub fn allocCount(bytecode: []const u8) usize {
    return allocCountFromBytecode(bytecode);
}

fn groupNameFromBytecode(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8 {
    const header = parseHeader(bytecode) orelse return null;
    if (one_based_capture_index == 0 or (header.flags & flags.named_groups) == 0) return null;
    const names_end: usize = if (header.latin1_len != 0)
        header.latin1_off
    else if (header.uc16_len != 0)
        header.uc16_off
    else
        bytecode.len;
    var off: usize = header_len;
    var i: usize = 0;
    while (i < header.name_count) : (i += 1) {
        if (off + 4 > names_end) return null;
        const index = std.mem.readInt(u16, bytecode[off..][0..2], .little);
        const len = std.mem.readInt(u16, bytecode[off + 2 ..][0..2], .little);
        off += 4;
        if (off + len > names_end) return null;
        if (index == one_based_capture_index) {
            if (len == 0) return null;
            return bytecode[off .. off + len];
        }
        off += len;
    }
    return null;
}

pub fn groupName(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8 {
    return groupNameFromBytecode(bytecode, one_based_capture_index);
}

pub fn captureSlotValue(value: usize) ?usize {
    return if (value == no_slot_value) null else value;
}

pub fn zjsFlagsToV8(zjs_flags: u16) u32 {
    var bits: u32 = 0;
    if ((zjs_flags & flags.global) != 0) bits |= v8_flag.global;
    if ((zjs_flags & flags.ignore_case) != 0) bits |= v8_flag.ignore_case;
    if ((zjs_flags & flags.multiline) != 0) bits |= v8_flag.multiline;
    if ((zjs_flags & flags.dot_all) != 0) bits |= v8_flag.dot_all;
    if ((zjs_flags & flags.unicode) != 0) bits |= v8_flag.unicode;
    if ((zjs_flags & flags.sticky) != 0) bits |= v8_flag.sticky;
    if ((zjs_flags & flags.indices) != 0) bits |= v8_flag.has_indices;
    if ((zjs_flags & flags.unicode_sets) != 0) bits |= v8_flag.unicode_sets;
    return bits;
}

const EncodedPattern = struct {
    bytes: []const u8,
    is_utf16: bool,
    owned: ?[]u8 = null,

    fn deinit(self: *EncodedPattern, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
        self.* = .{ .bytes = &.{}, .is_utf16 = false };
    }
};

fn isAsciiBytes(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

const Decoded = struct { cp: u21, next: usize };

fn decodeWtf8(bytes: []const u8, index: usize) error{InvalidPattern}!Decoded {
    const b0 = bytes[index];
    if (b0 < 0x80) return .{ .cp = b0, .next = index + 1 };

    if (b0 & 0xe0 == 0xc0) {
        if (index + 1 >= bytes.len) return error.InvalidPattern;
        const b1 = bytes[index + 1];
        if (b1 & 0xc0 != 0x80) return error.InvalidPattern;
        const cp: u21 = (@as(u21, b0 & 0x1f) << 6) | (b1 & 0x3f);
        if (cp < 0x80) return error.InvalidPattern;
        return .{ .cp = cp, .next = index + 2 };
    }

    if (b0 & 0xf0 == 0xe0) {
        if (index + 2 >= bytes.len) return error.InvalidPattern;
        const b1 = bytes[index + 1];
        const b2 = bytes[index + 2];
        if (b1 & 0xc0 != 0x80 or b2 & 0xc0 != 0x80) return error.InvalidPattern;
        const cp: u21 = (@as(u21, b0 & 0x0f) << 12) | (@as(u21, b1 & 0x3f) << 6) | (b2 & 0x3f);
        if (cp < 0x800) return error.InvalidPattern;
        return .{ .cp = cp, .next = index + 3 };
    }

    if (b0 & 0xf8 == 0xf0) {
        if (index + 3 >= bytes.len) return error.InvalidPattern;
        const b1 = bytes[index + 1];
        const b2 = bytes[index + 2];
        const b3 = bytes[index + 3];
        if (b1 & 0xc0 != 0x80 or b2 & 0xc0 != 0x80 or b3 & 0xc0 != 0x80) return error.InvalidPattern;
        const cp: u21 = (@as(u21, b0 & 0x07) << 18) | (@as(u21, b1 & 0x3f) << 12) | (@as(u21, b2 & 0x3f) << 6) | (b3 & 0x3f);
        if (cp < 0x10000 or cp > 0x10ffff) return error.InvalidPattern;
        return .{ .cp = cp, .next = index + 4 };
    }

    return error.InvalidPattern;
}

fn encodePattern(allocator: std.mem.Allocator, pattern: []const u8) !EncodedPattern {
    if (isAsciiBytes(pattern)) {
        return .{ .bytes = pattern, .is_utf16 = false };
    }

    var units = std.ArrayList(u16).empty;
    defer units.deinit(allocator);
    var index: usize = 0;
    var wide = false;
    while (index < pattern.len) {
        const decoded = try decodeWtf8(pattern, index);
        index = decoded.next;
        if (decoded.cp <= 0xffff) {
            if (decoded.cp > 0xff) wide = true;
            try units.append(allocator, @intCast(decoded.cp));
        } else {
            wide = true;
            const pair = unicode.surrogatePairFromCodePoint(decoded.cp);
            try units.append(allocator, pair.high);
            try units.append(allocator, pair.low);
        }
    }

    if (!wide) {
        const latin1 = try allocator.alloc(u8, units.items.len);
        for (units.items, 0..) |unit, i| latin1[i] = @intCast(unit);
        return .{ .bytes = latin1, .is_utf16 = false, .owned = latin1 };
    }

    const raw = try allocator.alloc(u8, units.items.len * 2);
    for (units.items, 0..) |unit, i| {
        std.mem.writeInt(u16, raw[i * 2 ..][0..2], unit, .little);
    }
    return .{ .bytes = raw, .is_utf16 = true, .owned = raw };
}

fn compileStatus(status: c_int) CompileError!void {
    return switch (status) {
        c.OK => {},
        c.SYNTAX, c.CORRUPT => error.InvalidPattern,
        c.STACK => error.StackOverflow,
        c.OOM => error.OutOfMemory,
        else => error.InvalidPattern,
    };
}

pub fn compilePatternAndFlags(allocator: std.mem.Allocator, pattern: []const u8, flags_str: []const u8) !Compiled {
    return compilePatternAndFlagsWithOptions(allocator, pattern, flags_str, .{});
}

pub fn compilePatternAndFlagsWithOptions(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    flags_str: []const u8,
    options: CompileOptions,
) !Compiled {
    return compilePatternWithFlagBitsAndOptions(allocator, pattern, try parseFlagBits(flags_str), options);
}

pub fn compilePatternWithFlagBitsAndOptions(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    re_flags: u16,
    options: CompileOptions,
) !Compiled {
    _ = options;
    // Keep the unicode-hook exports live so the linker does not drop them in
    // favor of the weak ASCII fallbacks in the C++ shim.
    std.mem.doNotOptimizeAway(&zjs_irregexp_canonicalize);
    std.mem.doNotOptimizeAway(&zjs_irregexp_uncanonicalize);
    std.mem.doNotOptimizeAway(&zjs_irregexp_is_identifier_start);
    std.mem.doNotOptimizeAway(&zjs_irregexp_is_identifier_part);
    std.mem.doNotOptimizeAway(&zjs_irregexp_is_letter);

    var encoded = try encodePattern(allocator, pattern);
    defer encoded.deinit(allocator);

    var out = c.CompileOut{
        .blob = null,
        .blob_len = 0,
        .error_message = null,
    };
    var empty_pattern: [1]u8 = .{0};
    const pattern_ptr: [*]const u8 = if (encoded.bytes.len == 0)
        &empty_pattern
    else
        encoded.bytes.ptr;
    const status = c.zjs_irregexp_compile(
        pattern_ptr,
        encoded.bytes.len,
        if (encoded.is_utf16) @as(c_int, 1) else 0,
        zjsFlagsToV8(re_flags),
        &out,
    );
    try compileStatus(status);
    const blob = out.blob orelse return error.OutOfMemory;
    defer c.zjs_irregexp_free(blob);
    const copy = try allocator.dupe(u8, blob[0..out.blob_len]);
    return .{ .bytecode = copy };
}

const InterruptContext = struct {
    @"opaque": ?*anyopaque,
    check_timeout: CheckTimeout,
};

fn interruptThunk(opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const ctx: *const InterruptContext = @ptrCast(@alignCast(opaque_ptr orelse return 0));
    return if (ctx.check_timeout(ctx.@"opaque")) 1 else 0;
}

fn execStatus(status: c_int) !ExecResult {
    return switch (status) {
        c.OK => .match,
        c.NO_MATCH => .no_match,
        c.TIMEOUT => error.Timeout,
        c.CORRUPT, c.STACK => error.BytecodeCorrupt,
        c.OOM => error.OutOfMemory,
        else => error.BytecodeCorrupt,
    };
}

fn copyRegisters(dst: []usize, src: []const i32, capture_slots: usize) void {
    const n = @min(dst.len, src.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i < capture_slots) {
            dst[i] = if (src[i] < 0) no_slot_value else @intCast(src[i]);
        } else {
            dst[i] = if (src[i] < 0) no_slot_value else @intCast(src[i]);
        }
    }
    if (n < dst.len) @memset(dst[n..], no_slot_value);
}

pub fn execCaptureSlotsSliceTrustedWithOptions(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
    capture: []usize,
) !ExecResult {
    const header = parseHeader(bytecode) orelse return error.BytecodeCorrupt;
    const registers_per_match = header.capture_count * 2;
    if (capture.len < registers_per_match) return error.BytecodeCorrupt;
    const input_len = switch (input) {
        .latin1 => |bytes| bytes.len,
        .utf16 => |units| units.len,
    };
    if (start_index > input_len) return .out_of_range;

    const need = @max(registers_per_match, header.register_count);
    var inline_regs: [small_exec_slots]i32 = undefined;
    var heap_regs: []i32 = &.{};
    defer if (heap_regs.len != 0) allocator.free(heap_regs);
    const regs = if (need <= inline_regs.len)
        inline_regs[0..need]
    else blk: {
        heap_regs = try allocator.alloc(i32, need);
        break :blk heap_regs;
    };
    @memset(regs, -1);

    var interrupt_ctx: InterruptContext = undefined;
    var interrupt_fn: c.InterruptFn = null;
    var interrupt_opaque: ?*anyopaque = null;
    if (options.check_timeout) |check| {
        interrupt_ctx = .{
            .@"opaque" = options.@"opaque",
            .check_timeout = check,
        };
        interrupt_fn = interruptThunk;
        interrupt_opaque = @ptrCast(&interrupt_ctx);
    }

    const status = switch (input) {
        .latin1 => |bytes| c.zjs_irregexp_exec(
            bytecode.ptr,
            bytecode.len,
            bytes.ptr,
            bytes.len,
            c.LATIN1,
            start_index,
            regs.ptr,
            regs.len,
            interrupt_fn,
            interrupt_opaque,
        ),
        .utf16 => |units| c.zjs_irregexp_exec(
            bytecode.ptr,
            bytecode.len,
            units.ptr,
            units.len,
            c.UTF16,
            start_index,
            regs.ptr,
            regs.len,
            interrupt_fn,
            interrupt_opaque,
        ),
    };
    const result = try execStatus(status);
    if (result == .match) {
        copyRegisters(capture, regs, registers_per_match);
    }
    return result;
}

fn writeMatch(bytecode: []const u8, capture_count: usize, slots: []const usize, out_match: *Match) void {
    const start = captureSlotValue(slots[0]) orelse 0;
    const end = captureSlotValue(slots[1]) orelse start;
    const named_count = capture_count - 1;
    out_match.* = .{
        .start = start,
        .end = end,
        .capture_count = named_count,
    };
    var i: usize = 0;
    while (i < named_count) : (i += 1) {
        out_match.captures[i] = .{
            .start = captureSlotValue(slots[2 * (i + 1)]),
            .end = captureSlotValue(slots[2 * (i + 1) + 1]),
            .name = groupNameFromBytecode(bytecode, i + 1),
        };
    }
}

pub fn execWithOptions(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
) !ExecStatus {
    const header = parseHeader(bytecode) orelse return error.BytecodeCorrupt;
    const alloc_count = header.capture_count * 2 + header.register_count;
    var inline_slots: [small_exec_slots]usize = undefined;
    var heap_slots: []usize = &.{};
    defer if (heap_slots.len != 0) allocator.free(heap_slots);
    const slots = if (alloc_count <= inline_slots.len)
        inline_slots[0..alloc_count]
    else blk: {
        heap_slots = try allocator.alloc(usize, alloc_count);
        break :blk heap_slots;
    };
    const result = try execCaptureSlotsSliceTrustedWithOptions(allocator, bytecode, input, start_index, options, slots);
    if (result != .match) return .{ .result = result };
    var match: Match = undefined;
    writeMatch(bytecode, header.capture_count, slots, &match);
    return .{ .result = .match, .match = match };
}

pub fn exec(allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize) !ExecStatus {
    return execWithOptions(allocator, bytecode, input, start_index, .{});
}

pub fn testMatchTrustedWithOptions(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
) !?bool {
    const header = parseHeader(bytecode) orelse return error.BytecodeCorrupt;
    const alloc_count = @max(header.capture_count * 2, header.register_count);
    var inline_slots: [small_exec_slots]usize = undefined;
    var heap_slots: []usize = &.{};
    defer if (heap_slots.len != 0) allocator.free(heap_slots);
    const slots = if (alloc_count <= inline_slots.len)
        inline_slots[0..alloc_count]
    else blk: {
        heap_slots = try allocator.alloc(usize, alloc_count);
        break :blk heap_slots;
    };
    const result = try execCaptureSlotsSliceTrustedWithOptions(allocator, bytecode, input, start_index, options, slots);
    return switch (result) {
        .match => true,
        .no_match, .out_of_range => false,
        .not_available => null,
    };
}

fn clampCodePoint(c: u32) ?u21 {
    if (c > 0x10ffff) return null;
    return @intCast(c);
}

export fn zjs_irregexp_canonicalize(c: u32, unicode_flag: c_int) u32 {
    const cp = clampCodePoint(c) orelse return c;
    return unicode.regexpCanonicalize(cp, unicode_flag != 0);
}

export fn zjs_irregexp_uncanonicalize(c: u32, out: [*c]u32, max_out: c_int) c_int {
    if (max_out < 1 or out == null) return 0;
    const dest = out[0..@intCast(max_out)];
    var n: usize = 0;
    const add = struct {
        fn run(buf: []u32, count: *usize, value: u32) void {
            if (count.* >= buf.len) return;
            for (buf[0..count.*]) |existing| {
                if (existing == value) return;
            }
            buf[count.*] = value;
            count.* += 1;
        }
    }.run;

    add(dest, &n, c);
    if (clampCodePoint(c)) |cp| {
        const lower = unicode.caseConvert(cp, true);
        const upper = unicode.caseConvert(cp, false);
        if (lower.len > 0 and lower.codepoints[0] <= 0x10ffff) add(dest, &n, lower.codepoints[0]);
        if (upper.len > 0 and upper.codepoints[0] <= 0x10ffff) add(dest, &n, upper.codepoints[0]);
        add(dest, &n, unicode.regexpCanonicalize(cp, false));
        add(dest, &n, unicode.regexpCanonicalize(cp, true));
    }
    return @intCast(n);
}

export fn zjs_irregexp_is_identifier_start(c: u32) c_int {
    const cp = clampCodePoint(c) orelse return 0;
    return if (unicode.isIdentifierStart(cp)) 1 else 0;
}

export fn zjs_irregexp_is_identifier_part(c: u32) c_int {
    const cp = clampCodePoint(c) orelse return 0;
    return if (unicode.isIdentifierContinue(cp)) 1 else 0;
}

export fn zjs_irregexp_is_letter(c: u32) c_int {
    const cp = clampCodePoint(c) orelse return 0;
    return if (regexp_properties.isUnicodePropertyMatches(cp, "L")) 1 else 0;
}

test "Irregexp compiles and matches a simple ignore-case pattern" {
    var compiled = try compilePatternAndFlags(std.testing.allocator, "abc", "i");
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect((compiled.flagBits() & flags.ignore_case) != 0);
    const status = try exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xxAbCy" }, 0);
    try std.testing.expect(status.result == .match);
    try std.testing.expectEqual(@as(usize, 2), status.match.start);
    try std.testing.expectEqual(@as(usize, 5), status.match.end);
}

test "Irregexp preserves multiple named capture groups" {
    var compiled = try compilePatternAndFlags(std.testing.allocator, "(?<a>.)(?<b>.)(?<c>.)(?<d>.)", "");
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect((compiled.flagBits() & flags.named_groups) != 0);
    try std.testing.expectEqual(@as(usize, 5), compiled.captureCount());

    const status = try exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "wxyz" }, 0);
    try std.testing.expect(status.result == .match);
    try std.testing.expectEqual(@as(usize, 4), status.match.capture_count);
    const expected_names = [_][]const u8{ "a", "b", "c", "d" };
    for (expected_names, 0..) |name, i| {
        try std.testing.expectEqual(i, status.match.captures[i].start.?);
        try std.testing.expectEqual(i + 1, status.match.captures[i].end.?);
        try std.testing.expectEqualStrings(name, status.match.captures[i].name.?);
    }
}

test "Irregexp rejects an unclosed group as InvalidPattern" {
    try std.testing.expectError(error.InvalidPattern, compilePatternAndFlags(std.testing.allocator, "(", ""));
}
