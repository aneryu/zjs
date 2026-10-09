//! RegExp constructor/prototype records, compilation, accessors, and escape.
//!
//! Receiver and argument values are borrowed; returned JSValues are owned, and
//! temporary source/flag strings plus compiled buffers are released locally.
//! The matching engine is `libs/regexp.zig`. The `Symbol.*` methods, which
//! `String.prototype.{match,matchAll,replace,search,split}` share, live in
//! `string_ops.zig`.

const core = @import("../core/root.zig");

const regexp_lib = @import("../libs/regexp.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const builtin_dispatch = @import("builtin_dispatch.zig");
const bytecode_mod = @import("../bytecode.zig");
const method_ids = core.host_function.builtin_method_ids;
const frame_mod = @import("frame.zig");
const call_runtime = @import("call_runtime.zig");

const string_ops = @import("string_ops.zig");
const object_ops = @import("object_ops.zig");
const array_ops = @import("array_ops.zig");
const exception_ops = @import("exception_ops.zig");
const value_ops = @import("value_ops.zig");

const HostError = exception_ops.HostError;

const AppendStringError = core.value_string.AppendStringError;

pub const StaticMethod = core.host_function.builtin_method_ids.regexp.StaticMethod;

// Relocated to engine core (`core/host_function.zig`, next to
// `builtin_method_ids.regexp.StaticMethod`) in Phase 6b-3e so the VM construct
// dispatchers can gate on the construct id without importing this operation Module;
// re-exported here so the install/dispatch side keeps the original name.
pub const ConstructorMethod = core.host_function.builtin_method_ids.regexp.ConstructorMethod;

const PrototypeMethod = core.host_function.builtin_method_ids.regexp.PrototypeMethod;

const AccessorMethod = core.host_function.builtin_method_ids.regexp.AccessorMethod;

pub const LegacyAccessorMethod = core.host_function.builtin_method_ids.regexp.LegacyAccessorMethod;

pub fn prototypeMethodId(name: []const u8) ?u32 {
    return @intFromEnum(prototype_method_names.get(name) orelse return null);
}

// Pure accessor/legacy-accessor id<->name(/kind) mappers relocated to engine
// core (`core/host_function.zig`, `builtin_method_id_lookup.regexp`) in Phase
// 6b-3 STEP 5B so exec's RegExp accessor cascade dispatches by id without
// naming this builtin.
pub const accessorMethodId = core.host_function.builtin_method_id_lookup.regexp.accessorMethodId;
const legacyAccessorMethodFromId = core.host_function.builtin_method_id_lookup.regexp.legacyAccessorMethodFromId;

/// Declaration + dispatch table for the `.regexp` native-builtin domain
/// (QuickJS js_regexp_funcs / js_regexp_proto_funcs analogue). One shared
/// record handler `regexpCall` switches on the per-record `magic` (== the
/// domain-local id, i.e. the `StaticMethod`/`ConstructorMethod`/`PrototypeMethod`/
/// `AccessorMethod`/`LegacyAccessorMethod` enum value). The `Symbol.*` and
/// `toString` prototype methods delegate to `string_ops.zig`; everything
/// else runs in this module.
/// Property installation resolves names/lengths through the standard-global
/// RegExp function list plus the `prototypeMethodId`/`accessorMethodId`/
/// `LegacyAccessorMethod` id helpers above (like Date); this table is consumed
/// by the record-dispatch path (`internal_builtins.table`).
pub const internal_entries = regexpEntries: {
    const Entry = core.host_function.InternalEntry;
    break :regexpEntries [_]Entry{
        // Constructor + static.
        regexpConstructorEntry("RegExp", 2, @intFromEnum(ConstructorMethod.construct)),
        regexpEntry("escape", 1, @intFromEnum(StaticMethod.escape)),
        // Prototype methods (the subset `prototypeMethodId` maps).
        regexpEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
        regexpEntry("test", 1, @intFromEnum(PrototypeMethod.test_)),
        regexpGenericEntry("exec", 1, @intFromEnum(PrototypeMethod.exec), builtin_dispatch.realmMethod(regExpExecMethod)),
        regexpEntry("[Symbol.search]", 1, @intFromEnum(PrototypeMethod.symbol_search)),
        regexpGenericEntry("[Symbol.match]", 1, @intFromEnum(PrototypeMethod.symbol_match), builtin_dispatch.realmMethod(string_ops.regExpSymbolMatch)),
        regexpEntry("[Symbol.matchAll]", 1, @intFromEnum(PrototypeMethod.symbol_match_all)),
        regexpEntry("[Symbol.replace]", 2, @intFromEnum(PrototypeMethod.symbol_replace)),
        regexpGenericEntry("[Symbol.split]", 2, @intFromEnum(PrototypeMethod.symbol_split), builtin_dispatch.realmMethod(string_ops.regExpSymbolSplit)),
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

const RegexpPrototypeName = struct { []const u8, PrototypeMethod };

const regexp_prototype_name_count = blk: {
    @setEvalBranchQuota(8000);
    var count: usize = 0;
    for (internal_entries) |entry| {
        if (entry.name.len == 0) continue;
        if (std.enums.fromInt(PrototypeMethod, entry.id) == null) continue;
        count += 1;
    }
    break :blk count;
};

fn regexpPrototypeNamePairs() [regexp_prototype_name_count]RegexpPrototypeName {
    @setEvalBranchQuota(8000);
    var pairs: [regexp_prototype_name_count]RegexpPrototypeName = undefined;
    var count: usize = 0;
    for (internal_entries) |entry| {
        if (entry.name.len == 0) continue;
        const method = std.enums.fromInt(PrototypeMethod, entry.id) orelse continue;
        pairs[count] = .{ entry.name, method };
        count += 1;
    }
    return pairs;
}

const prototype_method_names = std.StaticStringMap(PrototypeMethod).initComptime(regexpPrototypeNamePairs());

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

/// Shared record handler for the `.regexp` domain: the `Symbol.*` and
/// `toString` prototype methods delegate to `string_ops.zig`, the rest runs
/// here.
fn regexpCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const callable_global = try builtin_dispatch.activeGlobalOrNull(host_call);
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
    // A function object means callable_global came from its realm.
    const active_global = callable_global.?;
    if (id == @intFromEnum(StaticMethod.escape)) return escape(ctx.runtime, args);
    if (legacyAccessorMethodFromId(id)) |method| {
        return regExpLegacyAccessor(ctx, output, active_global, this_value, function_object, method, args, caller_function, caller_frame);
    }
    const method = std.enums.fromInt(PrototypeMethod, id) orelse return error.TypeError;
    return switch (method) {
        .compile => (try regExpCompile(ctx, output, active_global, this_value, args, caller_function, caller_frame)) orelse error.IncompatibleReceiver,
        .to_string => string_ops.regExpToString(ctx, output, active_global, this_value, caller_function, caller_frame),
        .test_ => try regExpTestMethod(ctx, output, active_global, this_value, args, caller_function, caller_frame),
        .exec => try regExpExecMethod(ctx, output, active_global, this_value, args, caller_function, caller_frame),
        .symbol_search => try string_ops.regExpSymbolSearch(ctx, output, active_global, this_value, args, caller_function, caller_frame),
        .symbol_match => try string_ops.regExpSymbolMatch(ctx, output, active_global, this_value, args, caller_function, caller_frame),
        .symbol_match_all => try string_ops.regExpSymbolMatchAll(ctx, output, active_global, this_value, args, caller_function, caller_frame),
        .symbol_replace => try string_ops.regExpSymbolReplace(ctx, output, active_global, this_value, args, caller_function, caller_frame),
        .symbol_split => try string_ops.regExpSymbolSplit(ctx, output, active_global, this_value, args, caller_function, caller_frame),
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
        if (value_ops.valueTruthy(value)) {
            str[count] = flag_char;
            count += 1;
        }
    }
    return createStringValue(native_ctx.runtime, str[0..count]);
}

fn accessorFallback(ctx: *core.JSContext, global: *core.Object, getter: *core.Object, receiver: *core.Object, comptime source_hit: bool) HostError!core.JSValue {
    if (try object_ops.regExpPrototypeFromGlobal(ctx.runtime, global)) |prototype| if (receiver == prototype) {
        return if (source_hit) createStringValue(ctx.runtime, "(?:)") else core.JSValue.undefinedValue();
    };
    return array_ops.throwRegExpAccessorTypeError(ctx, getter.value());
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
        return accessor(native_ctx.runtime, native_this, "source");
    }
    return accessorFallback(native_ctx, active_global, function_object, receiver, true);
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
    return accessorFallback(native_ctx, active_global, function_object, receiver, false);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, pattern: core.JSValue, flags: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    return constructWithPrototypeInRealm(rt, null, pattern, flags, prototype);
}

fn constructWithPrototypeInRealm(rt: *core.JSRuntime, realm_global: ?*core.Object, pattern: core.JSValue, flags: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var values = [_]core.JSValue{ pattern, flags, if (realm_global) |object| object.value() else core.JSValue.nullValue(), if (prototype) |object| object.value() else core.JSValue.nullValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);
    if (values[1].is(.undefined_value)) {
        if (regexpObjectFromValue(values[0])) |regexp_object| {
            const source_val = try getInternalSource(regexp_object);
            const bytecode = regexp_object.regexpCompiledBytecode();
            if (bytecode.len == 0) return error.TypeError;
            return constructCompiled(rt, objectFromValue(values[2]), source_val, bytecode, objectFromValue(values[3]));
        }
    }

    values[4] = if (regexpObjectFromValue(values[0])) |regexp_object|
        try getInternalSource(regexp_object)
    else if (values[0].is(.undefined_value))
        try createStringValue(rt, "")
    else
        try regExpStringValue(rt, values[0]);

    const pattern_object = regexpObjectFromValue(values[0]);
    values[5] = if (values[1].is(.undefined_value) and pattern_object != null)
        try getInternalFlags(rt, pattern_object.?)
    else if (values[1].is(.undefined_value))
        try createStringValue(rt, "")
    else
        try regExpStringValue(rt, values[1]);

    var compiled = try compileSourceAndFlags(rt, objectFromValue(values[2]), values[4], values[5]);
    defer compiled.deinit(rt.nativeAllocator());

    return constructCompiled(rt, objectFromValue(values[2]), values[4], compiled.bytecode, objectFromValue(values[3]));
}

fn regExpStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isString()) return value;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendValueString(rt, &bytes, value);
    return try createStringValue(rt, bytes.items);
}

fn regexpCompileOptions(rt: *core.JSRuntime) regexp_lib.CompileOptions {
    return .{ .host = runtimeHost(rt) };
}

/// Every compile failure is a SyntaxError, including a parser stack
/// overflow: error.StackOverflow itself would materialize InternalError.
fn regexpCompileErrorMessage(err: regexp_lib.CompileError, part: enum { flags, pattern }) []const u8 {
    return switch (err) {
        error.InvalidPattern => if (part == .flags) "invalid regular expression flags" else "invalid regular expression",
        error.TooComplex => "regular expression is too complex",
        error.StackOverflow => "stack overflow",
        error.OutOfMemory => unreachable,
    };
}

fn throwRegExpSyntaxError(rt: *core.JSRuntime, global: ?*core.Object, message: []const u8) !noreturn {
    if (global) |g| {
        if (rt.contexts.forGlobal(g, .include_constructing)) |ctx| {
            _ = try exception_ops.throwSyntaxErrorMessage(ctx, g, message);
        }
    } else if (rt.contexts.live_head) |ctx| {
        if (ctx.global) |g| {
            _ = try exception_ops.throwSyntaxErrorMessage(ctx, g, message);
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
    var flag_bytes = try core.JSValue.String.Utf8.fromValue(rt.nativeAllocator(), flags);
    defer flag_bytes.deinit();
    // js_compile_regexp validates flags before converting the source, then
    // passes CESU-8 unless `u` selects WTF-8 (QuickJS `cesu8 = !unicode`).
    // That preserves exception/allocation order and keeps non-Unicode
    // patterns in UTF-16 code units rather than merging surrogate pairs.
    const re_flags = regexp_lib.Flags.parse(flag_bytes.slice()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| try throwRegExpSyntaxError(rt, global, regexpCompileErrorMessage(e, .flags)),
    };
    const encoding: core.JSValue.String.Encoding = if (re_flags.fullUnicode()) .wtf8 else .cesu8;
    var source_bytes = try core.JSValue.String.Utf8.fromValueCesu8(rt.nativeAllocator(), source, encoding);
    defer source_bytes.deinit();

    return regexp_lib.compilePatternWithFlagsAndOptions(rt.nativeAllocator(), source_bytes.slice(), re_flags, regexpCompileOptions(rt)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| try throwRegExpSyntaxError(rt, global, regexpCompileErrorMessage(e, .pattern)),
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
    var values = [_]core.JSValue{if (prototype) |object| object.value() else core.JSValue.nullValue()};
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[0] = (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.regexp, objectFromValue(values[0]), 1)).value();
    try objectFromValue(values[0]).?.initializeRegExpLastIndex(rt);
    return objectFromValue(values[0]).?;
}

fn constructCompiled(rt: *core.JSRuntime, realm_global: ?*core.Object, source: core.JSValue, bytecode: []const u8, prototype: ?*core.Object) !core.JSValue {
    var values = [_]core.JSValue{ source, if (realm_global) |object| object.value() else core.JSValue.nullValue(), if (prototype) |object| object.value() else core.JSValue.nullValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    values[3] = (try createRegExpObject(rt, objectFromValue(values[1]), objectFromValue(values[2]))).value();
    try objectFromValue(values[3]).?.setRegexpProgram(rt, values[0], bytecode);
    return values[3];
}

test "constructCompiled roots string source while creating regexp object" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const source = try core.string.String.createAscii(rt, "a");
    const source_value = source.value();
    var compiled = try regexp_lib.compilePatternAndFlags(rt.nativeAllocator(), "a", "g");
    defer compiled.deinit(rt.nativeAllocator());
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const regexp_value = try constructCompiled(rt, null, source_value, compiled.bytecode, null);
    const regexp = regexpObjectFromValue(regexp_value) orelse return error.TypeError;

    try std.testing.expect(regexp.regexpSource().?.same(source_value));
    try std.testing.expect(regexp.regexpCompiledBytecode().len != 0);
}

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
    defer bytes.deinit(rt.nativeAllocator());
    try appendValueString(rt, &bytes, source);
    if (bytes.items.len == 0) return createStringValue(rt, "(?:)");

    var escaped = std.ArrayList(u8).empty;
    defer escaped.deinit(rt.nativeAllocator());
    var in_class = false;
    var index: usize = 0;
    while (index < bytes.items.len) : (index += 1) {
        const byte = bytes.items[index];
        // EscapeRegExpPattern: the result must parse as a regular expression
        // literal, so every line terminator (escaped or not) is spelled out.
        if (lineTerminatorEscape(bytes.items[index..])) |line_terminator| {
            try escaped.appendSlice(rt.nativeAllocator(), line_terminator.text);
            index += line_terminator.len - 1;
            continue;
        }
        if (byte == '\\') {
            if (index + 1 < bytes.items.len and lineTerminatorEscape(bytes.items[index + 1 ..]) != null) continue;
            try escaped.append(rt.nativeAllocator(), byte);
            if (index + 1 < bytes.items.len) {
                index += 1;
                try escaped.append(rt.nativeAllocator(), bytes.items[index]);
            }
            continue;
        }
        switch (byte) {
            '[' => {
                in_class = true;
                try escaped.append(rt.nativeAllocator(), byte);
            },
            ']' => {
                in_class = false;
                try escaped.append(rt.nativeAllocator(), byte);
            },
            '/' => {
                if (!in_class) try escaped.append(rt.nativeAllocator(), '\\');
                try escaped.append(rt.nativeAllocator(), byte);
            },
            else => try escaped.append(rt.nativeAllocator(), byte),
        }
    }
    return createStringValue(rt, escaped.items);
}

/// The escape spelling of a UTF-8 line terminator at the start of `bytes`.
fn lineTerminatorEscape(bytes: []const u8) ?struct { text: []const u8, len: usize } {
    if (bytes.len == 0) return null;
    switch (bytes[0]) {
        '\n' => return .{ .text = "\\n", .len = 1 },
        '\r' => return .{ .text = "\\r", .len = 1 },
        0xE2 => if (bytes.len >= 3 and bytes[1] == 0x80) switch (bytes[2]) {
            0xA8 => return .{ .text = "\\u2028", .len = 3 },
            0xA9 => return .{ .text = "\\u2029", .len = 3 },
            else => {},
        },
        else => {},
    }
    return null;
}

fn regexpSourceCanReturnRaw(source: core.JSValue) bool {
    if (!source.isString()) return false;
    const length = core.string.stringValueLenUnchecked(source);
    if (length == 0) return false;
    var in_class = false;
    var escaped = false;
    for (0..length) |index| {
        const unit = core.string.stringValueCodeUnitAtUnchecked(source, index);
        if (unicode.isEcmaLineTerminatorUnit(unit)) return false;
        if (escaped) {
            // An escaped `[`, `]` or `/` neither opens nor closes a class.
            escaped = false;
            continue;
        }
        switch (unit) {
            '\\' => escaped = true,
            '[' => in_class = true,
            ']' => in_class = false,
            '/' => if (!in_class) return false,
            else => {},
        }
    }
    return true;
}

test "regexp source raw probe does not materialize ropes" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const source = try roots.ref(2);
    for ([_][]const u8{ "abc", "[/", "abc/", "abc\n" }, [_]bool{ true, true, false, false }) |prefix, expected| {
        try left.set(rt, (try core.string.String.createAscii(rt, prefix)).value());
        try right.set(rt, (try core.string.String.createAscii(rt, "]")).value());
        const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
        try source.set(rt, rope.value());
        const epoch = rt.gc.collection_epoch;
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        try std.testing.expectEqual(expected, regexpSourceCanReturnRaw(try source.get(rt)));
        try std.testing.expect(!rope.isLinearized());
        try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
    }
}

pub fn escape(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    if (args.len < 1 or !args[0].isString()) return error.NotAString;

    const input = args[0];
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.nativeAllocator());
    var borrow = core.runtime.NoGcScope{};
    borrow.activate(rt);
    defer borrow.deactivate();
    const flat = core.string.asFlat(input);
    if (flat != null and !flat.?.isWide()) {
        for (flat.?.latin1(), 0..) |byte, index| try appendEscapedCodeUnit(rt, &buffer, byte, index == 0);
    } else {
        const length = core.string.stringValueLenUnchecked(input);
        var index: usize = 0;
        while (index < length) {
            const unit = core.string.stringValueCodeUnitAtUnchecked(input, index);
            if (unicode.isHighSurrogateUnit(unit)) {
                if (index + 1 < length) {
                    const next = core.string.stringValueCodeUnitAtUnchecked(input, index + 1);
                    if (unicode.isLowSurrogateUnit(next)) {
                        try unicode.appendUtf8CodePoint(rt.nativeAllocator(), &buffer, surrogateCodePoint(unit, next));
                        index += 2;
                        continue;
                    }
                }
                try appendUnicodeEscape(rt, &buffer, unit);
            } else if (unicode.isLowSurrogateUnit(unit)) {
                try appendUnicodeEscape(rt, &buffer, unit);
            } else {
                try appendEscapedCodeUnit(rt, &buffer, unit, index == 0);
            }
            index += 1;
        }
    }

    // The output bytes now own everything needed for result allocation.
    borrow.deactivate();
    const output = try core.string.String.createUtf8(rt, buffer.items);
    return output.value();
}

fn canonicalFlagsValue(rt: *core.JSRuntime, flags: Flags) !core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.nativeAllocator());
    try appendCanonicalFlags(rt.nativeAllocator(), &buffer, flags);
    return createStringValue(rt, buffer.items);
}

fn expectRegExpObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.is(.object)) return error.TypeError;
    const object = core.Object.fromHeader(header);
    if (object.class_id != core.class.ids.regexp) return error.TypeError;
    return object;
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
            try buffer.append(rt.nativeAllocator(), '\\');
            try buffer.append(rt.nativeAllocator(), byte);
            return;
        }
        if (controlEscapeChar(byte)) |escaped| {
            try buffer.append(rt.nativeAllocator(), '\\');
            try buffer.append(rt.nativeAllocator(), escaped);
            return;
        }
        if (byte == ' ' or otherPunctuator(byte)) return appendHexEscape(rt, buffer, byte);
        try buffer.append(rt.nativeAllocator(), byte);
        return;
    }

    if (isEscapedWhitespaceOrLineTerminator(unit)) {
        if (unit <= 0xff) return appendHexEscape(rt, buffer, @intCast(unit));
        return appendUnicodeEscape(rt, buffer, unit);
    }
    try unicode.appendUtf8CodePoint(rt.nativeAllocator(), buffer, unit);
}

fn appendHexEscape(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), byte: u8) !void {
    try buffer.appendSlice(rt.nativeAllocator(), "\\x");
    try appendHexByte(rt, buffer, byte);
}

fn appendUnicodeEscape(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), unit: u16) !void {
    try buffer.appendSlice(rt.nativeAllocator(), "\\u");
    try appendHexByte(rt, buffer, @intCast(unit >> 8));
    try appendHexByte(rt, buffer, @intCast(unit & 0xff));
}

fn appendHexByte(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), byte: u8) !void {
    try buffer.append(rt.nativeAllocator(), unicode.asciiLowerHexDigitChar(byte >> 4));
    try buffer.append(rt.nativeAllocator(), unicode.asciiLowerHexDigitChar(byte & 0x0f));
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

// ----- Runtime adapter over libs/regexp.zig -----
// Runtime-aware adapter over the allocation-only regular-expression library.
//
// It bridges flat JS string storage, runtime stack-overflow/timeout checks,
// capture slots, and canonical flags to `libs/regexp.zig`. Compiled handles
// and caller-provided capture buffers retain their existing library ownership.
const regexp_bytecode = regexp_lib;
const max_exec_slots = regexp_bytecode.max_exec_slots;
pub const small_exec_slots = regexp_bytecode.small_exec_slots;
pub const Flags = regexp_bytecode.Flags;
pub const ExecResult = regexp_bytecode.ExecResult;
pub const ExecError = error{ OutOfMemory, BytecodeCorrupt, Timeout };
pub const Compiled = regexp_lib.Compiled;

/// Inline capture storage for one regexp execution. `buffers` parallel slices
/// share one heap allocation when `count` exceeds `small_exec_slots`.
/// Initialize in place: `slices` point at `inline_slots`, so the value must
/// not be returned and then used.
pub fn ExecSlots(comptime buffers: usize) type {
    return struct {
        inline_slots: [buffers][small_exec_slots]usize = undefined,
        heap: []usize = &.{},
        slices: [buffers][]usize = undefined,

        const Self = @This();

        pub fn prepare(self: *Self, allocator: std.mem.Allocator, count: usize) !void {
            if (count <= small_exec_slots) {
                inline for (0..buffers) |index| {
                    self.slices[index] = self.inline_slots[index][0..count];
                }
                return;
            }
            self.heap = try allocator.alloc(usize, count * buffers);
            const heap = self.heap;
            inline for (0..buffers) |index| {
                self.slices[index] = heap[index * count ..][0..count];
            }
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.heap.len != 0) allocator.free(self.heap);
        }
    };
}

/// Corrupt bytecode is a failed match (the caller returns null). A timeout is
/// the uncatchable interrupt. Any other exec error propagates.
pub fn recoverExecError(ctx: *core.JSContext, global: *core.Object, err: ExecError) !void {
    switch (err) {
        error.BytecodeCorrupt => return,
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return exception_ops.throwInterrupted(ctx, global),
    }
}
pub fn compileWithRuntime(rt: *core.JSRuntime, pattern: []const u8, flags: []const u8) !Compiled {
    return regexp_lib.compilePatternAndFlagsWithOptions(rt.nativeAllocator(), pattern, flags, .{ .host = runtimeHost(rt) });
}

const runtimeHost = core.regexp.libraryHost;
pub fn execCaptureSlotsOnResolvedStringFromIndex(
    rt: *core.JSRuntime,
    compiled: Compiled,
    string_data: core.string.String.ResolvedData,
    start_index: usize,
    capture: []usize,
) ExecError!ExecResult {
    const options = execOptions(rt);
    return switch (string_data) {
        .latin1 => |bytes| try regexp_bytecode.execCaptureSlotsSliceTrustedWithOptions(rt.nativeAllocator(), compiled.bytecode, .{ .latin1 = bytes }, start_index, options, capture),
        .utf16 => |units| try regexp_bytecode.execCaptureSlotsSliceTrustedWithOptions(rt.nativeAllocator(), compiled.bytecode, .{ .utf16 = units }, start_index, options, capture),
    };
}

pub fn captureSlotValue(value: usize) ?usize {
    return regexp_bytecode.captureSlotValue(value);
}

pub fn groupName(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8 {
    return regexp_bytecode.groupNameFromBytecode(bytecode, one_based_capture_index);
}

fn flatRegExpInput(rt: *core.JSRuntime, input: core.JSValue) error{OutOfMemory}!core.JSValue {
    return flatRegExpInputRooted(rt, input) catch |err| switch (err) {
        error.OutOfMemory, error.RootGenerationExhausted => error.OutOfMemory,
        // Existing string values already satisfy the engine's length limit.
        error.StringTooLong, error.ExpectedString, error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("regexp input root contract: {s}", .{@errorName(err)}),
    };
}

fn flatRegExpInputRooted(rt: *core.JSRuntime, input: core.JSValue) !core.JSValue {
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const value = try roots.ref(0);
    try value.set(rt, input);
    try core.string.ensureFlat(rt, value.readOnly(), value);
    return value.get(rt);
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
    defer buffer.deinit(rt.nativeAllocator());
    try appendCanonicalFlags(rt.nativeAllocator(), &buffer, flagsFromBytecode(bytecode));
    return (try core.string.String.createAscii(rt, buffer.items)).value();
}

test "JavaScript RegExp adapter compilation and execution" {
    var compiled = try regexp_lib.compilePatternAndFlags(std.testing.allocator, "abc", "i");
    defer compiled.deinit(std.testing.allocator);
    var slots: [max_exec_slots]usize = undefined;
    const result = try regexp_bytecode.execCaptureSlotsSliceTrustedWithOptions(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xxAbCy" }, 0, .{}, &slots);
    try std.testing.expect(result == .match);
    try std.testing.expectEqual(@as(usize, 2), regexp_bytecode.captureSlotValue(slots[0]).?);
    try std.testing.expectEqual(@as(usize, 5), regexp_bytecode.captureSlotValue(slots[1]).?);
}

test "JavaScript RegExp adapter preserves multiple named capture groups" {
    var compiled = try regexp_lib.compilePatternAndFlags(std.testing.allocator, "(?<a>.)(?<b>.)(?<c>.)(?<d>.)", "");
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

// ----- RegExp builtin integration and fast paths -----
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
    return (try builtin_dispatch.callConstructRecordInNativeScope(ctx, output, global, constructor, regexp_construct_ref, prototype, &args, caller_function, caller_frame)) orelse error.TypeError;
}

// Shared exec helpers.
const RegExpMatch = string_ops.RegExpMatch;
const appendStringValueUnits = string_ops.appendStringValueUnits;
const appendUtf16UnitsAsUtf8 = string_ops.appendUtf16UnitsAsUtf8;
const appendUtf8CodePointForRegExpName = string_ops.appendUtf8CodePointForRegExpName;
const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
const combinedSurrogateCodePoint = string_ops.combinedSurrogateCodePoint;
const createRegExpMatchArrayFromValue = string_ops.createRegExpMatchArrayFromValue;
const defineSplitValueElement = string_ops.defineSplitValueElement;
const decodeRegExpLegacyCaptureSlice = string_ops.decodeRegExpLegacyCaptureSlice;
const fastToLengthIndex = value_ops.fastToLengthIndex;
const getValueProperty = object_ops.getValueProperty;
const hexNibble = @import("uint8array_codec.zig").hexNibble;
const isCallableValue = call_runtime.isCallableValue;
const isHighSurrogateCodePoint = string_ops.isHighSurrogateCodePoint;
const isLowSurrogateCodePoint = string_ops.isLowSurrogateCodePoint;
const objectFromValue = object_ops.objectFromValue;
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
const toLengthIndexSlow = value_ops.toLengthIndexSlow;
const toStringForAnnexB = string_ops.toStringForAnnexB;
const valueTruthy = value_ops.valueTruthy;
fn regExpFunctionCall(
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
        // Step 4.b compares against newTarget, which for a call is the active
        // function, not whatever the global `RegExp` binding now holds.
        const regexp_ctor = if (constructor) |active| active.value() else try regExpConstructorFromGlobal(ctx.runtime, global);
        if (sameObjectIdentity(pattern_constructor, regexp_ctor)) return input_pattern;
    }

    var operands = try regExpConstructorOperands(ctx, output, global, input_pattern, input_flags, pattern_is_regexp, caller_function, caller_frame);
    try operands.initialize(ctx, output, global, caller_function, caller_frame);
    return constructRegExpRecordInNativeScope(ctx, output, global, constructor, ctx.classPrototypeObject(core.class.ids.regexp), operands.pattern, operands.flags, caller_function, caller_frame);
}

/// RegExp constructor steps 4-6: the source P and flags F of `pattern`.
const RegExpOperands = struct {
    pattern: core.JSValue,
    flags: core.JSValue,

    /// RegExpInitialize steps 1-4, after the prototype lookup (step 7 runs
    /// RegExpAlloc first): undefined is "", anything else ToString.
    fn initialize(
        self: *RegExpOperands,
        ctx: *core.JSContext,
        output: ?*std.Io.Writer,
        global: *core.Object,
        caller_function: ?*const bytecode_mod.FunctionBytecode,
        caller_frame: ?*frame_mod.Frame,
    ) !void {
        if (self.pattern.is(.undefined_value)) {
            self.pattern = try value_ops.createStringValue(ctx.runtime, "");
        } else if (!self.pattern.isString()) {
            self.pattern = try toStringForAnnexB(ctx, output, global, self.pattern, caller_function, caller_frame);
        }
        if (!self.flags.is(.undefined_value) and !self.flags.isString()) {
            self.flags = try toStringForAnnexB(ctx, output, global, self.flags, caller_function, caller_frame);
        }
    }
};

fn regExpConstructorOperands(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    pattern: core.JSValue,
    flags: core.JSValue,
    pattern_is_regexp: bool,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpOperands {
    if (objectFromValue(pattern)) |pattern_object| {
        // A RegExp object supplies its [[OriginalSource]]/[[OriginalFlags]]
        // whatever its @@match says.
        if (pattern_object.class_id == core.class.ids.regexp) return .{
            .pattern = try regexpInternalStringValue(ctx.runtime, pattern_object, true),
            .flags = if (flags.is(.undefined_value)) try regexpInternalStringValue(ctx.runtime, pattern_object, false) else flags,
        };
        if (pattern_is_regexp) {
            const source = try getValueProperty(ctx, output, global, pattern, core.atom.ids.source, caller_function, caller_frame);
            const flags_key = comptime core.atom.predefinedId("flags", .string).?;
            return .{
                .pattern = source,
                .flags = if (flags.is(.undefined_value)) try getValueProperty(ctx, output, global, pattern, flags_key, caller_function, caller_frame) else flags,
            };
        }
    }
    return .{ .pattern = pattern, .flags = flags };
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
        const prototype = try reflectConstructPrototypeVm(ctx, output, global, "RegExp", new_target, caller_function, caller_frame);
        return constructRegExpRecordInNativeScope(ctx, output, global, constructor, prototype, input_pattern, input_flags, caller_function, caller_frame);
    }
    const pattern_is_regexp = try isRegExpObservable(ctx, output, global, input_pattern, caller_function, caller_frame);
    var operands = try regExpConstructorOperands(ctx, output, global, input_pattern, input_flags, pattern_is_regexp, caller_function, caller_frame);
    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "RegExp", new_target, caller_function, caller_frame);
    try operands.initialize(ctx, output, global, caller_function, caller_frame);
    return constructRegExpRecordInNativeScope(ctx, output, global, constructor, prototype, operands.pattern, operands.flags, caller_function, caller_frame);
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
    var values = [_]core.JSValue{ global.value(), this_value, if (args.len >= 1) args[0] else core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const regexp_object = core.value_semantics.objectFromValue(this_value) orelse {
        return try throwTypeErrorMessage(ctx, global, "RegExp object expected");
    };
    if (regexp_object.class_id != core.class.ids.regexp) {
        return try throwTypeErrorMessage(ctx, global, "RegExp object expected");
    }
    if (!values[2].isString()) values[2] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
    return (try regExpExecResult(ctx, output, objectFromValue(values[0]).?, values[1], objectFromValue(values[1]).?, values[2], true, caller_function, caller_frame)) orelse error.TypeError;
}

pub fn regExpTestMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var values = [_]core.JSValue{ global.value(), this_value, if (args.len >= 1) args[0] else core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (core.value_semantics.objectFromValue(this_value) == null) {
        return throwTypeErrorMessage(ctx, global, "RegExp object expected");
    }
    if (!values[2].isString()) values[2] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
    if (object_ops.regExpExecIsDefault(objectFromValue(values[1]).?)) {
        if (try regExpTestFastNoResult(ctx, objectFromValue(values[0]).?, objectFromValue(values[1]).?, values[2])) |matched| {
            return core.JSValue.boolean(matched);
        }
        const result = try regExpExecResult(ctx, output, objectFromValue(values[0]).?, values[1], objectFromValue(values[1]).?, values[2], true, caller_function, caller_frame) orelse return core.JSValue.boolean(false);
        return core.JSValue.boolean(!result.is(.null_value));
    }

    const result = try regExpExecGeneric(ctx, output, objectFromValue(values[0]).?, values[1], values[2], caller_function, caller_frame);
    return core.JSValue.boolean(!result.is(.null_value));
}

pub fn regExpTestFastNoResult(
    ctx: *core.JSContext,
    global: *core.Object,
    regexp_object: *core.Object,
    string_value: core.JSValue,
) !?bool {
    if (!regExpLastIndexCanSkipCoercion(regexp_object)) return null;
    var values = [_]core.JSValue{ regexp_object.value(), string_value, regexp_object.regexpCompiledBytecodeValue() orelse return null };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const cached_bytecode = core.string.asFlat(values[2]).?.resolveData().latin1;
    if (cached_bytecode.len != 0) {
        const compiled = Compiled{ .bytecode = @constCast(cached_bytecode) };
        const flags = compiled.flags();
        if (flags.global or flags.sticky) return null;
        return testAndRecordLegacyStatics(ctx, global, compiled, values[1]);
    }

    return null;
}

/// RegExpBuiltinExec without the result array: matches from index 0 and, on a
/// match, records the legacy RegExp statics exactly as `exec` does.
fn testAndRecordLegacyStatics(ctx: *core.JSContext, global: *core.Object, compiled: Compiled, string_value: core.JSValue) !?bool {
    if (!string_value.isString()) return null;
    const rt = ctx.runtime;
    var values = [_]core.JSValue{ global.value(), string_value };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[1] = try flatRegExpInput(rt, values[1]);
    const string_data = core.string.asFlat(values[1]).?.resolveData();

    const alloc_count = compiled.allocCount();
    var capture_storage: ExecSlots(1) = .{};
    defer capture_storage.deinit(rt.nativeAllocator());
    try capture_storage.prepare(rt.nativeAllocator(), alloc_count);
    const capture_slots = capture_storage.slices[0];
    const result = execCaptureSlotsOnResolvedStringFromIndex(rt, compiled, string_data, 0, capture_slots) catch |err| {
        try recoverExecError(ctx, global, err);
        return null;
    };
    switch (result) {
        .match => {
            const match_start = captureSlotValue(capture_slots[0]) orelse 0;
            const match_end = captureSlotValue(capture_slots[1]) orelse match_start;
            const total_capture_count = compiled.captureCount();
            const found = RegExpMatch{
                .index = match_start,
                .len = match_end - match_start,
                .capture_slots = capture_slots[2 .. total_capture_count * 2],
                .capture_bytecode = compiled.bytecode,
                .capture_count = total_capture_count - 1,
                .has_named_captures = compiled.flags().named_groups,
            };
            try string_ops.updateRegExpLegacyStaticsForMatch(rt, objectFromValue(values[0]).?, values[1], &found, string_data.len());
            return true;
        },
        .no_match, .out_of_range => return false,
        .not_available => return null,
    }
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
    // Conversion may run JavaScript. Keep both inputs and intermediate strings
    // in writable root slots, and reacquire heap pointers after every safepoint.
    var values = [_]core.JSValue{ this_value, global.value(), if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), if (args.len >= 2) args[1] else core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const regexp_object = core.value_semantics.objectFromValue(this_value) orelse return null;
    if (regexp_object.class_id != core.class.ids.regexp) return null;
    const expected_prototype = (try regExpPrototypeFromGlobal(ctx.runtime, global)) orelse
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    if (regexp_object.getPrototype() != expected_prototype) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    }

    if (values[3].is(.undefined_value)) {
        if (objectFromValue(values[2])) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                values[4] = try regexpInternalStringValue(ctx.runtime, pattern_object, true);
                const compiled_bytecode = objectFromValue(values[2]).?.regexpCompiledBytecode();
                if (compiled_bytecode.len == 0) return error.TypeError;

                try objectFromValue(values[0]).?.setRegexpProgram(ctx.runtime, values[4], compiled_bytecode);

                try setValuePropertyStrict(ctx, output, objectFromValue(values[1]).?, values[0], core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
                return values[0];
            }
        }
    }

    values[4] = blk: {
        if (objectFromValue(values[2])) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                if (!values[3].is(.undefined_value)) return error.RegExpFlagsNotUndefined;
                break :blk try regexpInternalStringValue(ctx.runtime, pattern_object, true);
            }
        }
        if (values[2].is(.undefined_value)) break :blk try value_ops.createStringValue(ctx.runtime, "");
        break :blk try toStringForAnnexB(ctx, output, objectFromValue(values[1]).?, values[2], caller_function, caller_frame);
    };

    values[5] = blk: {
        if (objectFromValue(values[2])) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                break :blk try regexpInternalStringValue(ctx.runtime, pattern_object, false);
            }
        }
        if (values[3].is(.undefined_value)) break :blk try value_ops.createStringValue(ctx.runtime, "");
        break :blk try toStringForAnnexB(ctx, output, objectFromValue(values[1]).?, values[3], caller_function, caller_frame);
    };

    var source_bytes = std.ArrayList(u8).empty;
    defer source_bytes.deinit(ctx.runtime.nativeAllocator());
    try value_ops.appendValueString(ctx.runtime, &source_bytes, values[4]);
    var flag_bytes = std.ArrayList(u8).empty;
    defer flag_bytes.deinit(ctx.runtime.nativeAllocator());
    try value_ops.appendValueString(ctx.runtime, &flag_bytes, values[5]);
    var compiled = compileWithRuntime(ctx.runtime, source_bytes.items, flag_bytes.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| try throwRegExpSyntaxError(ctx.runtime, objectFromValue(values[1]).?, regexpCompileErrorMessage(e, .pattern)),
    };
    defer compiled.deinit(ctx.runtime.nativeAllocator());

    try objectFromValue(values[0]).?.setRegexpProgram(ctx.runtime, values[4], compiled.bytecode);

    try setValuePropertyStrict(ctx, output, objectFromValue(values[1]).?, values[0], core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    return values[0];
}

pub fn regExpSpeciesConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode_mod.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const default_constructor = try regExpConstructorFromGlobal(ctx.runtime, global);
    return object_ops.speciesConstructor(ctx, output, global, rx, default_constructor, caller_function, caller_frame);
}

pub fn regExpFlagsAreFullUnicode(rt: *core.JSRuntime, flags_string: core.JSValue) !bool {
    return try stringValueContainsByte(rt, flags_string, 'u') or
        try stringValueContainsByte(rt, flags_string, 'v');
}

pub fn setRegExpLastIndexZero(rt: *core.JSRuntime, regexp_object: *core.Object) !void {
    try regexp_object.setProperty(rt, core.atom.ids.lastIndex, core.JSValue.int32(0));
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
    var values = [_]core.JSValue{ global.value(), named_captures, core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const name_start = index.* + 2;
    const name_end = std.mem.indexOfScalarPos(u16, replacement, name_start, '>') orelse return false;
    var name = std.ArrayList(u8).empty;
    defer name.deinit(ctx.runtime.nativeAllocator());
    try appendUtf16UnitsAsUtf8(ctx.runtime, &name, replacement[name_start..name_end]);
    const atom = try ctx.runtime.internAtom(name.items);
    // TGC S3 §4 class B: the group name is held across a property get that
    // can run a JS accessor, plus the ToString of its result.
    var group_atom_roots = core.runtime.rootAtoms(.{&atom});
    group_atom_roots.activate(ctx.runtime);
    defer group_atom_roots.deactivate(ctx.runtime);
    values[2] = try getValueProperty(ctx, output, core.value_semantics.objectFromValue(values[0]).?, values[1], atom, caller_function, caller_frame);
    if (!values[2].is(.undefined_value)) {
        values[2] = try toStringForAnnexB(ctx, output, core.value_semantics.objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
        try appendStringValueUnits(ctx.runtime, out, values[2]);
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
    const exec_atom = comptime core.atom.predefinedId("exec", .string).?;
    // Reading `exec` can run a getter. Keep the actual argument slots visible
    // in non-test builds too, then reload them before calling the method.
    var values = [_]core.JSValue{ global.value(), rx, string_value, core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[3] = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[1], exec_atom, caller_function, caller_frame);
    const exec_method = values[3];
    if (!exec_method.is(.undefined_value) and !exec_method.is(.null_value)) {
        if (isCallableValue(exec_method)) {
            // JS_RegExpExec is a synchronous native algorithm boundary. The
            // receiver, method and string are all rooted by this scope, so an
            // eligible bytecode override can execute on the active Machine;
            // non-eligible targets retain the authoritative root-call path.
            const call_args = [_]core.JSValue{values[2]};
            const result = try call_runtime.callValueOrBytecodeSyncInternalOutlined(
                ctx,
                output,
                objectFromValue(values[0]).?,
                values[1],
                exec_method,
                &call_args,
                caller_function,
                caller_frame,
            );
            if (!result.is(.null_value) and !result.is(.object)) return error.InvalidExecResult;
            return result;
        }
        const rx_object = objectFromValue(values[1]) orelse return error.NotARegExp;
        if (rx_object.class_id != core.class.ids.regexp) return error.NotARegExp;
    }
    return try regExpExecMethod(ctx, output, objectFromValue(values[0]).?, values[1], &.{values[2]}, caller_function, caller_frame);
}

fn regExpLegacyAccessor(
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
        .get_last_match => return (try regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .match)) orelse regExpLegacySlotValue(ctx.runtime, legacy.last_match),
        .get_last_paren => return (try regExpLegacyCaptureSliceValue(ctx.runtime, legacy, legacy.last_paren)) orelse regExpLegacySlotValue(ctx.runtime, legacy.last_paren),
        .get_left_context => return (try regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .left)) orelse regExpLegacySlotValue(ctx.runtime, legacy.left_context),
        .get_right_context => return (try regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .right)) orelse regExpLegacySlotValue(ctx.runtime, legacy.right_context),
        else => {
            // The remaining tags are get_capture_1..9.
            const capture_index = core.host_function.builtin_method_id_lookup.regexp.legacyCaptureIndex(method).?;
            return (try regExpLegacyCaptureSliceValue(ctx.runtime, legacy, legacy.captures[capture_index])) orelse regExpLegacySlotValue(ctx.runtime, legacy.captures[capture_index]);
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

fn regExpLegacySlotValue(rt: *core.JSRuntime, slot: ?core.JSValue) !core.JSValue {
    if (slot) |stored| return stored;
    return value_ops.createStringValue(rt, "");
}

fn materializeRegExpLegacyNoCaptureSlots(rt: *core.JSRuntime, owner: *core.Object, legacy: anytype) !void {
    if (!legacy.lazy_no_capture_match) return;
    const input = legacy.input orelse {
        legacy.lazy_no_capture_match = false;
        return;
    };

    const matched = try stringSliceValue(rt, input, legacy.lazy_match_index, legacy.lazy_match_len);
    try replaceRegExpLegacySlot(rt, owner, &legacy.last_match, matched);

    if (legacy.lazy_match_index == 0) {
        clearRegExpLegacySlot(&legacy.left_context);
    } else {
        const left = try stringSliceValue(rt, input, 0, legacy.lazy_match_index);
        try replaceRegExpLegacySlot(rt, owner, &legacy.left_context, left);
    }

    const right_start = @min(legacy.lazy_match_index + legacy.lazy_match_len, legacy.lazy_input_len);
    if (right_start >= legacy.lazy_input_len) {
        clearRegExpLegacySlot(&legacy.right_context);
    } else {
        const right = try stringSliceValue(rt, input, right_start, legacy.lazy_input_len - right_start);
        try replaceRegExpLegacySlot(rt, owner, &legacy.right_context, right);
    }

    if (try regExpLegacyCaptureSliceValue(rt, legacy, legacy.last_paren)) |last_paren| {
        try replaceRegExpLegacySlot(rt, owner, &legacy.last_paren, last_paren);
    }
    for (legacy.captures[0..legacy.capture_slot_count]) |*capture_slot| {
        if (try regExpLegacyCaptureSliceValue(rt, legacy, capture_slot.*)) |capture| {
            try replaceRegExpLegacySlot(rt, owner, capture_slot, capture);
        }
    }
    legacy.lazy_no_capture_match = false;
}

fn regExpLegacyCaptureSliceValue(rt: *core.JSRuntime, legacy: anytype, slot: ?core.JSValue) !?core.JSValue {
    if (!legacy.lazy_no_capture_match) return null;
    const input = legacy.input orelse return null;
    const encoded = slot orelse return null;
    const slice = decodeRegExpLegacyCaptureSlice(encoded) orelse return null;
    return try stringSliceValue(rt, input, slice.start, slice.len);
}

pub fn clearRegExpLegacySlot(slot: *?core.JSValue) void {
    slot.* = null;
}

fn getRegExpLastIndexLength(
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
        if (!regexp_object.regexpLastIndexWritable()) return error.ReadOnly;
        const slot = regexp_object.regexpLastIndexSlot();
        slot.* = value;
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
    if (!string_value.isString()) return null;
    var values = [_]core.JSValue{ global.value(), regexp_value, regexp_object.value(), string_value, core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[4] = try flatRegExpInput(ctx.runtime, values[3]);
    const input_len = core.string.stringValueLenUnchecked(values[4]);
    const initial_last_index = if (use_last_index)
        try getRegExpLastIndexLength(ctx, output, objectFromValue(values[0]).?, values[1], objectFromValue(values[2]).?, caller_function, caller_frame)
    else
        0;

    // lastIndex conversion can reenter JS and replace the receiver's program.
    // Select it after conversion, then retain that exact bytecode body through
    // interrupt callbacks and capture/result allocation.
    values[5] = objectFromValue(values[2]).?.regexpCompiledBytecodeValue() orelse return null;
    const cached_bytecode = core.string.asFlat(values[5]).?.resolveData().latin1;
    if (cached_bytecode.len != 0) {
        const compiled = Compiled{ .bytecode = @constCast(cached_bytecode) };
        const flags = compiled.flags();
        const start_index = if (use_last_index and (flags.global or flags.sticky)) initial_last_index else 0;
        if (start_index > input_len) {
            // A nonzero start_index means lastIndex is in use.
            try setRegExpLastIndexStrict(ctx, output, objectFromValue(values[0]).?, values[1], objectFromValue(values[2]).?, core.JSValue.int32(0), caller_function, caller_frame);
            return core.JSValue.nullValue();
        }
        const string_data = core.string.asFlat(values[4]).?.resolveData();
        return try regExpExecCompiledResult(ctx, output, objectFromValue(values[0]).?, values[1], objectFromValue(values[2]).?, values[3], string_data, compiled, use_last_index, flags, start_index, caller_function, caller_frame);
    }

    return null;
}

fn regExpExecCompiledResult(
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
    // The caller retains the exact compiled/flat backing snapshots, including
    // when an interrupt hook replaces the regexp's current program. Mutable
    // slots here protect and refresh the receiver/global used after callbacks.
    var values = [_]core.JSValue{ global.value(), regexp_value, regexp_object.value(), string_value };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var exec_roots = core.runtime.ValueRootFrame{ .slices = &slices };
    exec_roots.activate(rt);
    defer exec_roots.deactivate(rt);
    const alloc_count = compiled.allocCount();
    var capture_storage: ExecSlots(1) = .{};
    defer capture_storage.deinit(rt.nativeAllocator());
    try capture_storage.prepare(rt.nativeAllocator(), alloc_count);
    const capture_slots = capture_storage.slices[0];
    const result = execCaptureSlotsOnResolvedStringFromIndex(rt, compiled, string_data, start_index, capture_slots) catch |err| {
        try recoverExecError(ctx, global, err);
        return null;
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
                try setRegExpLastIndexStrict(ctx, output, objectFromValue(values[0]).?, values[1], objectFromValue(values[2]).?, next_value, caller_function, caller_frame);
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
            return try createRegExpMatchArrayFromValue(rt, objectFromValue(values[0]).?, values[3], &found, string_data.len(), flags.indices);
        },
        .no_match, .out_of_range => {
            if (use_last_index and (flags.global or flags.sticky)) {
                try setRegExpLastIndexStrict(ctx, output, objectFromValue(values[0]).?, values[1], objectFromValue(values[2]).?, core.JSValue.int32(0), caller_function, caller_frame);
            }
            return core.JSValue.nullValue();
        },
        .not_available => return null,
    }
}

fn isRegExpValue(value: core.JSValue) bool {
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
    var values = [_]core.JSValue{ global.value(), value };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const match_atom = comptime core.atom.predefinedId("Symbol.match", .symbol).?;
    const matcher = try getValueProperty(ctx, output, core.value_semantics.objectFromValue(values[0]).?, values[1], match_atom, caller_function, caller_frame);
    if (!matcher.is(.undefined_value)) return valueTruthy(matcher);
    return isRegExpValue(values[1]);
}

pub fn regexpLastIndex(object: *core.Object) usize {
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
    var values = [_]core.JSValue{global.value()};
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[0] = (try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, objectFromValue(values[0]).?))).value();
    try defineSplitValueElement(rt, objectFromValue(values[0]).?, 0, core.JSValue.int32(@intCast(start)));
    try defineSplitValueElement(rt, objectFromValue(values[0]).?, 1, core.JSValue.int32(@intCast(end)));
    return values[0];
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
        // A non-u pattern holds an astral character as two WTF-8 surrogate
        // halves; the property key is the one code point they encode.
        if (index + 6 <= name.len and name[index] == 0xED and name[index + 1] & 0xF0 == 0xA0 and
            name[index + 3] == 0xED and name[index + 4] & 0xF0 == 0xB0)
        {
            const high: u21 = 0xD000 | (@as(u21, name[index + 1] & 0x3F) << 6) | (name[index + 2] & 0x3F);
            const low: u21 = 0xD000 | (@as(u21, name[index + 4] & 0x3F) << 6) | (name[index + 5] & 0x3F);
            try appendUtf8CodePointForRegExpName(rt, out, combinedSurrogateCodePoint(@intCast(high), @intCast(low)));
            index += 6;
            continue;
        }
        try out.append(rt.nativeAllocator(), name[index]);
        index += 1;
    }
}

fn readRegExpGroupNameEscape(name: []const u8, index: *usize) ?u21 {
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
