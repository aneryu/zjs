const core = @import("../core/root.zig");
const core_array = @import("../core/array.zig");
const buffer_builtin = @import("buffer_ops.zig");
const bignum = @import("../libs/bigint.zig");
const std = @import("std");
const builtin_glue = @import("builtin_glue.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const exception_ops = @import("vm_exception_ops.zig");

const HostError = @import("exceptions.zig").HostError;
const InternalCall = core.host_function.InternalCall;

const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

const RootedValueCopies = struct {
    values: []core.JSValue,
    roots: []core.runtime.ValueRootValue,

    fn init(rt: *core.JSRuntime, source: []const core.JSValue) !RootedValueCopies {
        const values = try rt.memory.alloc(core.JSValue, source.len);
        errdefer rt.memory.free(core.JSValue, values);
        @memcpy(values, source);

        const roots = try rt.memory.alloc(core.runtime.ValueRootValue, source.len);
        errdefer rt.memory.free(core.runtime.ValueRootValue, roots);
        for (values, 0..) |*value, index| {
            roots[index] = .{ .value = value };
        }

        return .{ .values = values, .roots = roots };
    }

    fn deinit(self: RootedValueCopies, rt: *core.JSRuntime) void {
        rt.memory.free(core.runtime.ValueRootValue, self.roots);
        rt.memory.free(core.JSValue, self.values);
    }
};

pub const StaticMethod = core.host_function.builtin_method_ids.array.StaticMethod;
pub const PrototypeMethod = core.host_function.builtin_method_ids.array.PrototypeMethod;
pub const ConstructorMethod = core.host_function.builtin_method_ids.array.ConstructorMethod;

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "from")) return @intFromEnum(StaticMethod.from);
    if (std.mem.eql(u8, name, "fromAsync")) return @intFromEnum(StaticMethod.from_async);
    if (std.mem.eql(u8, name, "isArray")) return @intFromEnum(StaticMethod.is_array);
    if (std.mem.eql(u8, name, "of")) return @intFromEnum(StaticMethod.of);
    return null;
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return @intFromEnum(PrototypeMethod.to_string);
    if (std.mem.eql(u8, name, "toLocaleString")) return @intFromEnum(PrototypeMethod.to_locale_string);
    if (std.mem.eql(u8, name, "map")) return @intFromEnum(PrototypeMethod.map);
    if (std.mem.eql(u8, name, "filter")) return @intFromEnum(PrototypeMethod.filter);
    if (std.mem.eql(u8, name, "reduce")) return @intFromEnum(PrototypeMethod.reduce);
    if (std.mem.eql(u8, name, "reduceRight")) return @intFromEnum(PrototypeMethod.reduce_right);
    if (std.mem.eql(u8, name, "forEach")) return @intFromEnum(PrototypeMethod.for_each);
    if (std.mem.eql(u8, name, "push")) return @intFromEnum(PrototypeMethod.push);
    if (std.mem.eql(u8, name, "pop")) return @intFromEnum(PrototypeMethod.pop);
    if (std.mem.eql(u8, name, "shift")) return @intFromEnum(PrototypeMethod.shift);
    if (std.mem.eql(u8, name, "unshift")) return @intFromEnum(PrototypeMethod.unshift);
    if (std.mem.eql(u8, name, "some")) return @intFromEnum(PrototypeMethod.some);
    if (std.mem.eql(u8, name, "every")) return @intFromEnum(PrototypeMethod.every);
    if (std.mem.eql(u8, name, "find")) return @intFromEnum(PrototypeMethod.find);
    if (std.mem.eql(u8, name, "findIndex")) return @intFromEnum(PrototypeMethod.find_index);
    if (std.mem.eql(u8, name, "findLast")) return @intFromEnum(PrototypeMethod.find_last);
    if (std.mem.eql(u8, name, "findLastIndex")) return @intFromEnum(PrototypeMethod.find_last_index);
    if (std.mem.eql(u8, name, "includes")) return @intFromEnum(PrototypeMethod.includes);
    if (std.mem.eql(u8, name, "indexOf")) return @intFromEnum(PrototypeMethod.index_of);
    if (std.mem.eql(u8, name, "lastIndexOf")) return @intFromEnum(PrototypeMethod.last_index_of);
    if (std.mem.eql(u8, name, "at")) return @intFromEnum(PrototypeMethod.at);
    if (std.mem.eql(u8, name, "copyWithin")) return @intFromEnum(PrototypeMethod.copy_within);
    if (std.mem.eql(u8, name, "fill")) return @intFromEnum(PrototypeMethod.fill);
    if (std.mem.eql(u8, name, "slice")) return @intFromEnum(PrototypeMethod.slice);
    if (std.mem.eql(u8, name, "splice")) return @intFromEnum(PrototypeMethod.splice);
    if (std.mem.eql(u8, name, "join")) return @intFromEnum(PrototypeMethod.join);
    if (std.mem.eql(u8, name, "concat")) return @intFromEnum(PrototypeMethod.concat);
    if (std.mem.eql(u8, name, "reverse")) return @intFromEnum(PrototypeMethod.reverse);
    if (std.mem.eql(u8, name, "sort")) return @intFromEnum(PrototypeMethod.sort);
    if (std.mem.eql(u8, name, "flat")) return @intFromEnum(PrototypeMethod.flat);
    if (std.mem.eql(u8, name, "flatMap")) return @intFromEnum(PrototypeMethod.flat_map);
    if (std.mem.eql(u8, name, "toReversed")) return @intFromEnum(PrototypeMethod.to_reversed);
    if (std.mem.eql(u8, name, "toSorted")) return @intFromEnum(PrototypeMethod.to_sorted);
    if (std.mem.eql(u8, name, "toSpliced")) return @intFromEnum(PrototypeMethod.to_spliced);
    if (std.mem.eql(u8, name, "with")) return @intFromEnum(PrototypeMethod.with_);
    if (std.mem.eql(u8, name, "keys")) return @intFromEnum(PrototypeMethod.keys);
    if (std.mem.eql(u8, name, "values")) return @intFromEnum(PrototypeMethod.values);
    if (std.mem.eql(u8, name, "entries")) return @intFromEnum(PrototypeMethod.entries);
    return null;
}

// Pure native-id -> legacy-id mapping relocated to engine core
// (`core/host_function.zig`, next to `builtin_method_ids.array`) in Phase
// 6b-3c; re-exported here so the dispatch/install side keeps the original name.
pub const decodePrototypeMethodId = core.host_function.builtin_method_id_lookup.array.decodePrototypeMethodId;

pub fn legacyPrototypeMethodId(name: []const u8) ?u32 {
    const native_id = prototypeMethodId(name) orelse return null;
    return decodePrototypeMethodId(native_id);
}

/// `arrayCall` switches on the per-record `magic` (== domain-local id) by
/// forwarding to `builtin_glue.qjsArrayNativeRecord`, the exec VM-op dispatch
/// glue that resolves `Array.from`/`Array.of`/`Array.isArray` and the
/// Array.prototype method record hub against the realm-aware exec ops. Those
/// exec ops stay in exec (`exec/array_ops.zig`): the prototype hub
/// (`qjsArrayPrototypeNativeRecord`) and its leaf method bodies are BOTH —
/// reached through this record table AND directly by the VM's residual
/// fast-array fast-call (`qjsArrayMethodFastCall`) and the realm-fallback name
/// cascade (`call_runtime.callValueOrBytecodeClassModeDispatch`) — so per the
/// client model the implementation core stays in exec and builtins hosts only this thin
/// record entry. (Phase 6b-relocate inventory: unlike String — whose six
/// movable bodies were reachable only through `stringCall` — almost every
/// Array.prototype / Array static body here is reached by the opcode-bound
/// fast-array fast-call, so it is BOTH and stays. The only bodies reachable
/// solely through native-dispatch surfaces are `qjsArrayJoinCall` and the
/// `Array.from`/`Array.of` statics; those still stay in exec because their
/// other live caller is the realm name cascade in `call_runtime.zig` (outside
/// this relocation's file scope) and because `from`/`of` are construction
/// orchestrators wired into the array-iterator-protocol and TypedArray-from
/// machinery that the client model deliberately keeps in exec. The lone
/// record-only function `qjsArrayIteratorMethodRecord` is the
/// array-iterator-protocol core and likewise stays.) The
/// fast-array `[[Get]]/[[Set]]` element semantics, the array iterator protocol
/// core, the `new_array` / `array_join` construction opcodes, and the VM
/// stack/frame primitives (`popCatchMarker`, `pushSlotValue`,
/// `pushFunctionClosure`) are NOT here — they are driven by opcode handlers,
/// never by function-object record dispatch. Property installation still
/// resolves names/lengths through the registry's own `array_static` /
/// `array_prototype` method tables and the `staticMethodId` /
/// `prototypeMethodId` helpers above; this table is consumed by both the slow
/// record-dispatch path and the VM hot paths (`rt.internal_builtins`).
///
/// `prepared_call_ok` is uniformly false, but unlike the other domains that is
/// not what gates `.array` prepared eligibility: the VM admits exactly `push`
/// and `pop` to the prepared (no-function-object) path through
/// `vm_call.arrayNativeSupportedWithoutFunctionObject`, and those calls now
/// route through this same record handler with `func_obj = null` (uniform
/// dispatch). `arrayCall` and the exec hub tolerate the null function object
/// for `push`/`pop` and reject every other id, so the residual flag stays
/// `false` without affecting the prepared path.
pub const internal_entries = arrayEntries: {
    const Entry = core.host_function.InternalEntry;
    break :arrayEntries [_]Entry{
        // Array constructor (`new Array(...)` / `Array(...)`). Construct-capable
        // so the construct dispatch path routes through `arrayCall`'s construct
        // branch; the Array constructor object is not installed with this native
        // id (its call-as-function/species recognition stays on the existing
        // name + `arrayBuiltinMarker` paths), so this record is reached only
        // through `builtin_dispatch.callConstructRecord` with an explicit ref.
        arrayConstructorEntry("Array", 1, @intFromEnum(ConstructorMethod.construct)),
        // Array static methods.
        arrayEntry("from", 1, @intFromEnum(StaticMethod.from)),
        arrayEntry("fromAsync", 1, @intFromEnum(StaticMethod.from_async)),
        arrayEntry("isArray", 1, @intFromEnum(StaticMethod.is_array)),
        arrayEntry("of", 0, @intFromEnum(StaticMethod.of)),
        // Array.prototype methods.
        arrayEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
        arrayEntry("toLocaleString", 0, @intFromEnum(PrototypeMethod.to_locale_string)),
        arrayEntry("map", 1, @intFromEnum(PrototypeMethod.map)),
        arrayEntry("filter", 1, @intFromEnum(PrototypeMethod.filter)),
        arrayEntry("reduce", 1, @intFromEnum(PrototypeMethod.reduce)),
        arrayEntry("reduceRight", 1, @intFromEnum(PrototypeMethod.reduce_right)),
        arrayEntry("forEach", 1, @intFromEnum(PrototypeMethod.for_each)),
        arrayPushEntry("push", 1, @intFromEnum(PrototypeMethod.push)),
        arrayEntry("pop", 0, @intFromEnum(PrototypeMethod.pop)),
        arrayEntry("shift", 0, @intFromEnum(PrototypeMethod.shift)),
        arrayEntry("unshift", 1, @intFromEnum(PrototypeMethod.unshift)),
        arrayEntry("some", 1, @intFromEnum(PrototypeMethod.some)),
        arrayEntry("every", 1, @intFromEnum(PrototypeMethod.every)),
        arrayEntry("find", 1, @intFromEnum(PrototypeMethod.find)),
        arrayEntry("findIndex", 1, @intFromEnum(PrototypeMethod.find_index)),
        arrayEntry("findLast", 1, @intFromEnum(PrototypeMethod.find_last)),
        arrayEntry("findLastIndex", 1, @intFromEnum(PrototypeMethod.find_last_index)),
        arrayEntry("includes", 1, @intFromEnum(PrototypeMethod.includes)),
        arrayEntry("indexOf", 1, @intFromEnum(PrototypeMethod.index_of)),
        arrayEntry("lastIndexOf", 1, @intFromEnum(PrototypeMethod.last_index_of)),
        arrayEntry("at", 1, @intFromEnum(PrototypeMethod.at)),
        arrayEntry("copyWithin", 2, @intFromEnum(PrototypeMethod.copy_within)),
        arrayEntry("fill", 1, @intFromEnum(PrototypeMethod.fill)),
        arrayEntry("slice", 2, @intFromEnum(PrototypeMethod.slice)),
        arrayEntry("splice", 2, @intFromEnum(PrototypeMethod.splice)),
        arrayEntry("join", 1, @intFromEnum(PrototypeMethod.join)),
        arrayEntry("concat", 1, @intFromEnum(PrototypeMethod.concat)),
        arrayEntry("reverse", 0, @intFromEnum(PrototypeMethod.reverse)),
        arrayEntry("sort", 1, @intFromEnum(PrototypeMethod.sort)),
        arrayEntry("flat", 0, @intFromEnum(PrototypeMethod.flat)),
        arrayEntry("flatMap", 1, @intFromEnum(PrototypeMethod.flat_map)),
        arrayEntry("toReversed", 0, @intFromEnum(PrototypeMethod.to_reversed)),
        arrayEntry("toSorted", 1, @intFromEnum(PrototypeMethod.to_sorted)),
        arrayEntry("toSpliced", 2, @intFromEnum(PrototypeMethod.to_spliced)),
        arrayEntry("with", 2, @intFromEnum(PrototypeMethod.with_)),
        arrayEntry("keys", 0, @intFromEnum(PrototypeMethod.keys)),
        arrayEntry("values", 0, @intFromEnum(PrototypeMethod.values)),
        arrayEntry("entries", 0, @intFromEnum(PrototypeMethod.entries)),
    };
};

fn arrayEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .call = &arrayCall };
}

fn arrayPushEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .call = &arrayPushCall };
}

test "Array.push has a dedicated native record handler" {
    var push_call: ?core.host_function.InternalCallFn = null;
    var pop_call: ?core.host_function.InternalCallFn = null;
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.push)) push_call = entry.call;
        if (entry.id == @intFromEnum(PrototypeMethod.pop)) pop_call = entry.call;
    }
    try std.testing.expect(push_call != null);
    try std.testing.expect(pop_call != null);
    try std.testing.expect(push_call.? == &arrayPushCall);
    try std.testing.expect(pop_call.? == &arrayCall);
}

/// The Array constructor record: construct-capable so `new Array(...)` (and
/// `Array(...)` called as a function, routed with `flags.constructor == false`)
/// reach `arrayCall`'s construct branch. Never prepared-eligible.
fn arrayConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .constructor = true, .call = &arrayCall };
}

/// The realm's default `Array.prototype` for the call-as-function construct
/// fallback (the construct path passes `new_target` instead). Returns null when
/// the realm cache is not yet populated, in which case the array is created
/// with the engine default prototype.
fn arrayPrototypeFromGlobal(global: *core.Object) ?*core.Object {
    const stored = global.cachedRealmValue(.array_prototype) orelse return null;
    if (!stored.isObject()) return null;
    const header = stored.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

/// Shared record handler for the `.array` domain. Mirrors the retired
/// `call.zig` `callArrayNativeFunctionRecord`: forward the record id to the
/// exec dispatch glue, and surface the corrupt-id / null-result case (e.g. an
/// Array.prototype method invoked against a non-array receiver the hub
/// declines) as a TypeError, exactly as before.
///
/// `func_obj` is nullable so the prepared (no-function-object) call path can
/// reach this same record handler under the uniform dispatch model: the
/// prepared-call gate (`vm_call.arrayNativeSupportedWithoutFunctionObject`)
/// only admits `push`/`pop`, whose implementations need only the receiver
/// array, so the exec glue routes those two ids to their func-object-free
/// bodies when `func_obj == null`. Every other Array method record requires the
/// materialized function object (to disambiguate Array vs `%TypedArray%`
/// prototype methods sharing a record id, and to read species/callbacks) and
/// surfaces the corrupt-id `error.TypeError` under null func_obj — which never
/// fires here because the gate blocks those ids from the prepared path. The VM
/// caller bytecode/frame are recovered and threaded so the relocated table path
/// keeps the inline-cache hint the dedicated prepared bypass used to carry.
fn arrayCall(host_call: InternalCall) HostError!core.JSValue {
    const id: u32 = host_call.magic;
    if (id == @intFromEnum(ConstructorMethod.construct)) {
        // `new Array(...)` arrives through the construct record path with
        // `flags.constructor` set and the resolved instance prototype in
        // `new_target`. `Array(...)` called as a function behaves identically
        // (per spec) but is currently name-dispatched and so does not reach this
        // id; the `flags.constructor == false` branch falls back to the realm's
        // default Array.prototype (null when no realm global is threaded — e.g.
        // a bare `Reflect.construct` against an unwired native function — which
        // yields the engine default prototype). The construct branch runs before
        // the `global` requirement below because it needs no realm global, just
        // like the Date/RegExp/String construct records. RangeError surfaces
        // unchanged for an invalid `new Array(length)`.
        const prototype = if (host_call.flags.constructor)
            host_call.new_target
        else if (host_call.global) |global|
            arrayPrototypeFromGlobal(global)
        else
            null;
        return constructConstructorWithPrototype(host_call.ctx.runtime, host_call.args, prototype) catch |err| switch (err) {
            error.RangeError => if (host_call.global) |global|
                exception_ops.throwRangeErrorMessage(host_call.ctx, global, "invalid array length")
            else
                error.RangeError,
            else => return err,
        };
    }
    const global = host_call.global orelse return error.TypeError;
    if (try builtin_glue.qjsArrayNativeRecord(
        host_call.ctx,
        host_call.output,
        global,
        host_call.this_value,
        host_call.func_obj,
        host_call.magic,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    )) |value| return value;
    return error.TypeError;
}

/// Per-method function pointer for Array.prototype.push. This is the same
/// full-context ABI as the shared array record handler, so proxy/accessor and
/// cross-realm behavior keep their existing output/global/caller threading;
/// only the magic-switch and redundant function-object recognition disappear.
fn arrayPushCall(host_call: InternalCall) HostError!core.JSValue {
    const global = host_call.global orelse return error.TypeError;
    return (try builtin_glue.qjsArrayPushNativeRecord(
        host_call.ctx,
        host_call.output,
        global,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    )) orelse error.TypeError;
}

pub fn isArrayIndex(bytes: []const u8) bool {
    return core_array.isArrayIndexName(bytes);
}

// Proxy-aware `Array.isArray` predicate relocated to engine core
// (`core/array.zig`) in Phase 6b-3 STEP 2; re-exported here unchanged.
pub const isArrayValue = core_array.isArrayValue;

pub fn lengthAfterSet(index: u32, current: u32) u32 {
    if (index >= current) return index + 1;
    return current;
}

/// QuickJS source map: narrow array literal helper used by transitional
/// `new_array` bytecode.
pub fn construct(rt: *core.JSRuntime, values: []const core.JSValue) !core.JSValue {
    return constructWithPrototype(rt, values, null);
}

pub fn constructConstructorWithPrototype(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    if (args.len == 1 and args[0].isNumber()) {
        const length = arrayLengthFromNumber(args[0]) orelse return error.RangeError;
        const object = try core.Object.createArray(rt, prototype);
        errdefer core.Object.destroyFromHeader(rt, &object.header);
        // new Array(n): fast array with count=0, length=n, slots [0,n) holes.
        // Faithful to js_array_constructor -> set_array_length (quickjs.c:9447-9455);
        // no sparse conversion. This is the holey-prealloc unblock.
        object.setArrayLength(length);
        return object.value();
    }
    return constructWithPrototype(rt, args, prototype);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, values: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const rooted = try RootedValueCopies.init(rt, values);
    defer rooted.deinit(rt);
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = rooted.roots,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.createArray(rt, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    try object.reserveDenseArrayElements(rt, @intCast(rooted.values.len));
    for (rooted.values, 0..) |value, index| {
        const atom_id = core.atom.atomFromUInt32(@intCast(index));
        if (try object.appendDenseArrayIndex(rt, @intCast(index), atom_id, value)) continue;
        try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true));
    }
    return object.value();
}

// `constructLiteralWithPrototype` (the array-literal opcode helper) is pure and
// was relocated to engine core (`core/array.zig`) in Phase 6b-3 STEP 4 so
// `src/exec/vm_literal.zig` can call it without importing builtins; it is not
// re-exported here because the only caller was that exec opcode handler.

fn arrayLengthFromNumber(value: core.JSValue) ?u32 {
    const number: f64 = if (value.asInt32()) |int_value|
        @floatFromInt(int_value)
    else
        value.asFloat64() orelse return null;
    if (!std.math.isFinite(number)) return null;
    if (std.math.isNan(number)) return null;
    if (number < 0 or number > @as(f64, @floatFromInt(core_array.max_array_length))) return null;
    const truncated = @trunc(number);
    if (truncated != number) return null;
    return @intFromFloat(truncated);
}

/// QuickJS source map: selected Array.prototype.join behavior used by the
/// transitional `array_join` bytecode.
pub fn join(rt: *core.JSRuntime, array_value: core.JSValue, separator_value: core.JSValue) !core.JSValue {
    const object = try expectObject(array_value);

    var separator = std.ArrayList(u8).empty;
    defer separator.deinit(rt.memory.allocator);
    try appendValueString(rt, &separator, separator_value);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    var index: u32 = 0;
    while (index < object.arrayLength()) : (index += 1) {
        if (index != 0) try buffer.appendSlice(rt.memory.allocator, separator.items);
        const item = object.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        if (!item.isUndefined() and !item.isNull()) try appendValueString(rt, &buffer, item);
    }
    return createStringValue(rt, buffer.items);
}

/// QuickJS source map: selected Array.prototype methods currently covered by
/// smoke fixtures and transitional array opcodes.
pub fn methodCall(rt: *core.JSRuntime, receiver: core.JSValue, method: u32, args: []const core.JSValue) !core.JSValue {
    return switch (method) {
        1 => {
            if (args.len != 0) return error.TypeError;
            return filterEven(rt, receiver);
        },
        2 => {
            if (args.len != 0) return error.TypeError;
            return reduceSum(rt, receiver);
        },
        4 => {
            if (args.len != 0) return error.TypeError;
            return someEven(rt, receiver);
        },
        5 => {
            if (args.len != 0) return error.TypeError;
            return everyPositive(rt, receiver);
        },
        6 => {
            if (args.len != 1) return error.TypeError;
            return indexSearch(rt, receiver, args[0], .first);
        },
        7 => {
            if (args.len != 1) return error.TypeError;
            return indexSearch(rt, receiver, args[0], .includes);
        },
        8 => {
            if (args.len != 1) return error.TypeError;
            return indexSearch(rt, receiver, args[0], .last);
        },
        9 => {
            if (args.len != 1) return error.TypeError;
            return at(rt, receiver, args[0]);
        },
        10 => {
            if (args.len != 1) return error.TypeError;
            return slice(rt, receiver, args[0]);
        },
        11 => {
            if (args.len != 4) return error.TypeError;
            return splice(rt, receiver, args);
        },
        12 => {
            if (args.len != 0) return error.TypeError;
            return reverse(rt, receiver);
        },
        13 => return push(rt, receiver, args),
        14 => {
            if (args.len != 0) return error.TypeError;
            return pop(rt, receiver);
        },
        15 => return concat(rt, receiver, args),
        16 => sort(rt, receiver, args),
        17 => {
            if (args.len != 0) return error.TypeError;
            return arrayIterator(rt, receiver, .value);
        },
        18 => {
            if (args.len != 0) return error.TypeError;
            return arrayIterator(rt, receiver, .key);
        },
        19 => {
            if (args.len != 0) return error.TypeError;
            return arrayIterator(rt, receiver, .key_value);
        },
        20 => {
            if (args.len != 0) return error.TypeError;
            return arrayIteratorNext(rt, receiver);
        },
        else => error.TypeError,
    };
}

const ArrayIteratorKind = enum(u8) {
    key = 1,
    value = 2,
    key_value = 3,
};

fn arrayIterator(rt: *core.JSRuntime, receiver: core.JSValue, kind: ArrayIteratorKind) !core.JSValue {
    _ = try expectArrayIteratorTarget(receiver);
    const prototype = try iteratorPrototype(rt, "Array Iterator");
    defer prototype.value().free(rt);
    const iterator = try core.Object.create(rt, core.class.ids.array_iterator, prototype);
    errdefer core.Object.destroyFromHeader(rt, &iterator.header);
    try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), receiver.dup());
    iterator.iteratorIndexSlot().* = 0;
    iterator.iteratorKindSlot().* = @intFromEnum(kind);
    try core.function.defineNativeMethod(rt, iterator, "next", 0);
    return iterator.value();
}

fn iteratorPrototype(rt: *core.JSRuntime, tag_name: []const u8) !*core.Object {
    const base = try core.Object.create(rt, core.class.ids.object, null);
    var base_raw_owned = true;
    errdefer if (base_raw_owned) core.Object.destroyFromHeader(rt, &base.header);
    try defineToStringTag(rt, base, "Iterator");
    const specific = try core.Object.create(rt, core.class.ids.object, base);
    errdefer core.Object.destroyFromHeader(rt, &specific.header);
    base_raw_owned = false;
    base.value().free(rt);
    try defineToStringTag(rt, specific, tag_name);
    return specific;
}

fn defineToStringTag(rt: *core.JSRuntime, object: *core.Object, tag_name: []const u8) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag_value = try core.string.String.createUtf8(rt, tag_name);
    defer tag_value.value().free(rt);
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag_value.value(), false, false, true));
}

fn arrayIteratorNext(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    const iterator = try expectObject(receiver);
    if (iterator.class_id != core.class.ids.array_iterator) return error.TypeError;
    const target_value = (iterator.iteratorTargetSlot().*) orelse return iteratorResult(rt, core.JSValue.undefinedValue(), true);
    const target = try expectArrayIteratorTarget(target_value);
    const length = arrayIteratorTargetLength(rt, target);
    if ((iterator.iteratorIndexSlot().*) >= length) {
        const done_result = try iteratorResult(rt, core.JSValue.undefinedValue(), true);
        iterator.clearOptionalValueSlot(rt, iterator.iteratorTargetSlot());
        return done_result;
    }

    const index: u32 = @intCast((iterator.iteratorIndexSlot().*));
    iterator.iteratorIndexSlot().* += 1;
    const value = try arrayIteratorValue(rt, target, index, @enumFromInt((iterator.iteratorKindSlot().*)));
    return iteratorResult(rt, value, false);
}

fn arrayIteratorValue(rt: *core.JSRuntime, target: *core.Object, index: u32, kind: ArrayIteratorKind) !core.JSValue {
    return switch (kind) {
        .key => core.JSValue.int32(@intCast(index)),
        .value => if (buffer_builtin.isTypedArrayObject(target)) try buffer_builtin.typedArrayGetIndex(rt, target, index) else target.getProperty(core.atom.atomFromUInt32(index)),
        .key_value => blk: {
            const pair = try core.Object.createArray(rt, null);
            errdefer core.Object.destroyFromHeader(rt, &pair.header);
            const value = if (buffer_builtin.isTypedArrayObject(target)) try buffer_builtin.typedArrayGetIndex(rt, target, index) else target.getProperty(core.atom.atomFromUInt32(index));
            defer value.free(rt);
            try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, true, true));
            try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(value, true, true, true));
            break :blk pair.value();
        },
    };
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
    try result.defineOwnProperty(rt, core.atom.predefinedId("value", .string).?, core.Descriptor.data(rooted_value, true, true, true));
    try result.defineOwnProperty(rt, core.atom.predefinedId("done", .string).?, core.Descriptor.data(core.JSValue.boolean(done), true, true, true));
    return result.value();
}

test "array iteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        fb.cpool = __cp.ptr;
        fb.cpool_count = @intCast(__cp.len);
    }
    const symbol_atom = try rt.atoms.newValueSymbol("gc-array-iterator-result-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
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
    const iterator_result = objectFromValue(iterator_result_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = iterator_result.getProperty(core.atom.predefinedId("value", .string).?);
        defer stored.free(rt);
        try std.testing.expect(stored.same(result_value));
    }

    iterator_result_value.free(rt);
    iterator_result_alive = false;
    result_value.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "array splice roots direct function bytecode insert values while creating removed array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try core.Object.createArray(rt, null);
    const array_value = array.value();
    var array_alive = true;
    defer if (array_alive) array_value.free(rt);

    const first_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const first_fb = &first_slice[0];
    first_fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&first_fb.header);

    const first_symbol_value = try rt.newSymbolValue("gc-array-splice-first-bytecode-symbol");
    const first_symbol = first_symbol_value.asSymbolAtom().?;
    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        first_fb.cpool = __cp.ptr;
        first_fb.cpool_count = @intCast(__cp.len);
    }
    first_fb.cpool[0] = first_symbol_value;
    first_fb.cpool_count = 1;

    const second_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const second_fb = &second_slice[0];
    second_fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&second_fb.header);

    const second_symbol_value = try rt.newSymbolValue("gc-array-splice-second-bytecode-symbol");
    const second_symbol = second_symbol_value.asSymbolAtom().?;
    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        second_fb.cpool = __cp.ptr;
        second_fb.cpool_count = @intCast(__cp.len);
    }
    second_fb.cpool[0] = second_symbol_value;
    second_fb.cpool_count = 1;

    var first_value = core.JSValue.functionBytecode(&first_fb.header);
    var first_alive = true;
    defer if (first_alive) first_value.free(rt);
    var second_value = core.JSValue.functionBytecode(&second_fb.header);
    var second_alive = true;
    defer if (second_alive) second_value.free(rt);
    const args = [_]core.JSValue{
        core.JSValue.int32(0),
        core.JSValue.int32(0),
        first_value,
        second_value,
    };

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const removed_value = try splice(rt, array_value, &args);
    var removed_alive = true;
    defer if (removed_alive) removed_value.free(rt);

    try std.testing.expect(rt.atoms.name(first_symbol) != null);
    try std.testing.expect(rt.atoms.name(second_symbol) != null);
    {
        const stored_first = array.getProperty(core.atom.atomFromUInt32(0));
        defer stored_first.free(rt);
        try std.testing.expect(stored_first.same(first_value));
        const stored_second = array.getProperty(core.atom.atomFromUInt32(1));
        defer stored_second.free(rt);
        try std.testing.expect(stored_second.same(second_value));
    }

    removed_value.free(rt);
    removed_alive = false;
    first_value.free(rt);
    first_alive = false;
    second_value.free(rt);
    second_alive = false;
    array_value.free(rt);
    array_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(first_symbol) == null);
    try std.testing.expect(rt.atoms.name(second_symbol) == null);
}

test "array constructWithPrototype roots direct function bytecode elements while creating array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        fb.cpool = __cp.ptr;
        fb.cpool_count = @intCast(__cp.len);
    }
    const symbol_atom = try rt.atoms.newValueSymbol("gc-array-construct-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var element_value = core.JSValue.functionBytecode(&fb.header);
    var element_alive = true;
    defer if (element_alive) element_value.free(rt);
    const values = [_]core.JSValue{element_value};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const array_value = try constructWithPrototype(rt, &values, null);
    var array_alive = true;
    defer if (array_alive) array_value.free(rt);
    const array = try expectArray(array_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = array.getProperty(core.atom.atomFromUInt32(0));
        defer stored.free(rt);
        try std.testing.expect(stored.same(element_value));
    }

    array_value.free(rt);
    array_alive = false;
    element_value.free(rt);
    element_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "array concat roots direct function bytecode argument while creating output array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const receiver = try core.Object.createArray(rt, null);
    const receiver_value = receiver.value();
    var receiver_alive = true;
    defer if (receiver_alive) receiver_value.free(rt);

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        fb.cpool = __cp.ptr;
        fb.cpool_count = @intCast(__cp.len);
    }
    const symbol_atom = try rt.atoms.newValueSymbol("gc-array-concat-arg-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var arg_value = core.JSValue.functionBytecode(&fb.header);
    var arg_alive = true;
    defer if (arg_alive) arg_value.free(rt);
    const args = [_]core.JSValue{arg_value};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const out_value = try concat(rt, receiver_value, &args);
    var out_alive = true;
    defer if (out_alive) out_value.free(rt);
    const out = try expectArray(out_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = out.getProperty(core.atom.atomFromUInt32(0));
        defer stored.free(rt);
        try std.testing.expect(stored.same(arg_value));
    }

    out_value.free(rt);
    out_alive = false;
    arg_value.free(rt);
    arg_alive = false;
    receiver_value.free(rt);
    receiver_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn filterEven(rt: *core.JSRuntime, array_value: core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    var out_index: u32 = 0;
    var index: u32 = 0;
    while (index < array.arrayLength()) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        if (item.asInt32()) |n| {
            if (@mod(n, 2) == 0) {
                try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(item, true, true, true));
                out_index += 1;
            }
        }
    }
    return out.value();
}

fn reduceSum(rt: *core.JSRuntime, array_value: core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    var sum: i32 = 0;
    var index: u32 = 0;
    while (index < array.arrayLength()) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        sum += item.asInt32() orelse 0;
    }
    return core.JSValue.int32(sum);
}

fn someEven(rt: *core.JSRuntime, array_value: core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    var found = false;
    var index: u32 = 0;
    while (index < array.arrayLength()) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        if (item.asInt32()) |n| found = found or @mod(n, 2) == 0;
    }
    return core.JSValue.boolean(found);
}

fn everyPositive(rt: *core.JSRuntime, array_value: core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    var ok = true;
    var index: u32 = 0;
    while (index < array.arrayLength()) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        if ((item.asInt32() orelse 0) <= 0) ok = false;
    }
    return core.JSValue.boolean(ok);
}

const SearchMode = enum {
    first,
    includes,
    last,
};

fn indexSearch(rt: *core.JSRuntime, value: core.JSValue, needle: core.JSValue, mode: SearchMode) !core.JSValue {
    if (value.isString()) return stringSearchValue(rt, value, needle, mode);
    const array = try expectArray(value);
    var found_index: i32 = -1;
    if (array.arrayElements().len != 0) {
        const dense_len: u32 = @intCast(@min(array.arrayElements().len, @as(usize, @intCast(array.arrayLength()))));
        var dense_index: u32 = 0;
        while (dense_index < dense_len) : (dense_index += 1) {
            const item = array.arrayElements()[@intCast(dense_index)];
            if (valuesEqual(item, needle)) {
                found_index = @intCast(dense_index);
                if (mode != .last) break;
            }
        }
        if (found_index >= 0 and mode != .last) {
            return switch (mode) {
                .includes => core.JSValue.boolean(true),
                else => core.JSValue.int32(found_index),
            };
        }
        if (dense_len >= array.arrayLength()) {
            return switch (mode) {
                .includes => core.JSValue.boolean(found_index >= 0),
                else => core.JSValue.int32(found_index),
            };
        }
    }
    var index: u32 = 0;
    while (index < array.arrayLength()) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        if (valuesEqual(item, needle)) {
            found_index = @intCast(index);
            if (mode != .last) break;
        }
    }
    if (needle.isUndefined() and mode != .includes) found_index = @as(i32, @intCast(array.arrayLength())) - 1;
    return switch (mode) {
        .includes => core.JSValue.boolean(found_index >= 0),
        else => core.JSValue.int32(found_index),
    };
}

fn stringSearchValue(rt: *core.JSRuntime, value: core.JSValue, needle: core.JSValue, mode: SearchMode) !core.JSValue {
    var haystack = std.ArrayList(u8).empty;
    defer haystack.deinit(rt.memory.allocator);
    try appendRawString(rt, &haystack, value);
    var query = std.ArrayList(u8).empty;
    defer query.deinit(rt.memory.allocator);
    try appendValueString(rt, &query, needle);
    const index = std.mem.indexOf(u8, haystack.items, query.items);
    return switch (mode) {
        .includes => core.JSValue.boolean(index != null),
        else => core.JSValue.int32(if (index) |found| @intCast(found) else -1),
    };
}

fn at(_: *core.JSRuntime, array_value: core.JSValue, index_value: core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    var index = index_value.asInt32() orelse 0;
    if (index < 0) index = @as(i32, @intCast(array.arrayLength())) + index;
    if (index < 0 or index >= array.arrayLength()) return core.JSValue.undefinedValue();
    return array.getProperty(core.atom.atomFromUInt32(@intCast(index)));
}

fn slice(rt: *core.JSRuntime, array_value: core.JSValue, start_value: core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    var start = start_value.asInt32() orelse 0;
    if (start < 0) start = @as(i32, @intCast(array.arrayLength())) + start;
    if (start < 0) start = 0;
    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    var out_index: u32 = 0;
    var index: u32 = @intCast(start);
    while (index < array.arrayLength()) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(item, true, true, true));
        out_index += 1;
    }
    return out.value();
}

fn splice(rt: *core.JSRuntime, array_value: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    const start: u32 = @intCast(args[0].asInt32() orelse 0);
    const delete_count: u32 = @intCast(args[1].asInt32() orelse 0);
    var insert_a = args[2];
    var insert_b = args[3];
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &insert_a },
        .{ .value = &insert_b },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const removed = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &removed.header);
    var i: u32 = 0;
    while (i < delete_count) : (i += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(start + i));
        defer item.free(rt);
        try removed.defineOwnProperty(rt, core.atom.atomFromUInt32(i), core.Descriptor.data(item, true, true, true));
    }
    const tail = array.getProperty(core.atom.atomFromUInt32(start + delete_count));
    defer tail.free(rt);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(start), core.Descriptor.data(insert_a, true, true, true));
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(start + 1), core.Descriptor.data(insert_b, true, true, true));
    if (!tail.isUndefined()) try array.defineOwnProperty(rt, core.atom.atomFromUInt32(start + 2), core.Descriptor.data(tail, true, true, true));
    return removed.value();
}

fn push(rt: *core.JSRuntime, array_value: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    for (args) |item| {
        try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.arrayLength()), core.Descriptor.data(item, true, true, true));
    }
    return core.JSValue.int32(@intCast(array.arrayLength()));
}

fn pop(rt: *core.JSRuntime, array_value: core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    if (array.arrayLength() == 0) return core.JSValue.undefinedValue();
    const index = array.arrayLength() - 1;
    const key = core.atom.atomFromUInt32(index);
    const value = array.getProperty(key);
    _ = array.deleteProperty(rt, key);
    try array.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, false, false));
    return value;
}

/// Mirrors the indexed-property swap shape of QuickJS `js_array_reverse`
/// (`quickjs.c:42497-42547`) for ordinary arrays.
fn reverse(rt: *core.JSRuntime, array_value: core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    if (array.arrayLength() <= 1) return array_value.dup();

    var lower: u32 = 0;
    var upper: u32 = array.arrayLength() - 1;
    while (lower < upper) : ({
        lower += 1;
        upper -= 1;
    }) {
        const lower_key = core.atom.atomFromUInt32(lower);
        const upper_key = core.atom.atomFromUInt32(upper);
        const lower_value = array.getProperty(lower_key);
        defer lower_value.free(rt);
        const upper_value = array.getProperty(upper_key);
        defer upper_value.free(rt);

        _ = array.deleteProperty(rt, lower_key);
        _ = array.deleteProperty(rt, upper_key);
        if (!upper_value.isUndefined()) {
            try array.defineOwnProperty(rt, lower_key, core.Descriptor.data(upper_value, true, true, true));
        }
        if (!lower_value.isUndefined()) {
            try array.defineOwnProperty(rt, upper_key, core.Descriptor.data(lower_value, true, true, true));
        }
    }
    return array_value.dup();
}

const SortEntry = struct {
    value: core.JSValue,
    key: []u8,
};

/// Mirrors the default string-order branch of QuickJS `js_array_sort`
/// (`quickjs.c:43017-43144`) for ordinary arrays. Custom comparators remain
/// outside this narrow transitional path.
fn sort(rt: *core.JSRuntime, array_value: core.JSValue, args: []const core.JSValue) !core.JSValue {
    if (args.len >= 1 and !args[0].isUndefined()) return error.TypeError;
    const array = try expectArray(array_value);

    var entries = std.ArrayList(SortEntry).empty;
    defer {
        for (entries.items) |entry| {
            entry.value.free(rt);
            rt.memory.allocator.free(entry.key);
        }
        entries.deinit(rt.memory.allocator);
    }

    var index: u32 = 0;
    while (index < array.arrayLength()) : (index += 1) {
        const value = array.getProperty(core.atom.atomFromUInt32(index));
        if (value.isUndefined()) {
            value.free(rt);
            continue;
        }
        var value_owned = true;
        errdefer if (value_owned) value.free(rt);

        var key_buffer = std.ArrayList(u8).empty;
        defer key_buffer.deinit(rt.memory.allocator);
        try appendValueString(rt, &key_buffer, value);
        const key = try rt.memory.allocator.dupe(u8, key_buffer.items);
        var key_owned = true;
        errdefer if (key_owned) rt.memory.allocator.free(key);

        try entries.append(rt.memory.allocator, .{ .value = value, .key = key });
        value_owned = false;
        key_owned = false;
    }

    std.mem.sort(SortEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: SortEntry, rhs: SortEntry) bool {
            return std.mem.lessThan(u8, lhs.key, rhs.key);
        }
    }.lessThan);

    index = 0;
    while (index < array.arrayLength()) : (index += 1) {
        _ = array.deleteProperty(rt, core.atom.atomFromUInt32(index));
    }
    for (entries.items, 0..) |entry, out_index| {
        try array.defineOwnProperty(rt, core.atom.atomFromUInt32(@intCast(out_index)), core.Descriptor.data(entry.value, true, true, true));
    }
    return array_value.dup();
}

/// Mirrors the core shape of QuickJS `js_array_concat`
/// (`quickjs.c:41684-41739`) for ordinary arrays: create a fresh array, then
/// append `this` and each array argument element-by-element.
fn concat(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    var rooted_receiver = receiver;
    const rooted_args = try RootedValueCopies.init(rt, args);
    defer rooted_args.deinit(rt);
    var receiver_root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_receiver },
    };
    const receiver_root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &receiver_root_values,
    };
    rt.active_value_roots = &receiver_root_frame;
    defer rt.active_value_roots = receiver_root_frame.previous;

    const args_root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = rooted_args.roots,
    };
    rt.active_value_roots = &args_root_frame;
    defer rt.active_value_roots = args_root_frame.previous;

    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);

    var next_index: u32 = 0;
    try concatAppend(rt, out, &next_index, rooted_receiver);
    for (rooted_args.values) |arg| {
        try concatAppend(rt, out, &next_index, arg);
    }
    try out.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(@intCast(next_index)), true, false, false));
    return out.value();
}

fn concatAppend(rt: *core.JSRuntime, out: *core.Object, next_index: *u32, value: core.JSValue) !void {
    if (value.isObject()) {
        const header = value.refHeader() orelse unreachable;
        const object: *core.Object = @fieldParentPtr("header", header);
        if (object.flags.is_array) {
            var index: u32 = 0;
            while (index < object.arrayLength()) : (index += 1) {
                const item = object.getProperty(core.atom.atomFromUInt32(index));
                defer item.free(rt);
                if (!item.isUndefined()) {
                    try out.defineOwnProperty(rt, core.atom.atomFromUInt32(next_index.*), core.Descriptor.data(item, true, true, true));
                }
                next_index.* += 1;
            }
            return;
        }
    }

    try out.defineOwnProperty(rt, core.atom.atomFromUInt32(next_index.*), core.Descriptor.data(value, true, true, true));
    next_index.* += 1;
}

fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (!value.isObject()) return null;
    return @fieldParentPtr("header", header);
}

// `expectArray` relocated to engine core (`core/array.zig`) in Phase 6b-3
// STEP 2; re-exported here unchanged.
pub const expectArray = core_array.expectArray;

fn expectArrayIteratorTarget(value: core.JSValue) !*core.Object {
    const object = try expectObject(value);
    if (object.flags.is_array or object.class_id == core.class.ids.arguments or object.class_id == core.class.ids.mapped_arguments or buffer_builtin.isTypedArrayObject(object)) return object;
    return error.TypeError;
}

fn arrayIteratorTargetLength(rt: *core.JSRuntime, object: *core.Object) u32 {
    if (object.flags.is_array) return object.arrayLength();
    if (buffer_builtin.isTypedArrayObject(object)) return buffer_builtin.typedArrayLength(rt, object) catch 0;
    const length = object.getProperty(core.atom.ids.length);
    defer length.free(rt);
    return @intCast(length.asInt32() orelse 0);
}

fn createStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const str = try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

fn appendRawString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    const string_value = value.asStringBody() orelse return;
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) try buffer.append(rt.memory.allocator, @intCast(unit));
            }
        },
    }
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
        var big = try cloneBigIntValue(rt, value);
        defer big.deinit();
        const printed = try big.formatBase10Alloc(rt.memory.allocator);
        defer rt.memory.allocator.free(printed);
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    } else if (value.isUndefined()) {
        try buffer.appendSlice(rt.memory.allocator, "undefined");
    } else if (value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
    } else if (value.isString()) {
        const string_value = value.asStringBody() orelse return;
        try string_value.ensureFlat(rt);
        switch (string_value.resolveData()) {
            .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
            .utf16 => |units| {
                for (units) |unit| {
                    if (unit <= 0x7f) {
                        try buffer.append(rt.memory.allocator, @intCast(unit));
                    } else {
                        var unit_buf: [16]u8 = undefined;
                        const printed = try std.fmt.bufPrint(&unit_buf, "\\u{x}", .{unit});
                        try buffer.appendSlice(rt.memory.allocator, printed);
                    }
                }
            },
        }
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
        try buffer.appendSlice(rt.memory.allocator, "[object Object]");
    }
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

fn valuesEqual(a: core.JSValue, b: core.JSValue) bool {
    if (a.isBigInt() and b.isBigInt()) {
        return (compareBigIntValues(a, b) orelse return false) == .eq;
    }
    if (a.asInt32()) |ai| {
        if (b.asInt32()) |bi| return ai == bi;
    }
    if (a.asBool()) |ab| {
        if (b.asBool()) |bb| return ab == bb;
    }
    if (a.isNull() or a.isUndefined()) return a.same(b);
    if (a.isString() and b.isString()) {
        if (a.same(b)) return true;
        return (compareStringValues(a, b) orelse 1) == 0;
    }
    return a.same(b);
}

fn compareBigIntValues(a: core.JSValue, b: core.JSValue) ?std.math.Order {
    var lhs_scratch: [2]bignum.Limb = undefined;
    var rhs_scratch: [2]bignum.Limb = undefined;
    const lhs = bigIntParts(a, &lhs_scratch) orelse return null;
    const rhs = bigIntParts(b, &rhs_scratch) orelse return null;
    return bignum.compareParts(lhs.negative, lhs.limbs, rhs.negative, rhs.limbs);
}

const BigIntParts = struct {
    negative: bool,
    limbs: []const bignum.Limb,
};

fn bigIntParts(value: core.JSValue, scratch: *[2]bignum.Limb) ?BigIntParts {
    if (value.asShortBigInt()) |short| {
        const signed: i128 = short;
        var magnitude: u128 = if (signed < 0) @intCast(-signed) else @intCast(signed);
        var len: usize = 0;
        while (magnitude != 0) {
            scratch[len] = @truncate(magnitude);
            magnitude >>= @bitSizeOf(bignum.Limb);
            len += 1;
        }
        return .{
            .negative = short < 0,
            .limbs = scratch[0..len],
        };
    }
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return .{ .negative = big.value.negative, .limbs = big.value.limbs };
    }
    return null;
}

fn compareStringValues(a: core.JSValue, b: core.JSValue) ?i32 {
    return core.string.compareStringValues(a, b, false);
}

fn cloneBigIntValue(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt {
    if (value.asShortBigInt()) |big_int| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, big_int);
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return big.value.cloneWithAllocator(rt.memory.allocator);
    }
    return error.TypeError;
}
