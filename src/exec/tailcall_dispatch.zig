//! Tail-call threaded bytecode dispatcher — the architecture that reaches qjs
//! parity (scratch/perf/TAILCALL-REWRITE.md). Each HOT opcode is its own small
//! function; dispatch is `@call(.always_tail)` through a 256-entry table = a real
//! computed-goto `br`. Every COLD opcode (and every uncommon path of a hot
//! opcode) routes through one `op_cold` that delegates to `coldDispatch`.
//!
//! State lives in argument registers on the hot path:
//!   handler(pc: [*]const u8,  // x0 — raw bytecode cursor, points AT its opcode
//!           sp: [*]JSValue,   // x1 — operand-stack cursor (next free slot)
//!           var_buf: [*]JSValue, // x2 — frame.locals.ptr (hottest non-stack state)
//!           vm: *Vm)          // x3 — cold context (touched only by cold paths)
//!           callconv(.c) Outcome
//!
//! CRITICAL INVARIANT — a hot handler must contain ZERO non-tail calls. Any
//! `bl` (value.free/dup, slotValueBorrow, numberToValue, an interrupt handler,
//! …) forces a stack frame + callee-saved spills, which is exactly the per-op
//! overhead this architecture exists to remove. So each hot handler inlines only
//! the int/bool, no-allocation, no-refcount common case and TAIL-CALLS a slow
//! handler (`op_cold` / `op_interrupt_check`) for everything else. The empty loop
//! and the alloc-free compute kernels stay entirely on the call-free fast paths.
//!
//! comptime-gated behind `build_options.zjs_tailcall_dispatch` (default OFF). When
//! ON the engine module is compiled with `-fomit-frame-pointer` (build.zig).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const exception_ops = @import("vm_exception_ops.zig");
const HostError = @import("exceptions.zig").HostError;

const arith_vm = @import("vm_arith.zig");
const control_vm = @import("vm_control.zig");
const call_vm = @import("vm_call.zig");
const call_runtime = @import("call_runtime.zig");
const inline_calls = @import("inline_calls.zig");
const call_internal = @import("call_internal.zig");
// Handlers the cold-opcode arms (ported from dispatchRecursive) delegate to.
const value_vm = @import("vm_value.zig");
const array_ops = @import("array_ops.zig");
const forof_ops = @import("forof_ops.zig");
const regexp_vm = @import("vm_regexp.zig");
const class_vm = @import("object_ops.zig");
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
const JSValue = core.JSValue;
pub const tailcall_dispatch_enabled = build_options.zjs_tailcall_dispatch;

fn readInt(comptime T: type, bytes: [*]const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn relativePc(operand_pc: usize, diff: i32) usize {
    return @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
}

const eval_class_field_initializer_flag: u16 = 0x8000;
const eval_parameter_initializer_flag: u16 = 0x4000;

// ===========================================================================
// Outcome + Vm
// ===========================================================================

/// What the tail-call chain produced, returned (as a single u32 in x0) all the
/// way up to `callInternalTC`. The actual payload rides in `Vm` fields.
pub const Outcome = enum(u32) {
    /// A return/return_undef/fall-off produced `vm.return_value`.
    returned,
    /// An UNCAUGHT error: re-raise `vm.pending_error`.
    threw,
    /// A proper tail call: `vm.tail_request` (only when allow_tail_signal).
    tail,
};

/// Per-frame cold context reached via the x3 pointer.
pub const Vm = struct {
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    output: ?*std.Io.Writer,

    code_base: [*]const u8,
    code_len: usize,
    /// One past the last code byte. A forward dispatch reaching it is a fall-off
    /// (implicit return of the stack top / undefined) — `next` routes to op_falloff.
    code_end: [*]const u8,
    stack_base: [*]JSValue,
    arg_buf: [*]JSValue,
    arg_count: usize,

    catch_target: ?usize = null,
    interrupt_poller: control_vm.InterruptPoller,
    allow_inline_calls: bool,
    allow_tail_signal: bool,
    /// True iff the function has NO lexical (let/const) locals — then put_loc's
    /// non-refcount fast path needs no uninitialized-bit bookkeeping.
    no_lexical_locals: bool,

    return_value: JSValue = JSValue.undefinedValue(),
    pending_error: HostError = error.OutOfMemory,
    tail_request: call_runtime.InlineCallRequest = undefined,

    /// sp -> stack.values.len (slot count) for the GC root + cold handlers.
    inline fn publish(self: *Vm, pc: [*]const u8, sp: [*]JSValue) void {
        self.stack.values.len = (@intFromPtr(sp) - @intFromPtr(self.stack_base)) / @sizeOf(JSValue);
        // Cold handlers read frame.pc as the OPERAND cursor (one past the opcode
        // byte), mirroring dispatchRecursive's `pc` local at each arm.
        self.frame.pc = (@intFromPtr(pc) - @intFromPtr(self.code_base)) + 1;
    }
    inline fn reloadSp(self: *Vm) [*]JSValue {
        return self.stack_base + self.stack.values.len;
    }
    inline fn fail(self: *Vm, err: HostError) Outcome {
        self.pending_error = err;
        return .threw;
    }
};

// ===========================================================================
// Dispatch primitives
// ===========================================================================

const Handler = *const fn (pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome;

/// Computed-goto: tail-call the handler for the opcode at `pc[0]`. A forward
/// dispatch that reaches code_end is a fall-off → tail to op_falloff (both arms
/// are tail calls, so the caller stays frame-free; T2: replace the bounds check
/// with a trailing-return sentinel byte for zero per-op cost).
inline fn next(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome {
    if (@intFromPtr(pc) >= @intFromPtr(vm.code_end)) return @call(.always_tail, op_falloff, .{ pc, sp, var_buf, vm });
    return @call(.always_tail, dispatch_table[pc[0]], .{ pc, sp, var_buf, vm });
}

/// Tail-call the cold handler for the opcode AT `pc` (pc unchanged, sp/var_buf
/// as-of-entry). The single escape hatch every hot fast path uses.
inline fn cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome {
    return @call(.always_tail, op_cold, .{ pc, sp, var_buf, vm });
}

/// Signed pointer displacement for branches (handles backward jumps).
inline fn jumpFrom(base: [*]const u8, diff: i32) [*]const u8 {
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(@intFromPtr(base))) +% diff)));
}

/// Pure (call-free) int32 binary op. Returns the int32 result, or null for any
/// case that would need a non-tail call (overflow → float, div/mod/shr → float/
/// unsigned). Those fall to `op_cold`.
inline fn fastBinaryInt32Pure(comptime binop: u8, a: i32, b: i32) ?i32 {
    return switch (binop) {
        op.add => {
            const r = @addWithOverflow(a, b);
            return if (r[1] == 0) r[0] else null;
        },
        op.sub => {
            const r = @subWithOverflow(a, b);
            return if (r[1] == 0) r[0] else null;
        },
        op.mul => {
            const r = @mulWithOverflow(a, b);
            return if (r[1] == 0) r[0] else null;
        },
        op.@"and" => a & b,
        op.@"or" => a | b,
        op.xor => a ^ b,
        op.shl => a << @intCast(@as(u32, @bitCast(b)) & 31),
        op.sar => a >> @intCast(@as(u32, @bitCast(b)) & 31),
        else => null, // div / mod / shr → cold (float / unsigned result)
    };
}

// ===========================================================================
// HOT opcode handlers — ZERO non-tail calls on the fast path.
// ===========================================================================

/// Push a slot value. Non-refcount (int/bool/null/undefined/float) is a plain
/// store + advance; a refcounted value (object/string/cell) needs a borrow+dup
/// (a call), so it tail-routes to `op_cold` (which runs the full get_loc).
inline fn getSlot(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm, slot: JSValue, size: usize) Outcome {
    if (slot.requiresRefCount()) return cold(pc, sp, vb, vm);
    sp[0] = slot;
    return next(pc + size, sp + 1, vb, vm);
}

fn op_get_loc0(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getSlot(pc, sp, vb, vm, vb[0], 1);
}
fn op_get_loc1(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getSlot(pc, sp, vb, vm, vb[1], 1);
}
fn op_get_loc2(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getSlot(pc, sp, vb, vm, vb[2], 1);
}
fn op_get_loc3(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getSlot(pc, sp, vb, vm, vb[3], 1);
}
fn op_get_loc8(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getSlot(pc, sp, vb, vm, vb[pc[1]], 2);
}
fn op_get_loc(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getSlot(pc, sp, vb, vm, vb[readInt(u16, pc + 1)], 3);
}

inline fn getArg(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm, idx: usize, size: usize) Outcome {
    const slot = if (idx < vm.arg_count) vm.arg_buf[idx] else JSValue.undefinedValue();
    return getSlot(pc, sp, vb, vm, slot, size);
}
fn op_get_arg0(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getArg(pc, sp, vb, vm, 0, 1);
}
fn op_get_arg1(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getArg(pc, sp, vb, vm, 1, 1);
}
fn op_get_arg2(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getArg(pc, sp, vb, vm, 2, 1);
}
fn op_get_arg3(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getArg(pc, sp, vb, vm, 3, 1);
}
fn op_get_arg(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return getArg(pc, sp, vb, vm, readInt(u16, pc + 1), 3);
}

/// put_loc fast path: a non-refcount slot AND a non-refcount value, in a
/// function with no lexical locals (no uninitialized-bit bookkeeping), is a
/// plain store. Anything else tail-routes to `op_cold` (full execPutLoc: frees
/// the old refcounted value, drives a var-ref cell, clears the lexical bit).
inline fn putLocFast(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm, idx: usize, size: usize) Outcome {
    const nsp = sp - 1;
    const value = nsp[0];
    const slot = &vb[idx];
    if (vm.no_lexical_locals and !slot.requiresRefCount() and !value.requiresRefCount()) {
        slot.* = value;
        return next(pc + size, nsp, vb, vm);
    }
    return cold(pc, sp, vb, vm);
}
fn op_put_loc0(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return putLocFast(pc, sp, vb, vm, 0, 1);
}
fn op_put_loc1(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return putLocFast(pc, sp, vb, vm, 1, 1);
}
fn op_put_loc2(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return putLocFast(pc, sp, vb, vm, 2, 1);
}
fn op_put_loc3(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return putLocFast(pc, sp, vb, vm, 3, 1);
}
fn op_put_loc8(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return putLocFast(pc, sp, vb, vm, pc[1], 2);
}
fn op_put_loc(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return putLocFast(pc, sp, vb, vm, readInt(u16, pc + 1), 3);
}

// ---- immediate / literal pushes (always call-free) ----
fn op_push_i32(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    sp[0] = JSValue.int32(readInt(i32, pc + 1));
    return next(pc + 5, sp + 1, vb, vm);
}
fn op_push_i16(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    sp[0] = JSValue.int32(readInt(i16, pc + 1));
    return next(pc + 3, sp + 1, vb, vm);
}
fn op_push_i8(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    sp[0] = JSValue.int32(@as(i8, @bitCast(pc[1])));
    return next(pc + 2, sp + 1, vb, vm);
}
fn pushConstInt(comptime v: i32) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            sp[0] = JSValue.int32(v);
            return next(pc + 1, sp + 1, vb, vm);
        }
    }.h;
}
fn pushConstValue(comptime v: JSValue) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            sp[0] = v;
            return next(pc + 1, sp + 1, vb, vm);
        }
    }.h;
}

// ---- comparisons (int32 fast path; else cold) ----
fn compareHandler(comptime cmp: u8) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            if ((sp - 2)[0].asInt32()) |a| {
                if ((sp - 1)[0].asInt32()) |b| {
                    const r = switch (cmp) {
                        op.lt => a < b,
                        op.lte => a <= b,
                        op.gt => a > b,
                        op.gte => a >= b,
                        op.eq, op.strict_eq => a == b,
                        op.neq, op.strict_neq => a != b,
                        else => unreachable,
                    };
                    (sp - 2)[0] = JSValue.boolean(r);
                    return next(pc + 1, sp - 1, vb, vm);
                }
            }
            return cold(pc, sp, vb, vm);
        }
    }.h;
}

// ---- arithmetic / bitwise (pure int32 fast path; else cold) ----
fn binaryHandler(comptime binop: u8) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            if ((sp - 2)[0].asInt32()) |ai| {
                if ((sp - 1)[0].asInt32()) |bi| {
                    if (fastBinaryInt32Pure(binop, ai, bi)) |res| {
                        (sp - 2)[0] = JSValue.int32(res);
                        return next(pc + 1, sp - 1, vb, vm);
                    }
                }
            }
            return cold(pc, sp, vb, vm);
        }
    }.h;
}

// ---- post_inc / post_dec (leave old, push old±1; pure int fast path) ----
fn postUpdateHandler(comptime is_inc: bool) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            if ((sp - 1)[0].asInt32()) |oi| {
                const r = if (is_inc) @addWithOverflow(oi, 1) else @subWithOverflow(oi, 1);
                if (r[1] == 0) {
                    sp[0] = JSValue.int32(r[0]);
                    return next(pc + 1, sp + 1, vb, vm);
                }
            }
            return cold(pc, sp, vb, vm);
        }
    }.h;
}

// ---- inc_loc / dec_loc (in-place pure int fast path) ----
fn updateLocalHandler(comptime is_inc: bool) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            const idx = pc[1];
            if (vb[idx].asInt32()) |iv| {
                const r = if (is_inc) @addWithOverflow(iv, 1) else @subWithOverflow(iv, 1);
                if (r[1] == 0) {
                    vb[idx] = JSValue.int32(r[0]);
                    return next(pc + 2, sp, vb, vm);
                }
            }
            return cold(pc, sp, vb, vm);
        }
    }.h;
}

// ---- branches / jumps ----
/// Rare backward-branch interrupt: runs the handler (a call) off the hot path.
/// `pc` is ALREADY the branch target; on no-interrupt it resumes there.
fn op_interrupt_check(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.ctx.runtime.runInterruptHandler()) return vm.fail(error.Interrupted);
    return next(pc, sp, vb, vm);
}
/// Backward-jump poll: the budget counter is inline; only the rare 1-in-1024
/// trigger tail-calls `op_interrupt_check`. (TODO T2: LLVM inlines
/// op_interrupt_check's `runInterruptHandler` bl here, forcing a frame on the
/// hot back-edge; runtime-inert when `active` is false, but it's ~4% of the
/// empty loop. Needs a frame-free trampoline.)
inline fn pollAndJump(sp: [*]JSValue, vb: [*]JSValue, vm: *Vm, target: [*]const u8) Outcome {
    if (vm.interrupt_poller.active) {
        vm.interrupt_poller.budget +%= 1;
        if ((vm.interrupt_poller.budget & 0x3ff) == 0) {
            return @call(.always_tail, op_interrupt_check, .{ target, sp, vb, vm });
        }
    }
    return next(target, sp, vb, vm);
}
fn op_goto(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const diff = readInt(i32, pc + 1);
    const target = jumpFrom(pc + 1, diff);
    if (diff < 0) return pollAndJump(sp, vb, vm, target);
    return next(target, sp, vb, vm);
}
fn op_goto16(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const diff: i32 = readInt(i16, pc + 1);
    const target = jumpFrom(pc + 1, diff);
    if (diff < 0) return pollAndJump(sp, vb, vm, target);
    return next(target, sp, vb, vm);
}
fn op_goto8(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const diff: i32 = @as(i8, @bitCast(pc[1]));
    const target = jumpFrom(pc + 1, diff);
    if (diff < 0) return pollAndJump(sp, vb, vm, target);
    return next(target, sp, vb, vm);
}
/// if_false/if_true. The condition MUST be a boolean to stay on the fast path
/// (so no free + no isTruthy call); any other value tail-routes to `op_cold`.
fn ifHandler(comptime branch_if_true: bool, comptime is8: bool) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            const truthy = (sp - 1)[0].asBool() orelse return cold(pc, sp, vb, vm);
            const nsp = sp - 1; // boolean: non-refcount, nothing to free
            const operand_size: usize = if (is8) 1 else 4;
            if (truthy == branch_if_true) {
                const diff: i32 = if (is8) @as(i8, @bitCast(pc[1])) else readInt(i32, pc + 1);
                const target = jumpFrom(pc + 1, diff);
                if (diff < 0) return pollAndJump(nsp, vb, vm, target);
                return next(target, nsp, vb, vm);
            }
            return next(pc + 1 + operand_size, nsp, vb, vm);
        }
    }.h;
}

// ---- stack manipulation ----
fn op_drop(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const top = (sp - 1)[0];
    // Refcounted top needs a free (a call); catch markers need the full handler.
    if (top.requiresRefCount() or top.isCatchOffset()) return cold(pc, sp, vb, vm);
    return next(pc + 1, sp - 1, vb, vm);
}
fn op_dup(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const top = (sp - 1)[0];
    if (top.requiresRefCount()) return cold(pc, sp, vb, vm); // dup() is a call
    sp[0] = top;
    return next(pc + 1, sp + 1, vb, vm);
}
fn op_get_loc0_loc1(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const a = vb[0];
    const b = vb[1];
    if (a.requiresRefCount() or b.requiresRefCount()) return cold(pc, sp, vb, vm);
    sp[0] = a;
    sp[1] = b;
    return next(pc + 1, sp + 2, vb, vm);
}
fn op_nop(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return next(pc + 1, sp, vb, vm);
}

// ---- fall-off the end (implicit return of the stack top / undefined),
//      mirroring dispatchLoop:533. A terminal handler; a frame is fine. ----
fn finishFalloff(vm: *Vm, sp: [*]JSValue) Outcome {
    vm.stack.values.len = (@intFromPtr(sp) - @intFromPtr(vm.stack_base)) / @sizeOf(JSValue);
    vm.return_value = control_vm.finishFunctionReturn(vm.ctx, vm.frame, if (vm.stack.peek()) |v| v else JSValue.undefinedValue()) catch |e| return vm.fail(e);
    return .returned;
}
fn op_falloff(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = pc;
    _ = vb;
    return finishFalloff(vm, sp);
}

// ---- returns (rare: a frame here is fine) ----
fn op_return(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = vb;
    vm.publish(pc, sp);
    vm.return_value = control_vm.returnTop(vm.ctx, vm.stack, vm.frame, null) catch |e| return vm.fail(e);
    return .returned;
}
fn op_return_undef(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = vb;
    vm.publish(pc, sp);
    vm.return_value = control_vm.returnUndefined(vm.ctx, vm.frame, null) catch |e| return vm.fail(e);
    return .returned;
}

// ===========================================================================
// COLD path: one handler + the (T1) coldDispatch delegating to existing arms.
// ===========================================================================

const ColdStep = union(enum) {
    /// Continue dispatch at `vm.frame.pc` (the arm advanced it / set a catch target).
    next,
    returned: JSValue,
    tail: call_runtime.InlineCallRequest,
};

fn op_cold(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const opc = pc[0];
    vm.publish(pc, sp);
    const step = coldDispatch(opc, vm) catch |e| return vm.fail(e);
    const nsp = vm.reloadSp();
    switch (step) {
        .next => {
            if (vm.frame.pc >= vm.code_len) {
                vm.return_value = control_vm.finishFunctionReturn(vm.ctx, vm.frame, if (vm.stack.peek()) |v| v else JSValue.undefinedValue()) catch |e| return vm.fail(e);
                return .returned;
            }
            const npc = vm.code_base + vm.frame.pc;
            return @call(.always_tail, dispatch_table[npc[0]], .{ npc, nsp, vb, vm });
        },
        .returned => |v| {
            vm.return_value = v;
            return .returned;
        },
        .tail => |req| {
            vm.tail_request = req;
            return .tail;
        },
    }
}

fn op_invalid(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = sp;
    _ = vb;
    const pc_off = @intFromPtr(pc) - @intFromPtr(vm.code_base);
    const n = @min(vm.code_len, 12);
    std.debug.panic("tailcall: invalid opcode {d} at pc_off={d} code_len={d} code[0..]={any}", .{ pc[0], pc_off, vm.code_len, vm.code_base[0..n] });
}

/// The cold-opcode body — ported from dispatchRecursive's switch (the
/// semantic ground truth). `continue` -> `return .next`, recurseInlineCall ->
/// recurseInlineCallTC; op_cold manages frame.pc/sp around it.
fn coldDispatch(opc: u8, vm: *Vm) HostError!ColdStep {
    const ctx = vm.ctx;
    const function = vm.function;
    const global = vm.global;
    const frame = vm.frame;
    const stack = vm.stack;
    const output = vm.output;
    const catch_target = &vm.catch_target;
    const code = function.code;
    const allow_inline_calls = vm.allow_inline_calls;
    const allow_tail_signal = vm.allow_tail_signal;
    const interrupt_poller = &vm.interrupt_poller;
    var pc: usize = frame.pc;
    switch (opc) {
    // ===================================================================
    // Pushes that decode an immediate operand (INLINE on C-local pc)
    // ===================================================================
    // Immediate pushes use assumeCapacity: every push is counted in the
    // verifier's stack_size and the frame stack is presized to stack_size+1
    // (reserveEntryFrameCapacity), so the bounds check is redundant — mirrors
    // qjs's bare `*sp++` and the get_loc inline above.
    op.push_i32 => {
        const v = readInt(i32, code[pc..][0..4]);
        pc += 4;
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(v));
    },
    op.push_i16 => {
        const v: i32 = readInt(i16, code[pc..][0..2]);
        pc += 2;
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(v));
    },
    op.push_i8 => {
        const v: i32 = @as(i8, @bitCast(code[pc]));
        pc += 1;
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(v));
    },
    op.push_bigint_i32 => {
        const v = readInt(i32, code[pc..][0..4]);
        pc += 4;
        stack.pushOwnedAssumeCapacity(core.JSValue.shortBigInt(v));
    },

    // ---- Small-int / literal pushes (no operand; plain unfused push) ----
    op.push_minus1 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(-1)),
    op.push_0 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(0)),
    op.push_1 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(1)),
    op.push_2 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(2)),
    op.push_3 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(3)),
    op.push_4 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(4)),
    op.push_5 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(5)),
    op.push_6 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(6)),
    op.push_7 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(7)),
    op.@"undefined" => stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue()),
    op.@"null" => stack.pushOwnedAssumeCapacity(core.JSValue.nullValue()),
    op.push_false => stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false)),
    op.push_true => stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true)),

    // ---- Constant-table / atom pushes (DELEGATE: operand decode + fusion) ----
    op.push_const => {
        frame.pc = pc;
        try value_vm.pushConst(ctx, stack, function, frame, opc);
        pc = frame.pc;
    },
    op.push_const8 => {
        frame.pc = pc;
        try value_vm.pushConst8(ctx, stack, function, frame, opc);
        pc = frame.pc;
    },
    op.push_atom_value => {
        frame.pc = pc;
        try value_vm.pushAtomValue(ctx, stack, function, frame);
        pc = frame.pc;
    },
    op.push_empty_string => {
        frame.pc = pc;
        try value_vm.pushEmptyString(ctx, stack);
        pc = frame.pc;
    },
    op.private_symbol => {
        frame.pc = pc;
        try value_vm.pushPrivateSymbol(ctx, stack, function, frame);
        pc = frame.pc;
    },
    op.regexp => {
        frame.pc = pc;
        try regexp_vm.pushLiteral(ctx, stack, class_vm.constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"));
        pc = frame.pc;
    },
    op.fclosure, op.fclosure8 => {
        frame.pc = pc;
        const step = try call_vm.closure(ctx, output, global, stack, function, frame, catch_target, opc, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },

    // ===================================================================
    // Stack manipulation (DELEGATE; pure-stack, no operand)
    // ===================================================================
    op.drop => {
        // Fast path: a plain (non catch-marker) top is popped + freed inline
        // (free is a no-op for ints). Catch markers carry the try-region target
        // and delegate to the full handler.
        const top = stack.values[stack.values.len - 1];
        if (top.isCatchOffset()) {
            frame.pc = pc;
            switch (try value_vm.drop(ctx.runtime, stack)) {
                .value => {},
                .catch_target => |target| {
                    catch_target.* = target;
                    pc = frame.pc;
                    return .next;
                },
            }
            pc = frame.pc;
        } else {
            stack.values.len -= 1;
            top.free(ctx.runtime);
        }
    },
    op.nip_catch => {
        frame.pc = pc;
        try value_vm.nipCatch(ctx.runtime, stack);
        pc = frame.pc;
    },
    op.nip => {
        frame.pc = pc;
        try value_vm.nip(ctx, stack);
        pc = frame.pc;
    },
    op.nip1 => {
        frame.pc = pc;
        try value_vm.nip1(ctx, stack);
        pc = frame.pc;
    },
    op.dup => {
        frame.pc = pc;
        try value_vm.dup(ctx, stack, opc);
        pc = frame.pc;
    },
    op.dup1 => {
        frame.pc = pc;
        try value_vm.dup1(ctx, stack);
        pc = frame.pc;
    },
    op.dup2 => {
        frame.pc = pc;
        try value_vm.dup2(ctx, stack);
        pc = frame.pc;
    },
    op.dup3 => {
        frame.pc = pc;
        try value_vm.dup3(ctx, stack);
        pc = frame.pc;
    },
    op.swap => {
        frame.pc = pc;
        try value_vm.swap(ctx, stack);
        pc = frame.pc;
    },
    op.swap2 => {
        frame.pc = pc;
        try value_vm.swap2(ctx, stack);
        pc = frame.pc;
    },
    op.insert2 => {
        frame.pc = pc;
        try value_vm.insert2(ctx, stack);
        pc = frame.pc;
    },
    op.insert3 => {
        frame.pc = pc;
        try value_vm.insert3(ctx, stack);
        pc = frame.pc;
    },
    op.insert4 => {
        frame.pc = pc;
        try value_vm.insert4(ctx, stack);
        pc = frame.pc;
    },
    op.perm3 => {
        frame.pc = pc;
        try value_vm.perm3(ctx, stack);
        pc = frame.pc;
    },
    op.perm4 => {
        frame.pc = pc;
        try value_vm.perm4(ctx, stack);
        pc = frame.pc;
    },
    op.perm5 => {
        frame.pc = pc;
        try value_vm.perm5(ctx, stack);
        pc = frame.pc;
    },
    op.rot3l => {
        frame.pc = pc;
        try value_vm.rot3l(ctx, stack);
        pc = frame.pc;
    },
    op.rot3r => {
        frame.pc = pc;
        try value_vm.rot3r(ctx, stack);
        pc = frame.pc;
    },
    op.rot4l => {
        frame.pc = pc;
        try value_vm.rot4l(ctx, stack);
        pc = frame.pc;
    },
    op.rot5l => {
        frame.pc = pc;
        try value_vm.rot5l(ctx, stack);
        pc = frame.pc;
    },

    // ===================================================================
    // Locals / args / var-refs (all DELEGATE; operand decode in handler)
    // ===================================================================
    // S2b: hot local GETs inline the leaned body directly — skip the `loc`
    // dispatcher (its per-op switch + the comptime-gated fusion scans) AND the
    // execGetLoc call AND the frame.pc round-trip. GC-free (presized-stack
    // assumeCapacity push + a verifier-trusted frame.locals[idx] read, no bounds
    // check), so no frame.pc publish is needed. This is the #1 crypto opcode.
    op.get_loc0 => array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[0]),
    op.get_loc1 => array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[1]),
    op.get_loc2 => array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[2]),
    op.get_loc3 => array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[3]),
    op.get_loc8 => {
        const idx = code[pc];
        pc += 1;
        array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[idx]);
    },
    op.get_loc => {
        const idx = readInt(u16, code[pc..][0..2]);
        pc += 2;
        array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[idx]);
    },
    op.put_loc, op.set_loc, op.put_loc8, op.set_loc8, op.set_loc0, op.set_loc1, op.set_loc2, op.set_loc3, op.get_loc0_loc1 => {
        frame.pc = pc;
        try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
        pc = frame.pc;
    },
    op.put_loc0 => {
        frame.pc = pc;
        try slot_ops.execPutLoc(ctx, function, global, frame, stack, 0, 0, opc, false);
        pc = frame.pc;
    },
    op.put_loc1 => {
        frame.pc = pc;
        try slot_ops.execPutLoc(ctx, function, global, frame, stack, 1, 0, opc, false);
        pc = frame.pc;
    },
    op.put_loc2 => {
        frame.pc = pc;
        try slot_ops.execPutLoc(ctx, function, global, frame, stack, 2, 0, opc, false);
        pc = frame.pc;
    },
    op.put_loc3 => {
        frame.pc = pc;
        try slot_ops.execPutLoc(ctx, function, global, frame, stack, 3, 0, opc, false);
        pc = frame.pc;
    },
    // S2b: hot arg GETs inline the leaned body (skip the `arg` dispatcher + the
    // execGetArg call + frame.pc round-trip). Variadic bound: an arg index past
    // the actual arg count reads undefined (args may be fewer than declared).
    // GC-free presized-stack push, so no frame.pc publish needed.
    op.get_arg0 => array_ops.pushSlotValueAssumeCapacity(stack, if (frame.args.len > 0) frame.args[0] else core.JSValue.undefinedValue()),
    op.get_arg1 => array_ops.pushSlotValueAssumeCapacity(stack, if (frame.args.len > 1) frame.args[1] else core.JSValue.undefinedValue()),
    op.get_arg2 => array_ops.pushSlotValueAssumeCapacity(stack, if (frame.args.len > 2) frame.args[2] else core.JSValue.undefinedValue()),
    op.get_arg3 => array_ops.pushSlotValueAssumeCapacity(stack, if (frame.args.len > 3) frame.args[3] else core.JSValue.undefinedValue()),
    op.get_arg => {
        const idx = readInt(u16, code[pc..][0..2]);
        pc += 2;
        array_ops.pushSlotValueAssumeCapacity(stack, if (idx < frame.args.len) frame.args[idx] else core.JSValue.undefinedValue());
    },
    op.put_arg, op.set_arg, op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3, op.set_arg0, op.set_arg1, op.set_arg2, op.set_arg3 => {
        frame.pc = pc;
        try vm_property_locals.arg(ctx, function, frame, stack, opc);
        pc = frame.pc;
    },
    op.get_var_ref, op.get_var_ref_check, op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init, op.set_var_ref, op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3, op.put_var_ref0, op.put_var_ref1, op.put_var_ref2, op.put_var_ref3, op.set_var_ref0, op.set_var_ref1, op.set_var_ref2, op.set_var_ref3 => {
        frame.pc = pc;
        const step = try vm_property_locals.varRefVm(ctx, function, global, frame, stack, opc, catch_target, false, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.set_loc_uninitialized, op.get_loc_check, op.put_loc_check, op.put_loc_check_init => {
        frame.pc = pc;
        const step = try vm_property_locals.checkedLocVm(ctx, function, global, frame, stack, opc, catch_target, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.close_loc => {
        frame.pc = pc;
        try vm_property_locals.closeLoc(ctx, function, frame);
        pc = frame.pc;
    },
    op.make_loc_ref, op.make_arg_ref, op.make_var_ref_ref => {
        frame.pc = pc;
        try vm_property_ref.makeSlotRef(ctx, stack, function, frame, opc);
        pc = frame.pc;
    },
    op.make_var_ref => {
        frame.pc = pc;
        const step = try vm_property_ref.makeVarRefVm(ctx, output, global, stack, function, frame, catch_target, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },

    // ===================================================================
    // Arithmetic / compare / logic (int32 fast path INLINE; slow DELEGATE)
    // ===================================================================
    op.add, op.sub, op.mul, op.div, op.mod, op.pow, op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor => {
        if (opc != op.pow and arith_vm.tryInt32Binary(stack, opc)) { frame.pc = pc; return .next; }
        frame.pc = pc;
        switch (try arith_vm.binaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq => {
        if (arith_vm.tryInt32Compare(stack, opc)) { frame.pc = pc; return .next; }
        frame.pc = pc;
        switch (try arith_vm.compareVm(ctx, stack, frame, catch_target, opc, output, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.neg, op.plus, op.inc, op.dec => {
        frame.pc = pc;
        switch (try arith_vm.unaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.not => {
        frame.pc = pc;
        switch (try arith_vm.bitNotVm(ctx, stack, frame, catch_target, output, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.lnot => try value_vm.logicalNot(ctx.runtime, stack),
    op.post_inc, op.post_dec => {
        // Int32 fast path: leave the old value on the stack and push old±1 on
        // top (mirrors postUpdate's int branch). Overflow folds to float via
        // fastInt32Add. GC-free. Non-int delegates.
        const top = stack.values[stack.values.len - 1];
        if (top.asInt32()) |oi| {
            const updated = if (opc == op.post_inc) arith_vm.fastInt32Add(oi, 1) else arith_vm.fastInt32Sub(oi, 1);
            stack.pushOwnedAssumeCapacity(updated);
        } else {
            frame.pc = pc;
            switch (try arith_vm.postUpdateVm(ctx, stack, frame, catch_target, opc, output, global)) {
                .done => {},
                .continue_loop => {},
            }
            pc = frame.pc;
        }
    },
    op.inc_loc, op.dec_loc => {
        // Int32 fast path: a local holding an int32 is a plain slot (NOT a
        // var-ref cell — a cell is an object), so update it in place with no
        // dup/free and no global-lexical sync (dispatchRecursive runs only
        // normal-kind frames, which have no top-level global-lexical locals).
        // Overflow folds to a float via fastInt32Add. Anything else (cell,
        // bigint, coercible object) delegates to the full handler.
        const idx = code[pc];
        if (frame.locals[idx].asInt32()) |iv| {
            pc += 1;
            frame.locals[idx] = if (opc == op.inc_loc) arith_vm.fastInt32Add(iv, 1) else arith_vm.fastInt32Sub(iv, 1);
        } else {
            frame.pc = pc;
            switch (try arith_vm.updateLocalVm(ctx, stack, function, global, frame, catch_target, opc, output, false)) {
                .done => {},
                .continue_loop => {},
            }
            pc = frame.pc;
        }
    },
    op.add_loc => {
        frame.pc = pc;
        switch (try arith_vm.addLocalVm(ctx, stack, function, global, frame, catch_target, output, false)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.typeof => try value_vm.typeOf(ctx, stack),
    op.typeof_is_undefined => try value_vm.typeOfIsUndefined(ctx.runtime, stack),
    op.typeof_is_function => try value_vm.typeOfIsFunction(ctx.runtime, stack),
    op.is_undefined_or_null => try value_vm.isUndefinedOrNull(ctx.runtime, stack),
    op.is_undefined => try value_vm.isUndefined(ctx.runtime, stack),
    op.is_null => try value_vm.isNull(ctx.runtime, stack),
    op.in, op.instanceof => {
        frame.pc = pc;
        switch (try vm_property_field.inOrInstanceof(ctx, output, global, stack, function, frame, catch_target, opc)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.private_in => {
        frame.pc = pc;
        switch (try class_vm.privateInVm(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.delete => {
        frame.pc = pc;
        switch (try vm_property_ref.deletePropertyVm(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.delete_var => {
        frame.pc = pc;
        try vm_property_ref.deleteVar(ctx, global, stack, function, frame, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
        pc = frame.pc;
    },

    // ===================================================================
    // Control flow (jumps/branches INLINE on C-local pc; throw DELEGATE)
    // ===================================================================
    op.goto => {
        const operand_pc = pc;
        const diff = readInt(i32, code[pc..][0..4]);
        pc = relativePc(operand_pc, diff);
        if (diff < 0) try interrupt_poller.poll(ctx.runtime);
    },
    op.goto16 => {
        const operand_pc = pc;
        const diff: i32 = readInt(i16, code[pc..][0..2]);
        pc = relativePc(operand_pc, diff);
        if (diff < 0) try interrupt_poller.poll(ctx.runtime);
    },
    op.goto8 => {
        const operand_pc = pc;
        const diff: i32 = @as(i8, @bitCast(code[pc]));
        pc = relativePc(operand_pc, diff);
        if (diff < 0) try interrupt_poller.poll(ctx.runtime);
    },
    op.if_false, op.if_true => {
        const operand_pc = pc;
        const diff = readInt(i32, code[pc..][0..4]);
        pc += 4;
        const value = try stack.pop();
        defer value.free(ctx.runtime);
        const truthy = value.asBool() orelse value_ops.isTruthy(value);
        const branch_if_true = (opc == op.if_true);
        if (truthy == branch_if_true) {
            pc = relativePc(operand_pc, diff);
            if (diff < 0) try interrupt_poller.poll(ctx.runtime);
        }
    },
    op.if_false8, op.if_true8 => {
        const operand_pc = pc;
        const diff: i32 = @as(i8, @bitCast(code[pc]));
        pc += 1;
        const value = try stack.pop();
        defer value.free(ctx.runtime);
        const truthy = value.asBool() orelse value_ops.isTruthy(value);
        const branch_if_true = (opc == op.if_true8);
        if (truthy == branch_if_true) {
            pc = relativePc(operand_pc, diff);
            if (diff < 0) try interrupt_poller.poll(ctx.runtime);
        }
    },
    op.gosub => {
        const operand_pc = pc;
        const diff = readInt(i32, code[pc..][0..4]);
        const return_pc = pc + 4;
        if (return_pc > @as(usize, @intCast(std.math.maxInt(i32)))) return error.InvalidBytecode;
        try stack.pushOwned(core.JSValue.int32(@intCast(return_pc)));
        pc = relativePc(operand_pc, diff);
    },
    op.ret => {
        const target = try stack.pop();
        defer target.free(ctx.runtime);
        const pc_i32 = target.asInt32() orelse return error.InvalidBytecode;
        if (pc_i32 < 0) return error.InvalidBytecode;
        const target_pc: usize = @intCast(pc_i32);
        if (target_pc >= code.len) return error.InvalidBytecode;
        pc = target_pc;
    },
    op.nop => control_vm.nop(),

    // ---- Return ----
    op.@"return" => {
        frame.pc = pc;
        return .{ .returned = try control_vm.returnTop(ctx, stack, frame, null) };
    },
    op.return_undef => {
        frame.pc = pc;
        return .{ .returned = try control_vm.returnUndefined(ctx, frame, null) };
    },

    // ---- Throw / catch ----
    op.throw => {
        frame.pc = pc;
        switch (try control_vm.throwTop(ctx, output, global, stack, frame, catch_target)) {
            .handled => {},
        }
        pc = frame.pc;
        return .next;
    },
    op.throw_error => {
        frame.pc = pc;
        switch (try control_vm.throwErrorVm(ctx, stack, function, frame, catch_target, global)) {
            .handled => {},
        }
        pc = frame.pc;
        return .next;
    },
    op.@"catch" => {
        frame.pc = pc;
        try control_vm.catchTarget(function, frame, stack, catch_target);
        pc = frame.pc;
    },

    // ===================================================================
    // Calls (DELEGATE to the out-of-line recursive call resolution)
    // ===================================================================
    op.call, op.call0, op.call1, op.call2, op.call3 => {
        const argc: u16 = switch (opc) {
            op.call => blk: {
                const v = readInt(u16, code[pc..][0..2]);
                pc += 2;
                break :blk v;
            },
            op.call0 => 0,
            op.call1 => 1,
            op.call2 => 2,
            op.call3 => 3,
            else => unreachable,
        };
        frame.pc = pc;
        // S2a: a plain-bytecode callee runs as a NATIVE recursion via
        // recurseInlineCall (reusing the Machine's zero-copy setup), not the
        // dup-heavy slow path.
        switch (try call_runtime.execCall(ctx, stack, function, frame, catch_target, argc, output, global, allow_inline_calls)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                return .next;
            },
            .inline_call => |request| switch (try recurseInlineCallTC(ctx, output, global, stack, frame, catch_target, request)) {
                .value => |v| stack.pushOwnedAssumeCapacity(v),
                .caught => {
                    pc = frame.pc;
                    return .next;
                },
            },
        }
        pc = frame.pc;
    },
    op.tail_call => {
        frame.pc = pc;
        switch (try call_vm.tailCall(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
            .handled => {
                pc = frame.pc;
                return .next;
            },
            .return_value => |value| {
                return .{ .returned = value };
            },
            // Proper tail call. Under a trampoline (allow_tail_signal) signal it
            // up so the native frame is reused (constant depth). Otherwise (the
            // callInternal slow-path entry) recurse and return the callee value.
            .tail_inline => |request| {
                if (allow_tail_signal) return .{ .tail = request };
                switch (try recurseInlineCallTC(ctx, output, global, stack, frame, catch_target, request)) {
                    .value => |v| return .{ .returned = v },
                    .caught => {
                        pc = frame.pc;
                        return .next;
                    },
                }
            },
        }
    },
    op.tail_call_method => {
        frame.pc = pc;
        switch (try call_vm.tailCallMethod(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
            .handled => {
                pc = frame.pc;
                return .next;
            },
            .return_value => |value| {
                return .{ .returned = value };
            },
            .tail_inline => |request| {
                if (allow_tail_signal) return .{ .tail = request };
                switch (try recurseInlineCallTC(ctx, output, global, stack, frame, catch_target, request)) {
                    .value => |v| return .{ .returned = v },
                    .caught => {
                        pc = frame.pc;
                        return .next;
                    },
                }
            },
        }
    },
    op.call_method => {
        frame.pc = pc;
        switch (try call_vm.callMethod(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                return .next;
            },
            .inline_call => |request| switch (try recurseInlineCallTC(ctx, output, global, stack, frame, catch_target, request)) {
                .value => |v| stack.pushOwnedAssumeCapacity(v),
                .caught => {
                    pc = frame.pc;
                    return .next;
                },
            },
        }
        pc = frame.pc;
    },
    op.call_prepared => {
        frame.pc = pc;
        switch (try call_vm.callPrepared(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                return .next;
            },
            .inline_call => |request| switch (try recurseInlineCallTC(ctx, output, global, stack, frame, catch_target, request)) {
                .value => |v| stack.pushOwnedAssumeCapacity(v),
                .caught => {
                    pc = frame.pc;
                    return .next;
                },
            },
        }
        pc = frame.pc;
    },
    op.prepare_call_prop_atom => {
        frame.pc = pc;
        switch (try call_vm.prepareCallPropAtom(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                return .next;
            },
        }
        pc = frame.pc;
    },
    op.call_constructor => {
        frame.pc = pc;
        switch (try call_vm.constructor(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                return .next;
            },
        }
        pc = frame.pc;
    },
    op.apply => {
        frame.pc = pc;
        switch (try call_vm.apply(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                return .next;
            },
        }
        pc = frame.pc;
    },
    op.apply_eval => {
        frame.pc = pc;
        switch (try eval_module_vm.applyEval(ctx, stack, function, frame, catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                return .next;
            },
        }
        pc = frame.pc;
    },
    op.eval => {
        frame.pc = pc;
        // A non-%eval% callee (the identifier `eval` shadowed by a normal
        // function) in tail position yields `.tail_inline` — handle it like a
        // tail call so eval-named tail recursion (test262 tco-non-eval-*) TCOs
        // via the trampoline instead of growing the native stack.
        switch (try eval_module_vm.directEval(ctx, stack, function, frame, catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag, allow_inline_calls)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                return .next;
            },
            .tail_inline => |request| {
                if (allow_tail_signal) return .{ .tail = request };
                switch (try recurseInlineCallTC(ctx, output, global, stack, frame, catch_target, request)) {
                    .value => |v| return .{ .returned = v },
                    .caught => {
                        pc = frame.pc;
                        return .next;
                    },
                }
            },
        }
        pc = frame.pc;
    },
    op.import => {
        frame.pc = pc;
        try eval_module_vm.dynamicImport(ctx, output, global, stack, function, frame);
        pc = frame.pc;
    },

    // ---- ctor / brand helpers (DELEGATE) ----
    op.check_ctor => {
        frame.pc = pc;
        switch (try call_vm.checkCtorVm(ctx, stack, frame, catch_target, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.check_ctor_return => {
        frame.pc = pc;
        switch (try call_vm.checkCtorReturnVm(ctx, stack, frame, catch_target, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.init_ctor => {
        frame.pc = pc;
        switch (try call_vm.initCtorVm(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.check_brand => {
        frame.pc = pc;
        switch (try class_vm.checkBrandVm(ctx, stack, frame, catch_target, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.add_brand => {
        frame.pc = pc;
        switch (try class_vm.addBrandVm(ctx, stack, frame, catch_target, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },

    // ===================================================================
    // Variables / globals / property access (DELEGATE)
    // ===================================================================
    op.get_var, op.get_var_undef => {
        frame.pc = pc;
        const step = try vm_property_globals.getVar(ctx, output, global, stack, function, frame, catch_target, opc, false, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, core.JSValue.undefinedValue());
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.put_var => {
        frame.pc = pc;
        const step = try vm_property_globals.putVar(ctx, output, global, stack, function, frame, catch_target, function.flags.is_strict or function.flags.runtime_strict, false, false, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, core.JSValue.undefinedValue());
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.check_define_var, op.define_var, op.define_func, op.put_var_init => {
        frame.pc = pc;
        const step = try vm_property_globals.globalDefinition(ctx, global, stack, function, frame, catch_target, opc, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, false, false);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.get_field, op.get_field2, op.put_field => {
        frame.pc = pc;
        const step = try vm_property_field.field(ctx, output, global, stack, function, frame, catch_target, opc, false);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.get_array_el, op.get_array_el2, op.put_array_el => {
        frame.pc = pc;
        const step = try vm_property_field.arrayElement(ctx, output, global, stack, function, frame, catch_target, opc);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.to_propkey => {
        frame.pc = pc;
        const step = try vm_property_field.toPropKeyVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.to_propkey2 => {
        frame.pc = pc;
        const step = try vm_property_field.toPropKey2Vm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.set_name, op.set_name_computed => {
        frame.pc = pc;
        try vm_property_field.setName(ctx, output, global, stack, function, frame, opc);
        pc = frame.pc;
    },
    op.get_ref_value => {
        frame.pc = pc;
        const step = try vm_property_ref.getRefValueVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.put_ref_value => {
        frame.pc = pc;
        const step = try vm_property_ref.putRefValueVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.get_private_field => {
        frame.pc = pc;
        const step = try vm_property_private.getPrivateFieldVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.put_private_field => {
        frame.pc = pc;
        const step = try vm_property_private.putPrivateFieldVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.define_private_field => {
        frame.pc = pc;
        const step = try vm_property_private.definePrivateFieldVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },

    // ---- with-statement opcodes (a normal function body may contain `with`) ----
    op.with_get_var, op.with_delete_var, op.with_make_ref, op.with_get_ref, op.with_get_ref_undef => {
        frame.pc = pc;
        const step = try vm_property_ref.withGetOrDelete(ctx, output, global, stack, function, frame, catch_target, opc);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.with_put_var => {
        frame.pc = pc;
        const step = try vm_property_ref.withPut(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },

    // ===================================================================
    // Object / array literals, super, this, iterators (DELEGATE)
    // (define_field / get_super / get_super_value / put_super_value /
    //  get_length appeared in two draft categories — merged here once)
    // ===================================================================
    op.object => {
        frame.pc = pc;
        try literal_vm.object(ctx, stack, global);
        pc = frame.pc;
    },
    op.array_from => {
        frame.pc = pc;
        try literal_vm.arrayFrom(ctx, stack, function, frame, global);
        pc = frame.pc;
    },
    op.append => {
        frame.pc = pc;
        const step = try literal_vm.appendSpreadValuesVm(ctx, output, global, stack, opc, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.rest => {
        frame.pc = pc;
        try literal_vm.rest(ctx, stack, function, frame);
        pc = frame.pc;
    },
    op.define_field => {
        frame.pc = pc;
        const step = try literal_vm.defineField(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.define_array_el => {
        frame.pc = pc;
        const step = try literal_vm.defineArrayEl(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.set_proto => {
        frame.pc = pc;
        try literal_vm.setProto(ctx, stack);
        pc = frame.pc;
    },
    op.set_home_object => {
        frame.pc = pc;
        try class_vm.setHomeObject(ctx, stack);
        pc = frame.pc;
    },
    op.copy_data_properties => {
        const mask = code[pc];
        pc += 1;
        frame.pc = pc;
        const step = try literal_vm.copyDataProperties(ctx, output, global, stack, mask, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.define_method => {
        frame.pc = pc;
        const step = try class_vm.defineMethod(ctx, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.define_method_computed => {
        frame.pc = pc;
        const step = try class_vm.defineMethodComputed(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.define_class, op.define_class_computed => {
        frame.pc = pc;
        const step = try class_vm.defineClass(ctx, output, global, stack, function, frame, catch_target, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, opc == op.define_class_computed);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.special_object => {
        frame.pc = pc;
        try literal_vm.specialObject(ctx, stack, function, frame, global, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
        pc = frame.pc;
    },
    op.get_super => {
        frame.pc = pc;
        try class_vm.getSuper(ctx, stack, frame);
        pc = frame.pc;
    },
    op.get_super_value => {
        frame.pc = pc;
        const step = try class_vm.getSuperValue(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.put_super_value => {
        frame.pc = pc;
        const step = try class_vm.putSuperValue(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.get_length => {
        frame.pc = pc;
        const step = try literal_vm.getLength(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.to_object => {
        frame.pc = pc;
        const step = try value_vm.toObjectVm(ctx, stack, frame, catch_target, global);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.push_this => {
        frame.pc = pc;
        const step = try value_vm.pushThisVm(ctx, stack, frame, catch_target, global);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.for_of_start, op.for_await_of_start => {
        frame.pc = pc;
        const step = try iter_vm.forOfStartVm(ctx, output, global, stack, function, frame, catch_target, opc == op.for_await_of_start);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.for_in_start => {
        frame.pc = pc;
        const step = try iter_vm.forInStartVm(ctx, output, global, stack, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.iterator_next => {
        frame.pc = pc;
        const step = try iter_vm.iteratorNextVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.iterator_check_object => {
        frame.pc = pc;
        const step = try iter_vm.iteratorCheckObjectVm(ctx, stack, frame, catch_target, global);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.iterator_get_value_done => {
        frame.pc = pc;
        const step = try iter_vm.iteratorGetValueDoneVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.iterator_call => {
        frame.pc = pc;
        const step = try iter_vm.iteratorCallVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.for_of_next => {
        frame.pc = pc;
        const step = try iter_vm.forOfNextVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },
    op.for_in_next => {
        frame.pc = pc;
        try iter_vm.forInNext(ctx, output, global, stack);
        pc = frame.pc;
    },
    op.iterator_close => {
        frame.pc = pc;
        const step = try iter_vm.iteratorCloseVm(ctx, output, global, stack, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => return .next,
        }
    },

    // ===================================================================
    // Generator / async opcodes: a normal-kind frame never executes these
    // ===================================================================
    op.initial_yield, op.yield, op.yield_star, op.async_yield_star, op.await, op.return_async => @panic("dispatchRecursive: generator opcode in normal frame"),

    // ===================================================================
    // Invalid / unknown
    // ===================================================================
    op.invalid => return error.InvalidBytecode,
    else => return error.InvalidBytecode,
    }
    frame.pc = pc;
    return .next;
}

// ===========================================================================
// Dispatch table (comptime)
// ===========================================================================

const dispatch_table: [256]Handler = blk: {
    var t = [_]Handler{&op_cold} ** 256;
    t[op.invalid] = &op_invalid;

    t[op.get_loc0] = &op_get_loc0;
    t[op.get_loc1] = &op_get_loc1;
    t[op.get_loc2] = &op_get_loc2;
    t[op.get_loc3] = &op_get_loc3;
    t[op.get_loc8] = &op_get_loc8;
    t[op.get_loc] = &op_get_loc;
    t[op.get_arg0] = &op_get_arg0;
    t[op.get_arg1] = &op_get_arg1;
    t[op.get_arg2] = &op_get_arg2;
    t[op.get_arg3] = &op_get_arg3;
    t[op.get_arg] = &op_get_arg;
    t[op.put_loc0] = &op_put_loc0;
    t[op.put_loc1] = &op_put_loc1;
    t[op.put_loc2] = &op_put_loc2;
    t[op.put_loc3] = &op_put_loc3;
    t[op.put_loc8] = &op_put_loc8;
    t[op.put_loc] = &op_put_loc;

    t[op.push_i32] = &op_push_i32;
    t[op.push_i16] = &op_push_i16;
    t[op.push_i8] = &op_push_i8;
    t[op.push_minus1] = pushConstInt(-1);
    t[op.push_0] = pushConstInt(0);
    t[op.push_1] = pushConstInt(1);
    t[op.push_2] = pushConstInt(2);
    t[op.push_3] = pushConstInt(3);
    t[op.push_4] = pushConstInt(4);
    t[op.push_5] = pushConstInt(5);
    t[op.push_6] = pushConstInt(6);
    t[op.push_7] = pushConstInt(7);
    t[op.@"undefined"] = pushConstValue(JSValue.undefinedValue());
    t[op.@"null"] = pushConstValue(JSValue.nullValue());
    t[op.push_false] = pushConstValue(JSValue.boolean(false));
    t[op.push_true] = pushConstValue(JSValue.boolean(true));

    t[op.lt] = compareHandler(op.lt);
    t[op.lte] = compareHandler(op.lte);
    t[op.gt] = compareHandler(op.gt);
    t[op.gte] = compareHandler(op.gte);
    t[op.eq] = compareHandler(op.eq);
    t[op.neq] = compareHandler(op.neq);
    t[op.strict_eq] = compareHandler(op.strict_eq);
    t[op.strict_neq] = compareHandler(op.strict_neq);

    t[op.add] = binaryHandler(op.add);
    t[op.sub] = binaryHandler(op.sub);
    t[op.mul] = binaryHandler(op.mul);
    t[op.div] = binaryHandler(op.div);
    t[op.mod] = binaryHandler(op.mod);
    t[op.shl] = binaryHandler(op.shl);
    t[op.sar] = binaryHandler(op.sar);
    t[op.shr] = binaryHandler(op.shr);
    t[op.@"and"] = binaryHandler(op.@"and");
    t[op.@"or"] = binaryHandler(op.@"or");
    t[op.xor] = binaryHandler(op.xor);

    t[op.post_inc] = postUpdateHandler(true);
    t[op.post_dec] = postUpdateHandler(false);
    t[op.inc_loc] = updateLocalHandler(true);
    t[op.dec_loc] = updateLocalHandler(false);

    t[op.goto] = &op_goto;
    t[op.goto16] = &op_goto16;
    t[op.goto8] = &op_goto8;
    t[op.if_false] = ifHandler(false, false);
    t[op.if_true] = ifHandler(true, false);
    t[op.if_false8] = ifHandler(false, true);
    t[op.if_true8] = ifHandler(true, true);

    t[op.drop] = &op_drop;
    t[op.dup] = &op_dup;
    t[op.get_loc0_loc1] = &op_get_loc0_loc1;
    t[op.nop] = &op_nop;
    t[op.@"return"] = &op_return;
    t[op.return_undef] = &op_return_undef;

    break :blk t;
};

// ===========================================================================
// Frame-setup entry — runs a NORMAL-kind bytecode function via the tail chain.
// Mirrors callInternal (call_internal.zig:64-131); the body diff is `enterChain`
// instead of `dispatchRecursive`.
// ===========================================================================

pub fn callInternalTC(
    ctx: *core.JSContext,
    entry_stack: *stack_mod.Stack,
    entry_function: *const bytecode.Bytecode,
    initial_this_value: JSValue,
    args: []const JSValue,
    var_refs: []const JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    input_eval_var_ref_names: []const core.Atom,
    input_eval_var_refs: []const JSValue,
    current_function_value: JSValue,
    new_target_value: JSValue,
    constructor_this_value: JSValue,
) HostError!JSValue {
    const call_depth_guard = try call_vm.enterCallDepth(ctx, global);
    defer call_depth_guard.deinit();
    const call_profile_guard = call_vm.enterCallProfile(ctx.runtime);
    defer call_profile_guard.deinit();
    try ctx.pushBacktraceFrameLazyName(entry_function.name, entry_function.filename, entry_function.line_num, entry_function.col_num, entry_function, exception_ops.resolveBacktraceLocation, current_function_value);
    defer ctx.popBacktraceFrame();

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

    const frame_stack_size: usize = if (comptime builtin.mode == .Debug)
        (if (entry_function.stack_size == 0 and entry_function.code.len != 0) entry_function.code.len else entry_function.stack_size)
    else
        entry_function.stack_size;
    try entry_stack.reserveFrameCapacity(frame_stack_size);
    errdefer call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, entry_stack, &frame_storage);

    var no_lexical = true;
    for (entry_function.var_is_lexical) |is_lex| {
        if (is_lex) {
            no_lexical = false;
            break;
        }
    }

    var vm = Vm{
        .ctx = ctx,
        .function = entry_function,
        .global = global,
        .frame = &frame_storage,
        .stack = entry_stack,
        .output = output,
        .code_base = entry_function.code.ptr,
        .code_len = entry_function.code.len,
        .code_end = entry_function.code.ptr + entry_function.code.len,
        .stack_base = entry_stack.values.ptr,
        .arg_buf = frame_storage.args.ptr,
        .arg_count = frame_storage.args.len,
        .interrupt_poller = control_vm.InterruptPoller.init(ctx.runtime),
        .allow_inline_calls = !call_vm.nativeDepthNearCap(ctx),
        .allow_tail_signal = false,
        .no_lexical_locals = no_lexical,
    };

    const outcome = enterChain(&vm);
    return switch (outcome) {
        .returned => vm.return_value,
        .threw => vm.pending_error,
        .tail => unreachable, // allow_tail_signal=false: never produced here.
    };
}

/// Run the tail-call chain on a pre-built inline `Entry` (zero-copy arg setup by
/// `setupInlineEntry`), returning the same `call_internal.Outcome` shape as
/// `dispatchRecursive` so `recurseInlineCallTC` mirrors `recurseInlineCall`.
fn dispatchEntryTC(
    ctx: *core.JSContext,
    entry: *inline_calls.Entry,
    global: *core.Object,
    output: ?*std.Io.Writer,
    allow_tail_signal: bool,
) HostError!call_internal.Outcome {
    var no_lexical = true;
    for (entry.view.var_is_lexical) |is_lex| {
        if (is_lex) {
            no_lexical = false;
            break;
        }
    }
    var vm = Vm{
        .ctx = ctx,
        .function = &entry.view,
        .global = global,
        .frame = &entry.frame,
        .stack = &entry.stack,
        .output = output,
        .code_base = entry.view.code.ptr,
        .code_len = entry.view.code.len,
        .code_end = entry.view.code.ptr + entry.view.code.len,
        .stack_base = entry.stack.values.ptr,
        .arg_buf = entry.frame.args.ptr,
        .arg_count = entry.frame.args.len,
        .interrupt_poller = control_vm.InterruptPoller.init(ctx.runtime),
        .allow_inline_calls = !call_vm.nativeDepthNearCap(ctx),
        .allow_tail_signal = allow_tail_signal,
        .no_lexical_locals = no_lexical,
    };
    return switch (enterChain(&vm)) {
        .returned => .{ .returned = vm.return_value },
        .threw => vm.pending_error,
        .tail => .{ .tail = vm.tail_request },
    };
}

/// Tail-call variant of `call_internal.recurseInlineCall`: run an inline-eligible
/// callee on the TAIL-CALL chain. T0 minimal version (no TCO trampoline — the
/// empty-loop / leaf compute callees have no tail call; allow_tail_signal=false).
pub fn recurseInlineCallTC(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_stack: *stack_mod.Stack,
    caller_frame: *frame_mod.Frame,
    caller_catch_target: *?usize,
    request: call_runtime.InlineCallRequest,
) HostError!call_internal.RecurseOutcome {
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
        return call_internal.routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
    };
    defer depth_guard.deinit();

    var entry: inline_calls.Entry = undefined;
    inline_calls.Machine.setupInlineEntry(ctx, global, &entry, request.target, source) catch |err| {
        return call_internal.routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
    };
    // TCO trampoline (mirrors call_internal.recurseInlineCall): a proper tail call
    // returns `.tail`; we move the call region off the dying entry stack, teardown,
    // re-setup the tail target in the SAME native frame + held depth slot (constant
    // depth), and loop — so 100k strict tail calls don't blow the C stack.
    while (true) {
        const outcome = dispatchEntryTC(ctx, &entry, global, output, true) catch |err| {
            call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, &entry.stack, &entry.frame);
            inline_calls.Machine.teardownInlineEntry(ctx, &entry);
            return call_internal.routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
        };
        switch (outcome) {
            .returned => |result| {
                inline_calls.Machine.teardownInlineEntry(ctx, &entry);
                return .{ .value = result };
            },
            .tail => |tail_req| {
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
                defer for (moved) |v| v.free(ctx.runtime);
                inline_calls.Machine.teardownInlineEntry(ctx, &entry);
                inline_calls.Machine.setupInlineEntry(ctx, global, &entry, tail_req.target, .{ .moved = .{ .values = moved, .has_receiver = has_receiver } }) catch |err| {
                    return call_internal.routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
                };
            },
        }
    }
}

/// NON-tail entry into the tail-call chain (one handler frame on top of
/// callInternalTC, reused across every opcode via the tail calls).
fn enterChain(vm: *Vm) Outcome {
    if (vm.frame.pc >= vm.code_len) {
        vm.return_value = control_vm.finishFunctionReturn(vm.ctx, vm.frame, if (vm.stack.peek()) |v| v else JSValue.undefinedValue()) catch |e| return vm.fail(e);
        return .returned;
    }
    const pc: [*]const u8 = vm.code_base + vm.frame.pc;
    const sp: [*]JSValue = vm.stack_base + vm.stack.values.len;
    const var_buf: [*]JSValue = vm.frame.locals.ptr;
    return dispatch_table[pc[0]](pc, sp, var_buf, vm);
}

comptime {
    // Keep the entry referenced even when the flag is off (so it type-checks).
    _ = &callInternalTC;
}
