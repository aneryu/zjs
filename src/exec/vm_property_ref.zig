//! With-statement and reference opcode handlers (make_ref/get_ref_value/put_ref_value/with_*).

const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ic = @import("property_ic.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");

const shared_vm = @import("shared.zig");
const readInt = shared_vm.readInt;
const varRefCellFromValue = shared_vm.varRefCellFromValue;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const property_vm = @import("vm_property.zig");
const Step = property_vm.Step;
const decodeGlobalDataGet = property_vm.decodeGlobalDataGet;
const decodeVarRefGet = property_vm.decodeVarRefGet;
const frameHasVarRefBinding = property_vm.frameHasVarRefBinding;
const hasObjectBinding = property_vm.hasObjectBinding;
const simpleStringCallableKind = property_vm.simpleStringCallableKind;
const stringFromValue = property_vm.stringFromValue;
const varRefReadableBorrowed = property_vm.varRefReadableBorrowed;

const globalDataPropertyValueForFastPath = property_ic.globalDataPropertyValueForFastPath;
const globalWritableDataStoreAvailableForFastPath = property_ic.globalWritableDataStoreAvailableForFastPath;
const setGlobalWritableDataStoreForFastPathOwned = property_ic.setGlobalWritableDataStoreForFastPathOwned;

const op = bytecode.opcode.op;

pub fn withGetOrDelete(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    comptime hasPropertyForWith: anytype,
    comptime isBlockedByUnscopables: anytype,
    comptime getValueProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const diff = readInt(i32, function.code[frame.pc + 4 ..][0..4]);
    const operand_pc = frame.pc;
    frame.pc += 9;
    const obj_value = stack.peek() orelse return error.StackUnderflow;
    defer obj_value.free(ctx.runtime);
    const object = property_ops.expectObject(obj_value) catch {
        const dropped = try stack.pop();
        dropped.free(ctx.runtime);
        return .continue_loop;
    };
    const has_binding = hasPropertyForWith(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const blocked = if (has_binding)
        isBlockedByUnscopables(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        }
    else
        false;
    if (!has_binding or blocked) {
        const dropped = try stack.pop();
        dropped.free(ctx.runtime);
        return .continue_loop;
    }
    const still_has_binding = if (opc == op.with_make_ref)
        true
    else
        hasPropertyForWith(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    if (opc == op.with_get_var and !still_has_binding) {
        const dropped = try stack.pop();
        dropped.free(ctx.runtime);
        if (function.flags.is_strict) {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        }
        try stack.pushOwned(core.JSValue.undefinedValue());
        frame.pc = @intCast(@as(i64, @intCast(operand_pc + 4)) + diff);
        return .continue_loop;
    }
    switch (opc) {
        op.with_get_var => {
            const value = try getValueProperty(ctx, output, global, obj_value, atom_id, function, frame);
            errdefer value.free(ctx.runtime);
            const dropped = try stack.pop();
            dropped.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.with_delete_var => {
            const deleted = object.deleteProperty(ctx.runtime, atom_id);
            if (!deleted and function.flags.is_strict) {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                return error.TypeError;
            }
            const dropped = try stack.pop();
            dropped.free(ctx.runtime);
            try stack.pushOwned(core.JSValue.boolean(deleted));
        },
        op.with_get_ref => {
            const value = try getValueProperty(ctx, output, global, obj_value, atom_id, function, frame);
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.with_get_ref_undef => {
            const value = try getValueProperty(ctx, output, global, obj_value, atom_id, function, frame);
            var value_owned = true;
            errdefer if (value_owned) value.free(ctx.runtime);
            try stack.reserveAdditional(1);
            const dropped = try stack.pop();
            dropped.free(ctx.runtime);
            stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
            stack.pushOwnedAssumeCapacity(value);
            value_owned = false;
        },
        op.with_make_ref => {
            const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
            errdefer key_value.free(ctx.runtime);
            try stack.pushOwned(key_value);
        },
        else => unreachable,
    }
    frame.pc = @intCast(@as(i64, @intCast(operand_pc + 4)) + diff);
    return .done;
}

pub fn makeSlotRef(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    opc: u8,
    comptime ensureVarRefsCapacity: anytype,
    comptime ensureVarRefCell: anytype,
    comptime ensureLocalVarRefCell: anytype,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const idx = readInt(u16, function.code[frame.pc + 4 ..][0..2]);
    frame.pc += 6;

    const ref_value = switch (opc) {
        op.make_loc_ref => blk: {
            if (idx >= frame.locals.len) return error.InvalidBytecode;
            const is_lexical = idx < function.var_is_lexical.len and function.var_is_lexical[idx];
            break :blk try ensureLocalVarRefCell(ctx, frame, idx, is_lexical);
        },
        op.make_arg_ref => blk: {
            if (idx >= frame.args.len) return error.InvalidBytecode;
            break :blk try ensureVarRefCell(ctx, &frame.args[idx]);
        },
        op.make_var_ref_ref => blk: {
            try ensureVarRefsCapacity(ctx, frame, idx);
            break :blk try ensureVarRefCell(ctx, &frame.var_refs[idx]);
        },
        else => unreachable,
    };
    defer ref_value.free(ctx.runtime);
    const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
    errdefer key_value.free(ctx.runtime);
    try stack.push(ref_value);
    try stack.pushOwned(key_value);
}

pub fn makeVarRef(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    if (try makeEvalBindingRef(ctx, eval_local_names, eval_local_slots, atom_id)) |ref_value| {
        defer ref_value.free(ctx.runtime);
        const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
        errdefer key_value.free(ctx.runtime);
        try stack.push(ref_value);
        try stack.pushOwned(key_value);
        return;
    }
    if (!frame.eval_var_refs_republished) {
        if (makeEvalVarRef(ctx.runtime, eval_var_ref_names, eval_var_refs, atom_id)) |ref_value| {
            defer ref_value.free(ctx.runtime);
            const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
            errdefer key_value.free(ctx.runtime);
            try stack.push(ref_value);
            try stack.pushOwned(key_value);
            return;
        }
    }
    if (try makeEvalBindingRef(ctx, frame.eval_local_names, frame.eval_local_slots, atom_id)) |ref_value| {
        defer ref_value.free(ctx.runtime);
        const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
        errdefer key_value.free(ctx.runtime);
        try stack.push(ref_value);
        try stack.pushOwned(key_value);
        return;
    }
    if (makeEvalVarRef(ctx.runtime, frame.eval_var_ref_names, frame.eval_var_refs, atom_id)) |ref_value| {
        defer ref_value.free(ctx.runtime);
        const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
        errdefer key_value.free(ctx.runtime);
        try stack.push(ref_value);
        try stack.pushOwned(key_value);
        return;
    }
    const global_value = global.value();
    const has_global_binding = try hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame);
    const object_value = if (shared_vm.existingGlobalLexicalEnv(ctx)) |env|
        if (env.hasOwnProperty(atom_id))
            env.value()
        else if (has_global_binding)
            global_value
        else
            core.JSValue.undefinedValue()
    else if (has_global_binding)
        global_value
    else
        core.JSValue.undefinedValue();
    const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    try stack.push(object_value);
    try stack.push(key_value);
}

pub fn makeVarRefVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    if (try tryFuseMakeVarRefPercentHexGlobalStringAssignment(ctx, global, function, frame, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs)) return .continue_loop;
    makeVarRef(ctx, output, global, stack, function, frame, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn tryFuseMakeVarRefPercentHexGlobalStringAssignment(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !bool {
    _ = eval_local_slots;
    _ = eval_var_refs;
    const code = function.code;
    if (frame.pc == 0 or frame.pc + 4 > code.len) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;

    const store_atom = readInt(u32, code[frame.pc..][0..4]);
    const store_site_pc = frame.pc - 1;
    const lhs_pc = frame.pc + 4;
    if (!globalReferenceAtomCanUseFastData(ctx, function, global, frame, store_atom)) return false;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, store_site_pc, store_atom)) return false;

    const lhs_get = decodeGlobalDataGet(code, lhs_pc) orelse return false;
    if (!globalReferenceAtomCanUseFastData(ctx, function, global, frame, lhs_get.atom)) return false;
    const lhs = globalDataPropertyValueForFastPath(ctx.runtime, global, function, lhs_pc, lhs_get.atom) orelse return false;
    const lhs_string = stringFromValue(lhs) orelse return false;
    if (lhs_string.isRope()) return false;
    const lhs_bytes = lhs_string.borrowLatin1() orelse return false;

    const callee_get = decodeVarRefGet(code, lhs_get.next_pc) orelse return false;
    const callee = varRefReadableBorrowed(frame, callee_get.idx) orelse return false;
    if (simpleStringCallableKind(callee) != .percent_hex_byte) return false;

    const arg_get = decodeGlobalDataGet(code, callee_get.next_pc) orelse return false;
    if (!globalReferenceAtomCanUseFastData(ctx, function, global, frame, arg_get.atom)) return false;
    const arg_value = globalDataPropertyValueForFastPath(ctx.runtime, global, function, callee_get.next_pc, arg_get.atom) orelse return false;
    const arg_i32 = arg_value.asInt32() orelse return false;

    const call_pc = arg_get.next_pc;
    if (call_pc + 3 > code.len or code[call_pc] != op.call1 or code[call_pc + 1] != op.add or code[call_pc + 2] != op.put_ref_value) return false;

    const suffix_string = try ctx.runtime.percentHexString(@truncate(@as(u32, @bitCast(arg_i32))));
    const suffix_bytes = suffix_string.borrowLatin1() orelse return false;
    const updated_string = try core.string.String.createLatin1Concat(ctx.runtime, lhs_bytes, suffix_bytes);
    var updated_owned = true;
    errdefer if (updated_owned) updated_string.value().free(ctx.runtime);
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, store_site_pc, store_atom, updated_string.value())) {
        updated_string.value().free(ctx.runtime);
        return false;
    }
    updated_owned = false;

    frame.pc = call_pc + 3;
    return true;
}

fn globalReferenceAtomCanUseFastData(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *const frame_mod.Frame,
    atom_id: core.Atom,
) bool {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (!frame.current_function.isUndefined()) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
    _ = global;
    if (ctx.lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return false;
    }
    return true;
}

fn makeEvalBindingRef(
    ctx: *core.JSContext,
    names: []const core.Atom,
    slots: []core.JSValue,
    atom_id: core.Atom,
) !?core.JSValue {
    for (names, 0..) |name, idx| {
        if (idx >= slots.len) continue;
        if (!shared_vm.atomIdOrNameEql(ctx.runtime, name, atom_id)) continue;
        return try shared_vm.ensureVarRefCell(ctx, &slots[idx]);
    }
    return null;
}

fn makeEvalVarRef(
    rt: *core.JSRuntime,
    names: []const core.Atom,
    refs: []const core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    for (names, 0..) |name, idx| {
        if (idx >= refs.len) continue;
        if (!shared_vm.atomIdOrNameEql(rt, name, atom_id)) continue;
        if (varRefCellFromValue(refs[idx]) == null) return null;
        return refs[idx].dup();
    }
    return null;
}

pub fn getRefValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime slotValueDup: anytype,
    comptime toPropertyKeyAtom: anytype,
    comptime getValueProperty: anytype,
) !void {
    if (stack.values.len < 2) return error.StackUnderflow;
    const obj = stack.values[stack.values.len - 2].dup();
    defer obj.free(ctx.runtime);
    const key = stack.values[stack.values.len - 1].dup();
    defer key.free(ctx.runtime);
    if (obj.isUndefined()) return error.ReferenceError;
    if (varRefCellFromValue(obj) != null) {
        const value = slotValueDup(obj);
        errdefer value.free(ctx.runtime);
        if (value.isUninitialized()) return error.ReferenceError;
        try stack.pushOwned(value);
        return;
    }
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    const value = try getValueProperty(ctx, output, global, obj, atom_id, function, frame);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub fn getRefValueVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime slotValueDup: anytype,
    comptime toPropertyKeyAtom: anytype,
    comptime getValueProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    getRefValue(ctx, output, global, stack, function, frame, slotValueDup, toPropertyKeyAtom, getValueProperty) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn putRefValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime setSlotValue: anytype,
    comptime toPropertyKeyAtom: anytype,
    comptime setValueProperty: anytype,
) !void {
    const value = try stack.pop();
    errdefer value.free(ctx.runtime);
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    var obj = try stack.pop();
    defer obj.free(ctx.runtime);

    const runtime_strict = function.flags.is_strict or function.flags.runtime_strict;
    if (obj.isUndefined()) {
        if (runtime_strict) return error.ReferenceError;
        const global_value = global.value().dup();
        obj.free(ctx.runtime);
        obj = global_value;
    }
    if (varRefCellFromValue(obj)) |cell| {
        if (cell.varRefIsFunctionNameSlot().*) {
            if (!runtime_strict) {
                value.free(ctx.runtime);
                return;
            }
            _ = shared_vm.throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
            return error.TypeError;
        }
        if (cell.varRefIsConstSlot().*) {
            _ = shared_vm.throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
            return error.TypeError;
        }
        var ref_slot = obj.dup();
        defer ref_slot.free(ctx.runtime);
        try setSlotValue(ctx, &ref_slot, value);
        return;
    }
    defer value.free(ctx.runtime);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    if (runtime_strict) {
        const object = try property_ops.expectObject(obj);
        if (!try hasObjectBinding(ctx, output, global, obj, object, atom_id, function, frame)) return error.ReferenceError;
    }
    const result = try setValueProperty(ctx, output, global, obj, atom_id, value, function, frame);
    result.free(ctx.runtime);
}

pub fn putRefValueVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime setSlotValue: anytype,
    comptime toPropertyKeyAtom: anytype,
    comptime setValueProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    putRefValue(ctx, output, global, stack, function, frame, setSlotValue, toPropertyKeyAtom, setValueProperty) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn withPut(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime hasPropertyForWith: anytype,
    comptime setValueProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const diff = readInt(i32, function.code[frame.pc + 4 ..][0..4]);
    const operand_pc = frame.pc;
    frame.pc += 9;
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    if (obj.isUndefined()) return .continue_loop;
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    _ = hasPropertyForWith(ctx, output, global, obj, atom_id, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const result = setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    frame.pc = @intCast(@as(i64, @intCast(operand_pc + 4)) + diff);
    result.free(ctx.runtime);
    return .done;
}

pub fn deleteVar(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    comptime deleteEvalBinding: anytype,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    if (deleteEvalBinding(ctx.runtime, function, frame, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, atom_id)) |deleted| {
        try stack.pushOwned(core.JSValue.boolean(deleted));
    } else if (global.hasProperty(atom_id)) {
        try stack.pushOwned(core.JSValue.boolean(global.deleteProperty(ctx.runtime, atom_id)));
    } else {
        try stack.pushOwned(core.JSValue.boolean(true));
    }
}

pub fn deletePropertyVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime deleteValueProperty: anytype,
    comptime functionHasFrameBinding: anytype,
    comptime typedArrayCanonicalDelete: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const prop = try stack.pop();
    defer prop.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    if (obj.isNull() or obj.isUndefined()) {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
        return error.TypeError;
    } else if (!obj.isObject()) {
        try stack.pushOwned(core.JSValue.boolean(true));
    } else {
        const object = try property_ops.expectObject(obj);
        const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, prop);
        defer ctx.runtime.atoms.free(atom_id);
        const deleted = if (object.proxyTarget() != null) blk: {
            break :blk deleteValueProperty(ctx, output, global, obj, object, atom_id, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        } else if (object == global and functionHasFrameBinding(ctx.runtime, function, frame, atom_id))
            false
        else if (object.flags.is_array and atom_id == core.atom.ids.length)
            false
        else if (try typedArrayCanonicalDelete(ctx.runtime, object, atom_id)) |typed_deleted|
            typed_deleted
        else
            object.deleteProperty(ctx.runtime, atom_id);
        if (!deleted and function.flags.is_strict) {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
            return error.TypeError;
        }
        try stack.pushOwned(core.JSValue.boolean(deleted));
    }
    return .done;
}
