//! Local, argument, var-ref and global-lexical slot operations shared between the VM and call runtime.

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");

const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const object_ops = @import("object_ops.zig");

// Helpers that remain in call_runtime.zig (generic runtime utilities outside the
// slot-operation cluster).
const atomIdOrNameEql = call_runtime.atomIdOrNameEql;
const ensureVarRefsCapacity = frame_mod.ensureVarRefsCapacity;
const existingGlobalLexicalEnv = call_runtime.existingGlobalLexicalEnv;
const existingGlobalLexicalEnvForGlobal = call_runtime.existingGlobalLexicalEnvForGlobal;
const globalLexicalHas = call_runtime.globalLexicalHas;
const globalLexicalHasForGlobal = call_runtime.globalLexicalHasForGlobal;
const globalLexicalValue = call_runtime.globalLexicalValue;
const globalLexicalValueForGlobal = call_runtime.globalLexicalValueForGlobal;
const handleCatchableRuntimeError = call_runtime.handleCatchableRuntimeError;
const isFunctionLikeClass = call_runtime.isFunctionLikeClass;
const pushSlotValue = array_ops.pushSlotValue;
const pushSlotValueAssumeCapacity = array_ops.pushSlotValueAssumeCapacity;
const sameObjectIdentity = object_ops.sameObjectIdentity;
const setGlobalLexicalValue = call_runtime.setGlobalLexicalValue;
const setGlobalLexicalValueForGlobal = call_runtime.setGlobalLexicalValueForGlobal;
const throwTdzReference = exception_ops.throwTdzReference;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;

const op = bytecode.opcode.op;

/// Shared helper for `get_loc` / `get_loc8` / `get_loc0..3`. `consume`
/// is the operand byte width (0 for short, 1 for u8, 2 for u16); the
/// caller has already decoded the index, so we only need to advance pc.
pub fn execGetLoc(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = ctx;
    _ = opc;
    // No runtime bounds check: `resolve_variables` only emits get_loc with
    // idx < var_count, and `frame.locals` is sized to exactly var_count
    // (vm_call.initFrameLocals). idx < var_count == frame.locals.len holds for
    // every dispatched frame — the same trusted-compiler model as QuickJS's
    // bare `var_buf[idx]`. The stack is pre-sized (reserveEntryFrameCapacity),
    // so the push skips reserveAdditional, mirroring qjs's `*sp++`.
    pushSlotValueAssumeCapacity(stack, frame.locals[idx]);
}

pub noinline fn execPutLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
    sync_global_lexical_locals: bool,
) !void {
    frame.pc += consume;
    _ = opc;
    // idx < var_count == frame.locals.len by construction (see execGetLoc).
    const value = try stack.pop();
    if (try assignDirectEvalGlobalVarLocalSlot(ctx, global, function, idx, &frame.locals[idx], value)) return;
    try setSlotValue(ctx, &frame.locals[idx], value);
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
}

pub fn execSetLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
    sync_global_lexical_locals: bool,
) !void {
    frame.pc += consume;
    _ = opc;
    // idx < var_count == frame.locals.len by construction (see execGetLoc).
    const value = stack.peek() orelse return error.StackUnderflow;
    defer value.free(ctx.runtime);
    if (try assignDirectEvalGlobalVarLocalSlot(ctx, global, function, idx, &frame.locals[idx], value.dup())) return;
    try setSlotValue(ctx, &frame.locals[idx], value.dup());
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
}

fn assignDirectEvalGlobalVarLocalSlot(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    idx: usize,
    slot: *core.JSValue,
    value: core.JSValue,
) !bool {
    const atom_id = call_runtime.directEvalGlobalVarLocalAtom(ctx.runtime, function, idx, slot.*) orelse return false;
    defer value.free(ctx.runtime);

    if (!try global.setOwnWritableDataProperty(ctx.runtime, atom_id, value)) {
        if (!global.hasOwnProperty(atom_id)) {
            try defineGlobalFunctionBindingValue(ctx.runtime, global, atom_id, value, true);
        }
    }

    const next_value = global.getProperty(atom_id);
    try setSlotValue(ctx, slot, next_value);
    return true;
}

pub fn syncTopLevelGlobalLexicalLocal(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: usize,
    enabled: bool,
) !void {
    if (!enabled) return;
    if (!try ensureGlobalLexicalSyncSlots(ctx, function, global, frame)) return;
    if (idx >= frame.globalLexicalSyncSlots().len or !frame.globalLexicalSyncSlots()[idx]) return;
    const atom_id = function.var_names[idx];
    if (idx < frame.globalLexicalSyncIndices().len) {
        const property_index = frame.globalLexicalSyncIndices()[idx];
        if (property_index != frame_mod.no_global_lexical_sync_index) {
            const env = frame.globalLexicalSyncEnv() orelse existingGlobalLexicalEnvForGlobal(ctx, global) orelse return;
            if (try env.setOwnDataPropertyAtForLexicalSync(ctx.runtime, property_index, atom_id, slotValueBorrow(frame.locals[idx]))) return;
        }
    }
    const value = slotValueDup(frame.locals[idx]);
    defer value.free(ctx.runtime);
    _ = try setGlobalLexicalValueForGlobal(ctx, global, atom_id, value);
}

pub fn ensureGlobalLexicalSyncSlots(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
) !bool {
    _ = global;
    if (frame.globalLexicalSyncChecked()) return frame.globalLexicalSyncSlots().len != 0;
    const env = existingGlobalLexicalEnv(ctx) orelse {
        // No global lexical env exists => this frame has no lexical slot to
        // mirror. Latch so the put_loc_check fast path stops re-probing (and
        // re-entering the noinline slow handler) on every iteration.
        (try frame.ensureCold(&ctx.runtime.memory)).global_lexical_sync_checked = true;
        return false;
    };
    (try frame.ensureCold(&ctx.runtime.memory)).global_lexical_sync_env = env;
    const count = @min(function.var_names.len, function.var_is_lexical.len);
    if (count == 0) {
        (try frame.ensureCold(&ctx.runtime.memory)).global_lexical_sync_checked = true;
        return false;
    }
    const slots = try ctx.runtime.memory.alloc(bool, count);
    errdefer ctx.runtime.memory.free(bool, slots);
    @memset(slots, false);
    const indices = try ctx.runtime.memory.alloc(usize, count);
    errdefer ctx.runtime.memory.free(usize, indices);
    @memset(indices, frame_mod.no_global_lexical_sync_index);
    var has_sync_slot = false;
    for (function.var_names[0..count], 0..) |atom_id, idx| {
        if (!function.var_is_lexical[idx]) continue;
        // Only a top-level (scope_level == 0) lexical binding mirrors the
        // global lexical cell. A block-level shadower (scope_level > 0) that
        // shares a name with a top-level `let`/`const` is a distinct frame
        // local and must NOT write through to the global cell. Mirrors qjs,
        // where a block `let` is `add_scope_var` (a pure frame local) with no
        // tie to the JS_CLOSURE_GLOBAL_DECL cell (quickjs.c:24380 define_var
        // gates global on scope_level == body_scope).
        if (idx < function.var_scope_level.len and function.var_scope_level[idx] != 0) continue;
        if (!env.hasOwnProperty(atom_id)) continue;
        if (env.getOwnDataPropertyLookup(atom_id)) |lookup| {
            indices[idx] = lookup.index;
            lookup.value.free(ctx.runtime);
        }
        var duplicate_prior = false;
        var prior_idx: usize = 0;
        while (prior_idx < idx) : (prior_idx += 1) {
            if (atomIdOrNameEql(ctx.runtime, function.var_names[prior_idx], atom_id)) {
                duplicate_prior = true;
                break;
            }
        }
        if (duplicate_prior) continue;
        slots[idx] = true;
        has_sync_slot = true;
    }
    const cold = try frame.ensureCold(&ctx.runtime.memory);
    cold.global_lexical_sync_checked = true;
    if (!has_sync_slot) {
        ctx.runtime.memory.free(bool, slots);
        ctx.runtime.memory.free(usize, indices);
        return false;
    }
    cold.global_lexical_sync_slots = slots;
    cold.global_lexical_sync_indices = indices;
    return true;
}

pub fn execGetArg(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = ctx;
    _ = opc;
    if (idx >= frame.args.len) {
        try stack.pushOwned(core.JSValue.undefinedValue());
        return;
    }
    try pushSlotValue(stack, frame.args[idx]);
}

pub fn execPutArg(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.args.len) return error.InvalidBytecode;
    const value = try stack.pop();
    try setSlotValue(ctx, &frame.args[idx], value);
}

pub fn execSetArg(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.args.len) return error.InvalidBytecode;
    const value = stack.peek() orelse return error.StackUnderflow;
    defer value.free(ctx.runtime);
    try setSlotValue(ctx, &frame.args[idx], value.dup());
}

pub fn execGetVarRef(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    try pushSlotValue(stack, frame.var_refs[idx]);
}

pub fn execGetVarRefMaybeTdz(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    catch_target: *?usize,
    global: *core.Object,
) !bool {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    if (idx < function.var_ref_names.len) {
        const atom_id = function.var_ref_names[idx];
        // Only a genuine top-level global_decl var-ref (qjs JS_CLOSURE_GLOBAL_DECL)
        // reads through the global lexical cell by name. A captured block/loop
        // lexical (.ref/.local) that merely shares a name must fall through to the
        // real frame.var_refs cell below so its TDZ check is honored — otherwise a
        // same-named outer top-level `let` shadows the captured per-iteration TDZ slot.
        const is_global_decl_ref = idx < function.var_ref_is_global_decl.len and function.var_ref_is_global_decl[idx];
        if (is_global_decl_ref) {
            if (globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| {
                if (lexical_value.isUninitialized()) {
                    lexical_value.free(ctx.runtime);
                    const err = throwTdzReference(ctx);
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
                        return true;
                    }
                    return err;
                }
                errdefer lexical_value.free(ctx.runtime);
                try stack.pushOwned(lexical_value);
                return false;
            }
        }
        if (call_runtime.closureVarIsNonLexicalGlobalSentinel(function, idx)) {
            const value = global.getProperty(atom_id);
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
            return false;
        }
    }
    const slot = frame.var_refs[idx];
    if (varRefCellFromValue(slot)) |cell| {
        if (cell.varRefIsDeletedSlot().*) {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) {
                return true;
            }
            return error.ReferenceError;
        }
        const value = slotValueBorrow(slot);
        if (value.isUninitialized()) {
            const err = throwTdzReference(ctx);
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
                return true;
            }
            return err;
        }
        try stack.push(value);
        return false;
    }
    if (slot.isUninitialized()) {
        const err = throwTdzReference(ctx);
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
            return true;
        }
        return err;
    }
    try stack.push(slot);
    return false;
}

pub fn execPutVarRef(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
    eval_global_var_bindings: bool,
    is_eval_code: bool,
) !void {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    const value = try stack.pop();
    const slot = frame.var_refs[idx];
    if (varRefCellFromValue(slot)) |cell| {
        if (opc == op.put_var_ref_check_init) {
            const current = cell.varRefValue();
            if (!current.isUninitialized()) {
                value.free(ctx.runtime);
                return error.ReferenceError;
            }
        }
        if (opc == op.put_var_ref_check) {
            const current = cell.varRefValue();
            if (current.isUninitialized()) {
                value.free(ctx.runtime);
                return throwTdzReference(ctx);
            }
        }
        if (cell.varRefIsFunctionNameSlot().*) {
            value.free(ctx.runtime);
            if (function.flags.is_strict) return error.TypeError;
            return;
        }
        if (cell.varRefIsConstSlot().* and !constVarRefWriteAllowed(cell, opc)) {
            value.free(ctx.runtime);
            _ = throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
            return error.TypeError;
        }
        try publishTopLevelFunctionVarRef(ctx.runtime, function, global, frame, idx, value, eval_global_var_bindings, is_eval_code);
        var assigned = value;
        if (varRefCellFromValue(value) != null) {
            assigned = slotValueDup(value);
            value.free(ctx.runtime);
        }
        cell.varRefIsDeletedSlot().* = false;
        errdefer assigned.free(ctx.runtime);
        try cell.setVarRefValue(ctx.runtime, assigned);
        return;
    }
    if (opc == op.put_var_ref_check_init and !slot.isUninitialized()) {
        value.free(ctx.runtime);
        return error.ReferenceError;
    }
    if (opc == op.put_var_ref_check and slot.isUninitialized()) {
        value.free(ctx.runtime);
        return throwTdzReference(ctx);
    }
    if (opc == op.put_var_ref_check and idx < function.var_ref_names.len) {
        const atom_id = function.var_ref_names[idx];
        if (globalLexicalHasForGlobal(ctx, global, atom_id)) {
            _ = setGlobalLexicalValueForGlobal(ctx, global, atom_id, value) catch |err| {
                value.free(ctx.runtime);
                return err;
            };
            return;
        }
        if (call_runtime.closureVarIsNonLexicalGlobalSentinel(function, idx)) {
            errdefer value.free(ctx.runtime);
            try publishTopLevelFunctionVarRef(ctx.runtime, function, global, frame, idx, value, eval_global_var_bindings, is_eval_code);
            try property_ops.setProperty(ctx.runtime, global, atom_id, value);
            value.free(ctx.runtime);
            return;
        }
    }
    if (opc == op.put_var_ref_check and idx < function.var_ref_is_const.len and function.var_ref_is_const[idx]) {
        value.free(ctx.runtime);
        _ = throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
        return error.TypeError;
    }
    try publishTopLevelFunctionVarRef(ctx.runtime, function, global, frame, idx, value, eval_global_var_bindings, is_eval_code);
    try setSlotValue(ctx, &frame.var_refs[idx], value);
}

pub fn isVarRefInitOpcode(opc: u8) bool {
    return opc == op.put_var_ref or
        opc == op.put_var_ref_check_init or
        opc == op.put_var_ref0 or
        opc == op.put_var_ref1 or
        opc == op.put_var_ref2 or
        opc == op.put_var_ref3;
}

pub fn constVarRefWriteAllowed(cell: *core.VarRef, opc: u8) bool {
    _ = cell;
    return isVarRefInitOpcode(opc);
}

pub fn publishTopLevelFunctionVarRef(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    value: core.JSValue,
    eval_global_var_bindings: bool,
    is_eval_code: bool,
) !void {
    if (idx >= function.var_ref_names.len) return;
    if (!value.isObject()) return;
    if (function.flags.is_module) return;
    if (is_eval_code and !eval_global_var_bindings) return;
    if (!sameObjectIdentity(frame.this_value, global.value())) return;
    const object = property_ops.expectObject(value) catch return;
    if (!isFunctionLikeClass(object.class_id)) return;
    try defineGlobalFunctionBindingValue(rt, global, function.var_ref_names[idx], value, is_eval_code);
}

pub fn defineGlobalFunctionBindingValue(
    rt: *core.JSRuntime,
    global: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    configurable: bool,
) !void {
    if (global.findProperty(atom_id)) |index| {
        const flags = global.propFlagsAt(index);
        if (!flags.deleted and !flags.isAccessor()) {
            if (global.asVarRefAt(index)) |cell| {
                try cell.setVarRefValue(rt, value.dup());
                cell.varRefIsDeletedSlot().* = false;
                return;
            }
        }
    }

    const desc = if (global.getOwnProperty(rt, atom_id)) |current| blk: {
        defer current.destroy(rt);
        if (current.configurable == true) {
            break :blk core.Descriptor.data(value, true, true, configurable);
        }
        break :blk core.Descriptor{
            .kind = .data,
            .value = value,
            .value_present = true,
        };
    } else core.Descriptor.data(value, true, true, configurable);

    global.defineOwnProperty(rt, atom_id, desc) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        else => return err,
    };
}

pub fn execSetVarRef(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    _ = opc;
    const value = stack.peek() orelse return error.StackUnderflow;
    defer value.free(ctx.runtime);
    try setSlotValue(ctx, &frame.var_refs[idx], value.dup());
}

pub fn slotValueDup(slot: core.JSValue) core.JSValue {
    return slotValueBorrow(slot).dup();
}

pub fn slotValueBorrow(slot: core.JSValue) core.JSValue {
    var current = slot;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const cell = varRefCellFromValue(current) orelse return current;
        current = cell.varRefValue();
    }
    return current;
}

pub fn varRefSlotIsUninitialized(slot: core.JSValue) bool {
    return slotValueBorrow(slot).isUninitialized();
}

pub fn varRefSlotIsDeleted(slot: core.JSValue) bool {
    const cell = varRefCellFromValue(slot) orelse return false;
    return cell.varRefIsDeletedSlot().*;
}

pub fn evalLocalSlotIsEvalVarCell(slot: core.JSValue) bool {
    const cell = varRefCellFromValue(slot) orelse return false;
    return cell.varRefIsDeletableSlot().*;
}

pub fn setSlotValue(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) !void {
    if (!slot.requiresRefCount() and !value.requiresRefCount()) {
        slot.* = value;
        return;
    }
    var assigned = value;
    if (varRefCellFromValue(value) != null) {
        assigned = slotValueDup(value);
        value.free(ctx.runtime);
    }
    if (varRefCellFromValue(slot.*)) |cell| {
        cell.varRefIsDeletedSlot().* = false;
        try cell.setVarRefValue(ctx.runtime, assigned);
        return;
    }
    const old_value = slot.*;
    slot.* = assigned;
    old_value.free(ctx.runtime);
}

pub fn derivedConstructorThisLocalSlot(frame: *frame_mod.Frame) ?*core.JSValue {
    if (!frame.function.flags.is_derived_class_constructor) return null;
    for (frame.function.var_names, 0..) |name, idx| {
        if (name == 8 and idx < frame.locals.len) return &frame.locals[idx];
    }
    return null;
}

pub fn closeLocalVarRef(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: u16) !void {
    if (idx >= frame.locals.len) return error.InvalidBytecode;
    frame.closeOpenVarRefForSlot(ctx.runtime, &frame.locals[idx]);
    const cell = varRefCellFromValue(frame.locals[idx]) orelse return;
    const value = cell.varRefValue().dup();
    const old_value = frame.locals[idx];
    frame.locals[idx] = value;
    old_value.free(ctx.runtime);
}

pub fn ensureVarRefCell(ctx: *core.JSContext, slot: *core.JSValue) !core.JSValue {
    if (varRefCellFromValue(slot.*) != null) return slot.*.dup();
    const cell = try core.VarRef.createClosed(ctx.runtime, slot.*);
    slot.* = cell.valueRef();
    return slot.*.dup();
}

pub fn ensureFrameVarRefCell(ctx: *core.JSContext, frame: *frame_mod.Frame, slot: *core.JSValue) !core.JSValue {
    if (varRefCellFromValue(slot.*) != null) return ensureVarRefCell(ctx, slot);
    if (!frameSlotCanOpenAlias(frame, slot)) return ensureVarRefCell(ctx, slot);
    if (frame.open_var_refs.len == 0) return ensureVarRefCell(ctx, slot);
    if (frame.findOpenVarRef(slot)) |cell| return cell.valueRef().dup();

    // The frame owns the initial reference; callers receive an additional
    // reference and may drop it on error without leaving the open list dangling.
    const cell = try core.VarRef.createOpen(ctx.runtime, slot);
    frame.addOpenVarRef(cell);
    return cell.valueRef().dup();
}

pub fn ensureLocalVarRefCell(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize, is_lexical: bool) !core.JSValue {
    if (varRefSlotIsUninitialized(frame.locals[idx])) return ensureVarRefCell(ctx, &frame.locals[idx]);
    if (is_lexical) return ensureVarRefCell(ctx, &frame.locals[idx]);
    return ensureFrameVarRefCell(ctx, frame, &frame.locals[idx]);
}

pub fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef {
    return core.VarRef.fromValue(value);
}

fn frameSlotCanOpenAlias(frame: *const frame_mod.Frame, slot: *const core.JSValue) bool {
    if (frame.function.flags.is_generator or frame.function.flags.is_async) return false;
    return slotInSlice(slot, frame.locals) or slotInSlice(slot, frame.args);
}

fn slotInSlice(slot: *const core.JSValue, values: []const core.JSValue) bool {
    if (values.len == 0) return false;
    const slot_addr = @intFromPtr(slot);
    const start = @intFromPtr(values.ptr);
    const byte_len = values.len * @sizeOf(core.JSValue);
    const end = start + byte_len;
    return slot_addr >= start and slot_addr < end and (slot_addr - start) % @sizeOf(core.JSValue) == 0;
}
