//! With-statement and reference opcode handlers (make_ref/get_ref_value/put_ref_value/with_*).

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ic = @import("property_ic.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");

const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("vm_exception_ops.zig");
const array_ops = @import("array_ops.zig");
const object_ops = @import("object_ops.zig");
const slot_ops = @import("slot_ops.zig");
const readInt = call_runtime.readInt;
const varRefCellFromValue = slot_ops.varRefCellFromValue;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const property_vm = @import("vm_property.zig");
const Step = property_vm.Step;
const decodeGlobalDataGet = property_vm.decodeGlobalDataGet;
const frameHasVarRefBinding = property_vm.frameHasVarRefBinding;
const hasObjectBinding = property_vm.hasObjectBinding;
const stringFromValue = property_vm.stringFromValue;
const varRefReadableBorrowed = property_vm.varRefReadableBorrowed;

const globalDataPropertyValueForFastPath = property_ic.globalDataPropertyValueForFastPath;
const globalWritableDataStoreAvailableForFastPath = property_ic.globalWritableDataStoreAvailableForFastPath;
const setGlobalWritableDataStoreForFastPathOwned = property_ic.setGlobalWritableDataStoreForFastPathOwned;

const op = bytecode.opcode.op;

pub noinline fn withGetOrDelete(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const diff = readInt(i32, function.code[frame.pc + 4 ..][0..4]);
    const is_with = function.code[frame.pc + 8] != 0;
    const operand_pc = frame.pc;
    frame.pc += 9;
    const obj_value = stack.peek() orelse return error.StackUnderflow;
    defer obj_value.free(ctx.runtime);
    const object = property_ops.expectObject(obj_value) catch {
        const dropped = try stack.pop();
        dropped.free(ctx.runtime);
        return .continue_loop;
    };
    const has_binding = object_ops.hasPropertyForWith(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const blocked = if (is_with and has_binding)
        call_runtime.isBlockedByUnscopables(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        }
    else
        false;
    if (!has_binding or blocked) {
        const dropped = try stack.pop();
        dropped.free(ctx.runtime);
        return .continue_loop;
    }
    const still_has_binding = if (opc == op.with_get_var or opc == op.with_get_ref)
        object_ops.hasPropertyForWith(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        }
    else
        true;
    if (opc == op.with_get_var and !still_has_binding and (function.flags.is_strict or function.flags.runtime_strict)) {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
        return error.ReferenceError;
    }
    switch (opc) {
        op.with_get_var => {
            const value = if (still_has_binding)
                try object_ops.getValueProperty(ctx, output, global, obj_value, atom_id, function, frame)
            else
                core.JSValue.undefinedValue();
            errdefer value.free(ctx.runtime);
            const dropped = try stack.pop();
            dropped.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.with_delete_var => {
            var deleted_cell_value = core.JSValue.undefinedValue();
            var has_deleted_cell = false;
            if (!is_with) {
                if (object.findProperty(atom_id)) |index| {
                    if (object.asVarRefAt(index)) |cell| {
                        if (cell.varRefIsDeletableSlot().*) {
                            deleted_cell_value = cell.valueRef().dup();
                            has_deleted_cell = true;
                        }
                    }
                }
            }
            defer if (has_deleted_cell) deleted_cell_value.free(ctx.runtime);
            const deleted = object.deleteProperty(ctx.runtime, atom_id);
            if (deleted and has_deleted_cell) {
                if (varRefCellFromValue(deleted_cell_value)) |cell| {
                    const old_value = cell.varRefValueSlot().*;
                    cell.varRefValueSlot().* = core.JSValue.uninitialized();
                    cell.is_lexical = false;
                    cell.varRefIsConstSlot().* = false;
                    old_value.free(ctx.runtime);
                }
            }
            if (!deleted and function.flags.is_strict) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                return error.TypeError;
            }
            const dropped = try stack.pop();
            dropped.free(ctx.runtime);
            try stack.pushOwned(core.JSValue.boolean(deleted));
        },
        op.with_get_ref => {
            const value = if (still_has_binding)
                try object_ops.getValueProperty(ctx, output, global, obj_value, atom_id, function, frame)
            else
                core.JSValue.undefinedValue();
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
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

pub noinline fn makeSlotRef(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    opc: u8,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const idx = readInt(u16, function.code[frame.pc + 4 ..][0..2]);
    frame.pc += 6;

    const cell: *core.VarRef = switch (opc) {
        op.make_loc_ref => blk: {
            if (idx >= frame.locals.len) return error.InvalidBytecode;
            break :blk try frame.captureLocal(ctx.runtime, idx);
        },
        op.make_arg_ref => blk: {
            if (idx >= frame.args.len) return error.InvalidBytecode;
            break :blk try frame.captureArg(ctx.runtime, idx);
        },
        op.make_var_ref_ref => blk: {
            try frame_mod.ensureVarRefsCapacity(ctx, frame, idx);
            break :blk frame.var_refs[idx].retain();
        },
        else => unreachable,
    };
    defer cell.release(ctx.runtime);
    const ref_value = cell.valueRef();
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
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const global_value = global.value();
    const has_global_binding = try hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame);
    const object_value = if (call_runtime.existingGlobalLexicalEnv(ctx)) |env|
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

pub noinline fn makeVarRefVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    makeVarRef(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn getRefValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    if (stack.values.len < 2) return error.StackUnderflow;
    const obj = stack.values[stack.values.len - 2].dup();
    defer obj.free(ctx.runtime);
    const key = stack.values[stack.values.len - 1].dup();
    defer key.free(ctx.runtime);
    if (obj.isUndefined()) return error.ReferenceError;
    if (varRefCellFromValue(obj) != null) {
        const value = slot_ops.adapterValueDup(obj);
        errdefer value.free(ctx.runtime);
        if (value.isUninitialized()) return error.ReferenceError;
        try stack.pushOwned(value);
        return;
    }
    const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    const value = try object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub noinline fn getRefValueVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    getRefValue(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
            _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
            return error.TypeError;
        }
        if (cell.varRefIsConstSlot().*) {
            _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
            return error.TypeError;
        }
        var ref_slot = obj.dup();
        defer ref_slot.free(ctx.runtime);
        slot_ops.replaceAdapterOwned(ctx, &ref_slot, value);
        return;
    }
    defer value.free(ctx.runtime);
    const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    const object = try property_ops.expectObject(obj);
    const still_exists = try hasObjectBinding(ctx, output, global, obj, object, atom_id, function, frame);
    if (!still_exists and runtime_strict) return error.ReferenceError;
    const result = try object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame);
    result.free(ctx.runtime);
}

pub noinline fn putRefValueVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    putRefValue(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn withPut(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const diff = readInt(i32, function.code[frame.pc + 4 ..][0..4]);
    const mode: bytecode.opcode.WithPutMode = switch (function.code[frame.pc + 8]) {
        @intFromEnum(bytecode.opcode.WithPutMode.var_object_probe) => .var_object_probe,
        @intFromEnum(bytecode.opcode.WithPutMode.selected_reference) => .selected_reference,
        @intFromEnum(bytecode.opcode.WithPutMode.with_probe) => .with_probe,
        else => return error.InvalidBytecode,
    };
    const operand_pc = frame.pc;
    frame.pc += 9;
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    if (obj.isUndefined()) return .continue_loop;
    if (mode != .selected_reference) {
        const has_binding = object_ops.hasPropertyForWith(ctx, output, global, obj, atom_id, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
        if (!has_binding) return .continue_loop;
        if (mode == .with_probe) {
            const blocked = call_runtime.isBlockedByUnscopables(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            if (blocked) return .continue_loop;
        }
    }
    const still_exists = object_ops.hasPropertyForWith(ctx, output, global, obj, atom_id, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (!still_exists and (function.flags.is_strict or function.flags.runtime_strict)) {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
        return error.ReferenceError;
    }
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const result = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    frame.pc = @intCast(@as(i64, @intCast(operand_pc + 4)) + diff);
    result.free(ctx.runtime);
    return .done;
}

pub noinline fn deleteVar(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    // qjs JS_DeleteGlobalVar: declarative globals are not deletable; every
    // object-environment binding goes through the ordinary global property
    // delete, which also parks a captured VARREF cell at UNINITIALIZED.
    const deleted = if (call_runtime.globalLexicalHasForGlobal(ctx, global, atom_id))
        false
    else if (global.hasProperty(atom_id))
        global.deleteProperty(ctx.runtime, atom_id)
    else
        true;
    try stack.pushOwned(core.JSValue.boolean(deleted));
}

pub noinline fn deletePropertyVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const prop = try stack.pop();
    defer prop.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    // qjs js_operator_delete (quickjs.c:16072) runs JS_ValueToAtom on the key
    // FIRST: user toString/Symbol.toPrimitive side effects (and their
    // exceptions) fire before any base check.
    const atom_id = object_ops.toPropertyKeyAtom(ctx, output, global, prop, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    defer ctx.runtime.atoms.free(atom_id);
    if (obj.isNull() or obj.isUndefined()) {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
        return error.TypeError;
    }
    // JS_DeleteProperty (quickjs.c:10920) converts the base via JS_ToObject and
    // runs the real delete on the wrapper, so string-exotic non-configurable
    // props (indices, .length) report false and strict mode throws.
    const obj_value = if (obj.isObject()) obj.dup() else object_ops.primitiveObjectForAccess(ctx.runtime, global, obj) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    defer obj_value.free(ctx.runtime);
    const object = try property_ops.expectObject(obj_value);
    const deleted = if (object.proxyTarget() != null) blk: {
        break :blk object_ops.deleteValueProperty(ctx, output, global, obj_value, object, atom_id, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    } else if (object.isArray() and atom_id == core.atom.ids.length)
        false
    else if (try array_ops.typedArrayCanonicalDelete(ctx.runtime, object, atom_id)) |typed_deleted|
        typed_deleted
    else
        object.deleteProperty(ctx.runtime, atom_id);
    if (!deleted and function.flags.is_strict) {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
        return error.TypeError;
    }
    try stack.pushOwned(core.JSValue.boolean(deleted));
    return .done;
}
