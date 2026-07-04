//! Local, argument, var-ref and global-lexical slot operations shared between the VM and call runtime.

const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("../bytecode.zig");
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
const ensureVarRefsCapacity = frame_mod.ensureVarRefsCapacity;
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
) !void {
    frame.pc += consume;
    _ = opc;
    // idx < var_count == frame.locals.len by construction (see execGetLoc).
    const value = try stack.pop();
    if (try assignDirectEvalGlobalVarLocalSlot(ctx, global, function, idx, &frame.locals[idx], value)) return;
    try setSlotValue(ctx, &frame.locals[idx], value);
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
) !void {
    frame.pc += consume;
    _ = opc;
    // idx < var_count == frame.locals.len by construction (see execGetLoc).
    const value = stack.peek() orelse return error.StackUnderflow;
    defer value.free(ctx.runtime);
    if (try assignDirectEvalGlobalVarLocalSlot(ctx, global, function, idx, &frame.locals[idx], value.dup())) return;
    try setSlotValue(ctx, &frame.locals[idx], value.dup());
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
    try pushSlotValue(stack, varRefSlot(frame, idx));
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
    if (idx < function.varRefNamesLen()) {
        const atom_id = function.varRefName(idx);
        // Only a genuine top-level global_decl var-ref (qjs JS_CLOSURE_GLOBAL_DECL)
        // reads through the global lexical cell by name. A captured block/loop
        // lexical (.ref/.local) that merely shares a name must fall through to the
        // real frame.var_refs cell below so its TDZ check is honored — otherwise a
        // same-named outer top-level `let` shadows the captured per-iteration TDZ slot.
        const is_global_decl_ref = function.varRefIsGlobalDeclAt(idx);
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
    // Slot is a cell by type (qjs OP_get_var_ref_check, quickjs.c:18630);
    // the pre-typed raw-slot arm is gone with the type flip.
    const cell = varRefSlotCell(frame, idx);
    const value = slotValueBorrow(cell.valueRef());
    if (value.isUninitialized()) {
        // A deletable cell parked at UNINITIALIZED is a deleted
        // eval-created binding (qjs remove_global_object_property):
        // plain ReferenceError, not the TDZ message.
        if (cell.varRefIsDeletableSlot().*) {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) {
                return true;
            }
            return error.ReferenceError;
        }
        const err = throwTdzReference(ctx);
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
            return true;
        }
        return err;
    }
    try stack.push(value);
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
    // Slot is a cell by type (qjs OP_put_var_ref set_value into
    // var_refs[idx]->pvalue, quickjs.c:18638); the raw-slot arm — including
    // its global-lexical/sentinel fallbacks, which post phase-B could never
    // execute (every slot was already a cell) — is deleted with the type.
    const cell = varRefSlotCell(frame, idx);
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
    errdefer assigned.free(ctx.runtime);
    try cell.setVarRefValue(ctx.runtime, assigned);
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
    if (idx >= function.varRefNamesLen()) return;
    if (!value.isObject()) return;
    if (function.flags.is_module) return;
    if (is_eval_code and !eval_global_var_bindings) return;
    // Only NON-lexical top-level bindings (`var`/`function` declarations) reflect
    // their function value onto the global object. A top-level LEXICAL binding
    // (`let`/`const`/`class`, a JS_CLOSURE_GLOBAL_DECL with is_lexical) lives in
    // the global lexical environment record only — qjs never creates a global
    // object property for it (a top-level `class A{}` / `let f = function(){}`
    // must leave `globalThis.A` undefined; `language/global-code/decl-lex.js`).
    if (function.varRefIsLexicalAt(idx)) return;
    if (!sameObjectIdentity(frame.this_value, global.value())) return;
    const object = property_ops.expectObject(value) catch return;
    if (!isFunctionLikeClass(object.class_id)) return;
    try defineGlobalFunctionBindingValue(rt, global, function.varRefName(idx), value, is_eval_code);
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
    try setVarRefSlotValue(ctx, frame, idx, value.dup());
}

pub fn slotValueDup(slot: core.JSValue) core.JSValue {
    return slotValueBorrow(slot).dup();
}

pub fn slotValueBorrow(slot: core.JSValue) callconv(.c) core.JSValue {
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

/// A deleted eval-created binding: its deletable cell was parked at
/// UNINITIALIZED by deleteVarRefSlot (qjs remove_global_object_property,
/// quickjs.c:9289-9309). Distinct from a TDZ cell, which is uninitialized
/// but NOT deletable.
pub fn varRefSlotIsDeletedEvalBinding(slot: core.JSValue) bool {
    const cell = varRefCellFromValue(slot) orelse return false;
    if (!cell.varRefIsDeletableSlot().*) return false;
    return cell.varRefValue().isUninitialized();
}

pub fn evalLocalSlotIsEvalVarCell(slot: core.JSValue) bool {
    const cell = varRefCellFromValue(slot) orelse return false;
    return cell.varRefIsDeletableSlot().*;
}

// inline, mirroring QuickJS `static inline set_value`: the common store where
// neither the outgoing slot nor the incoming value is reference-counted (the hot
// numeric local-assign case) is a bare move with no call boundary, so a hot
// handler need not spill its live values across it. The var-ref-cell / refcounted
// teardown is outlined to keep the inlined footprint to a single branch + store.
pub inline fn setSlotValue(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) !void {
    if (!slot.requiresRefCount() and !value.requiresRefCount()) {
        slot.* = value;
        return;
    }
    return setSlotValueRefCounted(ctx, slot, value);
}

noinline fn setSlotValueRefCounted(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) !void {
    var assigned = value;
    if (varRefCellFromValue(value) != null) {
        assigned = slotValueDup(value);
        value.free(ctx.runtime);
    }
    if (varRefCellFromValue(slot.*)) |cell| {
        try cell.setVarRefValue(ctx.runtime, assigned);
        return;
    }
    const old_value = slot.*;
    slot.* = assigned;
    old_value.free(ctx.runtime);
}

pub fn derivedConstructorThisLocalSlot(frame: *frame_mod.Frame) ?*core.JSValue {
    if (!frame.function.flags.is_derived_class_constructor) return null;
    for (frame.function.vardefs, 0..) |vd, idx| {
        if (vd.var_name == 8 and idx < frame.locals.len) return &frame.locals[idx];
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

// ---- frame.var_refs slot accessors (VARREFS-SLOT-TYPING-BLUEPRINT, phase D) ----
//
// Single funnel for every ELEMENT access of `frame.var_refs: []*core.VarRef`
// (qjs `JSVarRef **var_refs`: JSObject.u.func.var_refs alloc, quickjs.c:17277;
// JS_CallInternal prologue `var_refs = p->u.func.var_refs`, 17844). Every slot
// is a live cell by the type; the phase-A/B "is this slot a cell" runtime
// discrimination and its debug canary are gone. `varRefSlot*` returning
// JSValue are the boundary views for the JSValue-typed domains (eval name
// tables, property cells) — they wrap the cell, they do not chase its value.

/// Bounds-checked cell read: `frame.var_refs[idx]`.
pub inline fn varRefSlotCell(frame: *const frame_mod.Frame, idx: usize) *core.VarRef {
    return frame.var_refs[idx];
}

/// Unchecked cell read: `frame.var_refs.ptr[idx]`, for hot handlers that
/// already tested `idx < frame.var_refs.len` (qjs OP_get_var_ref reads
/// `var_refs[idx]` with no bounds check at all, quickjs.c:18627).
pub inline fn varRefSlotCellUnchecked(frame: *const frame_mod.Frame, idx: usize) *core.VarRef {
    return frame.var_refs.ptr[idx];
}

/// Bounds-checked element read in JSValue form (the cell's value view) —
/// boundary accessor for the JSValue-typed eval/name-table domains. Borrowed:
/// callers dup for ownership, exactly as they did on the pre-typed slot.
pub inline fn varRefSlot(frame: *const frame_mod.Frame, idx: usize) core.JSValue {
    return frame.var_refs[idx].valueRef();
}

/// Cell store — slot REBIND, not value write-through. The only users are the
/// element-level replacement points (eval republish
/// `replaceFrameVarRefBinding`, global-decl PASS2 cell surgery
/// `defineGlobalDecl*Cell`, module prologue fill): the caller owns the
/// refcount choreography for both the incoming cell and the displaced one.
/// The JSValue parameter is the boundary form those callers hold (an owned
/// ref to a cell by construction); the transfer keeps its refcount.
pub inline fn storeVarRefSlot(frame: *frame_mod.Frame, idx: usize, slot: core.JSValue) void {
    frame.var_refs[idx] = varRefCellFromValue(slot) orelse unreachable;
}

/// Write-through store into the slot's cell (qjs OP_put_var_ref
/// `set_value(ctx, var_refs[idx]->pvalue, ...)`, quickjs.c:18638). Preserves
/// the setSlotValueRefCounted unwrap: an incoming cell VALUE is dereferenced
/// before the store so cell values never nest through writes.
pub inline fn setVarRefSlotValue(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize, value: core.JSValue) !void {
    var assigned = value;
    if (varRefCellFromValue(value) != null) {
        assigned = slotValueDup(value);
        value.free(ctx.runtime);
    }
    return frame.var_refs[idx].setVarRefValue(ctx.runtime, assigned);
}

/// Owned JSValue ref to the slot's cell. Pre-flip this cellified a raw slot
/// in place; the slot type now guarantees the cell, so this is a pure rc++
/// (qjs JS_CLOSURE_REF pointer copy + ref_count++, quickjs.c:17322-17324).
pub inline fn ensureVarRefSlotCell(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize) !core.JSValue {
    _ = ctx;
    return frame.var_refs[idx].valueRef().dup();
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
