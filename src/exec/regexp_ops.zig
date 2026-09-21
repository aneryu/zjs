//! RegExp constructor/prototype records, compilation, accessors, and escape.
//!
//! Receiver and argument values are borrowed; returned JSValues are owned, and
//! temporary source/flag strings plus compiled buffers are released locally.
//! The matching engine remains in `libs/regexp.zig`; VM/string observable
//! integration stays behind `zig` and `string_ops.zig` rather
//! than being folded into these builtin bodies. QuickJS mappings include the
//! constructor at quickjs.c, flags access at quickjs.c, and
//! compilation/error handling at quickjs.c.

const core = @import("../core/root.zig");

const regexp_lib = @import("../libs/regexp.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const builtin_dispatch = @import("builtin_dispatch.zig");
const bytecode_mod = @import("../bytecode.zig");
const method_ids = core.host_function.builtin_method_ids;
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");

const string_ops = @import("string_ops.zig");
const exceptions = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const coercion_ops = @import("value_ops.zig");
const array_ops = @import("array_ops.zig");
const exception_ops = @import("exception_ops.zig");
const value_ops = @import("value_ops.zig");

const HostError = exceptions.HostError;

const AppendStringError = core.value_string.AppendStringError;

pub const StaticMethod = core.host_function.builtin_method_ids.regexp.StaticMethod;

// Relocated to engine core (`core/host_function.zig`, next to
// `builtin_method_ids.regexp.StaticMethod`) in Phase 6b-3e so the VM construct
// dispatchers can gate on the construct id without importing this operation Module;
// re-exported here so the install/dispatch side keeps the original name.
pub const ConstructorMethod = core.host_function.builtin_method_ids.regexp.ConstructorMethod;

pub const PrototypeMethod = core.host_function.builtin_method_ids.regexp.PrototypeMethod;

pub const AccessorMethod = core.host_function.builtin_method_ids.regexp.AccessorMethod;

pub const LegacyAccessorMethod = core.host_function.builtin_method_ids.regexp.LegacyAccessorMethod;

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
/// `zig` VM ops, the `Symbol.*` and `toString` prototype methods
/// delegate to `string_ops.zig`, and `RegExp.escape` plus the accessor
/// primitive-only fallback run in this module. Those exec ops STAY in exec
/// because the RegExp fast-path opcode handlers (`vm_call.zig`,
/// `call_runtime.zig`) and the matcher fast path also call them directly; the
/// `Symbol.*` helpers additionally back `String.prototype.{match,replace,split,
/// search,matchAll}` (BOTH — kept in exec, reused through a thin entry here).
/// Property installation resolves names/lengths through the standard-global
/// RegExp function list plus the `prototypeMethodId`/`accessorMethodId`/
/// `LegacyAccessorMethod` id helpers above (like Date); this table is consumed
/// by the record-dispatch path (`rt.internal_builtins`).
pub const internal_entries = regexpEntries: {
    const Entry = core.host_function.InternalEntry;
    break :regexpEntries [_]Entry{
        // Constructor + static.
        regexpConstructorEntry("RegExp", 2, @intFromEnum(ConstructorMethod.construct)),
        regexpEntry("escape", 1, @intFromEnum(StaticMethod.escape)),
        // Prototype methods (the subset `prototypeMethodId` maps and
        // `decodePrototypeMethodId` decodes).
        regexpEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
        regexpEntry("test", 1, @intFromEnum(PrototypeMethod.test_)),
        regexpGenericEntry("exec", 1, @intFromEnum(PrototypeMethod.exec), &regexpExecCall),
        regexpEntry("[Symbol.search]", 1, @intFromEnum(PrototypeMethod.symbol_search)),
        regexpGenericEntry("[Symbol.match]", 1, @intFromEnum(PrototypeMethod.symbol_match), &regexpSymbolMatchCall),
        regexpEntry("[Symbol.matchAll]", 1, @intFromEnum(PrototypeMethod.symbol_match_all)),
        regexpEntry("[Symbol.replace]", 2, @intFromEnum(PrototypeMethod.symbol_replace)),
        regexpGenericEntry("[Symbol.split]", 2, @intFromEnum(PrototypeMethod.symbol_split), &regexpSymbolSplitCall),
        regexpEntry("compile", 2, @intFromEnum(PrototypeMethod.compile)),
        // Flag/source accessor getters.
        regexpGetterEntry("get source", @intFromEnum(AccessorMethod.source), &regexpSourceAccessorCall),
        regexpGetterEntry("get flags", @intFromEnum(AccessorMethod.flags), &regexpFlagsAccessorCall),
        regexpFlagGetterEntry("get global", @intFromEnum(AccessorMethod.global), .{ .global = true }),
        regexpFlagGetterEntry("get ignoreCase", @intFromEnum(AccessorMethod.ignore_case), .{ .ignore_case = true }),
        regexpFlagGetterEntry("get multiline", @intFromEnum(AccessorMethod.multiline), .{ .multiline = true }),
        regexpFlagGetterEntry("get dotAll", @intFromEnum(AccessorMethod.dot_all), .{ .dot_all = true }),
        regexpFlagGetterEntry("get unicode", @intFromEnum(AccessorMethod.unicode), .{ .unicode = true }),
        regexpFlagGetterEntry("get sticky", @intFromEnum(AccessorMethod.sticky), .{ .sticky = true }),
        regexpFlagGetterEntry("get hasIndices", @intFromEnum(AccessorMethod.has_indices), .{ .indices = true }),
        regexpFlagGetterEntry("get unicodeSets", @intFromEnum(AccessorMethod.unicode_sets), .{ .unicode_sets = true }),
        // Legacy static RegExp accessors (input/$_, lastMatch, capture groups).
        regexpEntry("get input", 0, @intFromEnum(LegacyAccessorMethod.get_input)),
        regexpEntry("set input", 1, @intFromEnum(LegacyAccessorMethod.set_input)),
        regexpEntry("get lastMatch", 0, @intFromEnum(LegacyAccessorMethod.get_last_match)),
        regexpEntry("get lastParen", 0, @intFromEnum(LegacyAccessorMethod.get_last_paren)),
        regexpEntry("get leftContext", 0, @intFromEnum(LegacyAccessorMethod.get_left_context)),
        regexpEntry("get rightContext", 0, @intFromEnum(LegacyAccessorMethod.get_right_context)),
        regexpEntry("get $1", 0, @intFromEnum(LegacyAccessorMethod.get_capture_1)),
        regexpEntry("get $2", 0, @intFromEnum(LegacyAccessorMethod.get_capture_2)),
        regexpEntry("get $3", 0, @intFromEnum(LegacyAccessorMethod.get_capture_3)),
        regexpEntry("get $4", 0, @intFromEnum(LegacyAccessorMethod.get_capture_4)),
        regexpEntry("get $5", 0, @intFromEnum(LegacyAccessorMethod.get_capture_5)),
        regexpEntry("get $6", 0, @intFromEnum(LegacyAccessorMethod.get_capture_6)),
        regexpEntry("get $7", 0, @intFromEnum(LegacyAccessorMethod.get_capture_7)),
        regexpEntry("get $8", 0, @intFromEnum(LegacyAccessorMethod.get_capture_8)),
        regexpEntry("get $9", 0, @intFromEnum(LegacyAccessorMethod.get_capture_9)),
    };
};

fn regexpEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&regexpCall),
    };
}

fn regexpGenericEntry(
    comptime name: []const u8,
    comptime length: u8,
    comptime id: u32,
    comptime implementation: core.host_function.NativeGenericFn,
) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = 0,
        .cproto = .generic,
        .native_function = .{ .generic = implementation },
    };
}

/// QuickJS gives `flags` and `source` distinct getter functions and shares only
/// the eight boolean flag getters through `JS_CGETSET_MAGIC_DEF`. Preserve that
/// call shape here: the record id still names the installed builtin while
/// `magic` carries the compiled regexp flag mask, exactly like QuickJS.
fn regexpGetterEntry(
    comptime name: []const u8,
    comptime id: u32,
    comptime implementation: core.host_function.NativeGetterFn,
) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = 0,
        .id = id,
        .magic = 0,
        .cproto = .getter,
        .native_function = .{ .getter = implementation },
    };
}

fn regexpFlagGetterEntry(comptime name: []const u8, comptime id: u32, comptime flag: Flags) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = 0,
        .id = id,
        .magic = flag.bits(),
        .cproto = .getter_magic,
        .native_function = .{ .getter_magic = &regexpFlagAccessorCall },
    };
}

/// The RegExp constructor record: construct-capable so `new RegExp(...)`
/// routes through the construct dispatch path into `regexpCall`'s construct
/// branch.
fn regexpConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .constructor_or_func_magic,
        .native_function = builtin_dispatch.constructorOrFunctionMagic(&regexpCall),
    };
}

/// Shared record handler for the `.regexp` domain. Mirrors the retired
/// `call.zig` `callRegExpNativeFunctionRecord`: the constructor, the
/// exec/test/compile prototype methods and the accessors delegate to the
/// `zig` VM ops (which fall back to `accessor` below when the
/// fast path returns null), the `Symbol.*` and `toString` prototype methods
/// delegate to `string_ops.zig`, and `RegExp.escape` runs in this module. All
/// of those exec ops stay in exec because the RegExp opcode handlers and the
/// matcher fast path also call them.
fn regexpCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const callable_global: ?*core.Object = if (host_call.func_obj != null) blk: {
        const realm = try builtin_dispatch.callableRealm(host_call);
        std.debug.assert(realm.realm == ctx);
        break :blk realm.global;
    } else host_call.global;
    const output = host_call.output;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const this_value = host_call.this_value;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (id == @intFromEnum(ConstructorMethod.construct)) {
        // `new RegExp(pattern, flags)` arrives through the construct record
        // path with `is_constructor` set and the resolved instance prototype
        // in `new_target`. The construct branch reads only `args`/`new_target`,
        // so it runs before the `func_obj` requirement below: the VM construct
        // fast path (`regExpConstructCall`) routes its
        // coerced terminal here without a materialized constructor object.
        // `RegExp(...)` called as a function routes through the fast-path call
        // op (which itself handles the "return the argument unchanged when it is
        // already a RegExp and no flags are given" call-only behavior).
        if (host_call.is_constructor) {
            const rt = ctx.runtime;
            // Synthetic construct terminals explicitly supply their active
            // global; observable calls receive it through `callable_realm`.
            const active_global = callable_global orelse return error.TypeError;
            const pattern = if (args.len >= 1) args[0] else try createStringValue(rt, "");
            const flags = if (args.len >= 2) args[1] else try createStringValue(rt, "");
            return constructWithPrototypeInRealm(rt, active_global, pattern, flags, host_call.new_target);
        }
        const active_global = callable_global orelse return error.TypeError;
        return regExpFunctionCall(ctx, output, active_global, host_call.func_obj, args, caller_function, caller_frame);
    }

    const function_object = host_call.func_obj orelse return error.TypeError;
    if (id == @intFromEnum(StaticMethod.escape)) return escape(ctx.runtime, args);
    if (legacyAccessorMethodFromId(id)) |method| {
        const active_global = callable_global orelse return error.TypeError;
        return regExpLegacyAccessor(ctx, output, active_global, this_value, function_object, method, args, caller_function, caller_frame);
    }
    const method_id = decodePrototypeMethodId(id) orelse return error.TypeError;
    if (method_id == 9) {
        const active_global = callable_global orelse return error.TypeError;
        return (try regExpCompile(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError;
    }
    const active_global = callable_global orelse return error.TypeError;
    return switch (method_id) {
        1 => string_ops.regExpToString(ctx, output, active_global, this_value, caller_function, caller_frame),
        2 => (try regExpTestMethod(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        3 => try regExpExecMethod(ctx, output, active_global, this_value, args, caller_function, caller_frame),
        4 => (try string_ops.regExpSymbolSearch(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        5 => (try string_ops.regExpSymbolMatch(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        6 => (try string_ops.regExpSymbolMatchAll(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        7 => (try string_ops.regExpSymbolReplace(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        8 => (try string_ops.regExpSymbolSplit(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.TypeError,
        else => error.TypeError,
    };
}

fn regexpFlagsAccessorCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, &.{}, 0) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == native_ctx);
    const active_global = realm.global;
    if (!native_this.is(.object)) return exception_ops.throwTypeErrorMessage(native_ctx, active_global, "not an object");

    // js_regexp_get_flags: generic receiver; observe the
    // eight flag properties through ordinary [[Get]] in canonical order.
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
        const value = try object_ops.getValueProperty(
            native_ctx,
            host_call.output,
            active_global,
            native_this,
            flag_atom,
            host_call.caller_function,
            host_call.caller_frame,
        );
        if (coercion_ops.valueTruthy(value)) {
            str[count] = flag_char;
            count += 1;
        }
    }
    return createStringValue(native_ctx.runtime, str[0..count]);
}

fn regexpSourceAccessorCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, &.{}, 0) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == native_ctx);
    const active_global = realm.global;
    const function_object = host_call.func_obj orelse return error.TypeError;
    if (!native_this.is(.object)) return exception_ops.throwTypeErrorMessage(native_ctx, active_global, "not an object");

    const header = native_this.refHeader() orelse return error.TypeError;
    const receiver = core.Object.fromHeader(header);
    if (receiver.class_id == core.class.ids.regexp and (regexpFlags(receiver) catch null) != null) {
        return accessor(native_ctx.runtime, native_this, "source") catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    if (object_ops.regExpPrototypeFromGlobal(native_ctx.runtime, active_global)) |resolved| {
        var prototype = resolved;
        defer prototype.deinit(native_ctx.runtime);
        if (receiver == prototype.object()) return createStringValue(native_ctx.runtime, "(?:)");
    }
    _ = try array_ops.throwRegExpAccessorTypeError(native_ctx, function_object.value());
    return error.TypeError;
}

fn regexpFlagAccessorCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, &.{}, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == native_ctx);
    const active_global = realm.global;
    const function_object = host_call.func_obj orelse return error.TypeError;
    if (!native_this.is(.object)) return exception_ops.throwTypeErrorMessage(native_ctx, active_global, "not an object");

    const header = native_this.refHeader() orelse return error.TypeError;
    const receiver = core.Object.fromHeader(header);
    if (receiver.class_id == core.class.ids.regexp) {
        if (regexpFlags(receiver) catch null) |flags| {
            const mask: u16 = @intCast(native_magic);
            return core.JSValue.boolean((flags.bits() & mask) != 0);
        }
    }
    if (object_ops.regExpPrototypeFromGlobal(native_ctx.runtime, active_global)) |resolved| {
        var prototype = resolved;
        defer prototype.deinit(native_ctx.runtime);
        if (receiver == prototype.object()) return core.JSValue.undefinedValue();
    }
    _ = try array_ops.throwRegExpAccessorTypeError(native_ctx, function_object.value());
    return error.TypeError;
}

fn regexpExecCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, 0) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == native_ctx);
    const active_global = realm.global;
    return try regExpExecMethod(
        native_ctx,
        host_call.output,
        active_global,
        native_this,
        native_args,
        host_call.caller_function,
        host_call.caller_frame,
    );
}

fn regexpSymbolMatchCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, 0) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == native_ctx);
    const active_global = realm.global;
    return (try string_ops.regExpSymbolMatch(
        native_ctx,
        host_call.output,
        active_global,
        native_this,
        native_args,
        host_call.caller_function,
        host_call.caller_frame,
    )) orelse error.TypeError;
}

fn regexpSymbolSplitCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, 0) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == native_ctx);
    const active_global = realm.global;
    return (try string_ops.regExpSymbolSplit(
        native_ctx,
        host_call.output,
        active_global,
        native_this,
        native_args,
        host_call.caller_function,
        host_call.caller_frame,
    )) orelse error.TypeError;
}

pub fn constructWithPrototype(rt: *core.JSRuntime, pattern: core.JSValue, flags: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    return constructWithPrototypeInRealm(rt, null, pattern, flags, prototype);
}

fn constructWithPrototypeInRealm(rt: *core.JSRuntime, realm_global: ?*core.Object, pattern: core.JSValue, flags: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    if (flags.is(.undefined_value)) {
        if (regexpObjectFromValue(pattern)) |regexp_object| {
            const source_val = try getInternalSource(regexp_object);
            const bytecode = regexp_object.regexpCompiledBytecode();
            if (bytecode.len == 0) return error.TypeError;
            return constructCompiled(rt, realm_global, source_val, bytecode, prototype);
        }
    }

    var source_val = core.JSValue.undefinedValue();
    var flags_val = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &source_val, &flags_val });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const pattern_object = regexpObjectFromValue(pattern);
    source_val = if (pattern_object) |regexp_object|
        try getInternalSource(regexp_object)
    else if (pattern.is(.undefined_value))
        try createStringValue(rt, "")
    else
        try regExpStringValue(rt, pattern);

    flags_val = if (flags.is(.undefined_value) and pattern_object != null)
        try getInternalFlags(rt, pattern_object.?)
    else if (flags.is(.undefined_value))
        try createStringValue(rt, "")
    else
        try regExpStringValue(rt, flags);

    var compiled = try compileSourceAndFlags(rt, realm_global, source_val, flags_val);
    defer compiled.deinit(rt.memory.allocator);

    return constructCompiled(rt, realm_global, source_val, compiled.bytecode, prototype);
}

fn regExpStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isString()) return value;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, value);
    return try createStringValue(rt, bytes.items);
}

fn regexpCompileOptions(rt: *core.JSRuntime) regexp_lib.CompileOptions {
    return .{ .host = runtimeHost(rt) };
}

fn throwRegExpStackOverflow(rt: *core.JSRuntime, global: ?*core.Object) !void {
    // qjs:quickjs.c JS_ThrowSyntaxError(ctx, "%s", error_msg) with
    // re_parse_error(s, "stack overflow"). Must not reuse error.StackOverflow,
    // which materializes InternalError.
    if (global) |g| {
        if (rt.contextForGlobal(g) orelse rt.contextForGlobalIncludingConstructing(g)) |ctx| {
            _ = try exception_ops.throwSyntaxErrorMessage(ctx, g, "stack overflow");
        }
    } else if (rt.context_head) |ctx| {
        if (ctx.global) |g| {
            _ = try exception_ops.throwSyntaxErrorMessage(ctx, g, "stack overflow");
        }
    }
    return error.SyntaxError;
}

fn compileSourceAndFlags(rt: *core.JSRuntime, global: ?*core.Object, source: core.JSValue, flags: core.JSValue) !regexp_lib.Compiled {
    // QuickJS's js_compile_regexp passes both strings through
    // JS_ToCStringLen2. ASCII strings keep a live reference and expose their
    // inline bytes directly; only strings that need UTF-8 transcoding allocate
    // a temporary buffer. `JSString.Utf8` has that same borrowed/owned
    // contract, so do not unconditionally copy every source and flags string
    // into separate ArrayLists before compiling.
    var flag_bytes = try core.JSValue.String.Utf8.fromValue(rt.memory.allocator, flags);
    defer flag_bytes.deinit();
    // js_compile_regexp validates flags before converting the source, then
    // passes `cesu8 = !unicode` to JS_ToCStringLen2. Besides preserving its
    // exception/allocation order, this keeps non-Unicode patterns expressed
    // in UTF-16 code units rather than merging surrogate pairs prematurely.
    const re_flags = regexp_lib.Flags.parse(flag_bytes.slice()) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return error.SyntaxError,
        error.StackOverflow => {
            try throwRegExpStackOverflow(rt, global);
            return error.SyntaxError;
        },
        else => |other| return other,
    };
    const cesu8 = !re_flags.fullUnicode();
    var source_bytes = try core.JSValue.String.Utf8.fromValueCesu8(rt.memory.allocator, source, cesu8);
    defer source_bytes.deinit();

    return regexp_lib.compilePatternWithFlagsAndOptions(rt.memory.allocator, source_bytes.slice(), re_flags, regexpCompileOptions(rt)) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return error.SyntaxError,
        error.StackOverflow => {
            try throwRegExpStackOverflow(rt, global);
            return error.SyntaxError;
        },
        else => |other| return other,
    };
}

fn createRegExpObject(rt: *core.JSRuntime, realm_global: ?*core.Object, prototype: ?*core.Object) !*core.Object {
    if (realm_global) |global| {
        if (rt.contextForGlobal(global)) |ctx| {
            if (ctx.regexp_shape) |initial_shape| {
                if (initial_shape.proto == prototype) return core.Object.createRegExpFromShape(rt, initial_shape);
            }
        }
    }

    // Custom/null prototypes do not use the realm's intrinsic shape in QJS
    // either (`js_create_from_ctor` followed by defining lastIndex). Reserve the
    // slot and let the ordinary transition cache build the corresponding shape.
    const object = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.regexp, prototype, 1);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    try object.initializeRegExpLastIndex(rt);
    return object;
}

fn constructCompiled(rt: *core.JSRuntime, realm_global: ?*core.Object, source: core.JSValue, bytecode: []const u8, prototype: ?*core.Object) !core.JSValue {
    var source_val = source;
    var root_frame = core.runtime.rootValues(.{&source_val});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try createRegExpObject(rt, realm_global, prototype);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());

    try object.setRegexpSource(rt, source_val);
    try object.setRegexpCompiledBytecode(rt, bytecode);
    return object.value();
}

test "constructCompiled roots string source while creating regexp object" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const source = try core.string.String.createAscii(rt, "a");
    const source_value = source.value();
    var compiled = try regexp_lib.compilePatternAndFlags(rt.memory.allocator, "a", "g");
    defer compiled.deinit(rt.memory.allocator);
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const regexp_value = try constructCompiled(rt, null, source_value, compiled.bytecode, null);
    const regexp = regexpObjectFromValue(regexp_value) orelse return error.TypeError;

    try std.testing.expect(regexp.regexpSource().?.same(source_value));
    try std.testing.expect(regexp.regexpCompiledBytecode().len != 0);
}

/// Pattern/flags early-error validation lives in `libs/regexp.zig`
/// (QuickJS: `js_compile_regexp` flag parsing plus `lre_compile`).
pub const compilePatternAndFlags = regexp_lib.compilePatternAndFlags;

/// Core-owned character-class membership shared with VM string operations.
pub const classMatchesUtf16Unit = core.regexp.classMatchesUtf16Unit;

fn regexpObjectFromValue(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (!value.is(.object)) return null;
    const object = core.Object.fromHeader(header);
    return if (object.class_id == core.class.ids.regexp) object else null;
}

pub fn accessor(rt: *core.JSRuntime, object_value: core.JSValue, name: []const u8) !core.JSValue {
    const object = try expectRegExpObject(object_value);
    if (std.mem.eql(u8, name, "source")) {
        const source = try getInternalSource(object);
        return escapedSource(rt, source);
    }
    const flags = try regexpFlags(object);
    if (std.mem.eql(u8, name, "flags")) return canonicalFlagsValue(rt, flags);

    const present = if (flag_by_accessor_name.get(name)) |field| switch (field) {
        ._reserved => false,
        inline else => |f| @field(flags, @tagName(f)),
    } else false;
    return core.JSValue.boolean(present);
}

fn escapedSource(rt: *core.JSRuntime, source: core.JSValue) !core.JSValue {
    if (regexpSourceCanReturnRaw(source)) return source;
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
    for (0..string_value.len()) |index| {
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

    switch (input.resolveData()) {
        .latin1 => |bytes| {
            for (bytes, 0..) |byte, index| try appendEscapedCodeUnit(rt, &buffer, byte, index == 0);
        },
        .utf16 => |units| {
            var index: usize = 0;
            while (index < units.len) {
                const unit = units[index];
                if (unicode.isHighSurrogateUnit(unit)) {
                    if (index + 1 < units.len and unicode.isLowSurrogateUnit(units[index + 1])) {
                        const cp = surrogateCodePoint(unit, units[index + 1]);
                        try unicode.appendUtf8CodePoint(rt.memory.allocator, &buffer, cp);
                        index += 2;
                        continue;
                    }
                    try appendUnicodeEscape(rt, &buffer, unit);
                } else if (unicode.isLowSurrogateUnit(unit)) {
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
    const flags = try regexpFlags(object);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try buffer.append(rt.memory.allocator, '/');
    try appendValueString(rt, &buffer, source);
    try buffer.append(rt.memory.allocator, '/');
    try appendCanonicalFlags(rt.memory.allocator, &buffer, flags);

    const str = try core.string.String.createUtf8(rt, buffer.items);
    return str.value();
}

fn canonicalFlagsValue(rt: *core.JSRuntime, flags: Flags) !core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendCanonicalFlags(rt.memory.allocator, &buffer, flags);
    return createStringValue(rt, buffer.items);
}

fn expectRegExpObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.is(.object)) return error.TypeError;
    const object = core.Object.fromHeader(header);
    if (object.class_id != core.class.ids.regexp) return error.TypeError;
    return object;
}

fn expectString(value: core.JSValue) !*core.string.String {
    return value.asStringBody() orelse return error.TypeError;
}

// Leftover empty + ascii/utf8 mint. Same walk as `value_ops.createStringValue`
// (including the canonical empty atom for flagless `flags` / `@@split`).
const createStringValue = value_ops.createStringValue;

fn getInternalSource(object: *core.Object) !core.JSValue {
    return (object.regexpSource() orelse return error.TypeError);
}

fn getInternalFlags(rt: *core.JSRuntime, object: *core.Object) !core.JSValue {
    return flagsStringValueFromBytecode(rt, object.regexpCompiledBytecode());
}

fn regexpFlags(object: *core.Object) !Flags {
    const bytecode = object.regexpCompiledBytecode();
    if (bytecode.len == 0) return error.TypeError;
    return flagsFromBytecode(bytecode);
}

/// Accessor name -> flag field, for the name-dispatched accessor path.
const flag_by_accessor_name = std.StaticStringMap(std.meta.FieldEnum(Flags)).initComptime(.{
    .{ "global", .global },
    .{ "ignoreCase", .ignore_case },
    .{ "multiline", .multiline },
    .{ "dotAll", .dot_all },
    .{ "unicode", .unicode },
    .{ "sticky", .sticky },
    .{ "hasIndices", .indices },
    .{ "unicodeSets", .unicode_sets },
});

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
    try unicode.appendUtf8CodePoint(rt.memory.allocator, buffer, unit);
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

fn surrogateCodePoint(high: u16, low: u16) u32 {
    return @intCast(unicode.codePointFromSurrogatePair(high, low));
}

/// This file's policy for the shared bare-runtime ToString owner.
fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void {
    return core.value_string.appendValueString(rt, buffer, value, .{ .unsupported = .type_error });
}


// ----- merged from regexp_adapter.zig -----
// Runtime-aware adapter over the allocation-only regular-expression library.
//
// It bridges flat JS string storage, runtime stack-overflow/timeout checks,
// capture slots, and canonical flags to `libs/regexp.zig`. Compiled handles
// and caller-provided capture buffers retain their existing library ownership.
const regexp_bytecode = regexp_lib;
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


// ----- merged from regexp_fastpath.zig -----
// RegExp builtin integration helpers and VM-backed fast paths.
const regexp_construct_ref = core.function.NativeBuiltinRef{
    .domain = .regexp,
    .id = @intFromEnum(core.host_function.builtin_method_ids.regexp.ConstructorMethod.construct),
};
fn constructRegExpRecordInNativeScope(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: ?*core.Object,
    prototype: ?*core.Object,
    pattern: core.JSValue,
    flags: core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const args = [_]core.JSValue{ pattern, flags };
    return (try builtin_dispatch.callConstructRecordInNativeScope(ctx, output, global, &.{}, constructor, regexp_construct_ref, prototype, &args, caller_function, caller_frame)) orelse error.TypeError;
}

// Helpers that remain in call_runtime.zig (generic utilities and RegExp helpers
// outside the fast-path cluster).
const RegExpMatch = string_ops.RegExpMatch;
const appendStringValueUnits = string_ops.appendStringValueUnits;
const appendUtf16UnitsAsUtf8 = string_ops.appendUtf16UnitsAsUtf8;
const appendUtf8CodePointForRegExpName = string_ops.appendUtf8CodePointForRegExpName;
const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
const combinedSurrogateCodePoint = string_ops.combinedSurrogateCodePoint;
const createRegExpMatchArrayFromValue = string_ops.createRegExpMatchArrayFromValue;
const defineSplitValueElement = string_ops.defineSplitValueElement;
const decodeRegExpLegacyCaptureSlice = string_ops.decodeRegExpLegacyCaptureSlice;
const fastToLengthIndex = coercion_ops.fastToLengthIndex;
const getValueProperty = object_ops.getValueProperty;
const hexNibble = array_ops.hexNibble;
const isCallableValue = call_runtime.isCallableValue;
const isConstructorLike = call_runtime.isConstructorLike;
const isHighSurrogateCodePoint = string_ops.isHighSurrogateCodePoint;
const isLowSurrogateCodePoint = string_ops.isLowSurrogateCodePoint;
const objectFromValue = object_ops.objectFromValue;
const regExpPrototypeMethodIsDefault = object_ops.regExpPrototypeMethodIsDefault;
const stringValueContainsByte = string_ops.stringValueContainsByte;
const reflectConstructPrototypeVm = object_ops.reflectConstructPrototypeVm;
const regExpLegacyNoCaptureSliceValue = array_ops.regExpLegacyNoCaptureSliceValue;
const regExpPrototypeFromGlobal = object_ops.regExpPrototypeFromGlobal;
const regexpInternalStringValue = string_ops.regexpInternalStringValue;
const replaceRegExpLegacySlot = string_ops.replaceRegExpLegacySlot;
const sameObjectIdentity = object_ops.sameObjectIdentity;
const setValuePropertyStrict = object_ops.setValuePropertyStrict;
const stringSliceValue = string_ops.stringSliceValue;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const toLengthIndexSlow = coercion_ops.toLengthIndexSlow;
const toStringForAnnexB = string_ops.toStringForAnnexB;
const valueTruthy = coercion_ops.valueTruthy;
pub fn regExpFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input_pattern = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const input_flags = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const pattern_is_regexp = try isRegExpObservable(ctx, output, global, input_pattern, caller_function, caller_frame);
    if (pattern_is_regexp and input_flags.is(.undefined_value)) {
        const pattern_constructor = try getValueProperty(ctx, output, global, input_pattern, core.atom.ids.constructor, caller_function, caller_frame);
        const regexp_key = comptime core.atom.predefinedId("RegExp", .string).?;
        const regexp_ctor = try global.getProperty(regexp_key);
        if (sameObjectIdentity(pattern_constructor, regexp_ctor)) return input_pattern;
    }

    var owned_source: ?core.JSValue = null;
    var owned_pattern: ?core.JSValue = null;
    var pattern = if (args.len >= 1) args[0] else blk: {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_pattern = empty;
        break :blk empty;
    };
    if (pattern_is_regexp) {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id != core.class.ids.regexp) {
                const source = try getValueProperty(ctx, output, global, pattern, core.atom.ids.source, caller_function, caller_frame);
                owned_source = source;
                pattern = source;
            }
        }
    }
    if (pattern.is(.object) and !pattern_is_regexp) {
        const pattern_object = objectFromValue(pattern) orelse return error.TypeError;
        if (pattern_object.class_id != core.class.ids.regexp) {
            const string_value = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
            owned_pattern = string_value;
            pattern = string_value;
        }
    } else if (!pattern_is_regexp and !pattern.isString() and !pattern.is(.undefined_value)) {
        // Mirrors js_regexp_constructor: any non-regexp,
        // non-undefined pattern goes through JS_ToString, which throws TypeError
        // for symbols instead of leaking '[object Object]'.
        const string_value = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
        owned_pattern = string_value;
        pattern = string_value;
    }

    var owned_flags: ?core.JSValue = null;
    var flags = if (!input_flags.is(.undefined_value))
        input_flags
    else if (pattern_is_regexp) blk: {
        const pattern_object = objectFromValue(input_pattern) orelse break :blk input_flags;
        if (pattern_object.class_id == core.class.ids.regexp) break :blk input_flags;
        const flags_key = comptime core.atom.predefinedId("flags", .string).?;
        const pattern_flags = try getValueProperty(ctx, output, global, input_pattern, flags_key, caller_function, caller_frame);
        owned_flags = pattern_flags;
        break :blk pattern_flags;
    } else blk: {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_flags = empty;
        break :blk empty;
    };
    // Mirrors js_compile_regexp: the flags operand is
    // ToString'd via JS_ToCStringLen, which throws TypeError for symbols.
    if (!flags.is(.undefined_value) and !flags.isString()) {
        const string_value = try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
        owned_flags = string_value;
        flags = string_value;
    }

    return constructRegExpRecordInNativeScope(ctx, output, global, constructor, ctx.classPrototypeObject(core.class.ids.regexp), pattern, flags, caller_function, caller_frame);
}

pub fn regExpConstructCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: ?*core.Object,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    try builtin_dispatch.preflightInternalRecordCFunction(ctx, global, constructor, regexp_construct_ref);
    var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, constructor);
    native_scope.push();
    defer native_scope.deinit();

    return regExpConstructCallInNativeScope(ctx, output, global, constructor, new_target, args, caller_function, caller_frame) catch |err| {
        try builtin_dispatch.materializeRuntimeError(ctx, global, err);
        return err;
    };
}

fn regExpConstructCallInNativeScope(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: ?*core.Object,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input_pattern = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const input_flags = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if ((input_pattern.isString() or input_pattern.is(.undefined_value)) and
        (input_flags.isString() or input_flags.is(.undefined_value)))
    {
        // Both operands are already string/undefined primitives, so the
        // construct record's value path runs no observable coercion: thread
        // the (pattern, flags) values straight through the table. (The former
        // borrowed-Latin1 fast path produced an identical object for these
        // inputs and is subsumed here now that the construct logic is owned by
        // the record.)
        var prototype = try reflectConstructPrototypeVm(ctx, output, global, "RegExp", new_target, caller_function, caller_frame);
        defer prototype.deinit(ctx.runtime);
        return constructRegExpRecordInNativeScope(ctx, output, global, constructor, prototype.object(), input_pattern, input_flags, caller_function, caller_frame);
    }
    const pattern_is_regexp = try isRegExpObservable(ctx, output, global, input_pattern, caller_function, caller_frame);

    var owned_source: ?core.JSValue = null;
    var owned_pattern: ?core.JSValue = null;
    var pattern = if (args.len >= 1) args[0] else blk: {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_pattern = empty;
        break :blk empty;
    };
    if (pattern.is(.undefined_value)) {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_pattern = empty;
        pattern = empty;
    } else if (pattern_is_regexp) {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                const source = try regexpInternalStringValue(ctx.runtime, pattern_object, true);
                owned_source = source;
                pattern = source;
            } else {
                const source = try getValueProperty(ctx, output, global, pattern, core.atom.ids.source, caller_function, caller_frame);
                owned_source = source;
                pattern = source;
            }
        }
    } else if (pattern.is(.object)) {
        const pattern_object = objectFromValue(pattern) orelse return error.TypeError;
        if (pattern_object.class_id != core.class.ids.regexp) {
            const string_value = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
            owned_pattern = string_value;
            pattern = string_value;
        }
    } else if (!pattern.isString()) {
        // Mirrors js_regexp_constructor: any non-regexp,
        // non-undefined pattern goes through JS_ToString, which throws TypeError
        // for symbols instead of leaking '[object Object]'.
        const string_value = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
        owned_pattern = string_value;
        pattern = string_value;
    }

    var owned_flags: ?core.JSValue = null;
    var flags = if (!input_flags.is(.undefined_value))
        input_flags
    else if (pattern_is_regexp) blk: {
        const pattern_object = objectFromValue(input_pattern) orelse break :blk core.JSValue.undefinedValue();
        if (pattern_object.class_id == core.class.ids.regexp) {
            const pattern_flags = try regexpInternalStringValue(ctx.runtime, pattern_object, false);
            owned_flags = pattern_flags;
            break :blk pattern_flags;
        }
        const flags_key = comptime core.atom.predefinedId("flags", .string).?;
        const pattern_flags = try getValueProperty(ctx, output, global, input_pattern, flags_key, caller_function, caller_frame);
        owned_flags = pattern_flags;
        break :blk pattern_flags;
    } else core.JSValue.undefinedValue();

    var prototype = try reflectConstructPrototypeVm(ctx, output, global, "RegExp", new_target, caller_function, caller_frame);
    defer prototype.deinit(ctx.runtime);
    // Mirrors js_regexp_constructor + js_compile_regexp (quickjs.c +
    // 47577-47578): the flags operand is ToString'd inside js_compile_regexp —
    // after js_create_from_ctor resolved new.target's prototype — and
    // JS_ToCStringLen throws TypeError for symbols (not SyntaxError).
    if (!flags.is(.undefined_value) and !flags.isString()) {
        const string_value = try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
        owned_flags = string_value;
        flags = string_value;
    }
    return constructRegExpRecordInNativeScope(ctx, output, global, constructor, prototype.object(), pattern, flags, caller_function, caller_frame);
}

pub fn regExpExecMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const regexp_object = core.value_semantics.objectFromValue(this_value) orelse {
        return try throwTypeErrorMessage(ctx, global, "RegExp object expected");
    };
    if (regexp_object.class_id != core.class.ids.regexp) {
        return try throwTypeErrorMessage(ctx, global, "RegExp object expected");
    }
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    var owned_string: ?core.JSValue = null;
    const string_value = if (input.isString()) input else blk: {
        const value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
        owned_string = value;
        break :blk value;
    };
    return (try regExpExecResult(ctx, output, global, this_value, regexp_object, string_value, true, caller_function, caller_frame)) orelse error.TypeError;
}

pub fn regExpTestMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const receiver_object = core.value_semantics.objectFromValue(this_value) orelse {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    };
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    var owned_string: ?core.JSValue = null;
    const string_value = if (input.isString()) input else blk: {
        const value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
        owned_string = value;
        break :blk value;
    };
    const exec_atom = (comptime core.atom.predefinedId("exec", .string)) orelse return error.TypeError;
    if (regExpPrototypeMethodIsDefault(ctx.runtime, receiver_object, exec_atom, @intFromEnum(method_ids.regexp.PrototypeMethod.exec))) {
        if (try regExpTestFastNoResult(ctx, receiver_object, string_value)) |matched| {
            return core.JSValue.boolean(matched);
        }
        const result = try regExpExecResult(ctx, output, global, this_value, receiver_object, string_value, true, caller_function, caller_frame) orelse return core.JSValue.boolean(false);
        return core.JSValue.boolean(!result.is(.null_value));
    }

    const result = try regExpExecGeneric(ctx, output, global, this_value, string_value, caller_function, caller_frame);
    return core.JSValue.boolean(!result.is(.null_value));
}

pub fn regExpTestFastNoResult(
    ctx: *core.JSContext,
    regexp_object: *core.Object,
    string_value: core.JSValue,
) !?bool {
    if (!regExpLastIndexCanSkipCoercion(regexp_object)) return null;

    const cached_bytecode = regexp_object.regexpCompiledBytecode();
    if (cached_bytecode.len != 0) {
        const compiled = Compiled{ .bytecode = @constCast(cached_bytecode) };
        const flags = compiled.flags();
        if (flags.global or flags.sticky) return null;
        return testOnStringFromIndex(ctx.runtime, compiled, string_value, 0) catch |err| switch (err) {
            error.BytecodeCorrupt, error.Timeout => return null,
            else => return err,
        };
    }

    return null;
}

pub fn regExpLastIndexCanSkipCoercion(object: *core.Object) bool {
    const value = object.regexpLastIndex() orelse return false;
    if (value.is(.object) or value.isBigInt() or value.is(.symbol)) return false;
    return true;
}

pub fn regExpCompile(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const regexp_object = core.value_semantics.objectFromValue(this_value) orelse return null;
    if (regexp_object.class_id != core.class.ids.regexp) return null;
    var expected_prototype = regExpPrototypeFromGlobal(ctx.runtime, global) orelse
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    defer expected_prototype.deinit(ctx.runtime);
    if (regexp_object.getPrototype() != expected_prototype.object()) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    }

    const pattern = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const flags = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();

    if (flags.is(.undefined_value)) {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                const source_value = try regexpInternalStringValue(ctx.runtime, pattern_object, true);
                const compiled_bytecode = pattern_object.regexpCompiledBytecode();
                if (compiled_bytecode.len == 0) return error.TypeError;

                try regexp_object.setRegexpCompiledBytecode(ctx.runtime, compiled_bytecode);
                try regexp_object.setRegexpSource(ctx.runtime, source_value);

                try setValuePropertyStrict(ctx, output, global, this_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
                return this_value;
            }
        }
    }

    const source_value = blk: {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                if (!flags.is(.undefined_value)) return error.TypeError;
                break :blk try regexpInternalStringValue(ctx.runtime, pattern_object, true);
            }
        }
        if (pattern.is(.undefined_value)) break :blk try value_ops.createStringValue(ctx.runtime, "");
        break :blk try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
    };

    const flags_value = blk: {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                break :blk try regexpInternalStringValue(ctx.runtime, pattern_object, false);
            }
        }
        if (flags.is(.undefined_value)) break :blk try value_ops.createStringValue(ctx.runtime, "");
        break :blk try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
    };

    var source_bytes = std.ArrayList(u8).empty;
    defer source_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendValueString(ctx.runtime, &source_bytes, source_value);
    var flag_bytes = std.ArrayList(u8).empty;
    defer flag_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendValueString(ctx.runtime, &flag_bytes, flags_value);
    var compiled = compileWithRuntime(ctx.runtime, source_bytes.items, flag_bytes.items) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return error.SyntaxError,
        error.StackOverflow => {
            _ = exception_ops.throwSyntaxErrorMessage(ctx, global, "stack overflow") catch |throw_err| return throw_err;
            return error.SyntaxError;
        },
        else => |other| return other,
    };
    defer compiled.deinit(ctx.runtime.memory.allocator);

    try regexp_object.setRegexpCompiledBytecode(ctx.runtime, compiled.bytecode);
    try regexp_object.setRegexpSource(ctx.runtime, source_value);

    try setValuePropertyStrict(ctx, output, global, this_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    return this_value;
}

pub fn regExpSpeciesConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // JS_SpeciesConstructor(ctx, rx, ctx->regexp_ctor): the default is the
    // realm intrinsic, not the observable and replaceable global binding.
    const default_constructor = try regExpConstructorFromGlobal(ctx.runtime, global);

    const constructor_value = try getValueProperty(ctx, output, global, rx, core.atom.ids.constructor, caller_function, caller_frame);
    if (constructor_value.is(.undefined_value)) return default_constructor;
    if (!constructor_value.is(.object)) {
        return error.TypeError;
    }

    const species_atom = (comptime core.atom.predefinedId("Symbol.species", .symbol)) orelse {
        return error.TypeError;
    };
    const species_value = try getValueProperty(ctx, output, global, constructor_value, species_atom, caller_function, caller_frame);
    if (species_value.is(.undefined_value) or species_value.is(.null_value)) return default_constructor;
    if (!(try isConstructorLike(ctx, species_value))) {
        return error.TypeError;
    }
    return species_value;
}

pub fn regExpFlagsAreFullUnicode(rt: *core.JSRuntime, flags_string: core.JSValue) !bool {
    return try stringValueContainsByte(rt, flags_string, 'u') or
        try stringValueContainsByte(rt, flags_string, 'v');
}

pub fn setRegExpLastIndexZero(rt: *core.JSRuntime, regexp_object: *core.Object) !void {
    regexp_object.setProperty(rt, core.atom.ids.lastIndex, core.JSValue.int32(0)) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible => return error.TypeError,
        else => return err,
    };
}

pub fn appendNamedCaptureSubstitution(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    named_captures: core.JSValue,
    replacement: []const u16,
    index: *usize,
    out: *std.ArrayList(u16),
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (named_captures.is(.undefined_value)) return false;
    const name_start = index.* + 2;
    const name_end = std.mem.indexOfScalarPos(u16, replacement, name_start, '>') orelse return false;
    var name = std.ArrayList(u8).empty;
    defer name.deinit(ctx.runtime.memory.allocator);
    try appendUtf16UnitsAsUtf8(ctx.runtime, &name, replacement[name_start..name_end]);
    const atom = try ctx.runtime.internAtom(name.items);
    // TGC S3 §4 class B: the group name is held across a property get that
    // can run a JS accessor, plus the ToString of its result.
    var group_atom_roots = core.runtime.rootAtoms(.{&atom});
    group_atom_roots.activate(ctx.runtime);
    defer group_atom_roots.deactivate(ctx.runtime);
    const capture = try getValueProperty(ctx, output, global, named_captures, atom, caller_function, caller_frame);
    if (!capture.is(.undefined_value)) {
        const capture_string = try toStringForAnnexB(ctx, output, global, capture, caller_function, caller_frame);
        try appendStringValueUnits(ctx.runtime, out, capture_string);
    }
    index.* = name_end;
    return true;
}

pub fn regExpExecGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const exec_atom = (comptime core.atom.predefinedId("exec", .string)) orelse return error.TypeError;
    const exec_method = try getValueProperty(ctx, output, global, rx, exec_atom, caller_function, caller_frame);
    if (!exec_method.is(.undefined_value) and !exec_method.is(.null_value)) {
        if (isCallableValue(exec_method)) {
            // JS_RegExpExec is a synchronous native algorithm boundary. The
            // receiver, method and string are all rooted by this scope, so an
            // eligible bytecode override can execute on the active Machine;
            // non-eligible targets retain the authoritative root-call path.
            const call_args = [_]core.JSValue{string_value};
            const result = try call_runtime.callValueOrBytecodeSyncInternalOutlined(
                ctx,
                output,
                global,
                rx,
                exec_method,
                &call_args,
                caller_function,
                caller_frame,
            );
            if (!result.is(.null_value) and !result.is(.object)) {
                return error.TypeError;
            }
            return result;
        }
        const rx_object = objectFromValue(rx) orelse return error.TypeError;
        if (rx_object.class_id != core.class.ids.regexp) return error.TypeError;
    }
    return try regExpExecMethod(ctx, output, global, rx, &.{string_value}, caller_function, caller_frame);
}

pub fn regExpLegacyAccessor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    method: method_ids.regexp.LegacyAccessorMethod,
    args: []const core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const owner_global = function_object.nativeFunctionRealmGlobalPtr() orelse global;
    const regexp_ctor_value = try regExpConstructorFromGlobal(ctx.runtime, owner_global);
    const regexp_ctor = objectFromValue(regexp_ctor_value) orelse return error.TypeError;
    const receiver = objectFromValue(this_value) orelse return throwTypeErrorMessage(ctx, owner_global, "RegExp legacy accessor receiver mismatch");
    if (receiver != regexp_ctor) return throwTypeErrorMessage(ctx, owner_global, "RegExp legacy accessor receiver mismatch");

    const legacy = (try owner_global.ensureInstalledRealmRegExpLegacyStatics(ctx.runtime)) orelse return error.TypeError;
    switch (method) {
        .set_input => {
            try materializeRegExpLegacyNoCaptureSlots(ctx.runtime, owner_global, legacy);
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const string_value = try toStringForAnnexB(ctx, output, owner_global, input, caller_function, caller_frame);
            try replaceRegExpLegacySlot(ctx.runtime, owner_global, &legacy.input, string_value);
            return core.JSValue.undefinedValue();
        },
        .get_input => return regExpLegacySlotValue(ctx.runtime, legacy.input),
        .get_last_match => return regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .match) orelse regExpLegacySlotValue(ctx.runtime, legacy.last_match),
        .get_last_paren => return regExpLegacyCaptureSliceValue(ctx.runtime, legacy, legacy.last_paren) orelse regExpLegacySlotValue(ctx.runtime, legacy.last_paren),
        .get_left_context => return regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .left) orelse regExpLegacySlotValue(ctx.runtime, legacy.left_context),
        .get_right_context => return regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .right) orelse regExpLegacySlotValue(ctx.runtime, legacy.right_context),
        else => {
            const capture_index = core.host_function.builtin_method_id_lookup.regexp.legacyCaptureIndex(method) orelse return error.TypeError;
            return regExpLegacyCaptureSliceValue(ctx.runtime, legacy, legacy.captures[capture_index]) orelse regExpLegacySlotValue(ctx.runtime, legacy.captures[capture_index]);
        },
    }
}

/// Returns an owned constructor value. The fallback global lookup can produce
/// the last reference to a fresh object, so callers must retain the JSValue for
/// as long as they use its object pointer.
pub fn regExpConstructorFromGlobal(rt: *core.JSRuntime, global: *core.Object) !core.JSValue {
    if (global.cachedRealmValue(rt, .regexp_constructor)) |stored| {
        _ = objectFromValue(stored) orelse return error.TypeError;
        return stored;
    }
    const key = core.atom.ids.RegExp;
    const value = try global.getProperty(key);
    if (objectFromValue(value) == null) {
        return error.TypeError;
    }
    return value;
}

pub fn regExpLegacySlotValue(rt: *core.JSRuntime, slot: ?core.JSValue) !core.JSValue {
    if (slot) |stored| return stored;
    return value_ops.createStringValue(rt, "");
}

pub fn materializeRegExpLegacyNoCaptureSlots(rt: *core.JSRuntime, owner: *core.Object, legacy: anytype) !void {
    if (!legacy.lazy_no_capture_match) return;
    const input = legacy.input orelse {
        legacy.lazy_no_capture_match = false;
        return;
    };

    const matched = try stringSliceValue(rt, input, legacy.lazy_match_index, legacy.lazy_match_len);
    try replaceRegExpLegacySlot(rt, owner, &legacy.last_match, matched);

    if (legacy.lazy_match_index == 0) {
        clearRegExpLegacySlot(rt, &legacy.left_context);
    } else {
        const left = try stringSliceValue(rt, input, 0, legacy.lazy_match_index);
        try replaceRegExpLegacySlot(rt, owner, &legacy.left_context, left);
    }

    const right_start = @min(legacy.lazy_match_index + legacy.lazy_match_len, legacy.lazy_input_len);
    if (right_start >= legacy.lazy_input_len) {
        clearRegExpLegacySlot(rt, &legacy.right_context);
    } else {
        const right = try stringSliceValue(rt, input, right_start, legacy.lazy_input_len - right_start);
        try replaceRegExpLegacySlot(rt, owner, &legacy.right_context, right);
    }

    if (regExpLegacyCaptureSliceValue(rt, legacy, legacy.last_paren)) |last_paren| {
        try replaceRegExpLegacySlot(rt, owner, &legacy.last_paren, last_paren);
    }
    for (legacy.captures[0..legacy.capture_slot_count]) |*capture_slot| {
        if (regExpLegacyCaptureSliceValue(rt, legacy, capture_slot.*)) |capture| {
            try replaceRegExpLegacySlot(rt, owner, capture_slot, capture);
        }
    }
    legacy.lazy_no_capture_match = false;
}

pub fn regExpLegacyCaptureSliceValue(rt: *core.JSRuntime, legacy: anytype, slot: ?core.JSValue) ?core.JSValue {
    if (!legacy.lazy_no_capture_match) return null;
    const input = legacy.input orelse return null;
    const encoded = slot orelse return null;
    const slice = decodeRegExpLegacyCaptureSlice(encoded) orelse return null;
    return stringSliceValue(rt, input, slice.start, slice.len) catch null;
}

pub fn clearRegExpLegacySlot(_: *core.JSRuntime, slot: *?core.JSValue) void {
    slot.* = null;
}

pub fn getRegExpLastIndexLength(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    if (objectFromValue(regexp_value) == regexp_object) {
        if (regexp_object.regexpLastIndex()) |stored| {
            if (fastToLengthIndex(stored)) |index| return index;
        }
    }
    const last_index_value = try getValueProperty(ctx, output, global, regexp_value, core.atom.ids.lastIndex, caller_function, caller_frame);
    return try toLengthIndexSlow(ctx, output, global, last_index_value);
}

pub fn setRegExpLastIndexStrict(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (objectFromValue(regexp_value) == regexp_object and regexp_object.regexpLastIndex() != null) {
        if (!regexp_object.regexpLastIndexWritable()) return error.TypeError;
        const slot = regexp_object.regexpLastIndexSlot();
        const next_value = value;
        slot.* = next_value;
        return;
    }
    try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, value, caller_function, caller_frame);
}

pub fn regExpExecResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    use_last_index: bool,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const string_object = string_value.asStringBody() orelse return null;
    const string_data = string_object.resolveData();
    const input_len = string_data.len();
    const initial_last_index = if (use_last_index)
        try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame)
    else
        0;

    const cached_bytecode = regexp_object.regexpCompiledBytecode();
    if (cached_bytecode.len != 0) {
        const compiled = Compiled{ .bytecode = @constCast(cached_bytecode) };
        const flags = compiled.flags();
        const start_index = if (use_last_index and (flags.global or flags.sticky)) initial_last_index else 0;
        if (start_index > input_len) {
            if (use_last_index and (flags.global or flags.sticky)) {
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
            }
            return core.JSValue.nullValue();
        }
        return try regExpExecCompiledResult(ctx, output, global, regexp_value, regexp_object, string_value, string_data, compiled, use_last_index, flags, start_index, caller_function, caller_frame);
    }

    return null;
}

pub fn regExpExecCompiledResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    string_data: core.string.String.ResolvedData,
    compiled: Compiled,
    use_last_index: bool,
    flags: Flags,
    start_index: usize,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const rt = ctx.runtime;
    // TGC R1-c. Three borrowed things outlive a collection point here.
    // `compiled.bytecode` (carried on into `found.capture_bytecode`, which
    // `captureNameAt` reads while the result array is being built) is the
    // regexp object's own compiled payload, and `string_data` is the input
    // string's flat payload; neither is a GC pointer the scanner can map
    // back to an owner. Naming `regexp_value` and `string_value` is what
    // keeps both payloads addressable across `setRegExpLastIndexStrict`
    // (which can run an accessor) and `createRegExpMatchArrayFromValue`
    // (which allocates every capture substring).
    var rooted_regexp = regexp_value;
    var rooted_string = string_value;
    var exec_roots = core.runtime.rootValues(.{ &rooted_regexp, &rooted_string });
    exec_roots.activate(rt);
    defer exec_roots.deactivate(rt);
    const alloc_count = compiled.allocCount();
    var inline_capture_slots: [small_exec_slots]usize = undefined;
    var heap_capture_slots: []usize = &.{};
    defer if (heap_capture_slots.len != 0) rt.memory.allocator.free(heap_capture_slots);
    const capture_slots = if (alloc_count <= inline_capture_slots.len)
        inline_capture_slots[0..alloc_count]
    else capture: {
        heap_capture_slots = try rt.memory.allocator.alloc(usize, alloc_count);
        break :capture heap_capture_slots;
    };
    const result = execCaptureSlotsOnResolvedStringFromIndex(rt, compiled, string_data, start_index, capture_slots) catch |err| switch (err) {
        error.BytecodeCorrupt, error.Timeout => return null,
        else => return err,
    };

    switch (result) {
        .match => {
            const match_start = captureSlotValue(capture_slots[0]) orelse 0;
            const match_end = captureSlotValue(capture_slots[1]) orelse match_start;
            if (use_last_index and (flags.global or flags.sticky)) {
                const next_index = match_end;
                const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(next_index))
                else
                    core.JSValue.float64(@floatFromInt(next_index));
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
            }

            const total_capture_count = compiled.captureCount();
            const found = RegExpMatch{
                .index = match_start,
                .len = match_end - match_start,
                .capture_slots = capture_slots[2 .. total_capture_count * 2],
                .capture_bytecode = compiled.bytecode,
                .capture_count = total_capture_count - 1,
                .has_named_captures = compiled.flags().named_groups,
            };
            return try createRegExpMatchArrayFromValue(rt, global, string_value, &found, string_data.len(), flags.indices);
        },
        .no_match, .out_of_range => {
            if (use_last_index and (flags.global or flags.sticky)) {
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
            }
            return core.JSValue.nullValue();
        },
        .not_available => return null,
    }
}

pub fn isRegExpValue(value: core.JSValue) bool {
    const object = core.value_semantics.objectFromValue(value) orelse return false;
    return object.class_id == core.class.ids.regexp;
}

pub fn isRegExpObservable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (!value.is(.object)) return false;
    const match_atom = (comptime core.atom.predefinedId("Symbol.match", .symbol)) orelse return isRegExpValue(value);
    const matcher = try getValueProperty(ctx, output, global, value, match_atom, caller_function, caller_frame);
    if (!matcher.is(.undefined_value)) return valueTruthy(matcher);
    return isRegExpValue(value);
}

pub fn regexpLastIndex(_: *core.JSRuntime, object: *core.Object) usize {
    const value = (object.regexpLastIndex() orelse return 0);
    if (value.as(.int)) |int_value| return if (int_value < 0) 0 else @intCast(int_value);
    if (value.as(.float64)) |float_value| {
        if (std.math.isNan(float_value) or float_value <= 0) return 0;
        if (float_value >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
        return @intFromFloat(@floor(float_value));
    }
    return 0;
}

pub fn createRegExpIndexPair(rt: *core.JSRuntime, global: *core.Object, start: usize, end: usize) !core.JSValue {
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, out.gcHeader());
    try defineSplitValueElement(rt, out, 0, core.JSValue.int32(@intCast(start)));
    try defineSplitValueElement(rt, out, 1, core.JSValue.int32(@intCast(end)));
    return out.value();
}

pub fn appendDecodedRegExpGroupName(rt: *core.JSRuntime, out: *std.ArrayList(u8), name: []const u8) !void {
    var index: usize = 0;
    while (index < name.len) {
        if (name[index] == '\\' and index + 1 < name.len and name[index + 1] == 'u') {
            if (readRegExpGroupNameEscape(name, &index)) |cp| {
                var code_point = cp;
                if (isHighSurrogateCodePoint(cp)) {
                    const saved = index;
                    if (readRegExpGroupNameEscape(name, &index)) |low| {
                        if (isLowSurrogateCodePoint(low)) {
                            code_point = combinedSurrogateCodePoint(@intCast(cp), @intCast(low));
                        } else {
                            index = saved;
                        }
                    } else {
                        index = saved;
                    }
                }
                try appendUtf8CodePointForRegExpName(rt, out, code_point);
                continue;
            }
        }
        try out.append(rt.memory.allocator, name[index]);
        index += 1;
    }
}

pub fn readRegExpGroupNameEscape(name: []const u8, index: *usize) ?u21 {
    if (index.* + 2 > name.len or name[index.*] != '\\' or name[index.* + 1] != 'u') return null;
    var pos = index.* + 2;
    if (pos < name.len and name[pos] == '{') {
        pos += 1;
        var value: u32 = 0;
        var saw_digit = false;
        while (pos < name.len and name[pos] != '}') : (pos += 1) {
            const digit = hexNibble(name[pos]) orelse return null;
            saw_digit = true;
            value = value * 16 + digit;
            if (value > 0x10ffff) return null;
        }
        if (!saw_digit or pos >= name.len or name[pos] != '}') return null;
        index.* = pos + 1;
        return @intCast(value);
    }
    if (pos >= name.len or hexNibble(name[pos]) == null) return null;
    var available_hex: usize = 0;
    while (pos + available_hex < name.len and available_hex < 4 and hexNibble(name[pos + available_hex]) != null) : (available_hex += 1) {}
    const digit_count: usize = if (available_hex >= 4) 4 else available_hex;
    var value: u32 = 0;
    var count: usize = 0;
    while (count < digit_count) : (count += 1) {
        const digit = hexNibble(name[pos + count]) orelse return null;
        value = value * 16 + digit;
    }
    index.* = pos + digit_count;
    return @intCast(value);
}
