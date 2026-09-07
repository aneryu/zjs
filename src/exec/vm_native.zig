//! NB2 §5.2: the one VM-side native call dispatcher for both call shapes
//! (`op_call*`: window = [callee, args...]; `op_call_method`: window =
//! [receiver, callee, args...]). Replaces the plain / method twin
//! dispatchers of vm_call.zig. The terminal is
//! `builtin_dispatch.callRecordFromVmInRealm` (preflight, backtrace marker,
//! leaf arm without environment, managed arm with environment only when the
//! entry declares `needs_env`).
//!
//! Per D7 there is no interrupt tick here: qjs `js_call_c_function` does not
//! poll either; JS loops poll at their back-edges and function entries.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const vm_call = @import("vm_call.zig");

pub const Shape = enum { plain, method };

/// `hit` / `caught` re-dispatch via `coldNext`; `miss` falls through to the
/// generic call path (no entry, or a forwarding entry such as
/// Function.prototype.call).
pub const Outcome = enum { hit, caught, miss };

/// One entry for both kinds. The K1 leaf arm (§4.2: tag checks + direct C
/// call + boxing; no preflight, no backtrace marker, no environment, no
/// realm switch) sits at the top; everything else takes the full terminal.
/// Entry and callee realm come from one payload walk (`nativeCallTarget`).
pub noinline fn dispatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    func_obj: *core.Object,
    argc: u16,
    comptime shape: Shape,
) align(32) core.errors.HostError!Outcome {
    const window_head: usize = if (shape == .method) 2 else 1;
    const total: usize = @as(usize, argc) + window_head;
    if (shape == .method and stack.len() < total) return error.StackUnderflow;
    const region_base = stack.len() - total;
    const target = vm_call.resolvedNativeCallTargetAssumeCFunction(ctx, func_obj) orelse return .miss;
    const entry = target.entry;
    const args: []const core.JSValue = stack.values[region_base + window_head ..][0..argc];
    var result: core.JSValue = undefined;
    var handled = false;
    if (entry.kind == .leaf) {
        if (shape == .method) frame.pc += 3; // argc + cache_idx
        if (builtin_dispatch.invokeLeafFastEntry(entry, args)) |value| {
            result = value;
            handled = true;
        }
    } else {
        if (entry.flags.forwards_call) return .miss;
        if (shape == .method) frame.pc += 3; // argc + cache_idx
    }
    if (!handled) {
        const this_value = if (shape == .method) stack.values[region_base] else core.JSValue.undefinedValue();
        result = builtin_dispatch.nativeFromBits(builtin_dispatch.callRecordFromVmInRealm(
            ctx,
            output,
            global,
            func_obj,
            entry,
            target.realm,
            this_value,
            args,
            function,
            frame,
        ));
        if (builtin_dispatch.nativeIsExc(ctx, result)) {
            return failure(ctx, output, stack, frame, catch_target, global, region_base, builtin_dispatch.nativeHostError(ctx));
        }
    }
    stack.setLen(region_base);
    if (vm_call.dropUnusedCallResult(ctx, function, frame, result)) return .hit;
    stack.pushOwnedAssumeCapacity(result);
    return .hit;
}

/// K0 inline-arm eligibility (design §5.2): a managed entry without an
/// environment, with room on the native stack for the qjs `arg_buf`
/// reservation. Everything else takes `dispatch`.
pub inline fn managedInlineEligible(rt: *const core.JSRuntime, entry: *const core.NativeEntry) bool {
    if (entry.kind != .managed or entry.flags.needs_env or entry.flags.forwards_call) return false;
    return !rt.checkNativeStackOverflow(@as(usize, entry.arity) * @sizeOf(core.JSValue));
}

/// Same preflight for the W1 `.native_getter` arm: an untyped managed
/// getter without an environment is one `bl` from the field tail.
pub inline fn getterInlineEligible(rt: *const core.JSRuntime, entry: *const core.NativeEntry) bool {
    if (entry.kind != .getter or entry.sig != 0 or entry.flags.needs_env) return false;
    return !rt.checkNativeStackOverflow(@as(usize, entry.arity) * @sizeOf(core.JSValue));
}

/// Same preflight for the K2 `method_managed` arm of the method handler.
pub inline fn methodManagedInlineEligible(rt: *const core.JSRuntime, entry: *const core.NativeEntry) bool {
    if (entry.kind != .method_managed) return false;
    return !rt.checkNativeStackOverflow(@as(usize, entry.arity) * @sizeOf(core.JSValue));
}

/// Cold leg: drop the call region and route the pending error to the
/// frame's handler (`.caught`) or the caller.
pub noinline fn failure(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    region_base: usize,
    err: core.errors.HostError,
) core.errors.HostError!Outcome {
    call_runtime.popOwnedStackRegion(stack, region_base);
    const caught = call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err) catch |handler_err|
        return @errorCast(handler_err);
    if (caught) return .caught;
    return err;
}
