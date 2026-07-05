const core = @import("../core/root.zig");
const regexp_adapter = @import("../exec/regexp_adapter.zig");
const regexp_lib = @import("../libs/regexp.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const builtin_dispatch = @import("../exec/builtin_dispatch.zig");
const regexp_fastpath = @import("../exec/regexp_fastpath.zig");
const string_ops = @import("../exec/string_ops.zig");
const exceptions = @import("../exec/exceptions.zig");
const bytecode_mod = @import("../bytecode.zig");
const frame_mod = @import("../exec/frame.zig");
const object_ops = @import("../exec/object_ops.zig");
const coercion_ops = @import("../exec/coercion_ops.zig");
const array_ops = @import("../exec/array_ops.zig");
const exception_ops = @import("../exec/vm_exception_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

pub const StaticMethod = core.host_function.builtin_method_ids.regexp.StaticMethod;

// Relocated to engine core (`core/host_function.zig`, next to
// `builtin_method_ids.regexp.StaticMethod`) in Phase 6b-3e so the VM construct
// dispatchers can gate on the construct id without importing builtins;
// re-exported here so the install/dispatch side keeps the original name.
pub const ConstructorMethod = core.host_function.builtin_method_ids.regexp.ConstructorMethod;

pub const PrototypeMethod = core.host_function.builtin_method_ids.regexp.PrototypeMethod;

pub const AccessorMethod = core.host_function.builtin_method_ids.regexp.AccessorMethod;

pub const LegacyAccessorMethod = core.host_function.builtin_method_ids.regexp.LegacyAccessorMethod;

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

// Pure accessor/legacy-accessor id<->name(/kind) mappers relocated to engine
// core (`core/host_function.zig`, `builtin_method_id_lookup.regexp`) in Phase
// 6b-3 STEP 5B so exec's RegExp accessor cascade dispatches by id without
// naming this builtin; re-exported here for the install/dispatch side.
pub const accessorMethodId = core.host_function.builtin_method_id_lookup.regexp.accessorMethodId;
pub const accessorNameFromId = core.host_function.builtin_method_id_lookup.regexp.accessorNameFromId;
pub const accessorNameFromGetterName = core.host_function.builtin_method_id_lookup.regexp.accessorNameFromGetterName;
pub const legacyAccessorMethodFromId = core.host_function.builtin_method_id_lookup.regexp.legacyAccessorMethodFromId;
pub const legacyCaptureIndex = core.host_function.builtin_method_id_lookup.regexp.legacyCaptureIndex;

/// Declaration + dispatch table for the `.regexp` native-builtin domain
/// (QuickJS js_regexp_funcs / js_regexp_proto_funcs analogue). One shared
/// record handler `regexpCall` switches on the per-record `magic` (== the
/// domain-local id, i.e. the `StaticMethod`/`ConstructorMethod`/`PrototypeMethod`/
/// `AccessorMethod`/`LegacyAccessorMethod` enum value) and mirrors the retired
/// `call.zig` `callRegExpNativeFunctionRecord` exactly: the constructor, the
/// exec/test/compile prototype methods and every accessor delegate to the
/// `regexp_fastpath.zig` VM ops, the `Symbol.*` and `toString` prototype methods
/// delegate to `string_ops.zig`, and `RegExp.escape` plus the accessor
/// primitive-only fallback run in this module. Those exec ops STAY in exec
/// because the RegExp fast-path opcode handlers (`vm_call.zig`,
/// `call_runtime.zig`) and the matcher fast path also call them directly; the
/// `Symbol.*` helpers additionally back `String.prototype.{match,replace,split,
/// search,matchAll}` (BOTH — kept in exec, reused through a thin entry here).
/// Property installation still resolves names/lengths through the registry's
/// `regexp_prototype` Method table plus the `prototypeMethodId`/`accessorMethodId`/
/// `LegacyAccessorMethod` id helpers above (like Date); this table is consumed
/// only by the slow record-dispatch path (`rt.internal_builtins`).
/// `prepared_call_ok` mirrors the prepared-call gate in `vm_call.zig`
/// (`nativeBuiltinSupportedWithoutFunctionObject`): only `RegExp.prototype.test`
/// and `RegExp.prototype.exec` are callable without a materialized function
/// object today.
pub const internal_entries = regexpEntries: {
    const Entry = core.host_function.InternalEntry;
    break :regexpEntries [_]Entry{
        // Constructor + static.
        regexpConstructorEntry("RegExp", 2, @intFromEnum(ConstructorMethod.construct)),
        regexpEntry("escape", 1, @intFromEnum(StaticMethod.escape), false),
        // Prototype methods (the subset `prototypeMethodId` maps and
        // `decodePrototypeMethodId` decodes).
        regexpEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string), false),
        regexpEntry("test", 1, @intFromEnum(PrototypeMethod.test_), true),
        regexpEntry("exec", 1, @intFromEnum(PrototypeMethod.exec), true),
        regexpEntry("[Symbol.search]", 1, @intFromEnum(PrototypeMethod.symbol_search), false),
        regexpEntry("[Symbol.match]", 1, @intFromEnum(PrototypeMethod.symbol_match), false),
        regexpEntry("[Symbol.matchAll]", 1, @intFromEnum(PrototypeMethod.symbol_match_all), false),
        regexpEntry("[Symbol.replace]", 2, @intFromEnum(PrototypeMethod.symbol_replace), false),
        regexpEntry("[Symbol.split]", 2, @intFromEnum(PrototypeMethod.symbol_split), false),
        regexpEntry("compile", 2, @intFromEnum(PrototypeMethod.compile), false),
        // Flag/source accessor getters.
        regexpEntry("get source", 0, @intFromEnum(AccessorMethod.source), false),
        regexpEntry("get flags", 0, @intFromEnum(AccessorMethod.flags), false),
        regexpEntry("get global", 0, @intFromEnum(AccessorMethod.global), false),
        regexpEntry("get ignoreCase", 0, @intFromEnum(AccessorMethod.ignore_case), false),
        regexpEntry("get multiline", 0, @intFromEnum(AccessorMethod.multiline), false),
        regexpEntry("get dotAll", 0, @intFromEnum(AccessorMethod.dot_all), false),
        regexpEntry("get unicode", 0, @intFromEnum(AccessorMethod.unicode), false),
        regexpEntry("get sticky", 0, @intFromEnum(AccessorMethod.sticky), false),
        regexpEntry("get hasIndices", 0, @intFromEnum(AccessorMethod.has_indices), false),
        regexpEntry("get unicodeSets", 0, @intFromEnum(AccessorMethod.unicode_sets), false),
        // Legacy static RegExp accessors (input/$_, lastMatch, capture groups).
        regexpEntry("get input", 0, @intFromEnum(LegacyAccessorMethod.get_input), false),
        regexpEntry("set input", 1, @intFromEnum(LegacyAccessorMethod.set_input), false),
        regexpEntry("get lastMatch", 0, @intFromEnum(LegacyAccessorMethod.get_last_match), false),
        regexpEntry("get lastParen", 0, @intFromEnum(LegacyAccessorMethod.get_last_paren), false),
        regexpEntry("get leftContext", 0, @intFromEnum(LegacyAccessorMethod.get_left_context), false),
        regexpEntry("get rightContext", 0, @intFromEnum(LegacyAccessorMethod.get_right_context), false),
        regexpEntry("get $1", 0, @intFromEnum(LegacyAccessorMethod.get_capture_1), false),
        regexpEntry("get $2", 0, @intFromEnum(LegacyAccessorMethod.get_capture_2), false),
        regexpEntry("get $3", 0, @intFromEnum(LegacyAccessorMethod.get_capture_3), false),
        regexpEntry("get $4", 0, @intFromEnum(LegacyAccessorMethod.get_capture_4), false),
        regexpEntry("get $5", 0, @intFromEnum(LegacyAccessorMethod.get_capture_5), false),
        regexpEntry("get $6", 0, @intFromEnum(LegacyAccessorMethod.get_capture_6), false),
        regexpEntry("get $7", 0, @intFromEnum(LegacyAccessorMethod.get_capture_7), false),
        regexpEntry("get $8", 0, @intFromEnum(LegacyAccessorMethod.get_capture_8), false),
        regexpEntry("get $9", 0, @intFromEnum(LegacyAccessorMethod.get_capture_9), false),
    };
};

fn regexpEntry(comptime name: []const u8, comptime length: u8, comptime id: u32, comptime prepared: bool) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = prepared, .call = &regexpCall };
}

/// The RegExp constructor record: construct-capable so `new RegExp(...)`
/// routes through the construct dispatch path into `regexpCall`'s construct
/// branch.
fn regexpConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .constructor = true, .call = &regexpCall };
}

/// Shared record handler for the `.regexp` domain. Mirrors the retired
/// `call.zig` `callRegExpNativeFunctionRecord`: the constructor, the
/// exec/test/compile prototype methods and the accessors delegate to the
/// `regexp_fastpath.zig` VM ops (which fall back to `accessor` below when the
/// fast path returns null), the `Symbol.*` and `toString` prototype methods
/// delegate to `string_ops.zig`, and `RegExp.escape` runs in this module. All
/// of those exec ops stay in exec because the RegExp opcode handlers and the
/// matcher fast path also call them.
fn regexpCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const output = host_call.output;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const this_value = host_call.this_value;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (id == @intFromEnum(ConstructorMethod.construct)) {
        // `new RegExp(pattern, flags)` arrives through the construct record
        // path with `flags.constructor` set and the resolved instance prototype
        // in `new_target`. The construct branch reads only `args`/`new_target`,
        // so it runs before the `func_obj` requirement below: the VM construct
        // fast path (`regexp_fastpath.qjsRegExpConstructCall`) routes its
        // coerced terminal here without a materialized constructor object.
        // `RegExp(...)` called as a function routes through the fast-path call
        // op (which itself handles the "return the argument unchanged when it is
        // already a RegExp and no flags are given" call-only behavior).
        if (host_call.flags.constructor) {
            const rt = ctx.runtime;
            const pattern = if (args.len >= 1) args[0] else try createStringValue(rt, "");
            defer if (args.len < 1) pattern.free(rt);
            const flags = if (args.len >= 2) args[1] else try createStringValue(rt, "");
            defer if (args.len < 2) flags.free(rt);
            return constructWithPrototype(rt, pattern, flags, host_call.new_target);
        }
        const active_global = host_call.global orelse return error.TypeError;
        return regexp_fastpath.qjsRegExpFunctionCall(ctx, output, active_global, args, caller_function, caller_frame);
    }

    const function_object = host_call.func_obj orelse return error.TypeError;
    if (id == @intFromEnum(StaticMethod.escape)) return escape(ctx.runtime, args);
    if (legacyAccessorMethodFromId(id)) |method| {
        const active_global = host_call.global orelse return error.TypeError;
        return regexp_fastpath.qjsRegExpLegacyAccessor(ctx, output, active_global, this_value, function_object, method, args, caller_function, caller_frame);
    }
    if (accessorNameFromId(id) != null) {
        const active_global = host_call.global orelse return error.TypeError;
        return accessorCallById(ctx, output, active_global, this_value, function_object, id, caller_function, caller_frame);
    }
    const method_id = decodePrototypeMethodId(id) orelse return error.TypeError;
    // `compile` resolves the global through the function object's realm first
    // (matching the retired call.zig branch); the rest take `host_call.global`.
    if (method_id == 9) {
        const compile_global = function_object.functionRealmGlobalPtr() orelse host_call.global orelse return error.TypeError;
        return (try regexp_fastpath.qjsRegExpCompile(ctx, output, compile_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError;
    }
    const active_global = host_call.global orelse return error.TypeError;
    return switch (method_id) {
        1 => string_ops.qjsRegExpToString(ctx, output, active_global, this_value, caller_function, caller_frame),
        2 => (try regexp_fastpath.qjsRegExpTestMethod(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        3 => (try regexp_fastpath.qjsRegExpExecMethod(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        4 => (try string_ops.qjsRegExpSymbolSearch(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        5 => (try string_ops.qjsRegExpSymbolMatch(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        6 => (try string_ops.qjsRegExpSymbolMatchAll(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        7 => (try string_ops.qjsRegExpSymbolReplace(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        8 => (try string_ops.qjsRegExpSymbolSplit(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        else => error.TypeError,
    };
}

/// QuickJS source map: narrow RegExp constructor payload used by transitional
/// `new_regexp` bytecode.
pub fn construct(rt: *core.JSRuntime, pattern: core.JSValue, flags: core.JSValue) !core.JSValue {
    return constructWithPrototype(rt, pattern, flags, null);
}

pub fn constructLiteral(rt: *core.JSRuntime, pattern: []const u8, flags: []const u8, prototype: ?*core.Object) !core.JSValue {
    var compiled = compilePatternAndFlagsSyntax(rt, pattern, flags) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return error.SyntaxError,
        else => |other| return other,
    };
    defer compiled.deinit(rt.memory.allocator);

    var source_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &source_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer source_val.free(rt);

    source_val = (try core.string.String.createUtf8(rt, pattern)).value();

    return constructCompiled(rt, source_val, compiled.bytecode, prototype);
}

pub fn constructLiteralWithValues(
    rt: *core.JSRuntime,
    source: core.JSValue,
    stored_flags: core.JSValue,
    pattern: []const u8,
    flags: []const u8,
    prototype: ?*core.Object,
) !core.JSValue {
    _ = stored_flags;
    var compiled = compilePatternAndFlagsSyntax(rt, pattern, flags) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return error.SyntaxError,
        else => |other| return other,
    };
    defer compiled.deinit(rt.memory.allocator);
    return constructCompiled(rt, source, compiled.bytecode, prototype);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, pattern: core.JSValue, flags: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    if (flags.isUndefined()) {
        if (regexpObjectFromValue(pattern)) |regexp_object| {
            const source_val = try getInternalSource(regexp_object);
            defer source_val.free(rt);
            const bytecode = regexp_object.regexpCompiledBytecode();
            if (bytecode.len == 0) return error.TypeError;
            return constructCompiled(rt, source_val, bytecode, prototype);
        }
    }

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
        try getInternalFlags(rt, pattern_object.?)
    else if (flags.isUndefined())
        try createStringValue(rt, "")
    else
        try regExpStringValue(rt, flags);

    var compiled = try compileSourceAndFlags(rt, source_val, flags_val);
    defer compiled.deinit(rt.memory.allocator);

    return constructCompiled(rt, source_val, compiled.bytecode, prototype);
}

fn regExpStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isString()) return value.dup();
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, value);
    return try createStringValue(rt, bytes.items);
}

fn compilePatternAndFlagsSyntax(rt: *core.JSRuntime, pattern: []const u8, flags: []const u8) !regexp_lib.Compiled {
    return regexp_lib.compilePatternAndFlags(rt.memory.allocator, pattern, flags);
}

fn compileSourceAndFlags(rt: *core.JSRuntime, source: core.JSValue, flags: core.JSValue) !regexp_lib.Compiled {
    var flag_bytes = std.ArrayList(u8).empty;
    defer flag_bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &flag_bytes, flags);

    var source_bytes = std.ArrayList(u8).empty;
    defer source_bytes.deinit(rt.memory.allocator);
    try appendRegExpPatternString(rt, &source_bytes, source, flag_bytes.items);

    return compilePatternAndFlagsSyntax(rt, source_bytes.items, flag_bytes.items) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return error.SyntaxError,
        else => |other| return other,
    };
}

fn constructCompiled(rt: *core.JSRuntime, source: core.JSValue, bytecode: []const u8, prototype: ?*core.Object) !core.JSValue {
    var source_val = source;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &source_val },
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
    try object.setRegexpCompiledBytecode(rt, bytecode);
    try object.setOptionalValueSlot(rt, object.regexpLastIndexSlot(), core.JSValue.int32(0));
    object.regexpLastIndexWritableSlot().* = true;
    return object.value();
}

test "constructCompiled roots source while creating regexp object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source_atom = try rt.atoms.newValueSymbol("gc-regexp-source-symbol");
    const source_value = try rt.symbolValue(source_atom);
    var compiled = try regexp_lib.compilePatternAndFlags(rt.memory.allocator, "a", "g");
    defer compiled.deinit(rt.memory.allocator);
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const regexp_value = try constructCompiled(rt, source_value, compiled.bytecode, null);
    var regexp_alive = true;
    defer if (regexp_alive) regexp_value.free(rt);
    const regexp = regexpObjectFromValue(regexp_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(source_atom) != null);
    try std.testing.expect(regexp.regexpSource().?.same(source_value));
    try std.testing.expect(regexp.regexpCompiledBytecode().len != 0);

    regexp_value.free(rt);
    regexp_alive = false;
    source_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(source_atom) == null);
}

/// Pattern/flags early-error validation lives in `libs/regexp.zig`
/// (QuickJS: `js_compile_regexp` flag parsing plus `lre_compile`).
pub const compilePatternAndFlags = regexp_lib.compilePatternAndFlags;

fn isSimpleGlobalClassEscapePattern(pattern: []const u8, flags: []const u8) bool {
    if (flags.len != 1 or flags[0] != 'g') return false;
    if (pattern.len != 3 or pattern[0] != '\\' or pattern[2] != '+') return false;
    return switch (pattern[1]) {
        'd', 'D', 's', 'S', 'w', 'W' => true,
        else => false,
    };
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
            if (index.* + 2 >= pattern.len or !unicode.isAsciiAlphaByte(pattern[index.* + 2])) return true;
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
            if (index.* + 2 < pattern.len and unicode.isAsciiDigitByte(pattern[index.* + 2])) return true;
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
    while (scan < pattern.len and unicode.isAsciiDigitByte(pattern[scan])) : (scan += 1) {
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
            const digit = unicode.asciiHexDigitValueByte(pattern[scan]) orelse return true;
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
        if (!unicode.isAsciiHexDigitByte(pattern[start + offset])) return false;
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
    if (start + 1 >= pattern.len or pattern[start] != '{' or !unicode.isAsciiDigitByte(pattern[start + 1])) return null;
    var index = start + 1;
    const min_start = index;
    while (index < pattern.len and unicode.isAsciiDigitByte(pattern[index])) : (index += 1) {}
    const min_digits = pattern[min_start..index];

    if (index < pattern.len and pattern[index] == ',') {
        index += 1;
        if (index < pattern.len and unicode.isAsciiDigitByte(pattern[index])) {
            const max_start = index;
            while (index < pattern.len and unicode.isAsciiDigitByte(pattern[index])) : (index += 1) {}
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

// Relocated to engine core (`core/regexp.zig`) in Phase 6b-3 STEP 2: the
// character-class membership predicate and its class-range parsing primitives
// are pure (std + core.unicode + libs/regexp.zig) and are consumed by the
// VM string fast paths without importing builtins. Re-exported here so the
// RegExp pattern validators below (hasDescendingCharacterClassRange /
// scanClassForDescendingRange / hasUnicodeClassEscapeRange / invalidUnicodeEscape)
// keep a single source of truth in core.
pub const classMatchesUtf16Unit = core.regexp.classMatchesUtf16Unit;
const ClassRangeAtom = core.regexp.ClassRangeAtom;
const readClassRangeAtom = core.regexp.readClassRangeAtom;
const isCharacterClassEscape = core.regexp.isCharacterClassEscape;
const consumeUnicodePropertyEscape = core.regexp.consumeUnicodePropertyEscape;

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
            const digit = unicode.asciiHexDigitValueByte(pattern[pos]) orelse return null;
            saw_digit = true;
            if (value > 0x10ffff / 16) return null;
            value = value * 16 + digit;
            if (value > 0x10ffff) return null;
        }
        if (!saw_digit or pos >= pattern.len or pattern[pos] != '}') return null;
        index.* = pos + 1;
        return value;
    }
    if (pos >= pattern.len or !unicode.isAsciiHexDigitByte(pattern[pos])) return null;
    var available_hex: usize = 0;
    while (pos + available_hex < pattern.len and available_hex < 4 and unicode.isAsciiHexDigitByte(pattern[pos + available_hex])) : (available_hex += 1) {}
    if (available_hex == 0) return null;
    const digit_count: usize = if (available_hex >= 4) 4 else available_hex;
    var value: u32 = 0;
    var count: usize = 0;
    while (count < digit_count) : (count += 1) {
        const digit = unicode.asciiHexDigitValueByte(pattern[pos + count]) orelse return null;
        value = value * 16 + digit;
    }
    index.* = pos + digit_count;
    return value;
}

fn isRegExpGroupNameStart(cp: u21) bool {
    if (cp == '$' or cp == '_') return true;
    if (unicode.isAsciiAlphaCodePoint(cp)) return true;
    if (isInvalidRegExpGroupNameStart(cp)) return false;
    return cp > 0x7f;
}

fn isRegExpGroupNameContinue(cp: u21) bool {
    if (isInvalidRegExpGroupNameContinue(cp)) return false;
    if (cp == 0x104a4) return true;
    if (isRegExpGroupNameStart(cp)) return true;
    if (unicode.isAsciiDigitCodePoint(cp)) return true;
    if (cp == 0x1d7da) return true;
    return false;
}

fn isInvalidRegExpGroupNameStart(cp: u21) bool {
    if (unicode.isSurrogateCodePoint(cp)) return true;
    return switch (cp) {
        0x275e, 0x2764, 0x104a4, 0x1f08b, 0x1f415, 0x1f712, 0x1f98a, 0x10ffff => true,
        else => false,
    };
}

fn isInvalidRegExpGroupNameContinue(cp: u21) bool {
    if (unicode.isSurrogateCodePoint(cp)) return true;
    return switch (cp) {
        0x275e, 0x2764, 0x1f08b, 0x1f415, 0x1f712, 0x1f98a, 0x10ffff => true,
        else => false,
    };
}

fn isGroupNameHighSurrogate(cp: u32) bool {
    return cp <= std.math.maxInt(u16) and unicode.isHighSurrogateUnit(@intCast(cp));
}

fn isGroupNameLowSurrogate(cp: u32) bool {
    return cp <= std.math.maxInt(u16) and unicode.isLowSurrogateUnit(@intCast(cp));
}

fn groupNameSurrogateCodePoint(high: u16, low: u16) u21 {
    return unicode.codePointFromSurrogatePair(high, low);
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

/// RegExp.prototype accessor bodies dispatched by the record id (the qjs
/// magic int): js_regexp_get_flag (quickjs.c:47921) for the eight flag
/// getters, js_regexp_get_flags (quickjs.c:47943) for `flags`, and the
/// source getter. The receiver's compiled bytecode is read directly; a
/// non-RegExp receiver resolves only when it is the realm's
/// RegExp.prototype (undefined / "(?:)"), else TypeError — no name-string
/// derivation and no per-call atom interning.
fn accessorCallById(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    caller_function: ?*const bytecode_mod.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    const rt = ctx.runtime;
    // JS_ThrowTypeErrorNotAnObject (js_regexp_get_flag / js_regexp_get_flags).
    if (!this_value.isObject()) return exception_ops.throwTypeErrorMessage(ctx, global, "not an object");

    if (id == @intFromEnum(AccessorMethod.flags)) {
        // js_regexp_get_flags (quickjs.c:47943): generic receiver; observe
        // the eight flag properties through ordinary [[Get]] in canonical
        // order (compile-time atoms, qjs flag_atom[] analogue).
        const flag_atoms = comptime [_]core.Atom{
            core.atom.predefinedId("hasIndices", .string).?,
            core.atom.predefinedId("global", .string).?,
            core.atom.predefinedId("ignoreCase", .string).?,
            core.atom.predefinedId("multiline", .string).?,
            core.atom.predefinedId("dotAll", .string).?,
            core.atom.predefinedId("unicode", .string).?,
            core.atom.predefinedId("unicodeSets", .string).?,
            core.atom.predefinedId("sticky", .string).?,
        };
        const flag_chars = [_]u8{ 'd', 'g', 'i', 'm', 's', 'u', 'v', 'y' };
        var str: [flag_chars.len]u8 = undefined;
        var count: usize = 0;
        for (flag_atoms, flag_chars) |flag_atom, flag_char| {
            const value = try object_ops.getValueProperty(ctx, output, global, this_value, flag_atom, caller_function, caller_frame);
            defer value.free(rt);
            if (coercion_ops.valueTruthy(value)) {
                str[count] = flag_char;
                count += 1;
            }
        }
        return createStringValue(rt, str[0..count]);
    }

    const header = this_value.refHeader() orelse return error.TypeError;
    const receiver: *core.Object = @fieldParentPtr("header", header);
    const maybe_bits: ?u16 = if (receiver.class_id == core.class.ids.regexp)
        (regexpFlagBits(receiver) catch null)
    else
        null;
    if (maybe_bits) |bits| {
        // js_get_regexp success: read the bit straight off the compiled
        // bytecode (lre_get_flags), or escape the internal source.
        if (id == @intFromEnum(AccessorMethod.source)) {
            return accessor(rt, this_value, "source") catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        const mask = flagMaskFromAccessorId(id) orelse return error.TypeError;
        return core.JSValue.boolean((bits & mask) != 0);
    }
    // js_regexp_get_flag !re branch: the realm's RegExp.prototype reads
    // undefined (source: "(?:)"); any other receiver is invalid.
    if (object_ops.regExpPrototypeFromGlobal(rt, global)) |proto| {
        if (receiver == proto) {
            if (id == @intFromEnum(AccessorMethod.source)) return createStringValue(rt, "(?:)");
            return core.JSValue.undefinedValue();
        }
    }
    _ = try array_ops.throwRegExpAccessorTypeError(ctx, global, function_object.value());
    return error.TypeError;
}

fn flagMaskFromAccessorId(id: u32) ?u16 {
    return switch (id) {
        @intFromEnum(AccessorMethod.global) => regexp_adapter.flag_bits.global,
        @intFromEnum(AccessorMethod.ignore_case) => regexp_adapter.flag_bits.ignore_case,
        @intFromEnum(AccessorMethod.multiline) => regexp_adapter.flag_bits.multiline,
        @intFromEnum(AccessorMethod.dot_all) => regexp_adapter.flag_bits.dot_all,
        @intFromEnum(AccessorMethod.unicode) => regexp_adapter.flag_bits.unicode,
        @intFromEnum(AccessorMethod.sticky) => regexp_adapter.flag_bits.sticky,
        @intFromEnum(AccessorMethod.has_indices) => regexp_adapter.flag_bits.indices,
        @intFromEnum(AccessorMethod.unicode_sets) => regexp_adapter.flag_bits.unicode_sets,
        else => null,
    };
}

pub fn accessor(rt: *core.JSRuntime, object_value: core.JSValue, name: []const u8) !core.JSValue {
    const object = try expectRegExpObject(object_value);
    if (std.mem.eql(u8, name, "source")) {
        const source = try getInternalSource(object);
        defer source.free(rt);
        return escapedSource(rt, source);
    }
    const flag_bits = try regexpFlagBits(object);
    if (std.mem.eql(u8, name, "flags")) return canonicalFlagsValue(rt, flag_bits);

    const present = if (regexpFlagBit(name)) |bit|
        (flag_bits & bit) != 0
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
    const string_value = source.asStringBody() orelse return false;
    if (string_value.len() == 0) return false;
    var in_class = false;
    var index: usize = 0;
    while (index < string_value.len()) : (index += 1) {
        const unit = string_value.codeUnitAt(index);
        switch (unit) {
            '[' => in_class = true,
            ']' => in_class = false,
            '/' => if (!in_class) return false,
            else => if (unicode.isEcmaLineTerminatorUnit(unit)) return false,
        }
    }
    return true;
}

pub fn escape(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    if (args.len < 1 or !args[0].isString()) return error.TypeError;

    const input = try expectString(args[0]);
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);

    try input.ensureFlat(rt);
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
    const flag_bits = try regexpFlagBits(object);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try buffer.append(rt.memory.allocator, '/');
    try appendValueString(rt, &buffer, source);
    try buffer.append(rt.memory.allocator, '/');
    try appendCanonicalRegExpFlags(rt, &buffer, flag_bits);

    const str = try core.string.String.createUtf8(rt, buffer.items);
    return str.value();
}

fn canonicalFlagsValue(rt: *core.JSRuntime, flag_bits: u16) !core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendCanonicalRegExpFlags(rt, &buffer, flag_bits);
    return createStringValue(rt, buffer.items);
}

fn appendCanonicalRegExpFlags(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), flag_bits: u16) !void {
    try regexp_adapter.appendCanonicalFlagsFromBits(rt.memory.allocator, buffer, flag_bits);
}

fn expectRegExpObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.regexp) return error.TypeError;
    return object;
}

fn expectString(value: core.JSValue) !*core.string.String {
    return value.asStringBody() orelse return error.TypeError;
}

fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn createStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const str = if (core.string.isAsciiBytes(bytes))
        try core.string.String.createAscii(rt, bytes)
    else
        try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

fn getInternalSource(object: *core.Object) !core.JSValue {
    return (object.regexpSource() orelse return error.TypeError).dup();
}

fn getInternalFlags(rt: *core.JSRuntime, object: *core.Object) !core.JSValue {
    return regexp_adapter.flagsStringValueFromBytecode(rt, object.regexpCompiledBytecode());
}

fn regexpFlagBits(object: *core.Object) !u16 {
    const bytecode = object.regexpCompiledBytecode();
    if (bytecode.len == 0) return error.TypeError;
    return regexp_adapter.flagBitsFromBytecode(bytecode);
}

fn bytecodeBytesFromValue(rt: *core.JSRuntime, value: core.JSValue) ![]const u8 {
    const string_value = value.asStringBody() orelse return error.TypeError;
    try string_value.ensureFlat(rt);
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| bytes,
        .utf16 => error.TypeError,
    };
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
        } else if (object_value.flags.is_array) {
            try appendArrayString(rt, buffer, object_value);
        } else {
            try buffer.appendSlice(rt.memory.allocator, "[object Object]");
        }
    } else {
        // Only symbols (and future exotic tags) can land here; JS_ToString
        // (js_regexp_constructor quickjs.c:47789 / js_compile_regexp
        // quickjs.c:47578,47627) throws TypeError for them — never a silent
        // '[object Object]' pattern.
        return error.TypeError;
    }
}

fn appendRawString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    const string_value = value.asStringBody() orelse return;
    try string_value.ensureFlat(rt);
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
    while (index < object.arrayLength()) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn regexpFlagBit(name: []const u8) ?u16 {
    if (std.mem.eql(u8, name, "global")) return regexp_adapter.flag_bits.global;
    if (std.mem.eql(u8, name, "ignoreCase")) return regexp_adapter.flag_bits.ignore_case;
    if (std.mem.eql(u8, name, "multiline")) return regexp_adapter.flag_bits.multiline;
    if (std.mem.eql(u8, name, "dotAll")) return regexp_adapter.flag_bits.dot_all;
    if (std.mem.eql(u8, name, "unicode")) return regexp_adapter.flag_bits.unicode;
    if (std.mem.eql(u8, name, "sticky")) return regexp_adapter.flag_bits.sticky;
    if (std.mem.eql(u8, name, "hasIndices")) return regexp_adapter.flag_bits.indices;
    if (std.mem.eql(u8, name, "unicodeSets")) return regexp_adapter.flag_bits.unicode_sets;
    return null;
}

fn appendEscapedCodeUnit(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), unit: u16, is_first: bool) !void {
    if (unit <= 0x7f) {
        const byte: u8 = @intCast(unit);
        if (is_first and unicode.isAsciiAlphanumericByte(byte)) return appendHexEscape(rt, buffer, byte);
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
    try buffer.append(rt.memory.allocator, unicode.asciiLowerHexDigitChar(byte >> 4));
    try buffer.append(rt.memory.allocator, unicode.asciiLowerHexDigitChar(byte & 0x0f));
}

fn appendUtf8CodePoint(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), cp: u32) !void {
    return unicode.appendUtf8CodePoint(rt.memory.allocator, buffer, cp);
}

fn appendUtf16AsUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void {
    return unicode.appendUtf16UnitsAsUtf8(rt.memory.allocator, buffer, units);
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
    return unit > 0x7f and unicode.isEcmaWhitespaceOrLineTerminatorUnit(unit);
}

fn isHighSurrogate(unit: u16) bool {
    return unicode.isHighSurrogateUnit(unit);
}

fn isLowSurrogate(unit: u16) bool {
    return unicode.isLowSurrogateUnit(unit);
}

fn surrogateCodePoint(high: u16, low: u16) u32 {
    return @intCast(unicode.codePointFromSurrogatePair(high, low));
}
