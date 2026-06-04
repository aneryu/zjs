const core = @import("../core/root.zig");
const regexp = @import("regexp.zig");
const regexp_bytecode = regexp;
const regexp_compile = regexp;
const std = @import("std");

pub const max_captures = regexp_bytecode.max_captures;
pub const flag_bits = regexp_bytecode.flags;
pub const Capture = regexp_bytecode.Capture;
pub const Match = regexp_bytecode.Match;
pub const ExecStatus = regexp_bytecode.ExecStatus;
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

    pub fn flagBits(self: Compiled) u16 {
        return regexp_bytecode.getFlags(self.bytecode);
    }
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) !Compiled {
    return compileRaw(allocator, pattern, flags) catch |err| switch (err) {
        error.InvalidPattern => {
            const normalized = normalizeModifierGroups(allocator, pattern, flags) catch |normalize_err| switch (normalize_err) {
                error.InvalidPattern => return error.InvalidPattern,
                else => |alloc_err| return alloc_err,
            };
            const normalized_pattern = normalized orelse return error.InvalidPattern;
            defer allocator.free(normalized_pattern.pattern);
            var normalized_flags: ?[]u8 = null;
            defer if (normalized_flags) |owned| allocator.free(owned);
            const compile_flags = if (normalized_pattern.drop_ignore_case) blk: {
                normalized_flags = try flagsWithout(allocator, flags, 'i');
                break :blk normalized_flags.?;
            } else flags;
            return compileRaw(allocator, normalized_pattern.pattern, compile_flags);
        },
        else => err,
    };
}

fn compileRaw(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) !Compiled {
    if (regexp_compile.compile(allocator, pattern, flags)) |bytecode| {
        return .{ .bytecode = bytecode };
    } else |err| switch (err) {
        error.Unsupported => if (try compileNormalizedWithZig(allocator, pattern, flags)) |compiled| return compiled,
        error.InvalidPattern => return error.InvalidPattern,
        else => |alloc_err| return alloc_err,
    }

    return error.Unsupported;
}

fn compileNormalizedWithZig(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) !?Compiled {
    const normalized = normalizeModifierGroups(allocator, pattern, flags) catch |err| switch (err) {
        error.InvalidPattern => return null,
        else => |alloc_err| return alloc_err,
    };
    const normalized_pattern = normalized orelse return null;
    defer allocator.free(normalized_pattern.pattern);
    var normalized_flags: ?[]u8 = null;
    defer if (normalized_flags) |owned| allocator.free(owned);
    const compile_flags = if (normalized_pattern.drop_ignore_case) blk: {
        normalized_flags = try flagsWithout(allocator, flags, 'i');
        break :blk normalized_flags.?;
    } else flags;
    if (regexp_compile.compile(allocator, normalized_pattern.pattern, compile_flags)) |bytecode| {
        return .{ .bytecode = bytecode };
    } else |err| switch (err) {
        error.Unsupported, error.InvalidPattern => return null,
        else => |alloc_err| return alloc_err,
    }
}

const NormalizeError = std.mem.Allocator.Error || error{InvalidPattern};

const NormalizeState = struct {
    changed: bool = false,
    global_dot_all: bool = false,
    global_multiline: bool = false,
    global_ignore_case: bool = false,
    unicode_mode: bool = false,
    rewrite_ignore_case: bool = false,
    next_capture_index: usize = 1,
    simple_captures: [max_captures]?[]const u8 = @splat(null),
};

const NormalizedPattern = struct {
    pattern: []u8,
    drop_ignore_case: bool = false,
};

const ModifierGroup = struct {
    body_start: usize,
    add: [3]bool,
    remove: [3]bool,

    fn dotAll(self: ModifierGroup, current: bool) bool {
        if (self.add[modifierFlagSlot('s')]) return true;
        if (self.remove[modifierFlagSlot('s')]) return false;
        return current;
    }

    fn multiline(self: ModifierGroup, current: bool) bool {
        if (self.add[modifierFlagSlot('m')]) return true;
        if (self.remove[modifierFlagSlot('m')]) return false;
        return current;
    }

    fn ignoreCase(self: ModifierGroup, current: bool) bool {
        if (self.add[modifierFlagSlot('i')]) return true;
        if (self.remove[modifierFlagSlot('i')]) return false;
        return current;
    }
};

fn normalizeModifierGroups(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) NormalizeError!?NormalizedPattern {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    var state: NormalizeState = .{
        .global_dot_all = hasFlag(flags, 's'),
        .global_multiline = hasFlag(flags, 'm'),
        .global_ignore_case = hasFlag(flags, 'i'),
        .unicode_mode = !patternUsesCodeUnitMode(flags),
        .rewrite_ignore_case = try modifierPatternMentionsFlag(pattern, 'i'),
    };
    _ = try normalizeRegExpSpan(allocator, pattern, &index, false, state.global_dot_all, state.global_multiline, state.global_ignore_case, &out, &state);
    if (index != pattern.len) return error.InvalidPattern;
    if (!state.changed) {
        out.deinit(allocator);
        return null;
    }
    return .{
        .pattern = try out.toOwnedSlice(allocator),
        .drop_ignore_case = state.rewrite_ignore_case,
    };
}

fn normalizeRegExpSpan(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    index: *usize,
    stop_on_close: bool,
    current_dot_all: bool,
    current_multiline: bool,
    current_ignore_case: bool,
    out: *std.ArrayList(u8),
    state: *NormalizeState,
) NormalizeError!bool {
    var trivial = true;
    while (index.* < pattern.len) {
        if (stop_on_close and pattern[index.*] == ')') return trivial;

        switch (pattern[index.*]) {
            '\\' => {
                try appendEscapedPatternAtom(allocator, pattern, index, out, current_ignore_case, state);
                trivial = false;
            },
            '[' => {
                try appendCharacterClass(allocator, pattern, index, out, current_ignore_case, state);
                trivial = false;
            },
            '.' => {
                try appendDotAtom(allocator, out, current_dot_all, state.global_dot_all);
                index.* += 1;
                trivial = false;
            },
            '^' => {
                try appendLineStartAssertion(allocator, out, current_multiline, state.global_multiline);
                index.* += 1;
                trivial = false;
            },
            '$' => {
                try appendLineEndAssertion(allocator, out, current_multiline, state.global_multiline);
                index.* += 1;
                trivial = false;
            },
            '(' => {
                if (try parseModifierGroup(pattern, index.*)) |modifier_group| {
                    state.changed = true;
                    index.* = modifier_group.body_start;
                    var body = std.ArrayList(u8).empty;
                    defer body.deinit(allocator);
                    const body_trivial = try normalizeRegExpSpan(
                        allocator,
                        pattern,
                        index,
                        true,
                        modifier_group.dotAll(current_dot_all),
                        modifier_group.multiline(current_multiline),
                        modifier_group.ignoreCase(current_ignore_case),
                        &body,
                        state,
                    );
                    if (index.* >= pattern.len or pattern[index.*] != ')') return error.InvalidPattern;
                    try out.appendSlice(allocator, "(?:");
                    try out.appendSlice(allocator, body.items);
                    try out.append(allocator, ')');
                    index.* += 1;
                    trivial = trivial and body_trivial;
                } else if (startsWithAt(pattern, index.*, "(?:")) {
                    try out.appendSlice(allocator, "(?:");
                    index.* += 3;
                    const body_trivial = try normalizeRegExpSpan(allocator, pattern, index, true, current_dot_all, current_multiline, current_ignore_case, out, state);
                    if (index.* >= pattern.len or pattern[index.*] != ')') return error.InvalidPattern;
                    try out.append(allocator, ')');
                    index.* += 1;
                    trivial = trivial and body_trivial;
                } else if (isNonCapturingAssertionStart(pattern, index.*)) {
                    try out.append(allocator, '(');
                    index.* += 1;
                    _ = try normalizeRegExpSpan(allocator, pattern, index, true, current_dot_all, current_multiline, current_ignore_case, out, state);
                    if (index.* >= pattern.len or pattern[index.*] != ')') return error.InvalidPattern;
                    try out.append(allocator, ')');
                    index.* += 1;
                    trivial = false;
                } else {
                    const capture_index = state.next_capture_index;
                    if (capture_index >= state.simple_captures.len) return error.InvalidPattern;
                    state.next_capture_index += 1;
                    try out.append(allocator, '(');
                    index.* += 1;
                    const body_start = index.*;
                    _ = try normalizeRegExpSpan(allocator, pattern, index, true, current_dot_all, current_multiline, current_ignore_case, out, state);
                    if (index.* >= pattern.len or pattern[index.*] != ')') return error.InvalidPattern;
                    const body_end = index.*;
                    if (isSimpleLiteralCapture(pattern[body_start..body_end])) {
                        state.simple_captures[capture_index] = pattern[body_start..body_end];
                    }
                    try out.append(allocator, ')');
                    index.* += 1;
                    trivial = false;
                }
            },
            else => {
                try appendPatternByte(allocator, out, pattern[index.*], current_ignore_case, state);
                index.* += 1;
                trivial = false;
            },
        }
    }
    if (stop_on_close) return error.InvalidPattern;
    return trivial;
}

fn appendPatternByte(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    byte: u8,
    current_ignore_case: bool,
    state: *const NormalizeState,
) NormalizeError!void {
    if (!shouldRewriteIgnoreCase(current_ignore_case, state)) {
        try out.append(allocator, byte);
        return;
    }
    if (isAsciiAlpha(byte)) {
        try appendCaseInsensitiveAsciiAtom(allocator, out, byte);
    } else if (byte < 0x80) {
        try out.append(allocator, byte);
    } else {
        return error.InvalidPattern;
    }
}

fn appendEscapedPatternAtom(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    index: *usize,
    out: *std.ArrayList(u8),
    current_ignore_case: bool,
    state: *const NormalizeState,
) NormalizeError!void {
    if (!shouldRewriteIgnoreCase(current_ignore_case, state)) {
        try appendRawEscapedPatternAtom(allocator, pattern, index, out);
        return;
    }
    const start = index.*;
    if (start + 1 >= pattern.len) {
        try out.append(allocator, pattern[index.*]);
        index.* += 1;
        return;
    }
    const escaped = pattern[start + 1];
    switch (escaped) {
        'd', 'D', 's', 'S', '0' => try appendRawEscapedPatternAtom(allocator, pattern, index, out),
        'b', 'B' => {
            if (state.unicode_mode) {
                try appendIgnoreCaseWordBoundary(allocator, out, escaped == 'B');
                index.* += 2;
            } else {
                try appendRawEscapedPatternAtom(allocator, pattern, index, out);
            }
        },
        'w' => {
            if (state.unicode_mode) {
                try out.appendSlice(allocator, "[A-Za-z0-9_\\u017f\\u212a]");
                index.* += 2;
            } else {
                try appendRawEscapedPatternAtom(allocator, pattern, index, out);
            }
        },
        'W' => {
            if (state.unicode_mode) {
                try out.appendSlice(allocator, "[^A-Za-z0-9_\\u017f\\u212a]");
                index.* += 2;
            } else {
                try appendRawEscapedPatternAtom(allocator, pattern, index, out);
            }
        },
        'x' => {
            const parsed = parseHexEscape(pattern, start, 2) orelse return error.InvalidPattern;
            try appendCaseInsensitiveEscapedCodePoint(allocator, out, pattern[start..parsed.end], parsed.code_point);
            index.* = parsed.end;
        },
        'u' => {
            const parsed = parseUnicodeEscape(pattern, start, state.unicode_mode) orelse return error.InvalidPattern;
            try appendCaseInsensitiveEscapedCodePoint(allocator, out, pattern[start..parsed.end], parsed.code_point);
            index.* = parsed.end;
        },
        'c' => try appendRawEscapedPatternAtom(allocator, pattern, index, out),
        'p', 'P' => {
            if (!state.unicode_mode) return error.InvalidPattern;
            if (!try appendCaseInsensitiveUnicodePropertyEscape(allocator, out, pattern, index, escaped == 'P')) return error.InvalidPattern;
        },
        'k' => return error.InvalidPattern,
        '1'...'9' => {
            const parsed = parseDecimalEscape(pattern, start) orelse return error.InvalidPattern;
            if (parsed.code_point >= state.simple_captures.len) return error.InvalidPattern;
            const capture = state.simple_captures[parsed.code_point] orelse return error.InvalidPattern;
            try appendCaseInsensitiveCaptureLiteral(allocator, out, capture);
            index.* = parsed.end;
        },
        else => {
            if (isAsciiAlpha(escaped)) return error.InvalidPattern;
            try appendRawEscapedPatternAtom(allocator, pattern, index, out);
        },
    }
}

fn appendRawEscapedPatternAtom(allocator: std.mem.Allocator, pattern: []const u8, index: *usize, out: *std.ArrayList(u8)) NormalizeError!void {
    try out.append(allocator, pattern[index.*]);
    index.* += 1;
    if (index.* < pattern.len) {
        try out.append(allocator, pattern[index.*]);
        index.* += 1;
    }
}

fn appendDotAtom(allocator: std.mem.Allocator, out: *std.ArrayList(u8), current_dot_all: bool, global_dot_all: bool) NormalizeError!void {
    if (current_dot_all == global_dot_all) {
        try out.append(allocator, '.');
    } else if (current_dot_all) {
        try out.appendSlice(allocator, "[\\s\\S]");
    } else {
        try out.appendSlice(allocator, "[^\\n\\r\\u2028\\u2029]");
    }
}

fn appendLineStartAssertion(allocator: std.mem.Allocator, out: *std.ArrayList(u8), current_multiline: bool, global_multiline: bool) NormalizeError!void {
    if (current_multiline == global_multiline) {
        try out.append(allocator, '^');
    } else if (current_multiline) {
        try out.appendSlice(allocator, "(?:^|(?<=[\\n\\r\\u2028\\u2029]))");
    } else {
        try out.appendSlice(allocator, "(?<![\\s\\S])");
    }
}

fn appendLineEndAssertion(allocator: std.mem.Allocator, out: *std.ArrayList(u8), current_multiline: bool, global_multiline: bool) NormalizeError!void {
    if (current_multiline == global_multiline) {
        try out.append(allocator, '$');
    } else if (current_multiline) {
        try out.appendSlice(allocator, "(?:$|(?=[\\n\\r\\u2028\\u2029]))");
    } else {
        try out.appendSlice(allocator, "(?![\\s\\S])");
    }
}

fn appendIgnoreCaseWordBoundary(allocator: std.mem.Allocator, out: *std.ArrayList(u8), inverted: bool) NormalizeError!void {
    const word_set = "[A-Za-z0-9_\\u017f\\u212a]";
    if (inverted) {
        try out.appendSlice(allocator, "(?:(?<!");
        try out.appendSlice(allocator, word_set);
        try out.appendSlice(allocator, ")(?!");
        try out.appendSlice(allocator, word_set);
        try out.appendSlice(allocator, ")|(?<=");
        try out.appendSlice(allocator, word_set);
        try out.appendSlice(allocator, ")(?=");
        try out.appendSlice(allocator, word_set);
        try out.appendSlice(allocator, "))");
    } else {
        try out.appendSlice(allocator, "(?:(?<!");
        try out.appendSlice(allocator, word_set);
        try out.appendSlice(allocator, ")(?=");
        try out.appendSlice(allocator, word_set);
        try out.appendSlice(allocator, ")|(?<=");
        try out.appendSlice(allocator, word_set);
        try out.appendSlice(allocator, ")(?!");
        try out.appendSlice(allocator, word_set);
        try out.appendSlice(allocator, "))");
    }
}

fn appendCharacterClass(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    index: *usize,
    out: *std.ArrayList(u8),
    current_ignore_case: bool,
    state: *const NormalizeState,
) NormalizeError!void {
    if (shouldRewriteIgnoreCase(current_ignore_case, state)) {
        try appendCaseInsensitiveCharacterClass(allocator, pattern, index, out, state);
        return;
    }
    try appendRawCharacterClass(allocator, pattern, index, out);
}

fn appendRawCharacterClass(allocator: std.mem.Allocator, pattern: []const u8, index: *usize, out: *std.ArrayList(u8)) NormalizeError!void {
    var escaped = false;
    while (index.* < pattern.len) {
        const byte = pattern[index.*];
        try out.append(allocator, byte);
        index.* += 1;
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == ']') return;
    }
}

fn appendCaseInsensitiveCharacterClass(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    index: *usize,
    out: *std.ArrayList(u8),
    state: *const NormalizeState,
) NormalizeError!void {
    std.debug.assert(pattern[index.*] == '[');
    try out.append(allocator, '[');
    index.* += 1;
    var content_start = index.*;
    if (index.* < pattern.len and pattern[index.*] == '^') {
        try out.append(allocator, '^');
        index.* += 1;
        content_start = index.*;
    }
    if (index.* < pattern.len and pattern[index.*] == ']') {
        try out.append(allocator, ']');
        index.* += 1;
    }
    while (index.* < pattern.len) {
        const byte = pattern[index.*];
        if (byte == ']') {
            try out.append(allocator, ']');
            index.* += 1;
            return;
        }
        if (byte == '\\') {
            try appendEscapedClassAtom(allocator, pattern, index, out, state);
            continue;
        }
        if (byte == '-' and index.* != content_start and index.* + 1 < pattern.len and pattern[index.* + 1] != ']') {
            return error.InvalidPattern;
        }
        if (isAsciiAlpha(byte)) {
            try appendCaseInsensitiveAsciiClassAtom(allocator, out, byte);
        } else if (byte < 0x80) {
            try out.append(allocator, byte);
        } else {
            return error.InvalidPattern;
        }
        index.* += 1;
    }
    return error.InvalidPattern;
}

fn appendEscapedClassAtom(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    index: *usize,
    out: *std.ArrayList(u8),
    state: *const NormalizeState,
) NormalizeError!void {
    const start = index.*;
    if (start + 1 >= pattern.len) return error.InvalidPattern;
    const escaped = pattern[start + 1];
    switch (escaped) {
        'd', 'D', 's', 'S', 'b', 'B', '0' => try appendRawEscapedPatternAtom(allocator, pattern, index, out),
        'w' => {
            if (state.unicode_mode) {
                try out.appendSlice(allocator, "A-Za-z0-9_\\u017f\\u212a");
                index.* += 2;
            } else {
                try appendRawEscapedPatternAtom(allocator, pattern, index, out);
            }
        },
        'W' => return error.InvalidPattern,
        'x' => {
            const parsed = parseHexEscape(pattern, start, 2) orelse return error.InvalidPattern;
            try appendCaseInsensitiveClassEscapedCodePoint(allocator, out, pattern[start..parsed.end], parsed.code_point);
            index.* = parsed.end;
        },
        'u' => {
            const parsed = parseUnicodeEscape(pattern, start, state.unicode_mode) orelse return error.InvalidPattern;
            try appendCaseInsensitiveClassEscapedCodePoint(allocator, out, pattern[start..parsed.end], parsed.code_point);
            index.* = parsed.end;
        },
        'p', 'P', 'k' => return error.InvalidPattern,
        '1'...'9' => return error.InvalidPattern,
        else => {
            if (isAsciiAlpha(escaped)) return error.InvalidPattern;
            try appendRawEscapedPatternAtom(allocator, pattern, index, out);
        },
    }
}

const ParsedEscape = struct {
    code_point: u21,
    end: usize,
};

fn parseHexEscape(pattern: []const u8, start: usize, digit_count: usize) ?ParsedEscape {
    if (start + 2 + digit_count > pattern.len) return null;
    var code_point: u21 = 0;
    var pos = start + 2;
    const end = pos + digit_count;
    while (pos < end) : (pos += 1) {
        const digit = hexValue(pattern[pos]) orelse return null;
        code_point = code_point * 16 + digit;
    }
    return .{ .code_point = code_point, .end = end };
}

fn parseDecimalEscape(pattern: []const u8, start: usize) ?ParsedEscape {
    if (start + 1 >= pattern.len or pattern[start] != '\\') return null;
    var pos = start + 1;
    if (pattern[pos] < '1' or pattern[pos] > '9') return null;
    var value: u21 = 0;
    while (pos < pattern.len and pattern[pos] >= '0' and pattern[pos] <= '9') : (pos += 1) {
        value = value * 10 + (pattern[pos] - '0');
        if (value >= max_captures) return null;
    }
    return .{ .code_point = value, .end = pos };
}

fn parseUnicodeEscape(pattern: []const u8, start: usize, unicode_mode: bool) ?ParsedEscape {
    if (start + 2 >= pattern.len or pattern[start + 1] != 'u') return null;
    if (unicode_mode and pattern[start + 2] == '{') {
        var code_point: u21 = 0;
        var pos = start + 3;
        var saw_digit = false;
        while (pos < pattern.len and pattern[pos] != '}') : (pos += 1) {
            const digit = hexValue(pattern[pos]) orelse return null;
            if (code_point > 0x10ffff / 16) return null;
            code_point = code_point * 16 + digit;
            if (code_point > 0x10ffff) return null;
            saw_digit = true;
        }
        if (!saw_digit or pos >= pattern.len or pattern[pos] != '}') return null;
        return .{ .code_point = code_point, .end = pos + 1 };
    }
    return parseHexEscape(pattern, start, 4);
}

fn appendCaseInsensitiveUnicodePropertyEscape(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pattern: []const u8,
    index: *usize,
    inverted: bool,
) NormalizeError!bool {
    const start = index.*;
    if (start + 3 >= pattern.len or pattern[start] != '\\' or pattern[start + 2] != '{') return false;
    var end = start + 3;
    while (end < pattern.len and pattern[end] != '}') : (end += 1) {
        if (pattern[end] == '\\') return false;
    }
    if (end >= pattern.len) return false;
    const name = pattern[start + 3 .. end];
    if (!isUppercaseLetterPropertyName(name)) return false;

    if (inverted) {
        try out.appendSlice(allocator, "[\\s\\S]");
    } else {
        try out.appendSlice(allocator, "\\p{LC}");
    }
    index.* = end + 1;
    return true;
}

fn isUppercaseLetterPropertyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Lu") or
        std.mem.eql(u8, name, "Uppercase_Letter") or
        std.mem.eql(u8, name, "General_Category=Lu") or
        std.mem.eql(u8, name, "General_Category=Uppercase_Letter") or
        std.mem.eql(u8, name, "gc=Lu") or
        std.mem.eql(u8, name, "gc=Uppercase_Letter");
}

fn appendCaseInsensitiveEscapedCodePoint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    raw_escape: []const u8,
    code_point: u21,
) NormalizeError!void {
    if (code_point <= 0x7f and isAsciiAlpha(@intCast(code_point))) {
        try appendCaseInsensitiveAsciiAtom(allocator, out, @intCast(code_point));
    } else if (code_point < 0x80) {
        try out.appendSlice(allocator, raw_escape);
    } else {
        return error.InvalidPattern;
    }
}

fn appendCaseInsensitiveClassEscapedCodePoint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    raw_escape: []const u8,
    code_point: u21,
) NormalizeError!void {
    if (code_point <= 0x7f and isAsciiAlpha(@intCast(code_point))) {
        try appendCaseInsensitiveAsciiClassAtom(allocator, out, @intCast(code_point));
    } else if (code_point < 0x80) {
        try out.appendSlice(allocator, raw_escape);
    } else {
        return error.InvalidPattern;
    }
}

fn appendCaseInsensitiveAsciiAtom(allocator: std.mem.Allocator, out: *std.ArrayList(u8), byte: u8) NormalizeError!void {
    try out.append(allocator, '[');
    try appendCaseInsensitiveAsciiClassAtom(allocator, out, byte);
    try out.append(allocator, ']');
}

fn appendCaseInsensitiveCaptureLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), capture: []const u8) NormalizeError!void {
    if (capture.len == 0) {
        try out.appendSlice(allocator, "(?:)");
        return;
    }
    var index: usize = 0;
    while (index < capture.len) {
        const byte = capture[index];
        if (byte == '\\') {
            const start = index;
            if (start + 1 >= capture.len) return error.InvalidPattern;
            const escaped = capture[start + 1];
            switch (escaped) {
                'x' => {
                    const parsed = parseHexEscape(capture, start, 2) orelse return error.InvalidPattern;
                    try appendCaseInsensitiveEscapedCodePoint(allocator, out, capture[start..parsed.end], parsed.code_point);
                    index = parsed.end;
                },
                'u' => {
                    const parsed = parseUnicodeEscape(capture, start, false) orelse return error.InvalidPattern;
                    try appendCaseInsensitiveEscapedCodePoint(allocator, out, capture[start..parsed.end], parsed.code_point);
                    index = parsed.end;
                },
                else => {
                    try out.appendSlice(allocator, capture[start .. start + 2]);
                    index = start + 2;
                },
            }
            continue;
        }
        if (isAsciiAlpha(byte)) {
            try appendCaseInsensitiveAsciiAtom(allocator, out, byte);
        } else if (byte < 0x80 and !isRegExpSyntaxByte(byte)) {
            try out.append(allocator, byte);
        } else {
            return error.InvalidPattern;
        }
        index += 1;
    }
}

fn appendCaseInsensitiveAsciiClassAtom(allocator: std.mem.Allocator, out: *std.ArrayList(u8), byte: u8) NormalizeError!void {
    const lower = asciiLower(byte);
    const upper = asciiUpper(byte);
    try out.append(allocator, lower);
    try out.append(allocator, upper);
}

fn shouldRewriteIgnoreCase(current_ignore_case: bool, state: *const NormalizeState) bool {
    return state.rewrite_ignore_case and current_ignore_case;
}

fn modifierPatternMentionsFlag(pattern: []const u8, flag: u8) NormalizeError!bool {
    var index: usize = 0;
    while (index < pattern.len) {
        switch (pattern[index]) {
            '\\' => index += if (index + 1 < pattern.len) 2 else 1,
            '[' => {
                try skipCharacterClass(pattern, &index);
            },
            '(' => {
                if (try parseModifierGroup(pattern, index)) |modifier_group| {
                    const slot = modifierFlagSlot(flag);
                    if (modifier_group.add[slot] or modifier_group.remove[slot]) return true;
                }
                index += 1;
            },
            else => index += 1,
        }
    }
    return false;
}

fn skipCharacterClass(pattern: []const u8, index: *usize) NormalizeError!void {
    std.debug.assert(pattern[index.*] == '[');
    index.* += 1;
    var escaped = false;
    while (index.* < pattern.len) : (index.* += 1) {
        const byte = pattern[index.*];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == ']') {
            index.* += 1;
            return;
        }
    }
    return error.InvalidPattern;
}

fn isSimpleLiteralCapture(body: []const u8) bool {
    var index: usize = 0;
    while (index < body.len) {
        const byte = body[index];
        if (byte == '\\') {
            if (index + 1 >= body.len) return false;
            const escaped = body[index + 1];
            switch (escaped) {
                'x' => {
                    const parsed = parseHexEscape(body, index, 2) orelse return false;
                    if (parsed.code_point >= 0x80) return false;
                    index = parsed.end;
                },
                'u' => {
                    const parsed = parseUnicodeEscape(body, index, false) orelse return false;
                    if (parsed.code_point >= 0x80) return false;
                    index = parsed.end;
                },
                'd', 'D', 's', 'S', 'w', 'W', 'b', 'B', 'p', 'P', 'k', '0'...'9' => return false,
                else => {
                    if (isAsciiAlpha(escaped)) return false;
                    index += 2;
                },
            }
            continue;
        }
        if (byte >= 0x80 or isRegExpSyntaxByte(byte)) return false;
        index += 1;
    }
    return true;
}

fn parseModifierGroup(pattern: []const u8, start: usize) NormalizeError!?ModifierGroup {
    if (!startsWithAt(pattern, start, "(?")) return null;
    var pos = start + 2;
    if (pos >= pattern.len) return null;
    const first = pattern[pos];
    if (first != '-' and !isRegExpModifierFlag(first)) return null;

    var add: [3]bool = .{ false, false, false };
    var remove: [3]bool = .{ false, false, false };
    var saw_modifier = false;
    while (pos < pattern.len and isRegExpModifierFlag(pattern[pos])) : (pos += 1) {
        const slot = modifierFlagSlot(pattern[pos]);
        if (add[slot]) return error.InvalidPattern;
        add[slot] = true;
        saw_modifier = true;
    }
    if (pos < pattern.len and pattern[pos] == '-') {
        pos += 1;
        while (pos < pattern.len and isRegExpModifierFlag(pattern[pos])) : (pos += 1) {
            const slot = modifierFlagSlot(pattern[pos]);
            if (remove[slot]) return error.InvalidPattern;
            remove[slot] = true;
            saw_modifier = true;
        }
    }
    if (!saw_modifier) return error.InvalidPattern;
    if (pos >= pattern.len or pattern[pos] != ':') return error.InvalidPattern;
    for (0..add.len) |slot| {
        if (add[slot] and remove[slot]) return error.InvalidPattern;
    }
    return .{ .body_start = pos + 1, .add = add, .remove = remove };
}

fn startsWithAt(haystack: []const u8, index: usize, needle: []const u8) bool {
    return index <= haystack.len and haystack.len - index >= needle.len and std.mem.eql(u8, haystack[index..][0..needle.len], needle);
}

fn isRegExpModifierFlag(byte: u8) bool {
    return byte == 'i' or byte == 'm' or byte == 's';
}

fn modifierFlagSlot(byte: u8) usize {
    return switch (byte) {
        'i' => 0,
        'm' => 1,
        's' => 2,
        else => unreachable,
    };
}

fn isNonCapturingAssertionStart(pattern: []const u8, start: usize) bool {
    return startsWithAt(pattern, start, "(?=") or
        startsWithAt(pattern, start, "(?!") or
        startsWithAt(pattern, start, "(?<=") or
        startsWithAt(pattern, start, "(?<!");
}

fn isRegExpSyntaxByte(byte: u8) bool {
    return switch (byte) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

fn isAsciiAlpha(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

fn asciiLower(byte: u8) u8 {
    if (byte >= 'A' and byte <= 'Z') return byte + ('a' - 'A');
    return byte;
}

fn asciiUpper(byte: u8) u8 {
    if (byte >= 'a' and byte <= 'z') return byte - ('a' - 'A');
    return byte;
}

fn hexValue(byte: u8) ?u21 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => 10 + byte - 'a',
        'A'...'F' => 10 + byte - 'A',
        else => null,
    };
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

pub fn execOnStringFromIndex(compiled: Compiled, string_value: core.JSValue, start_index: usize) ExecError!ExecStatus {
    const header = string_value.refHeader() orelse return .{ .result = .not_available };
    if (!string_value.isString()) return .{ .result = .not_available };
    const string_object: *core.string.String = @fieldParentPtr("header", header);

    return switch (string_object.resolveData()) {
        .latin1 => |bytes| try regexp_bytecode.exec(std.heap.page_allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index),
        .utf16 => |units| try regexp_bytecode.exec(std.heap.page_allocator, compiled.bytecode, .{ .utf16 = units }, start_index),
    };
}

pub fn testOnStringFromIndex(compiled: Compiled, string_value: core.JSValue, start_index: usize) ExecError!?bool {
    const header = string_value.refHeader() orelse return null;
    if (!string_value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);

    return switch (string_object.resolveData()) {
        .latin1 => |bytes| try regexp_bytecode.testMatch(std.heap.page_allocator, compiled.bytecode, .{ .latin1 = bytes }, start_index),
        .utf16 => |units| try regexp_bytecode.testMatch(std.heap.page_allocator, compiled.bytecode, .{ .utf16 = units }, start_index),
    };
}

pub fn flagsToBits(flags: []const u8) u32 {
    return compileFlagsToBits(flags) | if (hasFlag(flags, 'v')) regexp_bytecode.flags.unicode else 0;
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

fn flagsWithout(allocator: std.mem.Allocator, flags: []const u8, needle: u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (flags) |flag| {
        if (flag != needle) try out.append(allocator, flag);
    }
    return try out.toOwnedSlice(allocator);
}

fn patternUsesCodeUnitMode(flags: []const u8) bool {
    for (flags) |flag| {
        if (flag == 'u' or flag == 'v') return false;
    }
    return true;
}

test "quickjs_regexp compilation and execution" {
    var compiled = try compile(std.testing.allocator, "abc", "i");
    defer compiled.deinit(std.testing.allocator);
    const status = try regexp.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xxAbCy" }, 0);
    try std.testing.expect(status.result == .match);
    try std.testing.expectEqual(@as(usize, 2), status.match.start);
    try std.testing.expectEqual(@as(usize, 5), status.match.end);
}

