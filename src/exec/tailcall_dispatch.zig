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

const op = bytecode.opcode.op;
const JSValue = core.JSValue;
pub const tailcall_dispatch_enabled = build_options.zjs_tailcall_dispatch;

fn readInt(comptime T: type, bytes: [*]const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

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

/// Computed-goto: tail-call the handler for the opcode at `pc[0]`.
inline fn next(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome {
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
    _ = vm;
    std.debug.panic("tailcall: invalid opcode {d}", .{pc[0]});
}

/// T0 stub: the cold-opcode body. Filled in T1 by porting dispatchRecursive's
/// switch arms (mechanical). The empty-loop proof only exercises hot opcodes.
fn coldDispatch(opc: u8, vm: *Vm) HostError!ColdStep {
    _ = vm;
    std.debug.panic("tailcall: unmigrated cold opcode {d} ({s})", .{ opc, bytecode.opcode.nameOf(opc) });
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
    const outcome = dispatchEntryTC(ctx, &entry, global, output, false) catch |err| {
        call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, &entry.stack, &entry.frame);
        inline_calls.Machine.teardownInlineEntry(ctx, &entry);
        return call_internal.routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
    };
    switch (outcome) {
        .returned => |result| {
            inline_calls.Machine.teardownInlineEntry(ctx, &entry);
            return .{ .value = result };
        },
        .tail => unreachable, // allow_tail_signal=false: never produced (T0).
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
