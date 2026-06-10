const core = @import("../core/root.zig");
const quickjs_regexp = @import("../libs/quickjs_regexp.zig");
const std = @import("std");

const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

pub const StaticMethod = enum(u32) {
    escape = 1,
};

pub const ConstructorMethod = enum(u32) {
    construct = 1000,
};

pub fn isConstructorRecord(function_object: *core.Object) bool {
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return false;
    return native_ref.domain == .regexp and native_ref.id == @intFromEnum(ConstructorMethod.construct);
}

pub const PrototypeMethod = enum(u32) {
    to_string = 101,
    test_ = 102,
    exec = 103,
    symbol_search = 104,
    symbol_match = 105,
    symbol_match_all = 106,
    symbol_replace = 107,
    symbol_split = 108,
    compile = 109,
};

pub const AccessorMethod = enum(u32) {
    source = 201,
    flags = 202,
    global = 203,
    ignore_case = 204,
    multiline = 205,
    dot_all = 206,
    unicode = 207,
    sticky = 208,
    has_indices = 209,
    unicode_sets = 210,
};

pub const LegacyAccessorMethod = enum(u32) {
    get_input = 301,
    set_input = 302,
    get_last_match = 303,
    get_last_paren = 304,
    get_left_context = 305,
    get_right_context = 306,
    get_capture_1 = 311,
    get_capture_2 = 312,
    get_capture_3 = 313,
    get_capture_4 = 314,
    get_capture_5 = 315,
    get_capture_6 = 316,
    get_capture_7 = 317,
    get_capture_8 = 318,
    get_capture_9 = 319,
};

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "escape")) return @intFromEnum(StaticMethod.escape);
    return null;
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return @intFromEnum(PrototypeMethod.to_string);
    if (std.mem.eql(u8, name, "test")) return @intFromEnum(PrototypeMethod.test_);
    if (std.mem.eql(u8, name, "exec")) return @intFromEnum(PrototypeMethod.exec);
    if (std.mem.eql(u8, name, "[Symbol.search]")) return @intFromEnum(PrototypeMethod.symbol_search);
    if (std.mem.eql(u8, name, "[Symbol.match]")) return @intFromEnum(PrototypeMethod.symbol_match);
    if (std.mem.eql(u8, name, "[Symbol.matchAll]")) return @intFromEnum(PrototypeMethod.symbol_match_all);
    if (std.mem.eql(u8, name, "[Symbol.replace]")) return @intFromEnum(PrototypeMethod.symbol_replace);
    if (std.mem.eql(u8, name, "[Symbol.split]")) return @intFromEnum(PrototypeMethod.symbol_split);
    if (std.mem.eql(u8, name, "compile")) return @intFromEnum(PrototypeMethod.compile);
    return null;
}

pub fn legacyPrototypeMethodId(name: []const u8) ?u32 {
    const id = prototypeMethodId(name) orelse return null;
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string),
        @intFromEnum(PrototypeMethod.test_),
        @intFromEnum(PrototypeMethod.exec),
        => decodePrototypeMethodId(id),
        else => null,
    };
}

pub fn decodePrototypeMethodId(id: u32) ?u32 {
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => 1,
        @intFromEnum(PrototypeMethod.test_) => 2,
        @intFromEnum(PrototypeMethod.exec) => 3,
        @intFromEnum(PrototypeMethod.symbol_search) => 4,
        @intFromEnum(PrototypeMethod.symbol_match) => 5,
        @intFromEnum(PrototypeMethod.symbol_match_all) => 6,
        @intFromEnum(PrototypeMethod.symbol_replace) => 7,
        @intFromEnum(PrototypeMethod.symbol_split) => 8,
        @intFromEnum(PrototypeMethod.compile) => 9,
        else => null,
    };
}

pub fn accessorMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "source")) return @intFromEnum(AccessorMethod.source);
    if (std.mem.eql(u8, name, "flags")) return @intFromEnum(AccessorMethod.flags);
    if (std.mem.eql(u8, name, "global")) return @intFromEnum(AccessorMethod.global);
    if (std.mem.eql(u8, name, "ignoreCase")) return @intFromEnum(AccessorMethod.ignore_case);
    if (std.mem.eql(u8, name, "multiline")) return @intFromEnum(AccessorMethod.multiline);
    if (std.mem.eql(u8, name, "dotAll")) return @intFromEnum(AccessorMethod.dot_all);
    if (std.mem.eql(u8, name, "unicode")) return @intFromEnum(AccessorMethod.unicode);
    if (std.mem.eql(u8, name, "sticky")) return @intFromEnum(AccessorMethod.sticky);
    if (std.mem.eql(u8, name, "hasIndices")) return @intFromEnum(AccessorMethod.has_indices);
    if (std.mem.eql(u8, name, "unicodeSets")) return @intFromEnum(AccessorMethod.unicode_sets);
    return null;
}

pub fn accessorNameFromId(id: u32) ?[]const u8 {
    return switch (id) {
        @intFromEnum(AccessorMethod.source) => "source",
        @intFromEnum(AccessorMethod.flags) => "flags",
        @intFromEnum(AccessorMethod.global) => "global",
        @intFromEnum(AccessorMethod.ignore_case) => "ignoreCase",
        @intFromEnum(AccessorMethod.multiline) => "multiline",
        @intFromEnum(AccessorMethod.dot_all) => "dotAll",
        @intFromEnum(AccessorMethod.unicode) => "unicode",
        @intFromEnum(AccessorMethod.sticky) => "sticky",
        @intFromEnum(AccessorMethod.has_indices) => "hasIndices",
        @intFromEnum(AccessorMethod.unicode_sets) => "unicodeSets",
        else => null,
    };
}

pub fn accessorNameFromGetterName(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "get ")) return null;
    const accessor_name = name["get ".len..];
    const id = accessorMethodId(accessor_name) orelse return null;
    return accessorNameFromId(id);
}

pub fn legacyAccessorMethodFromId(id: u32) ?LegacyAccessorMethod {
    return switch (id) {
        @intFromEnum(LegacyAccessorMethod.get_input) => .get_input,
        @intFromEnum(LegacyAccessorMethod.set_input) => .set_input,
        @intFromEnum(LegacyAccessorMethod.get_last_match) => .get_last_match,
        @intFromEnum(LegacyAccessorMethod.get_last_paren) => .get_last_paren,
        @intFromEnum(LegacyAccessorMethod.get_left_context) => .get_left_context,
        @intFromEnum(LegacyAccessorMethod.get_right_context) => .get_right_context,
        @intFromEnum(LegacyAccessorMethod.get_capture_1) => .get_capture_1,
        @intFromEnum(LegacyAccessorMethod.get_capture_2) => .get_capture_2,
        @intFromEnum(LegacyAccessorMethod.get_capture_3) => .get_capture_3,
        @intFromEnum(LegacyAccessorMethod.get_capture_4) => .get_capture_4,
        @intFromEnum(LegacyAccessorMethod.get_capture_5) => .get_capture_5,
        @intFromEnum(LegacyAccessorMethod.get_capture_6) => .get_capture_6,
        @intFromEnum(LegacyAccessorMethod.get_capture_7) => .get_capture_7,
        @intFromEnum(LegacyAccessorMethod.get_capture_8) => .get_capture_8,
        @intFromEnum(LegacyAccessorMethod.get_capture_9) => .get_capture_9,
        else => null,
    };
}

pub fn legacyCaptureIndex(method: LegacyAccessorMethod) ?usize {
    return switch (method) {
        .get_capture_1 => 0,
        .get_capture_2 => 1,
        .get_capture_3 => 2,
        .get_capture_4 => 3,
        .get_capture_5 => 4,
        .get_capture_6 => 5,
        .get_capture_7 => 6,
        .get_capture_8 => 7,
        .get_capture_9 => 8,
        else => null,
    };
}

/// QuickJS source map: narrow RegExp constructor payload used by transitional
/// `new_regexp` bytecode.
pub fn construct(rt: *core.JSRuntime, pattern: core.JSValue, flags: core.JSValue) !core.JSValue {
    return constructWithPrototype(rt, pattern, flags, null);
}

pub fn constructLiteral(rt: *core.JSRuntime, pattern: []const u8, flags: []const u8, prototype: ?*core.Object) !core.JSValue {
    if (!validatePatternAndFlags(pattern, flags)) return error.SyntaxError;

    var source_val = core.JSValue.undefinedValue();
    var flags_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &source_val },
        .{ .value = &flags_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer source_val.free(rt);
    defer flags_val.free(rt);

    source_val = (try core.string.String.createUtf8(rt, pattern)).value();
    flags_val = (try core.string.String.createUtf8(rt, flags)).value();

    return constructValidated(rt, source_val, flags_val, prototype);
}

pub fn constructLiteralWithValues(
    rt: *core.JSRuntime,
    source: core.JSValue,
    stored_flags: core.JSValue,
    pattern: []const u8,
    flags: []const u8,
    prototype: ?*core.Object,
) !core.JSValue {
    if (!validatePatternAndFlags(pattern, flags)) return error.SyntaxError;
    return constructValidated(rt, source, stored_flags, prototype);
}

/// Construct a RegExp object for bytecode emitted by `parseRegExpLiteral`.
/// The parser has already validated `pattern`/`flags`, so the execution path
/// must not recompile the pattern on every literal evaluation.
pub fn constructPrevalidatedLiteralWithValues(
    rt: *core.JSRuntime,
    source: core.JSValue,
    stored_flags: core.JSValue,
    prototype: ?*core.Object,
) !core.JSValue {
    return constructValidated(rt, source, stored_flags, prototype);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, pattern: core.JSValue, flags: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var source_val = core.JSValue.undefinedValue();
    var flags_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &source_val },
        .{ .value = &flags_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer source_val.free(rt);
    defer flags_val.free(rt);

    const pattern_object = regexpObjectFromValue(pattern);
    source_val = if (pattern_object) |regexp_object|
        try getInternalSource(regexp_object)
    else if (pattern.isUndefined())
        try createStringValue(rt, "")
    else
        try regExpStringValue(rt, pattern);

    flags_val = if (flags.isUndefined() and pattern_object != null)
        try getInternalFlags(pattern_object.?)
    else if (flags.isUndefined())
        try createStringValue(rt, "")
    else
        try regExpStringValue(rt, flags);

    var flag_bytes = std.ArrayList(u8).empty;
    defer flag_bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &flag_bytes, flags_val);
    var source_bytes = std.ArrayList(u8).empty;
    defer source_bytes.deinit(rt.memory.allocator);
    try appendRegExpPatternString(rt, &source_bytes, source_val, flag_bytes.items);
    if (!validatePatternAndFlags(source_bytes.items, flag_bytes.items)) return error.SyntaxError;

    return constructValidated(rt, source_val, flags_val, prototype);
}

fn regExpStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isString()) return value.dup();
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, value);
    return try createStringValue(rt, bytes.items);
}

fn constructValidated(rt: *core.JSRuntime, source: core.JSValue, stored_flags: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var source_val = source;
    var flags_val = stored_flags;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &source_val },
        .{ .value = &flags_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, core.class.ids.regexp, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    try object.setOptionalValueSlot(rt, object.regexpSourceSlot(), source_val.dup());
    try object.setOptionalValueSlot(rt, object.regexpFlagsSlot(), flags_val.dup());
    try object.setOptionalValueSlot(rt, object.regexpLastIndexSlot(), core.JSValue.int32(0));
    object.regexpLastIndexWritableSlot().* = true;
    return object.value();
}

test "constructValidated roots source and flags while creating regexp object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source_atom = try rt.atoms.newValueSymbol("gc-regexp-source-symbol");
    const flags_atom = try rt.atoms.newValueSymbol("gc-regexp-flags-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const regexp_value = try constructValidated(rt, core.JSValue.symbol(source_atom), core.JSValue.symbol(flags_atom), null);
    var regexp_alive = true;
    defer if (regexp_alive) regexp_value.free(rt);
    const regexp = regexpObjectFromValue(regexp_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(source_atom) != null);
    try std.testing.expect(rt.atoms.name(flags_atom) != null);
    try std.testing.expect(regexp.regexpSource().?.same(core.JSValue.symbol(source_atom)));
    try std.testing.expect(regexp.regexpFlags().?.same(core.JSValue.symbol(flags_atom)));

    regexp_value.free(rt);
    regexp_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(source_atom) == null);
    try std.testing.expect(rt.atoms.name(flags_atom) == null);
}

pub fn validatePatternAndFlags(pattern: []const u8, flags: []const u8) bool {
    var seen_u = false;
    var seen_v = false;
    var seen: [256]bool = [_]bool{false} ** 256;
    for (flags) |flag| {
        switch (flag) {
            'd', 'g', 'i', 'm', 's', 'u', 'v', 'y' => {},
            else => return false,
        }
        if (seen[flag]) return false;
        seen[flag] = true;
        if (flag == 'u') seen_u = true;
        if (flag == 'v') seen_v = true;
    }
    if (seen_u and seen_v) return false;
    if (isNativeFunctionMatcherUnicodeClass(pattern, flags)) return true;
    if (isFastValidatedAsciiSequencePattern(pattern, flags)) return true;
    if (isFastValidatedUtf8LiteralSequencePattern(pattern, flags)) return true;
    if (isFastValidatedUnicodePropertyPattern(pattern, flags)) return true;

    var compiled = quickjs_regexp.compile(std.heap.page_allocator, pattern, flags) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return isSupportedPropertyEscapeFallback(pattern, flags),
        else => return false,
    };
    defer compiled.deinit(std.heap.page_allocator);
    return true;
}

fn isNativeFunctionMatcherUnicodeClass(pattern: []const u8, flags: []const u8) bool {
    return flags.len == 0 and
        (std.mem.startsWith(u8, pattern, "(?:[A-Za-z") or
            std.mem.startsWith(u8, pattern, "(?:[0-9A-Z_a-z"));
}

fn isSupportedPropertyEscapeFallback(pattern: []const u8, flags: []const u8) bool {
    if (isSupportedStringPropertyEscapeFallback(pattern, flags)) return true;
    if (!propertyEscapeFallbackFlags(flags)) return false;
    if (supportedPropertyEscapePatternName(pattern)) |_| return true;
    const positive_prefix = "^\\p{";
    const negative_prefix = "^\\P{";
    const prefix_len: usize = if (std.mem.startsWith(u8, pattern, positive_prefix))
        positive_prefix.len
    else if (std.mem.startsWith(u8, pattern, negative_prefix))
        negative_prefix.len
    else
        return false;
    const suffix = "}+$";
    if (!std.mem.endsWith(u8, pattern, suffix)) return false;
    if (pattern.len <= prefix_len + suffix.len) return false;
    return isSupportedUnicodePropertyExpression(pattern[prefix_len .. pattern.len - suffix.len]);
}

fn isSupportedStringPropertyEscapeFallback(pattern: []const u8, flags: []const u8) bool {
    if (!stringPropertyEscapeFallbackFlags(flags)) return false;
    if (supportedStringPropertyEscapePatternName(pattern)) |_| return true;
    const positive_prefix = "^\\p{";
    if (!std.mem.startsWith(u8, pattern, positive_prefix)) return false;
    const suffix = "}+$";
    if (!std.mem.endsWith(u8, pattern, suffix)) return false;
    if (pattern.len <= positive_prefix.len + suffix.len) return false;
    return isSupportedStringUnicodePropertyExpression(pattern[positive_prefix.len .. pattern.len - suffix.len]);
}

fn propertyEscapeFallbackFlags(flags: []const u8) bool {
    var has_u = false;
    for (flags) |flag| {
        switch (flag) {
            'd', 'g', 'y' => {},
            'u' => has_u = true,
            else => return false,
        }
    }
    return has_u;
}

fn stringPropertyEscapeFallbackFlags(flags: []const u8) bool {
    var has_v = false;
    for (flags) |flag| {
        switch (flag) {
            'd', 'g', 'y' => {},
            'v' => has_v = true,
            else => return false,
        }
    }
    return has_v;
}

fn supportedPropertyEscapePatternName(pattern: []const u8) ?[]const u8 {
    const positive_prefix = "\\p{";
    const negative_prefix = "\\P{";
    const prefix_len: usize = if (std.mem.startsWith(u8, pattern, positive_prefix))
        positive_prefix.len
    else if (std.mem.startsWith(u8, pattern, negative_prefix))
        negative_prefix.len
    else
        return null;
    if (pattern.len <= prefix_len or pattern[pattern.len - 1] != '}') return null;
    const name = pattern[prefix_len .. pattern.len - 1];
    if (!isSupportedUnicodePropertyExpression(name)) return null;
    return name;
}

fn supportedStringPropertyEscapePatternName(pattern: []const u8) ?[]const u8 {
    const positive_prefix = "\\p{";
    if (!std.mem.startsWith(u8, pattern, positive_prefix)) return null;
    if (pattern.len <= positive_prefix.len or pattern[pattern.len - 1] != '}') return null;
    const name = pattern[positive_prefix.len .. pattern.len - 1];
    if (!isSupportedStringUnicodePropertyExpression(name)) return null;
    return name;
}

fn isSupportedStringUnicodePropertyExpression(name: []const u8) bool {
    return std.mem.eql(u8, name, "RGI_Emoji");
}

fn isSimpleGlobalClassEscapePattern(pattern: []const u8, flags: []const u8) bool {
    if (flags.len != 1 or flags[0] != 'g') return false;
    if (pattern.len != 3 or pattern[0] != '\\' or pattern[2] != '+') return false;
    return switch (pattern[1]) {
        'd', 'D', 's', 'S', 'w', 'W' => true,
        else => false,
    };
}

fn isFastValidatedAsciiSequencePattern(pattern: []const u8, flags: []const u8) bool {
    if (pattern.len == 0 or !fastAsciiValidationFlags(flags)) return false;
    var index: usize = 0;
    while (index < pattern.len) {
        if (!consumeFastAsciiAtom(pattern, &index)) return false;
        if (index < pattern.len and isSimpleQuantifierByte(pattern[index])) {
            index += 1;
            if (index < pattern.len and pattern[index] == '?') index += 1;
        }
    }
    return true;
}

fn isFastValidatedUtf8LiteralSequencePattern(pattern: []const u8, flags: []const u8) bool {
    if (pattern.len == 0 or !fastAsciiValidationFlags(flags)) return false;
    if (bytesAreAscii(pattern)) return false;

    var index: usize = 0;
    while (index < pattern.len) {
        if (!consumeFastUtf8LiteralAtom(pattern, &index)) return false;
        if (index < pattern.len and isSimpleQuantifierByte(pattern[index])) {
            index += 1;
            if (index < pattern.len and pattern[index] == '?') index += 1;
        }
    }
    return true;
}

test "fast regexp validation accepts simple utf8 literal sequences conservatively" {
    try std.testing.expect(isFastValidatedUtf8LiteralSequencePattern("é+", ""));
    try std.testing.expect(isFastValidatedUtf8LiteralSequencePattern("éé?", "g"));
    try std.testing.expect(!isFastValidatedUtf8LiteralSequencePattern("abc+", ""));
    try std.testing.expect(!isFastValidatedUtf8LiteralSequencePattern("é++", ""));
    try std.testing.expect(!isFastValidatedUtf8LiteralSequencePattern("é{2}", ""));
    try std.testing.expect(!isFastValidatedUtf8LiteralSequencePattern("é+", "i"));
}

fn fastAsciiValidationFlags(flags: []const u8) bool {
    for (flags) |flag| {
        switch (flag) {
            'd', 'g', 'y' => {},
            else => return false,
        }
    }
    return true;
}

fn bytesAreAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

fn consumeFastAsciiAtom(pattern: []const u8, index: *usize) bool {
    if (index.* >= pattern.len) return false;
    const byte = pattern[index.*];
    if (byte == '\\') {
        if (index.* + 1 >= pattern.len) return false;
        switch (pattern[index.* + 1]) {
            'd', 'D', 's', 'S', 'w', 'W' => {
                index.* += 2;
                return true;
            },
            else => return false,
        }
    }
    if (byte >= 0x80 or isFastAsciiRegExpSyntaxByte(byte)) return false;
    index.* += 1;
    return true;
}

fn consumeFastUtf8LiteralAtom(pattern: []const u8, index: *usize) bool {
    if (index.* >= pattern.len) return false;
    const byte = pattern[index.*];
    if (byte < 0x80) {
        if (isFastAsciiRegExpSyntaxByte(byte)) return false;
        index.* += 1;
        return true;
    }

    const width = std.unicode.utf8ByteSequenceLength(byte) catch return false;
    if (index.* + width > pattern.len) return false;
    const code_point = std.unicode.utf8Decode(pattern[index.* .. index.* + width]) catch return false;
    if (code_point > std.math.maxInt(u16)) return false;
    index.* += width;
    return true;
}

fn isFastAsciiRegExpSyntaxByte(byte: u8) bool {
    return switch (byte) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

fn isSimpleQuantifierByte(byte: u8) bool {
    return byte == '*' or byte == '+' or byte == '?';
}

fn isFastValidatedUnicodePropertyPattern(pattern: []const u8, flags: []const u8) bool {
    if (!propertyEscapeFallbackFlags(flags)) return false;
    var index: usize = 0;
    if (!consumeFastUnicodePropertyEscape(pattern, &index)) return false;
    if (index == pattern.len) return true;
    if (!isSimpleQuantifierByte(pattern[index])) return false;
    index += 1;
    if (index < pattern.len and pattern[index] == '?') index += 1;
    return index == pattern.len;
}

fn consumeFastUnicodePropertyEscape(pattern: []const u8, index: *usize) bool {
    if (index.* + 3 >= pattern.len or pattern[index.*] != '\\') return false;
    const kind = pattern[index.* + 1];
    if (kind != 'p' and kind != 'P') return false;
    if (pattern[index.* + 2] != '{') return false;
    var scan = index.* + 3;
    const name_start = scan;
    while (scan < pattern.len and pattern[scan] != '}') : (scan += 1) {}
    if (scan == name_start or scan >= pattern.len or pattern[scan] != '}') return false;
    if (!isSupportedUnicodePropertyExpression(pattern[name_start..scan])) return false;
    index.* = scan + 1;
    return true;
}

fn hasTrailingEscape(pattern: []const u8) bool {
    var index: usize = 0;
    var in_class = false;
    var class_at_start = false;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == '\\') {
            if (index + 1 >= pattern.len) return true;
            index += 1;
            continue;
        }
        if (!in_class and byte == '[') {
            in_class = true;
            class_at_start = true;
            continue;
        }
        if (in_class) {
            if (byte == ']' and !class_at_start) in_class = false;
            class_at_start = false;
        }
    }
    return false;
}

fn hasInvalidUnicodePattern(pattern: []const u8) bool {
    var index: usize = 0;
    var group_depth: usize = 0;
    while (index < pattern.len) {
        switch (pattern[index]) {
            '\\' => {
                if (invalidUnicodeEscape(pattern, &index, false)) return true;
            },
            '[' => {
                index += 1;
                if (invalidUnicodeClass(pattern, &index)) return true;
            },
            '(' => {
                if (startsQuantifiedLookahead(pattern, index)) return true;
                group_depth += 1;
                index += 1;
                if (index < pattern.len and pattern[index] == '?') index += groupPrefixWidth(pattern[index..]);
            },
            ')' => {
                if (group_depth == 0) return true;
                group_depth -= 1;
                index += 1;
            },
            '{' => {
                var end = index;
                const quantifier = readQuantifier(pattern, index, &end) orelse return true;
                if (!quantifier) return true;
                index = end;
            },
            else => index += 1,
        }
    }
    return group_depth != 0;
}

fn invalidUnicodeClass(pattern: []const u8, index: *usize) bool {
    var at_start = true;
    if (index.* < pattern.len and pattern[index.*] == '^') index.* += 1;
    while (index.* < pattern.len) {
        if (pattern[index.*] == ']' and !at_start) {
            index.* += 1;
            return false;
        }
        if (pattern[index.*] == '\\') {
            if (invalidUnicodeEscape(pattern, index, true)) return true;
        } else {
            index.* += 1;
        }
        at_start = false;
    }
    return true;
}

fn invalidUnicodeEscape(pattern: []const u8, index: *usize, in_class: bool) bool {
    if (index.* + 1 >= pattern.len or pattern[index.*] != '\\') return true;
    const escaped = pattern[index.* + 1];
    if (isUnicodeSyntaxEscape(escaped) or escaped == '/') {
        index.* += 2;
        return false;
    }
    switch (escaped) {
        'b' => {
            index.* += 2;
            return false;
        },
        'B' => {
            if (in_class) return true;
            index.* += 2;
            return false;
        },
        'f', 'n', 'r', 't', 'v', 'd', 'D', 's', 'S', 'w', 'W' => {
            index.* += 2;
            return false;
        },
        'p', 'P' => return consumeUnicodePropertyEscape(pattern, index),
        'c' => {
            if (index.* + 2 >= pattern.len or !std.ascii.isAlphabetic(pattern[index.* + 2])) return true;
            index.* += 3;
            return false;
        },
        'x' => {
            if (!hasHexDigits(pattern, index.* + 2, 2)) return true;
            index.* += 4;
            return false;
        },
        'u' => return consumeUnicodeEscape(pattern, index),
        'k' => return consumeNamedBackreference(pattern, index, in_class),
        '0' => {
            if (index.* + 2 < pattern.len and std.ascii.isDigit(pattern[index.* + 2])) return true;
            index.* += 2;
            return false;
        },
        '1'...'9' => return consumeDecimalBackreference(pattern, index, in_class),
        '-' => {
            if (!in_class) return true;
            index.* += 2;
            return false;
        },
        else => return true,
    }
}

fn consumeUnicodePropertyEscape(pattern: []const u8, index: *usize) bool {
    if (index.* + 3 >= pattern.len or pattern[index.* + 2] != '{') return true;
    var scan = index.* + 3;
    const name_start = scan;
    while (scan < pattern.len and pattern[scan] != '}') : (scan += 1) {}
    if (scan == name_start or scan >= pattern.len or pattern[scan] != '}') return true;
    const name = pattern[name_start..scan];
    if (!isSupportedUnicodePropertyExpression(name)) return true;
    index.* = scan + 1;
    return false;
}

fn isSupportedUnicodePropertyExpression(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '=') != null) return isSupportedUnicodePropertyValueExpression(name);
    return isSupportedBinaryUnicodeProperty(name);
}

fn isSupportedBinaryUnicodeProperty(name: []const u8) bool {
    return std.mem.eql(u8, name, "ASCII") or
        std.mem.eql(u8, name, "Hex") or
        std.mem.eql(u8, name, "Hex_Digit") or
        std.mem.eql(u8, name, "Cased") or
        std.mem.eql(u8, name, "Dash") or
        std.mem.eql(u8, name, "Bidi_Mirrored") or
        std.mem.eql(u8, name, "Bidi_M") or
        std.mem.eql(u8, name, "Bidi_Control") or
        std.mem.eql(u8, name, "Bidi_C") or
        std.mem.eql(u8, name, "Deprecated") or
        std.mem.eql(u8, name, "Dep") or
        std.mem.eql(u8, name, "Diacritic") or
        std.mem.eql(u8, name, "Dia") or
        std.mem.eql(u8, name, "IDS_Binary_Operator") or
        std.mem.eql(u8, name, "IDSB") or
        std.mem.eql(u8, name, "IDS_Trinary_Operator") or
        std.mem.eql(u8, name, "IDST") or
        std.mem.eql(u8, name, "ID_Start") or
        std.mem.eql(u8, name, "IDS") or
        std.mem.eql(u8, name, "ID_Continue") or
        std.mem.eql(u8, name, "IDC") or
        std.mem.eql(u8, name, "XID_Start") or
        std.mem.eql(u8, name, "XIDS") or
        std.mem.eql(u8, name, "XID_Continue") or
        std.mem.eql(u8, name, "XIDC") or
        std.mem.eql(u8, name, "Join_Control") or
        std.mem.eql(u8, name, "Join_C") or
        std.mem.eql(u8, name, "Radical") or
        std.mem.eql(u8, name, "Variation_Selector") or
        std.mem.eql(u8, name, "VS") or
        std.mem.eql(u8, name, "Quotation_Mark") or
        std.mem.eql(u8, name, "QMark") or
        std.mem.eql(u8, name, "Pattern_White_Space") or
        std.mem.eql(u8, name, "Pat_WS") or
        std.mem.eql(u8, name, "White_Space") or
        std.mem.eql(u8, name, "space") or
        std.mem.eql(u8, name, "Regional_Indicator") or
        std.mem.eql(u8, name, "RI") or
        std.mem.eql(u8, name, "Logical_Order_Exception") or
        std.mem.eql(u8, name, "LOE") or
        std.mem.eql(u8, name, "Noncharacter_Code_Point") or
        std.mem.eql(u8, name, "NChar") or
        std.mem.eql(u8, name, "Pattern_Syntax") or
        std.mem.eql(u8, name, "Pat_Syn") or
        std.mem.eql(u8, name, "Default_Ignorable_Code_Point") or
        std.mem.eql(u8, name, "DI") or
        std.mem.eql(u8, name, "Alphabetic") or
        std.mem.eql(u8, name, "Alpha") or
        std.mem.eql(u8, name, "Case_Ignorable") or
        std.mem.eql(u8, name, "CI") or
        std.mem.eql(u8, name, "Changes_When_Casemapped") or
        std.mem.eql(u8, name, "CWCM") or
        std.mem.eql(u8, name, "Changes_When_Casefolded") or
        std.mem.eql(u8, name, "CWCF") or
        std.mem.eql(u8, name, "Changes_When_Lowercased") or
        std.mem.eql(u8, name, "CWL") or
        std.mem.eql(u8, name, "Changes_When_Titlecased") or
        std.mem.eql(u8, name, "CWT") or
        std.mem.eql(u8, name, "Changes_When_Uppercased") or
        std.mem.eql(u8, name, "CWU") or
        std.mem.eql(u8, name, "Changes_When_NFKC_Casefolded") or
        std.mem.eql(u8, name, "CWKCF") or
        std.mem.eql(u8, name, "Cased_Letter") or
        std.mem.eql(u8, name, "LC") or
        std.mem.eql(u8, name, "Letter") or
        std.mem.eql(u8, name, "L") or
        std.mem.eql(u8, name, "Lowercase") or
        std.mem.eql(u8, name, "Lower") or
        std.mem.eql(u8, name, "Lowercase_Letter") or
        std.mem.eql(u8, name, "Ll") or
        std.mem.eql(u8, name, "Uppercase") or
        std.mem.eql(u8, name, "Upper") or
        std.mem.eql(u8, name, "Uppercase_Letter") or
        std.mem.eql(u8, name, "Lu") or
        std.mem.eql(u8, name, "Titlecase_Letter") or
        std.mem.eql(u8, name, "Lt") or
        std.mem.eql(u8, name, "Format") or
        std.mem.eql(u8, name, "Cf") or
        std.mem.eql(u8, name, "Unassigned") or
        std.mem.eql(u8, name, "Cn") or
        std.mem.eql(u8, name, "Other") or
        std.mem.eql(u8, name, "C") or
        std.mem.eql(u8, name, "Decimal_Number") or
        std.mem.eql(u8, name, "Nd") or
        std.mem.eql(u8, name, "digit") or
        std.mem.eql(u8, name, "Other_Number") or
        std.mem.eql(u8, name, "No") or
        std.mem.eql(u8, name, "Number") or
        std.mem.eql(u8, name, "N") or
        std.mem.eql(u8, name, "Math_Symbol") or
        std.mem.eql(u8, name, "Sm") or
        std.mem.eql(u8, name, "Other_Symbol") or
        std.mem.eql(u8, name, "So") or
        std.mem.eql(u8, name, "Symbol") or
        std.mem.eql(u8, name, "S") or
        std.mem.eql(u8, name, "Close_Punctuation") or
        std.mem.eql(u8, name, "Pe") or
        std.mem.eql(u8, name, "Open_Punctuation") or
        std.mem.eql(u8, name, "Ps") or
        std.mem.eql(u8, name, "Other_Punctuation") or
        std.mem.eql(u8, name, "Po") or
        std.mem.eql(u8, name, "Punctuation") or
        std.mem.eql(u8, name, "P") or
        std.mem.eql(u8, name, "punct") or
        std.mem.eql(u8, name, "Spacing_Mark") or
        std.mem.eql(u8, name, "Mc") or
        std.mem.eql(u8, name, "Nonspacing_Mark") or
        std.mem.eql(u8, name, "Mn") or
        std.mem.eql(u8, name, "Mark") or
        std.mem.eql(u8, name, "Combining_Mark") or
        std.mem.eql(u8, name, "M") or
        std.mem.eql(u8, name, "Modifier_Letter") or
        std.mem.eql(u8, name, "Lm") or
        std.mem.eql(u8, name, "Other_Letter") or
        std.mem.eql(u8, name, "Lo") or
        std.mem.eql(u8, name, "Control") or
        std.mem.eql(u8, name, "Cc") or
        std.mem.eql(u8, name, "cntrl") or
        std.mem.eql(u8, name, "Connector_Punctuation") or
        std.mem.eql(u8, name, "Pc") or
        std.mem.eql(u8, name, "Letter_Number") or
        std.mem.eql(u8, name, "Nl") or
        std.mem.eql(u8, name, "Separator") or
        std.mem.eql(u8, name, "Z") or
        std.mem.eql(u8, name, "Line_Separator") or
        std.mem.eql(u8, name, "Zl") or
        std.mem.eql(u8, name, "Paragraph_Separator") or
        std.mem.eql(u8, name, "Zp") or
        std.mem.eql(u8, name, "Space_Separator") or
        std.mem.eql(u8, name, "Zs") or
        std.mem.eql(u8, name, "Private_Use") or
        std.mem.eql(u8, name, "Co") or
        std.mem.eql(u8, name, "Surrogate") or
        std.mem.eql(u8, name, "Cs") or
        std.mem.eql(u8, name, "Enclosing_Mark") or
        std.mem.eql(u8, name, "Me") or
        std.mem.eql(u8, name, "Currency_Symbol") or
        std.mem.eql(u8, name, "Sc") or
        std.mem.eql(u8, name, "Modifier_Symbol") or
        std.mem.eql(u8, name, "Sk") or
        std.mem.eql(u8, name, "Dash_Punctuation") or
        std.mem.eql(u8, name, "Pd") or
        std.mem.eql(u8, name, "Initial_Punctuation") or
        std.mem.eql(u8, name, "Pi") or
        std.mem.eql(u8, name, "Final_Punctuation") or
        std.mem.eql(u8, name, "Pf") or
        std.mem.eql(u8, name, "Any") or
        std.mem.eql(u8, name, "Assigned") or
        std.mem.eql(u8, name, "Emoji") or
        std.mem.eql(u8, name, "Emoji_Component") or
        std.mem.eql(u8, name, "EComp") or
        std.mem.eql(u8, name, "Emoji_Modifier") or
        std.mem.eql(u8, name, "EMod") or
        std.mem.eql(u8, name, "Emoji_Modifier_Base") or
        std.mem.eql(u8, name, "EBase") or
        std.mem.eql(u8, name, "Emoji_Presentation") or
        std.mem.eql(u8, name, "EPres") or
        std.mem.eql(u8, name, "Extended_Pictographic") or
        std.mem.eql(u8, name, "ExtPict") or
        std.mem.eql(u8, name, "Grapheme_Base") or
        std.mem.eql(u8, name, "Gr_Base") or
        std.mem.eql(u8, name, "Grapheme_Extend") or
        std.mem.eql(u8, name, "Gr_Ext") or
        std.mem.eql(u8, name, "Extender") or
        std.mem.eql(u8, name, "Ext") or
        std.mem.eql(u8, name, "Sentence_Terminal") or
        std.mem.eql(u8, name, "STerm") or
        std.mem.eql(u8, name, "Soft_Dotted") or
        std.mem.eql(u8, name, "SD") or
        std.mem.eql(u8, name, "Terminal_Punctuation") or
        std.mem.eql(u8, name, "Term") or
        std.mem.eql(u8, name, "Math") or
        std.mem.eql(u8, name, "Ideographic") or
        std.mem.eql(u8, name, "Ideo") or
        std.mem.eql(u8, name, "Unified_Ideograph") or
        std.mem.eql(u8, name, "UIdeo") or
        std.mem.eql(u8, name, "ASCII_Hex_Digit") or
        std.mem.eql(u8, name, "AHex");
}

fn isSupportedUnicodePropertyValueExpression(name: []const u8) bool {
    return isSupportedExactScriptExtensionsExpression(name) or
        std.mem.eql(u8, name, "Script=Adlam") or
        std.mem.eql(u8, name, "Script=Adlm") or
        std.mem.eql(u8, name, "sc=Adlam") or
        std.mem.eql(u8, name, "sc=Adlm") or
        std.mem.eql(u8, name, "Script_Extensions=Adlam") or
        std.mem.eql(u8, name, "Script_Extensions=Adlm") or
        std.mem.eql(u8, name, "scx=Adlam") or
        std.mem.eql(u8, name, "scx=Adlm") or
        std.mem.eql(u8, name, "Script=Anatolian_Hieroglyphs") or
        std.mem.eql(u8, name, "Script=Hluw") or
        std.mem.eql(u8, name, "sc=Anatolian_Hieroglyphs") or
        std.mem.eql(u8, name, "sc=Hluw") or
        std.mem.eql(u8, name, "Script=Ahom") or
        std.mem.eql(u8, name, "sc=Ahom") or
        std.mem.eql(u8, name, "Script_Extensions=Ahom") or
        std.mem.eql(u8, name, "scx=Ahom") or
        std.mem.eql(u8, name, "Script=Arabic") or
        std.mem.eql(u8, name, "Script=Arab") or
        std.mem.eql(u8, name, "sc=Arabic") or
        std.mem.eql(u8, name, "sc=Arab") or
        std.mem.eql(u8, name, "Script_Extensions=Arabic") or
        std.mem.eql(u8, name, "Script_Extensions=Arab") or
        std.mem.eql(u8, name, "scx=Arabic") or
        std.mem.eql(u8, name, "scx=Arab") or
        std.mem.eql(u8, name, "Script=Armenian") or
        std.mem.eql(u8, name, "Script=Armn") or
        std.mem.eql(u8, name, "sc=Armenian") or
        std.mem.eql(u8, name, "sc=Armn") or
        std.mem.eql(u8, name, "Script_Extensions=Armenian") or
        std.mem.eql(u8, name, "Script_Extensions=Armn") or
        std.mem.eql(u8, name, "scx=Armenian") or
        std.mem.eql(u8, name, "scx=Armn") or
        std.mem.eql(u8, name, "Script=Avestan") or
        std.mem.eql(u8, name, "Script=Avst") or
        std.mem.eql(u8, name, "sc=Avestan") or
        std.mem.eql(u8, name, "sc=Avst") or
        std.mem.eql(u8, name, "Script_Extensions=Avestan") or
        std.mem.eql(u8, name, "Script_Extensions=Avst") or
        std.mem.eql(u8, name, "scx=Avestan") or
        std.mem.eql(u8, name, "scx=Avst") or
        std.mem.eql(u8, name, "Script=Bassa_Vah") or
        std.mem.eql(u8, name, "Script=Bass") or
        std.mem.eql(u8, name, "sc=Bassa_Vah") or
        std.mem.eql(u8, name, "sc=Bass") or
        std.mem.eql(u8, name, "Script=Balinese") or
        std.mem.eql(u8, name, "Script=Bali") or
        std.mem.eql(u8, name, "sc=Balinese") or
        std.mem.eql(u8, name, "sc=Bali") or
        std.mem.eql(u8, name, "Script=Bamum") or
        std.mem.eql(u8, name, "Script=Bamu") or
        std.mem.eql(u8, name, "sc=Bamum") or
        std.mem.eql(u8, name, "sc=Bamu") or
        std.mem.eql(u8, name, "Script=Beria_Erfe") or
        std.mem.eql(u8, name, "Script=Berf") or
        std.mem.eql(u8, name, "sc=Beria_Erfe") or
        std.mem.eql(u8, name, "sc=Berf") or
        std.mem.eql(u8, name, "Script=Batak") or
        std.mem.eql(u8, name, "Script=Batk") or
        std.mem.eql(u8, name, "sc=Batak") or
        std.mem.eql(u8, name, "sc=Batk") or
        std.mem.eql(u8, name, "Script_Extensions=Batak") or
        std.mem.eql(u8, name, "Script_Extensions=Batk") or
        std.mem.eql(u8, name, "scx=Batak") or
        std.mem.eql(u8, name, "scx=Batk") or
        std.mem.eql(u8, name, "Script=Bengali") or
        std.mem.eql(u8, name, "Script=Beng") or
        std.mem.eql(u8, name, "sc=Bengali") or
        std.mem.eql(u8, name, "sc=Beng") or
        std.mem.eql(u8, name, "Script_Extensions=Bengali") or
        std.mem.eql(u8, name, "Script_Extensions=Beng") or
        std.mem.eql(u8, name, "scx=Bengali") or
        std.mem.eql(u8, name, "scx=Beng") or
        std.mem.eql(u8, name, "Script=Bhaiksuki") or
        std.mem.eql(u8, name, "Script=Bhks") or
        std.mem.eql(u8, name, "sc=Bhaiksuki") or
        std.mem.eql(u8, name, "sc=Bhks") or
        std.mem.eql(u8, name, "Script=Bopomofo") or
        std.mem.eql(u8, name, "Script=Bopo") or
        std.mem.eql(u8, name, "sc=Bopomofo") or
        std.mem.eql(u8, name, "sc=Bopo") or
        std.mem.eql(u8, name, "Script_Extensions=Bopomofo") or
        std.mem.eql(u8, name, "Script_Extensions=Bopo") or
        std.mem.eql(u8, name, "scx=Bopomofo") or
        std.mem.eql(u8, name, "scx=Bopo") or
        std.mem.eql(u8, name, "Script=Brahmi") or
        std.mem.eql(u8, name, "Script=Brah") or
        std.mem.eql(u8, name, "sc=Brahmi") or
        std.mem.eql(u8, name, "sc=Brah") or
        std.mem.eql(u8, name, "Script=Braille") or
        std.mem.eql(u8, name, "Script=Brai") or
        std.mem.eql(u8, name, "sc=Braille") or
        std.mem.eql(u8, name, "sc=Brai") or
        std.mem.eql(u8, name, "Script=Buginese") or
        std.mem.eql(u8, name, "Script=Bugi") or
        std.mem.eql(u8, name, "sc=Buginese") or
        std.mem.eql(u8, name, "sc=Bugi") or
        std.mem.eql(u8, name, "Script_Extensions=Buginese") or
        std.mem.eql(u8, name, "Script_Extensions=Bugi") or
        std.mem.eql(u8, name, "scx=Buginese") or
        std.mem.eql(u8, name, "scx=Bugi") or
        std.mem.eql(u8, name, "Script=Buhid") or
        std.mem.eql(u8, name, "Script=Buhd") or
        std.mem.eql(u8, name, "sc=Buhid") or
        std.mem.eql(u8, name, "sc=Buhd") or
        std.mem.eql(u8, name, "Script_Extensions=Buhid") or
        std.mem.eql(u8, name, "Script_Extensions=Buhd") or
        std.mem.eql(u8, name, "scx=Buhid") or
        std.mem.eql(u8, name, "scx=Buhd") or
        std.mem.eql(u8, name, "Script=Carian") or
        std.mem.eql(u8, name, "Script=Cari") or
        std.mem.eql(u8, name, "sc=Carian") or
        std.mem.eql(u8, name, "sc=Cari") or
        std.mem.eql(u8, name, "Script_Extensions=Carian") or
        std.mem.eql(u8, name, "Script_Extensions=Cari") or
        std.mem.eql(u8, name, "scx=Carian") or
        std.mem.eql(u8, name, "scx=Cari") or
        std.mem.eql(u8, name, "Script=Caucasian_Albanian") or
        std.mem.eql(u8, name, "Script=Aghb") or
        std.mem.eql(u8, name, "sc=Caucasian_Albanian") or
        std.mem.eql(u8, name, "sc=Aghb") or
        std.mem.eql(u8, name, "Script_Extensions=Caucasian_Albanian") or
        std.mem.eql(u8, name, "Script_Extensions=Aghb") or
        std.mem.eql(u8, name, "scx=Caucasian_Albanian") or
        std.mem.eql(u8, name, "scx=Aghb") or
        std.mem.eql(u8, name, "Script=Canadian_Aboriginal") or
        std.mem.eql(u8, name, "Script=Cans") or
        std.mem.eql(u8, name, "sc=Canadian_Aboriginal") or
        std.mem.eql(u8, name, "sc=Cans") or
        std.mem.eql(u8, name, "Script=Common") or
        std.mem.eql(u8, name, "Script=Zyyy") or
        std.mem.eql(u8, name, "sc=Common") or
        std.mem.eql(u8, name, "sc=Zyyy") or
        std.mem.eql(u8, name, "Script_Extensions=Common") or
        std.mem.eql(u8, name, "Script_Extensions=Zyyy") or
        std.mem.eql(u8, name, "scx=Common") or
        std.mem.eql(u8, name, "scx=Zyyy") or
        std.mem.eql(u8, name, "Script=Chakma") or
        std.mem.eql(u8, name, "Script=Cakm") or
        std.mem.eql(u8, name, "sc=Chakma") or
        std.mem.eql(u8, name, "sc=Cakm") or
        std.mem.eql(u8, name, "Script_Extensions=Chakma") or
        std.mem.eql(u8, name, "Script_Extensions=Cakm") or
        std.mem.eql(u8, name, "scx=Chakma") or
        std.mem.eql(u8, name, "scx=Cakm") or
        std.mem.eql(u8, name, "Script=Cham") or
        std.mem.eql(u8, name, "sc=Cham") or
        std.mem.eql(u8, name, "Script=Cherokee") or
        std.mem.eql(u8, name, "Script=Cher") or
        std.mem.eql(u8, name, "sc=Cherokee") or
        std.mem.eql(u8, name, "sc=Cher") or
        std.mem.eql(u8, name, "Script_Extensions=Cherokee") or
        std.mem.eql(u8, name, "Script_Extensions=Cher") or
        std.mem.eql(u8, name, "scx=Cherokee") or
        std.mem.eql(u8, name, "scx=Cher") or
        std.mem.eql(u8, name, "Script=Chorasmian") or
        std.mem.eql(u8, name, "Script=Chrs") or
        std.mem.eql(u8, name, "sc=Chorasmian") or
        std.mem.eql(u8, name, "sc=Chrs") or
        std.mem.eql(u8, name, "Script=Coptic") or
        std.mem.eql(u8, name, "Script=Copt") or
        std.mem.eql(u8, name, "Script=Qaac") or
        std.mem.eql(u8, name, "sc=Coptic") or
        std.mem.eql(u8, name, "sc=Copt") or
        std.mem.eql(u8, name, "sc=Qaac") or
        std.mem.eql(u8, name, "Script_Extensions=Coptic") or
        std.mem.eql(u8, name, "Script_Extensions=Copt") or
        std.mem.eql(u8, name, "Script_Extensions=Qaac") or
        std.mem.eql(u8, name, "scx=Coptic") or
        std.mem.eql(u8, name, "scx=Copt") or
        std.mem.eql(u8, name, "scx=Qaac") or
        std.mem.eql(u8, name, "Script=Cyrillic") or
        std.mem.eql(u8, name, "Script=Cyrl") or
        std.mem.eql(u8, name, "sc=Cyrillic") or
        std.mem.eql(u8, name, "sc=Cyrl") or
        std.mem.eql(u8, name, "Script_Extensions=Cyrillic") or
        std.mem.eql(u8, name, "Script_Extensions=Cyrl") or
        std.mem.eql(u8, name, "scx=Cyrillic") or
        std.mem.eql(u8, name, "scx=Cyrl") or
        std.mem.eql(u8, name, "Script=Cuneiform") or
        std.mem.eql(u8, name, "Script=Xsux") or
        std.mem.eql(u8, name, "sc=Cuneiform") or
        std.mem.eql(u8, name, "sc=Xsux") or
        std.mem.eql(u8, name, "Script=Cypro_Minoan") or
        std.mem.eql(u8, name, "Script=Cpmn") or
        std.mem.eql(u8, name, "sc=Cypro_Minoan") or
        std.mem.eql(u8, name, "sc=Cpmn") or
        std.mem.eql(u8, name, "Script_Extensions=Cypro_Minoan") or
        std.mem.eql(u8, name, "Script_Extensions=Cpmn") or
        std.mem.eql(u8, name, "scx=Cypro_Minoan") or
        std.mem.eql(u8, name, "scx=Cpmn") or
        std.mem.eql(u8, name, "Script=Cypriot") or
        std.mem.eql(u8, name, "Script=Cprt") or
        std.mem.eql(u8, name, "sc=Cypriot") or
        std.mem.eql(u8, name, "sc=Cprt") or
        std.mem.eql(u8, name, "Script_Extensions=Cypriot") or
        std.mem.eql(u8, name, "Script_Extensions=Cprt") or
        std.mem.eql(u8, name, "scx=Cypriot") or
        std.mem.eql(u8, name, "scx=Cprt") or
        std.mem.eql(u8, name, "Script=Devanagari") or
        std.mem.eql(u8, name, "Script=Deva") or
        std.mem.eql(u8, name, "sc=Devanagari") or
        std.mem.eql(u8, name, "sc=Deva") or
        std.mem.eql(u8, name, "Script_Extensions=Devanagari") or
        std.mem.eql(u8, name, "Script_Extensions=Deva") or
        std.mem.eql(u8, name, "scx=Devanagari") or
        std.mem.eql(u8, name, "scx=Deva") or
        std.mem.eql(u8, name, "Script=Deseret") or
        std.mem.eql(u8, name, "Script=Dsrt") or
        std.mem.eql(u8, name, "sc=Deseret") or
        std.mem.eql(u8, name, "sc=Dsrt") or
        std.mem.eql(u8, name, "Script=Dives_Akuru") or
        std.mem.eql(u8, name, "Script=Diak") or
        std.mem.eql(u8, name, "sc=Dives_Akuru") or
        std.mem.eql(u8, name, "sc=Diak") or
        std.mem.eql(u8, name, "Script_Extensions=Dives_Akuru") or
        std.mem.eql(u8, name, "Script_Extensions=Diak") or
        std.mem.eql(u8, name, "scx=Dives_Akuru") or
        std.mem.eql(u8, name, "scx=Diak") or
        std.mem.eql(u8, name, "Script=Duployan") or
        std.mem.eql(u8, name, "Script=Dupl") or
        std.mem.eql(u8, name, "sc=Duployan") or
        std.mem.eql(u8, name, "sc=Dupl") or
        std.mem.eql(u8, name, "Script_Extensions=Duployan") or
        std.mem.eql(u8, name, "Script_Extensions=Dupl") or
        std.mem.eql(u8, name, "scx=Duployan") or
        std.mem.eql(u8, name, "scx=Dupl") or
        std.mem.eql(u8, name, "Script=Dogra") or
        std.mem.eql(u8, name, "Script=Dogr") or
        std.mem.eql(u8, name, "sc=Dogra") or
        std.mem.eql(u8, name, "sc=Dogr") or
        std.mem.eql(u8, name, "Script_Extensions=Dogra") or
        std.mem.eql(u8, name, "Script_Extensions=Dogr") or
        std.mem.eql(u8, name, "scx=Dogra") or
        std.mem.eql(u8, name, "scx=Dogr") or
        std.mem.eql(u8, name, "Script=Elbasan") or
        std.mem.eql(u8, name, "Script=Elba") or
        std.mem.eql(u8, name, "sc=Elbasan") or
        std.mem.eql(u8, name, "sc=Elba") or
        std.mem.eql(u8, name, "Script_Extensions=Elbasan") or
        std.mem.eql(u8, name, "Script_Extensions=Elba") or
        std.mem.eql(u8, name, "scx=Elbasan") or
        std.mem.eql(u8, name, "scx=Elba") or
        std.mem.eql(u8, name, "Script=Elymaic") or
        std.mem.eql(u8, name, "Script=Elym") or
        std.mem.eql(u8, name, "sc=Elymaic") or
        std.mem.eql(u8, name, "sc=Elym") or
        std.mem.eql(u8, name, "Script=Egyptian_Hieroglyphs") or
        std.mem.eql(u8, name, "Script=Egyp") or
        std.mem.eql(u8, name, "sc=Egyptian_Hieroglyphs") or
        std.mem.eql(u8, name, "sc=Egyp") or
        std.mem.eql(u8, name, "Script=Ethiopic") or
        std.mem.eql(u8, name, "Script=Ethi") or
        std.mem.eql(u8, name, "sc=Ethiopic") or
        std.mem.eql(u8, name, "sc=Ethi") or
        std.mem.eql(u8, name, "Script_Extensions=Ethiopic") or
        std.mem.eql(u8, name, "Script_Extensions=Ethi") or
        std.mem.eql(u8, name, "scx=Ethiopic") or
        std.mem.eql(u8, name, "scx=Ethi") or
        std.mem.eql(u8, name, "Script=Garay") or
        std.mem.eql(u8, name, "Script=Gara") or
        std.mem.eql(u8, name, "sc=Garay") or
        std.mem.eql(u8, name, "sc=Gara") or
        std.mem.eql(u8, name, "Script_Extensions=Garay") or
        std.mem.eql(u8, name, "Script_Extensions=Gara") or
        std.mem.eql(u8, name, "scx=Garay") or
        std.mem.eql(u8, name, "scx=Gara") or
        std.mem.eql(u8, name, "Script=Georgian") or
        std.mem.eql(u8, name, "Script=Geor") or
        std.mem.eql(u8, name, "sc=Georgian") or
        std.mem.eql(u8, name, "sc=Geor") or
        std.mem.eql(u8, name, "Script_Extensions=Georgian") or
        std.mem.eql(u8, name, "Script_Extensions=Geor") or
        std.mem.eql(u8, name, "scx=Georgian") or
        std.mem.eql(u8, name, "scx=Geor") or
        std.mem.eql(u8, name, "Script=Glagolitic") or
        std.mem.eql(u8, name, "Script=Glag") or
        std.mem.eql(u8, name, "sc=Glagolitic") or
        std.mem.eql(u8, name, "sc=Glag") or
        std.mem.eql(u8, name, "Script_Extensions=Glagolitic") or
        std.mem.eql(u8, name, "Script_Extensions=Glag") or
        std.mem.eql(u8, name, "scx=Glagolitic") or
        std.mem.eql(u8, name, "scx=Glag") or
        std.mem.eql(u8, name, "Script=Gothic") or
        std.mem.eql(u8, name, "Script=Goth") or
        std.mem.eql(u8, name, "sc=Gothic") or
        std.mem.eql(u8, name, "sc=Goth") or
        std.mem.eql(u8, name, "Script_Extensions=Gothic") or
        std.mem.eql(u8, name, "Script_Extensions=Goth") or
        std.mem.eql(u8, name, "scx=Gothic") or
        std.mem.eql(u8, name, "scx=Goth") or
        std.mem.eql(u8, name, "Script=Greek") or
        std.mem.eql(u8, name, "Script=Grek") or
        std.mem.eql(u8, name, "sc=Greek") or
        std.mem.eql(u8, name, "sc=Grek") or
        std.mem.eql(u8, name, "Script_Extensions=Greek") or
        std.mem.eql(u8, name, "Script_Extensions=Grek") or
        std.mem.eql(u8, name, "scx=Greek") or
        std.mem.eql(u8, name, "scx=Grek") or
        std.mem.eql(u8, name, "Script=Grantha") or
        std.mem.eql(u8, name, "Script=Gran") or
        std.mem.eql(u8, name, "sc=Grantha") or
        std.mem.eql(u8, name, "sc=Gran") or
        std.mem.eql(u8, name, "Script_Extensions=Grantha") or
        std.mem.eql(u8, name, "Script_Extensions=Gran") or
        std.mem.eql(u8, name, "scx=Grantha") or
        std.mem.eql(u8, name, "scx=Gran") or
        std.mem.eql(u8, name, "Script=Gunjala_Gondi") or
        std.mem.eql(u8, name, "Script=Gong") or
        std.mem.eql(u8, name, "sc=Gunjala_Gondi") or
        std.mem.eql(u8, name, "sc=Gong") or
        std.mem.eql(u8, name, "Script_Extensions=Gunjala_Gondi") or
        std.mem.eql(u8, name, "Script_Extensions=Gong") or
        std.mem.eql(u8, name, "scx=Gunjala_Gondi") or
        std.mem.eql(u8, name, "scx=Gong") or
        std.mem.eql(u8, name, "Script=Gurung_Khema") or
        std.mem.eql(u8, name, "Script=Gukh") or
        std.mem.eql(u8, name, "sc=Gurung_Khema") or
        std.mem.eql(u8, name, "sc=Gukh") or
        std.mem.eql(u8, name, "Script_Extensions=Gurung_Khema") or
        std.mem.eql(u8, name, "Script_Extensions=Gukh") or
        std.mem.eql(u8, name, "scx=Gurung_Khema") or
        std.mem.eql(u8, name, "scx=Gukh") or
        std.mem.eql(u8, name, "Script=Gurmukhi") or
        std.mem.eql(u8, name, "Script=Guru") or
        std.mem.eql(u8, name, "sc=Gurmukhi") or
        std.mem.eql(u8, name, "sc=Guru") or
        std.mem.eql(u8, name, "Script_Extensions=Gurmukhi") or
        std.mem.eql(u8, name, "Script_Extensions=Guru") or
        std.mem.eql(u8, name, "scx=Gurmukhi") or
        std.mem.eql(u8, name, "scx=Guru") or
        std.mem.eql(u8, name, "Script=Gujarati") or
        std.mem.eql(u8, name, "Script=Gujr") or
        std.mem.eql(u8, name, "sc=Gujarati") or
        std.mem.eql(u8, name, "sc=Gujr") or
        std.mem.eql(u8, name, "Script_Extensions=Gujarati") or
        std.mem.eql(u8, name, "Script_Extensions=Gujr") or
        std.mem.eql(u8, name, "scx=Gujarati") or
        std.mem.eql(u8, name, "scx=Gujr") or
        std.mem.eql(u8, name, "Script=Han") or
        std.mem.eql(u8, name, "Script=Hani") or
        std.mem.eql(u8, name, "sc=Han") or
        std.mem.eql(u8, name, "sc=Hani") or
        std.mem.eql(u8, name, "Script_Extensions=Han") or
        std.mem.eql(u8, name, "Script_Extensions=Hani") or
        std.mem.eql(u8, name, "scx=Han") or
        std.mem.eql(u8, name, "scx=Hani") or
        std.mem.eql(u8, name, "Script=Hangul") or
        std.mem.eql(u8, name, "Script=Hang") or
        std.mem.eql(u8, name, "sc=Hangul") or
        std.mem.eql(u8, name, "sc=Hang") or
        std.mem.eql(u8, name, "Script_Extensions=Hangul") or
        std.mem.eql(u8, name, "Script_Extensions=Hang") or
        std.mem.eql(u8, name, "scx=Hangul") or
        std.mem.eql(u8, name, "scx=Hang") or
        std.mem.eql(u8, name, "Script=Hanunoo") or
        std.mem.eql(u8, name, "Script=Hano") or
        std.mem.eql(u8, name, "sc=Hanunoo") or
        std.mem.eql(u8, name, "sc=Hano") or
        std.mem.eql(u8, name, "Script_Extensions=Hanunoo") or
        std.mem.eql(u8, name, "Script_Extensions=Hano") or
        std.mem.eql(u8, name, "scx=Hanunoo") or
        std.mem.eql(u8, name, "scx=Hano") or
        std.mem.eql(u8, name, "Script=Hatran") or
        std.mem.eql(u8, name, "Script=Hatr") or
        std.mem.eql(u8, name, "sc=Hatran") or
        std.mem.eql(u8, name, "sc=Hatr") or
        std.mem.eql(u8, name, "Script=Hanifi_Rohingya") or
        std.mem.eql(u8, name, "Script=Rohg") or
        std.mem.eql(u8, name, "sc=Hanifi_Rohingya") or
        std.mem.eql(u8, name, "sc=Rohg") or
        std.mem.eql(u8, name, "Script_Extensions=Hanifi_Rohingya") or
        std.mem.eql(u8, name, "Script_Extensions=Rohg") or
        std.mem.eql(u8, name, "scx=Hanifi_Rohingya") or
        std.mem.eql(u8, name, "scx=Rohg") or
        std.mem.eql(u8, name, "Script=Hebrew") or
        std.mem.eql(u8, name, "Script=Hebr") or
        std.mem.eql(u8, name, "sc=Hebrew") or
        std.mem.eql(u8, name, "sc=Hebr") or
        std.mem.eql(u8, name, "Script_Extensions=Hebrew") or
        std.mem.eql(u8, name, "Script_Extensions=Hebr") or
        std.mem.eql(u8, name, "scx=Hebrew") or
        std.mem.eql(u8, name, "scx=Hebr") or
        std.mem.eql(u8, name, "Script=Hiragana") or
        std.mem.eql(u8, name, "Script=Hira") or
        std.mem.eql(u8, name, "sc=Hiragana") or
        std.mem.eql(u8, name, "sc=Hira") or
        std.mem.eql(u8, name, "Script_Extensions=Hiragana") or
        std.mem.eql(u8, name, "Script_Extensions=Hira") or
        std.mem.eql(u8, name, "scx=Hiragana") or
        std.mem.eql(u8, name, "scx=Hira") or
        std.mem.eql(u8, name, "Script=Inherited") or
        std.mem.eql(u8, name, "Script=Zinh") or
        std.mem.eql(u8, name, "Script=Qaai") or
        std.mem.eql(u8, name, "sc=Inherited") or
        std.mem.eql(u8, name, "sc=Zinh") or
        std.mem.eql(u8, name, "sc=Qaai") or
        std.mem.eql(u8, name, "Script_Extensions=Inherited") or
        std.mem.eql(u8, name, "Script_Extensions=Zinh") or
        std.mem.eql(u8, name, "Script_Extensions=Qaai") or
        std.mem.eql(u8, name, "scx=Inherited") or
        std.mem.eql(u8, name, "scx=Zinh") or
        std.mem.eql(u8, name, "scx=Qaai") or
        std.mem.eql(u8, name, "Script=Inscriptional_Pahlavi") or
        std.mem.eql(u8, name, "Script=Phli") or
        std.mem.eql(u8, name, "sc=Inscriptional_Pahlavi") or
        std.mem.eql(u8, name, "sc=Phli") or
        std.mem.eql(u8, name, "Script=Inscriptional_Parthian") or
        std.mem.eql(u8, name, "Script=Prti") or
        std.mem.eql(u8, name, "sc=Inscriptional_Parthian") or
        std.mem.eql(u8, name, "sc=Prti") or
        std.mem.eql(u8, name, "Script=Imperial_Aramaic") or
        std.mem.eql(u8, name, "Script=Armi") or
        std.mem.eql(u8, name, "sc=Imperial_Aramaic") or
        std.mem.eql(u8, name, "sc=Armi") or
        std.mem.eql(u8, name, "Script_Extensions=Imperial_Aramaic") or
        std.mem.eql(u8, name, "Script_Extensions=Armi") or
        std.mem.eql(u8, name, "scx=Imperial_Aramaic") or
        std.mem.eql(u8, name, "scx=Armi") or
        std.mem.eql(u8, name, "Script=Javanese") or
        std.mem.eql(u8, name, "Script=Java") or
        std.mem.eql(u8, name, "sc=Javanese") or
        std.mem.eql(u8, name, "sc=Java") or
        std.mem.eql(u8, name, "Script_Extensions=Javanese") or
        std.mem.eql(u8, name, "Script_Extensions=Java") or
        std.mem.eql(u8, name, "scx=Javanese") or
        std.mem.eql(u8, name, "scx=Java") or
        std.mem.eql(u8, name, "Script=Kaithi") or
        std.mem.eql(u8, name, "Script=Kthi") or
        std.mem.eql(u8, name, "sc=Kaithi") or
        std.mem.eql(u8, name, "sc=Kthi") or
        std.mem.eql(u8, name, "Script_Extensions=Kaithi") or
        std.mem.eql(u8, name, "Script_Extensions=Kthi") or
        std.mem.eql(u8, name, "scx=Kaithi") or
        std.mem.eql(u8, name, "scx=Kthi") or
        std.mem.eql(u8, name, "Script=Kayah_Li") or
        std.mem.eql(u8, name, "Script=Kali") or
        std.mem.eql(u8, name, "sc=Kayah_Li") or
        std.mem.eql(u8, name, "sc=Kali") or
        std.mem.eql(u8, name, "Script_Extensions=Kayah_Li") or
        std.mem.eql(u8, name, "Script_Extensions=Kali") or
        std.mem.eql(u8, name, "scx=Kayah_Li") or
        std.mem.eql(u8, name, "scx=Kali") or
        std.mem.eql(u8, name, "Script=Kannada") or
        std.mem.eql(u8, name, "Script=Knda") or
        std.mem.eql(u8, name, "sc=Kannada") or
        std.mem.eql(u8, name, "sc=Knda") or
        std.mem.eql(u8, name, "Script_Extensions=Kannada") or
        std.mem.eql(u8, name, "Script_Extensions=Knda") or
        std.mem.eql(u8, name, "scx=Kannada") or
        std.mem.eql(u8, name, "scx=Knda") or
        std.mem.eql(u8, name, "Script=Katakana") or
        std.mem.eql(u8, name, "Script=Kana") or
        std.mem.eql(u8, name, "sc=Katakana") or
        std.mem.eql(u8, name, "sc=Kana") or
        std.mem.eql(u8, name, "Script_Extensions=Katakana") or
        std.mem.eql(u8, name, "Script_Extensions=Kana") or
        std.mem.eql(u8, name, "scx=Katakana") or
        std.mem.eql(u8, name, "scx=Kana") or
        std.mem.eql(u8, name, "Script=Kawi") or
        std.mem.eql(u8, name, "sc=Kawi") or
        std.mem.eql(u8, name, "Script_Extensions=Kawi") or
        std.mem.eql(u8, name, "scx=Kawi") or
        std.mem.eql(u8, name, "Script=Kharoshthi") or
        std.mem.eql(u8, name, "Script=Khar") or
        std.mem.eql(u8, name, "sc=Kharoshthi") or
        std.mem.eql(u8, name, "sc=Khar") or
        std.mem.eql(u8, name, "Script=Khitan_Small_Script") or
        std.mem.eql(u8, name, "Script=Kits") or
        std.mem.eql(u8, name, "sc=Khitan_Small_Script") or
        std.mem.eql(u8, name, "sc=Kits") or
        std.mem.eql(u8, name, "Script=Khojki") or
        std.mem.eql(u8, name, "Script=Khoj") or
        std.mem.eql(u8, name, "sc=Khojki") or
        std.mem.eql(u8, name, "sc=Khoj") or
        std.mem.eql(u8, name, "Script_Extensions=Khojki") or
        std.mem.eql(u8, name, "Script_Extensions=Khoj") or
        std.mem.eql(u8, name, "scx=Khojki") or
        std.mem.eql(u8, name, "scx=Khoj") or
        std.mem.eql(u8, name, "Script=Khmer") or
        std.mem.eql(u8, name, "Script=Khmr") or
        std.mem.eql(u8, name, "sc=Khmer") or
        std.mem.eql(u8, name, "sc=Khmr") or
        std.mem.eql(u8, name, "Script=Kirat_Rai") or
        std.mem.eql(u8, name, "Script=Krai") or
        std.mem.eql(u8, name, "sc=Kirat_Rai") or
        std.mem.eql(u8, name, "sc=Krai") or
        std.mem.eql(u8, name, "Script=Khudawadi") or
        std.mem.eql(u8, name, "Script=Sind") or
        std.mem.eql(u8, name, "sc=Khudawadi") or
        std.mem.eql(u8, name, "sc=Sind") or
        std.mem.eql(u8, name, "Script_Extensions=Khudawadi") or
        std.mem.eql(u8, name, "Script_Extensions=Sind") or
        std.mem.eql(u8, name, "scx=Khudawadi") or
        std.mem.eql(u8, name, "scx=Sind") or
        std.mem.eql(u8, name, "Script=Lao") or
        std.mem.eql(u8, name, "Script=Laoo") or
        std.mem.eql(u8, name, "sc=Lao") or
        std.mem.eql(u8, name, "sc=Laoo") or
        std.mem.eql(u8, name, "Script_Extensions=Lao") or
        std.mem.eql(u8, name, "Script_Extensions=Laoo") or
        std.mem.eql(u8, name, "scx=Lao") or
        std.mem.eql(u8, name, "scx=Laoo") or
        std.mem.eql(u8, name, "Script=Lepcha") or
        std.mem.eql(u8, name, "Script=Lepc") or
        std.mem.eql(u8, name, "sc=Lepcha") or
        std.mem.eql(u8, name, "sc=Lepc") or
        std.mem.eql(u8, name, "Script=Limbu") or
        std.mem.eql(u8, name, "Script=Limb") or
        std.mem.eql(u8, name, "sc=Limbu") or
        std.mem.eql(u8, name, "sc=Limb") or
        std.mem.eql(u8, name, "Script_Extensions=Limbu") or
        std.mem.eql(u8, name, "Script_Extensions=Limb") or
        std.mem.eql(u8, name, "scx=Limbu") or
        std.mem.eql(u8, name, "scx=Limb") or
        std.mem.eql(u8, name, "Script=Linear_A") or
        std.mem.eql(u8, name, "Script=Lina") or
        std.mem.eql(u8, name, "sc=Linear_A") or
        std.mem.eql(u8, name, "sc=Lina") or
        std.mem.eql(u8, name, "Script=Linear_B") or
        std.mem.eql(u8, name, "Script=Linb") or
        std.mem.eql(u8, name, "sc=Linear_B") or
        std.mem.eql(u8, name, "sc=Linb") or
        std.mem.eql(u8, name, "Script=Lycian") or
        std.mem.eql(u8, name, "Script=Lyci") or
        std.mem.eql(u8, name, "sc=Lycian") or
        std.mem.eql(u8, name, "sc=Lyci") or
        std.mem.eql(u8, name, "Script_Extensions=Lycian") or
        std.mem.eql(u8, name, "Script_Extensions=Lyci") or
        std.mem.eql(u8, name, "scx=Lycian") or
        std.mem.eql(u8, name, "scx=Lyci") or
        std.mem.eql(u8, name, "Script=Lydian") or
        std.mem.eql(u8, name, "Script=Lydi") or
        std.mem.eql(u8, name, "sc=Lydian") or
        std.mem.eql(u8, name, "sc=Lydi") or
        std.mem.eql(u8, name, "Script=Latin") or
        std.mem.eql(u8, name, "Script=Latn") or
        std.mem.eql(u8, name, "sc=Latin") or
        std.mem.eql(u8, name, "sc=Latn") or
        std.mem.eql(u8, name, "Script_Extensions=Latin") or
        std.mem.eql(u8, name, "Script_Extensions=Latn") or
        std.mem.eql(u8, name, "scx=Latin") or
        std.mem.eql(u8, name, "scx=Latn") or
        std.mem.eql(u8, name, "Script=Lisu") or
        std.mem.eql(u8, name, "sc=Lisu") or
        std.mem.eql(u8, name, "Script=Mahajani") or
        std.mem.eql(u8, name, "Script=Mahj") or
        std.mem.eql(u8, name, "sc=Mahajani") or
        std.mem.eql(u8, name, "sc=Mahj") or
        std.mem.eql(u8, name, "Script=Makasar") or
        std.mem.eql(u8, name, "Script=Maka") or
        std.mem.eql(u8, name, "sc=Makasar") or
        std.mem.eql(u8, name, "sc=Maka") or
        std.mem.eql(u8, name, "Script=Malayalam") or
        std.mem.eql(u8, name, "Script=Mlym") or
        std.mem.eql(u8, name, "sc=Malayalam") or
        std.mem.eql(u8, name, "sc=Mlym") or
        std.mem.eql(u8, name, "Script_Extensions=Malayalam") or
        std.mem.eql(u8, name, "Script_Extensions=Mlym") or
        std.mem.eql(u8, name, "scx=Malayalam") or
        std.mem.eql(u8, name, "scx=Mlym") or
        std.mem.eql(u8, name, "Script=Masaram_Gondi") or
        std.mem.eql(u8, name, "Script=Gonm") or
        std.mem.eql(u8, name, "sc=Masaram_Gondi") or
        std.mem.eql(u8, name, "sc=Gonm") or
        std.mem.eql(u8, name, "Script=Mandaic") or
        std.mem.eql(u8, name, "Script=Mand") or
        std.mem.eql(u8, name, "sc=Mandaic") or
        std.mem.eql(u8, name, "sc=Mand") or
        std.mem.eql(u8, name, "Script_Extensions=Mandaic") or
        std.mem.eql(u8, name, "Script_Extensions=Mand") or
        std.mem.eql(u8, name, "scx=Mandaic") or
        std.mem.eql(u8, name, "scx=Mand") or
        std.mem.eql(u8, name, "Script=Manichaean") or
        std.mem.eql(u8, name, "Script=Mani") or
        std.mem.eql(u8, name, "sc=Manichaean") or
        std.mem.eql(u8, name, "sc=Mani") or
        std.mem.eql(u8, name, "Script=Marchen") or
        std.mem.eql(u8, name, "Script=Marc") or
        std.mem.eql(u8, name, "sc=Marchen") or
        std.mem.eql(u8, name, "sc=Marc") or
        std.mem.eql(u8, name, "Script=Medefaidrin") or
        std.mem.eql(u8, name, "Script=Medf") or
        std.mem.eql(u8, name, "sc=Medefaidrin") or
        std.mem.eql(u8, name, "sc=Medf") or
        std.mem.eql(u8, name, "Script=Meetei_Mayek") or
        std.mem.eql(u8, name, "Script=Mtei") or
        std.mem.eql(u8, name, "sc=Meetei_Mayek") or
        std.mem.eql(u8, name, "sc=Mtei") or
        std.mem.eql(u8, name, "Script=Mende_Kikakui") or
        std.mem.eql(u8, name, "Script=Mend") or
        std.mem.eql(u8, name, "sc=Mende_Kikakui") or
        std.mem.eql(u8, name, "sc=Mend") or
        std.mem.eql(u8, name, "Script=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "Script=Mero") or
        std.mem.eql(u8, name, "sc=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "sc=Mero") or
        std.mem.eql(u8, name, "Script_Extensions=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "Script_Extensions=Mero") or
        std.mem.eql(u8, name, "scx=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "scx=Mero") or
        std.mem.eql(u8, name, "Script=Meroitic_Cursive") or
        std.mem.eql(u8, name, "Script=Merc") or
        std.mem.eql(u8, name, "sc=Meroitic_Cursive") or
        std.mem.eql(u8, name, "sc=Merc") or
        std.mem.eql(u8, name, "Script=Miao") or
        std.mem.eql(u8, name, "Script=Plrd") or
        std.mem.eql(u8, name, "sc=Miao") or
        std.mem.eql(u8, name, "sc=Plrd") or
        std.mem.eql(u8, name, "Script=Modi") or
        std.mem.eql(u8, name, "sc=Modi") or
        std.mem.eql(u8, name, "Script_Extensions=Modi") or
        std.mem.eql(u8, name, "scx=Modi") or
        std.mem.eql(u8, name, "Script=Mongolian") or
        std.mem.eql(u8, name, "Script=Mong") or
        std.mem.eql(u8, name, "sc=Mongolian") or
        std.mem.eql(u8, name, "sc=Mong") or
        std.mem.eql(u8, name, "Script_Extensions=Mongolian") or
        std.mem.eql(u8, name, "Script_Extensions=Mong") or
        std.mem.eql(u8, name, "scx=Mongolian") or
        std.mem.eql(u8, name, "scx=Mong") or
        std.mem.eql(u8, name, "Script=Multani") or
        std.mem.eql(u8, name, "Script=Mult") or
        std.mem.eql(u8, name, "sc=Multani") or
        std.mem.eql(u8, name, "sc=Mult") or
        std.mem.eql(u8, name, "Script=Myanmar") or
        std.mem.eql(u8, name, "Script=Mymr") or
        std.mem.eql(u8, name, "sc=Myanmar") or
        std.mem.eql(u8, name, "sc=Mymr") or
        std.mem.eql(u8, name, "Script_Extensions=Myanmar") or
        std.mem.eql(u8, name, "Script_Extensions=Mymr") or
        std.mem.eql(u8, name, "scx=Myanmar") or
        std.mem.eql(u8, name, "scx=Mymr") or
        std.mem.eql(u8, name, "Script=Mro") or
        std.mem.eql(u8, name, "Script=Mroo") or
        std.mem.eql(u8, name, "sc=Mro") or
        std.mem.eql(u8, name, "sc=Mroo") or
        std.mem.eql(u8, name, "Script=Nag_Mundari") or
        std.mem.eql(u8, name, "Script=Nagm") or
        std.mem.eql(u8, name, "sc=Nag_Mundari") or
        std.mem.eql(u8, name, "sc=Nagm") or
        std.mem.eql(u8, name, "Script_Extensions=Nag_Mundari") or
        std.mem.eql(u8, name, "Script_Extensions=Nagm") or
        std.mem.eql(u8, name, "scx=Nag_Mundari") or
        std.mem.eql(u8, name, "scx=Nagm") or
        std.mem.eql(u8, name, "Script=Nabataean") or
        std.mem.eql(u8, name, "Script=Nbat") or
        std.mem.eql(u8, name, "sc=Nabataean") or
        std.mem.eql(u8, name, "sc=Nbat") or
        std.mem.eql(u8, name, "Script=Nandinagari") or
        std.mem.eql(u8, name, "Script=Nand") or
        std.mem.eql(u8, name, "sc=Nandinagari") or
        std.mem.eql(u8, name, "sc=Nand") or
        std.mem.eql(u8, name, "Script_Extensions=Nandinagari") or
        std.mem.eql(u8, name, "Script_Extensions=Nand") or
        std.mem.eql(u8, name, "scx=Nandinagari") or
        std.mem.eql(u8, name, "scx=Nand") or
        std.mem.eql(u8, name, "Script=Newa") or
        std.mem.eql(u8, name, "sc=Newa") or
        std.mem.eql(u8, name, "Script_Extensions=Newa") or
        std.mem.eql(u8, name, "scx=Newa") or
        std.mem.eql(u8, name, "Script=New_Tai_Lue") or
        std.mem.eql(u8, name, "Script=Talu") or
        std.mem.eql(u8, name, "sc=New_Tai_Lue") or
        std.mem.eql(u8, name, "sc=Talu") or
        std.mem.eql(u8, name, "Script_Extensions=New_Tai_Lue") or
        std.mem.eql(u8, name, "Script_Extensions=Talu") or
        std.mem.eql(u8, name, "scx=New_Tai_Lue") or
        std.mem.eql(u8, name, "scx=Talu") or
        std.mem.eql(u8, name, "Script=Nko") or
        std.mem.eql(u8, name, "Script=Nkoo") or
        std.mem.eql(u8, name, "sc=Nko") or
        std.mem.eql(u8, name, "sc=Nkoo") or
        std.mem.eql(u8, name, "Script_Extensions=Nko") or
        std.mem.eql(u8, name, "Script_Extensions=Nkoo") or
        std.mem.eql(u8, name, "scx=Nko") or
        std.mem.eql(u8, name, "scx=Nkoo") or
        std.mem.eql(u8, name, "Script=Nushu") or
        std.mem.eql(u8, name, "Script=Nshu") or
        std.mem.eql(u8, name, "sc=Nushu") or
        std.mem.eql(u8, name, "sc=Nshu") or
        std.mem.eql(u8, name, "Script=Nyiakeng_Puachue_Hmong") or
        std.mem.eql(u8, name, "Script=Hmnp") or
        std.mem.eql(u8, name, "sc=Nyiakeng_Puachue_Hmong") or
        std.mem.eql(u8, name, "sc=Hmnp") or
        std.mem.eql(u8, name, "Script=Ogham") or
        std.mem.eql(u8, name, "Script=Ogam") or
        std.mem.eql(u8, name, "sc=Ogham") or
        std.mem.eql(u8, name, "sc=Ogam") or
        std.mem.eql(u8, name, "Script=Ol_Chiki") or
        std.mem.eql(u8, name, "Script=Olck") or
        std.mem.eql(u8, name, "sc=Ol_Chiki") or
        std.mem.eql(u8, name, "sc=Olck") or
        std.mem.eql(u8, name, "Script=Ol_Onal") or
        std.mem.eql(u8, name, "Script=Onao") or
        std.mem.eql(u8, name, "sc=Ol_Onal") or
        std.mem.eql(u8, name, "sc=Onao") or
        std.mem.eql(u8, name, "Script_Extensions=Ol_Onal") or
        std.mem.eql(u8, name, "Script_Extensions=Onao") or
        std.mem.eql(u8, name, "scx=Ol_Onal") or
        std.mem.eql(u8, name, "scx=Onao") or
        std.mem.eql(u8, name, "Script=Old_Italic") or
        std.mem.eql(u8, name, "Script=Ital") or
        std.mem.eql(u8, name, "sc=Old_Italic") or
        std.mem.eql(u8, name, "sc=Ital") or
        std.mem.eql(u8, name, "Script=Old_North_Arabian") or
        std.mem.eql(u8, name, "Script=Narb") or
        std.mem.eql(u8, name, "sc=Old_North_Arabian") or
        std.mem.eql(u8, name, "sc=Narb") or
        std.mem.eql(u8, name, "Script=Old_Sogdian") or
        std.mem.eql(u8, name, "Script=Sogo") or
        std.mem.eql(u8, name, "sc=Old_Sogdian") or
        std.mem.eql(u8, name, "sc=Sogo") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Sogdian") or
        std.mem.eql(u8, name, "Script_Extensions=Sogo") or
        std.mem.eql(u8, name, "scx=Old_Sogdian") or
        std.mem.eql(u8, name, "scx=Sogo") or
        std.mem.eql(u8, name, "Script=Old_South_Arabian") or
        std.mem.eql(u8, name, "Script=Sarb") or
        std.mem.eql(u8, name, "sc=Old_South_Arabian") or
        std.mem.eql(u8, name, "sc=Sarb") or
        std.mem.eql(u8, name, "Script=Old_Hungarian") or
        std.mem.eql(u8, name, "Script=Hung") or
        std.mem.eql(u8, name, "sc=Old_Hungarian") or
        std.mem.eql(u8, name, "sc=Hung") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Hungarian") or
        std.mem.eql(u8, name, "Script_Extensions=Hung") or
        std.mem.eql(u8, name, "scx=Old_Hungarian") or
        std.mem.eql(u8, name, "scx=Hung") or
        std.mem.eql(u8, name, "Script=Old_Permic") or
        std.mem.eql(u8, name, "Script=Perm") or
        std.mem.eql(u8, name, "sc=Old_Permic") or
        std.mem.eql(u8, name, "sc=Perm") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Permic") or
        std.mem.eql(u8, name, "Script_Extensions=Perm") or
        std.mem.eql(u8, name, "scx=Old_Permic") or
        std.mem.eql(u8, name, "scx=Perm") or
        std.mem.eql(u8, name, "Script=Old_Uyghur") or
        std.mem.eql(u8, name, "Script=Ougr") or
        std.mem.eql(u8, name, "sc=Old_Uyghur") or
        std.mem.eql(u8, name, "sc=Ougr") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Uyghur") or
        std.mem.eql(u8, name, "Script_Extensions=Ougr") or
        std.mem.eql(u8, name, "scx=Old_Uyghur") or
        std.mem.eql(u8, name, "scx=Ougr") or
        std.mem.eql(u8, name, "Script=Old_Turkic") or
        std.mem.eql(u8, name, "Script=Orkh") or
        std.mem.eql(u8, name, "sc=Old_Turkic") or
        std.mem.eql(u8, name, "sc=Orkh") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Turkic") or
        std.mem.eql(u8, name, "Script_Extensions=Orkh") or
        std.mem.eql(u8, name, "scx=Old_Turkic") or
        std.mem.eql(u8, name, "scx=Orkh") or
        std.mem.eql(u8, name, "Script=Old_Persian") or
        std.mem.eql(u8, name, "Script=Xpeo") or
        std.mem.eql(u8, name, "sc=Old_Persian") or
        std.mem.eql(u8, name, "sc=Xpeo") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Persian") or
        std.mem.eql(u8, name, "Script_Extensions=Xpeo") or
        std.mem.eql(u8, name, "scx=Old_Persian") or
        std.mem.eql(u8, name, "scx=Xpeo") or
        std.mem.eql(u8, name, "Script=Osmanya") or
        std.mem.eql(u8, name, "Script=Osma") or
        std.mem.eql(u8, name, "sc=Osmanya") or
        std.mem.eql(u8, name, "sc=Osma") or
        std.mem.eql(u8, name, "Script_Extensions=Osmanya") or
        std.mem.eql(u8, name, "Script_Extensions=Osma") or
        std.mem.eql(u8, name, "scx=Osmanya") or
        std.mem.eql(u8, name, "scx=Osma") or
        std.mem.eql(u8, name, "Script=Oriya") or
        std.mem.eql(u8, name, "Script=Orya") or
        std.mem.eql(u8, name, "sc=Oriya") or
        std.mem.eql(u8, name, "sc=Orya") or
        std.mem.eql(u8, name, "Script_Extensions=Oriya") or
        std.mem.eql(u8, name, "Script_Extensions=Orya") or
        std.mem.eql(u8, name, "scx=Oriya") or
        std.mem.eql(u8, name, "scx=Orya") or
        std.mem.eql(u8, name, "Script=Osage") or
        std.mem.eql(u8, name, "Script=Osge") or
        std.mem.eql(u8, name, "sc=Osage") or
        std.mem.eql(u8, name, "sc=Osge") or
        std.mem.eql(u8, name, "Script_Extensions=Osage") or
        std.mem.eql(u8, name, "Script_Extensions=Osge") or
        std.mem.eql(u8, name, "scx=Osage") or
        std.mem.eql(u8, name, "scx=Osge") or
        std.mem.eql(u8, name, "Script=Palmyrene") or
        std.mem.eql(u8, name, "Script=Palm") or
        std.mem.eql(u8, name, "sc=Palmyrene") or
        std.mem.eql(u8, name, "sc=Palm") or
        std.mem.eql(u8, name, "Script=Pahawh_Hmong") or
        std.mem.eql(u8, name, "Script=Hmng") or
        std.mem.eql(u8, name, "sc=Pahawh_Hmong") or
        std.mem.eql(u8, name, "sc=Hmng") or
        std.mem.eql(u8, name, "Script_Extensions=Pahawh_Hmong") or
        std.mem.eql(u8, name, "Script_Extensions=Hmng") or
        std.mem.eql(u8, name, "scx=Pahawh_Hmong") or
        std.mem.eql(u8, name, "scx=Hmng") or
        std.mem.eql(u8, name, "Script=Pau_Cin_Hau") or
        std.mem.eql(u8, name, "Script=Pauc") or
        std.mem.eql(u8, name, "sc=Pau_Cin_Hau") or
        std.mem.eql(u8, name, "sc=Pauc") or
        std.mem.eql(u8, name, "Script_Extensions=Pau_Cin_Hau") or
        std.mem.eql(u8, name, "Script_Extensions=Pauc") or
        std.mem.eql(u8, name, "scx=Pau_Cin_Hau") or
        std.mem.eql(u8, name, "scx=Pauc") or
        std.mem.eql(u8, name, "Script=Phags_Pa") or
        std.mem.eql(u8, name, "Script=Phag") or
        std.mem.eql(u8, name, "sc=Phags_Pa") or
        std.mem.eql(u8, name, "sc=Phag") or
        std.mem.eql(u8, name, "Script_Extensions=Phags_Pa") or
        std.mem.eql(u8, name, "Script_Extensions=Phag") or
        std.mem.eql(u8, name, "scx=Phags_Pa") or
        std.mem.eql(u8, name, "scx=Phag") or
        std.mem.eql(u8, name, "Script=Phoenician") or
        std.mem.eql(u8, name, "Script=Phnx") or
        std.mem.eql(u8, name, "sc=Phoenician") or
        std.mem.eql(u8, name, "sc=Phnx") or
        std.mem.eql(u8, name, "Script_Extensions=Phoenician") or
        std.mem.eql(u8, name, "Script_Extensions=Phnx") or
        std.mem.eql(u8, name, "scx=Phoenician") or
        std.mem.eql(u8, name, "scx=Phnx") or
        std.mem.eql(u8, name, "Script=Psalter_Pahlavi") or
        std.mem.eql(u8, name, "Script=Phlp") or
        std.mem.eql(u8, name, "sc=Psalter_Pahlavi") or
        std.mem.eql(u8, name, "sc=Phlp") or
        std.mem.eql(u8, name, "Script_Extensions=Psalter_Pahlavi") or
        std.mem.eql(u8, name, "Script_Extensions=Phlp") or
        std.mem.eql(u8, name, "scx=Psalter_Pahlavi") or
        std.mem.eql(u8, name, "scx=Phlp") or
        std.mem.eql(u8, name, "Script=Rejang") or
        std.mem.eql(u8, name, "Script=Rjng") or
        std.mem.eql(u8, name, "sc=Rejang") or
        std.mem.eql(u8, name, "sc=Rjng") or
        std.mem.eql(u8, name, "Script_Extensions=Rejang") or
        std.mem.eql(u8, name, "Script_Extensions=Rjng") or
        std.mem.eql(u8, name, "scx=Rejang") or
        std.mem.eql(u8, name, "scx=Rjng") or
        std.mem.eql(u8, name, "Script=Runic") or
        std.mem.eql(u8, name, "Script=Runr") or
        std.mem.eql(u8, name, "sc=Runic") or
        std.mem.eql(u8, name, "sc=Runr") or
        std.mem.eql(u8, name, "Script_Extensions=Runic") or
        std.mem.eql(u8, name, "Script_Extensions=Runr") or
        std.mem.eql(u8, name, "scx=Runic") or
        std.mem.eql(u8, name, "scx=Runr") or
        std.mem.eql(u8, name, "Script=Saurashtra") or
        std.mem.eql(u8, name, "Script=Saur") or
        std.mem.eql(u8, name, "sc=Saurashtra") or
        std.mem.eql(u8, name, "sc=Saur") or
        std.mem.eql(u8, name, "Script_Extensions=Saurashtra") or
        std.mem.eql(u8, name, "Script_Extensions=Saur") or
        std.mem.eql(u8, name, "scx=Saurashtra") or
        std.mem.eql(u8, name, "scx=Saur") or
        std.mem.eql(u8, name, "Script=Shavian") or
        std.mem.eql(u8, name, "Script=Shaw") or
        std.mem.eql(u8, name, "sc=Shavian") or
        std.mem.eql(u8, name, "sc=Shaw") or
        std.mem.eql(u8, name, "Script_Extensions=Shavian") or
        std.mem.eql(u8, name, "Script_Extensions=Shaw") or
        std.mem.eql(u8, name, "scx=Shavian") or
        std.mem.eql(u8, name, "scx=Shaw") or
        std.mem.eql(u8, name, "Script=Sharada") or
        std.mem.eql(u8, name, "Script=Shrd") or
        std.mem.eql(u8, name, "sc=Sharada") or
        std.mem.eql(u8, name, "sc=Shrd") or
        std.mem.eql(u8, name, "Script_Extensions=Sharada") or
        std.mem.eql(u8, name, "Script_Extensions=Shrd") or
        std.mem.eql(u8, name, "scx=Sharada") or
        std.mem.eql(u8, name, "scx=Shrd") or
        std.mem.eql(u8, name, "Script=Samaritan") or
        std.mem.eql(u8, name, "Script=Samr") or
        std.mem.eql(u8, name, "sc=Samaritan") or
        std.mem.eql(u8, name, "sc=Samr") or
        std.mem.eql(u8, name, "Script_Extensions=Samaritan") or
        std.mem.eql(u8, name, "Script_Extensions=Samr") or
        std.mem.eql(u8, name, "scx=Samaritan") or
        std.mem.eql(u8, name, "scx=Samr") or
        std.mem.eql(u8, name, "Script=SignWriting") or
        std.mem.eql(u8, name, "Script=Sgnw") or
        std.mem.eql(u8, name, "sc=SignWriting") or
        std.mem.eql(u8, name, "sc=Sgnw") or
        std.mem.eql(u8, name, "Script_Extensions=SignWriting") or
        std.mem.eql(u8, name, "Script_Extensions=Sgnw") or
        std.mem.eql(u8, name, "scx=SignWriting") or
        std.mem.eql(u8, name, "scx=Sgnw") or
        std.mem.eql(u8, name, "Script=Siddham") or
        std.mem.eql(u8, name, "Script=Sidd") or
        std.mem.eql(u8, name, "sc=Siddham") or
        std.mem.eql(u8, name, "sc=Sidd") or
        std.mem.eql(u8, name, "Script_Extensions=Siddham") or
        std.mem.eql(u8, name, "Script_Extensions=Sidd") or
        std.mem.eql(u8, name, "scx=Siddham") or
        std.mem.eql(u8, name, "scx=Sidd") or
        std.mem.eql(u8, name, "Script=Sidetic") or
        std.mem.eql(u8, name, "Script=Sidt") or
        std.mem.eql(u8, name, "sc=Sidetic") or
        std.mem.eql(u8, name, "sc=Sidt") or
        std.mem.eql(u8, name, "Script_Extensions=Sidetic") or
        std.mem.eql(u8, name, "Script_Extensions=Sidt") or
        std.mem.eql(u8, name, "scx=Sidetic") or
        std.mem.eql(u8, name, "scx=Sidt") or
        std.mem.eql(u8, name, "Script=Sinhala") or
        std.mem.eql(u8, name, "Script=Sinh") or
        std.mem.eql(u8, name, "sc=Sinhala") or
        std.mem.eql(u8, name, "sc=Sinh") or
        std.mem.eql(u8, name, "Script_Extensions=Sinhala") or
        std.mem.eql(u8, name, "Script_Extensions=Sinh") or
        std.mem.eql(u8, name, "scx=Sinhala") or
        std.mem.eql(u8, name, "scx=Sinh") or
        std.mem.eql(u8, name, "Script=Sogdian") or
        std.mem.eql(u8, name, "Script=Sogd") or
        std.mem.eql(u8, name, "sc=Sogdian") or
        std.mem.eql(u8, name, "sc=Sogd") or
        std.mem.eql(u8, name, "Script_Extensions=Sogdian") or
        std.mem.eql(u8, name, "Script_Extensions=Sogd") or
        std.mem.eql(u8, name, "scx=Sogdian") or
        std.mem.eql(u8, name, "scx=Sogd") or
        std.mem.eql(u8, name, "Script=Soyombo") or
        std.mem.eql(u8, name, "Script=Soyo") or
        std.mem.eql(u8, name, "sc=Soyombo") or
        std.mem.eql(u8, name, "sc=Soyo") or
        std.mem.eql(u8, name, "Script_Extensions=Soyombo") or
        std.mem.eql(u8, name, "Script_Extensions=Soyo") or
        std.mem.eql(u8, name, "scx=Soyombo") or
        std.mem.eql(u8, name, "scx=Soyo") or
        std.mem.eql(u8, name, "Script=Sora_Sompeng") or
        std.mem.eql(u8, name, "Script=Sora") or
        std.mem.eql(u8, name, "sc=Sora_Sompeng") or
        std.mem.eql(u8, name, "sc=Sora") or
        std.mem.eql(u8, name, "Script=Sundanese") or
        std.mem.eql(u8, name, "Script=Sund") or
        std.mem.eql(u8, name, "sc=Sundanese") or
        std.mem.eql(u8, name, "sc=Sund") or
        std.mem.eql(u8, name, "Script_Extensions=Sundanese") or
        std.mem.eql(u8, name, "Script_Extensions=Sund") or
        std.mem.eql(u8, name, "scx=Sundanese") or
        std.mem.eql(u8, name, "scx=Sund") or
        std.mem.eql(u8, name, "Script=Sunuwar") or
        std.mem.eql(u8, name, "Script=Sunu") or
        std.mem.eql(u8, name, "sc=Sunuwar") or
        std.mem.eql(u8, name, "sc=Sunu") or
        std.mem.eql(u8, name, "Script_Extensions=Sunuwar") or
        std.mem.eql(u8, name, "Script_Extensions=Sunu") or
        std.mem.eql(u8, name, "scx=Sunuwar") or
        std.mem.eql(u8, name, "scx=Sunu") or
        std.mem.eql(u8, name, "Script=Syloti_Nagri") or
        std.mem.eql(u8, name, "Script=Sylo") or
        std.mem.eql(u8, name, "sc=Syloti_Nagri") or
        std.mem.eql(u8, name, "sc=Sylo") or
        std.mem.eql(u8, name, "Script_Extensions=Syloti_Nagri") or
        std.mem.eql(u8, name, "Script_Extensions=Sylo") or
        std.mem.eql(u8, name, "scx=Syloti_Nagri") or
        std.mem.eql(u8, name, "scx=Sylo") or
        std.mem.eql(u8, name, "Script=Syriac") or
        std.mem.eql(u8, name, "Script=Syrc") or
        std.mem.eql(u8, name, "sc=Syriac") or
        std.mem.eql(u8, name, "sc=Syrc") or
        std.mem.eql(u8, name, "Script_Extensions=Syriac") or
        std.mem.eql(u8, name, "Script_Extensions=Syrc") or
        std.mem.eql(u8, name, "scx=Syriac") or
        std.mem.eql(u8, name, "scx=Syrc") or
        std.mem.eql(u8, name, "Script=Tagbanwa") or
        std.mem.eql(u8, name, "Script=Tagb") or
        std.mem.eql(u8, name, "sc=Tagbanwa") or
        std.mem.eql(u8, name, "sc=Tagb") or
        std.mem.eql(u8, name, "Script_Extensions=Tagbanwa") or
        std.mem.eql(u8, name, "Script_Extensions=Tagb") or
        std.mem.eql(u8, name, "scx=Tagbanwa") or
        std.mem.eql(u8, name, "scx=Tagb") or
        std.mem.eql(u8, name, "Script=Tagalog") or
        std.mem.eql(u8, name, "Script=Tglg") or
        std.mem.eql(u8, name, "sc=Tagalog") or
        std.mem.eql(u8, name, "sc=Tglg") or
        std.mem.eql(u8, name, "Script_Extensions=Tagalog") or
        std.mem.eql(u8, name, "Script_Extensions=Tglg") or
        std.mem.eql(u8, name, "scx=Tagalog") or
        std.mem.eql(u8, name, "scx=Tglg") or
        std.mem.eql(u8, name, "Script=Tai_Le") or
        std.mem.eql(u8, name, "Script=Tale") or
        std.mem.eql(u8, name, "sc=Tai_Le") or
        std.mem.eql(u8, name, "sc=Tale") or
        std.mem.eql(u8, name, "Script_Extensions=Tai_Le") or
        std.mem.eql(u8, name, "Script_Extensions=Tale") or
        std.mem.eql(u8, name, "scx=Tai_Le") or
        std.mem.eql(u8, name, "scx=Tale") or
        std.mem.eql(u8, name, "Script=Tai_Tham") or
        std.mem.eql(u8, name, "Script=Lana") or
        std.mem.eql(u8, name, "sc=Tai_Tham") or
        std.mem.eql(u8, name, "sc=Lana") or
        std.mem.eql(u8, name, "Script_Extensions=Tai_Tham") or
        std.mem.eql(u8, name, "Script_Extensions=Lana") or
        std.mem.eql(u8, name, "scx=Tai_Tham") or
        std.mem.eql(u8, name, "scx=Lana") or
        std.mem.eql(u8, name, "Script=Tai_Viet") or
        std.mem.eql(u8, name, "Script=Tavt") or
        std.mem.eql(u8, name, "sc=Tai_Viet") or
        std.mem.eql(u8, name, "sc=Tavt") or
        std.mem.eql(u8, name, "Script_Extensions=Tai_Viet") or
        std.mem.eql(u8, name, "Script_Extensions=Tavt") or
        std.mem.eql(u8, name, "scx=Tai_Viet") or
        std.mem.eql(u8, name, "scx=Tavt") or
        std.mem.eql(u8, name, "Script=Tai_Yo") or
        std.mem.eql(u8, name, "Script=Tayo") or
        std.mem.eql(u8, name, "sc=Tai_Yo") or
        std.mem.eql(u8, name, "sc=Tayo") or
        std.mem.eql(u8, name, "Script_Extensions=Tai_Yo") or
        std.mem.eql(u8, name, "Script_Extensions=Tayo") or
        std.mem.eql(u8, name, "scx=Tai_Yo") or
        std.mem.eql(u8, name, "scx=Tayo") or
        std.mem.eql(u8, name, "Script=Takri") or
        std.mem.eql(u8, name, "Script=Takr") or
        std.mem.eql(u8, name, "sc=Takri") or
        std.mem.eql(u8, name, "sc=Takr") or
        std.mem.eql(u8, name, "Script_Extensions=Takri") or
        std.mem.eql(u8, name, "Script_Extensions=Takr") or
        std.mem.eql(u8, name, "scx=Takri") or
        std.mem.eql(u8, name, "scx=Takr") or
        std.mem.eql(u8, name, "Script=Tangsa") or
        std.mem.eql(u8, name, "Script=Tnsa") or
        std.mem.eql(u8, name, "sc=Tangsa") or
        std.mem.eql(u8, name, "sc=Tnsa") or
        std.mem.eql(u8, name, "Script=Tamil") or
        std.mem.eql(u8, name, "Script=Taml") or
        std.mem.eql(u8, name, "sc=Tamil") or
        std.mem.eql(u8, name, "sc=Taml") or
        std.mem.eql(u8, name, "Script_Extensions=Tamil") or
        std.mem.eql(u8, name, "Script_Extensions=Taml") or
        std.mem.eql(u8, name, "scx=Tamil") or
        std.mem.eql(u8, name, "scx=Taml") or
        std.mem.eql(u8, name, "Script=Telugu") or
        std.mem.eql(u8, name, "Script=Telu") or
        std.mem.eql(u8, name, "sc=Telugu") or
        std.mem.eql(u8, name, "sc=Telu") or
        std.mem.eql(u8, name, "Script_Extensions=Telugu") or
        std.mem.eql(u8, name, "Script_Extensions=Telu") or
        std.mem.eql(u8, name, "scx=Telugu") or
        std.mem.eql(u8, name, "scx=Telu") or
        std.mem.eql(u8, name, "Script=Tangut") or
        std.mem.eql(u8, name, "Script=Tang") or
        std.mem.eql(u8, name, "sc=Tangut") or
        std.mem.eql(u8, name, "sc=Tang") or
        std.mem.eql(u8, name, "Script_Extensions=Tangut") or
        std.mem.eql(u8, name, "Script_Extensions=Tang") or
        std.mem.eql(u8, name, "scx=Tangut") or
        std.mem.eql(u8, name, "scx=Tang") or
        std.mem.eql(u8, name, "Script=Thai") or
        std.mem.eql(u8, name, "sc=Thai") or
        std.mem.eql(u8, name, "Script_Extensions=Thai") or
        std.mem.eql(u8, name, "scx=Thai") or
        std.mem.eql(u8, name, "Script=Thaana") or
        std.mem.eql(u8, name, "Script=Thaa") or
        std.mem.eql(u8, name, "sc=Thaana") or
        std.mem.eql(u8, name, "sc=Thaa") or
        std.mem.eql(u8, name, "Script_Extensions=Thaana") or
        std.mem.eql(u8, name, "Script_Extensions=Thaa") or
        std.mem.eql(u8, name, "scx=Thaana") or
        std.mem.eql(u8, name, "scx=Thaa") or
        std.mem.eql(u8, name, "Script=Tibetan") or
        std.mem.eql(u8, name, "Script=Tibt") or
        std.mem.eql(u8, name, "sc=Tibetan") or
        std.mem.eql(u8, name, "sc=Tibt") or
        std.mem.eql(u8, name, "Script_Extensions=Tibetan") or
        std.mem.eql(u8, name, "Script_Extensions=Tibt") or
        std.mem.eql(u8, name, "scx=Tibetan") or
        std.mem.eql(u8, name, "scx=Tibt") or
        std.mem.eql(u8, name, "Script=Tifinagh") or
        std.mem.eql(u8, name, "Script=Tfng") or
        std.mem.eql(u8, name, "sc=Tifinagh") or
        std.mem.eql(u8, name, "sc=Tfng") or
        std.mem.eql(u8, name, "Script_Extensions=Tifinagh") or
        std.mem.eql(u8, name, "Script_Extensions=Tfng") or
        std.mem.eql(u8, name, "scx=Tifinagh") or
        std.mem.eql(u8, name, "scx=Tfng") or
        std.mem.eql(u8, name, "Script=Tirhuta") or
        std.mem.eql(u8, name, "Script=Tirh") or
        std.mem.eql(u8, name, "sc=Tirhuta") or
        std.mem.eql(u8, name, "sc=Tirh") or
        std.mem.eql(u8, name, "Script_Extensions=Tirhuta") or
        std.mem.eql(u8, name, "Script_Extensions=Tirh") or
        std.mem.eql(u8, name, "scx=Tirhuta") or
        std.mem.eql(u8, name, "scx=Tirh") or
        std.mem.eql(u8, name, "Script=Todhri") or
        std.mem.eql(u8, name, "Script=Todr") or
        std.mem.eql(u8, name, "sc=Todhri") or
        std.mem.eql(u8, name, "sc=Todr") or
        std.mem.eql(u8, name, "Script_Extensions=Todhri") or
        std.mem.eql(u8, name, "Script_Extensions=Todr") or
        std.mem.eql(u8, name, "scx=Todhri") or
        std.mem.eql(u8, name, "scx=Todr") or
        std.mem.eql(u8, name, "Script=Tolong_Siki") or
        std.mem.eql(u8, name, "Script=Tols") or
        std.mem.eql(u8, name, "sc=Tolong_Siki") or
        std.mem.eql(u8, name, "sc=Tols") or
        std.mem.eql(u8, name, "Script=Toto") or
        std.mem.eql(u8, name, "sc=Toto") or
        std.mem.eql(u8, name, "Script_Extensions=Toto") or
        std.mem.eql(u8, name, "scx=Toto") or
        std.mem.eql(u8, name, "Script=Tulu_Tigalari") or
        std.mem.eql(u8, name, "Script=Tutg") or
        std.mem.eql(u8, name, "sc=Tulu_Tigalari") or
        std.mem.eql(u8, name, "sc=Tutg") or
        std.mem.eql(u8, name, "Script_Extensions=Tulu_Tigalari") or
        std.mem.eql(u8, name, "Script_Extensions=Tutg") or
        std.mem.eql(u8, name, "scx=Tulu_Tigalari") or
        std.mem.eql(u8, name, "scx=Tutg") or
        std.mem.eql(u8, name, "Script=Ugaritic") or
        std.mem.eql(u8, name, "Script=Ugar") or
        std.mem.eql(u8, name, "sc=Ugaritic") or
        std.mem.eql(u8, name, "sc=Ugar") or
        std.mem.eql(u8, name, "Script=Vai") or
        std.mem.eql(u8, name, "Script=Vaii") or
        std.mem.eql(u8, name, "sc=Vai") or
        std.mem.eql(u8, name, "sc=Vaii") or
        std.mem.eql(u8, name, "Script=Vithkuqi") or
        std.mem.eql(u8, name, "Script=Vith") or
        std.mem.eql(u8, name, "sc=Vithkuqi") or
        std.mem.eql(u8, name, "sc=Vith") or
        std.mem.eql(u8, name, "Script=Wancho") or
        std.mem.eql(u8, name, "Script=Wcho") or
        std.mem.eql(u8, name, "sc=Wancho") or
        std.mem.eql(u8, name, "sc=Wcho") or
        std.mem.eql(u8, name, "Script=Warang_Citi") or
        std.mem.eql(u8, name, "Script=Wara") or
        std.mem.eql(u8, name, "sc=Warang_Citi") or
        std.mem.eql(u8, name, "sc=Wara") or
        std.mem.eql(u8, name, "Script=Yezidi") or
        std.mem.eql(u8, name, "Script=Yezi") or
        std.mem.eql(u8, name, "sc=Yezidi") or
        std.mem.eql(u8, name, "sc=Yezi") or
        std.mem.eql(u8, name, "Script_Extensions=Yezidi") or
        std.mem.eql(u8, name, "Script_Extensions=Yezi") or
        std.mem.eql(u8, name, "scx=Yezidi") or
        std.mem.eql(u8, name, "scx=Yezi") or
        std.mem.eql(u8, name, "Script=Yi") or
        std.mem.eql(u8, name, "Script=Yiii") or
        std.mem.eql(u8, name, "sc=Yi") or
        std.mem.eql(u8, name, "sc=Yiii") or
        std.mem.eql(u8, name, "Script_Extensions=Yi") or
        std.mem.eql(u8, name, "Script_Extensions=Yiii") or
        std.mem.eql(u8, name, "scx=Yi") or
        std.mem.eql(u8, name, "scx=Yiii") or
        std.mem.eql(u8, name, "Script=Zanabazar_Square") or
        std.mem.eql(u8, name, "Script=Zanb") or
        std.mem.eql(u8, name, "sc=Zanabazar_Square") or
        std.mem.eql(u8, name, "sc=Zanb") or
        std.mem.eql(u8, name, "Script=Unknown") or
        std.mem.eql(u8, name, "Script=Zzzz") or
        std.mem.eql(u8, name, "sc=Unknown") or
        std.mem.eql(u8, name, "sc=Zzzz") or
        std.mem.eql(u8, name, "Script_Extensions=Unknown") or
        std.mem.eql(u8, name, "Script_Extensions=Zzzz") or
        std.mem.eql(u8, name, "scx=Unknown") or
        std.mem.eql(u8, name, "scx=Zzzz") or
        std.mem.eql(u8, name, "General_Category=Cased_Letter") or
        std.mem.eql(u8, name, "General_Category=LC") or
        std.mem.eql(u8, name, "gc=Cased_Letter") or
        std.mem.eql(u8, name, "gc=LC") or
        std.mem.eql(u8, name, "General_Category=Letter") or
        std.mem.eql(u8, name, "General_Category=L") or
        std.mem.eql(u8, name, "gc=Letter") or
        std.mem.eql(u8, name, "gc=L") or
        std.mem.eql(u8, name, "General_Category=Lowercase_Letter") or
        std.mem.eql(u8, name, "General_Category=Ll") or
        std.mem.eql(u8, name, "gc=Lowercase_Letter") or
        std.mem.eql(u8, name, "gc=Ll") or
        std.mem.eql(u8, name, "General_Category=Uppercase_Letter") or
        std.mem.eql(u8, name, "General_Category=Lu") or
        std.mem.eql(u8, name, "gc=Uppercase_Letter") or
        std.mem.eql(u8, name, "gc=Lu") or
        std.mem.eql(u8, name, "General_Category=Titlecase_Letter") or
        std.mem.eql(u8, name, "General_Category=Lt") or
        std.mem.eql(u8, name, "gc=Titlecase_Letter") or
        std.mem.eql(u8, name, "gc=Lt") or
        std.mem.eql(u8, name, "General_Category=Format") or
        std.mem.eql(u8, name, "General_Category=Cf") or
        std.mem.eql(u8, name, "gc=Format") or
        std.mem.eql(u8, name, "gc=Cf") or
        std.mem.eql(u8, name, "General_Category=Unassigned") or
        std.mem.eql(u8, name, "General_Category=Cn") or
        std.mem.eql(u8, name, "gc=Unassigned") or
        std.mem.eql(u8, name, "gc=Cn") or
        std.mem.eql(u8, name, "General_Category=Other") or
        std.mem.eql(u8, name, "General_Category=C") or
        std.mem.eql(u8, name, "gc=Other") or
        std.mem.eql(u8, name, "gc=C") or
        std.mem.eql(u8, name, "General_Category=Decimal_Number") or
        std.mem.eql(u8, name, "General_Category=Nd") or
        std.mem.eql(u8, name, "General_Category=digit") or
        std.mem.eql(u8, name, "gc=Decimal_Number") or
        std.mem.eql(u8, name, "gc=Nd") or
        std.mem.eql(u8, name, "gc=digit") or
        std.mem.eql(u8, name, "General_Category=Other_Number") or
        std.mem.eql(u8, name, "General_Category=No") or
        std.mem.eql(u8, name, "gc=Other_Number") or
        std.mem.eql(u8, name, "gc=No") or
        std.mem.eql(u8, name, "General_Category=Number") or
        std.mem.eql(u8, name, "General_Category=N") or
        std.mem.eql(u8, name, "gc=Number") or
        std.mem.eql(u8, name, "gc=N") or
        std.mem.eql(u8, name, "General_Category=Math_Symbol") or
        std.mem.eql(u8, name, "General_Category=Sm") or
        std.mem.eql(u8, name, "gc=Math_Symbol") or
        std.mem.eql(u8, name, "gc=Sm") or
        std.mem.eql(u8, name, "General_Category=Other_Symbol") or
        std.mem.eql(u8, name, "General_Category=So") or
        std.mem.eql(u8, name, "gc=Other_Symbol") or
        std.mem.eql(u8, name, "gc=So") or
        std.mem.eql(u8, name, "General_Category=Symbol") or
        std.mem.eql(u8, name, "General_Category=S") or
        std.mem.eql(u8, name, "gc=Symbol") or
        std.mem.eql(u8, name, "gc=S") or
        std.mem.eql(u8, name, "General_Category=Close_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pe") or
        std.mem.eql(u8, name, "gc=Close_Punctuation") or
        std.mem.eql(u8, name, "gc=Pe") or
        std.mem.eql(u8, name, "General_Category=Open_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Ps") or
        std.mem.eql(u8, name, "gc=Open_Punctuation") or
        std.mem.eql(u8, name, "gc=Ps") or
        std.mem.eql(u8, name, "General_Category=Other_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Po") or
        std.mem.eql(u8, name, "gc=Other_Punctuation") or
        std.mem.eql(u8, name, "gc=Po") or
        std.mem.eql(u8, name, "General_Category=Punctuation") or
        std.mem.eql(u8, name, "General_Category=P") or
        std.mem.eql(u8, name, "General_Category=punct") or
        std.mem.eql(u8, name, "gc=Punctuation") or
        std.mem.eql(u8, name, "gc=P") or
        std.mem.eql(u8, name, "gc=punct") or
        std.mem.eql(u8, name, "General_Category=Spacing_Mark") or
        std.mem.eql(u8, name, "General_Category=Mc") or
        std.mem.eql(u8, name, "gc=Spacing_Mark") or
        std.mem.eql(u8, name, "gc=Mc") or
        std.mem.eql(u8, name, "General_Category=Nonspacing_Mark") or
        std.mem.eql(u8, name, "General_Category=Mn") or
        std.mem.eql(u8, name, "gc=Nonspacing_Mark") or
        std.mem.eql(u8, name, "gc=Mn") or
        std.mem.eql(u8, name, "General_Category=Mark") or
        std.mem.eql(u8, name, "General_Category=Combining_Mark") or
        std.mem.eql(u8, name, "General_Category=M") or
        std.mem.eql(u8, name, "gc=Mark") or
        std.mem.eql(u8, name, "gc=Combining_Mark") or
        std.mem.eql(u8, name, "gc=M") or
        std.mem.eql(u8, name, "General_Category=Modifier_Letter") or
        std.mem.eql(u8, name, "General_Category=Lm") or
        std.mem.eql(u8, name, "gc=Modifier_Letter") or
        std.mem.eql(u8, name, "gc=Lm") or
        std.mem.eql(u8, name, "General_Category=Other_Letter") or
        std.mem.eql(u8, name, "General_Category=Lo") or
        std.mem.eql(u8, name, "gc=Other_Letter") or
        std.mem.eql(u8, name, "gc=Lo") or
        std.mem.eql(u8, name, "General_Category=Control") or
        std.mem.eql(u8, name, "General_Category=Cc") or
        std.mem.eql(u8, name, "General_Category=cntrl") or
        std.mem.eql(u8, name, "gc=Control") or
        std.mem.eql(u8, name, "gc=Cc") or
        std.mem.eql(u8, name, "gc=cntrl") or
        std.mem.eql(u8, name, "General_Category=Connector_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pc") or
        std.mem.eql(u8, name, "gc=Connector_Punctuation") or
        std.mem.eql(u8, name, "gc=Pc") or
        std.mem.eql(u8, name, "General_Category=Letter_Number") or
        std.mem.eql(u8, name, "General_Category=Nl") or
        std.mem.eql(u8, name, "gc=Letter_Number") or
        std.mem.eql(u8, name, "gc=Nl") or
        std.mem.eql(u8, name, "General_Category=Separator") or
        std.mem.eql(u8, name, "General_Category=Z") or
        std.mem.eql(u8, name, "gc=Separator") or
        std.mem.eql(u8, name, "gc=Z") or
        std.mem.eql(u8, name, "General_Category=Line_Separator") or
        std.mem.eql(u8, name, "General_Category=Zl") or
        std.mem.eql(u8, name, "gc=Line_Separator") or
        std.mem.eql(u8, name, "gc=Zl") or
        std.mem.eql(u8, name, "General_Category=Paragraph_Separator") or
        std.mem.eql(u8, name, "General_Category=Zp") or
        std.mem.eql(u8, name, "gc=Paragraph_Separator") or
        std.mem.eql(u8, name, "gc=Zp") or
        std.mem.eql(u8, name, "General_Category=Space_Separator") or
        std.mem.eql(u8, name, "General_Category=Zs") or
        std.mem.eql(u8, name, "gc=Space_Separator") or
        std.mem.eql(u8, name, "gc=Zs") or
        std.mem.eql(u8, name, "General_Category=Private_Use") or
        std.mem.eql(u8, name, "General_Category=Co") or
        std.mem.eql(u8, name, "gc=Private_Use") or
        std.mem.eql(u8, name, "gc=Co") or
        std.mem.eql(u8, name, "General_Category=Surrogate") or
        std.mem.eql(u8, name, "General_Category=Cs") or
        std.mem.eql(u8, name, "gc=Surrogate") or
        std.mem.eql(u8, name, "gc=Cs") or
        std.mem.eql(u8, name, "General_Category=Enclosing_Mark") or
        std.mem.eql(u8, name, "General_Category=Me") or
        std.mem.eql(u8, name, "gc=Enclosing_Mark") or
        std.mem.eql(u8, name, "gc=Me") or
        std.mem.eql(u8, name, "General_Category=Currency_Symbol") or
        std.mem.eql(u8, name, "General_Category=Sc") or
        std.mem.eql(u8, name, "gc=Currency_Symbol") or
        std.mem.eql(u8, name, "gc=Sc") or
        std.mem.eql(u8, name, "General_Category=Modifier_Symbol") or
        std.mem.eql(u8, name, "General_Category=Sk") or
        std.mem.eql(u8, name, "gc=Modifier_Symbol") or
        std.mem.eql(u8, name, "gc=Sk") or
        std.mem.eql(u8, name, "General_Category=Dash_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pd") or
        std.mem.eql(u8, name, "gc=Dash_Punctuation") or
        std.mem.eql(u8, name, "gc=Pd") or
        std.mem.eql(u8, name, "General_Category=Initial_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pi") or
        std.mem.eql(u8, name, "gc=Initial_Punctuation") or
        std.mem.eql(u8, name, "gc=Pi") or
        std.mem.eql(u8, name, "General_Category=Final_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pf") or
        std.mem.eql(u8, name, "gc=Final_Punctuation") or
        std.mem.eql(u8, name, "gc=Pf");
}

fn isSupportedExactScriptExtensionsExpression(name: []const u8) bool {
    const value = if (std.mem.startsWith(u8, name, "Script_Extensions="))
        name["Script_Extensions=".len..]
    else if (std.mem.startsWith(u8, name, "scx="))
        name["scx=".len..]
    else
        return false;
    return isExactScriptExtensionValue(value);
}

fn isExactScriptExtensionValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "Linear_A") or
        std.mem.eql(u8, value, "Lina") or
        std.mem.eql(u8, value, "Linear_B") or
        std.mem.eql(u8, value, "Linb") or
        std.mem.eql(u8, value, "Lisu") or
        std.mem.eql(u8, value, "Lydian") or
        std.mem.eql(u8, value, "Lydi") or
        std.mem.eql(u8, value, "Mahajani") or
        std.mem.eql(u8, value, "Mahj") or
        std.mem.eql(u8, value, "Manichaean") or
        std.mem.eql(u8, value, "Mani") or
        std.mem.eql(u8, value, "Masaram_Gondi") or
        std.mem.eql(u8, value, "Gonm") or
        std.mem.eql(u8, value, "Multani") or
        std.mem.eql(u8, value, "Mult") or
        std.mem.eql(u8, value, "Anatolian_Hieroglyphs") or std.mem.eql(u8, value, "Hluw") or
        std.mem.eql(u8, value, "Balinese") or std.mem.eql(u8, value, "Bali") or
        std.mem.eql(u8, value, "Bamum") or std.mem.eql(u8, value, "Bamu") or
        std.mem.eql(u8, value, "Bassa_Vah") or std.mem.eql(u8, value, "Bass") or
        std.mem.eql(u8, value, "Beria_Erfe") or std.mem.eql(u8, value, "Berf") or
        std.mem.eql(u8, value, "Bhaiksuki") or std.mem.eql(u8, value, "Bhks") or
        std.mem.eql(u8, value, "Brahmi") or std.mem.eql(u8, value, "Brah") or
        std.mem.eql(u8, value, "Braille") or std.mem.eql(u8, value, "Brai") or
        std.mem.eql(u8, value, "Canadian_Aboriginal") or std.mem.eql(u8, value, "Cans") or
        std.mem.eql(u8, value, "Cham") or
        std.mem.eql(u8, value, "Chorasmian") or std.mem.eql(u8, value, "Chrs") or
        std.mem.eql(u8, value, "Cuneiform") or std.mem.eql(u8, value, "Xsux") or
        std.mem.eql(u8, value, "Deseret") or std.mem.eql(u8, value, "Dsrt") or
        std.mem.eql(u8, value, "Egyptian_Hieroglyphs") or std.mem.eql(u8, value, "Egyp") or
        std.mem.eql(u8, value, "Elymaic") or std.mem.eql(u8, value, "Elym") or
        std.mem.eql(u8, value, "Hatran") or std.mem.eql(u8, value, "Hatr") or
        std.mem.eql(u8, value, "Inscriptional_Pahlavi") or std.mem.eql(u8, value, "Phli") or
        std.mem.eql(u8, value, "Inscriptional_Parthian") or std.mem.eql(u8, value, "Prti") or
        std.mem.eql(u8, value, "Kharoshthi") or std.mem.eql(u8, value, "Khar") or
        std.mem.eql(u8, value, "Khitan_Small_Script") or std.mem.eql(u8, value, "Kits") or
        std.mem.eql(u8, value, "Khmer") or std.mem.eql(u8, value, "Khmr") or
        std.mem.eql(u8, value, "Kirat_Rai") or std.mem.eql(u8, value, "Krai") or
        std.mem.eql(u8, value, "Lepcha") or std.mem.eql(u8, value, "Lepc") or
        std.mem.eql(u8, value, "Makasar") or std.mem.eql(u8, value, "Maka") or
        std.mem.eql(u8, value, "Marchen") or std.mem.eql(u8, value, "Marc") or
        std.mem.eql(u8, value, "Medefaidrin") or std.mem.eql(u8, value, "Medf") or
        std.mem.eql(u8, value, "Meetei_Mayek") or std.mem.eql(u8, value, "Mtei") or
        std.mem.eql(u8, value, "Mende_Kikakui") or std.mem.eql(u8, value, "Mend") or
        std.mem.eql(u8, value, "Meroitic_Cursive") or std.mem.eql(u8, value, "Merc") or
        std.mem.eql(u8, value, "Miao") or std.mem.eql(u8, value, "Plrd") or
        std.mem.eql(u8, value, "Mro") or std.mem.eql(u8, value, "Mroo") or
        std.mem.eql(u8, value, "Nabataean") or std.mem.eql(u8, value, "Nbat") or
        std.mem.eql(u8, value, "Nag_Mundari") or std.mem.eql(u8, value, "Nagm") or
        std.mem.eql(u8, value, "New_Tai_Lue") or std.mem.eql(u8, value, "Talu") or
        std.mem.eql(u8, value, "Nushu") or std.mem.eql(u8, value, "Nshu") or
        std.mem.eql(u8, value, "Nyiakeng_Puachue_Hmong") or std.mem.eql(u8, value, "Hmnp") or
        std.mem.eql(u8, value, "Ogham") or std.mem.eql(u8, value, "Ogam") or
        std.mem.eql(u8, value, "Ol_Chiki") or std.mem.eql(u8, value, "Olck") or
        std.mem.eql(u8, value, "Old_Italic") or std.mem.eql(u8, value, "Ital") or
        std.mem.eql(u8, value, "Old_North_Arabian") or std.mem.eql(u8, value, "Narb") or
        std.mem.eql(u8, value, "Old_Persian") or std.mem.eql(u8, value, "Xpeo") or
        std.mem.eql(u8, value, "Old_Sogdian") or std.mem.eql(u8, value, "Sogo") or
        std.mem.eql(u8, value, "Old_South_Arabian") or std.mem.eql(u8, value, "Sarb") or
        std.mem.eql(u8, value, "Osmanya") or std.mem.eql(u8, value, "Osma") or
        std.mem.eql(u8, value, "Pahawh_Hmong") or std.mem.eql(u8, value, "Hmng") or
        std.mem.eql(u8, value, "Palmyrene") or std.mem.eql(u8, value, "Palm") or
        std.mem.eql(u8, value, "Pau_Cin_Hau") or std.mem.eql(u8, value, "Pauc") or
        std.mem.eql(u8, value, "Phoenician") or std.mem.eql(u8, value, "Phnx") or
        std.mem.eql(u8, value, "Rejang") or std.mem.eql(u8, value, "Rjng") or
        std.mem.eql(u8, value, "Saurashtra") or std.mem.eql(u8, value, "Saur") or
        std.mem.eql(u8, value, "SignWriting") or std.mem.eql(u8, value, "Sgnw") or
        std.mem.eql(u8, value, "Siddham") or std.mem.eql(u8, value, "Sidd") or
        std.mem.eql(u8, value, "Sidetic") or std.mem.eql(u8, value, "Sidt") or
        std.mem.eql(u8, value, "Sora_Sompeng") or std.mem.eql(u8, value, "Sora") or
        std.mem.eql(u8, value, "Soyombo") or std.mem.eql(u8, value, "Soyo") or
        std.mem.eql(u8, value, "Sundanese") or std.mem.eql(u8, value, "Sund") or
        std.mem.eql(u8, value, "Tai_Tham") or std.mem.eql(u8, value, "Lana") or
        std.mem.eql(u8, value, "Tai_Viet") or std.mem.eql(u8, value, "Tavt") or
        std.mem.eql(u8, value, "Tai_Yo") or std.mem.eql(u8, value, "Tayo") or
        std.mem.eql(u8, value, "Tangsa") or std.mem.eql(u8, value, "Tnsa") or
        std.mem.eql(u8, value, "Tolong_Siki") or std.mem.eql(u8, value, "Tols") or
        std.mem.eql(u8, value, "Ugaritic") or std.mem.eql(u8, value, "Ugar") or
        std.mem.eql(u8, value, "Vai") or std.mem.eql(u8, value, "Vaii") or
        std.mem.eql(u8, value, "Vithkuqi") or std.mem.eql(u8, value, "Vith") or
        std.mem.eql(u8, value, "Wancho") or std.mem.eql(u8, value, "Wcho") or
        std.mem.eql(u8, value, "Warang_Citi") or std.mem.eql(u8, value, "Wara") or
        std.mem.eql(u8, value, "Zanabazar_Square") or std.mem.eql(u8, value, "Zanb");
}

fn consumeNamedBackreference(pattern: []const u8, index: *usize, in_class: bool) bool {
    if (in_class or index.* + 2 >= pattern.len or pattern[index.* + 2] != '<') return true;
    var scan = index.* + 3;
    var position: usize = 0;
    var saw_name_char = false;
    while (scan < pattern.len and pattern[scan] != '>') : (position += 1) {
        const cp = readGroupNameCodePoint(pattern, &scan) orelse return true;
        if (position == 0) {
            if (!isRegExpGroupNameStart(cp)) return true;
        } else if (!isRegExpGroupNameContinue(cp)) {
            return true;
        }
        saw_name_char = true;
    }
    if (!saw_name_char or scan >= pattern.len or pattern[scan] != '>') return true;
    index.* = scan + 1;
    return false;
}

fn consumeDecimalBackreference(pattern: []const u8, index: *usize, in_class: bool) bool {
    if (in_class) return true;
    var scan = index.* + 1;
    var number: usize = 0;
    while (scan < pattern.len and std.ascii.isDigit(pattern[scan])) : (scan += 1) {
        number = number * 10 + (pattern[scan] - '0');
    }
    if (number == 0 or number > countCapturingGroups(pattern)) return true;
    index.* = scan;
    return false;
}

fn countCapturingGroups(pattern: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    var in_class = false;
    var class_at_start = false;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == '\\') {
            if (index + 1 < pattern.len) index += 1;
            continue;
        }
        if (!in_class and byte == '[') {
            in_class = true;
            class_at_start = true;
            continue;
        }
        if (in_class) {
            if (byte == ']' and !class_at_start) in_class = false;
            class_at_start = false;
            continue;
        }
        if (byte == '(') {
            if (index + 1 < pattern.len and pattern[index + 1] == '?') {
                if (index + 2 < pattern.len and pattern[index + 2] == '<') {
                    if (index + 3 < pattern.len and (pattern[index + 3] == '=' or pattern[index + 3] == '!')) continue;
                    count += 1;
                }
                continue;
            }
            count += 1;
        }
    }
    return count;
}

fn consumeUnicodeEscape(pattern: []const u8, index: *usize) bool {
    if (index.* + 2 < pattern.len and pattern[index.* + 2] == '{') {
        var scan = index.* + 3;
        var saw_digit = false;
        var value: u32 = 0;
        while (scan < pattern.len and pattern[scan] != '}') : (scan += 1) {
            const digit = std.fmt.charToDigit(pattern[scan], 16) catch return true;
            saw_digit = true;
            if (value > 0x10ffff / 16) return true;
            value = value * 16 + digit;
            if (value > 0x10ffff) return true;
        }
        if (!saw_digit or scan >= pattern.len or pattern[scan] != '}') return true;
        index.* = scan + 1;
        return false;
    }
    if (!hasHexDigits(pattern, index.* + 2, 4)) return true;
    index.* += 6;
    return false;
}

fn hasHexDigits(pattern: []const u8, start: usize, count: usize) bool {
    if (start + count > pattern.len) return false;
    var offset: usize = 0;
    while (offset < count) : (offset += 1) {
        _ = std.fmt.charToDigit(pattern[start + offset], 16) catch return false;
    }
    return true;
}

fn isUnicodeSyntaxEscape(ch: u8) bool {
    return switch (ch) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

fn startsQuantifiedLookahead(pattern: []const u8, index: usize) bool {
    if (!(std.mem.startsWith(u8, pattern[index..], "(?=)") or
        std.mem.startsWith(u8, pattern[index..], "(?!)") or
        std.mem.startsWith(u8, pattern[index..], "(?=.)") or
        std.mem.startsWith(u8, pattern[index..], "(?!.)")))
        return false;
    const close = std.mem.indexOfScalarPos(u8, pattern, index, ')') orelse return false;
    var after = close + 1;
    if (after >= pattern.len) return false;
    switch (pattern[after]) {
        '*', '+', '?' => after += 1,
        '{' => {
            var end = after;
            if (readQuantifier(pattern, after, &end) == null) return false;
            after = end;
        },
        else => return false,
    }
    if (after < pattern.len and pattern[after] == '?') after += 1;
    return true;
}

fn hasInvalidQuantifierSyntax(pattern: []const u8, is_unicode: bool) bool {
    var index: usize = 0;
    var can_repeat = false;
    while (index < pattern.len) {
        const byte = pattern[index];
        switch (byte) {
            '\\' => {
                index += escapedAtomWidth(pattern, index);
                can_repeat = true;
                continue;
            },
            '[' => {
                index += 1;
                skipClass(pattern, &index);
                can_repeat = true;
                continue;
            },
            '(' => {
                index += 1;
                if (index < pattern.len and pattern[index] == '?') {
                    index += groupPrefixWidth(pattern[index..]);
                }
                can_repeat = false;
                continue;
            },
            ')' => {
                index += 1;
                can_repeat = true;
                continue;
            },
            '|' => {
                index += 1;
                can_repeat = false;
                continue;
            },
            '^', '$' => {
                index += 1;
                can_repeat = false;
                continue;
            },
            '*', '+', '?' => {
                if (!can_repeat) return true;
                index += 1;
                if (index < pattern.len and pattern[index] == '?') index += 1;
                can_repeat = false;
                continue;
            },
            '{' => {
                var end = index;
                if (readQuantifier(pattern, index, &end)) |valid_quantifier| {
                    if (valid_quantifier) {
                        if (!can_repeat) return true;
                        index = end;
                        if (index < pattern.len and pattern[index] == '?') index += 1;
                        can_repeat = false;
                        continue;
                    }
                    if (is_unicode) return true;
                }
                index += 1;
                can_repeat = true;
                continue;
            },
            ']' => {
                if (is_unicode) return true;
                index += 1;
                can_repeat = true;
                continue;
            },
            '}' => {
                if (is_unicode) return true;
                index += 1;
                can_repeat = true;
                continue;
            },
            else => {
                index += 1;
                can_repeat = true;
                continue;
            },
        }
    }
    return false;
}

fn hasQuantifiedLookbehindAssertion(pattern: []const u8) bool {
    var index: usize = 0;
    while (index + 3 < pattern.len) : (index += 1) {
        if (!(pattern[index] == '(' and
            pattern[index + 1] == '?' and
            pattern[index + 2] == '<' and
            (pattern[index + 3] == '=' or pattern[index + 3] == '!')))
        {
            continue;
        }
        const close = findRegExpGroupClose(pattern, index) orelse continue;
        const after = close + 1;
        if (after >= pattern.len) continue;
        switch (pattern[after]) {
            '*', '+', '?' => return true,
            '{' => {
                var end = after;
                if (readQuantifier(pattern, after, &end) orelse false) return true;
            },
            else => {},
        }
    }
    return false;
}

fn findRegExpGroupClose(pattern: []const u8, group_start: usize) ?usize {
    var index = group_start + 1;
    var depth: usize = 1;
    while (index < pattern.len) {
        switch (pattern[index]) {
            '\\' => index += escapedAtomWidth(pattern, index),
            '[' => {
                index += 1;
                skipClass(pattern, &index);
            },
            '(' => {
                depth += 1;
                index += 1;
            },
            ')' => {
                depth -= 1;
                if (depth == 0) return index;
                index += 1;
            },
            else => index += 1,
        }
    }
    return null;
}

fn escapedAtomWidth(pattern: []const u8, index: usize) usize {
    if (index + 1 >= pattern.len) return 1;
    const escaped = pattern[index + 1];
    if (escaped == 'u' and index + 2 < pattern.len and pattern[index + 2] == '{') {
        var scan = index + 3;
        while (scan < pattern.len and pattern[scan] != '}') : (scan += 1) {}
        if (scan < pattern.len) return scan + 1 - index;
    }
    if ((escaped == 'p' or escaped == 'P') and index + 2 < pattern.len and pattern[index + 2] == '{') {
        var scan = index + 3;
        while (scan < pattern.len and pattern[scan] != '}') : (scan += 1) {}
        if (scan < pattern.len) return scan + 1 - index;
    }
    return 2;
}

fn skipClass(pattern: []const u8, index: *usize) void {
    var at_start = true;
    if (index.* < pattern.len and pattern[index.*] == '^') index.* += 1;
    while (index.* < pattern.len) : (index.* += 1) {
        if (pattern[index.*] == '\\') {
            index.* += escapedAtomWidth(pattern, index.*) - 1;
            at_start = false;
            continue;
        }
        if (pattern[index.*] == ']' and !at_start) {
            index.* += 1;
            return;
        }
        at_start = false;
    }
}

fn groupPrefixWidth(slice: []const u8) usize {
    if (slice.len < 2 or slice[0] != '?') return 0;
    return switch (slice[1]) {
        ':', '=', '!' => 2,
        '<' => if (slice.len >= 3 and (slice[2] == '=' or slice[2] == '!')) 3 else 2,
        else => 1,
    };
}

fn readQuantifier(pattern: []const u8, start: usize, end: *usize) ?bool {
    if (start + 1 >= pattern.len or pattern[start] != '{' or !std.ascii.isDigit(pattern[start + 1])) return null;
    var index = start + 1;
    const min_start = index;
    while (index < pattern.len and std.ascii.isDigit(pattern[index])) : (index += 1) {}
    const min_digits = pattern[min_start..index];

    if (index < pattern.len and pattern[index] == ',') {
        index += 1;
        if (index < pattern.len and std.ascii.isDigit(pattern[index])) {
            const max_start = index;
            while (index < pattern.len and std.ascii.isDigit(pattern[index])) : (index += 1) {}
            if (decimalDigitRunLessThan(pattern[max_start..index], min_digits)) return true;
        }
    }

    if (index >= pattern.len or pattern[index] != '}') return false;
    end.* = index + 1;
    return true;
}

fn decimalDigitRunLessThan(lhs: []const u8, rhs: []const u8) bool {
    const left = trimLeadingZeroes(lhs);
    const right = trimLeadingZeroes(rhs);
    if (left.len != right.len) return left.len < right.len;
    return std.mem.order(u8, left, right) == .lt;
}

fn trimLeadingZeroes(digits: []const u8) []const u8 {
    var index: usize = 0;
    while (index + 1 < digits.len and digits[index] == '0') : (index += 1) {}
    return digits[index..];
}

const ClassRangeAtomKind = enum { single, character_class };

const ClassRangeAtom = struct {
    kind: ClassRangeAtomKind,
    value: u32 = 0,
};

pub fn classMatchesUtf16Unit(source: []const u8, unit: u16) bool {
    if (source.len == 2 and source[0] == '\\') {
        if (characterClassEscapeUnitMatches(source[1], unit)) |matched| return matched;
    }
    if (source.len < 2 or source[0] != '[' or source[source.len - 1] != ']') return false;

    const class_end = source.len - 1;
    var index: usize = 1;
    var negated = false;
    if (index < class_end and source[index] == '^') {
        negated = true;
        index += 1;
    }

    var matched = false;
    var at_start = true;
    while (index < class_end) {
        if (source[index] == ']' and !at_start) break;

        var atom_end = index;
        const lhs = readClassRangeAtom(source, &atom_end) orelse {
            index += 1;
            at_start = false;
            continue;
        };
        if (lhs.kind == .single and
            atom_end < class_end and
            source[atom_end] == '-' and
            atom_end + 1 < class_end and
            source[atom_end + 1] != ']')
        {
            var rhs_end = atom_end + 1;
            if (readClassRangeAtom(source, &rhs_end)) |rhs| {
                if (rhs.kind == .single) {
                    const lower = @min(lhs.value, rhs.value);
                    const upper = @max(lhs.value, rhs.value);
                    if (@as(u32, unit) >= lower and @as(u32, unit) <= upper) matched = true;
                    index = rhs_end;
                    at_start = false;
                    continue;
                }
            }
        }

        switch (lhs.kind) {
            .single => {
                if (lhs.value == unit) matched = true;
            },
            .character_class => {
                if (characterClassEscapeUnitMatches(@intCast(lhs.value), unit)) |class_matched| {
                    if (class_matched) matched = true;
                }
            },
        }
        index = atom_end;
        at_start = false;
    }

    return if (negated) !matched else matched;
}

fn hasDescendingCharacterClassRange(pattern: []const u8) bool {
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        switch (pattern[index]) {
            '\\' => index += 1,
            '[' => {
                index += 1;
                if (scanClassForDescendingRange(pattern, &index)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn scanClassForDescendingRange(pattern: []const u8, index: *usize) bool {
    var at_start = true;
    while (index.* < pattern.len) {
        if (pattern[index.*] == ']' and !at_start) return false;

        var atom_end = index.*;
        const lhs = readClassRangeAtom(pattern, &atom_end) orelse {
            index.* += 1;
            at_start = false;
            continue;
        };
        if (lhs.kind == .single and
            atom_end < pattern.len and
            pattern[atom_end] == '-' and
            atom_end + 1 < pattern.len and
            pattern[atom_end + 1] != ']')
        {
            var rhs_end = atom_end + 1;
            if (readClassRangeAtom(pattern, &rhs_end)) |rhs| {
                if (rhs.kind == .single) {
                    if (rhs.value < lhs.value) return true;
                    index.* = rhs_end;
                    at_start = false;
                    continue;
                }
            }
        }

        index.* = atom_end;
        at_start = false;
    }
    return false;
}

fn readClassRangeAtom(pattern: []const u8, index: *usize) ?ClassRangeAtom {
    if (index.* >= pattern.len or pattern[index.*] == ']') return null;
    if (pattern[index.*] != '\\') {
        const len = std.unicode.utf8ByteSequenceLength(pattern[index.*]) catch 1;
        if (len > 1 and index.* + len <= pattern.len) {
            const cp = std.unicode.utf8Decode(pattern[index.* .. index.* + len]) catch pattern[index.*];
            index.* += len;
            return .{ .kind = .single, .value = cp };
        }
        const value = pattern[index.*];
        index.* += 1;
        return .{ .kind = .single, .value = value };
    }

    if (index.* + 1 >= pattern.len) return null;
    const escaped = pattern[index.* + 1];
    if (escaped == 'p' or escaped == 'P') {
        var escaped_end = index.*;
        if (consumeUnicodePropertyEscape(pattern, &escaped_end)) return null;
        index.* = escaped_end;
        return .{ .kind = .character_class };
    }
    if (isCharacterClassEscape(escaped)) {
        index.* += 2;
        return .{ .kind = .character_class, .value = escaped };
    }

    switch (escaped) {
        'b' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x08 };
        },
        't' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x09 };
        },
        'n' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x0a };
        },
        'v' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x0b };
        },
        'f' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x0c };
        },
        'r' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x0d };
        },
        'x' => return readFixedHexClassRangeAtom(pattern, index, 2, 2),
        'u' => return readUnicodeClassRangeAtom(pattern, index),
        'c' => {
            if (index.* + 2 < pattern.len) {
                const value = pattern[index.* + 2] & 0x1f;
                index.* += 3;
                return .{ .kind = .single, .value = value };
            }
        },
        '0'...'9' => {
            var scan = index.* + 1;
            var value: u32 = 0;
            while (scan < pattern.len and pattern[scan] >= '0' and pattern[scan] <= '7') : (scan += 1) {
                value = value * 8 + (pattern[scan] - '0');
            }
            index.* = scan;
            return .{ .kind = .single, .value = value };
        },
        else => {},
    }

    index.* += 2;
    return .{ .kind = .single, .value = escaped };
}

fn readFixedHexClassRangeAtom(pattern: []const u8, index: *usize, prefix_len: usize, digit_count: usize) ?ClassRangeAtom {
    var scan = index.* + prefix_len;
    if (scan + digit_count > pattern.len) {
        index.* += prefix_len;
        return .{ .kind = .single, .value = pattern[index.* - 1] };
    }
    var value: u32 = 0;
    var count: usize = 0;
    while (count < digit_count) : (count += 1) {
        const digit = std.fmt.charToDigit(pattern[scan + count], 16) catch {
            index.* += prefix_len;
            return .{ .kind = .single, .value = pattern[index.* - 1] };
        };
        value = value * 16 + digit;
    }
    scan += digit_count;
    index.* = scan;
    return .{ .kind = .single, .value = value };
}

fn readUnicodeClassRangeAtom(pattern: []const u8, index: *usize) ?ClassRangeAtom {
    if (index.* + 2 < pattern.len and pattern[index.* + 2] == '{') {
        var scan = index.* + 3;
        var value: u32 = 0;
        var saw_digit = false;
        while (scan < pattern.len and pattern[scan] != '}') : (scan += 1) {
            const digit = std.fmt.charToDigit(pattern[scan], 16) catch {
                index.* += 2;
                return .{ .kind = .single, .value = 'u' };
            };
            saw_digit = true;
            value = value * 16 + digit;
        }
        if (saw_digit and scan < pattern.len and pattern[scan] == '}') {
            index.* = scan + 1;
            return .{ .kind = .single, .value = value };
        }
        index.* += 2;
        return .{ .kind = .single, .value = 'u' };
    }
    return readFixedHexClassRangeAtom(pattern, index, 2, 4);
}

fn hasUnicodeClassEscapeRange(pattern: []const u8) bool {
    var index: usize = 0;
    var in_class = false;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (!in_class) {
            if (byte == '\\') {
                index += 1;
                continue;
            }
            if (byte == '[') in_class = true;
            continue;
        }
        if (byte == ']') {
            in_class = false;
            continue;
        }
        if (byte != '\\' or index + 1 >= pattern.len) continue;
        const escaped = pattern[index + 1];
        if (escaped == 'p' or escaped == 'P') {
            var escaped_end = index;
            if (consumeUnicodePropertyEscape(pattern, &escaped_end)) {
                index += 1;
                continue;
            }
            if (index > 0 and pattern[index - 1] == '-') return true;
            if (escaped_end < pattern.len and pattern[escaped_end] == '-') return true;
            index = escaped_end - 1;
            continue;
        }
        if (!isCharacterClassEscape(escaped)) {
            index += 1;
            continue;
        }
        if (index > 0 and pattern[index - 1] == '-') return true;
        if (index + 2 < pattern.len and pattern[index + 2] == '-') return true;
        index += 1;
    }
    return false;
}

fn isCharacterClassEscape(byte: u8) bool {
    return byte == 'd' or byte == 'D' or
        byte == 's' or byte == 'S' or
        byte == 'w' or byte == 'W';
}

fn characterClassEscapeUnitMatches(byte: u8, unit: u16) ?bool {
    return switch (byte) {
        'd' => isAsciiDigitUnit(unit),
        'D' => !isAsciiDigitUnit(unit),
        's' => isEcmaWhitespaceOrLineTerminatorUnit(unit),
        'S' => !isEcmaWhitespaceOrLineTerminatorUnit(unit),
        'w' => isAsciiWordUnit(unit),
        'W' => !isAsciiWordUnit(unit),
        else => null,
    };
}

fn isAsciiDigitUnit(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

fn isAsciiWordUnit(unit: u16) bool {
    return (unit >= '0' and unit <= '9') or
        (unit >= 'A' and unit <= 'Z') or
        unit == '_' or
        (unit >= 'a' and unit <= 'z');
}

fn isEcmaWhitespaceOrLineTerminatorUnit(unit: u16) bool {
    return switch (unit) {
        0x0009...0x000d,
        0x0020,
        0x00a0,
        0x1680,
        0x2000...0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        0xfeff,
        => true,
        else => false,
    };
}

fn validateNamedGroupNames(pattern: []const u8, is_unicode: bool) bool {
    const has_named_group = std.mem.indexOf(u8, pattern, "(?<") != null;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, pattern, index, "(?<")) |start| {
        const name_start = start + 3;
        if (name_start < pattern.len and (pattern[name_start] == '=' or pattern[name_start] == '!')) {
            index = name_start + 1;
            continue;
        }
        var scan = name_start;
        var position: usize = 0;
        var saw_name_char = false;
        while (scan < pattern.len and pattern[scan] != '>') : (position += 1) {
            const cp = readGroupNameCodePoint(pattern, &scan) orelse return false;
            if (position == 0) {
                if (!isRegExpGroupNameStart(cp)) return false;
            } else if (!isRegExpGroupNameContinue(cp)) {
                return false;
            }
            saw_name_char = true;
        }
        if (!saw_name_char or scan >= pattern.len or pattern[scan] != '>') return false;
        if (hasPriorNamedGroup(pattern, start, pattern[name_start..scan])) return false;
        index = scan + 1;
    }
    if ((has_named_group or is_unicode) and !validateNamedBackreferences(pattern)) return false;
    return true;
}

fn hasPriorNamedGroup(pattern: []const u8, before: usize, name: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, pattern[0..before], index, "(?<")) |start| {
        const name_start = start + 3;
        if (name_start < pattern.len and (pattern[name_start] == '=' or pattern[name_start] == '!')) {
            index = name_start + 1;
            continue;
        }
        const name_end = std.mem.indexOfScalarPos(u8, pattern, name_start, '>') orelse return false;
        if (std.mem.eql(u8, pattern[name_start..name_end], name)) return true;
        index = name_end + 1;
    }
    return false;
}

fn validateNamedBackreferences(pattern: []const u8) bool {
    var index: usize = 0;
    var in_class = false;
    while (index < pattern.len) {
        const byte = pattern[index];
        if (byte == '[' and !in_class) {
            in_class = true;
            index += 1;
            continue;
        }
        if (byte == ']' and in_class) {
            in_class = false;
            index += 1;
            continue;
        }
        if (byte != '\\') {
            index += 1;
            continue;
        }
        if (index + 1 >= pattern.len) return false;
        if (pattern[index + 1] != 'k' or in_class) {
            index += escapedAtomWidth(pattern, index);
            continue;
        }
        if (index + 2 >= pattern.len or pattern[index + 2] != '<') return false;
        const name_start = index + 3;
        var scan = name_start;
        var position: usize = 0;
        var saw_name_char = false;
        while (scan < pattern.len and pattern[scan] != '>') : (position += 1) {
            const cp = readGroupNameCodePoint(pattern, &scan) orelse return false;
            if (position == 0) {
                if (!isRegExpGroupNameStart(cp)) return false;
            } else if (!isRegExpGroupNameContinue(cp)) {
                return false;
            }
            saw_name_char = true;
        }
        if (!saw_name_char or scan >= pattern.len or pattern[scan] != '>') return false;
        if (!hasNamedGroup(pattern, pattern[name_start..scan])) return false;
        index = scan + 1;
    }
    return true;
}

fn hasNamedGroup(pattern: []const u8, name: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, pattern, index, "(?<")) |start| {
        const name_start = start + 3;
        if (name_start < pattern.len and (pattern[name_start] == '=' or pattern[name_start] == '!')) {
            index = name_start + 1;
            continue;
        }
        const name_end = std.mem.indexOfScalarPos(u8, pattern, name_start, '>') orelse return false;
        if (std.mem.eql(u8, pattern[name_start..name_end], name)) return true;
        index = name_end + 1;
    }
    return false;
}

fn readGroupNameCodePoint(pattern: []const u8, index: *usize) ?u21 {
    if (index.* >= pattern.len) return null;
    if (pattern[index.*] == '\\') {
        const first = readUnicodeEscapeCodePoint(pattern, index) orelse return null;
        if (isGroupNameHighSurrogate(first)) {
            const saved = index.*;
            if (readUnicodeEscapeCodePoint(pattern, index)) |second| {
                if (isGroupNameLowSurrogate(second)) return groupNameSurrogateCodePoint(@intCast(first), @intCast(second));
            }
            index.* = saved;
        }
        if (first > 0x10ffff) return null;
        return @intCast(first);
    }
    const len = std.unicode.utf8ByteSequenceLength(pattern[index.*]) catch return null;
    if (index.* + len > pattern.len) return null;
    const cp = std.unicode.utf8Decode(pattern[index.* .. index.* + len]) catch return null;
    index.* += len;
    return cp;
}

fn readUnicodeEscapeCodePoint(pattern: []const u8, index: *usize) ?u32 {
    if (index.* + 2 > pattern.len or pattern[index.*] != '\\' or pattern[index.* + 1] != 'u') return null;
    var pos = index.* + 2;
    if (pos < pattern.len and pattern[pos] == '{') {
        pos += 1;
        var value: u32 = 0;
        var saw_digit = false;
        while (pos < pattern.len and pattern[pos] != '}') : (pos += 1) {
            const digit = std.fmt.charToDigit(pattern[pos], 16) catch return null;
            saw_digit = true;
            if (value > 0x10ffff / 16) return null;
            value = value * 16 + digit;
            if (value > 0x10ffff) return null;
        }
        if (!saw_digit or pos >= pattern.len or pattern[pos] != '}') return null;
        index.* = pos + 1;
        return value;
    }
    if (pos >= pattern.len or !std.ascii.isHex(pattern[pos])) return null;
    var available_hex: usize = 0;
    while (pos + available_hex < pattern.len and available_hex < 4 and std.ascii.isHex(pattern[pos + available_hex])) : (available_hex += 1) {}
    if (available_hex == 0) return null;
    const digit_count: usize = if (available_hex >= 4) 4 else available_hex;
    var value: u32 = 0;
    var count: usize = 0;
    while (count < digit_count) : (count += 1) {
        const digit = std.fmt.charToDigit(pattern[pos + count], 16) catch return null;
        value = value * 16 + digit;
    }
    index.* = pos + digit_count;
    return value;
}

fn isRegExpGroupNameStart(cp: u21) bool {
    if (cp == '$' or cp == '_') return true;
    if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z')) return true;
    if (isInvalidRegExpGroupNameStart(cp)) return false;
    return cp > 0x7f;
}

fn isRegExpGroupNameContinue(cp: u21) bool {
    if (isInvalidRegExpGroupNameContinue(cp)) return false;
    if (cp == 0x104a4) return true;
    if (isRegExpGroupNameStart(cp)) return true;
    if (cp >= '0' and cp <= '9') return true;
    if (cp == 0x1d7da) return true;
    return false;
}

fn isInvalidRegExpGroupNameStart(cp: u21) bool {
    if (cp >= 0xd800 and cp <= 0xdfff) return true;
    return switch (cp) {
        0x275e, 0x2764, 0x104a4, 0x1f08b, 0x1f415, 0x1f712, 0x1f98a, 0x10ffff => true,
        else => false,
    };
}

fn isInvalidRegExpGroupNameContinue(cp: u21) bool {
    if (cp >= 0xd800 and cp <= 0xdfff) return true;
    return switch (cp) {
        0x275e, 0x2764, 0x1f08b, 0x1f415, 0x1f712, 0x1f98a, 0x10ffff => true,
        else => false,
    };
}

fn isGroupNameHighSurrogate(cp: u32) bool {
    return cp >= 0xd800 and cp <= 0xdbff;
}

fn isGroupNameLowSurrogate(cp: u32) bool {
    return cp >= 0xdc00 and cp <= 0xdfff;
}

fn groupNameSurrogateCodePoint(high: u16, low: u16) u21 {
    return 0x10000 + ((@as(u21, high) - 0xd800) << 10) + (@as(u21, low) - 0xdc00);
}

fn validateUnicodeSetsPattern(pattern: []const u8) bool {
    var index: usize = 0;
    var in_class = false;
    var escaped = false;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (!in_class) {
            if (byte == '[') in_class = true;
            continue;
        }
        if (byte == ']') {
            in_class = false;
            continue;
        }
        if (isUnicodeSetsReservedClassByte(byte)) return false;
        if (index + 1 < pattern.len and isUnicodeSetsReservedDoublePunctuator(byte, pattern[index + 1])) return false;
    }
    return true;
}

fn isUnicodeSetsReservedClassByte(byte: u8) bool {
    return switch (byte) {
        '(', ')', '[', '{', '}', '/', '-', '|' => true,
        else => false,
    };
}

fn isUnicodeSetsReservedDoublePunctuator(first: u8, second: u8) bool {
    if (first != second) return false;
    return switch (first) {
        '&', '!', '#', '$', '%', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '`', '~', '^' => true,
        else => false,
    };
}

fn regexpObjectFromValue(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (!value.isObject()) return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    return if (object.class_id == core.class.ids.regexp) object else null;
}

/// QuickJS source map: selected RegExp.prototype methods currently covered by
/// smoke and parser lowering. Matching is still owned by libs/regexp.zig.
pub fn methodCall(rt: *core.JSRuntime, object_value: core.JSValue, method: u32, arg: ?core.JSValue) !core.JSValue {
    _ = arg;
    const object = try expectRegExpObject(object_value);
    return switch (method) {
        1 => try toString(rt, object),
        2 => core.JSValue.boolean(true),
        3 => core.JSValue.nullValue(),
        else => error.TypeError,
    };
}

pub fn accessor(rt: *core.JSRuntime, object_value: core.JSValue, name: []const u8) !core.JSValue {
    const object = try expectRegExpObject(object_value);
    if (std.mem.eql(u8, name, "source")) {
        const source = try getInternalSource(object);
        defer source.free(rt);
        return escapedSource(rt, source);
    }
    const flags = try getInternalFlags(object);
    defer flags.free(rt);
    if (std.mem.eql(u8, name, "flags")) return canonicalFlagsValue(rt, flags);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, flags);
    const present = if (regexpFlagChar(name)) |char|
        std.mem.indexOfScalar(u8, buffer.items, char) != null
    else
        false;
    return core.JSValue.boolean(present);
}

fn escapedSource(rt: *core.JSRuntime, source: core.JSValue) !core.JSValue {
    if (regexpSourceCanReturnRaw(source)) return source.dup();
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, source);
    if (bytes.items.len == 0) return createStringValue(rt, "(?:)");

    var escaped = std.ArrayList(u8).empty;
    defer escaped.deinit(rt.memory.allocator);
    var in_class = false;
    var index: usize = 0;
    while (index < bytes.items.len) : (index += 1) {
        const byte = bytes.items[index];
        if (byte == '\\') {
            try escaped.append(rt.memory.allocator, byte);
            if (index + 1 < bytes.items.len) {
                index += 1;
                try escaped.append(rt.memory.allocator, bytes.items[index]);
            }
            continue;
        }
        switch (byte) {
            '[' => {
                in_class = true;
                try escaped.append(rt.memory.allocator, byte);
            },
            ']' => {
                in_class = false;
                try escaped.append(rt.memory.allocator, byte);
            },
            '/' => {
                if (!in_class) try escaped.append(rt.memory.allocator, '\\');
                try escaped.append(rt.memory.allocator, byte);
            },
            '\n' => try escaped.appendSlice(rt.memory.allocator, "\\n"),
            '\r' => try escaped.appendSlice(rt.memory.allocator, "\\r"),
            else => try escaped.append(rt.memory.allocator, byte),
        }
    }
    return createStringValue(rt, escaped.items);
}

fn regexpSourceCanReturnRaw(source: core.JSValue) bool {
    const header = source.refHeader() orelse return false;
    if (!source.isString()) return false;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    if (string_value.len() == 0) return false;
    var in_class = false;
    var index: usize = 0;
    while (index < string_value.len()) : (index += 1) {
        const unit = string_value.codeUnitAt(index);
        switch (unit) {
            '[' => in_class = true,
            ']' => in_class = false,
            '/' => if (!in_class) return false,
            '\n', '\r', 0x2028, 0x2029 => return false,
            else => {},
        }
    }
    return true;
}

pub fn escape(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    if (args.len < 1 or !args[0].isString()) return error.TypeError;

    const input = try expectString(args[0]);
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);

    switch (input.resolveData()) {
        .latin1 => |bytes| {
            for (bytes, 0..) |byte, index| try appendEscapedCodeUnit(rt, &buffer, byte, index == 0);
        },
        .utf16 => |units| {
            var index: usize = 0;
            while (index < units.len) {
                const unit = units[index];
                if (isHighSurrogate(unit)) {
                    if (index + 1 < units.len and isLowSurrogate(units[index + 1])) {
                        const cp = surrogateCodePoint(unit, units[index + 1]);
                        try appendUtf8CodePoint(rt, &buffer, cp);
                        index += 2;
                        continue;
                    }
                    try appendUnicodeEscape(rt, &buffer, unit);
                } else if (isLowSurrogate(unit)) {
                    try appendUnicodeEscape(rt, &buffer, unit);
                } else {
                    try appendEscapedCodeUnit(rt, &buffer, unit, index == 0);
                }
                index += 1;
            }
        },
    }

    const output = try core.string.String.createUtf8(rt, buffer.items);
    return output.value();
}

fn toString(rt: *core.JSRuntime, object: *core.Object) !core.JSValue {
    const source = try getInternalSource(object);
    defer source.free(rt);
    const flags = try getInternalFlags(object);
    defer flags.free(rt);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try buffer.append(rt.memory.allocator, '/');
    try appendValueString(rt, &buffer, source);
    try buffer.append(rt.memory.allocator, '/');
    try appendCanonicalRegExpFlags(rt, &buffer, flags);

    const str = try core.string.String.createUtf8(rt, buffer.items);
    return str.value();
}

fn canonicalFlagsValue(rt: *core.JSRuntime, flags: core.JSValue) !core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendCanonicalRegExpFlags(rt, &buffer, flags);
    return createStringValue(rt, buffer.items);
}

fn appendCanonicalRegExpFlags(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), flags: core.JSValue) !void {
    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(rt.memory.allocator);
    try appendValueString(rt, &raw, flags);
    const order = "dgimsuvy";
    for (order) |flag| {
        if (std.mem.indexOfScalar(u8, raw.items, flag) != null) try buffer.append(rt.memory.allocator, flag);
    }
}

fn expectRegExpObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.regexp) return error.TypeError;
    return object;
}

fn expectString(value: core.JSValue) !*core.string.String {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isString()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn createStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const str = if (isAsciiBytes(bytes))
        try core.string.String.createAscii(rt, bytes)
    else
        try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

fn isAsciiBytes(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

fn getInternalSource(object: *core.Object) !core.JSValue {
    return (object.regexpSource() orelse return error.TypeError).dup();
}

fn getInternalFlags(object: *core.Object) !core.JSValue {
    return (object.regexpFlags() orelse return error.TypeError).dup();
}

fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void {
    if (value.asInt32()) |int_value| {
        var int_buf: [32]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{int_value});
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asFloat64()) |float_value| {
        if (std.math.isNan(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "NaN");
        } else if (std.math.isPositiveInf(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "Infinity");
        } else if (std.math.isNegativeInf(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "-Infinity");
        } else if (std.math.isNegativeZero(float_value)) {
            try buffer.append(rt.memory.allocator, '0');
        } else {
            var float_buf: [64]u8 = undefined;
            const printed = try std.fmt.bufPrint(&float_buf, "{d}", .{float_value});
            try buffer.appendSlice(rt.memory.allocator, printed);
        }
    } else if (value.isBigInt()) {
        try core.value_format.appendBigIntBase10(rt.memory.allocator, buffer, value);
    } else if (value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    } else if (value.isUndefined()) {
        try buffer.appendSlice(rt.memory.allocator, "undefined");
    } else if (value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
    } else if (value.isString()) {
        try appendRawString(rt, buffer, value);
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.string) {
            const data = object_value.objectData() orelse return error.TypeError;
            try appendValueString(rt, buffer, data);
        } else if (object_value.class_id == core.class.ids.array_buffer) {
            try buffer.appendSlice(rt.memory.allocator, "[object ArrayBuffer]");
        } else if (object_value.class_id == core.class.ids.promise) {
            try buffer.appendSlice(rt.memory.allocator, "[object Promise]");
        } else if (object_value.is_array) {
            try appendArrayString(rt, buffer, object_value);
        } else {
            try buffer.appendSlice(rt.memory.allocator, "[object Object]");
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "[object Object]");
    }
}

fn appendRawString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            for (bytes) |byte| try appendUtf8CodePoint(rt, buffer, byte);
        },
        .utf16 => |units| try appendUtf16AsUtf8(rt, buffer, units),
    }
}

fn appendRegExpPatternString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue, flags: []const u8) !void {
    _ = flags;
    try appendValueString(rt, buffer, value);
}

fn appendArrayString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object) AppendStringError!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn regexpFlagChar(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "global")) return 'g';
    if (std.mem.eql(u8, name, "ignoreCase")) return 'i';
    if (std.mem.eql(u8, name, "multiline")) return 'm';
    if (std.mem.eql(u8, name, "dotAll")) return 's';
    if (std.mem.eql(u8, name, "unicode")) return 'u';
    if (std.mem.eql(u8, name, "sticky")) return 'y';
    if (std.mem.eql(u8, name, "hasIndices")) return 'd';
    if (std.mem.eql(u8, name, "unicodeSets")) return 'v';
    return null;
}

fn appendEscapedCodeUnit(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), unit: u16, is_first: bool) !void {
    if (unit <= 0x7f) {
        const byte: u8 = @intCast(unit);
        if (is_first and isAsciiAlphaNumeric(byte)) return appendHexEscape(rt, buffer, byte);
        if (syntaxEscapeChar(byte)) {
            try buffer.append(rt.memory.allocator, '\\');
            try buffer.append(rt.memory.allocator, byte);
            return;
        }
        if (controlEscapeChar(byte)) |escaped| {
            try buffer.append(rt.memory.allocator, '\\');
            try buffer.append(rt.memory.allocator, escaped);
            return;
        }
        if (byte == ' ' or otherPunctuator(byte)) return appendHexEscape(rt, buffer, byte);
        try buffer.append(rt.memory.allocator, byte);
        return;
    }

    if (isEscapedWhitespaceOrLineTerminator(unit)) {
        if (unit <= 0xff) return appendHexEscape(rt, buffer, @intCast(unit));
        return appendUnicodeEscape(rt, buffer, unit);
    }
    try appendUtf8CodePoint(rt, buffer, unit);
}

fn appendHexEscape(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), byte: u8) !void {
    try buffer.appendSlice(rt.memory.allocator, "\\x");
    try appendHexByte(rt, buffer, byte);
}

fn appendUnicodeEscape(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), unit: u16) !void {
    try buffer.appendSlice(rt.memory.allocator, "\\u");
    try appendHexByte(rt, buffer, @intCast(unit >> 8));
    try appendHexByte(rt, buffer, @intCast(unit & 0xff));
}

fn appendHexByte(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), byte: u8) !void {
    const hex = "0123456789abcdef";
    try buffer.append(rt.memory.allocator, hex[byte >> 4]);
    try buffer.append(rt.memory.allocator, hex[byte & 0x0f]);
}

fn appendUtf8CodePoint(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), cp: u32) !void {
    if (cp <= 0x7f) {
        try buffer.append(rt.memory.allocator, @intCast(cp));
    } else if (cp <= 0x7ff) {
        try buffer.append(rt.memory.allocator, @intCast(0xc0 | (cp >> 6)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    } else if (cp <= 0xffff) {
        try buffer.append(rt.memory.allocator, @intCast(0xe0 | (cp >> 12)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    } else {
        try buffer.append(rt.memory.allocator, @intCast(0xf0 | (cp >> 18)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 12) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    }
}

fn appendUtf16AsUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void {
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const unit = units[index];
        if (isHighSurrogate(unit) and index + 1 < units.len and isLowSurrogate(units[index + 1])) {
            try appendUtf8CodePoint(rt, buffer, surrogateCodePoint(unit, units[index + 1]));
            index += 1;
            continue;
        }
        try appendUtf8CodePoint(rt, buffer, unit);
    }
}

fn isAsciiAlphaNumeric(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}

fn syntaxEscapeChar(byte: u8) bool {
    return switch (byte) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
        else => false,
    };
}

fn controlEscapeChar(byte: u8) ?u8 {
    return switch (byte) {
        '\t' => 't',
        '\n' => 'n',
        0x0b => 'v',
        '\x0c' => 'f',
        '\r' => 'r',
        else => null,
    };
}

fn otherPunctuator(byte: u8) bool {
    return switch (byte) {
        ',', '-', '=', '<', '>', '#', '&', '!', '%', ':', ';', '@', '~', '\'', '`', '"' => true,
        else => false,
    };
}

fn isEscapedWhitespaceOrLineTerminator(unit: u16) bool {
    return unit == 0x00a0 or
        unit == 0x1680 or
        (unit >= 0x2000 and unit <= 0x200a) or
        unit == 0x2028 or
        unit == 0x2029 or
        unit == 0x202f or
        unit == 0x205f or
        unit == 0x3000 or
        unit == 0xfeff;
}

fn isHighSurrogate(unit: u16) bool {
    return unit >= 0xd800 and unit <= 0xdbff;
}

fn isLowSurrogate(unit: u16) bool {
    return unit >= 0xdc00 and unit <= 0xdfff;
}

fn surrogateCodePoint(high: u16, low: u16) u32 {
    return 0x10000 + ((@as(u32, high) - 0xd800) << 10) + (@as(u32, low) - 0xdc00);
}
