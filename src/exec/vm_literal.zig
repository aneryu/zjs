//! Object, array, spread, rest, and special-object literal opcode adapters.
//!
//! Popped stack values are owned locally; successful property insertion or
//! stack push transfers them, while guarded fast probes remain borrow-until-
//! commit. Observable iterator and property work stays on the explicit call
//! environment. The opcode bodies follow QuickJS object/field creation at
//! quickjs.c:17961 and quickjs.c:19269, spread copying at quickjs.c:16814-16920,
//! and rest-array construction at quickjs.c:18017.

const std = @import("std");
const builtin = @import("builtin");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const object_ops = @import("object_ops.zig");
const stack_mod = @import("stack.zig");

const op = bytecode.opcode.op;
const special_object_subtype = bytecode.opcode.special_object_subtype;

pub const Step = enum { done, continue_loop };

pub noinline fn object(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    global: *core.Object,
) !void {
    const created = try core.Object.create(ctx.runtime, core.class.ids.object, object_ops.objectPrototypeFromGlobal(ctx.runtime, global));
    const value = created.value();
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub noinline fn objectReserved2(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    global: *core.Object,
) !void {
    const created = try core.Object.createPlainObjectReserved2(
        ctx.runtime,
        object_ops.objectPrototypeFromGlobal(ctx.runtime, global),
    );
    const value = created.value();
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

/// Frameless OP_object fast path (qjs CASE(OP_object): `*sp++ = JS_NewObject(ctx)`,
/// quickjs.c:17961). Creates a bare `{}` and returns it OWNED for the handler to push
/// onto the register-resident sp, so no `publish`/stack round-trip is needed — object
/// creation runs no user code and captures no backtrace (qjs sets no `sf->cur_pc`
/// here), only OOM can fail (→ handler routes to the cold shell). Mirrors the object()
/// body minus the stack.pushOwned so the value stays in a register.
pub inline fn newPlainObjectValue(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    const created = try core.Object.create(ctx.runtime, core.class.ids.object, object_ops.objectPrototypeFromGlobal(ctx.runtime, global));
    return created.value();
}

pub inline fn newPlainObjectReserved2Value(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    const created = try core.Object.createPlainObjectReserved2(
        ctx.runtime,
        object_ops.objectPrototypeFromGlobal(ctx.runtime, global),
    );
    return created.value();
}

/// Frameless OP_define_field fast leg (qjs CASE(OP_define_field): a single
/// JS_DefinePropertyValue on sp[-2] with sp[-1], quickjs.c:19269). Handles the
/// plain-data-add/replace on a plain, extensible, non-array, non-exotic, non-proxy
/// `obj` for ANY value shape — qjs's define path carries no value-form gate either:
/// a refcounted value ({left:obj,right:obj} literals) takes the same
/// JS_DefinePropertyValue fast route as an int. No explicit value rooting is needed
/// across the shape-transition alloc/GC: the value keeps its live refcount in the
/// (unpublished) sp slot, and cycle removal is qjs-faithful trial deletion
/// (gc_decref/gc_scan) — a refcount unaccounted for by traced children IS an
/// external root, so the stack-held ref keeps the value alive. Returns true on a
/// completed define (handler pops the value + keeps obj as the literal receiver);
/// false routes to the cold shell (arrays, proxies, non-extensible, setters — every
/// backtrace/user-code-capable case stays on the publishing path). `value` is
/// CONSUMED into the property slot on success (like the cold leg's Descriptor.data)
/// and NOT consumed on `false` — definePlainDataPropertyKnownFast is
/// borrow-until-commit on its failure paths, so the cold shell re-executes the
/// opcode with the stack's ownership intact (no double-free on OOM mid-append).
///
/// No private-atom probe: OP_define_field's u32 operand is a parser-minted
/// property-name atom — every private name is discriminated at parse time into
/// the define/get/put_private_field family (qjs OP_define_field likewise
/// carries no JS_ATOM_TYPE_PRIVATE test, quickjs.c:19269), so the
/// mightBePrivate 3-load chain was a zjs-only tax on the trusted bytecode-atom
/// path (op_get/put_field precedent). Debug keeps the precise kind claim.
/// The receiver is likewise an evaluated expression value (OP_object /
/// push_this / any literal-start), never a make_ref cell pair, so the
/// trusted-expression classification skips the header-kind re-load.
pub inline fn defineFieldFast(rt: *core.JSRuntime, obj: core.JSValue, atom_id: core.Atom, value: core.JSValue) bool {
    if (comptime builtin.mode == .Debug) {
        std.debug.assert(rt.atoms.kind(atom_id) != .private);
    }
    const target = object_ops.objectFromValueTrustedExpression(obj) orelse return false;
    // qjs OP_define_field → JS_DefinePropertyValue with JS_PROP_THROW: only a plain
    // ordinary object with room to add a data property takes the in-CASE fast add;
    // everything exotic/proxy/array/non-extensible defers to the general define.
    if (target.class_id != core.class.ids.object) return false;
    if (target.hasExoticMethods()) return false;
    if (target.proxyTarget() != null) return false;
    if (target.isArray()) return false;
    if (!target.flags.extensible) return false;
    target.definePlainDataPropertyKnownFast(rt, atom_id, value) catch return false;
    return true;
}

pub noinline fn arrayFrom(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
) !void {
    const argc = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    var stack_values: [8]core.JSValue = undefined;
    const values = if (argc <= stack_values.len)
        stack_values[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > stack_values.len) ctx.runtime.memory.free(core.JSValue, values);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        values[remaining] = try stack.pop();
    }
    defer for (values) |value| value.free(ctx.runtime);
    const array = try core.array.constructLiteralWithPrototype(ctx.runtime, values, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer array.free(ctx.runtime);
    try stack.pushOwned(array);
}

pub noinline fn defineField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const atom_id = readInt(u32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    if (ctx.runtime.atoms.kind(atom_id) == .private) return error.InvalidBytecode;
    const value = try stack.pop();
    const obj = stack.peekBorrowed() orelse return error.StackUnderflow;
    if (!value.requiresRefCount()) {
        if (property_ops.expectObject(obj)) |target| {
            // flags.extensible gate: qjs OP_define_field (quickjs.c:19269) goes
            // through JS_DefinePropertyValue with JS_PROP_THROW, which enforces
            // extensibility in JS_CreateProperty — a non-extensible
            // object must fall through to createDataPropertyOrThrow's TypeError.
            if (target.class_id == core.class.ids.object and
                !target.hasExoticMethods() and
                target.proxyTarget() == null and
                !target.isArray() and
                target.flags.extensible)
            {
                try target.definePlainDataPropertyKnownFast(ctx.runtime, atom_id, value);
                return .done;
            }
        } else |_| {}
    }
    var rooted_value = value;
    defer value.free(ctx.runtime);
    var rooted_obj = obj;
    var root_frame = core.runtime.rootValues(.{ &rooted_value, &rooted_obj });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const target = try property_ops.expectObject(obj);
    if (target.isArray() and atom_id == core.atom.ids.length and
        target.flags.length_writable and target.shape_ref.prop_count == 0)
    {
        if (value.asInt32()) |length| {
            const new_len: u32 = @intCast(@max(length, 0));
            // No index properties to delete, so the length set reduces to the
            // dense case: growth keeps the fast array (tail holes), shrink frees
            // the dense tail via truncateArrayElements. No sparse conversion
            // either way — faithful to set_array_length (quickjs.c:9447-9455).
            // Arrays carrying index properties fall through to defineArrayLength.
            target.truncateArrayElements(ctx.runtime, new_len);
            target.setArrayLength(new_len);
            return .done;
        }
    }
    if (target.isArray()) {
        if (core.array.arrayIndexFromAtom(&ctx.runtime.atoms, atom_id)) |index| {
            if (try target.defineDenseArrayDataProperty(ctx.runtime, index, rooted_value)) return .done;
        }
    }
    if (target.class_id == core.class.ids.object and
        !target.hasExoticMethods() and
        target.proxyTarget() == null and
        !target.isArray() and
        target.flags.extensible and
        target.shape_ref.prop_count == 0)
    {
        try target.defineOwnPropertyAssumingNew(ctx.runtime, atom_id, core.Descriptor.data(rooted_value, true, true, true));
        return .done;
    }
    object_ops.createDataPropertyOrThrow(ctx, output, global, rooted_obj, target, atom_id, rooted_value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn setProto(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
) !void {
    const proto_value = try stack.pop();
    defer proto_value.free(ctx.runtime);
    const obj = stack.peek() orelse return error.StackUnderflow;
    defer obj.free(ctx.runtime);
    const object_value = try property_ops.expectObject(obj);
    if (proto_value.isNull()) {
        try object_value.setPrototype(ctx.runtime, null);
    } else if (proto_value.isObject()) {
        try object_value.setPrototype(ctx.runtime, try property_ops.expectObject(proto_value));
    }
}

pub noinline fn defineArrayEl(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const value = try stack.pop();
    var rooted_value = value;
    defer value.free(ctx.runtime);
    const index = try stack.pop();
    var rooted_index = index;
    defer index.free(ctx.runtime);
    const array_value = stack.peek() orelse return error.StackUnderflow;
    var rooted_array = array_value;
    defer array_value.free(ctx.runtime);

    var root_frame = core.runtime.rootValues(.{ &rooted_value, &rooted_index, &rooted_array });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const object_value = property_ops.expectObject(rooted_array) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, frame, catch_target, global, err);
    const atom_id = object_ops.toPropertyKeyAtom(ctx, output, global, rooted_index, function, frame) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, frame, catch_target, global, err);
    defer ctx.runtime.atoms.free(atom_id);
    object_ops.createDataPropertyOrThrow(ctx, output, global, rooted_array, object_value, atom_id, rooted_value, function, frame) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, frame, catch_target, global, err);
    try stack.push(rooted_index);
    return .done;
}

pub fn appendSpreadValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    opc: u8,
) !void {
    const iterable = try stack.pop();
    defer iterable.free(ctx.runtime);
    const index = try stack.pop();
    defer index.free(ctx.runtime);
    _ = opc;
    const array_value = stack.peek() orelse return error.StackUnderflow;
    defer array_value.free(ctx.runtime);
    const array = try property_ops.expectObject(array_value);
    const start_index = index.asInt32() orelse 0;
    // Faithful to qjs js_append_enumerate (quickjs.c:16814): resolve @@iterator
    // and create the iterator, taking the dense bulk copy ONLY when the Array
    // iterator protocol is un-tampered. The former `is_array`-only fast path
    // silently ignored a user-patched src[Symbol.iterator] / %ArrayIteratorPrototype%.next.
    const out_index = try call_runtime.appendSpreadValuesEnumerate(ctx, output, global, array, iterable, start_index);
    try stack.pushOwned(core.JSValue.int32(out_index));
}

pub noinline fn appendSpreadValuesVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    opc: u8,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    appendSpreadValues(ctx, output, global, stack, opc) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn copyDataProperties(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    mask: u8,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const rt = ctx.runtime;
    const target_value = try stackValueFromTop(stack, mask & 3);
    var rooted_target_value = target_value;
    defer target_value.free(rt);
    const source_value = try stackValueFromTop(stack, (mask >> 2) & 7);
    var rooted_source_value = source_value;
    defer source_value.free(rt);
    const exclusion_value = try stackValueFromTop(stack, (mask >> 5) & 7);
    var rooted_exclusion_value = exclusion_value;
    defer exclusion_value.free(rt);

    var root_frame = core.runtime.rootValues(.{
        &rooted_target_value,
        &rooted_source_value,
        &rooted_exclusion_value,
    });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    // qjs JS_CopyDataProperties (quickjs.c:16912-16913) skips EVERY non-object
    // source — `{...5}`, `{...true}`, `{..."ab"}`, `{...Symbol()}` all yield no
    // properties, not just null/undefined. (Object-rest destructuring still
    // copies from a wrapped string because its source is objectified upstream
    // before OP_copy_data_properties, both engines.) The former
    // null/undefined-only skip let a primitive source fall into expectObject's
    // TypeError — a divergence from qjs, not a spec-ordering guard.
    if (!rooted_source_value.isObject()) return .done;

    const target = property_ops.expectObject(rooted_target_value) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
    const source = property_ops.expectObject(rooted_source_value) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
    const exclusion: ?*core.Object = if (rooted_exclusion_value.isNull() or rooted_exclusion_value.isUndefined())
        null
    else
        property_ops.expectObject(rooted_exclusion_value) catch |err|
            return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
    const keys = object_ops.objectRestOwnKeys(ctx, output, global, source) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
    defer core.Object.freeKeys(rt, keys);

    // qjs JS_CopyDataProperties (quickjs.c:16920) requests JS_GPN_ENUM_ONLY
    // for an ordinary (non-exotic) source, so the per-key enumerable
    // descriptor probe is folded into the key enumeration up-front: the key
    // set is already enumerable-filtered before the copy loop runs any
    // user getter, and each surviving key takes a single JS_GetProperty.
    // Only an exotic source with a get_own_property_names hook (a Proxy, or
    // a typed array / module namespace here) keeps JS_GPN_ENUM_ONLY cleared,
    // so its descriptor test stays interleaved with the per-key get (trap
    // ordering for a proxy: gopd:k, get:k, ...).
    const source_is_ordinary = source.proxyTarget() == null and
        !core.object.isTypedArrayObject(source) and
        source.class_id != core.class.ids.module_ns;
    if (source_is_ordinary) {
        // Up-front enumerable snapshot. getOwnProperty for an ordinary source
        // never invokes a user getter (it surfaces the getter function, not
        // its result), so resolving every key's enumerability here is free of
        // observable side effects -- and it freezes which keys copy before any
        // value getter can mutate a later key's enumerability/existence
        // (qjs ENUM_ONLY snapshots tab_atom once up front).
        const copy_flags = try rt.memory.alloc(bool, keys.len);
        defer rt.memory.free(bool, copy_flags);
        for (keys, copy_flags) |key, *copy| {
            if (exclusion) |excluded| {
                if (excluded.hasOwnProperty(key)) {
                    copy.* = false;
                    continue;
                }
            }
            copy.* = switch (source.ownPropertyEnumerableKind(rt, key)) {
                .enumerable => true,
                .not_enumerable => false,
                // Ordinary sources never yield `.descriptor` here (typed
                // arrays / module namespaces are routed to the interleaved
                // path above); fall back defensively if that ever changes.
                .descriptor => blk: {
                    const maybe_desc = object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, source, key) catch |err|
                        return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
                    const desc = maybe_desc orelse break :blk false;
                    defer desc.destroy(rt);
                    break :blk (desc.enumerable orelse false);
                },
            };
        }
        for (keys, copy_flags) |key, copy| {
            if (!copy) continue;
            const value = object_ops.getValueProperty(ctx, output, global, rooted_source_value, key, caller_function, caller_frame) catch |err|
                return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
            var rooted_value = value;
            defer value.free(rt);
            var value_root_values = [_]core.runtime.ValueRootValue{
                .{ .value = &rooted_value },
            };
            var value_root_frame = core.runtime.ValueRootFrame{
                .values = &value_root_values,
            };
            value_root_frame.activate(rt);
            defer value_root_frame.deactivate(rt);
            property_ops.defineDataProperty(rt, target, key, rooted_value) catch |err|
                return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
        }
        return .done;
    }

    for (keys) |key| {
        if (exclusion) |excluded| {
            if (excluded.hasOwnProperty(key)) continue;
        }
        const maybe_desc = object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, source, key) catch |err|
            return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
        const desc = maybe_desc orelse continue;
        defer desc.destroy(rt);
        if (!(desc.enumerable orelse false)) continue;
        const value = object_ops.getValueProperty(ctx, output, global, rooted_source_value, key, caller_function, caller_frame) catch |err|
            return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
        var rooted_value = value;
        defer value.free(rt);
        var value_root_frame = core.runtime.rootValues(.{&rooted_value});
        value_root_frame.activate(rt);
        defer value_root_frame.deactivate(rt);
        property_ops.defineDataProperty(rt, target, key, rooted_value) catch |err|
            return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
    }
    return .done;
}

fn handleLiteralRuntimeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    err: anytype,
) !Step {
    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
    return err;
}

pub noinline fn specialObject(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
) !void {
    const subtype = function.byteCode()[frame.pc];
    frame.pc += 1;
    if (subtype == 0 or subtype == 1) {
        const arguments = try object_ops.frameArgumentsObjectForSpecialObject(ctx, global, frame, subtype);
        errdefer arguments.free(ctx.runtime);
        try stack.pushOwned(arguments);
    } else if (subtype == 2) {
        try stack.push(frame.current_function);
    } else if (subtype == 3) {
        try stack.push(frame.newTargetValue());
    } else if (subtype == special_object_subtype.home_object) {
        if (property_ops.expectObject(frame.current_function)) |function_object| {
            if (function_object.functionHomeObject()) |home_object| {
                try stack.push(home_object.value());
                return;
            }
        } else |_| {}
        try stack.pushOwned(core.JSValue.undefinedValue());
    } else if (subtype == special_object_subtype.import_meta) {
        const import_meta = try object_ops.importMetaObject(ctx, function);
        errdefer import_meta.free(ctx.runtime);
        try stack.pushOwned(import_meta);
    } else if (subtype == special_object_subtype.var_object) {
        const var_object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
        const value = var_object.value();
        errdefer value.free(ctx.runtime);
        try stack.pushOwned(value);
    } else {
        try stack.pushOwned(core.JSValue.undefinedValue());
    }
}

pub noinline fn getLength(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const length = object_ops.getValueProperty(ctx, output, global, value, core.atom.ids.length, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    errdefer length.free(ctx.runtime);
    try stack.pushOwned(length);
    return .done;
}

pub noinline fn rest(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const first_arg_idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    // qjs OP_rest uses js_create_array → JS_NewArray (quickjs.c:18017, 9601-9607,
    // 5841-5844), whose shape proto is the realm Array.prototype. Rest arrays
    // must walk that real chain; the deleted class-name Get fallback is gone.
    const prototype = if (ctx.global) |global| array_ops.arrayPrototypeFromGlobal(ctx.runtime, global) else null;
    const object_value = try core.Object.createArray(ctx.runtime, prototype);
    var array_value = object_value.value();
    var element_value = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &array_value, &element_value });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    errdefer {
        const failed_array = array_value;
        array_value = core.JSValue.undefinedValue();
        failed_array.free(ctx.runtime);
    }
    var source_index: usize = first_arg_idx;
    while (source_index < frame.actual_arg_count and source_index < frame.args.len) : (source_index += 1) {
        const value = frame.args[source_index].dup();
        element_value = value;
        var value_owned = true;
        errdefer if (value_owned) {
            element_value = core.JSValue.undefinedValue();
            value.free(ctx.runtime);
        };
        try object_value.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(object_value.arrayLength()), core.Descriptor.data(value, true, true, true));
        element_value = core.JSValue.undefinedValue();
        value.free(ctx.runtime);
        value_owned = false;
    }
    try stack.pushOwned(array_value);
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.len()) return error.StackUnderflow;
    return stack.values[stack.len() - 1 - index_from_top].dup();
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
