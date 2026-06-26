//! Property field and array-element opcode handlers (get/put_field, get/put_array_el, in/instanceof, to_prop_key).

const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
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

fn decodeRegExpMatchGet(function: *const bytecode.Bytecode, pc: usize) ?RegExpMatchGet {
    const code = function.code;
    if (decodeBindingGet(code, pc)) |get| return .{ .binding = get };
    if (decodeGlobalDataGet(function, pc)) |get| return .{ .global = get };
    return null;
}

fn decodeRegExpMatchPut(function: *const bytecode.Bytecode, pc: usize) ?RegExpMatchPut {
    const code = function.code;
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
    function: *const bytecode.Bytecode,
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
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    toPropKey(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn setName(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    opc: u8,
) !void {
    switch (opc) {
        op.set_name => {
            const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
            frame.pc += 4;
            if (stack.values.len == 0) return error.StackUnderflow;
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
            if (stack.values.len < 2) return error.StackUnderflow;
            const value = stack.values[stack.values.len - 1].dup();
            defer value.free(ctx.runtime);
            const key = stack.values[stack.values.len - 2].dup();
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
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !Step {
    const err = if (opc == op.in)
        call_runtime.inOp(ctx, stack, output, global, function, frame)
    else
        call_runtime.instanceofOp(ctx, stack, output, global, function, frame);
    err catch |runtime_err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, runtime_err)) return .continue_loop;
        return runtime_err;
    };
    return .done;
}

pub noinline fn field(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    sync_global_lexical_locals: bool,
) !Step {
    _ = sync_global_lexical_locals;
    const site_pc = frame.pc - 1;
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    switch (opc) {
        op.get_field => {
            if (stack.values.len == 0) return error.StackUnderflow;
            const top_index = stack.values.len - 1;
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
            stack.values = stack.values.ptr[0..top_index];
            const obj = receiver;
            defer obj.free(ctx.runtime);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                try forof_ops.closeStackTopForOfIteratorForPendingErrorWithFrame(ctx, output, global, stack, frame);
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            result.free(ctx.runtime);
        },
        else => unreachable,
    }
    return .done;
}

pub inline fn qjsGetFieldFast(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    if (rt.atoms.mightBePrivate(atom_id)) return null;
    var object = objectFromValue(receiver) orelse return null;
    while (true) {
        if (object.needsSlowPropertyAccess()) return null;
        switch (object.findOwnDataPropertyFast(atom_id)) {
            .value => |lookup| return lookup.value,
            .slow => return null,
            .missing => {},
        }
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

pub inline fn qjsPutFieldFast(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, value: core.JSValue) bool {
    if (rt.atoms.mightBePrivate(atom_id)) return false;
    const object = objectFromValue(receiver) orelse return false;
    if (object.needsSlowPropertyAccess()) return false;
    const lookup = object.findWritableOwnDataPropertyFast(atom_id) orelse return false;
    const old_value = lookup.value.*;
    lookup.value.* = value;
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
    if (!object.flags.is_array or object.hasExoticMethods() or object.proxyTarget() != null) return false;
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
    function: *const bytecode.Bytecode,
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
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
            const atom_id = object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer ctx.runtime.atoms.free(atom_id);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.values.len - 1];
                stack.values[stack.values.len - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.values.len - 1];
                stack.values[stack.values.len - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            if (fastTypedArrayElementValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.values.len - 1];
                stack.values[stack.values.len - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer key_value.free(ctx.runtime);
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(atom_id);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            const old_value = stack.values[stack.values.len - 1];
            stack.values[stack.values.len - 1] = value;
            old_value.free(ctx.runtime);
        },
        op.get_array_el3 => {
            const key = try stackValueFromTop(stack, 0);
            defer key.free(ctx.runtime);
            const obj = try stackValueFromTop(stack, 1);
            defer obj.free(ctx.runtime);
            if (obj.isNull() or obj.isUndefined()) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            var key_value_owned = true;
            defer if (key_value_owned) key_value.free(ctx.runtime);
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(atom_id);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            const old_key = stack.values[stack.values.len - 1];
            stack.values[stack.values.len - 1] = key_value;
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
            if (obj.isNull() or obj.isUndefined()) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            switch (putTypedArrayElementFast(ctx.runtime, obj, key, value) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }) {
                .handled => return .continue_loop,
                .not_typed_array => {},
            }
            if (try array_ops.putDenseArrayElementFast(ctx.runtime, obj, key, value)) return .continue_loop;
            const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer key_value.free(ctx.runtime);
            if (try array_ops.putDenseArrayElementFast(ctx.runtime, obj, key_value, value)) return .continue_loop;
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(atom_id);
            const result = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
    // All bounds/detach/length conditions above match typedArrayGetIndex's own
    // gating, so for kinds 1..10 it cannot error here (no allocation) — but route
    // any unexpected error to the slow path rather than swallowing it.
    return core.typed_array.typedArrayGetIndex(rt, object, index) catch null;
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
    if (!core.object.isTypedArrayObject(object)) return .not_typed_array;
    const kind = object.typedArrayKind();
    // BigInt64/BigUint64 punt to the slow path (it converts via JS_ToBigInt64).
    if (kind == 11 or kind == 12) return .not_typed_array;
    const index: u32 = @intCast(key_int);
    // typedArraySetElement mirrors qjs exactly: immutable reject (silent no-op),
    // convert into a scratch buffer FIRST (user code may detach/resize), then
    // re-check the in-bounds/attached state and store. OOB after conversion is a
    // silent no-op (qjs `ta_out_of_bound: return TRUE`), not a throw.
    _ = try core.typed_array.typedArraySetElement(rt, object, index, value);
    return .handled;
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
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse {
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
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse {
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
    const string_value = value.asStringBody() orelse return null;
    const index: usize = @intCast(index_i32);
    if (index >= string_value.len()) return null;
    const unit = string_value.codeUnitAt(index);
    if (unit <= 0x7f) {
        const cached = rt.cachedSingleByteString(@intCast(unit)) orelse return null;
        return cached.value().dup();
    }
    return null;
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.values.len) return error.StackUnderflow;
    return stack.values[stack.values.len - 1 - index_from_top].dup();
}
