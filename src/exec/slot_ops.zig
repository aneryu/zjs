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
const value_slot = @import("value_slot.zig");

// Helpers that remain in call_runtime.zig (generic runtime utilities outside the
// slot-operation cluster).
const ensureVarRefsCapacity = frame_mod.ensureVarRefsCapacity;
const globalLexicalHas = call_runtime.globalLexicalHas;
const globalLexicalHasForGlobal = call_runtime.globalLexicalHasForGlobal;
const globalLexicalValue = call_runtime.globalLexicalValue;
const globalLexicalValueForGlobal = call_runtime.globalLexicalValueForGlobal;
const handleCatchableRuntimeError = call_runtime.handleCatchableRuntimeError;
const isFunctionLikeClass = call_runtime.isFunctionLikeClass;
const pushAdapterValue = array_ops.pushAdapterValue;
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
    stack.pushOwnedAssumeCapacity(value_slot.loadOwned(&frame.locals[idx]));
}

pub noinline fn execPutLoc(
    ctx: *core.JSContext,
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
    value_slot.replaceOwned(ctx.runtime, &frame.locals[idx], value);
}

pub fn execSetLoc(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    // idx < var_count == frame.locals.len by construction (see execGetLoc).
    // set_loc leaves the operand on the stack; borrow it and let the
    // ValueSlot take exactly one retained reference.
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    value_slot.replaceBorrowed(ctx.runtime, &frame.locals[idx], value);
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
    _ = opc;
    if (idx >= frame.args.len) {
        try stack.pushOwned(core.JSValue.undefinedValue());
        return;
    }
    const owned = value_slot.loadOwned(&frame.args[idx]);
    errdefer owned.free(ctx.runtime);
    try stack.pushOwned(owned);
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
    value_slot.replaceOwned(ctx.runtime, &frame.args[idx], value);
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
    // set_arg has the same non-consuming ownership contract as set_loc.
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    value_slot.replaceBorrowed(ctx.runtime, &frame.args[idx], value);
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
    try pushAdapterValue(stack, varRefSlot(frame, idx));
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
    const value = cell.varRefValue();
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
    const capture_is_function_name = idx < function.closure_var.len and
        function.closure_var[idx].var_kind == .function_name;
    const capture_is_const = idx < function.closure_var.len and
        function.closure_var[idx].is_const;
    if (cell.varRefIsFunctionNameSlot().* or capture_is_function_name) {
        value.free(ctx.runtime);
        if (function.flags.is_strict) return error.TypeError;
        return;
    }
    if ((cell.varRefIsConstSlot().* or capture_is_const) and !constVarRefWriteAllowed(cell, opc)) {
        value.free(ctx.runtime);
        _ = throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
        return error.TypeError;
    }
    if (value.isObject()) {
        try publishTopLevelFunctionVarRef(ctx.runtime, function, global, frame, idx, value, eval_global_var_bindings, is_eval_code);
    }
    var assigned = value;
    if (varRefCellFromValue(value) != null) {
        assigned = adapterValueDup(value);
        value.free(ctx.runtime);
    }
    errdefer assigned.free(ctx.runtime);
    cell.setVarRefValue(ctx.runtime, assigned);
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

pub noinline fn publishTopLevelFunctionVarRef(
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
    const eval_annex_b_function = is_eval_code and eval_global_var_bindings and idx < function.closure_var.len and
        (function.closure_var[idx].var_kind == .function_decl or function.closure_var[idx].var_kind == .new_function_decl);
    if (function.varRefIsLexicalAt(idx) and !eval_annex_b_function) return;
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
                cell.setVarRefValue(rt, value.dup());
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
    replaceVarRefValueOwned(ctx, frame, idx, value.dup());
}

/// Owned value view of a JSValue Adapter slot. Frame locals and arguments do
/// not use this Interface; they are always plain ValueSlots.
pub fn adapterValueDup(slot: core.JSValue) core.JSValue {
    return adapterValueBorrow(slot).dup();
}

pub fn adapterValueBorrow(slot: core.JSValue) callconv(.c) core.JSValue {
    // Terminal-state invariant: a cell's VALUE is never itself a cell — the
    // last nesting producer (the direct-eval const view) now pvalue-aliases
    // its target (eval_ops.directEvalOuterVarRefView) — so ONE unwrap reaches
    // the plain value (qjs bare `*var_ref->pvalue`, quickjs.c:18627).
    const cell = varRefCellFromValue(slot) orelse return slot;
    const value = cell.varRefValue();
    if (comptime builtin.mode == .Debug) {
        std.debug.assert(varRefCellFromValue(value) == null);
    }
    return value;
}

pub fn adapterValueIsUninitialized(slot: core.JSValue) bool {
    return adapterValueBorrow(slot).isUninitialized();
}

/// A deleted eval-created binding: its deletable cell was parked at
/// UNINITIALIZED by ordinary global property deletion (qjs
/// remove_global_object_property, quickjs.c:9289-9309). Distinct from a TDZ
/// cell, which is uninitialized but NOT deletable.
pub fn adapterIsDeletedEvalBinding(slot: core.JSValue) bool {
    const cell = varRefCellFromValue(slot) orelse return false;
    if (!cell.varRefIsDeletableSlot().*) return false;
    return cell.varRefValue().isUninitialized();
}

/// Replace an owned JSValue Adapter slot. Unlike `value_slot.replaceOwned`,
/// this cold boundary accepts a VarRef handle on either side and preserves its
/// write-through semantics. It must not be used for frame locals or arguments.
pub inline fn replaceAdapterOwned(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) void {
    if (!slot.requiresRefCount() and !value.requiresRefCount()) {
        slot.* = value;
        return;
    }
    replaceAdapterRefCounted(ctx, slot, value);
}

noinline fn replaceAdapterRefCounted(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) void {
    var assigned = value;
    if (varRefCellFromValue(value) != null) {
        assigned = adapterValueDup(value);
        value.free(ctx.runtime);
    }
    if (varRefCellFromValue(slot.*)) |cell| {
        cell.setVarRefValue(ctx.runtime, assigned);
        return;
    }
    const old_value = slot.*;
    slot.* = assigned;
    old_value.free(ctx.runtime);
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

/// Bounds-checked element read in JSValue form (the cell's value view).
/// Borrowed: callers dup when they need ownership.
pub inline fn varRefSlot(frame: *const frame_mod.Frame, idx: usize) core.JSValue {
    return frame.var_refs[idx].valueRef();
}

/// Cell store — slot REBIND, not value write-through. The only users are the
/// element-level replacement points (global-decl PASS2 cell surgery and
/// module prologue fill): the caller owns the
/// refcount choreography for both the incoming cell and the displaced one.
/// The JSValue parameter is the boundary form those callers hold (an owned
/// ref to a cell by construction); the transfer keeps its refcount.
pub inline fn storeVarRefSlot(frame: *frame_mod.Frame, idx: usize, slot: core.JSValue) void {
    frame.var_refs[idx] = varRefCellFromValue(slot) orelse unreachable;
}

/// Write-through store into the slot's cell (qjs OP_put_var_ref
/// `set_value(ctx, var_refs[idx]->pvalue, ...)`, quickjs.c:18638). Preserves
/// the Adapter replacement unwrap: an incoming cell VALUE is dereferenced
/// before the store so cell values never nest through writes.
pub inline fn replaceVarRefValueOwned(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize, value: core.JSValue) void {
    var assigned = value;
    if (varRefCellFromValue(value) != null) {
        assigned = adapterValueDup(value);
        value.free(ctx.runtime);
    }
    frame.var_refs[idx].setVarRefValue(ctx.runtime, assigned);
}
