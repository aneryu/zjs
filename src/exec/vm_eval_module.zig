const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const call_runtime = @import("call_runtime.zig");
const eval_ops = @import("eval_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const module_graph = @import("module_graph.zig");
const promise_ops = @import("promise_ops.zig");
const string_ops = @import("string_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

pub const Step = enum { done, continue_loop };

pub const EvalStep = union(enum) {
    done,
    continue_loop,
    /// Non-%eval% callee in tail position; eligible for frame reuse.
    tail_inline: call_runtime.InlineCallRequest,
};

pub noinline fn directEval(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
    global: *core.Object,
    class_field_initializer_flag: u16,
    parameter_initializer_flag: u16,
    allow_tail_inline: bool,
) !EvalStep {
    const eval_operands = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const argc: u16 = @intCast(eval_operands & 0xffff);
    const eval_scope: u16 = @intCast((eval_operands >> 16) & 0xffff);
    const eval_scope_index = eval_scope & ~(class_field_initializer_flag | parameter_initializer_flag);
    return switch (try eval_ops.execDirectEval(
        ctx,
        stack,
        function,
        frame,
        catch_target,
        argc,
        output,
        global,
        eval_scope_index,
        (eval_scope & class_field_initializer_flag) != 0,
        (eval_scope & parameter_initializer_flag) != 0,
        allow_tail_inline,
    )) {
        .done => .done,
        .continue_loop => .continue_loop,
        .tail_inline => |request| .{ .tail_inline = request },
    };
}

pub noinline fn applyEval(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
    global: *core.Object,
    class_field_initializer_flag: u16,
    parameter_initializer_flag: u16,
) !Step {
    const eval_scope = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    const eval_scope_index = eval_scope & ~(class_field_initializer_flag | parameter_initializer_flag);
    return switch (try eval_ops.execApplyEval(
        ctx,
        stack,
        function,
        frame,
        catch_target,
        output,
        global,
        eval_scope_index,
        (eval_scope & class_field_initializer_flag) != 0,
        (eval_scope & parameter_initializer_flag) != 0,
    )) {
        .done => .done,
        .continue_loop => .continue_loop,
        // eval_ops.execApplyEval never requests tail-call inlining.
        .tail_inline => unreachable,
    };
}

pub noinline fn dynamicImport(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    const options = try stack.pop();
    defer options.free(ctx.runtime);
    const specifier = try stack.pop();
    defer specifier.free(ctx.runtime);

    const prototype = promise_ops.promisePrototypeFromGlobal(ctx.runtime, global);
    const specifier_string = string_ops.toStringForAnnexB(ctx, output, global, specifier, function, frame) catch |err| {
        const rejected = try exception_ops.rejectedPromiseForRuntimeError(ctx, global, err, prototype);
        errdefer rejected.free(ctx.runtime);
        try stack.pushOwned(rejected);
        return;
    };
    defer specifier_string.free(ctx.runtime);

    // Mirror qjs js_dynamic_import (quickjs.c:31073): the specifier ToString
    // (above) plus options/with-attribute validation run synchronously; the
    // load/link/evaluate work is deferred to an enqueued job (JS_EnqueueJob
    // quickjs.c:31155) that settles the returned pending promise, so the
    // statement after import() runs before any module side effect. All
    // options validation, attribute-string enforcement, and attribute
    // threading live in module_graph.evaluateImportCall.
    // Referrer = the stable active ScriptOrModule identity (spec
    // GetActiveScriptOrModule, qjs JS_GetScriptOrModuleName quickjs.c:30854).
    // Direct eval retains this separately from its "<eval>" display filename,
    // so escaped eval-created functions do not depend on live caller frames.
    const referrer_path = ctx.runtime.atoms.name(function.script_or_module) orelse "";
    const promise = module_graph.evaluateImportCall(ctx, output, global, prototype, referrer_path, specifier_string, options, function, frame) catch |err| {
        const rejected = try exception_ops.rejectedPromiseForRuntimeError(ctx, global, err, prototype);
        errdefer rejected.free(ctx.runtime);
        try stack.pushOwned(rejected);
        return;
    };
    errdefer promise.free(ctx.runtime);
    try stack.pushOwned(promise);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
