//! Zig boundary over standalone V8 Irregexp.
//!
//! Compile still goes through the C ABI (`IRRX` header + V8 bytecode). Exec
//! is a Zig interpreter of that bytecode (`irregexp_interp.zig`). The JS
//! object layer still stores the blob as a latin1 `JSString`. Flag parsing
//! and character-class helpers stay in `regexp.zig`.
const std = @import("std");
const unicode = @import("unicode.zig");
const regexp_properties = unicode.regexp_properties;
const regexp_lib = @import("regexp.zig");
const interp = @import("irregexp_interp.zig");

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

const abi = struct {
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

    pub fn header(self: Compiled) ?BlobHeader {
        return parseHeader(self.bytecode);
    }
};

pub const BlobHeader = struct {
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
    const header = parseHeader(bytecode) orelse return 0;
    return header.capture_count * 2 + header.register_count;
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
        abi.OK => {},
        abi.SYNTAX, abi.CORRUPT => error.InvalidPattern,
        abi.STACK => error.StackOverflow,
        abi.OOM => error.OutOfMemory,
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

/// Nesting budget for the compile-time stack guard. V8's parser is largely
/// iterative, so deep `(?:` / nested-`v` class trees do not overflow its C++
/// stack the way the QuickJS-style recursive compiler did. JS still needs a
/// catchable `SyntaxError: stack overflow` instead of an unbounded compile or
/// an OS stack crash. 2048 covers the existing shallow-ok fixtures (1000
/// groups, 200 nested classes) and rejects the overflow fixtures (40000
/// groups, 4000 nested `v` classes).
const compile_nest_limit: usize = 2048;
const compile_nest_frame_bytes: usize = 256;

fn checkCompileNesting(pattern: []const u8, re_flags: u16, options: CompileOptions) CompileError!void {
    const unicode_sets = (re_flags & flags.unicode_sets) != 0;
    var index: usize = 0;
    var depth: usize = 0;
    var class_depth: usize = 0;
    while (index < pattern.len) {
        const byte = pattern[index];
        if (byte == '\\') {
            index += if (index + 1 < pattern.len) @as(usize, 2) else 1;
            continue;
        }
        if (class_depth == 0) {
            if (byte == '(') {
                try pushCompileNest(&depth, options);
            } else if (byte == ')' and depth > 0) {
                depth -= 1;
            } else if (byte == '[') {
                try pushCompileNest(&depth, options);
                if (unicode_sets) {
                    class_depth = 1;
                } else if (skipCharacterClass(pattern, &index)) {
                    if (depth > 0) depth -= 1;
                    continue;
                }
            }
        } else if (byte == '[' and unicode_sets) {
            try pushCompileNest(&depth, options);
            class_depth += 1;
        } else if (byte == ']') {
            class_depth -= 1;
            if (depth > 0) depth -= 1;
        }
        index += 1;
    }
}

fn pushCompileNest(depth: *usize, options: CompileOptions) CompileError!void {
    depth.* += 1;
    if (depth.* > compile_nest_limit) return error.StackOverflow;
    const check = options.check_stack_overflow orelse return;
    if (check(options.@"opaque", depth.* * compile_nest_frame_bytes)) return error.StackOverflow;
}

fn skipCharacterClass(pattern: []const u8, index: *usize) bool {
    var i = index.* + 1;
    if (i < pattern.len and pattern[i] == '^') i += 1;
    while (i < pattern.len) {
        if (pattern[i] == '\\') {
            i += if (i + 1 < pattern.len) @as(usize, 2) else 1;
            continue;
        }
        if (pattern[i] == ']') {
            index.* = i + 1;
            return true;
        }
        i += 1;
    }
    return false;
}

fn isV8StackOverflowMessage(message: ?[*:0]const u8) bool {
    const ptr = message orelse return false;
    const text = std.mem.span(ptr);
    return std.mem.eql(u8, text, "Stack overflow") or
        std.mem.eql(u8, text, "Maximum call stack size exceeded") or
        std.mem.eql(u8, text, "Regular expression too large");
}

pub fn compilePatternWithFlagBitsAndOptions(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    re_flags: u16,
    options: CompileOptions,
) !Compiled {
    try checkCompileNesting(pattern, re_flags, options);
    // Keep the unicode-hook exports live so the linker does not drop them in
    // favor of the weak ASCII fallbacks in the C++ shim.
    std.mem.doNotOptimizeAway(&zjs_irregexp_canonicalize);
    std.mem.doNotOptimizeAway(&zjs_irregexp_uncanonicalize);
    std.mem.doNotOptimizeAway(&zjs_irregexp_is_identifier_start);
    std.mem.doNotOptimizeAway(&zjs_irregexp_is_identifier_part);
    std.mem.doNotOptimizeAway(&zjs_irregexp_is_letter);

    var encoded = try encodePattern(allocator, pattern);
    defer encoded.deinit(allocator);

    var out = abi.CompileOut{
        .blob = null,
        .blob_len = 0,
        .error_message = null,
    };
    var empty_pattern: [1]u8 = .{0};
    const pattern_ptr: [*]const u8 = if (encoded.bytes.len == 0)
        &empty_pattern
    else
        encoded.bytes.ptr;
    const status = abi.zjs_irregexp_compile(
        pattern_ptr,
        encoded.bytes.len,
        if (encoded.is_utf16) @as(c_int, 1) else 0,
        zjsFlagsToV8(re_flags),
        &out,
    );
    if (status != abi.OK and isV8StackOverflowMessage(out.error_message)) {
        return error.StackOverflow;
    }
    try compileStatus(status);
    const blob = out.blob orelse return error.OutOfMemory;
    defer abi.zjs_irregexp_free(blob);
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
        abi.OK => .match,
        abi.NO_MATCH => .no_match,
        abi.TIMEOUT => error.Timeout,
        abi.CORRUPT, abi.STACK => error.BytecodeCorrupt,
        abi.OOM => error.OutOfMemory,
        else => error.BytecodeCorrupt,
    };
}

fn copyRegisters(dst: []usize, src: []const i32) void {
    const n = @min(dst.len, src.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dst[i] = if (src[i] < 0) no_slot_value else @intCast(src[i]);
    }
    if (n < dst.len) @memset(dst[n..], no_slot_value);
}

fn inputLen(input: Input) usize {
    return switch (input) {
        .latin1 => |bytes| bytes.len,
        .utf16 => |units| units.len,
    };
}

fn runInterp(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    header: BlobHeader,
    input: Input,
    start_index: usize,
    options: ExecOptions,
    regs: []i32,
) !interp.Result {
    var widened: []u16 = &.{};
    defer if (widened.len != 0) allocator.free(widened);

    const interrupt = interp.Interrupt{
        .check = options.check_timeout,
        .ctx = options.@"opaque",
    };

    return switch (input) {
        .latin1 => |bytes| blk: {
            if (header.latin1_len != 0) {
                const code = bytecode[header.latin1_off..][0..header.latin1_len];
                break :blk try @call(.always_inline, interp.execLatin1, .{ allocator, code, bytes, start_index, regs, interrupt });
            }
            if (header.uc16_len == 0) return error.BytecodeCorrupt;
            widened = try allocator.alloc(u16, bytes.len);
            for (bytes, 0..) |b, i| widened[i] = b;
            const code = bytecode[header.uc16_off..][0..header.uc16_len];
            break :blk try interp.execUtf16(allocator, code, widened, start_index, regs, interrupt);
        },
        .utf16 => |units| blk: {
            if (header.uc16_len == 0) return error.BytecodeCorrupt;
            const code = bytecode[header.uc16_off..][0..header.uc16_len];
            break :blk try interp.execUtf16(allocator, code, units, start_index, regs, interrupt);
        },
    };
}

fn acquireRegisters(
    allocator: std.mem.Allocator,
    need: usize,
    inline_regs: *[small_exec_slots]i32,
    heap_regs: *[]i32,
) ![]i32 {
    const regs = if (need <= inline_regs.len)
        inline_regs[0..need]
    else blk: {
        heap_regs.* = try allocator.alloc(i32, need);
        break :blk heap_regs.*;
    };
    @memset(regs, -1);
    return regs;
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
    if (start_index > inputLen(input)) return .out_of_range;

    const need = @max(registers_per_match, header.register_count);
    var inline_regs: [small_exec_slots]i32 = undefined;
    var heap_regs: []i32 = &.{};
    defer if (heap_regs.len != 0) allocator.free(heap_regs);
    const regs = try acquireRegisters(allocator, need, &inline_regs, &heap_regs);

    const zig_result = try runInterp(allocator, bytecode, header, input, start_index, options, regs);
    const result: ExecResult = switch (zig_result) {
        .success => .match,
        .failure => .no_match,
    };
    if (result == .match) {
        copyRegisters(capture, regs);
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
    if (start_index > inputLen(input)) return false;
    const need = @max(header.capture_count * 2, header.register_count);
    var inline_regs: [small_exec_slots]i32 = undefined;
    var heap_regs: []i32 = &.{};
    defer if (heap_regs.len != 0) allocator.free(heap_regs);
    const regs = try acquireRegisters(allocator, need, &inline_regs, &heap_regs);
    const zig_result = try runInterp(allocator, bytecode, header, input, start_index, options, regs);
    return switch (zig_result) {
        .success => true,
        .failure => false,
    };
}

fn clampCodePoint(code_point: u32) ?u21 {
    if (code_point > 0x10ffff) return null;
    return @intCast(code_point);
}

export fn zjs_irregexp_canonicalize(code_point: u32, unicode_flag: c_int) u32 {
    const cp = clampCodePoint(code_point) orelse return code_point;
    return unicode.regexpCanonicalize(cp, unicode_flag != 0);
}

export fn zjs_irregexp_uncanonicalize(code_point: u32, out: [*c]u32, max_out: c_int) c_int {
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

    add(dest, &n, code_point);
    if (clampCodePoint(code_point)) |cp| {
        const lower = unicode.caseConvert(cp, true);
        const upper = unicode.caseConvert(cp, false);
        if (lower.len > 0 and lower.codepoints[0] <= 0x10ffff) add(dest, &n, lower.codepoints[0]);
        if (upper.len > 0 and upper.codepoints[0] <= 0x10ffff) add(dest, &n, upper.codepoints[0]);
        add(dest, &n, unicode.regexpCanonicalize(cp, false));
        add(dest, &n, unicode.regexpCanonicalize(cp, true));
    }
    return @intCast(n);
}

export fn zjs_irregexp_is_identifier_start(code_point: u32) c_int {
    const cp = clampCodePoint(code_point) orelse return 0;
    return if (unicode.isIdentifierStart(cp)) 1 else 0;
}

export fn zjs_irregexp_is_identifier_part(code_point: u32) c_int {
    const cp = clampCodePoint(code_point) orelse return 0;
    return if (unicode.isIdentifierContinue(cp)) 1 else 0;
}

export fn zjs_irregexp_is_letter(code_point: u32) c_int {
    const cp = clampCodePoint(code_point) orelse return 0;
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

test "Irregexp turns extreme nesting into StackOverflow" {
    const opens = "(?:" ** 3000;
    try std.testing.expectError(error.StackOverflow, compilePatternAndFlags(std.testing.allocator, opens, ""));
}

test "Irregexp exec reuses isolate state across repeated matches" {
    const allocator = std.testing.allocator;
    var compiled = try compilePatternAndFlags(allocator, "a+", "");
    defer compiled.deinit(allocator);

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const hit = try exec(allocator, compiled.bytecode, .{ .latin1 = "xxaaa" }, 0);
        try std.testing.expect(hit.result == .match);
        try std.testing.expectEqual(@as(usize, 2), hit.match.start);
        try std.testing.expectEqual(@as(usize, 5), hit.match.end);

        const miss = try exec(allocator, compiled.bytecode, .{ .latin1 = "xyz" }, 0);
        try std.testing.expect(miss.result == .no_match);
    }

    const empty = try exec(allocator, compiled.bytecode, .{ .latin1 = "" }, 0);
    try std.testing.expect(empty.result == .no_match);

    var empty_pat = try compilePatternAndFlags(allocator, "(?:)", "");
    defer empty_pat.deinit(allocator);
    const empty_hit = try exec(allocator, empty_pat.bytecode, .{ .latin1 = "" }, 0);
    try std.testing.expect(empty_hit.result == .match);
    try std.testing.expectEqual(@as(usize, 0), empty_hit.match.start);
    try std.testing.expectEqual(@as(usize, 0), empty_hit.match.end);
}

test "Irregexp matches UTF-16 subjects above Latin-1" {
    const allocator = std.testing.allocator;
    const han = [_]u16{0x4E2D};
    const pair = [_]u16{ 0xD834, 0xDF06 };
    const xa = [_]u16{ 0x0078, 0x0061 };

    {
        var compiled = try compilePatternAndFlags(allocator, ".", "");
        defer compiled.deinit(allocator);
        const han_status = try exec(allocator, compiled.bytecode, .{ .utf16 = &han }, 0);
        try std.testing.expect(han_status.result == .match);
        try std.testing.expectEqual(@as(usize, 0), han_status.match.start);
        try std.testing.expectEqual(@as(usize, 1), han_status.match.end);

        const pair_status = try exec(allocator, compiled.bytecode, .{ .utf16 = &pair }, 0);
        try std.testing.expect(pair_status.result == .match);
        try std.testing.expectEqual(@as(usize, 0), pair_status.match.start);
        try std.testing.expectEqual(@as(usize, 1), pair_status.match.end);
    }

    {
        var compiled = try compilePatternAndFlags(allocator, ".", "u");
        defer compiled.deinit(allocator);
        const pair_status = try exec(allocator, compiled.bytecode, .{ .utf16 = &pair }, 0);
        try std.testing.expect(pair_status.result == .match);
        try std.testing.expectEqual(@as(usize, 0), pair_status.match.start);
        try std.testing.expectEqual(@as(usize, 2), pair_status.match.end);
    }

    {
        var compiled = try compilePatternAndFlags(allocator, "a", "");
        defer compiled.deinit(allocator);
        const status = try exec(allocator, compiled.bytecode, .{ .utf16 = &xa }, 0);
        try std.testing.expect(status.result == .match);
        try std.testing.expectEqual(@as(usize, 1), status.match.start);
        try std.testing.expectEqual(@as(usize, 2), status.match.end);
    }
}

test "Zig Irregexp interpreter matches C++ exec on representative patterns" {
    const allocator = std.testing.allocator;
    const Case = struct { pattern: []const u8, flags_str: []const u8, subject: []const u8, start: usize };
    const cases = [_]Case{
        .{ .pattern = "a+", .flags_str = "", .subject = "xxaaa", .start = 0 },
        .{ .pattern = "a+", .flags_str = "", .subject = "xyz", .start = 0 },
        .{ .pattern = "(?:)", .flags_str = "", .subject = "", .start = 0 },
        .{ .pattern = "abc", .flags_str = "i", .subject = "xxAbCy", .start = 0 },
        .{ .pattern = "(a+)(b+)", .flags_str = "", .subject = "aaabbb", .start = 0 },
        .{ .pattern = "\\d+", .flags_str = "", .subject = "ab12cd", .start = 0 },
        .{ .pattern = "[aeiou]+", .flags_str = "", .subject = "xxooi", .start = 0 },
        .{ .pattern = "^foo", .flags_str = "", .subject = "foo bar", .start = 0 },
        .{ .pattern = "foo$", .flags_str = "", .subject = "bar foo", .start = 0 },
        .{ .pattern = "a|b", .flags_str = "", .subject = "xb", .start = 0 },
        .{ .pattern = "(a)\\1", .flags_str = "", .subject = "aa", .start = 0 },
        .{ .pattern = "a{2,4}", .flags_str = "", .subject = "caaaad", .start = 0 },
        .{ .pattern = ".", .flags_str = "s", .subject = "\n", .start = 0 },
        .{ .pattern = "\\bword\\b", .flags_str = "", .subject = "a word here", .start = 0 },
        .{ .pattern = "end", .flags_str = "", .subject = "the end", .start = 4 },
    };

    for (cases) |case| {
        var compiled = try compilePatternAndFlags(allocator, case.pattern, case.flags_str);
        defer compiled.deinit(allocator);
        const header = parseHeader(compiled.bytecode) orelse return error.BytecodeCorrupt;
        const registers_per_match = header.capture_count * 2;
        const need = @max(registers_per_match, header.register_count);
        const zig_slots = try allocator.alloc(usize, registers_per_match);
        defer allocator.free(zig_slots);
        const cpp_slots = try allocator.alloc(usize, registers_per_match);
        defer allocator.free(cpp_slots);
        const zig = try execCaptureSlotsSliceTrustedWithOptions(allocator, compiled.bytecode, .{ .latin1 = case.subject }, case.start, .{}, zig_slots);

        const cpp_regs = try allocator.alloc(i32, need);
        defer allocator.free(cpp_regs);
        @memset(cpp_regs, -1);
        const cpp_status = abi.zjs_irregexp_exec(
            compiled.bytecode.ptr,
            compiled.bytecode.len,
            case.subject.ptr,
            case.subject.len,
            abi.LATIN1,
            case.start,
            cpp_regs.ptr,
            cpp_regs.len,
            null,
            null,
        );
        const cpp = try execStatus(cpp_status);
        if (cpp == .match) copyRegisters(cpp_slots, cpp_regs);
        try std.testing.expectEqual(cpp, zig);
        if (zig == .match) {
            try std.testing.expectEqualSlices(usize, cpp_slots, zig_slots);
        }
    }
}
