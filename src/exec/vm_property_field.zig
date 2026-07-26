//! Property field and array-element opcode handlers (get/put_field, get/put_array_el, in/instanceof, to_prop_key).

const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const frame_mod = @import("frame.zig");
const property_ic = @import("property_ic.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const builtin_glue = @import("builtin_glue.zig");
const array_ops = @import("array_ops.zig");
const forof_ops = @import("forof_ops.zig");
const object_ops = @import("object_ops.zig");
const regexp_fastpath = @import("regexp_fastpath.zig");
const slot_ops = @import("slot_ops.zig");
const string_ops = @import("string_ops.zig");
const objectFromValue = object_ops.objectFromValue;
const readInt = call_runtime.readInt;
const varRefCellFromValue = slot_ops.varRefCellFromValue;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const property_vm = @import("vm_property.zig");
const BindingGet = property_vm.BindingGet;
const BindingPut = property_vm.BindingPut;
const DecodedFalseBranch = property_vm.DecodedFalseBranch;
const GlobalBindingGet = property_vm.GlobalBindingGet;
const GlobalBindingPut = property_vm.GlobalBindingPut;
const LoopLimitGet = property_vm.LoopLimitGet;
const Step = property_vm.Step;
const atomAsciiText = property_vm.atomAsciiText;
const atomStringValueForFastPath = property_vm.atomStringValueForFastPath;
const bindingReadableBorrowed = property_vm.bindingReadableBorrowed;
const bindingStoreWritableForFastPath = property_vm.bindingStoreWritableForFastPath;
const decodeBindingGet = property_vm.decodeBindingGet;
const decodeBindingPut = property_vm.decodeBindingPut;
const decodeFalseBranch = property_vm.decodeFalseBranch;
const decodeGlobalDataGet = property_vm.decodeGlobalDataGet;
const decodeGlobalPut = property_vm.decodeGlobalPut;
const decodeGotoTarget = property_vm.decodeGotoTarget;
const decodeLocalGet = property_vm.decodeLocalGet;
const decodeLocalPut = property_vm.decodeLocalPut;
const decodeLoopLimitGet = property_vm.decodeLoopLimitGet;
const decodeOptionalLocalCompletionTail = property_vm.decodeOptionalLocalCompletionTail;
const decodeStringSliceConstLocalStore = property_vm.decodeStringSliceConstLocalStore;
const fastArrayPrototypeMethodIsDefault = property_vm.fastArrayPrototypeMethodIsDefault;
pub const fastDenseArrayElementValue = property_vm.fastDenseArrayElementValue;
pub const fastArrayOwnIntElementValue = property_vm.fastArrayOwnIntElementValue;
pub const fastArrayOwnIntElementSet = property_vm.fastArrayOwnIntElementSet;
const fastRegExpPrototypeMethodIsDefault = property_vm.fastRegExpPrototypeMethodIsDefault;
const finishUndefinedCallResult = property_vm.finishUndefinedCallResult;
const frameHasVarRefBinding = property_vm.frameHasVarRefBinding;
const immediateInt32Operand = property_vm.immediateInt32Operand;
const isHostOutputFunctionValue = property_vm.isHostOutputFunctionValue;
const loopLimitReadableInt32 = property_vm.loopLimitReadableInt32;
const mathMinMaxInductionRangeSum = property_vm.mathMinMaxInductionRangeSum;
const mathMinMaxPrimitive2 = property_vm.mathMinMaxPrimitive2;
const sameBinding = property_vm.sameBinding;
const slotValueBorrowed = property_vm.slotValueBorrowed;
const storeBindingOwnedValue = property_vm.storeBindingOwnedValue;
const storeLocalCompletionBorrowedValue = property_vm.storeLocalCompletionBorrowedValue;
const storeStringSliceConstLocal = property_vm.storeStringSliceConstLocal;
const stringFromCharCodeInt32Arg = property_vm.stringFromCharCodeInt32Arg;
const varRefReadableBorrowed = property_vm.varRefReadableBorrowed;

const functionOwnDataPropertyValueForFastPath = property_ic.functionOwnDataPropertyValueForFastPath;
const functionOwnNativeBuiltinRefForFastPath = property_ic.functionOwnNativeBuiltinRefForFastPath;
const dataPropertyValueForFastPath = property_ic.dataPropertyValueForFastPath;
const globalOwnDataPropertyValue = property_ic.globalOwnDataPropertyValue;
const ordinaryDataPropertyValueOrUndefinedForFastPath = property_ic.ordinaryDataPropertyValueOrUndefinedForFastPath;
const ownDataPropertyValueMaterializedForFastPath = property_ic.ownDataPropertyValueMaterializedForFastPath;
const op = bytecode.opcode.op;
const atom_byte_length = core.atom.predefinedId("byteLength", .string).?;
const atom_byte_offset = core.atom.predefinedId("byteOffset", .string).?;

const RegExpMatchGet = union(enum) {
    binding: BindingGet,
    global: GlobalBindingGet,
};

const RegExpMatchPut = union(enum) {
    binding: BindingPut,
    global: GlobalBindingPut,
};

fn sameBindingGetPut(get: BindingGet, put: BindingPut) bool {
    return get.idx == put.idx and get.is_var_ref == put.is_var_ref;
}

fn decodeRegExpMatchGet(function: *const bytecode.FunctionBytecode, pc: usize) ?RegExpMatchGet {
    const code = function.byteCode();
    if (decodeBindingGet(code, pc)) |get| return .{ .binding = get };
    if (decodeGlobalDataGet(function, pc)) |get| return .{ .global = get };
    return null;
}

fn decodeRegExpMatchPut(function: *const bytecode.FunctionBytecode, pc: usize) ?RegExpMatchPut {
    const code = function.byteCode();
    if (decodeBindingPut(code, pc)) |put| return .{ .binding = put };
    if (decodeGlobalPut(function, pc)) |put| return .{ .global = put };
    return null;
}

fn regExpMatchGetNextPc(get: RegExpMatchGet) usize {
    return switch (get) {
        .binding => |binding| binding.next_pc,
        .global => |global| global.next_pc,
    };
}

fn regExpMatchPutNextPc(put: RegExpMatchPut) usize {
    return switch (put) {
        .binding => |binding| binding.operand_pc + binding.consume,
        .global => |global| global.next_pc,
    };
}

fn sameRegExpMatchGetPut(get: RegExpMatchGet, put: RegExpMatchPut) bool {
    return switch (get) {
        .binding => |get_binding| switch (put) {
            .binding => |put_binding| sameBindingGetPut(get_binding, put_binding),
            .global => false,
        },
        .global => |get_global| switch (put) {
            .binding => false,
            .global => |put_global| get_global.atom == put_global.atom,
        },
    };
}

pub fn toPropKey(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const key = try object_ops.toPropertyKeyValue(ctx, output, global, value, function, frame);
    errdefer key.free(ctx.runtime);
    try stack.pushOwned(key);
}

pub noinline fn toPropKeyVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    toPropKey(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn setName(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    opc: u8,
) !void {
    switch (opc) {
        op.set_name => {
            const atom_id = readInt(u32, function.byteCode()[frame.pc..][0..4]);
            frame.pc += 4;
            if (stack.len() == 0) return error.StackUnderflow;
            const value = try stackValueFromTop(stack, 0);
            defer value.free(ctx.runtime);
            if (value.isObject()) {
                const object = try property_ops.expectObject(value);
                const name_value = try call_runtime.functionNameValueFromAtom(ctx.runtime, atom_id, null);
                defer name_value.free(ctx.runtime);
                try object_ops.defineFunctionNameProperty(ctx.runtime, object, name_value);
            }
        },
        op.set_name_computed => {
            if (stack.len() < 2) return error.StackUnderflow;
            const value = stack.values[stack.len() - 1].dup();
            defer value.free(ctx.runtime);
            const key = stack.values[stack.len() - 2].dup();
            defer key.free(ctx.runtime);
            if (value.isObject()) {
                const object = try property_ops.expectObject(value);
                const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame);
                defer ctx.runtime.atoms.free(atom_id);
                const name_value = try call_runtime.functionNameValueFromAtom(ctx.runtime, atom_id, null);
                defer name_value.free(ctx.runtime);
                try object_ops.defineFunctionNameProperty(ctx.runtime, object, name_value);
            }
        },
        else => unreachable,
    }
}

pub noinline fn inOrInstanceof(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !Step {
    const err = if (opc == op.in)
        call_runtime.inOp(ctx, stack, output, global, function, frame)
    else
        call_runtime.instanceofOp(ctx, stack, output, global, function, frame);
    err catch |runtime_err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, runtime_err)) return .continue_loop;
        return runtime_err;
    };
    return .done;
}

pub noinline fn field(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !Step {
    const site_pc = frame.pc - 1;
    const atom_id = readInt(u32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    switch (opc) {
        op.get_field => {
            if (stack.len() == 0) return error.StackUnderflow;
            const top_index = stack.len() - 1;
            const receiver = stack.values[top_index];
            if (dataPropertyValueForFastPath(function, site_pc, ctx.runtime, receiver, atom_id)) |value| {
                replaceTopBorrowed(ctx.runtime, stack, top_index, receiver, value);
                return .done;
            }
            if (qjsGetFieldFast(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopBorrowed(ctx.runtime, stack, top_index, receiver, value);
                return .done;
            }
            if (ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopBorrowed(ctx.runtime, stack, top_index, receiver, value);
                return .done;
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopOwned(ctx.runtime, stack, top_index, receiver, value);
                return .done;
            }
            if (functionOwnDataPropertyValueForFastPath(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopOwned(ctx.runtime, stack, top_index, receiver, value);
                return .done;
            }
            if (fastCollectionPrototypeMethodValue(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopOwned(ctx.runtime, stack, top_index, receiver, value);
                return .done;
            }
            stack.setLen(top_index);
            const obj = receiver;
            defer obj.free(ctx.runtime);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                try forof_ops.closeStackTopForOfIteratorForPendingErrorWithFrame(ctx, output, global, stack, frame);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            stack.pushOwnedAssumeCapacity(value);
        },
        op.get_field2 => {
            const obj = try stackValueFromTop(stack, 0);
            defer obj.free(ctx.runtime);
            if (dataPropertyValueForFastPath(function, site_pc, ctx.runtime, obj, atom_id)) |value| {
                stack.pushAssumeCapacity(value);
                return .done;
            }
            if (qjsGetFieldFast(ctx.runtime, obj, atom_id)) |value| {
                stack.pushAssumeCapacity(value);
                return .done;
            }
            if (ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, obj, atom_id)) |value| {
                stack.pushAssumeCapacity(value);
                return .done;
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                stack.pushOwnedAssumeCapacity(value);
                return .done;
            }
            if (functionOwnDataPropertyValueForFastPath(ctx.runtime, obj, atom_id)) |value| {
                stack.pushOwnedAssumeCapacity(value);
                return .done;
            }
            if (fastCollectionPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                stack.pushOwnedAssumeCapacity(value);
                return .done;
            }
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                try forof_ops.closeStackTopForOfIteratorForPendingErrorWithFrame(ctx, output, global, stack, frame);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.put_field => {
            const value = try stack.pop();
            var value_consumed = false;
            defer if (!value_consumed) value.free(ctx.runtime);
            const obj = try stack.pop();
            defer obj.free(ctx.runtime);
            if (setArrayLengthForPutFieldFastPath(ctx.runtime, obj, atom_id, value)) return .done;
            if (try property_ic.setObjectDataPropertyForPutFieldFastPath(ctx.runtime, function, site_pc, obj, atom_id, value)) {
                value_consumed = true;
                return .done;
            }
            if (qjsPutFieldFast(ctx.runtime, obj, atom_id, value)) {
                value_consumed = true;
                return .done;
            }
            const result = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
                try forof_ops.closeStackTopForOfIteratorForPendingErrorWithFrame(ctx, output, global, stack, frame);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            result.free(ctx.runtime);
        },
        else => unreachable,
    }
    return .done;
}

/// `.length` of a plain fast array (qjs OP_get_length / OP_get_array_length leg):
/// the element count as int32 (float64 above i32) for an own, non-exotic,
/// non-proxy array. Null for everything else — strings are handled by the
/// caller's string leg; exotic/subclassed arrays, typed arrays (not is_array),
/// and objects with a `length` getter fall to the cold getLength.
pub inline fn fastArrayLengthValue(value: core.JSValue) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    if (!object.isArray() or object.hasExoticMethods() or object.proxyTarget() != null) return null;
    const len = object.arrayLength();
    if (len <= @as(u32, @intCast(std.math.maxInt(i32)))) return core.JSValue.int32(@intCast(len));
    return core.JSValue.float64(@floatFromInt(len));
}

/// Debug oracle for the trusted-atom entries below. The precise claim (kind,
/// not the imprecise `mightBePrivate` id-range filter): a get_field/get_field2/
/// put_field/get_length atom operand never names a private atom. Proof chain:
/// every `.`/`?.` member site discriminates TOK_PRIVATE_NAME into the
/// scope_get/put_private_field family or a SyntaxError (parser.zig
/// parseMemberChain/parseNewCalleeMemberAccess), those scope ops lower only to
/// get/put_private_field/check_brand (bytecode.zig writeLoweredPrivateField),
/// object-property names reject TOK_PRIVATE_NAME (parseObjectPropertyName),
/// peepholes copy atoms from already-emitted field ops, and `internString`
/// can never mint a .private atom (kind-filtered predefinedId + .string
/// internDynamic). Mirrors qjs, whose OP_get_field operand is likewise
/// unreachable by JS_ATOM_TYPE_PRIVATE atoms (js_parse_postfix_expr routes
/// #name through OP_scope_get_private_field, quickjs.c:27430, resolved at
/// 27574 into the OP_get_private_field family, 19232).
inline fn debugAssertNonPrivateFieldOperandAtom(rt: *const core.JSRuntime, atom_id: core.Atom) void {
    if (comptime builtin.mode == .Debug) {
        const kind = rt.atoms.kind(atom_id) orelse .string;
        std.debug.assert(kind != .private);
    }
}

inline fn qjsGetFieldFastSlotWithExoticOrder(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    comptime trust_mapped_arguments_probe: bool,
    comptime trust_non_private_atom: bool,
) ?*const core.JSValue {
    // Object-ness gate FIRST, mirroring qjs GET_FIELD_INLINE's leading
    // JS_VALUE_GET_TAG(obj)==JS_TAG_OBJECT check (quickjs.c:19107-19160): a non-object
    // receiver (e.g. a string routed here from op_get_field2) returns immediately
    // without paying the private-atom probe. Two pure guards reordered.
    // Trusted-expression classification: the receiver came off the operand
    // stack as an expression value, so the header-kind re-load in the generic
    // objectFromValue is dead here (see objectFromValueTrustedExpression).
    var object = object_ops.objectFromValueTrustedExpression(receiver) orelse return null;
    // Bytecode atom operands are proven non-private at compile time (see
    // debugAssertNonPrivateFieldOperandAtom), exactly why qjs GET_FIELD_INLINE
    // carries no private-atom probe. Only the computed-key entry
    // (atomPropertyValueForFastPath), whose atoms come from runtime string
    // interning, still pays the range filter.
    if (comptime trust_non_private_atom) {
        debugAssertNonPrivateFieldOperandAtom(rt, atom_id);
    } else {
        if (rt.atoms.mightBePrivate(atom_id)) return null;
    }
    // The mapped-Arguments compensation only matters when the operand atom could
    // name one of the out-of-shape numeric bindings. Those bindings cover indices
    // [0, argc); argc is a u16 arg_count, so every binding atom interns as a
    // tagged-int atom (<= max_int_atom == 2^31-1). A named/symbol atom can never
    // alias a binding, so its shape slot is authoritative — exactly as in qjs,
    // whose find_own_property leans solely on the per-property TMASK/kind check.
    // Hoisting this loop-invariant decision keeps the common named-field walk (the
    // get_field / get_field2 hot path) off the per-object class test entirely; the
    // predicate comptime-folds to false for the get_length caller (trust=true).
    const probe_mapped_arguments = !trust_mapped_arguments_probe and core.atom.isTaggedInt(atom_id);
    while (true) {
        // zjs-only divergence from qjs's probe-first order: mapped Arguments
        // numeric bindings live in out-of-shape var-ref cells, so a shape data
        // slot on a mapped Arguments object can be stale and its hit cannot be
        // trusted — bail before probing. (qjs stores those bindings as
        // JS_PROP_VARREF shape entries, which its own probe rejects via
        // JS_PROP_TMASK.) Only a tagged-int operand atom can alias one of those
        // numeric bindings; named atoms and the constant `length` atom skip it.
        if (probe_mapped_arguments and object.class_id == core.class.ids.mapped_arguments) return null;
        var slow_property = false;
        if (object.findOwnDataSlotFast(atom_id, &slow_property)) |slot| return slot;
        if (slow_property) return null;
        // qjs GET_FIELD_INLINE consults `p->is_exotic` only AFTER the own
        // probe misses (quickjs.c:19135-19141): an own plain-data hit — sparse
        // array element, named data on a typed array, anything the shape
        // authoritatively owns — never pays the class test. Mirror that; a
        // miss on a slow class defers to the full resolver.
        if (object.needsSlowPropertyAccess()) return null;
        // End of the explicit self.prototype chain. We must NOT synthesize `undefined`
        // here: zjs resolves built-in prototype methods/constructor for arrays and other
        // class objects via a by-class-name global fallback (object_ops.getValueProperty),
        // and some objects (rest-parameter arrays, regexp-split results) legitimately have
        // a null self.prototype while still resolving those members through that fallback.
        // Returning null defers to the slow path, which both does the global fallback and
        // returns a genuine `undefined` for truly-absent properties.
        object = object.getPrototype() orelse return null;
    }
}

/// Hot-handler variant: returns the BORROWED own/prototype data slot address
/// so the resident get_field handlers can re-load it as two 64-bit integer
/// words (see findOwnDataSlotFast). The pointer is only valid until the next
/// potentially-shape-mutating operation; both callers consume it immediately.
pub inline fn qjsGetFieldFastSlot(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?*const core.JSValue {
    return qjsGetFieldFastSlotWithExoticOrder(rt, receiver, atom_id, false, true);
}

pub inline fn qjsGetFieldFast(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const slot = qjsGetFieldFastSlotWithExoticOrder(rt, receiver, atom_id, false, false) orelse return null;
    return slot.*;
}

/// qjs GET_FIELD_INLINE probes an own shape entry before `p->is_exotic`.
/// This ordering is safe for the constant `length` atom because it can never
/// alias zjs's out-of-shape mapped Arguments numeric bindings. It lets ordinary
/// own `length` data on Arguments and typed arrays hit before their slow class
/// semantics while misses and accessor entries still defer to the resolver.
pub inline fn qjsGetLengthFieldFast(rt: *core.JSRuntime, receiver: core.JSValue) ?core.JSValue {
    const slot = qjsGetFieldFastSlotWithExoticOrder(rt, receiver, core.atom.ids.length, true, true) orelse return null;
    return slot.*;
}

/// Primitive twin of qjsGetFieldFast. QuickJS selects
/// `ctx->class_proto[primitive_tag]` inside JS_GetPropertyInternal and then
/// performs the same shape walk as an object receiver. Realm prototype slots
/// are the zjs class_proto equivalent; only ordinary data hits are returned.
/// Accessors, auto-init/var-ref properties, exotic/proxy holders, and string
/// own index/length semantics fall back to the full resolver.
pub inline fn primitivePrototypeDataPropertyValueForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    if (rt.atoms.mightBePrivate(atom_id)) return null;
    var object = primitivePrototypeObjectForFastPath(rt, global, receiver, atom_id) orelse return null;
    while (true) {
        if (object.needsSlowPropertyAccess() or object.hasExoticMethods() or object.proxyTarget() != null) return null;
        var slow_property = false;
        if (object.findOwnDataValueFast(atom_id, &slow_property)) |value| return value;
        if (slow_property) return null;
        object = object.getPrototype() orelse return null;
    }
}

inline fn primitivePrototypeObjectForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?*core.Object {
    const slot: core.object.RealmValueSlot = if (receiver.isString()) blk: {
        if (atom_id == core.atom.ids.length or core.atom.isTaggedInt(atom_id)) return null;
        break :blk .string_prototype;
    } else if (receiver.isNumber())
        .number_prototype
    else if (receiver.isBool())
        .boolean_prototype
    else if (receiver.isBigInt())
        .bigint_prototype
    else if (receiver.isSymbol())
        .symbol_prototype
    else
        return null;

    const prototype_value = global.cachedRealmValue(rt, slot) orelse return null;
    return objectFromValue(prototype_value);
}

pub const PropertyFastValue = union(enum) {
    borrowed: core.JSValue,
    owned: core.JSValue,
    getter: core.JSValue,
    proxy: *core.Object,
};

inline fn typedArrayAccessorMethodId(atom_id: core.Atom) ?u32 {
    const TypedArrayAccessorMethod = method_ids.buffer.TypedArrayAccessorMethod;
    if (atom_id == core.atom.ids.length) return @intFromEnum(TypedArrayAccessorMethod.length);
    if (atom_id == atom_byte_length) return @intFromEnum(TypedArrayAccessorMethod.byte_length);
    if (atom_id == atom_byte_offset) return @intFromEnum(TypedArrayAccessorMethod.byte_offset);
    return null;
}

pub inline fn isTypedArrayPayloadAtomForFastPath(atom_id: core.Atom) bool {
    return atom_id == core.atom.ids.length or atom_id == atom_byte_length or atom_id == atom_byte_offset;
}

inline fn typedArrayNativeAccessorIdMatches(encoded_id: i32, expected_id: u32) bool {
    const native_ref = core.function.decodeNativeBuiltinId(encoded_id) orelse return false;
    return native_ref.domain == .buffer and native_ref.id == expected_id;
}

inline fn typedArrayIntrinsicNamedValue(
    rt: *core.JSRuntime,
    receiver: *core.Object,
    atom_id: core.Atom,
) ?PropertyFastValue {
    if (atom_id == core.atom.ids.length) {
        const length = core.object.typedArrayLength(rt, receiver) catch return null;
        return .{ .owned = array_ops.lengthIndexValue(@intCast(length)) };
    }
    if (atom_id == atom_byte_length) {
        const length = core.object.typedArrayByteLength(rt, receiver) catch return null;
        return .{ .owned = array_ops.lengthIndexValue(length) };
    }
    if (atom_id == atom_byte_offset) {
        const offset = core.object.typedArrayEffectiveByteOffset(receiver) catch return null;
        return .{ .owned = array_ops.lengthIndexValue(offset) };
    }
    return null;
}

inline fn typedArrayShapePropertyForFastPath(
    rt: *core.JSRuntime,
    receiver: *core.Object,
    holder: *core.Object,
    index: usize,
    atom_id: core.Atom,
    expected_id: u32,
) ?PropertyFastValue {
    return switch (holder.propKindAt(index)) {
        .data => .{ .borrowed = holder.prop_values[index].slot.data },
        .accessor => accessor: {
            const getter = holder.prop_values[index].slot.accessor.getterValue();
            if (objectFromValue(getter)) |getter_object| {
                if (typedArrayNativeAccessorIdMatches(getter_object.nativeFunctionId(), expected_id)) {
                    break :accessor typedArrayIntrinsicNamedValue(rt, receiver, atom_id);
                }
            }
            break :accessor .{ .getter = getter };
        },
        .auto_init => null,
        .var_ref => null,
    };
}

noinline fn typedArrayPrototypeNamedPropertyForFastPath(
    rt: *core.JSRuntime,
    receiver: *core.Object,
    atom_id: core.Atom,
    expected_id: u32,
) ?PropertyFastValue {
    var holder = receiver.getPrototype() orelse return .{ .borrowed = core.JSValue.undefinedValue() };
    while (true) {
        // Trusted hash-chain probe: mirrors qjs's force-inlined find_own_property
        // (quickjs.c:6135), which walks hash_next off the already-loaded property
        // with no per-step cycle/bounds guards. The defensive findProperty's
        // extra `steps < prop_count` / `index >= prop_count` / `index >= props.len`
        // guards are dead on any well-formed shape (the trusted probe's debug
        // asserts confirm the invariants), so this is the same lean probe the
        // ordinary get_field data path already uses — a faithful alignment, not a
        // behavior change — on this hot `.length`/`.byteLength`/`.byteOffset` walk.
        if (holder.findPropertyIndexTrusted(atom_id)) |index| {
            return typedArrayShapePropertyForFastPath(rt, receiver, holder, index, atom_id, expected_id);
        }
        if (holder.proxyTarget() != null) return .{ .proxy = holder };
        if (holder.needsSlowPropertyAccess() or holder.hasExoticMethods()) return null;
        holder = holder.getPrototype() orelse return .{ .borrowed = core.JSValue.undefinedValue() };
    }
}

noinline fn typedArrayNamedPropertyForFastPath(
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
) ?PropertyFastValue {
    const expected_id = typedArrayAccessorMethodId(atom_id) orelse return null;
    // Trusted hash-chain probe (qjs find_own_property, quickjs.c:6135), matching
    // the ordinary get_field data path rather than the defensive findProperty
    // whose per-step guards are dead on a well-formed shape.
    if (object.findPropertyIndexTrusted(atom_id)) |index| {
        return typedArrayShapePropertyForFastPath(rt, object, object, index, atom_id, expected_id);
    }
    return typedArrayPrototypeNamedPropertyForFastPath(rt, object, atom_id, expected_id);
}

/// Cheap routing guard used only after the ordinary static-field data lookup
/// misses. TypedArray instance class ids are a contiguous range; checking that
/// range avoids probing the out-of-line payload on every ordinary accessor
/// miss. Keeping the test in the opcode handler prevents the larger typed-array
/// action classifier from changing the shared ordinary accessor/Proxy tail.
pub inline fn typedArrayReceiverForFastPath(receiver: core.JSValue) ?*core.Object {
    const object = objectFromValue(receiver) orelse return null;
    if (object.class_id < core.class.ids.uint8c_array or object.class_id > core.class.ids.float64_array) return null;
    return object;
}

/// Static named-property action classifier for TypedArray instances. This is
/// deliberately outlined from atomPropertyValueForFastPath: ordinary static
/// accessor/Proxy reads should retain the same resident handler shape whether
/// or not TypedArray payload accessors are accelerated.
pub inline fn typedArrayPropertyValueForFastPath(
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
) ?PropertyFastValue {
    if (rt.atoms.mightBePrivate(atom_id)) return null;
    return typedArrayNamedPropertyForFastPath(rt, object, atom_id);
}

/// Action half of qjs GET_FIELD_INLINE for the constant `length` atom. The
/// data-only helper above already settles the hot case; after that misses, qjs
/// still inspects an own accessor before consulting `p->is_exotic`. That order
/// matters for user-defined `length` accessors on typed arrays and mapped
/// Arguments. Proxies become resident actions; unsupported exotic misses retain
/// the existing slow machinery.
pub inline fn qjsGetLengthActionForFastPath(rt: *core.JSRuntime, receiver: core.JSValue) ?PropertyFastValue {
    const receiver_object = objectFromValue(receiver) orelse return null;
    var object = receiver_object;
    while (true) {
        if (object.findProperty(core.atom.ids.length)) |index| {
            return switch (object.propKindAt(index)) {
                .data => .{ .borrowed = object.prop_values[index].slot.data },
                .accessor => .{ .getter = object.prop_values[index].slot.accessor.getterValue() },
                .var_ref, .auto_init => null,
            };
        }
        // qjs continues from the typed-array exotic object into its current
        // prototype chain for this non-numeric name. The helper recognizes the
        // unmodified intrinsic accessor without calling it, but custom/null/
        // Proxy prototype chains keep their observable lookup semantics.
        if (core.object.isTypedArrayObject(object)) {
            const expected_id = typedArrayAccessorMethodId(core.atom.ids.length).?;
            // The intrinsic getter's brand check applies to the original
            // receiver, not to the typed-array object where prototype walking
            // happened to arrive (for example Object.create(typedArray)).
            return typedArrayPrototypeNamedPropertyForFastPath(rt, receiver_object, core.atom.ids.length, expected_id);
        }
        if (object.proxyTarget() != null) return .{ .proxy = object };
        if (object.needsSlowPropertyAccess() or object.hasExoticMethods()) return null;
        object = object.getPrototype() orelse return null;
    }
}

inline fn primitivePrototypePropertyForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?PropertyFastValue {
    if (rt.atoms.mightBePrivate(atom_id)) return null;
    var object = primitivePrototypeObjectForFastPath(rt, global, receiver, atom_id) orelse return null;
    while (true) {
        if (object.proxyTarget() != null) return .{ .proxy = object };
        if (object.needsSlowPropertyAccess() or object.hasExoticMethods()) return null;
        if (object.findProperty(atom_id)) |index| {
            return switch (object.propKindAt(index)) {
                .data => .{ .borrowed = object.prop_values[index].slot.data },
                .accessor => .{ .getter = object.prop_values[index].slot.accessor.getterValue() },
                .var_ref, .auto_init => null,
            };
        }
        object = object.getPrototype() orelse return null;
    }
}

/// Atom-keyed counterpart shared by static and computed property handlers.
/// Ordinary receivers return a semantically complete data/getter/Proxy/missing
/// result. Class-specific exotics and primitive index/length cases remain on
/// the general resolver. Returned data/getter values are borrowed from their
/// holder and must be duplicated before the caller releases the receiver.
pub inline fn atomPropertyValueForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?PropertyFastValue {
    if (objectFromValue(receiver)) |object| {
        if (object.class_id == core.class.ids.object or object.isArray() or object.isGlobal()) {
            return switch (property_ic.ordinaryComputedPropertyLookupForFastPath(rt, receiver, atom_id)) {
                .value => |value| .{ .borrowed = value },
                .getter => |getter| .{ .getter = getter },
                .proxy => |proxy| .{ .proxy = proxy },
                .undefined => .{ .borrowed = core.JSValue.undefinedValue() },
                .slow => null,
            };
        }
        const value = qjsGetFieldFast(rt, receiver, atom_id) orelse return null;
        return .{ .borrowed = value };
    }
    return primitivePrototypePropertyForFastPath(rt, global, receiver, atom_id);
}

/// Computed-property twin of the field fast paths. qjs strings are atoms,
/// so JS_ValueToAtom can pass an already-interned key straight into
/// JS_GetProperty. zjs keeps a weak atom back-pointer on materialized strings;
/// when it is present, indexed storage or an ordinary data hit can be resolved
/// without publishing the VM or entering the allocating/general computed-key
/// resolver. The operation cannot re-enter, so borrowing the weak id is safe.
pub inline fn cachedStringPropertyValueForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    key: core.JSValue,
) ?PropertyFastValue {
    const atom_id = string_ops.stringAtomId(key) orelse return null;
    if (core.array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
        if (index <= @as(u32, @intCast(std.math.maxInt(i32)))) {
            const index_value = core.JSValue.int32(@intCast(index));
            if (fastDenseArrayElementValue(receiver, index_value)) |value| return .{ .owned = value };
            if (fastStringIndexValue(rt, receiver, index_value)) |value| return .{ .owned = value };
            if (fastTypedArrayElementValue(rt, receiver, index_value)) |value| return .{ .owned = value };
        }
    }
    return atomPropertyValueForFastPath(rt, global, receiver, atom_id);
}

pub inline fn cachedStringAtomForFastPath(value: core.JSValue) ?core.Atom {
    return string_ops.stringAtomId(value);
}

/// Hot-handler variant of the qjs OP_put_field fast window (quickjs.c:19188-
/// 19203): returns the MUTABLE own plain-writable-data slot address so the
/// resident op_put_field can perform set_value's swap-then-free itself with
/// integer-pair slot accesses. Mirrors the get-side probe-first ordering:
/// - Object-ness gate FIRST (qjs's leading JS_VALUE_GET_TAG(obj) ==
///   JS_TAG_OBJECT check), then the private-atom probe.
/// - find_own_property runs with NO class qualification at all: qjs's write
///   fast path trusts any own shape hit whose flags pass the single
///   (TMASK|WRITABLE|LENGTH) == WRITABLE mask, whatever the class — exotic
///   index storage (typed arrays, strings) never lives in the shape, mapped
///   Arguments numeric bindings are JS_PROP_VARREF entries the mask rejects,
///   and array `length` carries JS_PROP_LENGTH. Unlike GET_FIELD_INLINE
///   there is no miss-side `p->is_exotic` consultation either: the write
///   window is own-hit-only and every miss already defers to the cold
///   resolver (put_field_slow_path -> JS_SetPropertyInternal), which walks
///   prototypes for setters/read-only holders and runs the exotic machinery.
/// - zjs-only deviation, same as qjsGetFieldFastSlot: a mapped Arguments
///   receiver bails before probing — its numeric bindings live in
///   out-of-shape var-ref cells, so a shape data hit could be a stale mirror
///   and a direct slot write would desync the aliased parameter.
/// The pointer is only valid until the next potentially-shape-mutating
/// operation; both callers consume it immediately.
pub inline fn qjsPutFieldFastSlot(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?*core.JSValue {
    // Trusted-expression receiver contract (qjs OP_put_field's raw
    // JS_VALUE_GET_OBJ, quickjs.c:19190-19192): expression receivers are
    // never cells, so the header-kind recheck is a Debug assert only.
    const object = object_ops.objectFromValueTrustedExpression(receiver) orelse return null;
    // Bytecode put_field atom operands are proven non-private (qjs
    // OP_put_field's inline window carries no private probe either,
    // quickjs.c:19177-19199; private stores are OP_put_private_field only).
    debugAssertNonPrivateFieldOperandAtom(rt, atom_id);
    if (object.class_id == core.class.ids.mapped_arguments) return null;
    var slow_property = false;
    if (object.findWritableOwnDataSlotFast(atom_id, &slow_property)) |slot| return slot;
    return null;
}

pub inline fn qjsPutFieldFast(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, value: core.JSValue) bool {
    const slot = qjsPutFieldFastSlot(rt, receiver, atom_id) orelse return false;
    // Integer-pair slot access (qjs set_value's swap-then-free ldp/stp form,
    // quickjs.c:5091): a 128-bit SIMD store here stalls every 64-bit
    // re-reader of the slot — the get_field hit and the for-of done/value
    // probes read property slots as integer halves (JSValue.loadSlotAsIntPair
    // note). (When the stored value is copy-only LLVM may re-fuse the split
    // store into a `str q`; a 64-bit load fully contained in a 128-bit store
    // still forwards, so that lowering is harmless — the split source form
    // just keeps the value SSA-scalar and forwarding-eligible.)
    const old_value = core.JSValue.loadSlotAsIntPair(slot);
    core.JSValue.storeSlotAsIntPair(slot, value);
    old_value.free(rt);
    return true;
}

inline fn replaceTopBorrowed(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    index: usize,
    old_value: core.JSValue,
    new_value: core.JSValue,
) void {
    stack.values[index] = if (new_value.requiresRefCount()) new_value.dup() else new_value;
    old_value.free(rt);
}

inline fn replaceTopOwned(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    index: usize,
    old_value: core.JSValue,
    new_value: core.JSValue,
) void {
    stack.values[index] = new_value;
    old_value.free(rt);
}

fn setArrayLengthForPutFieldFastPath(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) bool {
    if (atom_id != core.atom.ids.length) return false;
    const length = value.asInt32() orelse return false;
    if (length < 0) return false;
    const object = objectFromValue(receiver) orelse return false;
    if (!object.isArray() or object.hasExoticMethods() or object.proxyTarget() != null) return false;
    if (!object.flags.length_writable) return false;
    const new_len: u32 = @intCast(length);
    if (new_len < object.arrayLength()) {
        if (object.arrayElementStorageMode() != .dense) return false;
        for (object.shapeProps()) |prop| {
            if (core.property.Flags.fromBits(prop.flags).deleted) continue;
            const index = core.array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) orelse continue;
            if (index >= new_len) return false;
        }
        object.truncateArrayElements(rt, new_len);
    }
    // Growth keeps the fast array and just extends `.length` into tail holes
    // (faithful to set_array_length quickjs.c:9447-9455 — count is unchanged,
    // no sparse conversion). This is the `arr.length = bigger` fast path.
    object.setArrayLength(new_len);
    return true;
}

fn stringFromCharCodeInt32Value(rt: *core.JSRuntime, code: i32) !core.JSValue {
    const unit: u16 = @intCast(@as(u32, @bitCast(code)) & 0xffff);
    if (unit <= 0xff) {
        const byte: u8 = @intCast(unit);
        if (try rt.singleByteString(byte)) |cached| return cached.value().dup();
        return (try core.string.String.createAscii(rt, &.{byte})).value();
    }
    return (try core.string.String.createUtf16(rt, &.{unit})).value();
}

pub noinline fn arrayElement(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !Step {
    switch (opc) {
        op.get_array_el => {
            const key = try stack.pop();
            defer key.free(ctx.runtime);
            const obj = try stack.pop();
            defer obj.free(ctx.runtime);
            if (obj.isNull() or obj.isUndefined()) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            if (string_ops.stringAtomId(key)) |atom_id| {
                // String.atom_id is a weak cache. A Proxy getter can re-enter,
                // destroy the last shape that owns this atom, and intern a new
                // key that reuses the id before invariant validation resumes.
                // Retain it across the complete (potentially re-entrant) lookup.
                const retained_atom = ctx.runtime.atoms.dup(atom_id);
                defer ctx.runtime.atoms.free(retained_atom);
                const value = object_ops.getValueProperty(ctx, output, global, obj, retained_atom, function, frame) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastTypedArrayElementValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            const atom_id = object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer ctx.runtime.atoms.free(atom_id);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.get_array_el2 => {
            const key = try stackValueFromTop(stack, 0);
            defer key.free(ctx.runtime);
            const obj = try stackValueFromTop(stack, 1);
            defer obj.free(ctx.runtime);
            if (obj.isNull() or obj.isUndefined()) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.len() - 1];
                stack.values[stack.len() - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.len() - 1];
                stack.values[stack.len() - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            if (fastTypedArrayElementValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.len() - 1];
                stack.values[stack.len() - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer key_value.free(ctx.runtime);
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(atom_id);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            const old_value = stack.values[stack.len() - 1];
            stack.values[stack.len() - 1] = value;
            old_value.free(ctx.runtime);
        },
        op.get_array_el3 => {
            const key = try stackValueFromTop(stack, 0);
            defer key.free(ctx.runtime);
            const obj = try stackValueFromTop(stack, 1);
            defer obj.free(ctx.runtime);
            if (obj.isNull() or obj.isUndefined()) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastTypedArrayElementValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            var key_value_owned = true;
            defer if (key_value_owned) key_value.free(ctx.runtime);
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(atom_id);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            const old_key = stack.values[stack.len() - 1];
            stack.values[stack.len() - 1] = key_value;
            key_value_owned = false;
            old_key.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.put_array_el => {
            const value = try stack.pop();
            defer value.free(ctx.runtime);
            const key = try stack.pop();
            defer key.free(ctx.runtime);
            const obj = try stack.pop();
            defer obj.free(ctx.runtime);
            switch (putTypedArrayElementFast(ctx.runtime, obj, key, value) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }) {
                .handled => return .continue_loop,
                .not_typed_array => {},
            }
            if (try array_ops.putDenseArrayElementFast(ctx.runtime, obj, key, value)) return .continue_loop;
            const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer key_value.free(ctx.runtime);
            // qjs JS_SetPropertyValue slow path (quickjs.c:10060) runs
            // JS_ValueToAtom on the key BEFORE JS_SetPropertyInternal's nullish
            // base TypeError, so user key-coercion side effects fire first.
            if (obj.isNull() or obj.isUndefined()) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key_value) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            if (try array_ops.putDenseArrayElementFast(ctx.runtime, obj, key_value, value)) return .continue_loop;
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(atom_id);
            const result = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            result.free(ctx.runtime);
        },
        else => unreachable,
    }
    return .done;
}

// Inline typed-array element read for `obj[int]`, mirroring qjs's
// `JS_GetPropertyValue` per-`class_id` switch (quickjs.c:9029) which reads the
// element straight from the typed storage (`int8_ptr/.../double_ptr`) after a
// single bounds check. Covers every non-BigInt element kind (Int8/Uint8/
// Uint8Clamped/Int16/Uint16/Int32/Uint32/Float16/Float32/Float64 — kinds 1..10),
// which are all allocation-free; BigInt64/BigUint64 (kinds 11/12) return null so
// the value flows through the (correct, allocating) generic path. The byte→value
// mapping is delegated to the canonical `typedArrayGetIndex` (one source of truth
// with the slow path / DataView), so no kind-specific decoder is duplicated here.
pub fn fastTypedArrayElementValue(rt: *core.JSRuntime, obj: core.JSValue, key: core.JSValue) ?core.JSValue {
    const object = objectFromValue(obj) orelse return null;
    const key_int = key.asInt32() orelse return null;
    if (key_int < 0) return null;
    // Non-BigInt, fixed-length, real typed array only. element_size==0 means the
    // object is not a typed array; kinds 11/12 are BigInt (skip — they allocate).
    const kind = object.typedArrayKind();
    if (kind < 1 or kind > 10) return null;
    const fixed_len = object.typedArrayFixedLength() orelse return null;
    const element_size = object.typedArrayElementSize();
    const buffer_value = object.typedArrayBuffer() orelse return null;
    const buffer = objectFromValue(buffer_value) orelse return null;
    if (buffer.class_id != core.class.ids.array_buffer and buffer.class_id != core.class.ids.shared_array_buffer) return null;
    if (buffer.arrayBufferDetached()) return core.JSValue.undefinedValue();

    const bytes = buffer.byteStorage();
    const byte_offset = object.typedArrayByteOffset();
    if (byte_offset > bytes.len) return core.JSValue.undefinedValue();
    const byte_len = std.math.mul(usize, @as(usize, fixed_len), @as(usize, element_size)) catch return null;
    if (byte_len > bytes.len - byte_offset) return core.JSValue.undefinedValue();
    const index: u32 = @intCast(key_int);
    if (index >= fixed_len) return core.JSValue.undefinedValue();
    // Inline the typed load using the buffer/offset/kind already resolved above,
    // mirroring qjs JS_GetPropertyValue's per-class typed arm (quickjs.c:9048-
    // 9083) which is a single bounds check + typed load off cached state. The
    // former `typedArrayGetIndex` call RE-resolved the payload, buffer, and
    // length a second time (the 2.78x-vs-qjs helper-chain redundancy). Bounds
    // are already guaranteed by the byte_len/index checks above, so for
    // kinds 1..10 (non-BigInt) readElement cannot error.
    const element_offset = byte_offset + @as(usize, index) * @as(usize, element_size);
    return core.typed_array.readElement(rt, kind, bytes[element_offset..][0..element_size]) catch null;
}

pub const TypedArrayWriteFast = enum { not_typed_array, handled };

/// qjs JS_SetPropertyValue (quickjs.c:9947) typed-array arm: a single
/// per-class_id store that, for each numeric element kind, converts the value
/// (which can run user code via valueOf/Symbol.toPrimitive and DETACH/RESIZE the
/// buffer) and stores into the typed buffer after a bounds RE-check. The
/// convert-first / recheck-after / silent-no-op-on-OOB ordering (qjs comment at
/// quickjs.c:9987 + the `ta_out_of_bound: return TRUE` leg) lives in the
/// canonical `typedArraySetElement` helper, which this fast probe delegates to as
/// the single source of truth for the value->bytes mapping.
///
/// Returns `.not_typed_array` when obj/key do not select a numeric typed-array
/// element (fall through to the dense/slow path); `.handled` when the write was
/// performed or correctly turned into a no-op (OOB / detached after conversion).
/// BigInt64/BigUint64 (kinds 11/12) punt to the slow path. A conversion that
/// throws (e.g. BigInt assigned to a non-BigInt array) surfaces as a Zig error
/// for the caller to route through handleCatchableRuntimeError.
pub fn putTypedArrayElementFast(rt: *core.JSRuntime, obj: core.JSValue, key: core.JSValue, value: core.JSValue) !TypedArrayWriteFast {
    const object = objectFromValue(obj) orelse return .not_typed_array;
    const key_int = key.asInt32() orelse return .not_typed_array;
    if (key_int < 0) return .not_typed_array;
    // A value object needs ToPrimitive (valueOf / Symbol.toPrimitive), which runs
    // user code and needs the full interpreter context (ctx/output/global) — that
    // conversion lives in the slow path's coerceTypedArrayElementForSet. The
    // canonical typedArraySetElement only coerces primitives, so an object value
    // punts to the slow path; the numeric-primitive write is the fast case.
    if (value.isObject()) return .not_typed_array;
    // A BigInt or Symbol value has a ToNumber that THROWS a TypeError, and per
    // IntegerIndexedElementSet (ToNumber at spec step 6) that throw must happen
    // BEFORE the in-bounds/immutable validity check. typedArraySetElement does the
    // validity check first (silent no-op on OOB/immutable), which would swallow the
    // throw for an out-of-bounds / immutable-buffer element — so punt these
    // throwing-conversion values to the slow path, which converts first. (Number /
    // string / boolean / null / undefined have non-throwing conversions, so the
    // validity-check-first order is observably identical for them — they stay fast.)
    if (value.isBigInt() or value.isSymbol()) return .not_typed_array;
    // Resolve the payload ONCE (was re-resolved ~5x across isTypedArrayObject +
    // typedArrayKind + typedArraySetElement's immutable/element_size/kind/
    // index-valid/buffer/byte_offset accessor calls — the write-side twin of the
    // read collapse). Same operation SEQUENCE as typedArraySetElement, which is
    // qjs-exact: immutable reject (silent no-op) -> convert into scratch FIRST
    // (number/string/bool/null/undefined values never run user code, so no
    // mid-write detach; object/BigInt/Symbol already punted above) -> re-check
    // live in-bounds/attached -> store, OOB/detached a silent no-op
    // (qjs `ta_out_of_bound: return TRUE`).
    const payload = object.typedArrayPayloadFast() orelse return .not_typed_array;
    const kind = payload.kind;
    if (kind == 11 or kind == 12) return .not_typed_array; // BigInt -> slow (JS_ToBigInt64)
    const buffer_obj = objectFromValue(payload.buffer orelse return .not_typed_array) orelse return .not_typed_array;
    if (buffer_obj.class_id != core.class.ids.array_buffer and buffer_obj.class_id != core.class.ids.shared_array_buffer) return .not_typed_array;
    if (core.object.arrayBufferIsImmutable(rt, buffer_obj)) return .handled; // silent no-op
    const width = payload.element_size;
    var scratch: [8]u8 = undefined;
    try core.typed_array.writeElement(rt, kind, scratch[0..width], value); // coerce FIRST
    const index: u32 = @intCast(key_int);
    const fixed_len = payload.fixed_length orelse {
        // Length-tracking (resizable): recompute the live length via the
        // canonical validity check, then store the already-coerced bytes.
        if (!(try core.object.typedArrayIndexValid(rt, object, index))) return .handled;
        const off = payload.byte_offset + @as(usize, index) * @as(usize, width);
        storeElementBytes(buffer_obj.byteStorage()[off..], &scratch, width);
        return .handled;
    };
    // Live validity, identical to the read leg's proven-correct check: a
    // detached buffer, or a fixed-length TA whose backing (resizable) buffer
    // shrank so the WHOLE TA no longer fits, makes every index out-of-bounds
    // (IsTypedArrayOutOfBounds) -> silent no-op, not just indices past the new
    // buffer end. `byte_len > bytes.len - byte_offset` is the whole-TA check the
    // per-element bound would have missed (test262 out-of-bounds-get-and-set).
    if (buffer_obj.arrayBufferDetached()) return .handled;
    const bytes = buffer_obj.byteStorage();
    const byte_offset = payload.byte_offset;
    if (byte_offset > bytes.len) return .handled;
    const byte_len = std.math.mul(usize, @as(usize, fixed_len), @as(usize, width)) catch return .handled;
    if (byte_len > bytes.len - byte_offset) return .handled;
    if (index >= fixed_len) return .handled;
    const off = byte_offset + @as(usize, index) * @as(usize, width);
    // Store the coerced element with a direct sized copy. `width` is a runtime
    // value (payload.element_size), so a plain @memcpy lowers to a memcpyFast
    // CALL even for a 1-byte Uint8 store — the top self-cost of typed-array-heavy
    // code (gbemu VRAM/memory writes). Switch to comptime lengths so each arm is
    // a single sized load+store. Widths are always one of {1,2,4,8}.
    storeElementBytes(bytes[off..], &scratch, width);
    return .handled;
}

/// Direct sized store of a coerced typed-array element from `scratch` into the
/// destination buffer. Comptime lengths per width so LLVM emits a plain sized
/// store instead of a runtime-length memcpyFast call.
inline fn storeElementBytes(dst: []u8, scratch: *const [8]u8, width: u32) void {
    switch (width) {
        1 => dst[0] = scratch[0],
        2 => dst[0..2].* = scratch[0..2].*,
        4 => dst[0..4].* = scratch[0..4].*,
        8 => dst[0..8].* = scratch[0..8].*,
        else => @memcpy(dst[0..width], scratch[0..width]),
    }
}

fn fastRegExpPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    if (object.class_id != core.class.ids.regexp) return null;
    const name = rt.atoms.name(atom_id) orelse return null;
    const expected_id: u32 = if (std.mem.eql(u8, name, "test"))
        @intFromEnum(method_ids.regexp.PrototypeMethod.test_)
    else if (std.mem.eql(u8, name, "exec"))
        @intFromEnum(method_ids.regexp.PrototypeMethod.exec)
    else
        return null;

    if (object.hasOwnProperty(atom_id)) return null;
    const proto = object.getPrototype() orelse return null;
    const lookup = proto.getOwnDataPropertyLookup(atom_id) orelse return null;
    const method = lookup.value;
    const function_object = objectFromValue(method) orelse {
        method.free(rt);
        return null;
    };
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse {
        method.free(rt);
        return null;
    };
    if (native_ref.domain != .regexp or native_ref.id != expected_id) {
        method.free(rt);
        return null;
    }
    return method;
}

fn fastCollectionPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    const name = rt.atoms.name(atom_id) orelse return null;
    const expected_id = core.host_function.builtin_method_id_lookup.collection.fastPrototypeMethodIdForClass(object.class_id, name) orelse return null;
    if (object.hasOwnProperty(atom_id)) return null;
    const proto = object.getPrototype() orelse return null;
    const lookup = proto.getOwnDataPropertyLookup(atom_id) orelse return null;
    const method = lookup.value;
    const function_object = objectFromValue(method) orelse {
        method.free(rt);
        return null;
    };
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse {
        method.free(rt);
        return null;
    };
    if (native_ref.domain != .collection or native_ref.id != expected_id) {
        method.free(rt);
        return null;
    }
    return method;
}

fn fastStringIndexValue(rt: *core.JSRuntime, value: core.JSValue, key: core.JSValue) ?core.JSValue {
    if (!value.isString() or !key.isInt()) return null;
    const index_i32 = key.asInt32().?;
    if (index_i32 < 0) return null;
    const index: usize = @intCast(index_i32);
    if (index >= core.string.stringValueLenUnchecked(value)) return null;
    const unit = core.string.stringValueCodeUnitAtUnchecked(value, index);
    if (unit <= 0x7f) {
        const cached = rt.cachedSingleByteString(@intCast(unit)) orelse return null;
        return cached.value().dup();
    }
    return null;
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.len()) return error.StackUnderflow;
    return stack.values[stack.len() - 1 - index_from_top].dup();
}
