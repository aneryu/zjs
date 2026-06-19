//! Property field and array-element opcode handlers (get/put_field, get/put_array_el, in/instanceof, to_prop_key).

const fusion_stats = @import("vm_fusion_stats.zig");
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
const InductionImmediateInt32Args = property_vm.InductionImmediateInt32Args;
const LoopLimitGet = property_vm.LoopLimitGet;
const Step = property_vm.Step;
const atomAsciiText = property_vm.atomAsciiText;
const atomStringValueForFastPath = property_vm.atomStringValueForFastPath;
const bindingReadableBorrowed = property_vm.bindingReadableBorrowed;
const bindingStoreWritableForFastPath = property_vm.bindingStoreWritableForFastPath;
const borrowedSimpleCallArg = property_vm.borrowedSimpleCallArg;
const decodeBindingGet = property_vm.decodeBindingGet;
const decodeBindingPut = property_vm.decodeBindingPut;
const decodeFalseBranch = property_vm.decodeFalseBranch;
const decodeGlobalPut = property_vm.decodeGlobalPut;
const decodeGotoTarget = property_vm.decodeGotoTarget;
const decodeLocalGet = property_vm.decodeLocalGet;
const decodeLocalPut = property_vm.decodeLocalPut;
const decodeLoopLimitGet = property_vm.decodeLoopLimitGet;
const decodeOptionalLocalCompletionTail = property_vm.decodeOptionalLocalCompletionTail;
const decodeStringSliceConstLocalStore = property_vm.decodeStringSliceConstLocalStore;
const fastArrayPrototypeMethodIsDefault = property_vm.fastArrayPrototypeMethodIsDefault;
const fastDenseArrayElementValue = property_vm.fastDenseArrayElementValue;
const fastRegExpPrototypeMethodIsDefault = property_vm.fastRegExpPrototypeMethodIsDefault;
const finishUndefinedCallResult = property_vm.finishUndefinedCallResult;
const frameHasVarRefBinding = property_vm.frameHasVarRefBinding;
const immediateInt32Operand = property_vm.immediateInt32Operand;
const isHostOutputFunctionValue = property_vm.isHostOutputFunctionValue;
const loopLimitReadableInt32 = property_vm.loopLimitReadableInt32;
const mathMinMaxInductionRangeSum = property_vm.mathMinMaxInductionRangeSum;
const mathMinMaxPrimitive2 = property_vm.mathMinMaxPrimitive2;
const sameBinding = property_vm.sameBinding;
const simpleNumericBinary = property_vm.simpleNumericBinary;
const slotValueBorrowed = property_vm.slotValueBorrowed;
const storeBindingOwnedValue = property_vm.storeBindingOwnedValue;
const storeLocalCompletionBorrowedValue = property_vm.storeLocalCompletionBorrowedValue;
const storeStringSliceConstLocal = property_vm.storeStringSliceConstLocal;
const stringFromCharCodeInt32Arg = property_vm.stringFromCharCodeInt32Arg;
const varRefReadableBorrowed = property_vm.varRefReadableBorrowed;

const functionOwnDataPropertyValueForFastPath = property_ic.functionOwnDataPropertyValueForFastPath;
const functionOwnNativeBuiltinRefForFastPath = property_ic.functionOwnNativeBuiltinRefForFastPath;
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

fn decodeRegExpMatchGet(code: []const u8, pc: usize) ?RegExpMatchGet {
    if (decodeBindingGet(code, pc)) |get| return .{ .binding = get };
    if (pc + 5 <= code.len and (code[pc] == op.get_var or code[pc] == op.get_var_undef)) {
        return .{ .global = .{
            .atom = readInt(u32, code[pc + 1 ..][0..4]),
            .next_pc = pc + 5,
        } };
    }
    return null;
}

fn decodeRegExpMatchPut(code: []const u8, pc: usize) ?RegExpMatchPut {
    if (decodeBindingPut(code, pc)) |put| return .{ .binding = put };
    if (decodeGlobalPut(code, pc)) |put| return .{ .global = put };
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

pub fn toPropKeyVm(
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

pub fn toPropKey2(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    if (stack.values.len < 2) return error.StackUnderflow;
    const receiver = stack.values[stack.values.len - 2];
    if (receiver.isUndefined() or receiver.isNull()) return error.TypeError;

    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const key = try object_ops.toPropertyKeyValue(ctx, output, global, value, function, frame);
    errdefer key.free(ctx.runtime);
    try stack.pushOwned(key);
}

pub fn toPropKey2Vm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    toPropKey2(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn setName(
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

pub fn inOrInstanceof(
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

pub fn field(
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
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    switch (opc) {
        op.get_field => {
            if (stack.values.len == 0) return error.StackUnderflow;
            const top_index = stack.values.len - 1;
            const receiver = stack.values[top_index];
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
            const site_pc = frame.pc - 5;
            const obj = try stackValueFromTop(stack, 0);
            defer obj.free(ctx.runtime);
            if (fusion_stats.fusions_enabled and fusion_stats.counted(.tryFuseRegExpTestConstStringFromField2, try tryFuseRegExpTestConstStringFromField2(ctx, function, frame, stack, obj, atom_id))) return .done;
            if (fusion_stats.fusions_enabled and fusion_stats.counted(.tryFuseNumberStaticLiteralCallFromField2, try tryFuseNumberStaticLiteralCallFromField2(ctx, output, function, frame, stack, obj, atom_id, site_pc))) return .done;
            if (fusion_stats.fusions_enabled and fusion_stats.counted(.tryFuseMathMinMaxPrimitiveCallFromField2, try tryFuseMathMinMaxPrimitiveCallFromField2(ctx, function, frame, stack, obj, atom_id))) return .done;
            if (fusion_stats.fusions_enabled and fusion_stats.counted(.tryFuseStringFromCharCodeInt32CallFromField2, try tryFuseStringFromCharCodeInt32CallFromField2(ctx, function, frame, stack, obj, atom_id, site_pc))) return .done;
            if (fusion_stats.fusions_enabled and fusion_stats.counted(.tryFuseStringSliceConstLocalStoreFromField2, try tryFuseStringSliceConstLocalStoreFromField2(ctx, function, global, frame, stack, obj, atom_id, sync_global_lexical_locals))) return .done;
            if (fusion_stats.fusions_enabled and fusion_stats.counted(.tryFuseArrayPushCallFromField2, try tryFuseArrayPushCallFromField2(ctx, function, global, frame, stack, obj, atom_id, sync_global_lexical_locals))) return .done;
            if (qjsGetFieldFast(ctx.runtime, obj, atom_id)) |value| {
                try stack.push(value);
                return .done;
            }
            if (ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, obj, atom_id)) |value| {
                try stack.push(value);
                return .done;
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (functionOwnDataPropertyValueForFastPath(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastCollectionPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
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
            defer value.free(ctx.runtime);
            const obj = try stack.pop();
            defer obj.free(ctx.runtime);
            if (setArrayLengthForPutFieldFastPath(ctx.runtime, obj, atom_id, value)) return .done;
            if (qjsPutFieldFast(ctx.runtime, obj, atom_id, value)) return .done;
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

fn qjsGetFieldFast(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    if (rt.atoms.kind(atom_id) == .private) return null;
    var object = objectFromValue(receiver) orelse return null;
    while (true) {
        if (qjsFieldObjectNeedsSlow(rt, object, atom_id)) return null;
        if (object.findProperty(atom_id)) |index| {
            if (object.propFlagsAt(index).accessor) return null;
            return switch (object.properties[index].slot) {
                .data => |stored| stored,
                .auto_init, .accessor, .deleted => null,
            };
        }
        object = object.getPrototype() orelse return core.JSValue.undefinedValue();
    }
}

fn qjsPutFieldFast(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, value: core.JSValue) bool {
    if (rt.atoms.kind(atom_id) == .private) return false;
    const object = objectFromValue(receiver) orelse return false;
    if (qjsPutFieldObjectNeedsSlow(object, atom_id)) return false;
    const index = object.findProperty(atom_id) orelse return false;
    const flags = object.propFlagsAt(index);
    if (!flags.writable or flags.accessor) return false;
    const entry = &object.properties[index];
    switch (entry.slot) {
        .data => |old_value| {
            const next_value = core.object.dupPropertyDataValue(&rt.atoms, atom_id, value);
            entry.slot = .{ .data = next_value };
            core.object.destroyPropertySlot(rt, atom_id, .{ .data = old_value });
            object.pruneBorrowedReferenceHolderIfEmpty(rt);
            return true;
        },
        .auto_init, .accessor, .deleted => return false,
    }
}

fn qjsFieldObjectNeedsSlow(rt: *core.JSRuntime, object: *const core.Object, atom_id: core.Atom) bool {
    if (object.flags.is_proxy or object.proxyTarget() != null or object.exotic != null) return true;
    if (object.flags.is_array and (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null)) return true;
    if (core.object.isTypedArrayObject(object)) return true;
    if (object.class_id == core.class.ids.regexp and atom_id == core.atom.ids.lastIndex and object.regexpLastIndex() != null) return true;
    if (object.class_id == core.class.ids.module_ns or object.class_id == core.class.ids.mapped_arguments) return true;
    return false;
}

fn qjsPutFieldObjectNeedsSlow(object: *const core.Object, atom_id: core.Atom) bool {
    if (object.flags.is_proxy or object.proxyTarget() != null or object.exotic != null) return true;
    if (object.flags.is_array) return true;
    if (core.object.isTypedArrayObject(object)) return true;
    if (object.class_id == core.class.ids.regexp and atom_id == core.atom.ids.lastIndex and object.regexpLastIndex() != null) return true;
    if (object.class_id == core.class.ids.module_ns or object.class_id == core.class.ids.mapped_arguments) return true;
    return false;
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
    if (!object.flags.is_array or object.exotic != null or object.proxyTarget() != null) return false;
    if (!object.flags.length_writable) return false;
    const new_len: u32 = @intCast(length);
    if (new_len < object.length) {
        if (object.arrayElementStorageMode() != .dense) return false;
        for (object.shapeProps()) |prop| {
            if (core.property.Flags.fromBits(prop.flags).deleted) continue;
            const index = core.array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) orelse continue;
            if (index >= new_len) return false;
        }
        object.truncateArrayElements(rt, new_len);
    }
    object.length = new_len;
    return true;
}

fn tryFuseMathMinMaxPrimitiveCallFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
) !bool {
    const method = ownDataPropertyValueMaterializedForFastPath(ctx.runtime, receiver, atom_id) orelse return false;
    const method_object = objectFromValue(method) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(method_object.nativeFunctionIdSlot().*) orelse return false;
    if (native_ref.domain != .math) return false;
    const is_max = switch (native_ref.id) {
        7 => false,
        8 => true,
        else => return false,
    };

    const arg0 = borrowedSimpleCallArg(frame, function, frame.pc) orelse return false;
    const arg1 = borrowedSimpleCallArg(frame, function, arg0.next_pc) orelse return false;
    const code = function.code;
    if (arg1.next_pc + 3 > code.len or code[arg1.next_pc] != op.call_method) return false;
    if (readInt(u16, code[arg1.next_pc + 1 ..][0..2]) != 2) return false;

    const result_number = mathMinMaxPrimitive2(arg0.value, arg1.value, is_max) orelse return false;
    const dropped_receiver = try stack.pop();
    dropped_receiver.free(ctx.runtime);
    const result = value_ops.numberToValue(result_number);
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    frame.pc = arg1.next_pc + 3;
    return true;
}

fn tryFuseStringFromCharCodeInt32CallFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
    site_pc: usize,
) !bool {
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, site_pc, ctx.runtime, receiver, atom_id) orelse return false;
    if (native_ref.domain != .string or native_ref.id != @intFromEnum(method_ids.string.StaticMethod.from_char_code)) return false;

    const argument = stringFromCharCodeInt32Arg(function, frame, frame.pc) orelse return false;
    const code = function.code;
    if (argument.next_pc + 3 > code.len or code[argument.next_pc] != op.call_method) return false;
    if (readInt(u16, code[argument.next_pc + 1 ..][0..2]) != 1) return false;

    const dropped_receiver = try stack.pop();
    dropped_receiver.free(ctx.runtime);
    const result = try stringFromCharCodeInt32Value(ctx.runtime, argument.value);
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    frame.pc = argument.next_pc + 3;
    return true;
}

fn tryFuseStringSliceConstLocalStoreFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
    sync_global_lexical_locals: bool,
) !bool {
    const decoded = decodeStringSliceConstLocalStore(ctx, function, global, frame, receiver, atom_id, frame.pc) orelse return false;
    if (stack.values.len == 0) return false;
    try storeStringSliceConstLocal(ctx, function, global, frame, receiver, decoded, sync_global_lexical_locals);
    const receiver_owned = try stack.pop();
    receiver_owned.free(ctx.runtime);
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

fn tryFuseNumberStaticLiteralCallFromField2(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
    site_pc: usize,
) !bool {
    const pc = frame.pc;
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, site_pc, ctx.runtime, receiver, atom_id) orelse return false;
    if (native_ref.domain != .number) return false;

    const code = function.code;
    const number_static = method_ids.number.StaticMethod;
    const number_parse = core.number;
    var call_end_pc: usize = undefined;
    const result_number = switch (native_ref.id) {
        @intFromEnum(number_static.parse_int) => blk: {
            if (pc + 5 > code.len or code[pc] != op.push_atom_value) return false;
            const string_atom = readInt(u32, code[pc + 1 ..][0..4]);
            var atom_buf: [10]u8 = undefined;
            const text = atomAsciiText(ctx.runtime, string_atom, &atom_buf) orelse return false;
            const radix_operand = immediateInt32Operand(code, pc + 5) orelse return false;
            if (radix_operand.next_pc + 3 > code.len or code[radix_operand.next_pc] != op.call_method) return false;
            if (readInt(u16, code[radix_operand.next_pc + 1 ..][0..2]) != 2) return false;
            call_end_pc = radix_operand.next_pc + 3;
            break :blk number_parse.parseIntLatin1Bytes(text, radix_operand.value);
        },
        @intFromEnum(number_static.parse_float) => blk: {
            if (pc + 8 > code.len or code[pc] != op.push_atom_value) return false;
            const string_atom = readInt(u32, code[pc + 1 ..][0..4]);
            var atom_buf: [10]u8 = undefined;
            const text = atomAsciiText(ctx.runtime, string_atom, &atom_buf) orelse return false;
            const call_pc = pc + 5;
            if (code[call_pc] != op.call_method) return false;
            if (readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return false;
            call_end_pc = call_pc + 3;
            break :blk number_parse.parseFloatLatin1Bytes(text);
        },
        else => return false,
    };

    const dropped_receiver = try stack.pop();
    dropped_receiver.free(ctx.runtime);
    const result = value_ops.numberToValue(result_number);
    errdefer result.free(ctx.runtime);
    if (call_end_pc < code.len and code[call_end_pc] == op.call1 and stack.values.len >= 1) {
        const outer_callee = try stackValueFromTop(stack, 0);
        defer outer_callee.free(ctx.runtime);
        if (isHostOutputFunctionValue(ctx.runtime, outer_callee)) {
            const dropped_callee = try stack.pop();
            dropped_callee.free(ctx.runtime);
            defer result.free(ctx.runtime);
            try builtin_glue.printHostOutputArgs(ctx.runtime, output, &.{result});
            try finishUndefinedCallResult(stack, function, frame, call_end_pc + 1);
            return true;
        }
    }
    try stack.pushOwned(result);
    frame.pc = call_end_pc;
    return true;
}

pub fn arrayElement(
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
            if (fastInt32TypedArrayElementValue(obj, key)) |value| {
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
            if (fastInt32TypedArrayElementValue(obj, key)) |value| {
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
            if (try putInt32TypedArrayElementFast(ctx.runtime, obj, key, value)) return .continue_loop;
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

fn fastInt32TypedArrayElementValue(obj: core.JSValue, key: core.JSValue) ?core.JSValue {
    const object = objectFromValue(obj) orelse return null;
    const key_int = key.asInt32() orelse return null;
    if (key_int < 0) return null;
    if (object.typedArrayKind() != 6 or object.typedArrayElementSize() != 4) return null;
    const fixed_len = object.typedArrayFixedLength() orelse return null;
    const buffer_value = object.typedArrayBuffer() orelse return null;
    const buffer = objectFromValue(buffer_value) orelse return null;
    if (buffer.class_id != core.class.ids.array_buffer and buffer.class_id != core.class.ids.shared_array_buffer) return null;
    if (buffer.arrayBufferDetached()) return core.JSValue.undefinedValue();

    const bytes = buffer.byteStorage();
    const byte_offset = object.typedArrayByteOffset();
    if (byte_offset > bytes.len) return core.JSValue.undefinedValue();
    const byte_len = std.math.mul(usize, @as(usize, fixed_len), @as(usize, 4)) catch return null;
    if (byte_len > bytes.len - byte_offset) return core.JSValue.undefinedValue();
    const index: u32 = @intCast(key_int);
    if (index >= fixed_len) return core.JSValue.undefinedValue();
    const offset = byte_offset + @as(usize, index) * 4;
    return core.JSValue.int32(std.mem.readInt(i32, bytes[offset..][0..4], .little));
}

fn putInt32TypedArrayElementFast(rt: *core.JSRuntime, obj: core.JSValue, key: core.JSValue, value: core.JSValue) !bool {
    _ = rt;
    const object = objectFromValue(obj) orelse return false;
    const key_int = key.asInt32() orelse return false;
    if (key_int < 0) return false;
    const value_int = value.asInt32() orelse return false;
    if (object.typedArrayKind() != 6 or object.typedArrayElementSize() != 4) return false;
    const fixed_len = object.typedArrayFixedLength() orelse return false;
    const buffer_value = object.typedArrayBuffer() orelse return false;
    const buffer = objectFromValue(buffer_value) orelse return false;
    if (buffer.class_id != core.class.ids.array_buffer and buffer.class_id != core.class.ids.shared_array_buffer) return false;
    if (buffer.arrayBufferImmutable()) return false;
    if (buffer.arrayBufferDetached()) return true;

    const bytes = buffer.byteStorage();
    const byte_offset = object.typedArrayByteOffset();
    if (byte_offset > bytes.len) return true;
    const byte_len = std.math.mul(usize, @as(usize, fixed_len), @as(usize, 4)) catch return false;
    if (byte_len > bytes.len - byte_offset) return true;
    const index: u32 = @intCast(key_int);
    if (index >= fixed_len) return true;
    const offset = byte_offset + @as(usize, index) * 4;
    std.mem.writeInt(i32, bytes[offset..][0..4], value_int, .little);
    return true;
}

fn tryFuseRegExpTestConstStringFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    method_atom: core.Atom,
) !bool {
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "test")) return false;
    const code = function.code;
    const pc = frame.pc;
    if (pc + 8 > code.len) return false;
    if (code[pc] != op.push_atom_value) return false;
    const input_atom = readInt(u32, code[pc + 1 ..][0..4]);
    if (code[pc + 5] != op.call_method or readInt(u16, code[pc + 6 ..][0..2]) != 1) return false;

    const regexp_object = objectFromValue(receiver) orelse return false;
    if (regexp_object.class_id != core.class.ids.regexp) return false;
    if (!fastRegExpPrototypeMethodIsDefault(ctx.runtime, receiver, method_atom, @intFromEnum(method_ids.regexp.PrototypeMethod.test_))) return false;

    const input_value = (try atomStringValueForFastPath(ctx.runtime, input_atom)) orelse return false;
    defer input_value.free(ctx.runtime);
    const matched = try regexp_fastpath.qjsRegExpTestFastNoResult(ctx, regexp_object, input_value) orelse return false;

    const stacked_receiver = try stack.pop();
    stacked_receiver.free(ctx.runtime);
    const next_pc = pc + 8;
    try stack.pushOwned(core.JSValue.boolean(matched));
    frame.pc = next_pc;
    return true;
}

fn tryFuseArrayPushCallFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    method_atom: core.Atom,
    sync_global_lexical_locals: bool,
) !bool {
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "push")) return false;
    if (!fastArrayPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(method_ids.array.PrototypeMethod.push))) return false;

    const object = objectFromValue(receiver) orelse return false;
    if (object.proxyTarget() != null or object.exotic != null) return false;
    if (object.length >= core.array.max_array_length) return false;

    const code = function.code;
    const call_arg = borrowedSimpleCallArg(frame, function, frame.pc) orelse return false;
    const call_pc = call_arg.next_pc;
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method) return false;
    if (readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return false;

    const index = object.length;
    if (!try object.appendDenseArrayIndex(ctx.runtime, index, core.atom.atomFromUInt32(index), call_arg.value)) return false;
    const result = array_ops.lengthIndexValue(index + 1);

    const stacked_receiver = try stack.pop();
    stacked_receiver.free(ctx.runtime);

    const after_call_pc = call_pc + 3;
    if (decodeOptionalLocalCompletionTail(function, frame, after_call_pc)) |completion_tail| {
        try storeLocalCompletionBorrowedValue(ctx, function, global, frame, completion_tail.completion_put, result, sync_global_lexical_locals);
        frame.pc = completion_tail.tail_pc;
        return true;
    }

    try stack.pushOwned(result);
    frame.pc = after_call_pc;
    return true;
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
    const header = value.refHeader() orelse return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
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
