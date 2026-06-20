//! Recursive, register-resident bytecode dispatcher — the radical rewrite core.
//! See `scratch/perf/ARCH-RECURSIVE-REWRITE.md`. comptime-gated behind
//! `build_options.zjs_recursive_dispatch` (default OFF); built up incrementally.
//! `pc` is a C-local mirror of frame.pc (LLVM register-allocates it); hot
//! operand-decoders inline on it, every other opcode syncs frame.pc and
//! delegates to the same handler dispatchLoop uses (drop the sync to migrate).
//! WIP: call_method/call_prepared/eval @panic on inline_call/tail_inline (need
//! native-recursion integration); no per-opcode interrupt poll yet.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const exception_ops = @import("vm_exception_ops.zig");
const HostError = @import("exceptions.zig").HostError;

const value_vm = @import("vm_value.zig");
const inline_calls = @import("inline_calls.zig");
const array_ops = @import("array_ops.zig");
const forof_ops = @import("forof_ops.zig");
const call_vm = @import("vm_call.zig");
const regexp_vm = @import("vm_regexp.zig");
const class_vm = @import("object_ops.zig");
const arith_vm = @import("vm_arith.zig");
const control_vm = @import("vm_control.zig");
const call_runtime = @import("call_runtime.zig");
const eval_module_vm = @import("vm_eval_module.zig");
const value_ops = @import("value_ops.zig");
const vm_property_locals = @import("vm_property_locals.zig");
const vm_property_ref = @import("vm_property_ref.zig");
const vm_property_globals = @import("vm_property_globals.zig");
const vm_property_field = @import("vm_property_field.zig");
const vm_property_private = @import("vm_property_private.zig");
const literal_vm = @import("vm_literal.zig");
const iter_vm = @import("iterator_ops.zig");
const slot_ops = @import("slot_ops.zig");

const op = bytecode.opcode.op;
pub const recursive_dispatch_enabled = build_options.zjs_recursive_dispatch;

const eval_class_field_initializer_flag: u16 = 0x8000;
const eval_parameter_initializer_flag: u16 = 0x4000;

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn relativePc(operand_pc: usize, diff: i32) usize {
    return @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
}

/// STEP 2 (qjs technique): `ip` is the single register-resident instruction
/// pointer (qjs's `*pc++`). The bytecode base never has to be reloaded — we hold
/// one incrementing pointer instead of base+index. `ipOff` recovers the byte
/// offset only at cold boundaries that need `frame.pc` (calls/exceptions/jumps).
inline fn ipOff(ip: [*]const u8, code_base: [*]const u8) usize {
    return @intFromPtr(ip) - @intFromPtr(code_base);
}

inline fn plainLocalSlotFastPath(
    function: *const bytecode.Bytecode,
    idx: usize,
    old_value: core.JSValue,
    value: core.JSValue,
) bool {
    if (idx < function.var_is_lexical.len and function.var_is_lexical[idx]) return false;
    if (slot_ops.varRefCellFromValue(old_value) != null) return false;
    if (slot_ops.varRefCellFromValue(value) != null) return false;
    return true;
}

inline fn stackWindowLen(base: [*]core.JSValue, sp: [*]core.JSValue) usize {
    return (@intFromPtr(sp) - @intFromPtr(base)) / @sizeOf(core.JSValue);
}

inline fn stackHas(base: [*]core.JSValue, sp: [*]core.JSValue, needed: usize) bool {
    return (@intFromPtr(sp) - @intFromPtr(base)) >= needed * @sizeOf(core.JSValue);
}

inline fn publishStackWindow(stack: *stack_mod.Stack, base: [*]core.JSValue, sp: [*]core.JSValue) void {
    stack.values = base[0..stackWindowLen(base, sp)];
}

inline fn assertStackWindowSynced(stack: *const stack_mod.Stack, base: [*]core.JSValue, sp: [*]core.JSValue) void {
    if (std.debug.runtime_safety) std.debug.assert(stackWindowLen(base, sp) == stack.values.len);
}

// Pure publish model (faithful to qjs's `sf->cur_sp = sp`): the operand-stack GC
// root stays `.mutable = &stack.values` for the whole frame (set by
// FrameRootScope.init), and `sp` is a register C-local whose address is only
// passed to inline helpers. A cold arm that can allocate or recurse calls this on
// ENTRY to publish the live length, so the GC and the callee observe the correct
// operand slice.
inline fn enterStackBoundary(
    stack: *stack_mod.Stack,
    base: [*]core.JSValue,
    sp: [*]core.JSValue,
) void {
    publishStackWindow(stack, base, sp);
    assertStackWindowSynced(stack, base, sp);
}

// On LEAVING a cold-arm boundary, reload `base`+`sp` from `stack.values`: the
// cold op may have grown/reallocated the operand stack (new buffer and/or length).
inline fn leaveStackBoundary(
    stack: *stack_mod.Stack,
    base: *[*]core.JSValue,
    sp: *[*]core.JSValue,
    frame: *frame_mod.Frame,
    var_buf: *[*]core.JSValue,
    arg_buf: *[*]core.JSValue,
) void {
    base.* = stack.values.ptr;
    sp.* = stack.values.ptr + stack.values.len;
    var_buf.* = frame.locals.ptr;
    arg_buf.* = frame.args.ptr;
    assertStackWindowSynced(stack, base.*, sp.*);
}

inline fn pushOwnedWindow(stack: *const stack_mod.Stack, base: [*]core.JSValue, sp: *[*]core.JSValue, value: core.JSValue) void {
    std.debug.assert(stackWindowLen(base, sp.*) < stack.capacity);
    sp.*[0] = value;
    sp.* += 1;
}

inline fn pushBorrowedWindow(stack: *const stack_mod.Stack, base: [*]core.JSValue, sp: *[*]core.JSValue, value: core.JSValue) void {
    pushOwnedWindow(stack, base, sp, if (value.requiresRefCount()) value.dup() else value);
}

inline fn pushSlotWindow(stack: *const stack_mod.Stack, base: [*]core.JSValue, sp: *[*]core.JSValue, slot: core.JSValue) void {
    if (!slot.requiresRefCount()) return pushOwnedWindow(stack, base, sp, slot);
    pushBorrowedWindow(stack, base, sp, slotValueBorrowFast(slot));
}

inline fn popWindow(base: [*]core.JSValue, sp: *[*]core.JSValue) !core.JSValue {
    if (sp.* == base) return error.StackUnderflow;
    sp.* -= 1;
    return sp.*[0];
}

inline fn borrowedValueFast(value: core.JSValue) core.JSValue {
    return if (value.requiresRefCount()) value.dup() else value;
}

inline fn stackRequire(base: [*]core.JSValue, sp: [*]core.JSValue, required: usize) !void {
    if (!stackHas(base, sp, required)) return error.StackUnderflow;
}

inline fn dupWindow(stack: *const stack_mod.Stack, base: [*]core.JSValue, sp: *[*]core.JSValue) !void {
    try stackRequire(base, sp.*, 1);
    pushBorrowedWindow(stack, base, sp, (sp.* - 1)[0]);
}

inline fn dup1Window(base: [*]core.JSValue, sp: *[*]core.JSValue) !void {
    try stackRequire(base, sp.*, 2);
    const a = (sp.* - 2)[0];
    const b = (sp.* - 1)[0];
    (sp.* - 1)[0] = borrowedValueFast(a);
    sp.*[0] = b;
    sp.* += 1;
}

inline fn dup2Window(base: [*]core.JSValue, sp: *[*]core.JSValue) !void {
    try stackRequire(base, sp.*, 2);
    const a = (sp.* - 2)[0];
    const b = (sp.* - 1)[0];
    sp.*[0] = borrowedValueFast(a);
    sp.*[1] = borrowedValueFast(b);
    sp.* += 2;
}

inline fn dup3Window(base: [*]core.JSValue, sp: *[*]core.JSValue) !void {
    try stackRequire(base, sp.*, 3);
    const a = (sp.* - 3)[0];
    const b = (sp.* - 2)[0];
    const c = (sp.* - 1)[0];
    sp.*[0] = borrowedValueFast(a);
    sp.*[1] = borrowedValueFast(b);
    sp.*[2] = borrowedValueFast(c);
    sp.* += 3;
}

inline fn swapWindow(base: [*]core.JSValue, sp: [*]core.JSValue) !void {
    try stackRequire(base, sp, 2);
    const a_slot = sp - 2;
    const b_slot = sp - 1;
    const a = a_slot[0];
    a_slot[0] = b_slot[0];
    b_slot[0] = a;
}

inline fn swap2Window(base: [*]core.JSValue, sp: [*]core.JSValue) !void {
    try stackRequire(base, sp, 4);
    const a = (sp - 4)[0];
    const b = (sp - 3)[0];
    const c = (sp - 2)[0];
    const d = (sp - 1)[0];
    (sp - 4)[0] = c;
    (sp - 3)[0] = d;
    (sp - 2)[0] = a;
    (sp - 1)[0] = b;
}

inline fn nipWindow(rt: *core.JSRuntime, base: [*]core.JSValue, sp: *[*]core.JSValue) !void {
    try stackRequire(base, sp.*, 2);
    const a_slot = sp.* - 2;
    const b = (sp.* - 1)[0];
    const a = a_slot[0];
    a_slot[0] = b;
    sp.* -= 1;
    a.free(rt);
}

inline fn nip1Window(rt: *core.JSRuntime, base: [*]core.JSValue, sp: *[*]core.JSValue) !void {
    try stackRequire(base, sp.*, 3);
    const a_slot = sp.* - 3;
    const a = a_slot[0];
    a_slot[0] = (sp.* - 2)[0];
    (sp.* - 2)[0] = (sp.* - 1)[0];
    sp.* -= 1;
    a.free(rt);
}

inline fn insert2Window(base: [*]core.JSValue, sp: *[*]core.JSValue) !void {
    try stackRequire(base, sp.*, 2);
    const a = (sp.* - 2)[0];
    const b = (sp.* - 1)[0];
    (sp.* - 2)[0] = borrowedValueFast(b);
    (sp.* - 1)[0] = a;
    sp.*[0] = b;
    sp.* += 1;
}

inline fn insert3Window(base: [*]core.JSValue, sp: *[*]core.JSValue) !void {
    try stackRequire(base, sp.*, 3);
    const a = (sp.* - 3)[0];
    const b = (sp.* - 2)[0];
    const c = (sp.* - 1)[0];
    (sp.* - 3)[0] = borrowedValueFast(c);
    (sp.* - 2)[0] = a;
    (sp.* - 1)[0] = b;
    sp.*[0] = c;
    sp.* += 1;
}

inline fn insert4Window(base: [*]core.JSValue, sp: *[*]core.JSValue) !void {
    try stackRequire(base, sp.*, 4);
    const a = (sp.* - 4)[0];
    const b = (sp.* - 3)[0];
    const c = (sp.* - 2)[0];
    const d = (sp.* - 1)[0];
    (sp.* - 4)[0] = borrowedValueFast(d);
    (sp.* - 3)[0] = a;
    (sp.* - 2)[0] = b;
    (sp.* - 1)[0] = c;
    sp.*[0] = d;
    sp.* += 1;
}

inline fn rot3lWindow(base: [*]core.JSValue, sp: [*]core.JSValue) !void {
    try stackRequire(base, sp, 3);
    const a = (sp - 3)[0];
    (sp - 3)[0] = (sp - 2)[0];
    (sp - 2)[0] = (sp - 1)[0];
    (sp - 1)[0] = a;
}

inline fn rot3rWindow(base: [*]core.JSValue, sp: [*]core.JSValue) !void {
    try stackRequire(base, sp, 3);
    const c = (sp - 1)[0];
    (sp - 1)[0] = (sp - 2)[0];
    (sp - 2)[0] = (sp - 3)[0];
    (sp - 3)[0] = c;
}

inline fn rot4lWindow(base: [*]core.JSValue, sp: [*]core.JSValue) !void {
    try stackRequire(base, sp, 4);
    const a = (sp - 4)[0];
    (sp - 4)[0] = (sp - 3)[0];
    (sp - 3)[0] = (sp - 2)[0];
    (sp - 2)[0] = (sp - 1)[0];
    (sp - 1)[0] = a;
}

inline fn rot5lWindow(base: [*]core.JSValue, sp: [*]core.JSValue) !void {
    try stackRequire(base, sp, 5);
    const a = (sp - 5)[0];
    (sp - 5)[0] = (sp - 4)[0];
    (sp - 4)[0] = (sp - 3)[0];
    (sp - 3)[0] = (sp - 2)[0];
    (sp - 2)[0] = (sp - 1)[0];
    (sp - 1)[0] = a;
}

inline fn perm3Window(base: [*]core.JSValue, sp: [*]core.JSValue) !void {
    try stackRequire(base, sp, 3);
    const a = (sp - 3)[0];
    (sp - 3)[0] = (sp - 2)[0];
    (sp - 2)[0] = a;
}

inline fn perm4Window(base: [*]core.JSValue, sp: [*]core.JSValue) !void {
    try stackRequire(base, sp, 4);
    const a = (sp - 4)[0];
    const b = (sp - 3)[0];
    const c = (sp - 2)[0];
    (sp - 4)[0] = c;
    (sp - 3)[0] = a;
    (sp - 2)[0] = b;
}

inline fn perm5Window(base: [*]core.JSValue, sp: [*]core.JSValue) !void {
    try stackRequire(base, sp, 5);
    const a = (sp - 5)[0];
    const b = (sp - 4)[0];
    const c = (sp - 3)[0];
    const d = (sp - 2)[0];
    (sp - 5)[0] = d;
    (sp - 4)[0] = a;
    (sp - 3)[0] = b;
    (sp - 2)[0] = c;
}

inline fn objectFromValueFast(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

inline fn slotValueBorrowFast(slot: core.JSValue) core.JSValue {
    var current = slot;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const cell = slot_ops.varRefCellFromValue(current) orelse return current;
        current = cell.varRefValue();
    }
    return current;
}

inline fn objectShapePropsFast(object: *const core.Object) []const core.shape.Property {
    return object.shape_ref.props[0..@min(object.shape_ref.prop_count, object.properties.len)];
}

inline fn objectFindPropertyFast(object: *const core.Object, atom_id: core.Atom) ?usize {
    const props = objectShapePropsFast(object);
    const shape = object.shape_ref;
    if (shape.prop_hash_mask != core.shape.no_property_hash and shape.hash_buckets.len != 0) {
        var shape_index = shape.hash_buckets[core.shape.propertyBucketIndex(shape.hash, atom_id, shape.prop_hash_mask)];
        var steps: usize = 0;
        while (shape_index != core.shape.no_property_index and steps < shape.prop_count) : (steps += 1) {
            const index: usize = @intCast(shape_index);
            if (index >= shape.prop_count) break;
            shape_index = shape.props[index].hash_next;
            if (index >= props.len) continue;
            const prop = props[index];
            if (prop.atom_id == atom_id and !core.property.Flags.fromBits(prop.flags).deleted) return index;
        }
        return null;
    }
    for (props, 0..) |prop, index| {
        if (prop.atom_id == atom_id and !core.property.Flags.fromBits(prop.flags).deleted) return index;
    }
    return null;
}

inline fn numberToValueFast(value: f64) core.JSValue {
    if (value >= -2147483648 and value <= 2147483647) {
        const int_val: i32 = @intFromFloat(value);
        if (@as(f64, @floatFromInt(int_val)) == value and !std.math.isNegativeZero(value)) {
            return core.JSValue.int32(int_val);
        }
    }
    return core.JSValue.float64(value);
}

inline fn fastInt32AddLocal(lhs: i32, rhs: i32) core.JSValue {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return numberToValueFast(@as(f64, @floatFromInt(lhs)) + @as(f64, @floatFromInt(rhs)));
}

inline fn fastInt32SubLocal(lhs: i32, rhs: i32) core.JSValue {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return numberToValueFast(@as(f64, @floatFromInt(lhs)) - @as(f64, @floatFromInt(rhs)));
}

inline fn fastInt32MulLocal(lhs: i32, rhs: i32) core.JSValue {
    if ((lhs == 0 and rhs < 0) or (rhs == 0 and lhs < 0)) return core.JSValue.float64(-0.0);
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return numberToValueFast(@as(f64, @floatFromInt(lhs)) * @as(f64, @floatFromInt(rhs)));
}

inline fn fastInt32ModLocal(lhs: i32, rhs: i32) core.JSValue {
    if (rhs == 0) return core.JSValue.float64(std.math.nan(f64));
    if (rhs == -1) return if (lhs < 0) core.JSValue.float64(-0.0) else core.JSValue.int32(0);
    const result = @rem(lhs, rhs);
    if (result == 0 and lhs < 0) return core.JSValue.float64(-0.0);
    return core.JSValue.int32(result);
}

inline fn fastBinaryInt32Local(binop: u8, lhs: i32, rhs: i32) ?core.JSValue {
    return switch (binop) {
        op.add => fastInt32AddLocal(lhs, rhs),
        op.sub => fastInt32SubLocal(lhs, rhs),
        op.mul => fastInt32MulLocal(lhs, rhs),
        op.div => numberToValueFast(@as(f64, @floatFromInt(lhs)) / @as(f64, @floatFromInt(rhs))),
        op.mod => fastInt32ModLocal(lhs, rhs),
        op.shl => core.JSValue.int32(lhs << @intCast(rhs & 31)),
        op.sar => core.JSValue.int32(lhs >> @intCast(rhs & 31)),
        op.shr => numberToValueFast(@floatFromInt(@as(u32, @bitCast(lhs)) >> @intCast(rhs & 31))),
        op.@"and" => core.JSValue.int32(lhs & rhs),
        op.@"or" => core.JSValue.int32(lhs | rhs),
        op.xor => core.JSValue.int32(lhs ^ rhs),
        else => null,
    };
}

inline fn tryFastPutLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    var_buf: [*]core.JSValue,
    base: [*]core.JSValue,
    sp: *[*]core.JSValue,
    idx: usize,
) bool {
    if (!stackHas(base, sp.*, 1)) return false;
    const value = (sp.* - 1)[0];
    const old_value = var_buf[idx];
    if (!plainLocalSlotFastPath(function, idx, old_value, value)) return false;

    // Move the owned stack slot into the local, matching execPutLoc -> setSlotValue
    // for a plain local slot. The stack slot is consumed by shrinking the slice.
    var_buf[idx] = value;
    sp.* -= 1;
    old_value.free(ctx.runtime);
    return true;
}

inline fn tryFastSetLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    var_buf: [*]core.JSValue,
    base: [*]core.JSValue,
    sp: *const [*]core.JSValue,
    idx: usize,
) bool {
    if (!stackHas(base, sp.*, 1)) return false;
    const value = (sp.* - 1)[0];
    const old_value = var_buf[idx];
    if (!plainLocalSlotFastPath(function, idx, old_value, value)) return false;

    var_buf[idx] = if (value.requiresRefCount()) value.dup() else value;
    old_value.free(ctx.runtime);
    return true;
}

inline fn tryFastGetField(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    base: [*]core.JSValue,
    sp: *const [*]core.JSValue,
    atom_id: core.Atom,
) bool {
    _ = stack;
    if (!stackHas(base, sp.*, 1)) return false;
    const receiver_slot = sp.* - 1;
    const receiver = receiver_slot[0];
    const value = vm_property_field.qjsGetFieldFast(ctx.runtime, receiver, atom_id) orelse return false;
    receiver_slot[0] = if (value.requiresRefCount()) value.dup() else value;
    receiver.free(ctx.runtime);
    return true;
}

inline fn tryFastGetField2(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    base: [*]core.JSValue,
    sp: *[*]core.JSValue,
    atom_id: core.Atom,
) bool {
    if (!stackHas(base, sp.*, 1)) return false;
    const receiver = (sp.* - 1)[0];
    const value = vm_property_field.qjsGetFieldFast(ctx.runtime, receiver, atom_id) orelse return false;
    pushBorrowedWindow(stack, base, sp, value);
    return true;
}

inline fn tryFastPutField(
    ctx: *core.JSContext,
    base: [*]core.JSValue,
    sp: *[*]core.JSValue,
    atom_id: core.Atom,
) bool {
    if (!stackHas(base, sp.*, 2)) return false;
    const value_slot = sp.* - 1;
    const obj_slot = sp.* - 2;
    const value = value_slot[0];
    const obj = obj_slot[0];
    if (ctx.runtime.atoms.kind(atom_id) == .private) return false;
    if (value.requiresRefCount()) return false;
    const object = objectFromValueFast(obj) orelse return false;
    if (object.flags.is_borrowed_reference_holder) return false;
    if (object.flags.is_proxy or object.class_payload_kind == .proxy or object.hasExoticMethods()) return false;
    if (object.flags.is_array) return false;
    if (object.class_payload_kind == .typed_array) return false;
    if (object.class_id == core.class.ids.regexp and atom_id == core.atom.ids.lastIndex and object.regexpLastIndex() != null) return false;
    if (object.class_id == core.class.ids.module_ns or object.class_id == core.class.ids.mapped_arguments) return false;
    const index = objectFindPropertyFast(object, atom_id) orelse return false;
    const flags = object.propFlagsAt(index);
    if (!flags.writable or flags.accessor) return false;
    const entry = &object.properties[index];
    switch (entry.slot) {
        .data => |old_value| {
            if (old_value.requiresRefCount()) return false;
            entry.slot = .{ .data = value };
        },
        .auto_init, .accessor, .deleted => return false,
    }

    sp.* = obj_slot;
    obj.free(ctx.runtime);
    value.free(ctx.runtime);
    return true;
}

inline fn fastDenseArrayElementValueLocal(value: core.JSValue, key: core.JSValue) ?core.JSValue {
    const index_i32 = key.asInt32() orelse return null;
    if (index_i32 < 0) return null;
    const object = objectFromValueFast(value) orelse return null;
    const index: u32 = @intCast(index_i32);
    return object.fastArrayElementDup(index);
}

inline fn tryFastGetArrayEl(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    base: [*]core.JSValue,
    sp: *[*]core.JSValue,
) bool {
    if (!stackHas(base, sp.*, 2)) return false;
    const key_slot = sp.* - 1;
    const obj_slot = sp.* - 2;
    const key = key_slot[0];
    const obj = obj_slot[0];
    const value = fastDenseArrayElementValueLocal(obj, key) orelse return false;

    sp.* = obj_slot;
    pushOwnedWindow(stack, base, sp, value);
    obj.free(ctx.runtime);
    key.free(ctx.runtime);
    return true;
}

inline fn tryFastGetArrayEl2(
    ctx: *core.JSContext,
    base: [*]core.JSValue,
    sp: *const [*]core.JSValue,
) bool {
    if (!stackHas(base, sp.*, 2)) return false;
    const key_slot = sp.* - 1;
    const key = key_slot[0];
    const obj = (sp.* - 2)[0];
    const value = fastDenseArrayElementValueLocal(obj, key) orelse return false;

    key_slot[0] = value;
    key.free(ctx.runtime);
    return true;
}

inline fn fastPutDenseArrayExistingIntIndexLocal(rt: *core.JSRuntime, obj: core.JSValue, key: core.JSValue, value: core.JSValue) bool {
    const index_i32 = key.asInt32() orelse return false;
    if (index_i32 < 0 or index_i32 > core.array.max_array_index) return false;
    const object = objectFromValueFast(obj) orelse return false;
    const index: u32 = @intCast(index_i32);
    return object.setFastArrayElementDup(rt, index, value);
}

inline fn tryFastPutArrayEl(
    ctx: *core.JSContext,
    base: [*]core.JSValue,
    sp: *[*]core.JSValue,
) bool {
    if (!stackHas(base, sp.*, 3)) return false;
    const value_slot = sp.* - 1;
    const key_slot = sp.* - 2;
    const obj_slot = sp.* - 3;
    const value = value_slot[0];
    const key = key_slot[0];
    const obj = obj_slot[0];
    if (!fastPutDenseArrayExistingIntIndexLocal(ctx.runtime, obj, key, value)) return false;

    sp.* = obj_slot;
    obj.free(ctx.runtime);
    key.free(ctx.runtime);
    value.free(ctx.runtime);
    return true;
}

inline fn tryInt32BinaryPtr(base: [*]core.JSValue, sp: *[*]core.JSValue, binop: u8) bool {
    if (!stackHas(base, sp.*, 2)) return false;
    const rhs_slot = sp.* - 1;
    const lhs_slot = sp.* - 2;
    const lhs_int = lhs_slot[0].asInt32() orelse return false;
    const rhs_int = rhs_slot[0].asInt32() orelse return false;
    const result = fastBinaryInt32Local(binop, lhs_int, rhs_int) orelse return false;
    lhs_slot[0] = result;
    sp.* = rhs_slot;
    return true;
}

inline fn tryInt32ComparePtr(base: [*]core.JSValue, sp: *[*]core.JSValue, cmp: u8) bool {
    if (!stackHas(base, sp.*, 2)) return false;
    const rhs_slot = sp.* - 1;
    const lhs_slot = sp.* - 2;
    const lhs_int = lhs_slot[0].asInt32() orelse return false;
    const rhs_int = rhs_slot[0].asInt32() orelse return false;
    const result = switch (cmp) {
        op.lt => lhs_int < rhs_int,
        op.lte => lhs_int <= rhs_int,
        op.gt => lhs_int > rhs_int,
        op.gte => lhs_int >= rhs_int,
        op.eq, op.strict_eq => lhs_int == rhs_int,
        op.neq, op.strict_neq => lhs_int != rhs_int,
        else => return false,
    };
    lhs_slot[0] = core.JSValue.boolean(result);
    sp.* = rhs_slot;
    return true;
}

/// Frame-setup wrapper that runs a NORMAL-kind bytecode function through the
/// recursive `dispatchRecursive`. Mirrors `runWithArgsState`'s setup (lines
/// 294-339) minus the inline-`Machine` loop and the generator/eval-code state,
/// which never apply to a normal-kind callee (`resumeExecutionState` /
/// `completeResumeState` are no-ops when `generator_state == null`, returning an
/// empty resume state and a null catch target). Nested JS→JS calls recurse
/// natively because the call opcodes run with `allow_inline=false`, routing back
/// through `callFunctionBytecodeModeState` → `callInternal`. Gated to
/// `recursive_dispatch_enabled` from `callFunctionBytecodeModeState`.
pub fn callInternal(
    ctx: *core.JSContext,
    entry_stack: *stack_mod.Stack,
    entry_function: *const bytecode.Bytecode,
    initial_this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    input_eval_var_ref_names: []const core.Atom,
    input_eval_var_refs: []const core.JSValue,
    current_function_value: core.JSValue,
    new_target_value: core.JSValue,
    constructor_this_value: core.JSValue,
) HostError!core.JSValue {
    const call_depth_guard = try call_vm.enterCallDepth(ctx, global);
    defer call_depth_guard.deinit();
    const call_profile_guard = call_vm.enterCallProfile(ctx.runtime);
    defer call_profile_guard.deinit();
    try ctx.pushBacktraceFrameLazyName(entry_function.name, entry_function.filename, entry_function.line_num, entry_function.col_num, entry_function, exception_ops.resolveBacktraceLocation, current_function_value);
    defer ctx.popBacktraceFrame();

    // Frame storage (locals/args/var_refs) is carved from the VM stack arena;
    // reclaim the watermark after the frame has released its values.
    const frame_arena_mark = ctx.runtime.vm_stack.mark();
    defer ctx.runtime.vm_stack.restore(frame_arena_mark);

    var frame_storage = frame_mod.Frame.init(entry_function);
    ctx.borrowBacktracePc(&frame_storage.pc);
    defer frame_storage.deinit(&ctx.runtime.memory, ctx.runtime);
    var frame_eval_var_refs = try frame_storage.initCallBindings(ctx.runtime, .{
        .initial_this_value = initial_this_value,
        .current_function_value = current_function_value,
        .new_target_value = new_target_value,
        .constructor_this_value = constructor_this_value,
        .eval_local_names = &.{},
        .eval_local_slots = &.{},
        .input_eval_var_ref_names = input_eval_var_ref_names,
        .input_eval_var_refs = input_eval_var_refs,
        .inherited_eval_local_names = &.{},
        .inherited_eval_local_slots = &.{},
        .inherited_eval_var_ref_names = &.{},
        .inherited_eval_var_refs = &.{},
    });
    defer frame_eval_var_refs.deinit(ctx.runtime);

    var frame_roots = frame_mod.FrameRootScope{};
    frame_roots.init(ctx.runtime, entry_stack, &frame_storage, &frame_eval_var_refs);
    defer frame_roots.deinit();

    const use_inline_frame_storage = !entry_function.flags.is_generator and !entry_function.flags.is_async;
    const frame_arena: ?*core.VmStackArena = if (use_inline_frame_storage) &ctx.runtime.vm_stack else null;
    try call_vm.initFrameLocals(ctx, entry_function, &frame_storage, &.{}, &.{}, use_inline_frame_storage);
    try frame_storage.initArguments(&ctx.runtime.memory, frame_arena, args, use_inline_frame_storage, frame_mod.argumentsNeedsOriginalSnapshot(entry_function));
    try call_vm.initFrameVarRefs(ctx, global, entry_function, &frame_storage, var_refs, use_inline_frame_storage);

    try reserveEntryFrameCapacity(entry_stack, entry_function);
    errdefer call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, entry_stack, &frame_storage);

    // Slow-path entry: not a trampoline, so pass allow_tail_signal=false (a tail
    // call recurses through recurseInlineCall, which IS a trampoline — so the
    // callee's own tail chain is still TCO'd; only this single frame adds one
    // native level). dispatchRecursive therefore never yields `.tail` here.
    return switch (try dispatchRecursive(ctx, entry_function, global, &frame_storage, entry_stack, output, false)) {
        .returned => |value| value,
        .tail => unreachable,
    };
}

fn reserveEntryFrameCapacity(entry_stack: *stack_mod.Stack, entry_function: *const bytecode.Bytecode) !void {
    const frame_stack_size: usize = if (comptime builtin.mode == .Debug)
        // Some colocated tests hand-build bytecode without finalize's stack-size
        // pass; keep those Debug-only fixtures checked at entry. ReleaseFast
        // relies on finalized bytecode's verified stack_size.
        if (entry_function.stack_size == 0 and entry_function.code.len != 0)
            entry_function.code.len
        else
            entry_function.stack_size
    else
        entry_function.stack_size;
    try entry_stack.reserveFrameCapacity(frame_stack_size);
}

/// Result of running an inline-eligible callee via native recursion.
pub const RecurseOutcome = union(enum) {
    /// The callee returned `value` (owned by the caller). A regular call pushes
    /// it onto the operand stack; a tail call returns it as its own result.
    value: core.JSValue,
    /// The callee threw and THIS (caller) frame caught it — `frame.pc` is the
    /// catch target. The caller continues its dispatch loop.
    caught,
};

/// What a single `dispatchRecursive` frame produced. Returned to the caller's
/// trampoline (`recurseInlineCall`) so a proper tail call can REUSE the native
/// frame (constant stack depth) instead of recursing — the TCO trampoline.
pub const Outcome = union(enum) {
    /// The frame ran to a `return` / fall-off; `value` is owned by the caller.
    returned: core.JSValue,
    /// The frame hit a proper tail call; the trampoline tears this frame down
    /// and re-enters with `request`'s target (the call region is still live on
    /// the just-finished frame's operand stack). Only produced when the caller
    /// passed `allow_tail_signal = true`.
    tail: call_runtime.InlineCallRequest,
};

/// Run an inline-eligible bytecode call (`request`, resolved by
/// `resolveInlineTarget`) as a NATIVE Zig recursion into `dispatchRecursive`,
/// reusing the Machine's zero-copy frame setup (`setupInlineEntry`) — this is
/// the S2a pivot replacing `machine.pushCall`. Native depth is bounded by
/// `enterCallDepth` (catchable RangeError before stack overflow). On a callee
/// error, the error is routed through the CURRENT frame's catch handler
/// (mirroring `Machine.unwindForError` one level): caught → `.caught`,
/// otherwise the error propagates (the caller frame's own recursion catch / the
/// top-level handles it). NOTE (S2a-v1): no TCO trampoline yet — a tail call
/// recurses like a regular call (deep tail recursion is bounded by the native
/// depth cap, same limitation as S1; the trampoline is S2a-v2).
pub fn recurseInlineCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_stack: *stack_mod.Stack,
    caller_frame: *frame_mod.Frame,
    caller_catch_target: *?usize,
    request: call_runtime.InlineCallRequest,
) HostError!RecurseOutcome {
    const source: inline_calls.Machine.ArgsSource = switch (request.layout) {
        .plain, .method => .{ .stack_region = .{
            .stack = caller_stack,
            .region_base = request.region_base,
            .argc = request.argc,
            .has_receiver = request.layout == .method,
        } },
        .prepared => .{ .prepared = .{
            .stack = caller_stack,
            .region_base = request.region_base,
            .argc = request.argc,
        } },
    };

    const depth_guard = call_vm.enterCallDepth(ctx, global) catch |err| {
        return routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
    };
    defer depth_guard.deinit();

    var entry: inline_calls.Entry = undefined;
    inline_calls.Machine.setupInlineEntry(ctx, global, &entry, request.target, source) catch |err| {
        return routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
    };
    // setupInlineEntry has consumed (popped + freed) the call region from
    // caller_stack; `entry` owns the new frame/stack carved from the arena.
    // TCO TRAMPOLINE: a proper tail call from the running frame replaces `entry`
    // in place (reusing the native frame + the held depth slot = constant native
    // stack depth), instead of recursing — so 100k strict tail calls don't blow
    // the C stack. Mirrors inline_calls.Machine.tailCallReuse.
    while (true) {
        const outcome = dispatchRecursive(ctx, &entry.view, global, &entry.frame, &entry.stack, output, true) catch |err| {
            call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, &entry.stack, &entry.frame);
            inline_calls.Machine.teardownInlineEntry(ctx, &entry);
            return routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
        };
        switch (outcome) {
            .returned => |result| {
                inline_calls.Machine.teardownInlineEntry(ctx, &entry);
                return .{ .value = result };
            },
            .tail => |tail_req| {
                // Tail call region [callable,args] (or [recv,callable,args] for a
                // method tail call) is still live on the just-finished frame's
                // operand stack. Move it out before tearing the frame down, then
                // re-enter with the tail target.
                const has_receiver = tail_req.layout == .method;
                const total = @as(usize, tail_req.argc) + 1 + @as(usize, @intFromBool(has_receiver));
                var inline_buf: [10]core.JSValue = undefined;
                const moved: []core.JSValue = if (total <= inline_buf.len)
                    inline_buf[0..total]
                else
                    try ctx.runtime.memory.alloc(core.JSValue, total);
                defer if (total > inline_buf.len) ctx.runtime.memory.free(core.JSValue, moved);
                @memcpy(moved, entry.stack.values[tail_req.region_base..][0..total]);
                entry.stack.values = entry.stack.values.ptr[0..tail_req.region_base];
                // `moved` now owns the region; free whatever setupInlineEntry does
                // not transfer (transferred slots are nulled to undefined).
                defer for (moved) |v| v.free(ctx.runtime);
                inline_calls.Machine.teardownInlineEntry(ctx, &entry);
                inline_calls.Machine.setupInlineEntry(ctx, global, &entry, tail_req.target, .{ .moved = .{ .values = moved, .has_receiver = has_receiver } }) catch |err| {
                    return routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
                };
                // loop: re-run dispatchRecursive on the reused frame.
            },
        }
    }
}

/// Shared error-unwind for `recurseInlineCall`: close any pending for-of
/// iterator on the caller stack, then try the caller frame's catch handler.
/// Returns `.caught` when handled (caller resumes at `frame.pc`), else the
/// error propagates. Mirrors the `catch` legs of the dispatch-loop call arms.
pub fn routeCalleeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_stack: *stack_mod.Stack,
    caller_frame: *frame_mod.Frame,
    caller_catch_target: *?usize,
    err: HostError,
) HostError!RecurseOutcome {
    try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, caller_stack);
    if (try call_runtime.handleCatchableRuntimeError(ctx, caller_stack, caller_frame, caller_catch_target, global, err)) {
        return .caught;
    }
    return err;
}

pub fn dispatchRecursive(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    output: ?*std.Io.Writer,
    // When true (the recurseInlineCall trampoline), a proper tail call returns
    // `.tail` so the trampoline reuses the native frame (TCO). When false (the
    // callInternal slow-path entry, which is not a trampoline), a tail call
    // recurses like a regular call (one extra native frame, then the callee's
    // own trampoline TCOs its tail calls).
    allow_tail_signal: bool,
) HostError!Outcome {
    const code = function.code;
    // STEP 2: single incrementing instruction pointer (qjs `*pc++`). `code_base`
    // is a loop-invariant the optimizer can keep in a callee-saved register; `ip`
    // is the only live bytecode state on the hot path, so the per-opcode reload of
    // the bytecode base from spill (`ldr [sp,#256]`) disappears.
    const code_end: [*]const u8 = code.ptr + code.len;
    var ip: [*]const u8 = code.ptr + frame.pc;
    var catch_target_storage: ?usize = null;
    const catch_target: *?usize = &catch_target_storage;
    // Loops are made interruptible by polling on backward jumps (mirroring
    // QuickJS's backward-branch poll); the straight-line path stays poll-free.
    var interrupt_poller = control_vm.InterruptPoller.init(ctx.runtime);
    // S2a-v3 heap fallback: this frame's native depth is fixed for its lifetime
    // (sub-calls increment then restore it), so decide ONCE whether to inline
    // (native recurse) or hand calls to the slow heap path. Near the native cap,
    // a call goes slow → callFunctionBytecodeModeState routes it to the Machine.
    const allow_inline_calls = !call_vm.nativeDepthNearCap(ctx);
    var base: [*]core.JSValue = stack.values.ptr;
    var sp: [*]core.JSValue = stack.values.ptr + stack.values.len;
    var var_buf: [*]core.JSValue = frame.locals.ptr;
    var arg_buf: [*]core.JSValue = frame.args.ptr;
    // The operand-stack GC root stays `.mutable = &stack.values` for this whole
    // frame (set by FrameRootScope.init). We publish the live `sp` at every
    // cold-arm boundary, and once more here on any exit path, so `stack.values`
    // is in sync whenever the GC or the caller can observe the operand stack.
    defer publishStackWindow(stack, base, sp);
    while (true) {
        // Fall-off-end check, now in POINTER form (`ip == code_end`) using the
        // loop-invariant `code_end` pointer instead of `pc >= code.len` (which
        // recomputed `code.len` from the spilled slice header each opcode →
        // `ldr [sp,#248]`). Comparing two pointers lets LLVM keep `code_end` in a
        // register / rematerialize it as `code_base + const`, so the per-opcode
        // memory reload of the bytecode end disappears while the rare fall-off-end
        // path (some bodies end without an explicit return opcode) stays correct.
        if (ip == code_end) {
            frame.pc = ipOff(ip, function.code.ptr);
            const value = if (sp == base)
                core.JSValue.undefinedValue()
            else
                (if ((sp - 1)[0].requiresRefCount()) (sp - 1)[0].dup() else (sp - 1)[0]);
            return .{ .returned = try control_vm.finishFunctionReturn(ctx, frame, value) };
        }
        sw: switch (ip[0]) {
            // ===================================================================
            // Pushes that decode an immediate operand (INLINE on C-local pc)
            // ===================================================================
            // Immediate pushes use assumeCapacity: every push is counted in the
            // verifier's stack_size and the frame stack is presized to stack_size+1
            // (reserveEntryFrameCapacity), so the bounds check is redundant — mirrors
            // qjs's bare `*sp++` and the get_loc inline above.
            op.push_i32 => {
                ip += 1;
                const v = readInt(i32, ip[0..4]);
                ip += 4;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(v));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_i16 => {
                ip += 1;
                const v: i32 = readInt(i16, ip[0..2]);
                ip += 2;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(v));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_i8 => {
                ip += 1;
                const v: i32 = @as(i8, @bitCast(ip[0]));
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(v));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_bigint_i32 => {
                ip += 1;
                const v = readInt(i32, ip[0..4]);
                ip += 4;
                pushOwnedWindow(stack, base, &sp, core.JSValue.shortBigInt(v));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ---- Small-int / literal pushes (no operand; plain unfused push) ----
            op.push_minus1 => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(-1));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_0 => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(0));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_1 => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(1));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_2 => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(2));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_3 => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(3));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_4 => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(4));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_5 => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(5));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_6 => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(6));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_7 => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(7));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.undefined => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.undefinedValue());
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.null => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.nullValue());
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_false => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.boolean(false));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_true => {
                ip += 1;
                pushOwnedWindow(stack, base, &sp, core.JSValue.boolean(true));
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ---- Constant-table / atom pushes (DELEGATE: operand decode + fusion) ----
            op.push_const => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try value_vm.pushConst(ctx, stack, function, frame, opc);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_const8 => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try value_vm.pushConst8(ctx, stack, function, frame, opc);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_atom_value => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try value_vm.pushAtomValue(ctx, stack, function, frame);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_empty_string => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try value_vm.pushEmptyString(ctx, stack);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.private_symbol => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try value_vm.pushPrivateSymbol(ctx, stack, function, frame);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.regexp => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try regexp_vm.pushLiteral(ctx, stack, class_vm.constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"));
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.fclosure, op.fclosure8 => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try call_vm.closure(ctx, output, global, stack, function, frame, catch_target, opc, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ===================================================================
            // Stack manipulation (DELEGATE; pure-stack, no operand)
            // ===================================================================
            op.drop => {
                ip += 1;
                // Fast path: a plain (non catch-marker) top is popped + freed inline
                // (free is a no-op for ints). Catch markers carry the try-region target
                // and delegate to the full handler.
                if (sp == base) return error.StackUnderflow;
                const top = (sp - 1)[0];
                if (top.isCatchOffset()) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    switch (try value_vm.drop(ctx.runtime, stack)) {
                        .value => {},
                        .catch_target => |target| {
                            catch_target.* = target;
                            ip = function.code.ptr + frame.pc;
                            if (ip == code_end) continue;
                            continue :sw ip[0];
                        },
                    }
                    ip = function.code.ptr + frame.pc;
                } else {
                    sp -= 1;
                    top.free(ctx.runtime);
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.nip_catch => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try value_vm.nipCatch(ctx.runtime, stack);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.nip => {
                ip += 1;
                try nipWindow(ctx.runtime, base, &sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.nip1 => {
                ip += 1;
                try nip1Window(ctx.runtime, base, &sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.dup => {
                ip += 1;
                try dupWindow(stack, base, &sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.dup1 => {
                ip += 1;
                try dup1Window(base, &sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.dup2 => {
                ip += 1;
                try dup2Window(base, &sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.dup3 => {
                ip += 1;
                try dup3Window(base, &sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.swap => {
                ip += 1;
                try swapWindow(base, sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.swap2 => {
                ip += 1;
                try swap2Window(base, sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.insert2 => {
                ip += 1;
                try insert2Window(base, &sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.insert3 => {
                ip += 1;
                try insert3Window(base, &sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.insert4 => {
                ip += 1;
                try insert4Window(base, &sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.perm3 => {
                ip += 1;
                try perm3Window(base, sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.perm4 => {
                ip += 1;
                try perm4Window(base, sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.perm5 => {
                ip += 1;
                try perm5Window(base, sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.rot3l => {
                ip += 1;
                try rot3lWindow(base, sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.rot3r => {
                ip += 1;
                try rot3rWindow(base, sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.rot4l => {
                ip += 1;
                try rot4lWindow(base, sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.rot5l => {
                ip += 1;
                try rot5lWindow(base, sp);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ===================================================================
            // Locals / args / var-refs (all DELEGATE; operand decode in handler)
            // ===================================================================
            // S2b: hot local GETs inline the leaned body directly — skip the `loc`
            // dispatcher (its per-op switch + the comptime-gated fusion scans) AND the
            // execGetLoc call AND the frame.pc round-trip. GC-free (presized-stack
            // assumeCapacity push + a verifier-trusted var_buf[idx] read, no bounds
            // check), so no frame.pc publish is needed. This is the #1 crypto opcode.
            op.get_loc0 => {
                ip += 1;
                pushSlotWindow(stack, base, &sp, var_buf[0]);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_loc1 => {
                ip += 1;
                pushSlotWindow(stack, base, &sp, var_buf[1]);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_loc2 => {
                ip += 1;
                pushSlotWindow(stack, base, &sp, var_buf[2]);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_loc3 => {
                ip += 1;
                pushSlotWindow(stack, base, &sp, var_buf[3]);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_loc8 => {
                ip += 1;
                const idx = ip[0];
                ip += 1;
                pushSlotWindow(stack, base, &sp, var_buf[idx]);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_loc => {
                ip += 1;
                const idx = readInt(u16, ip[0..2]);
                ip += 2;
                pushSlotWindow(stack, base, &sp, var_buf[idx]);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_loc => |opc| {
                ip += 1;
                const idx = readInt(u16, ip[0..2]);
                if (tryFastPutLoc(ctx, function, var_buf, base, &sp, idx)) {
                    ip += 2;
                } else {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.set_loc => |opc| {
                ip += 1;
                const idx = readInt(u16, ip[0..2]);
                if (tryFastSetLoc(ctx, function, var_buf, base, &sp, idx)) {
                    ip += 2;
                } else {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_loc8 => |opc| {
                ip += 1;
                const idx = ip[0];
                if (tryFastPutLoc(ctx, function, var_buf, base, &sp, idx)) {
                    ip += 1;
                } else {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.set_loc8 => |opc| {
                ip += 1;
                const idx = ip[0];
                if (tryFastSetLoc(ctx, function, var_buf, base, &sp, idx)) {
                    ip += 1;
                } else {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.set_loc0 => |opc| {
                ip += 1;
                if (!tryFastSetLoc(ctx, function, var_buf, base, &sp, 0)) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.set_loc1 => |opc| {
                ip += 1;
                if (!tryFastSetLoc(ctx, function, var_buf, base, &sp, 1)) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.set_loc2 => |opc| {
                ip += 1;
                if (!tryFastSetLoc(ctx, function, var_buf, base, &sp, 2)) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.set_loc3 => |opc| {
                ip += 1;
                if (!tryFastSetLoc(ctx, function, var_buf, base, &sp, 3)) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_loc0_loc1 => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_loc0 => |opc| {
                ip += 1;
                if (!tryFastPutLoc(ctx, function, var_buf, base, &sp, 0)) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try slot_ops.execPutLoc(ctx, function, global, frame, stack, 0, 0, opc, false);
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_loc1 => |opc| {
                ip += 1;
                if (!tryFastPutLoc(ctx, function, var_buf, base, &sp, 1)) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try slot_ops.execPutLoc(ctx, function, global, frame, stack, 1, 0, opc, false);
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_loc2 => |opc| {
                ip += 1;
                if (!tryFastPutLoc(ctx, function, var_buf, base, &sp, 2)) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try slot_ops.execPutLoc(ctx, function, global, frame, stack, 2, 0, opc, false);
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_loc3 => |opc| {
                ip += 1;
                if (!tryFastPutLoc(ctx, function, var_buf, base, &sp, 3)) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    try slot_ops.execPutLoc(ctx, function, global, frame, stack, 3, 0, opc, false);
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            // S2b: hot arg GETs inline the leaned body (skip the `arg` dispatcher + the
            // execGetArg call + frame.pc round-trip). Variadic bound: an arg index past
            // the actual arg count reads undefined (args may be fewer than declared).
            // GC-free presized-stack push, so no frame.pc publish needed.
            op.get_arg0 => {
                ip += 1;
                pushSlotWindow(stack, base, &sp, if (frame.args.len > 0) arg_buf[0] else core.JSValue.undefinedValue());
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_arg1 => {
                ip += 1;
                pushSlotWindow(stack, base, &sp, if (frame.args.len > 1) arg_buf[1] else core.JSValue.undefinedValue());
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_arg2 => {
                ip += 1;
                pushSlotWindow(stack, base, &sp, if (frame.args.len > 2) arg_buf[2] else core.JSValue.undefinedValue());
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_arg3 => {
                ip += 1;
                pushSlotWindow(stack, base, &sp, if (frame.args.len > 3) arg_buf[3] else core.JSValue.undefinedValue());
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_arg => {
                ip += 1;
                const idx = readInt(u16, ip[0..2]);
                ip += 2;
                pushSlotWindow(stack, base, &sp, if (idx < frame.args.len) arg_buf[idx] else core.JSValue.undefinedValue());
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_arg, op.set_arg, op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3, op.set_arg0, op.set_arg1, op.set_arg2, op.set_arg3 => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try vm_property_locals.arg(ctx, function, frame, stack, opc);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_var_ref, op.get_var_ref_check, op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init, op.set_var_ref, op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3, op.put_var_ref0, op.put_var_ref1, op.put_var_ref2, op.put_var_ref3, op.set_var_ref0, op.set_var_ref1, op.set_var_ref2, op.set_var_ref3 => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_locals.varRefVm(ctx, function, global, frame, stack, opc, catch_target, false, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.set_loc_uninitialized, op.get_loc_check, op.put_loc_check, op.put_loc_check_init => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_locals.checkedLocVm(ctx, function, global, frame, stack, opc, catch_target, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.close_loc => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try vm_property_locals.closeLoc(ctx, function, frame);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.make_loc_ref, op.make_arg_ref, op.make_var_ref_ref => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try vm_property_ref.makeSlotRef(ctx, stack, function, frame, opc);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.make_var_ref => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_ref.makeVarRefVm(ctx, output, global, stack, function, frame, catch_target, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ===================================================================
            // Arithmetic / compare / logic (int32 fast path INLINE; slow DELEGATE)
            // ===================================================================
            op.add, op.sub, op.mul, op.div, op.mod, op.pow, op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor => |opc| {
                ip += 1;
                if (opc != op.pow and tryInt32BinaryPtr(base, &sp, opc)) {
                    if (ip == code_end) continue;
                    continue :sw ip[0];
                }
                {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    switch (try arith_vm.binaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
                        .done => {},
                        .continue_loop => {},
                    }
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq => |opc| {
                ip += 1;
                if (tryInt32ComparePtr(base, &sp, opc)) {
                    if (ip == code_end) continue;
                    continue :sw ip[0];
                }
                {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    switch (try arith_vm.compareVm(ctx, stack, frame, catch_target, opc, output, global)) {
                        .done => {},
                        .continue_loop => {},
                    }
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.neg, op.plus, op.inc, op.dec => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try arith_vm.unaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.not => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try arith_vm.bitNotVm(ctx, stack, frame, catch_target, output, global)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.lnot => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                try value_vm.logicalNot(ctx.runtime, stack);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.post_inc, op.post_dec => |opc| {
                ip += 1;
                // Int32 fast path: leave the old value on the stack and push old±1 on
                // top (mirrors postUpdate's int branch). Overflow folds to float via
                // fastInt32Add. GC-free. Non-int delegates.
                if (sp == base) return error.StackUnderflow;
                const top = (sp - 1)[0];
                if (top.asInt32()) |oi| {
                    const updated = if (opc == op.post_inc) arith_vm.fastInt32Add(oi, 1) else arith_vm.fastInt32Sub(oi, 1);
                    pushOwnedWindow(stack, base, &sp, updated);
                } else {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    switch (try arith_vm.postUpdateVm(ctx, stack, frame, catch_target, opc, output, global)) {
                        .done => {},
                        .continue_loop => {},
                    }
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.inc_loc, op.dec_loc => |opc| {
                ip += 1;
                // Int32 fast path: a local holding an int32 is a plain slot (NOT a
                // var-ref cell — a cell is an object), so update it in place with no
                // dup/free and no global-lexical sync (dispatchRecursive runs only
                // normal-kind frames, which have no top-level global-lexical locals).
                // Overflow folds to a float via fastInt32Add. Anything else (cell,
                // bigint, coercible object) delegates to the full handler.
                const idx = ip[0];
                if (var_buf[idx].asInt32()) |iv| {
                    ip += 1;
                    var_buf[idx] = if (opc == op.inc_loc) arith_vm.fastInt32Add(iv, 1) else arith_vm.fastInt32Sub(iv, 1);
                } else {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    switch (try arith_vm.updateLocalVm(ctx, stack, function, global, frame, catch_target, opc, output, false)) {
                        .done => {},
                        .continue_loop => {},
                    }
                    ip = function.code.ptr + frame.pc;
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.add_loc => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try arith_vm.addLocalVm(ctx, stack, function, global, frame, catch_target, output, false)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.typeof => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                try value_vm.typeOf(ctx, stack);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.typeof_is_undefined => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                try value_vm.typeOfIsUndefined(ctx.runtime, stack);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.typeof_is_function => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                try value_vm.typeOfIsFunction(ctx.runtime, stack);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.is_undefined_or_null => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                try value_vm.isUndefinedOrNull(ctx.runtime, stack);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.is_undefined => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                try value_vm.isUndefined(ctx.runtime, stack);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.is_null => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                try value_vm.isNull(ctx.runtime, stack);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.in, op.instanceof => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try vm_property_field.inOrInstanceof(ctx, output, global, stack, function, frame, catch_target, opc)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.private_in => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try class_vm.privateInVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.delete => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try vm_property_ref.deletePropertyVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.delete_var => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try vm_property_ref.deleteVar(ctx, global, stack, function, frame, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ===================================================================
            // Control flow (jumps/branches INLINE on C-local pc; throw DELEGATE)
            // ===================================================================
            op.goto => {
                ip += 1;
                const operand_pc = ipOff(ip, function.code.ptr);
                const diff = readInt(i32, ip[0..4]);
                ip = function.code.ptr + relativePc(operand_pc, diff);
                if (diff < 0) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    try interrupt_poller.poll(ctx.runtime);
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.goto16 => {
                ip += 1;
                const operand_pc = ipOff(ip, function.code.ptr);
                const diff: i32 = readInt(i16, ip[0..2]);
                ip = function.code.ptr + relativePc(operand_pc, diff);
                if (diff < 0) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    try interrupt_poller.poll(ctx.runtime);
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.goto8 => {
                ip += 1;
                const operand_pc = ipOff(ip, function.code.ptr);
                const diff: i32 = @as(i8, @bitCast(ip[0]));
                ip = function.code.ptr + relativePc(operand_pc, diff);
                if (diff < 0) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    try interrupt_poller.poll(ctx.runtime);
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.if_false, op.if_true => |opc| {
                ip += 1;
                const operand_pc = ipOff(ip, function.code.ptr);
                const diff = readInt(i32, ip[0..4]);
                ip += 4;
                const value = try popWindow(base, &sp);
                defer value.free(ctx.runtime);
                const truthy = value.asBool() orelse value_ops.isTruthy(value);
                const branch_if_true = (opc == op.if_true);
                if (truthy == branch_if_true) {
                    ip = function.code.ptr + relativePc(operand_pc, diff);
                    if (diff < 0) {
                        enterStackBoundary(stack, base, sp);
                        defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                        try interrupt_poller.poll(ctx.runtime);
                    }
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.if_false8, op.if_true8 => |opc| {
                ip += 1;
                const operand_pc = ipOff(ip, function.code.ptr);
                const diff: i32 = @as(i8, @bitCast(ip[0]));
                ip += 1;
                const value = try popWindow(base, &sp);
                defer value.free(ctx.runtime);
                const truthy = value.asBool() orelse value_ops.isTruthy(value);
                const branch_if_true = (opc == op.if_true8);
                if (truthy == branch_if_true) {
                    ip = function.code.ptr + relativePc(operand_pc, diff);
                    if (diff < 0) {
                        enterStackBoundary(stack, base, sp);
                        defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                        try interrupt_poller.poll(ctx.runtime);
                    }
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.gosub => {
                ip += 1;
                const operand_pc = ipOff(ip, function.code.ptr);
                const diff = readInt(i32, ip[0..4]);
                const return_pc = operand_pc + 4;
                if (return_pc > @as(usize, @intCast(std.math.maxInt(i32)))) return error.InvalidBytecode;
                pushOwnedWindow(stack, base, &sp, core.JSValue.int32(@intCast(return_pc)));
                ip = function.code.ptr + relativePc(operand_pc, diff);
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.ret => {
                ip += 1;
                const target = try popWindow(base, &sp);
                defer target.free(ctx.runtime);
                const pc_i32 = target.asInt32() orelse return error.InvalidBytecode;
                if (pc_i32 < 0) return error.InvalidBytecode;
                const target_pc: usize = @intCast(pc_i32);
                if (target_pc >= code.len) return error.InvalidBytecode;
                ip = function.code.ptr + target_pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.nop => {
                ip += 1;
                control_vm.nop();
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ---- Return ----
            op.@"return" => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                return .{ .returned = try control_vm.returnTop(ctx, stack, frame, null) };
            },
            op.return_undef => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                return .{ .returned = try control_vm.returnUndefined(ctx, frame, null) };
            },

            // ---- Throw / catch ----
            op.throw => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try control_vm.throwTop(ctx, output, global, stack, frame, catch_target)) {
                    .handled => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.throw_error => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try control_vm.throwErrorVm(ctx, stack, function, frame, catch_target, global)) {
                    .handled => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.@"catch" => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try control_vm.catchTarget(function, frame, stack, catch_target);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ===================================================================
            // Calls (DELEGATE to the out-of-line recursive call resolution)
            // ===================================================================
            op.call, op.call0, op.call1, op.call2, op.call3 => |opc| {
                ip += 1;
                const argc: u16 = switch (opc) {
                    op.call => blk: {
                        const v = readInt(u16, ip[0..2]);
                        ip += 2;
                        break :blk v;
                    },
                    op.call0 => 0,
                    op.call1 => 1,
                    op.call2 => 2,
                    op.call3 => 3,
                    else => unreachable,
                };
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                // S2a: a plain-bytecode callee runs as a NATIVE recursion via
                // recurseInlineCall (reusing the Machine's zero-copy setup), not the
                // dup-heavy slow path.
                switch (try call_runtime.execCall(ctx, stack, function, frame, catch_target, argc, output, global, allow_inline_calls)) {
                    .done => {},
                    .continue_loop => {
                        ip = function.code.ptr + frame.pc;
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                    .inline_call => |request| switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                        .value => |v| stack.pushOwnedAssumeCapacity(v),
                        .caught => {
                            ip = function.code.ptr + frame.pc;
                            if (ip == code_end) continue;
                            continue :sw ip[0];
                        },
                    },
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.tail_call => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try call_vm.tailCall(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
                    .handled => {
                        ip = function.code.ptr + frame.pc;
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                    .return_value => |value| {
                        return .{ .returned = value };
                    },
                    // Proper tail call. Under a trampoline (allow_tail_signal) signal it
                    // up so the native frame is reused (constant depth). Otherwise (the
                    // callInternal slow-path entry) recurse and return the callee value.
                    .tail_inline => |request| {
                        if (allow_tail_signal) return .{ .tail = request };
                        switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                            .value => |v| return .{ .returned = v },
                            .caught => {
                                ip = function.code.ptr + frame.pc;
                                if (ip == code_end) continue;
                                continue :sw ip[0];
                            },
                        }
                    },
                }
            },
            op.tail_call_method => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try call_vm.tailCallMethod(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
                    .handled => {
                        ip = function.code.ptr + frame.pc;
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                    .return_value => |value| {
                        return .{ .returned = value };
                    },
                    .tail_inline => |request| {
                        if (allow_tail_signal) return .{ .tail = request };
                        switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                            .value => |v| return .{ .returned = v },
                            .caught => {
                                ip = function.code.ptr + frame.pc;
                                if (ip == code_end) continue;
                                continue :sw ip[0];
                            },
                        }
                    },
                }
            },
            op.call_method => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try call_vm.callMethod(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
                    .done => {},
                    .continue_loop => {
                        ip = function.code.ptr + frame.pc;
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                    .inline_call => |request| switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                        .value => |v| stack.pushOwnedAssumeCapacity(v),
                        .caught => {
                            ip = function.code.ptr + frame.pc;
                            if (ip == code_end) continue;
                            continue :sw ip[0];
                        },
                    },
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.call_prepared => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try call_vm.callPrepared(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
                    .done => {},
                    .continue_loop => {
                        ip = function.code.ptr + frame.pc;
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                    .inline_call => |request| switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                        .value => |v| stack.pushOwnedAssumeCapacity(v),
                        .caught => {
                            ip = function.code.ptr + frame.pc;
                            if (ip == code_end) continue;
                            continue :sw ip[0];
                        },
                    },
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.prepare_call_prop_atom => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try call_vm.prepareCallPropAtom(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => {
                        ip = function.code.ptr + frame.pc;
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.call_constructor => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try call_vm.constructor(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => {
                        ip = function.code.ptr + frame.pc;
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.apply => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try call_vm.apply(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => {
                        ip = function.code.ptr + frame.pc;
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.apply_eval => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try eval_module_vm.applyEval(ctx, stack, function, frame, catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag)) {
                    .done => {},
                    .continue_loop => {
                        ip = function.code.ptr + frame.pc;
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.eval => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                // A non-%eval% callee (the identifier `eval` shadowed by a normal
                // function) in tail position yields `.tail_inline` — handle it like a
                // tail call so eval-named tail recursion (test262 tco-non-eval-*) TCOs
                // via the trampoline instead of growing the native stack.
                switch (try eval_module_vm.directEval(ctx, stack, function, frame, catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag, allow_inline_calls)) {
                    .done => {},
                    .continue_loop => {
                        ip = function.code.ptr + frame.pc;
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                    .tail_inline => |request| {
                        if (allow_tail_signal) return .{ .tail = request };
                        switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                            .value => |v| return .{ .returned = v },
                            .caught => {
                                ip = function.code.ptr + frame.pc;
                                if (ip == code_end) continue;
                                continue :sw ip[0];
                            },
                        }
                    },
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.import => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try eval_module_vm.dynamicImport(ctx, output, global, stack, function, frame);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ---- ctor / brand helpers (DELEGATE) ----
            op.check_ctor => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try call_vm.checkCtorVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.check_ctor_return => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try call_vm.checkCtorReturnVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.init_ctor => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try call_vm.initCtorVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.check_brand => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try class_vm.checkBrandVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.add_brand => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                switch (try class_vm.addBrandVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => {},
                }
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ===================================================================
            // Variables / globals / property access (DELEGATE)
            // ===================================================================
            op.get_var, op.get_var_undef => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_globals.getVar(ctx, output, global, stack, function, frame, catch_target, opc, false, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, core.JSValue.undefinedValue());
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_var => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_globals.putVar(ctx, output, global, stack, function, frame, catch_target, function.flags.is_strict or function.flags.runtime_strict, false, false, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, core.JSValue.undefinedValue());
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.check_define_var, op.define_var, op.define_func, op.put_var_init => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_globals.globalDefinition(ctx, global, stack, function, frame, catch_target, opc, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, false, false);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_field, op.get_field2, op.put_field => |opc| {
                ip += 1;
                const atom_id = readInt(u32, ip[0..4]);
                const handled = switch (opc) {
                    op.get_field => tryFastGetField(ctx, stack, base, &sp, atom_id),
                    op.get_field2 => tryFastGetField2(ctx, stack, base, &sp, atom_id),
                    op.put_field => tryFastPutField(ctx, base, &sp, atom_id),
                    else => unreachable,
                };
                if (handled) {
                    ip += 4;
                } else {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    const step = try vm_property_field.field(ctx, output, global, stack, function, frame, catch_target, opc, false);
                    ip = function.code.ptr + frame.pc;
                    switch (step) {
                        .done => {},
                        .continue_loop => {
                            if (ip == code_end) continue;
                            continue :sw ip[0];
                        },
                    }
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_array_el, op.get_array_el2, op.put_array_el => |opc| {
                ip += 1;
                const handled = switch (opc) {
                    op.get_array_el => tryFastGetArrayEl(ctx, stack, base, &sp),
                    op.get_array_el2 => tryFastGetArrayEl2(ctx, base, &sp),
                    op.put_array_el => tryFastPutArrayEl(ctx, base, &sp),
                    else => unreachable,
                };
                if (!handled) {
                    enterStackBoundary(stack, base, sp);
                    defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                    frame.pc = ipOff(ip, function.code.ptr);
                    const step = try vm_property_field.arrayElement(ctx, output, global, stack, function, frame, catch_target, opc);
                    ip = function.code.ptr + frame.pc;
                    switch (step) {
                        .done => {},
                        .continue_loop => {
                            if (ip == code_end) continue;
                            continue :sw ip[0];
                        },
                    }
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.to_propkey => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_field.toPropKeyVm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.to_propkey2 => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_field.toPropKey2Vm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.set_name, op.set_name_computed => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try vm_property_field.setName(ctx, output, global, stack, function, frame, opc);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_ref_value => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_ref.getRefValueVm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_ref_value => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_ref.putRefValueVm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_private_field => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_private.getPrivateFieldVm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_private_field => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_private.putPrivateFieldVm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.define_private_field => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_private.definePrivateFieldVm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ---- with-statement opcodes (a normal function body may contain `with`) ----
            op.with_get_var, op.with_delete_var, op.with_make_ref, op.with_get_ref, op.with_get_ref_undef => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_ref.withGetOrDelete(ctx, output, global, stack, function, frame, catch_target, opc);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.with_put_var => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try vm_property_ref.withPut(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ===================================================================
            // Object / array literals, super, this, iterators (DELEGATE)
            // (define_field / get_super / get_super_value / put_super_value /
            //  get_length appeared in two draft categories — merged here once)
            // ===================================================================
            op.object => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try literal_vm.object(ctx, stack, global);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.array_from => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try literal_vm.arrayFrom(ctx, stack, function, frame, global);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.append => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try literal_vm.appendSpreadValuesVm(ctx, output, global, stack, opc, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.rest => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try literal_vm.rest(ctx, stack, function, frame);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.define_field => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try literal_vm.defineField(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.define_array_el => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try literal_vm.defineArrayEl(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.set_proto => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try literal_vm.setProto(ctx, stack);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.set_home_object => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try class_vm.setHomeObject(ctx, stack);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.copy_data_properties => {
                ip += 1;
                const mask = ip[0];
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try literal_vm.copyDataProperties(ctx, output, global, stack, mask, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.define_method => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try class_vm.defineMethod(ctx, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.define_method_computed => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try class_vm.defineMethodComputed(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.define_class, op.define_class_computed => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try class_vm.defineClass(ctx, output, global, stack, function, frame, catch_target, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, opc == op.define_class_computed);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.special_object => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try literal_vm.specialObject(ctx, stack, function, frame, global, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_super => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try class_vm.getSuper(ctx, stack, frame);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_super_value => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try class_vm.getSuperValue(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.put_super_value => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try class_vm.putSuperValue(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.get_length => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try literal_vm.getLength(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.to_object => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try value_vm.toObjectVm(ctx, stack, frame, catch_target, global);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.push_this => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try value_vm.pushThisVm(ctx, stack, frame, catch_target, global);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.for_of_start, op.for_await_of_start => |opc| {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try iter_vm.forOfStartVm(ctx, output, global, stack, function, frame, catch_target, opc == op.for_await_of_start);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.for_in_start => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try iter_vm.forInStartVm(ctx, output, global, stack, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.iterator_next => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try iter_vm.iteratorNextVm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.iterator_check_object => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try iter_vm.iteratorCheckObjectVm(ctx, stack, frame, catch_target, global);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.iterator_get_value_done => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try iter_vm.iteratorGetValueDoneVm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.iterator_call => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try iter_vm.iteratorCallVm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.for_of_next => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try iter_vm.forOfNextVm(ctx, output, global, stack, function, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.for_in_next => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                try iter_vm.forInNext(ctx, output, global, stack);
                ip = function.code.ptr + frame.pc;
                if (ip == code_end) continue;
                continue :sw ip[0];
            },
            op.iterator_close => {
                ip += 1;
                enterStackBoundary(stack, base, sp);
                defer leaveStackBoundary(stack, &base, &sp, frame, &var_buf, &arg_buf);
                frame.pc = ipOff(ip, function.code.ptr);
                const step = try iter_vm.iteratorCloseVm(ctx, output, global, stack, frame, catch_target);
                ip = function.code.ptr + frame.pc;
                switch (step) {
                    .done => {},
                    .continue_loop => {
                        if (ip == code_end) continue;
                        continue :sw ip[0];
                    },
                }
                if (ip == code_end) continue;
                continue :sw ip[0];
            },

            // ===================================================================
            // Generator / async opcodes: a normal-kind frame never executes these
            // ===================================================================
            op.initial_yield, op.yield, op.yield_star, op.async_yield_star, op.await, op.return_async => @panic("dispatchRecursive: generator opcode in normal frame"),

            // ===================================================================
            // Invalid / unknown
            // ===================================================================
            op.invalid => return error.InvalidBytecode,
            else => unreachable,
        }
    }
}

comptime {
    if (recursive_dispatch_enabled) {
        _ = &callInternal;
        _ = &dispatchRecursive;
    }
}
