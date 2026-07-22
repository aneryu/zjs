const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
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
/// `exec/object_ops.qjsPrimitivePrototypeMethod`). Method 1 is toString, 2
/// valueOf, 3 the constructor-called-as-function path; the Symbol-only getter
/// (4 description) and method (5 [Symbol.toPrimitive]) also live here because
/// they share the same QuickJS primitive wrapper dispatch domain.
const Tag = enum(u32) {
    number = 1,
    boolean = 2,
    bigint = 3,
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

/// Shared record handler for the `.primitive` domain. It resolves the active
/// realm global (call global, else the function object's realm, else the
/// context global) and delegates to `qjsPrimitivePrototypeMethod`, which stays in
/// exec because the VM's prototype-method fast path also calls it.
pub fn primitiveCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const function_object = host_call.func_obj orelse return error.TypeError;
    const active_global = host_call.global orelse object_ops.objectRealmGlobal(function_object) orelse ctx.global orelse return error.TypeError;
    return object_ops.qjsPrimitivePrototypeMethod(
        ctx,
        host_call.output,
        active_global,
        function_object,
        host_call.this_value,
        host_call.magic,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}
