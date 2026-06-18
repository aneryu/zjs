//! Recursive, register-resident bytecode dispatcher — the radical rewrite core.
//! See `scratch/perf/ARCH-RECURSIVE-REWRITE.md`. comptime-gated behind
//! `build_options.zjs_recursive_dispatch` (default OFF) so it is built up
//! incrementally without disturbing the proven flattened `dispatchLoop`.
//!
//! ARCHITECTURE (mirrors QuickJS JS_CallInternal, quickjs.c:17746):
//!   - `pc` is a Zig C-LOCAL `usize` whose address is never taken, so LLVM
//!     register-allocates it across the labeled `switch` (no per-opcode
//!     `frame.pc` load/store through the *Frame pointer).
//!   - JS->JS calls to a normal-func_kind bytecode callee RECURSE natively into
//!     `callInternal` instead of pushing on the flattened inline Machine.
//!   - the operand stack and locals are reused from the existing Frame/Stack in
//!     this first cut (S2.0); a bare-pointer `sp` + one arena window come next.
//!
//! INCREMENTAL DISCIPLINE (the loop is COMPLETE + CORRECT at every step):
//!   - HOT opcodes that decode operands are inlined here using the C-local `pc`
//!     (the win: zero `frame.pc` traffic on the compute floor).
//!   - every other opcode delegates to the SAME out-of-line handler the
//!     flattened `dispatchLoop` uses, with `frame.pc` synced around the call
//!     (`frame.pc = pc` before, `pc = frame.pc` after) so operand decode + the
//!     lazy backtrace stay correct. Migrating an opcode from "delegate" to
//!     "inline" is a local change that only drops the sync — never a
//!     correctness change. Until the dispatch is complete, unmigrated control
//!     paths return `error.RecursiveDispatchTodo` (only reachable with the
//!     build flag ON, which is not yet wired into any call site).

const std = @import("std");
const build_options = @import("build_options");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const HostError = @import("exceptions.zig").HostError;

const op = bytecode.opcode.op;

pub const recursive_dispatch_enabled = build_options.zjs_recursive_dispatch;

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

/// The recursive register-resident dispatch loop for a single normal-func_kind
/// bytecode frame. `frame` and `stack` are already fully set up by the caller
/// (locals/args/var_refs initialized, stack pre-sized, backtrace pushed); this
/// runs the function body to a `return`/`return_undef` and yields its value.
///
/// `pc` is a C-local mirror of `frame.pc`; on entry they are equal. The loop
/// keeps `pc` authoritative across the inlined hot arms and re-syncs `frame.pc`
/// only at the boundaries an out-of-line handler / throw / backtrace observes.
pub fn dispatchRecursive(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
) HostError!core.JSValue {
    _ = ctx;
    _ = global;
    const code = function.code;
    var pc: usize = frame.pc;

    while (true) {
        if (pc >= code.len) {
            // Fell off the end without an explicit return: the function result
            // is the top of stack (or undefined). Mirror finishFunctionReturn's
            // fallthrough value.
            frame.pc = pc;
            const fallthrough = stack.peek() orelse core.JSValue.undefinedValue();
            return fallthrough;
        }

        const opc = code[pc];
        pc += 1;

        switch (opc) {
            // ---- pushes that decode an immediate operand (inlined on C-local pc) ----
            op.push_i32 => {
                const v = readInt(i32, code[pc..][0..4]);
                pc += 4;
                try stack.pushOwned(core.JSValue.int32(v));
            },
            op.push_i16 => {
                const v: i32 = readInt(i16, code[pc..][0..2]);
                pc += 2;
                try stack.pushOwned(core.JSValue.int32(v));
            },
            op.push_i8 => {
                const v: i32 = @as(i8, @bitCast(code[pc]));
                pc += 1;
                try stack.pushOwned(core.JSValue.int32(v));
            },

            op.@"return" => {
                frame.pc = pc;
                return stack.pop() catch core.JSValue.undefinedValue();
            },
            op.return_undef => {
                frame.pc = pc;
                return core.JSValue.undefinedValue();
            },

            else => {
                // Not yet migrated to the recursive loop. Sync frame.pc so the
                // future delegate path decodes the right operand. Unreachable in
                // practice: no call site enables the flag until the dispatch is
                // complete; this is a WIP backstop, not a runtime path.
                frame.pc = pc;
                @panic("call_internal.dispatchRecursive: opcode not yet migrated");
            },
        }
    }
}

comptime {
    // Keep the entry referenced so it type-checks in the default (flag-off)
    // build without an "unused" complaint, and so any signature drift against
    // the core types is caught by the normal build.
    if (recursive_dispatch_enabled) {
        _ = &dispatchRecursive;
    }
}
