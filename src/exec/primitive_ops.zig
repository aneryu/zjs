//! Native record tables and dispatch for primitive wrappers and Symbol helpers.
//!
//! Boolean, BigInt, String, Number valueOf, and Symbol records share this
//! domain because they converge on the same wrapper/coercion machinery; Number
//! formatting stays in `number_ops`. Call inputs are borrowed and returned
//! values are owned.

const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const builtin_glue = @import("builtin_glue.zig");
const exceptions = @import("exceptions.zig");
const object_ops = @import("object_ops.zig");

const HostError = exceptions.HostError;

pub const description = core.symbol.description;
pub const registryKey = core.symbol.registryKey;
pub const canBeHeldWeakly = core.symbol.canBeHeldWeakly;

pub fn toString(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// `.primitive` native-builtin ids encode `class_tag * 10 + method` (class
/// tags: 1 number, 2 boolean, 3 bigint, 4 symbol, 5 string; see
/// `exec/object_ops.primitivePrototypeMethod`). Method 1 is toString, 2
/// valueOf, 3 the constructor-called-as-function path; the Symbol-only getter
/// (4 description) and method (5 [Symbol.toPrimitive]) also live here because
/// they share the same QuickJS primitive wrapper dispatch domain. Methods 6+
/// are the wrapper *constructor* statics (qjs's separate `js_<class>_funcs`
/// lists), which do not route through `primitivePrototypeMethod`.
const Tag = enum(u32) {
    number = 1,
    boolean = 2,
    bigint = 3,
    symbol = 4,
    string = 5,
};

fn primitiveId(comptime tag: Tag, comptime method: u32) u32 {
    return @intFromEnum(tag) * 10 + method;
}

/// Boolean's slice of the `.primitive` native-builtin domain: the
/// `Boolean.prototype` toString/valueOf and `Boolean(...)` called as a
/// function. The domain also carries the generic Number/BigInt/String prototype
/// toString/valueOf entries below because their dispatch is the same shared exec
/// op.
pub const boolean_entries = [_]core.host_function.InternalEntry{
    primitiveEntry("toString", 0, primitiveId(.boolean, 1)),
    primitiveEntry("valueOf", 0, primitiveId(.boolean, 2)),
    // Boolean(...) called as a function (constructor path id, method 3).
    primitiveEntry("Boolean", 1, primitiveId(.boolean, 3)),
};

/// Number/BigInt/String prototype toString/valueOf entries that share the
/// `.primitive` domain. Number's toString is dispatched through the `.number`
/// domain (number_ops.zig), so only its valueOf appears here.
pub const shared_entries = [_]core.host_function.InternalEntry{
    primitiveEntry("valueOf", 0, primitiveId(.number, 2)),
    primitiveEntry("toString", 0, primitiveId(.bigint, 1)),
    primitiveEntry("valueOf", 0, primitiveId(.bigint, 2)),
    primitiveEntry("toString", 0, primitiveId(.string, 1)),
    primitiveEntry("valueOf", 0, primitiveId(.string, 2)),
};

/// Symbol's slice of the `.primitive` native-builtin domain (class tag 4).
/// Methods: 1 toString, 2 valueOf, 3 `Symbol(...)` called as a function, 4 the
/// `description` getter, 5 `[Symbol.toPrimitive]`. The description getter and
/// `[Symbol.toPrimitive]` ids must match the `primitive_symbol_*_id` constants
/// the registry installs.
pub const symbol_entries = [_]core.host_function.InternalEntry{
    primitiveEntry("toString", 0, 41),
    primitiveEntry("valueOf", 0, 42),
    primitiveEntry("Symbol", 0, 43),
    primitiveEntry("get description", 0, 44),
    primitiveEntry("[Symbol.toPrimitive]", 1, 45),
};

/// `BigInt.asIntN` / `BigInt.asUintN`: qjs `js_bigint_funcs`
/// (quickjs.c:56350), a two-entry `JS_CFUNC_MAGIC_DEF` list over the single
/// body `js_bigint_asUintN` whose magic selects the signedness (0 unsigned,
/// 1 signed). They stay in the `.primitive` domain rather than getting one of
/// their own because that domain already *is* the wrapper-primitive class
/// family; `.buffer` sets the same precedent by holding the ArrayBuffer,
/// SharedArrayBuffer, DataView and %TypedArray% lists in separate id blocks.
/// Ids continue BigInt's class-tag-3 block past the prototype methods.
pub const bigint_asintn_id: u32 = primitiveId(.bigint, 6);
pub const bigint_asuintn_id: u32 = primitiveId(.bigint, 7);

pub const bigint_static_entries = [_]core.host_function.InternalEntry{
    primitiveStaticEntry("asIntN", 2, bigint_asintn_id),
    primitiveStaticEntry("asUintN", 2, bigint_asuintn_id),
};

/// `Symbol.for` / `Symbol.keyFor`: qjs `js_symbol_funcs` (quickjs.c:51672),
/// two plain `JS_CFUNC_DEF` entries over `js_symbol_for` (quickjs.c:51648)
/// and `js_symbol_keyFor` (quickjs.c:51659). Same domain rationale as the
/// BigInt statics above; ids continue Symbol's class-tag-4 block past its
/// prototype methods, the `Symbol(...)`-as-function path and the two
/// Symbol-only accessors (41-45).
pub const symbol_for_id: u32 = primitiveId(.symbol, 6);
pub const symbol_key_for_id: u32 = primitiveId(.symbol, 7);

pub const symbol_static_entries = [_]core.host_function.InternalEntry{
    primitiveStaticEntry("for", 1, symbol_for_id),
    primitiveStaticEntry("keyFor", 1, symbol_key_for_id),
};

fn primitiveEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&primitiveCall),
    };
}

/// Shared record handler for the `.primitive` domain. It consumes the atomic
/// final-call realm view and delegates to `primitivePrototypeMethod`, which stays in
/// exec because the VM's prototype-method fast path also calls it.
pub fn primitiveCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    const ctx = realm.realm;
    const function_object = host_call.func_obj orelse return error.TypeError;
    return object_ops.primitivePrototypeMethod(
        ctx,
        host_call.output,
        realm.global,
        function_object,
        host_call.this_value,
        host_call.magic,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}

fn primitiveStaticEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&primitiveStaticCall),
    };
}

/// Shared record handler for the wrapper-primitive *constructor* statics
/// (method ids 6+). These are ordinary `JS_CFUNC_*_DEF` entries in qjs, so
/// they belong on the record path like every other builtin; before this they
/// were the last `.none`-tagged bigint/symbol tables and fell through to
/// `call_runtime.callNativeCallableByName`'s name cascade.
fn primitiveStaticCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    const ctx = realm.realm;
    return switch (host_call.magic) {
        // qjs js_bigint_asUintN (quickjs.c:56322) with magic 1 == signed.
        bigint_asintn_id => builtin_glue.bigIntAsN(
            ctx,
            host_call.output,
            realm.global,
            host_call.args,
            false,
            builtin_dispatch.callerBytecode(host_call),
            builtin_dispatch.callerFrame(host_call),
        ),
        // qjs js_bigint_asUintN (quickjs.c:56322) with magic 0 == unsigned.
        bigint_asuintn_id => builtin_glue.bigIntAsN(
            ctx,
            host_call.output,
            realm.global,
            host_call.args,
            true,
            builtin_dispatch.callerBytecode(host_call),
            builtin_dispatch.callerFrame(host_call),
        ),
        // qjs js_symbol_for (quickjs.c:51648).
        symbol_for_id => builtin_glue.symbolFor(
            ctx,
            host_call.output,
            realm.global,
            host_call.args,
            builtin_dispatch.callerBytecode(host_call),
            builtin_dispatch.callerFrame(host_call),
        ),
        // qjs js_symbol_keyFor (quickjs.c:51659).
        symbol_key_for_id => builtin_glue.symbolKeyFor(ctx.runtime, host_call.args),
        else => error.TypeError,
    };
}
