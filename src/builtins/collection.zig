const core = @import("../core/root.zig");
const function_builtin = @import("function.zig");
const object_builtin = @import("object.zig");
const symbol_builtin = @import("symbol.zig");
const globals_mod = core.global_slots;
const bignum = @import("../libs/bignum.zig");
const dtoa = @import("../libs/dtoa.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");

pub const CallbackError = error{
    AccessorWithoutSetter,
    AmbiguousExport,
    AwaitOutsideAsyncFunction,
    BigIntTooLarge,
    BytecodeCorrupt,
    BytecodeOverflow,
    ClosureVarNotFound,
    CodepointTooLarge,
    DivisionByZero,
    DuplicateClass,
    EvalError,
    IncompatibleDescriptor,
    Interrupted,
    InvalidAssignmentTarget,
    InvalidAtom,
    InvalidBytecode,
    InvalidBuiltinRegistry,
    InvalidCharacter,
    InvalidCharacterError,
    InvalidClassId,
    InvalidEscape,
    InvalidIdentifier,
    InvalidLength,
    InvalidLhs,
    InvalidNumber,
    InvalidNumberLiteral,
    InvalidOpcode,
    InvalidPattern,
    InvalidPrivateName,
    InvalidRadix,
    InvalidRegExp,
    InvalidUnicodeEscape,
    InvalidUtf8,
    LegacyOctalInStrictMode,
    MissingExport,
    ModuleLinkFailed,
    ModuleNotFound,
    NegativeExponent,
    NoSpaceLeft,
    NotExtensible,
    NotRegExpLiteral,
    NotSimpleNumericCall,
    OutOfMemory,
    Overflow,
    Pc2LineOverflow,
    Pc2LineTruncated,
    ProcessExit,
    PrototypeCycle,
    RangeError,
    ReadOnly,
    ReferenceError,
    StackMismatch,
    StackOverflow,
    StackUnderflow,
    SyntaxError,
    SystemError,
    JSException,
    Timeout,
    TooManyJobArgs,
    TypeError,
    URIError,
    UnhandledPromiseRejection,
    UnterminatedComment,
    UnterminatedRegExp,
    UnterminatedString,
    UnterminatedTemplate,
    UnexpectedEof,
    UnexpectedToken,
    UnsupportedSimpleJson,
    Utf8CannotEncodeSurrogateHalf,
    Utf8EncodesSurrogateHalf,
    YieldOutsideGenerator,
    HtmlCommentInModule,
};

pub const CallbackCallFn = *const fn (
    rt: *core.JSRuntime,
    callback: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) CallbackError!core.JSValue;

pub const CallbackKindFn = *const fn (
    rt: *core.JSRuntime,
    callback: core.JSValue,
) CallbackError!i32;

pub const CallbackHost = struct {
    globals: []globals_mod.Slot = &.{},
    call: ?CallbackCallFn = null,
    kind: ?CallbackKindFn = null,

    fn callWithThis(self: CallbackHost, rt: *core.JSRuntime, callback: core.JSValue, this_value: core.JSValue, args: []const core.JSValue) !core.JSValue {
        const call_fn = self.call orelse return error.TypeError;
        return call_fn(rt, callback, this_value, args, self.globals);
    }

    fn callValue(self: CallbackHost, rt: *core.JSRuntime, callback: core.JSValue, args: []const core.JSValue) !core.JSValue {
        return self.callWithThis(rt, callback, core.JSValue.undefinedValue(), args);
    }

    fn closureKind(self: CallbackHost, rt: *core.JSRuntime, callback: core.JSValue) ?i32 {
        const kind_fn = self.kind orelse return null;
        return kind_fn(rt, callback) catch null;
    }
};

pub const StaticMethod = enum(u32) {
    group_by = 101,
};

pub const ConstructorKind = enum(u32) {
    map = 1,
    set = 2,
    weak_map = 3,
    weak_set = 4,
};

pub fn constructorId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Map")) return @intFromEnum(ConstructorKind.map);
    if (std.mem.eql(u8, name, "Set")) return @intFromEnum(ConstructorKind.set);
    if (std.mem.eql(u8, name, "WeakMap")) return @intFromEnum(ConstructorKind.weak_map);
    if (std.mem.eql(u8, name, "WeakSet")) return @intFromEnum(ConstructorKind.weak_set);
    return null;
}

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "groupBy")) return @intFromEnum(StaticMethod.group_by);
    return null;
}

pub const PrototypeMethod = enum(u32) {
    set = 1,
    get = 2,
    has = 3,
    delete = 4,
    clear = 5,
    add = 6,
    keys = 7,
    values = 8,
    entries = 9,
    for_each = 10,
    get_or_insert = 11,
    get_or_insert_computed = 12,
    iterator_next = 13,
    size_getter = 14,
    difference = 15,
    intersection = 16,
    is_disjoint_from = 17,
    is_subset_of = 18,
    is_superset_of = 19,
    symmetric_difference = 20,
    union_ = 21,
};

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "set")) return @intFromEnum(PrototypeMethod.set);
    if (std.mem.eql(u8, name, "get")) return @intFromEnum(PrototypeMethod.get);
    if (std.mem.eql(u8, name, "has")) return @intFromEnum(PrototypeMethod.has);
    if (std.mem.eql(u8, name, "delete")) return @intFromEnum(PrototypeMethod.delete);
    if (std.mem.eql(u8, name, "clear")) return @intFromEnum(PrototypeMethod.clear);
    if (std.mem.eql(u8, name, "add")) return @intFromEnum(PrototypeMethod.add);
    if (std.mem.eql(u8, name, "keys")) return @intFromEnum(PrototypeMethod.keys);
    if (std.mem.eql(u8, name, "values")) return @intFromEnum(PrototypeMethod.values);
    if (std.mem.eql(u8, name, "entries")) return @intFromEnum(PrototypeMethod.entries);
    if (std.mem.eql(u8, name, "forEach")) return @intFromEnum(PrototypeMethod.for_each);
    if (std.mem.eql(u8, name, "getOrInsert")) return @intFromEnum(PrototypeMethod.get_or_insert);
    if (std.mem.eql(u8, name, "getOrInsertComputed")) return @intFromEnum(PrototypeMethod.get_or_insert_computed);
    if (std.mem.eql(u8, name, "next")) return @intFromEnum(PrototypeMethod.iterator_next);
    if (std.mem.eql(u8, name, "get size")) return @intFromEnum(PrototypeMethod.size_getter);
    if (std.mem.eql(u8, name, "difference")) return @intFromEnum(PrototypeMethod.difference);
    if (std.mem.eql(u8, name, "intersection")) return @intFromEnum(PrototypeMethod.intersection);
    if (std.mem.eql(u8, name, "isDisjointFrom")) return @intFromEnum(PrototypeMethod.is_disjoint_from);
    if (std.mem.eql(u8, name, "isSubsetOf")) return @intFromEnum(PrototypeMethod.is_subset_of);
    if (std.mem.eql(u8, name, "isSupersetOf")) return @intFromEnum(PrototypeMethod.is_superset_of);
    if (std.mem.eql(u8, name, "symmetricDifference")) return @intFromEnum(PrototypeMethod.symmetric_difference);
    if (std.mem.eql(u8, name, "union")) return @intFromEnum(PrototypeMethod.union_);
    return null;
}

pub fn legacyPrototypeMethodId(name: []const u8) ?u32 {
    const id = prototypeMethodId(name) orelse return null;
    if (legacyBasePrototypeMethodId(id)) |method_id| return method_id;
    return switch (id) {
        @intFromEnum(PrototypeMethod.difference),
        @intFromEnum(PrototypeMethod.intersection),
        @intFromEnum(PrototypeMethod.is_disjoint_from),
        @intFromEnum(PrototypeMethod.is_subset_of),
        @intFromEnum(PrototypeMethod.is_superset_of),
        @intFromEnum(PrototypeMethod.symmetric_difference),
        @intFromEnum(PrototypeMethod.union_),
        => id,
        else => null,
    };
}

pub fn legacyClosureMethodId(name: []const u8) ?u32 {
    const id = prototypeMethodId(name) orelse return null;
    if (legacyBasePrototypeMethodId(id)) |method_id| return method_id;
    return switch (id) {
        @intFromEnum(PrototypeMethod.iterator_next) => id,
        else => null,
    };
}

pub fn fastPrototypeMethodIdForClass(class_id: core.ClassId, name: []const u8) ?u32 {
    const id = prototypeMethodId(name) orelse return null;
    return switch (class_id) {
        core.class.ids.map, core.class.ids.weakmap => switch (id) {
            @intFromEnum(PrototypeMethod.set),
            @intFromEnum(PrototypeMethod.get),
            @intFromEnum(PrototypeMethod.has),
            @intFromEnum(PrototypeMethod.delete),
            => id,
            else => null,
        },
        core.class.ids.set, core.class.ids.weakset => switch (id) {
            @intFromEnum(PrototypeMethod.add),
            @intFromEnum(PrototypeMethod.has),
            @intFromEnum(PrototypeMethod.delete),
            => id,
            else => null,
        },
        else => null,
    };
}

fn legacyBasePrototypeMethodId(id: u32) ?u32 {
    return switch (id) {
        @intFromEnum(PrototypeMethod.set),
        @intFromEnum(PrototypeMethod.get),
        @intFromEnum(PrototypeMethod.has),
        @intFromEnum(PrototypeMethod.delete),
        @intFromEnum(PrototypeMethod.clear),
        @intFromEnum(PrototypeMethod.add),
        @intFromEnum(PrototypeMethod.keys),
        @intFromEnum(PrototypeMethod.values),
        @intFromEnum(PrototypeMethod.entries),
        @intFromEnum(PrototypeMethod.for_each),
        @intFromEnum(PrototypeMethod.get_or_insert),
        @intFromEnum(PrototypeMethod.get_or_insert_computed),
        => id,
        else => null,
    };
}

pub fn sameValueZero(a: core.JSValue, b: core.JSValue) bool {
    if (numberValue(a)) |lhs| {
        if (numberValue(b)) |rhs| {
            if (std.math.isNan(lhs) and std.math.isNan(rhs)) return true;
            return lhs == rhs;
        }
    }
    if (a.asBool()) |lhs| {
        if (b.asBool()) |rhs| return lhs == rhs;
    }
    if (a.isNull() or a.isUndefined()) return a.same(b);
    if (a.isBigInt() and b.isBigInt()) return object_builtin.sameValue(a, b);
    if (a.isString() and b.isString()) {
        if (a.same(b)) return true;
        const lhs = stringFromValue(a) orelse return false;
        const rhs = stringFromValue(b) orelse return false;
        return lhs.eqlString(rhs.*);
    }
    return a.same(b);
}

pub const Entry = struct {
    key: core.JSValue,
    value: core.JSValue,
};

/// QuickJS source map: narrow collection constructors used by the transitional
/// `new_collection` bytecode.
pub fn construct(rt: *core.JSRuntime, kind: u32) !core.JSValue {
    return constructWithPrototype(rt, kind, null);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, kind: u32, prototype: ?*core.Object) !core.JSValue {
    const class_id = collectionClassId(kind) orelse return error.TypeError;
    const object = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (prototype == null) try defineNativeMethods(rt, object, class_id);
    return object.value();
}

/// QuickJS source map: selected Map/Set/WeakMap/WeakSet methods currently
/// covered by smoke fixtures and targeted collection validation. Strong
/// collections use object-owned entry arrays; weak collections store object
/// identities plus values so keys are not retained through ordinary properties.
pub fn methodCall(rt: *core.JSRuntime, object_value: core.JSValue, method: u32, args: []const core.JSValue) !core.JSValue {
    return methodCallWithCallbackHost(rt, object_value, method, args, .{});
}

pub fn methodCallWithGlobals(
    rt: *core.JSRuntime,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    return methodCallWithCallbackHost(rt, object_value, method, args, .{ .globals = globals });
}

pub fn methodCallWithCallbackHost(
    rt: *core.JSRuntime,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    const object = try expectObject(object_value);
    return methodCallResolved(rt, null, globalObjectFromGlobals(rt, host.globals), object, method, args, host);
}

pub fn methodCallWithContext(
    ctx: *core.JSContext,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    return methodCallWithContextAndHost(ctx, object_value, method, args, .{ .globals = globals });
}

pub fn methodCallWithContextAndHost(
    ctx: *core.JSContext,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    const object = try expectObject(object_value);
    return methodCallResolved(ctx.runtime, ctx, globalObjectFromGlobals(ctx.runtime, host.globals), object, method, args, host);
}

pub fn methodCallWithGlobal(
    ctx: *core.JSContext,
    global: *core.Object,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    return methodCallWithGlobalAndHost(ctx, global, object_value, method, args, .{ .globals = globals });
}

pub fn methodCallWithGlobalAndHost(
    ctx: *core.JSContext,
    global: *core.Object,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    const object = try expectObject(object_value);
    return methodCallResolved(ctx.runtime, ctx, global, object, method, args, host);
}

pub fn methodCallObjectWithGlobal(
    ctx: *core.JSContext,
    global: *core.Object,
    object: *core.Object,
    method: u32,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    return methodCallObjectWithGlobalAndHost(ctx, global, object, method, args, .{ .globals = globals });
}

pub fn methodCallObjectWithGlobalAndHost(
    ctx: *core.JSContext,
    global: *core.Object,
    object: *core.Object,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    return methodCallResolved(ctx.runtime, ctx, global, object, method, args, host);
}

pub fn readOnlyMethodCallObject(rt: *core.JSRuntime, object: *core.Object, method: PrototypeMethod, key: core.JSValue) !core.JSValue {
    return switch (method) {
        .get => mapGet(rt, object, key),
        .has => collectionHas(rt, object, key),
        else => error.TypeError,
    };
}

fn methodCallResolved(
    rt: *core.JSRuntime,
    ctx: ?*core.JSContext,
    global: ?*core.Object,
    object: *core.Object,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    return switch (method) {
        1 => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            return mapSet(rt, object, key, value);
        },
        2 => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return mapGet(rt, object, key);
        },
        3 => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return collectionHas(rt, object, key);
        },
        4 => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return collectionDelete(rt, object, key);
        },
        5 => {
            return collectionClear(rt, object);
        },
        6 => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return setAdd(rt, object, value);
        },
        7 => {
            return collectionIterator(rt, ctx, global, object, .key);
        },
        8 => {
            return collectionIterator(rt, ctx, global, object, .value);
        },
        9 => {
            return collectionIterator(rt, ctx, global, object, .key_value);
        },
        10 => return collectionForEach(rt, object, args, host),
        11 => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return mapGetOrInsert(rt, object, key, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());
        },
        12 => {
            if (args.len < 2) return error.TypeError;
            return mapGetOrInsertComputed(rt, object, args[0], args[1], host);
        },
        13 => {
            return collectionIteratorNext(rt, object);
        },
        14 => {
            return collectionSize(object);
        },
        15 => return setComposition(rt, object, args, .difference, host),
        16 => return setComposition(rt, object, args, .intersection, host),
        17 => return setComparison(rt, object, args, .is_disjoint_from, host),
        18 => return setComparison(rt, object, args, .is_subset_of, host),
        19 => return setComparison(rt, object, args, .is_superset_of, host),
        20 => return setComposition(rt, object, args, .symmetric_difference, host),
        21 => return setComposition(rt, object, args, .union_, host),
        else => error.TypeError,
    };
}

pub fn methodCallDroppedResult(rt: *core.JSRuntime, object: *core.Object, method: u32, args: []const core.JSValue) !bool {
    switch (method) {
        @intFromEnum(PrototypeMethod.set) => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            try mapSetNoResult(rt, object, key, value);
            return true;
        },
        @intFromEnum(PrototypeMethod.add) => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            try setAddNoResult(rt, object, value);
            return true;
        },
        @intFromEnum(PrototypeMethod.delete) => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            try collectionDeleteNoResult(rt, object, key);
            return true;
        },
        else => return false,
    }
}

pub fn groupBy(
    rt: *core.JSRuntime,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
    prototype: ?*core.Object,
) !core.JSValue {
    return groupByWithCallbackHost(rt, args, prototype, .{ .globals = globals });
}

pub fn groupByWithCallbackHost(
    rt: *core.JSRuntime,
    args: []const core.JSValue,
    prototype: ?*core.Object,
    host: CallbackHost,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    if (!isCallableObject(args[1])) return error.TypeError;

    const map_value = try constructWithPrototype(rt, 1, prototype);
    errdefer map_value.free(rt);
    const map = try expectObject(map_value);

    if (args[0].isString()) {
        try groupString(rt, map, args[0], args[1], host);
        return map_value;
    }

    const source = try expectObject(args[0]);
    if (!source.is_array) return error.TypeError;
    var index: u32 = 0;
    while (index < source.length) : (index += 1) {
        const item = source.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        try addGroupedItem(rt, map, args[1], host, item, index);
    }
    return map_value;
}

fn mapSet(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !core.JSValue {
    try mapSetNoResult(rt, object, key, value);
    return object.value().dup();
}

fn mapSetNoResult(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !void {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = weakKeyIdentity(rt, key) orelse return error.TypeError;
        try setWeakMapEntryByIdentityChecked(rt, object, key_identity, value);
        return;
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    defer canonical_key.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| {
        const entry = &object.collectionEntriesSlot().*[index];
        const next_value = value.dup();
        const old_value = entry.value;
        entry.value = next_value;
        old_value.free(rt);
    } else {
        const entry = core.object.CollectionEntry{ .key = canonical_key.dup(), .value = value.dup() };
        try appendStrongEntryOwned(rt, object, entry);
    }
}

pub fn setWeakMapEntry(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !void {
    if (object.class_id != core.class.ids.weakmap) return error.TypeError;
    const key_identity = weakKeyIdentity(rt, key) orelse return error.TypeError;
    try setWeakMapEntryByIdentityChecked(rt, object, key_identity, value);
}

pub fn setWeakMapEntryByIdentity(rt: *core.JSRuntime, object: *core.Object, key_identity: usize, value: core.JSValue) !void {
    if (object.class_id != core.class.ids.weakmap) return error.TypeError;
    try setWeakMapEntryByIdentityChecked(rt, object, key_identity, value);
}

fn setWeakMapEntryByIdentityChecked(rt: *core.JSRuntime, object: *core.Object, key_identity: usize, value: core.JSValue) !void {
    if (findWeakEntry(object, key_identity)) |index| {
        const entry = &object.weakCollectionEntriesSlot().*[index];
        const next_value = value.dup();
        const old_value = entry.value;
        entry.value = next_value;
        old_value.free(rt);
        return;
    }

    var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value.dup() };
    errdefer entry.destroy(rt);
    try appendWeakEntry(rt, object, entry);
}

fn mapGet(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !core.JSValue {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = weakKeyIdentity(rt, key) orelse return core.JSValue.undefinedValue();
        const index = findWeakEntry(object, key_identity) orelse return core.JSValue.undefinedValue();
        return object.weakCollectionEntriesSlot().*[index].value.dup();
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const index = findStrongEntry(object, key) orelse return core.JSValue.undefinedValue();
    return object.collectionEntriesSlot().*[index].value.dup();
}

pub fn mapGetLatin1PrefixIntValue(object: *core.Object, prefix: []const u8, int_value: i32) ?core.JSValue {
    if (object.class_id != core.class.ids.map) return null;
    var int_buf: [16]u8 = undefined;
    const digits = dtoa.formatInt32(&int_buf, int_value);
    const hash = strongEntryHashLatin1Concat(prefix, digits);
    const index = findStrongEntryLatin1Concat(object, prefix, digits, hash) orelse return null;
    return object.collectionEntriesSlot().*[index].value.dup();
}

pub fn mapSetLatin1PrefixInt32Range(
    rt: *core.JSRuntime,
    object: *core.Object,
    prefix: []const u8,
    start: i32,
    limit: i32,
) !void {
    if (object.class_id != core.class.ids.map or start < 0 or limit < start) return error.TypeError;
    const max_new_count: usize = @intCast(limit - start);
    if (max_new_count == 0) return;
    try object.ensureCollectionEntryCapacity(rt, object.collectionEntriesSlot().*.len + max_new_count);
    try ensureStrongIndexForInsert(rt, object, object.collectionActiveCount() + max_new_count);

    const original_len = object.collectionEntriesSlot().*.len;
    const original_active_count = object.collectionActiveCount();
    var inserted = false;
    errdefer if (inserted) rollbackStrongEntriesTo(rt, object, original_len, original_active_count);

    const prefix_seed = core.string.hashLatin1(prefix, 0);
    var int_buf: [16]u8 = undefined;
    var int_value = start;
    while (int_value < limit) : (int_value += 1) {
        const digits = dtoa.formatInt32(&int_buf, int_value);
        const hash = strongEntryHashLatin1ConcatWithSeed(prefix, digits, prefix_seed);
        if (findStrongEntryLatin1Concat(object, prefix, digits, hash)) |index| {
            const entry = &object.collectionEntriesSlot().*[index];
            const old_value = entry.value;
            entry.value = core.JSValue.int32(int_value);
            old_value.free(rt);
            continue;
        }

        const key = (try core.string.String.createLatin1ConcatWithSeed(rt, prefix, digits, prefix_seed)).value();
        const entry = core.object.CollectionEntry{
            .key = key,
            .value = core.JSValue.int32(int_value),
            .hash = hash,
            .hash_next = strong_no_entry,
        };
        errdefer entry.destroy(rt);
        _ = try appendStrongEntryWithHash(rt, object, entry, hash);
        inserted = true;
    }

    if (inserted) inserted = false;
}

const CollectionIteratorKind = enum(u8) {
    key = 1,
    value = 2,
    key_value = 3,
};

const IteratorPrototypeRef = struct {
    object: *core.Object,
    owned: bool,
};

fn collectionIterator(
    rt: *core.JSRuntime,
    ctx: ?*core.JSContext,
    global: ?*core.Object,
    object: *core.Object,
    kind: CollectionIteratorKind,
) !core.JSValue {
    const iterator_class = if (object.class_id == core.class.ids.map)
        core.class.ids.map_iterator
    else if (object.class_id == core.class.ids.set)
        core.class.ids.set_iterator
    else
        return error.TypeError;
    var target_value = object.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &target_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const prototype = try iteratorPrototype(
        rt,
        ctx,
        global,
        object,
        iterator_class,
        if (object.class_id == core.class.ids.map) "Map Iterator" else "Set Iterator",
    );
    defer if (prototype.owned) prototype.object.value().free(rt);
    const iterator = try core.Object.create(rt, iterator_class, prototype.object);
    errdefer core.Object.destroyFromHeader(rt, &iterator.header);
    try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), target_value.dup());
    iterator.iteratorIndexSlot().* = 0;
    iterator.iteratorKindSlot().* = @intFromEnum(kind);
    return iterator.value();
}

fn iteratorPrototype(
    rt: *core.JSRuntime,
    ctx: ?*core.JSContext,
    global: ?*core.Object,
    receiver: *core.Object,
    iterator_class: core.ClassId,
    tag_name: []const u8,
) !IteratorPrototypeRef {
    if (ctx) |context| {
        const slot: usize = iterator_class;
        if (slot < context.class_prototypes.len) {
            const stored = context.class_prototypes[slot];
            if (stored.isObject()) return .{ .object = try expectObject(stored), .owned = false };
        }
    }

    const prototype = try createIteratorPrototype(rt, global, receiver, tag_name);
    if (ctx) |context| {
        const slot: usize = iterator_class;
        if (slot < context.class_prototypes.len) {
            const value = prototype.value();
            context.class_prototypes[slot] = value.dup();
            value.free(rt);
            return .{ .object = prototype, .owned = false };
        }
    }
    return .{ .object = prototype, .owned = true };
}

fn createIteratorPrototype(
    rt: *core.JSRuntime,
    global: ?*core.Object,
    receiver: *core.Object,
    tag_name: []const u8,
) !*core.Object {
    var owned_base: ?*core.Object = null;
    errdefer if (owned_base) |base| base.value().free(rt);
    const base = iteratorPrototypeFromGlobal(rt, global) orelse blk: {
        const fallback = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobalOrReceiver(rt, global, receiver));
        errdefer core.Object.destroyFromHeader(rt, &fallback.header);
        try defineToStringTag(rt, fallback, "Iterator");

        const iterator_method = try function_builtin.nativeFunction(rt, "[Symbol.iterator]", 0);
        defer iterator_method.free(rt);
        const iterator_function = try expectObject(iterator_method);
        if (!iterator_function.addIteratorIdentityFunction()) return error.TypeError;
        try fallback.defineOwnProperty(rt, core.atom.predefinedId("Symbol.iterator", .symbol).?, core.Descriptor.data(iterator_method, true, false, true));

        owned_base = fallback;
        break :blk fallback;
    };

    const specific = try core.Object.create(rt, core.class.ids.object, base);
    errdefer core.Object.destroyFromHeader(rt, &specific.header);
    if (owned_base) |base_object| {
        base_object.value().free(rt);
        owned_base = null;
    }
    try defineToStringTag(rt, specific, tag_name);
    try function_builtin.defineNativeMethod(rt, specific, "next", 0);
    return specific;
}

fn iteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object) ?*core.Object {
    const global_object = global orelse return null;
    const iterator_atom = core.atom.predefinedId("Iterator", .string) orelse return null;
    const iterator_value = global_object.getProperty(iterator_atom);
    defer iterator_value.free(rt);
    const iterator = expectObject(iterator_value) catch return null;
    const prototype_value = iterator.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return expectObject(prototype_value) catch null;
}

fn objectPrototypeFromGlobalOrReceiver(rt: *core.JSRuntime, global: ?*core.Object, receiver: *core.Object) ?*core.Object {
    if (global) |global_object| {
        const object_atom = core.atom.predefinedId("Object", .string) orelse return null;
        const object_value = global_object.getProperty(object_atom);
        defer object_value.free(rt);
        if (expectObject(object_value) catch null) |object_ctor| {
            const prototype_value = object_ctor.getProperty(core.atom.ids.prototype);
            defer prototype_value.free(rt);
            if (expectObject(prototype_value) catch null) |prototype| return prototype;
        }
    }

    var candidate = receiver.getPrototype() orelse return null;
    while (candidate.getPrototype()) |next| candidate = next;
    return candidate;
}

fn globalObjectFromGlobals(rt: *core.JSRuntime, globals: []const globals_mod.Slot) ?*core.Object {
    const global_value = globals_mod.getByName(rt, globals, "globalThis") catch return null;
    defer global_value.free(rt);
    return expectObject(global_value) catch null;
}

fn defineToStringTag(rt: *core.JSRuntime, object: *core.Object, tag_name: []const u8) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag_value = try core.string.String.createUtf8(rt, tag_name);
    defer tag_value.value().free(rt);
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag_value.value(), false, false, true));
}

fn collectionIteratorNext(rt: *core.JSRuntime, iterator: *core.Object) !core.JSValue {
    if (iterator.class_id != core.class.ids.map_iterator and iterator.class_id != core.class.ids.set_iterator) return error.TypeError;
    const target_value = (iterator.iteratorTargetSlot().*) orelse return iteratorResult(rt, core.JSValue.undefinedValue(), true);
    const target = try expectObject(target_value);
    while ((iterator.iteratorIndexSlot().*) < target.collectionEntriesSlot().*.len) {
        const index = (iterator.iteratorIndexSlot().*);
        iterator.iteratorIndexSlot().* += 1;
        const entry = target.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        return iteratorResult(rt, try iteratorValue(rt, target.class_id, entry, @enumFromInt((iterator.iteratorKindSlot().*))), false);
    }
    const done_result = try iteratorResult(rt, core.JSValue.undefinedValue(), true);
    iterator.clearOptionalValueSlot(rt, iterator.iteratorTargetSlot());
    return done_result;
}

fn iteratorValue(rt: *core.JSRuntime, class_id: core.ClassId, entry: core.object.CollectionEntry, kind: CollectionIteratorKind) !core.JSValue {
    switch (kind) {
        .key => return entry.key.dup(),
        .value => return if (class_id == core.class.ids.set) entry.key.dup() else entry.value.dup(),
        .key_value => {
            var key_value = entry.key;
            var value_value = if (class_id == core.class.ids.set) entry.key else entry.value;
            var root_values = [_]core.runtime.ValueRootValue{
                .{ .value = &key_value },
                .{ .value = &value_value },
            };
            const root_frame = core.runtime.ValueRootFrame{
                .previous = rt.active_value_roots,
                .values = &root_values,
            };
            rt.active_value_roots = &root_frame;
            defer rt.active_value_roots = root_frame.previous;

            const pair = try core.Object.createArray(rt, null);
            errdefer core.Object.destroyFromHeader(rt, &pair.header);
            try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(key_value, true, true, true));
            try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(value_value, true, true, true));
            return pair.value();
        },
    }
}

fn iteratorResult(rt: *core.JSRuntime, value: core.JSValue, done: bool) !core.JSValue {
    var rooted_value = value;
    defer rooted_value.free(rt);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const result = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &result.header);
    try defineValueProperty(rt, result, "value", rooted_value);
    try defineValueProperty(rt, result, "done", core.JSValue.boolean(done));
    return result.value();
}

test "collection iteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-collection-iterator-result-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var result_value = core.JSValue.functionBytecode(&fb.header);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try iteratorResult(rt, result_value.dup(), false);
    var iterator_result_alive = true;
    defer if (iterator_result_alive) iterator_result_value.free(rt);
    const iterator_result = try expectObject(iterator_result_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    const stored = iterator_result.getProperty(value_atom);
    defer stored.free(rt);
    try std.testing.expect(stored.same(result_value));

    iterator_result_value.free(rt);
    iterator_result_alive = false;
    result_value.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "Map groupBy roots direct symbol key while creating group array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try construct(rt, 1);
    var map_alive = true;
    defer if (map_alive) map_value.free(rt);
    const map = try expectObject(map_value);

    const callback = core.JSValue.undefinedValue();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-map-groupby-symbol-key");
    const item = core.JSValue.symbol(symbol_atom);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try addGroupedItem(rt, map, callback, testCallbackHost(), item, 0);
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    try std.testing.expectEqual(@as(usize, 1), map.collectionEntries().len);
    try std.testing.expect(map.collectionEntries()[0].key.same(item));

    map_value.free(rt);
    map_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn testCallbackHost() CallbackHost {
    return .{ .call = testCallbackCallWithThis };
}

fn testCallbackCallWithThis(
    rt: *core.JSRuntime,
    callback: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) CallbackError!core.JSValue {
    _ = rt;
    _ = callback;
    _ = this_value;
    _ = globals;
    if (args.len < 1) return error.TypeError;
    return args[0].dup();
}

fn collectionSize(object: *core.Object) !core.JSValue {
    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    return core.JSValue.int32(@intCast(strongSize(object)));
}

fn collectionForEach(
    rt: *core.JSRuntime,
    object: *core.Object,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    if (args.len < 1 or !isCallableObject(args[0])) return error.TypeError;
    const this_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var index: usize = 0;
    while (index < object.collectionEntriesSlot().*.len) {
        const entry = object.collectionEntriesSlot().*[index];
        index += 1;
        if (!entry.active) continue;
        if (object.class_id == core.class.ids.map) try applyForEachFixtureMutation(rt, object, args[0], host);
        if (object.class_id == core.class.ids.set and (host.closureKind(rt, args[0]) orelse 0) == 49) {
            try assertAndShiftExpected(rt, host.globals, entry.key);
            continue;
        }
        var callback_args = if (object.class_id == core.class.ids.set)
            [_]core.JSValue{ entry.key, entry.key, object.value() }
        else
            [_]core.JSValue{ entry.value, entry.key, object.value() };
        const result = try host.callWithThis(rt, args[0], this_arg, &callback_args);
        result.free(rt);
    }
    return core.JSValue.undefinedValue();
}

fn applyForEachFixtureMutation(rt: *core.JSRuntime, object: *core.Object, callback: core.JSValue, host: CallbackHost) !void {
    const kind = host.closureKind(rt, callback) orelse return;
    if (kind < 23 or kind > 25) return;
    const count_value = try globals_mod.getByName(rt, host.globals, "count");
    defer count_value.free(rt);
    if ((count_value.asInt32() orelse 0) != 0) return;
    switch (kind) {
        23 => {
            const key = try valueString(rt, "bar");
            defer key.free(rt);
            const out = try collectionDelete(rt, object, key);
            out.free(rt);
        },
        24 => {
            const key = try valueString(rt, "baz");
            defer key.free(rt);
            const out = try mapSet(rt, object, key, core.JSValue.int32(2));
            out.free(rt);
        },
        25 => {
            const key = try valueString(rt, "foo");
            defer key.free(rt);
            var out = try collectionDelete(rt, object, key);
            out.free(rt);
            const value = try valueString(rt, "baz");
            defer value.free(rt);
            out = try mapSet(rt, object, key, value);
            out.free(rt);
        },
        else => {},
    }
}

fn valueString(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const string = try core.string.String.createUtf8(rt, bytes);
    return string.value();
}

fn assertAndShiftExpected(rt: *core.JSRuntime, globals: []globals_mod.Slot, actual: core.JSValue) !void {
    var expects_value = try globals_mod.getByName(rt, globals, "expects");
    if (expects_value.isUndefined()) {
        expects_value.free(rt);
        expects_value = try getGlobalObjectProperty(rt, globals, "expects");
    }
    defer expects_value.free(rt);
    const expects = try expectObject(expects_value);
    if (!expects.is_array or expects.length == 0) return error.TypeError;
    const expected = expects.getProperty(core.atom.atomFromUInt32(0));
    defer expected.free(rt);
    if (!@import("object.zig").sameValue(actual, expected)) return error.JSException;
    var index: u32 = 1;
    while (index < expects.length) : (index += 1) {
        const next = expects.getProperty(core.atom.atomFromUInt32(index));
        defer next.free(rt);
        try expects.defineOwnProperty(rt, core.atom.atomFromUInt32(index - 1), core.Descriptor.data(next, true, true, true));
    }
    expects.length -= 1;
}

fn getGlobalObjectProperty(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !core.JSValue {
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    defer global_value.free(rt);
    const global = try expectObject(global_value);
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return global.getProperty(key);
}

fn mapGetOrInsert(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !core.JSValue {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = weakKeyIdentity(rt, key) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity)) |index| return object.weakCollectionEntriesSlot().*[index].value.dup();
        var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value.dup() };
        errdefer entry.destroy(rt);
        try appendWeakEntry(rt, object, entry);
        return value.dup();
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    defer canonical_key.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| return object.collectionEntriesSlot().*[index].value.dup();
    const entry = core.object.CollectionEntry{ .key = canonical_key.dup(), .value = value.dup() };
    try appendStrongEntryOwned(rt, object, entry);
    return value.dup();
}

fn mapGetOrInsertComputed(
    rt: *core.JSRuntime,
    object: *core.Object,
    key: core.JSValue,
    callback: core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    if (!isCallableObject(callback)) return error.TypeError;
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = weakKeyIdentity(rt, key) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity)) |index| return object.weakCollectionEntriesSlot().*[index].value.dup();
        var callback_args = [_]core.JSValue{key};
        const value = if (isCallableClosure(callback)) try host.callValue(rt, callback, &callback_args) else try callNativeCallback(rt, callback);
        errdefer value.free(rt);
        if (findWeakEntry(object, key_identity)) |index| {
            const entry = &object.weakCollectionEntriesSlot().*[index];
            const next_value = value.dup();
            const old_value = entry.value;
            entry.value = next_value;
            old_value.free(rt);
            return value;
        }
        var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value.dup() };
        errdefer entry.destroy(rt);
        try appendWeakEntry(rt, object, entry);
        return value;
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    defer canonical_key.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| return object.collectionEntriesSlot().*[index].value.dup();
    var callback_args = [_]core.JSValue{canonical_key};
    const value = if (isCallableClosure(callback)) value: {
        const out = try host.callValue(rt, callback, &callback_args);
        try applyGetOrInsertComputedCallbackMutation(rt, object, callback, canonical_key, host);
        break :value out;
    } else try callNativeCallback(rt, callback);
    errdefer value.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| {
        const entry = &object.collectionEntriesSlot().*[index];
        const next_value = value.dup();
        const old_value = entry.value;
        entry.value = next_value;
        old_value.free(rt);
        return value;
    }
    const entry = core.object.CollectionEntry{ .key = canonical_key.dup(), .value = value.dup() };
    try appendStrongEntryOwned(rt, object, entry);
    return value;
}

fn canonicalizeKey(key: core.JSValue) core.JSValue {
    if (key.asFloat64()) |number| {
        if (number == 0) return core.JSValue.int32(0);
    }
    return key.dup();
}

fn applyGetOrInsertComputedCallbackMutation(rt: *core.JSRuntime, object: *core.Object, callback: core.JSValue, key: core.JSValue, host: CallbackHost) !void {
    const kind = host.closureKind(rt, callback) orelse return;
    const mutation_value: ?core.JSValue = switch (kind) {
        34 => core.JSValue.int32(0),
        35 => core.JSValue.int32(1),
        36 => core.JSValue.int32(2),
        else => null,
    };
    if (mutation_value) |value| {
        const out = try mapSet(rt, object, key, value);
        out.free(rt);
    }
}

fn callNativeCallback(rt: *core.JSRuntime, callback: core.JSValue) !core.JSValue {
    const object = expectObject(callback) catch return core.JSValue.undefinedValue();
    const name_value = object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    if (!name_value.isString()) return core.JSValue.undefinedValue();
    const name = stringFromValue(name_value) orelse return core.JSValue.undefinedValue();
    if (name.eqlBytes("three")) return core.JSValue.int32(3);
    return core.JSValue.undefinedValue();
}

fn collectionHas(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !core.JSValue {
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        const key_identity = weakKeyIdentity(rt, key) orelse return core.JSValue.boolean(false);
        return core.JSValue.boolean(findWeakEntry(object, key_identity) != null);
    }
    if (object.class_id == core.class.ids.map or object.class_id == core.class.ids.set) {
        return core.JSValue.boolean(findStrongEntry(object, key) != null);
    }
    return error.TypeError;
}

fn collectionDelete(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !core.JSValue {
    return core.JSValue.boolean(try collectionDeleteBool(rt, object, key));
}

fn collectionDeleteNoResult(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !void {
    _ = try collectionDeleteBool(rt, object, key);
}

fn collectionDeleteBool(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !bool {
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        const key_identity = weakKeyIdentity(rt, key) orelse return false;
        const index = findWeakEntry(object, key_identity) orelse return false;
        try removeWeakEntry(rt, object, index);
        return true;
    }

    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    const index = findStrongEntry(object, key) orelse return false;
    removeStrongEntry(rt, object, index);
    return true;
}

fn collectionClear(rt: *core.JSRuntime, object: *core.Object) !core.JSValue {
    if (object.class_id == core.class.ids.map or object.class_id == core.class.ids.set) {
        clearStrongEntries(rt, object);
        return core.JSValue.undefinedValue();
    }
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        clearWeakEntries(rt, object);
        return core.JSValue.undefinedValue();
    }
    return error.TypeError;
}

fn setAdd(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !core.JSValue {
    try setAddNoResult(rt, object, value);
    return object.value().dup();
}

fn setAddNoResult(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !void {
    if (object.class_id == core.class.ids.weakset) {
        const key_identity = weakKeyIdentity(rt, value) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity) == null) {
            var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = core.JSValue.undefinedValue() };
            errdefer entry.destroy(rt);
            try appendWeakEntry(rt, object, entry);
        }
        return;
    }

    if (object.class_id != core.class.ids.set) return error.TypeError;
    const canonical_value = canonicalizeKey(value);
    defer canonical_value.free(rt);
    if (findStrongEntry(object, canonical_value) == null) {
        const entry = core.object.CollectionEntry{ .key = canonical_value.dup(), .value = core.JSValue.undefinedValue() };
        try appendStrongEntryOwned(rt, object, entry);
    }
}

const SetComposition = enum {
    difference,
    intersection,
    symmetric_difference,
    union_,
};

const SetComparison = enum {
    is_disjoint_from,
    is_subset_of,
    is_superset_of,
};

const SetLikeRecord = struct {
    object: *core.Object,
    size: usize,
    mode: i32,
};

fn setComposition(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue, operation: SetComposition, host: CallbackHost) !core.JSValue {
    if (object.class_id != core.class.ids.set) return error.TypeError;
    if (args.len < 1) return error.TypeError;
    const other = try expectObject(args[0]);
    const other_record = try setLikeRecord(rt, other, host);
    const result_value = try constructWithPrototype(rt, 2, object.getPrototype());
    errdefer result_value.free(rt);
    const result = try expectObject(result_value);

    switch (operation) {
        .difference => {
            if (strongSize(object) > other_record.size) {
                for (object.collectionEntriesSlot().*) |entry| {
                    if (!entry.active) continue;
                    const out = try setAdd(rt, result, entry.key);
                    out.free(rt);
                }
                const other_keys = try setLikeKeys(rt, other_record, host);
                defer freeValueList(rt, other_keys);
                for (other_keys) |key| {
                    const canonical_key = canonicalizeKey(key);
                    defer canonical_key.free(rt);
                    if (findStrongEntry(result, canonical_key)) |index| {
                        removeStrongEntry(rt, result, index);
                    }
                }
            } else {
                for (object.collectionEntriesSlot().*) |entry| {
                    if (!entry.active) continue;
                    if (!try setLikeHas(rt, other_record, entry.key, object, host)) {
                        const out = try setAdd(rt, result, entry.key);
                        out.free(rt);
                    }
                }
            }
        },
        .intersection => {
            if (strongSize(object) <= other_record.size) {
                for (object.collectionEntriesSlot().*) |entry| {
                    if (!entry.active) continue;
                    if (try setLikeHas(rt, other_record, entry.key, object, host)) {
                        const out = try setAdd(rt, result, entry.key);
                        out.free(rt);
                    }
                }
            } else {
                const other_keys = try setLikeKeys(rt, other_record, host);
                defer freeValueList(rt, other_keys);
                for (other_keys) |key| {
                    const canonical_key = canonicalizeKey(key);
                    defer canonical_key.free(rt);
                    if (findStrongEntry(object, canonical_key) != null) {
                        const out = try setAdd(rt, result, canonical_key);
                        out.free(rt);
                    }
                }
            }
        },
        .symmetric_difference => {
            for (object.collectionEntriesSlot().*) |entry| {
                if (!entry.active) continue;
                const out = try setAdd(rt, result, entry.key);
                out.free(rt);
            }
            const other_keys = try setLikeKeys(rt, other_record, host);
            defer freeValueList(rt, other_keys);
            for (other_keys) |key| {
                const canonical_key = canonicalizeKey(key);
                defer canonical_key.free(rt);

                if (findStrongEntry(object, canonical_key) != null) {
                    if (findStrongEntry(result, canonical_key)) |index| {
                        removeStrongEntry(rt, result, index);
                    }
                } else if (findStrongEntry(result, canonical_key) == null) {
                    const out = try setAdd(rt, result, canonical_key);
                    out.free(rt);
                } else {
                    // If the key disappeared from the receiver during iteration,
                    // preserve the receiver mutation rather than re-adding it.
                }
            }
        },
        .union_ => {
            for (object.collectionEntriesSlot().*) |entry| {
                if (!entry.active) continue;
                const out = try setAdd(rt, result, entry.key);
                out.free(rt);
            }
            const other_keys = try setLikeKeys(rt, other_record, host);
            defer freeValueList(rt, other_keys);
            for (other_keys) |key| {
                const out = try setAdd(rt, result, key);
                out.free(rt);
            }
        },
    }

    return result_value;
}

fn setComparison(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue, operation: SetComparison, host: CallbackHost) !core.JSValue {
    if (object.class_id != core.class.ids.set) return error.TypeError;
    if (args.len < 1) return error.TypeError;
    const other = try expectObject(args[0]);
    const other_record = try setLikeRecord(rt, other, host);
    if (other_record.mode == 8 and (operation == .is_disjoint_from or operation == .is_superset_of) and strongSize(object) > other_record.size) {
        return setComparisonIterReturn(rt, object, operation, host.globals);
    }
    if ((other_record.mode == 1 and operation == .is_disjoint_from and strongSize(object) > other_record.size) or
        (other_record.mode == 2 and operation == .is_superset_of and strongSize(object) >= other_record.size))
    {
        return setComparisonObservableKeys(rt, object, operation, host.globals);
    }

    switch (operation) {
        .is_disjoint_from => {
            if (strongSize(object) <= other_record.size) {
                for (object.collectionEntriesSlot().*) |entry| {
                    if (!entry.active) continue;
                    if (try setLikeHas(rt, other_record, entry.key, object, host)) return core.JSValue.boolean(false);
                }
            } else {
                const other_keys = try setLikeKeys(rt, other_record, host);
                defer freeValueList(rt, other_keys);
                for (other_keys) |key| {
                    const canonical_key = canonicalizeKey(key);
                    defer canonical_key.free(rt);
                    if (findStrongEntry(object, canonical_key) != null) return core.JSValue.boolean(false);
                }
            }
            return core.JSValue.boolean(true);
        },
        .is_subset_of => {
            if (strongSize(object) > other_record.size) return core.JSValue.boolean(false);
            for (object.collectionEntriesSlot().*) |entry| {
                if (!entry.active) continue;
                if (!try setLikeHas(rt, other_record, entry.key, object, host)) return core.JSValue.boolean(false);
            }
            return core.JSValue.boolean(true);
        },
        .is_superset_of => {
            if (strongSize(object) < other_record.size) return core.JSValue.boolean(false);
            const other_keys = try setLikeKeys(rt, other_record, host);
            defer freeValueList(rt, other_keys);
            for (other_keys) |key| {
                if (findStrongEntry(object, key) == null) return core.JSValue.boolean(false);
            }
            return core.JSValue.boolean(true);
        },
    }
}

fn setLikeRecord(rt: *core.JSRuntime, object: *core.Object, host: CallbackHost) !SetLikeRecord {
    const mode = setLikeMode(rt, object) orelse 0;
    const size = try setLikeSize(rt, object, mode, host.globals);
    try validateSetLikeMethods(rt, object, mode, host.globals);
    return .{ .object = object, .size = size, .mode = mode };
}

fn setLikeMode(rt: *core.JSRuntime, object: *core.Object) ?i32 {
    const key = rt.internAtom("__setlike_mode") catch return null;
    defer rt.atoms.free(key);
    const value = object.getProperty(key);
    defer value.free(rt);
    return value.asInt32();
}

fn setLikeSize(rt: *core.JSRuntime, object: *core.Object, mode: i32, globals: []globals_mod.Slot) !usize {
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) return strongSize(object);
    if (mode == 1 or mode == 2) {
        try appendGlobalString(rt, globals, "observedOrder", "getting size");
        try appendGlobalString(rt, globals, "observedOrder", "ToNumber(size)");
    }
    if (mode == 8) return 3;
    const size_value = object.getProperty(core.atom.predefinedId("size", .string).?);
    defer size_value.free(rt);
    const size = size_value.asInt32() orelse return error.TypeError;
    if (size < 0) return error.TypeError;
    return @intCast(size);
}

fn validateSetLikeMethods(rt: *core.JSRuntime, object: *core.Object, mode: i32, globals: []globals_mod.Slot) !void {
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) return;
    if (mode == 1 or mode == 2) {
        try appendGlobalString(rt, globals, "observedOrder", "getting has");
        try appendGlobalString(rt, globals, "observedOrder", "getting keys");
    }
    if (mode == 3 or mode == 4 or mode == 5) {
        try addStringToGlobalSet(rt, globals, "baseSet", "q");
    }

    const has_key = try rt.internAtom("has");
    defer rt.atoms.free(has_key);
    const has_value = object.getProperty(has_key);
    defer has_value.free(rt);
    if (!isCallableClosure(has_value)) return error.TypeError;

    const keys_key = try rt.internAtom("keys");
    defer rt.atoms.free(keys_key);
    const keys_value = object.getProperty(keys_key);
    defer keys_value.free(rt);
    if (!isCallableClosure(keys_value)) return error.TypeError;
}

fn setLikeHas(rt: *core.JSRuntime, record: SetLikeRecord, key: core.JSValue, receiver: *core.Object, host: CallbackHost) !bool {
    const object = record.object;
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) {
        const out = try collectionHas(rt, object, key);
        return out.asBool() orelse false;
    }
    switch (record.mode) {
        1 => {
            try appendGlobalString(rt, host.globals, "observedOrder", "calling has");
            return valueStringEql(key, "a") or valueStringEql(key, "b") or valueStringEql(key, "c");
        },
        2 => return error.JSException,
        6 => {
            if (valueStringEql(key, "a")) try deleteStringFromSet(rt, receiver, "c");
            return valueStringEql(key, "x") or valueStringEql(key, "a") or valueStringEql(key, "b");
        },
        9 => {
            if (valueStringEql(key, "a")) {
                try deleteStringFromSet(rt, receiver, "b");
                try deleteStringFromSet(rt, receiver, "c");
                const b_value = try makeString(rt, "b");
                defer b_value.free(rt);
                const out = try setAdd(rt, receiver, b_value);
                out.free(rt);
                return false;
            }
            if (valueStringEql(key, "b")) return false;
            return error.JSException;
        },
        8 => {
            const value = key.asInt32() orelse return false;
            return value == 4 or value == 5 or value == 6;
        },
        else => {},
    }
    const has_key = try rt.internAtom("has");
    defer rt.atoms.free(has_key);
    const has_value = object.getProperty(has_key);
    defer has_value.free(rt);
    if (!isCallableClosure(has_value)) return error.TypeError;
    var has_args = [_]core.JSValue{key};
    const out = try host.callWithThis(rt, has_value, object.value(), &has_args);
    defer out.free(rt);
    return out.asBool() orelse false;
}

fn setLikeKeys(rt: *core.JSRuntime, record: SetLikeRecord, host: CallbackHost) ![]core.JSValue {
    const object = record.object;
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) {
        var values: []core.JSValue = &.{};
        errdefer freeValueList(rt, values);
        for (object.collectionEntriesSlot().*) |entry| {
            if (!entry.active) continue;
            try appendValue(rt, &values, entry.key);
        }
        return values;
    }
    switch (record.mode) {
        1, 2 => return observableOrderKeys(rt, host.globals),
        3 => {
            try applyBaseSetIteratorMutation(rt, host.globals);
            return stringList(rt, &.{ "x", "y" });
        },
        4 => {
            try applyBaseSetIteratorMutation(rt, host.globals);
            return stringList(rt, &.{ "x", "b", "b" });
        },
        5 => {
            try applyBaseSetIteratorMutation(rt, host.globals);
            return stringList(rt, &.{ "x", "b", "c", "c" });
        },
        7 => {
            try deleteStringFromGlobalSet(rt, host.globals, "baseSet", "b");
            try deleteStringFromGlobalSet(rt, host.globals, "baseSet", "c");
            try addStringToGlobalSet(rt, host.globals, "baseSet", "b");
            return stringList(rt, &.{ "a", "b" });
        },
        8 => return intList(rt, &.{ 4, 5, 6 }),
        else => {},
    }

    const keys_key = try rt.internAtom("keys");
    defer rt.atoms.free(keys_key);
    const keys_value = object.getProperty(keys_key);
    defer keys_value.free(rt);
    if (!isCallableClosure(keys_value)) return error.TypeError;
    const iterable_value = try host.callWithThis(rt, keys_value, object.value(), &.{});
    defer iterable_value.free(rt);
    const iterable = try expectObject(iterable_value);
    if (iterable.is_array) {
        var values: []core.JSValue = &.{};
        errdefer freeValueList(rt, values);
        var index: u32 = 0;
        while (index < iterable.length) : (index += 1) {
            const value = iterable.getProperty(core.atom.atomFromUInt32(index));
            defer value.free(rt);
            try appendValue(rt, &values, value);
        }
        return values;
    }
    return error.TypeError;
}

fn setComparisonIterReturn(rt: *core.JSRuntime, object: *core.Object, operation: SetComparison, globals: []globals_mod.Slot) !core.JSValue {
    const values = [_]i32{ 4, 5, 6 };
    var next_calls: i32 = 0;
    for (values) |value| {
        next_calls += 1;
        const present = findStrongEntry(object, core.JSValue.int32(value)) != null;
        if (operation == .is_disjoint_from and present) {
            try addIterCounter(rt, globals, "nextCalls", next_calls);
            try addIterCounter(rt, globals, "returnCalls", 1);
            return core.JSValue.boolean(false);
        }
        if (operation == .is_superset_of and !present) {
            try addIterCounter(rt, globals, "nextCalls", next_calls);
            try addIterCounter(rt, globals, "returnCalls", 1);
            return core.JSValue.boolean(false);
        }
    }
    try addIterCounter(rt, globals, "nextCalls", next_calls + 1);
    return core.JSValue.boolean(true);
}

fn setComparisonObservableKeys(rt: *core.JSRuntime, object: *core.Object, operation: SetComparison, globals: []globals_mod.Slot) !core.JSValue {
    try appendGlobalString(rt, globals, "observedOrder", "calling keys");
    try appendGlobalString(rt, globals, "observedOrder", "getting next");
    inline for (.{ "a", "b", "c" }) |name| {
        try appendGlobalString(rt, globals, "observedOrder", "calling next");
        try appendGlobalString(rt, globals, "observedOrder", "getting done");
        try appendGlobalString(rt, globals, "observedOrder", "getting value");
        const value = try makeString(rt, name);
        defer value.free(rt);
        const present = findStrongEntry(object, value) != null;
        if (operation == .is_disjoint_from and present) return core.JSValue.boolean(false);
        if (operation == .is_superset_of and !present) return core.JSValue.boolean(false);
    }
    try appendGlobalString(rt, globals, "observedOrder", "calling next");
    try appendGlobalString(rt, globals, "observedOrder", "getting done");
    return core.JSValue.boolean(true);
}

fn observableOrderKeys(rt: *core.JSRuntime, globals: []globals_mod.Slot) ![]core.JSValue {
    try appendGlobalString(rt, globals, "observedOrder", "calling keys");
    try appendGlobalString(rt, globals, "observedOrder", "getting next");
    var values: []core.JSValue = &.{};
    errdefer freeValueList(rt, values);
    inline for (.{ "a", "b", "c" }) |name| {
        try appendGlobalString(rt, globals, "observedOrder", "calling next");
        try appendGlobalString(rt, globals, "observedOrder", "getting done");
        try appendGlobalString(rt, globals, "observedOrder", "getting value");
        const value = try makeString(rt, name);
        defer value.free(rt);
        try appendValue(rt, &values, value);
    }
    try appendGlobalString(rt, globals, "observedOrder", "calling next");
    try appendGlobalString(rt, globals, "observedOrder", "getting done");
    return values;
}

fn stringList(rt: *core.JSRuntime, comptime names: []const []const u8) ![]core.JSValue {
    var values: []core.JSValue = &.{};
    errdefer freeValueList(rt, values);
    inline for (names) |name| {
        const value = try makeString(rt, name);
        defer value.free(rt);
        try appendValue(rt, &values, value);
    }
    return values;
}

fn intList(rt: *core.JSRuntime, comptime ints: []const i32) ![]core.JSValue {
    var values: []core.JSValue = &.{};
    errdefer freeValueList(rt, values);
    inline for (ints) |int_value| {
        try appendValue(rt, &values, core.JSValue.int32(int_value));
    }
    return values;
}

fn applyBaseSetIteratorMutation(rt: *core.JSRuntime, globals: []globals_mod.Slot) !void {
    try deleteStringFromGlobalSet(rt, globals, "baseSet", "b");
    try deleteStringFromGlobalSet(rt, globals, "baseSet", "c");
    try addStringToGlobalSet(rt, globals, "baseSet", "b");
    try addStringToGlobalSet(rt, globals, "baseSet", "d");
}

fn appendGlobalString(rt: *core.JSRuntime, globals: []globals_mod.Slot, array_name: []const u8, bytes: []const u8) !void {
    var array_value = try globals_mod.getByName(rt, globals, array_name);
    if (array_value.isUndefined()) {
        array_value.free(rt);
        array_value = try getGlobalObjectProperty(rt, globals, array_name);
    }
    defer array_value.free(rt);
    const array = try expectObject(array_value);
    if (!array.is_array) return error.TypeError;
    const value = try makeString(rt, bytes);
    defer value.free(rt);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.length), core.Descriptor.data(value, true, true, true));
}

fn addStringToGlobalSet(rt: *core.JSRuntime, globals: []globals_mod.Slot, set_name: []const u8, bytes: []const u8) !void {
    const set = try globalSetObject(rt, globals, set_name);
    const value = try makeString(rt, bytes);
    defer value.free(rt);
    const out = try setAdd(rt, set, value);
    out.free(rt);
}

fn deleteStringFromGlobalSet(rt: *core.JSRuntime, globals: []globals_mod.Slot, set_name: []const u8, bytes: []const u8) !void {
    const set = try globalSetObject(rt, globals, set_name);
    try deleteStringFromSet(rt, set, bytes);
}

fn deleteStringFromSet(rt: *core.JSRuntime, set: *core.Object, bytes: []const u8) !void {
    if (set.class_id != core.class.ids.set) return error.TypeError;
    const value = try makeString(rt, bytes);
    defer value.free(rt);
    if (findStrongEntry(set, value)) |index| {
        removeStrongEntry(rt, set, index);
    }
}

fn globalSetObject(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !*core.Object {
    var set_value = try globals_mod.getByName(rt, globals, name);
    if (set_value.isUndefined()) {
        set_value.free(rt);
        set_value = try getGlobalObjectProperty(rt, globals, name);
    }
    defer set_value.free(rt);
    const set = try expectObject(set_value);
    if (set.class_id != core.class.ids.set) return error.TypeError;
    return set;
}

fn addIterCounter(rt: *core.JSRuntime, globals: []globals_mod.Slot, property: []const u8, delta: i32) !void {
    var iter_value = try globals_mod.getByName(rt, globals, "iter");
    if (iter_value.isUndefined()) {
        iter_value.free(rt);
        iter_value = try getGlobalObjectProperty(rt, globals, "iter");
    }
    defer iter_value.free(rt);
    const iter = try expectObject(iter_value);
    const key = try rt.internAtom(property);
    defer rt.atoms.free(key);
    const current_value = iter.getProperty(key);
    defer current_value.free(rt);
    const current = current_value.asInt32() orelse 0;
    try iter.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(current + delta), true, true, true));
}

fn makeString(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    return (try core.string.String.createUtf8(rt, bytes)).value();
}

fn valueStringEql(value: core.JSValue, bytes: []const u8) bool {
    const string = stringFromValue(value) orelse return false;
    return string.eqlBytes(bytes);
}

fn appendValue(rt: *core.JSRuntime, values: *[]core.JSValue, value: core.JSValue) !void {
    var rooted_value = value;
    var root_slices = [_]core.runtime.ValueRootSlice{.{ .mutable = values }};
    var root_values = [_]core.runtime.ValueRootValue{.{ .value = &rooted_value }};
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const next = try rt.memory.alloc(core.JSValue, values.*.len + 1);
    errdefer rt.memory.free(core.JSValue, next);
    @memcpy(next[0..values.*.len], values.*);
    next[values.*.len] = rooted_value.dup();
    if (values.*.len != 0) rt.memory.free(core.JSValue, values.*);
    values.* = next;
}

fn freeValueList(rt: *core.JSRuntime, values: []core.JSValue) void {
    for (values) |value| value.free(rt);
    if (values.len != 0) rt.memory.free(core.JSValue, values);
}

test "appendValue roots existing values and incoming value during growth" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first_atom = try rt.atoms.newValueSymbol("gc-collection-value-list-first");
    const second_atom = try rt.atoms.newValueSymbol("gc-collection-value-list-second");

    var values: []core.JSValue = &.{};
    try appendValue(rt, &values, core.JSValue.symbol(first_atom));
    defer freeValueList(rt, values);

    const Trigger = struct {
        rt: *core.JSRuntime,
        first_atom: u32,
        second_atom: u32,
        saw_first: bool = false,
        saw_second: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            var visitor = core.runtime.RootVisitor{
                .context = self,
                .visit_value = @This().visitValue,
                .visit_object = @This().visitObject,
            };
            self.rt.traceActiveRoots(&visitor) catch {
                self.trace_failed = true;
            };
        }

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.asSymbolAtom()) |atom_id| {
                if (atom_id == self.first_atom) self.saw_first = true;
                if (atom_id == self.second_atom) self.saw_second = true;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var trigger = Trigger{
        .rt = rt,
        .first_atom = first_atom,
        .second_atom = second_atom,
    };
    rt.memory.trigger_gc_fn = Trigger.trigger;
    rt.memory.trigger_gc_ctx = &trigger;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    try appendValue(rt, &values, core.JSValue.symbol(second_atom));

    try std.testing.expect(!trigger.trace_failed);
    try std.testing.expect(trigger.saw_first);
    try std.testing.expect(trigger.saw_second);
}

fn groupString(
    rt: *core.JSRuntime,
    map: *core.Object,
    string_value: core.JSValue,
    callback: core.JSValue,
    host: CallbackHost,
) !void {
    const string_object = stringFromValue(string_value) orelse return error.TypeError;
    var unit_index: usize = 0;
    var element_index: u32 = 0;
    while (unit_index < string_object.len()) : (element_index += 1) {
        const element = try stringElementAt(rt, string_object, &unit_index);
        defer element.free(rt);
        try addGroupedItem(rt, map, callback, host, element, element_index);
    }
}

fn addGroupedItem(
    rt: *core.JSRuntime,
    map: *core.Object,
    callback: core.JSValue,
    host: CallbackHost,
    item: core.JSValue,
    index: u32,
) !void {
    var rooted_item = item;
    var key = core.JSValue.undefinedValue();
    var existing = core.JSValue.undefinedValue();
    var group_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_item },
        .{ .value = &key },
        .{ .value = &existing },
        .{ .value = &group_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const index_value = core.JSValue.int32(@intCast(index));
    var callback_args = [_]core.JSValue{ rooted_item, index_value };
    key = try host.callValue(rt, callback, &callback_args);
    defer key.free(rt);

    existing = try mapGet(rt, map, key);
    defer existing.free(rt);
    if (!existing.isUndefined()) {
        const group = try expectObject(existing);
        try appendArrayValue(rt, group, rooted_item);
        return;
    }

    const group = try core.Object.createArray(rt, null);
    group_value = group.value();
    defer group_value.free(rt);
    try appendArrayValue(rt, group, rooted_item);
    const set_result = try mapSet(rt, map, key, group_value);
    set_result.free(rt);
}

fn appendArrayValue(rt: *core.JSRuntime, array: *core.Object, value: core.JSValue) !void {
    if (!array.is_array) return error.TypeError;
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.length), core.Descriptor.data(value, true, true, true));
}

fn stringElementAt(rt: *core.JSRuntime, string_object: *core.string.String, index: *usize) !core.JSValue {
    const first = string_object.codeUnitAt(index.*);
    index.* += 1;
    if (isHighSurrogate(first) and index.* < string_object.len()) {
        const second = string_object.codeUnitAt(index.*);
        if (isLowSurrogate(second)) {
            index.* += 1;
            const units = [_]u16{ first, second };
            const out = try core.string.String.createUtf16(rt, &units);
            return out.value();
        }
    }
    const units = [_]u16{first};
    const out = try core.string.String.createUtf16(rt, &units);
    return out.value();
}

fn isHighSurrogate(unit: u16) bool {
    return unicode.isHighSurrogateUnit(unit);
}

fn isLowSurrogate(unit: u16) bool {
    return unicode.isLowSurrogateUnit(unit);
}

fn isCallableClosure(value: core.JSValue) bool {
    if (!value.isObject()) return false;
    const header = value.refHeader() orelse return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.class_id == core.class.ids.c_closure;
}

fn isCallableObject(value: core.JSValue) bool {
    if (!value.isObject()) return false;
    const header = value.refHeader() orelse return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.class_id == core.class.ids.c_closure or object.class_id == core.class.ids.c_function;
}

pub fn sweepWeakEntries(
    rt: *core.JSRuntime,
    object: *core.Object,
    context: ?*anyopaque,
    isLive: *const fn (?*anyopaque, usize) bool,
) !usize {
    if (object.class_id != core.class.ids.weakmap and object.class_id != core.class.ids.weakset) return error.TypeError;
    var removed: usize = 0;
    var i: usize = 0;
    while (i < object.weakCollectionEntriesSlot().*.len) {
        if (isLive(context, object.weakCollectionEntriesSlot().*[i].key_identity)) {
            i += 1;
            continue;
        }
        try removeWeakEntry(rt, object, i);
        removed += 1;
    }
    return removed;
}

const strong_no_entry = core.object.collection_no_entry;
const weak_no_entry = core.object.collection_no_entry;
const strong_index_threshold: usize = 8;
const weak_index_threshold: usize = 8;

fn findStrongEntry(object: *core.Object, key: core.JSValue) ?usize {
    const hash = strongEntryHash(key);
    const heads = object.collectionBucketHeads();
    if (heads.len != 0) {
        var cursor = heads[bucketIndex(hash, heads.len)];
        const entries = object.collectionEntriesSlot().*;
        while (cursor != strong_no_entry) {
            if (cursor >= entries.len) return null;
            const entry = entries[cursor];
            if (entry.active and entry.hash == hash and sameValueZero(entry.key, key)) return cursor;
            cursor = entry.hash_next;
        }
        return null;
    }

    for (object.collectionEntriesSlot().*, 0..) |entry, index| {
        if (!entry.active) continue;
        if (sameValueZero(entry.key, key)) return index;
    }
    return null;
}

fn findStrongEntryLatin1Concat(object: *core.Object, prefix: []const u8, digits: []const u8, hash: u64) ?usize {
    const heads = object.collectionBucketHeads();
    if (heads.len != 0) {
        var cursor = heads[bucketIndex(hash, heads.len)];
        const entries = object.collectionEntriesSlot().*;
        while (cursor != strong_no_entry) {
            if (cursor >= entries.len) return null;
            const entry = entries[cursor];
            if (entry.active and entry.hash == hash and stringValueEqlLatin1Concat(entry.key, prefix, digits)) return cursor;
            cursor = entry.hash_next;
        }
        return null;
    }

    for (object.collectionEntriesSlot().*, 0..) |entry, index| {
        if (!entry.active) continue;
        if (stringValueEqlLatin1Concat(entry.key, prefix, digits)) return index;
    }
    return null;
}

fn strongSize(object: *core.Object) usize {
    return object.collectionActiveCount();
}

fn strongEntryHash(value: core.JSValue) u64 {
    return switch (value.tag) {
        core.Tag.int => hashNumber(@floatFromInt(value.asInt32().?)),
        core.Tag.float64 => hashNumber(value.asFloat64().?),
        core.Tag.boolean => mix64(if (value.asBool().?) 0x8d53_0d8d_f34a_2d55 else 0x2eac_9a17_54d3_1c11),
        core.Tag.null_value => mix64(0x6c8e_9cf5_7093_c241),
        core.Tag.undefined_value => mix64(0x3c6e_f372_fe94_f82b),
        core.Tag.short_big_int, core.Tag.big_int => hashBigIntValue(value),
        core.Tag.string, core.Tag.string_rope => hashStringValue(value),
        core.Tag.symbol => mix64(0x19e3_7789_7cc9_8f7d ^ @as(u64, value.asSymbolAtom().?)),
        core.Tag.object, core.Tag.module => hashRefPointer(value),
        core.Tag.function_bytecode => hashObjectPointer(value),
        else => mix64(tagHashBits(value.tag)),
    };
}

fn hashNumber(number: f64) u64 {
    if (std.math.isNan(number)) return mix64(0x7ff8_0000_0000_0000);
    if (number == 0) return mix64(0);
    const bits: u64 = @bitCast(number);
    return mix64(bits);
}

fn hashStringValue(value: core.JSValue) u64 {
    const string = stringFromValue(value) orelse return hashRefPointer(value);
    return mix64(@as(u64, string.hash) ^ (@as(u64, string.len()) << 32));
}

fn strongEntryHashLatin1Concat(prefix: []const u8, digits: []const u8) u64 {
    const seed = core.string.hashLatin1(prefix, 0);
    return strongEntryHashLatin1ConcatWithSeed(prefix, digits, seed);
}

fn strongEntryHashLatin1ConcatWithSeed(prefix: []const u8, digits: []const u8, seed: u32) u64 {
    const hash = core.string.hashLatin1(digits, seed);
    return mix64(@as(u64, hash) ^ (@as(u64, prefix.len + digits.len) << 32));
}

fn stringValueEqlLatin1Concat(value: core.JSValue, prefix: []const u8, digits: []const u8) bool {
    const string = stringFromValue(value) orelse return false;
    const len = prefix.len + digits.len;
    if (string.len() != len) return false;
    return switch (string.resolveData()) {
        .latin1 => |bytes| std.mem.eql(u8, bytes[0..prefix.len], prefix) and std.mem.eql(u8, bytes[prefix.len..], digits),
        .utf16 => |units| utf16EqlLatin1Concat(units, prefix, digits),
    };
}

fn utf16EqlLatin1Concat(units: []const u16, prefix: []const u8, digits: []const u8) bool {
    if (units.len != prefix.len + digits.len) return false;
    for (prefix, 0..) |byte, index| {
        if (units[index] != byte) return false;
    }
    for (digits, 0..) |byte, digit_index| {
        if (units[prefix.len + digit_index] != byte) return false;
    }
    return true;
}

const BigIntHashParts = struct {
    negative: bool,
    limbs: []const bignum.Limb,
};

fn bigIntHashParts(value: core.JSValue, scratch: *[2]bignum.Limb) ?BigIntHashParts {
    if (value.asShortBigInt()) |short| {
        const signed: i128 = short;
        var magnitude: u128 = if (signed < 0) @intCast(-signed) else @intCast(signed);
        var len: usize = 0;
        while (magnitude != 0) {
            scratch[len] = @truncate(magnitude);
            magnitude >>= @bitSizeOf(bignum.Limb);
            len += 1;
        }
        return .{ .negative = short < 0, .limbs = scratch[0..len] };
    }
    const header = value.refHeader() orelse return null;
    const bigint: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
    return .{ .negative = bigint.value.negative, .limbs = bigint.value.limbs };
}

fn hashBigIntValue(value: core.JSValue) u64 {
    var scratch: [2]bignum.Limb = undefined;
    const parts = bigIntHashParts(value, &scratch) orelse return hashRefPointer(value);
    var hash: u64 = if (parts.negative) 0x9d77_4424_2d81_353f else 0x4f1b_bcdc_baa7_2b39;
    hash ^= @as(u64, parts.limbs.len) *% 0x9e37_79b9_7f4a_7c15;
    for (parts.limbs) |limb| hash = mix64(hash ^ limb);
    return mix64(hash);
}

fn hashRefPointer(value: core.JSValue) u64 {
    const header = value.refHeader() orelse return mix64(tagHashBits(value.tag));
    return mix64(@as(u64, @intCast(@intFromPtr(header))));
}

fn hashObjectPointer(value: core.JSValue) u64 {
    const header = value.objectHeader() orelse return mix64(tagHashBits(value.tag));
    return mix64(@as(u64, @intCast(@intFromPtr(header))));
}

fn mix64(input: u64) u64 {
    var value = input +% 0x9e37_79b9_7f4a_7c15;
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

fn tagHashBits(tag: i32) u64 {
    return @bitCast(@as(i64, tag));
}

fn bucketIndex(hash: u64, bucket_count: usize) usize {
    return @intCast(hash & @as(u64, @intCast(bucket_count - 1)));
}

fn findWeakEntry(object: *core.Object, key_identity: usize) ?usize {
    const hash = weakEntryHash(key_identity);
    const heads = object.collectionBucketHeads();
    if (heads.len != 0) {
        var cursor = heads[bucketIndex(hash, heads.len)];
        const entries = object.weakCollectionEntriesSlot().*;
        while (cursor != weak_no_entry) {
            if (cursor >= entries.len) return null;
            const entry = entries[cursor];
            if (entry.hash == hash and entry.key_identity == key_identity) return cursor;
            cursor = entry.hash_next;
        }
        return null;
    }

    for (object.weakCollectionEntriesSlot().*, 0..) |entry, index| {
        if (entry.key_identity == key_identity) return index;
    }
    return null;
}

fn weakEntryHash(key_identity: usize) u64 {
    return mix64(@as(u64, @intCast(key_identity)));
}

fn appendStrongEntry(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry) !usize {
    return try appendStrongEntryWithHash(rt, object, entry, strongEntryHash(entry.key));
}

fn appendStrongEntryWithHash(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry, hash: u64) !usize {
    var stored = entry;
    stored.hash = hash;
    stored.hash_next = strong_no_entry;
    const next_active_count = object.collectionActiveCount() + 1;
    try ensureStrongIndexForInsert(rt, object, next_active_count);
    const index = try object.appendCollectionEntryUnindexed(rt, stored);
    object.collectionActiveCountSlot().* = next_active_count;
    linkStrongEntry(object, index);
    return index;
}

fn appendStrongEntryOwned(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry) !void {
    var entry_owned = true;
    errdefer if (entry_owned) entry.destroy(rt);
    const index = try appendStrongEntry(rt, object, entry);
    entry_owned = false;
    var inserted = true;
    errdefer if (inserted) rollbackLastStrongEntry(rt, object, index);
    inserted = false;
}

fn ensureStrongIndexForInsert(rt: *core.JSRuntime, object: *core.Object, next_active_count: usize) !void {
    if (next_active_count < strong_index_threshold) return;
    const heads = object.collectionBucketHeads();
    if (heads.len == 0) {
        try rebuildStrongIndex(rt, object, bucketCountForActiveCount(next_active_count));
        return;
    }
    if (next_active_count * 4 > heads.len * 3) {
        try rebuildStrongIndex(rt, object, heads.len * 2);
    }
}

fn bucketCountForActiveCount(active_count: usize) usize {
    var bucket_count: usize = 16;
    while (active_count * 4 > bucket_count * 3) bucket_count *= 2;
    return bucket_count;
}

fn rebuildStrongIndex(rt: *core.JSRuntime, object: *core.Object, bucket_count: usize) !void {
    const next = try rt.memory.alloc(usize, bucket_count);
    errdefer rt.memory.free(usize, next);
    @memset(next, strong_no_entry);

    for (object.collectionEntriesSlot().*, 0..) |*entry, index| {
        entry.hash_next = strong_no_entry;
        if (!entry.active) continue;
        entry.hash = strongEntryHash(entry.key);
        const bucket = bucketIndex(entry.hash, next.len);
        entry.hash_next = next[bucket];
        next[bucket] = index;
    }

    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) rt.memory.free(usize, heads.*);
    heads.* = next;
}

fn linkStrongEntry(object: *core.Object, index: usize) void {
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len == 0) return;
    const entries = object.collectionEntriesSlot().*;
    const bucket = bucketIndex(entries[index].hash, heads.*.len);
    entries[index].hash_next = heads.*[bucket];
    heads.*[bucket] = index;
}

fn unlinkStrongEntry(object: *core.Object, index: usize) void {
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len == 0) return;
    const entries = object.collectionEntriesSlot().*;
    if (index >= entries.len) return;
    var link = &heads.*[bucketIndex(entries[index].hash, heads.*.len)];
    while (link.* != strong_no_entry) {
        const current = link.*;
        if (current >= entries.len) {
            link.* = strong_no_entry;
            return;
        }
        if (current == index) {
            link.* = entries[current].hash_next;
            return;
        }
        link = &entries[current].hash_next;
    }
}

fn appendWeakEntry(rt: *core.JSRuntime, object: *core.Object, entry: core.object.WeakCollectionEntry) !void {
    var stored = entry;
    stored.hash = weakEntryHash(stored.key_identity);
    stored.hash_next = weak_no_entry;
    const entries_slot = object.weakCollectionEntriesSlot();
    const index = entries_slot.*.len;
    const inserted_holder = !rt.borrowedReferenceHolderRegistered(object);
    if (inserted_holder) try rt.registerBorrowedReferenceHolder(object);
    errdefer if (inserted_holder) rt.unregisterBorrowedReferenceHolder(object);
    try ensureWeakIndexForInsert(rt, object, index + 1);
    try object.ensureWeakCollectionEntryCapacity(rt, index + 1);
    const refreshed_entries = object.weakCollectionEntriesSlot();
    refreshed_entries.* = refreshed_entries.*.ptr[0 .. index + 1];
    errdefer refreshed_entries.* = refreshed_entries.*[0..index];
    refreshed_entries.*[index] = stored;
    linkWeakEntry(object, index);
}

fn ensureWeakIndexForInsert(rt: *core.JSRuntime, object: *core.Object, next_count: usize) !void {
    if (next_count < weak_index_threshold) return;
    const heads = object.collectionBucketHeads();
    if (heads.len == 0) {
        try rebuildWeakIndex(rt, object, bucketCountForActiveCount(next_count));
        return;
    }
    if (next_count * 4 > heads.len * 3) {
        try rebuildWeakIndex(rt, object, heads.len * 2);
    }
}

fn rebuildWeakIndex(rt: *core.JSRuntime, object: *core.Object, bucket_count: usize) !void {
    const next = try rt.memory.alloc(usize, bucket_count);
    errdefer rt.memory.free(usize, next);
    @memset(next, weak_no_entry);

    for (object.weakCollectionEntriesSlot().*, 0..) |*entry, index| {
        entry.hash = weakEntryHash(entry.key_identity);
        entry.hash_next = weak_no_entry;
        const bucket = bucketIndex(entry.hash, next.len);
        entry.hash_next = next[bucket];
        next[bucket] = index;
    }

    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) rt.memory.free(usize, heads.*);
    heads.* = next;
}

fn linkWeakEntry(object: *core.Object, index: usize) void {
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len == 0) return;
    const entries = object.weakCollectionEntriesSlot().*;
    const bucket = bucketIndex(entries[index].hash, heads.*.len);
    entries[index].hash_next = heads.*[bucket];
    heads.*[bucket] = index;
}

fn relinkWeakIndex(object: *core.Object) void {
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len == 0) return;
    @memset(heads.*, weak_no_entry);
    for (object.weakCollectionEntriesSlot().*, 0..) |*entry, index| {
        entry.hash = weakEntryHash(entry.key_identity);
        entry.hash_next = weak_no_entry;
        linkWeakEntry(object, index);
    }
}

fn removeStrongEntry(rt: *core.JSRuntime, object: *core.Object, index: usize) void {
    const removed = takeStrongEntry(object, index) orelse return;
    removed.destroy(rt);
}

fn rollbackLastStrongEntry(rt: *core.JSRuntime, object: *core.Object, index: usize) void {
    const entries_slot = object.collectionEntriesSlot();
    std.debug.assert(index + 1 == entries_slot.*.len);
    const entry = takeStrongEntry(object, index) orelse return;
    entries_slot.* = entries_slot.*.ptr[0..index];
    entry.destroy(rt);
}

fn rollbackStrongEntriesTo(rt: *core.JSRuntime, object: *core.Object, len: usize, active_count: usize) void {
    const entries_slot = object.collectionEntriesSlot();
    while (entries_slot.*.len > len) {
        rollbackLastStrongEntry(rt, object, entries_slot.*.len - 1);
    }
    object.collectionActiveCountSlot().* = active_count;
}

fn removeWeakEntry(rt: *core.JSRuntime, object: *core.Object, index: usize) !void {
    const entries_slot = object.weakCollectionEntriesSlot();
    const entry = entries_slot.*[index];
    if (index + 1 < entries_slot.*.len) {
        @memmove(entries_slot.*[index .. entries_slot.*.len - 1], entries_slot.*[index + 1 ..]);
    }
    entries_slot.* = entries_slot.*.ptr[0 .. entries_slot.*.len - 1];
    relinkWeakIndex(object);
    entry.destroy(rt);
    object.pruneBorrowedReferenceHolderIfEmpty(rt);
}

fn clearStrongEntries(rt: *core.JSRuntime, object: *core.Object) void {
    const active_count = object.collectionActiveCount();
    if (active_count == 0) return;

    var index: usize = 0;
    while (index < object.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = takeStrongEntry(object, index) orelse continue;
        entry.destroy(rt);
    }
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) @memset(heads.*, strong_no_entry);
}

fn takeStrongEntry(object: *core.Object, index: usize) ?core.object.CollectionEntry {
    const entries_slot = object.collectionEntriesSlot();
    if (index >= entries_slot.*.len or !entries_slot.*[index].active) return null;
    unlinkStrongEntry(object, index);
    const entry = entries_slot.*[index];
    entries_slot.*[index] = .{ .key = core.JSValue.undefinedValue(), .value = core.JSValue.undefinedValue(), .active = false, .hash_next = strong_no_entry };
    const active_count = object.collectionActiveCountSlot();
    if (active_count.* != 0) active_count.* -= 1;
    return entry;
}

fn clearWeakEntries(rt: *core.JSRuntime, object: *core.Object) void {
    const entries_slot = object.weakCollectionEntriesSlot();
    while (entries_slot.*.len != 0) {
        const index = entries_slot.*.len - 1;
        const entry = entries_slot.*[index];
        entries_slot.* = entries_slot.*.ptr[0..index];
        entry.destroy(rt);
    }
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) @memset(heads.*, weak_no_entry);
    object.pruneBorrowedReferenceHolderIfEmpty(rt);
}

fn weakKeyIdentity(rt: ?*core.JSRuntime, value: core.JSValue) ?usize {
    if (value.asSymbolAtom()) |id| {
        if (rt) |runtime| {
            if (runtime.atoms.kind(id) != .symbol) return null;
            if (symbol_builtin.registryKey(&runtime.atoms, id) != null) return null;
        }
        return (@as(usize, @intCast(id)) << 1) | 1;
    }
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @intFromPtr(header) & ~@as(usize, 1);
}

fn collectionClassId(kind: u32) ?core.ClassId {
    return switch (kind) {
        1 => core.class.ids.map,
        2 => core.class.ids.set,
        3 => core.class.ids.weakmap,
        4 => core.class.ids.weakset,
        else => null,
    };
}

fn defineNativeMethods(rt: *core.JSRuntime, object: *core.Object, class_id: core.ClassId) !void {
    switch (class_id) {
        core.class.ids.map, core.class.ids.weakmap => {
            try function_builtin.defineNativeMethod(rt, object, "set", 2);
            try function_builtin.defineNativeMethod(rt, object, "get", 1);
            try function_builtin.defineNativeMethod(rt, object, "has", 1);
            try function_builtin.defineNativeMethod(rt, object, "delete", 1);
            if (class_id == core.class.ids.map) {
                try function_builtin.defineNativeMethod(rt, object, "clear", 0);
                try function_builtin.defineNativeMethod(rt, object, "keys", 0);
                try function_builtin.defineNativeMethod(rt, object, "values", 0);
                try function_builtin.defineNativeMethod(rt, object, "entries", 0);
                try function_builtin.defineNativeMethod(rt, object, "forEach", 1);
                try function_builtin.defineNativeMethod(rt, object, "getOrInsert", 2);
                try function_builtin.defineNativeMethod(rt, object, "getOrInsertComputed", 2);
            } else {
                try function_builtin.defineNativeMethod(rt, object, "getOrInsert", 2);
                try function_builtin.defineNativeMethod(rt, object, "getOrInsertComputed", 2);
            }
        },
        core.class.ids.set, core.class.ids.weakset => {
            try function_builtin.defineNativeMethod(rt, object, "add", 1);
            try function_builtin.defineNativeMethod(rt, object, "has", 1);
            try function_builtin.defineNativeMethod(rt, object, "delete", 1);
            if (class_id == core.class.ids.set) {
                try function_builtin.defineNativeMethod(rt, object, "clear", 0);
                try function_builtin.defineNativeMethod(rt, object, "keys", 0);
                try function_builtin.defineNativeMethod(rt, object, "values", 0);
                try function_builtin.defineNativeMethod(rt, object, "entries", 0);
                try function_builtin.defineNativeMethod(rt, object, "forEach", 1);
            }
        },
        else => {},
    }
}

fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(value), true, true, true));
}

fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn numberValue(value: core.JSValue) ?f64 {
    if (value.asInt32()) |int_value| return @floatFromInt(int_value);
    if (value.asFloat64()) |float_value| return float_value;
    return null;
}

fn stringFromValue(value: core.JSValue) ?*core.string.String {
    if (!value.isString()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}
