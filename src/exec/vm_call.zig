const std = @import("std");
const build_options = @import("build_options");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const collection_vm = @import("array_ops.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("vm_exception_ops.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const class_init_ops = @import("class_init_ops.zig");
const inline_calls = @import("inline_calls.zig");
const object_ops = @import("object_ops.zig");
const slot_ops = @import("slot_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const op = bytecode.opcode.op;

pub const Step = enum { done, continue_loop };

/// Step result for opcodes that may request an inline bytecode call to be
/// pushed by the dispatch loop.
pub const CallStep = enum {
    done,
    continue_loop,
    /// The InlineCallRequest is written through the caller's shared `req_out`
    /// slot, not carried in the result (payload-free → no per-call sret alloca).
    inline_call,
};

pub const TailCallMethodResult = union(enum) {
    handled,
    return_value: core.JSValue,
    /// Eligible bytecode method target for tail-call frame reuse; the
    /// dispatch loop replaces the current inline frame (the receiver becomes
    /// the reused frame's `this`) instead of recursing. The InlineCallRequest
    /// is written through the caller's shared `req_out` slot (payload-free).
    tail_inline,
};

pub const TailCallResult = union(enum) {
    handled,
    return_value: core.JSValue,
    /// Eligible bytecode target for tail-call frame reuse; the dispatch
    /// loop replaces the current inline frame instead of recursing. The
    /// InlineCallRequest is written through the caller's shared `req_out` slot
    /// (payload-free variant → no per-call sret alloca for the 88-byte request).
    tail_inline,
};

pub const CallDepthGuard = struct {
    ctx: *core.JSContext,

    pub fn deinit(self: CallDepthGuard) void {
        self.ctx.call_depth -= 1;
        self.ctx.native_call_depth -= 1;
    }
};

pub const CallProfileGuard = if (build_options.zjs_enable_opcode_profile) struct {
    rt: *core.JSRuntime,
    previous: ?*core.profile.OpcodeProfile,

    pub fn deinit(self: @This()) void {
        if (self.rt.opcode_profile != null) {
            _ = core.profile.activate(self.previous);
        }
    }
} else struct {
    pub fn deinit(_: @This()) void {}
};

pub fn enterCallDepth(ctx: *core.JSContext, global: *core.Object) !CallDepthGuard {
    if (ctx.native_call_depth >= maxNativeJsCallDepth(ctx) or ctx.call_depth >= maxLogicalJsCallDepth(ctx)) {
        _ = exception_ops.throwRangeErrorMessage(ctx, global, "Maximum call stack size exceeded") catch |err| return err;
        return error.RangeError;
    }
    ctx.call_depth += 1;
    ctx.native_call_depth += 1;
    return .{ .ctx = ctx };
}

/// Depth accounting for inline (same interpreter loop) call frames.
pub fn enterInlineCallDepth(ctx: *core.JSContext, global: *core.Object) !void {
    if (ctx.call_depth >= maxLogicalJsCallDepth(ctx)) {
        _ = exception_ops.throwRangeErrorMessage(ctx, global, "Maximum call stack size exceeded") catch |err| return err;
        return error.RangeError;
    }
    ctx.call_depth += 1;
}

pub fn enterCallProfile(rt: *core.JSRuntime) CallProfileGuard {
    if (comptime !build_options.zjs_enable_opcode_profile) {
        return .{};
    }
    if (rt.opcode_profile == null) {
        return .{ .rt = rt, .previous = null };
    }
    const previous = if (rt.opcode_profile) |opcode_profile|
        core.profile.activate(opcode_profile)
    else
        null;
    if (rt.opcode_profile) |profile| profile.recordCallFrame();
    return .{ .rt = rt, .previous = previous };
}

pub fn linkDerivedConstructorThisLocal(ctx: *core.JSContext, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
    if (!function.flags.is_derived_class_constructor) return;
    const count = @min(function.var_names.len, frame.locals.len);
    for (function.var_names[0..count], 0..) |atom_id, idx| {
        if (!value_ops.atomNameEql(ctx.runtime, atom_id, "this")) continue;
        const this_cell = try slot_ops.ensureVarRefCell(ctx, &frame.this_value);
        const old_value = frame.locals[idx];
        frame.locals[idx] = this_cell;
        old_value.free(ctx.runtime);
        return;
    }
}

pub inline fn initFrameLocals(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    use_inline_storage: bool,
    windows: frame_mod.FrameStorageWindows,
) !void {
    if (function.var_count == 0) return;
    var storage_transferred = false;
    errdefer if (!storage_transferred) frame.releaseOwnedStorage(&ctx.runtime.memory, ctx.runtime);

    const locals = blk: {
        if (windows.locals) |values| {
            std.debug.assert(values.len == function.var_count);
            break :blk values;
        }
        if (use_inline_storage) {
            if (ctx.runtime.vm_stack.carve(&ctx.runtime.memory, function.var_count)) |window| break :blk window;
        }
        break :blk try frame.allocOwnedStorage(&ctx.runtime.memory, function.var_count);
    };
    @memset(locals, core.JSValue.undefinedValue());
    frame.locals = locals;

    if (eval_local_names.len != 0 and value_ops.atomNameEql(ctx.runtime, function.name, "<eval>")) {
        call_runtime.initializeEvalFrameLocals(ctx, function, frame, eval_local_names, eval_local_slots);
    }
    if (function.flags.is_derived_class_constructor) {
        try linkDerivedConstructorThisLocal(ctx, function, frame);
    }
    storage_transferred = true;
}

pub inline fn initFrameVarRefs(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    var_refs: []const core.JSValue,
    use_inline_storage: bool,
    windows: frame_mod.FrameStorageWindows,
) !void {
    if (var_refs.len > 0) {
        const owned_refs = if (windows.var_refs) |values| blk: {
            std.debug.assert(values.len == var_refs.len);
            break :blk values;
        } else blk: {
            if (use_inline_storage) {
                if (ctx.runtime.vm_stack.carve(&ctx.runtime.memory, var_refs.len)) |window| break :blk window;
            }
            break :blk try frame.allocOwnedStorage(&ctx.runtime.memory, var_refs.len);
        };
        for (var_refs, 0..) |value, idx| owned_refs[idx] = value.dup();
        frame.var_refs = owned_refs;
        return;
    }

    if (function.closure_var.len > 0) {
        const owned_refs = if (windows.var_refs) |values| blk: {
            std.debug.assert(values.len == function.closure_var.len);
            break :blk values;
        } else blk: {
            if (use_inline_storage) {
                if (ctx.runtime.vm_stack.carve(&ctx.runtime.memory, function.closure_var.len)) |window| break :blk window;
            }
            break :blk try frame.allocOwnedStorage(&ctx.runtime.memory, function.closure_var.len);
        };
        var initialized: usize = 0;
        errdefer {
            for (owned_refs[0..initialized]) |*val| val.free(ctx.runtime);
        }
        for (function.closure_var, 0..) |cv, idx| {
            owned_refs[idx] = try initialClosureVarRef(ctx, global, cv);
            initialized += 1;
        }
        frame.var_refs = owned_refs;
        return;
    }

    if (function.var_ref_names.len == 0) return;
    const owned_refs = if (windows.var_refs) |values| blk: {
        std.debug.assert(values.len == function.var_ref_names.len);
        break :blk values;
    } else blk: {
        if (use_inline_storage) {
            if (ctx.runtime.vm_stack.carve(&ctx.runtime.memory, function.var_ref_names.len)) |window| break :blk window;
        }
        break :blk try frame.allocOwnedStorage(&ctx.runtime.memory, function.var_ref_names.len);
    };
    var initialized: usize = 0;
    errdefer {
        for (owned_refs[0..initialized]) |*val| val.free(ctx.runtime);
    }
    for (function.var_ref_names, 0..) |var_name, idx| {
        // Top-level script let/const: share the cell that already lives in the
        // ctx.lexicals VARREF slot (qjs frame.var_refs[idx] aliases the global
        // lexical cell, js_closure_define_global_var). Falls back to building a
        // fresh cell for ordinary globals (and before the VARREF slot exists).
        // In the var_ref_names path (top-level script frame only; module/closure
        // frames take the var_refs-passed path above), a lexical var-ref is a
        // .global_decl top-level let/const (the top frame has no .ref captures).
        const is_global_decl = idx < function.var_ref_is_global_decl.len and function.var_ref_is_global_decl[idx];
        if (is_global_decl) {
            // qjs check-before-create: the redeclaration gate (check_define_var,
            // mirrors JS_CheckDefineGlobalVar PASS1) must run BEFORE the
            // ctx.lexicals cell exists — otherwise a fresh `let foo` would see
            // its own cell via globalLexicalHas and falsely throw. Reserve an
            // uninitialized (TDZ) placeholder cell here. The define_var opcode
            // creates/shares the real ctx.lexicals VARREF cell after the check
            // passes and rebinds frame.var_refs[idx] to alias it (qjs
            // js_closure_define_global_var PASS2).
            const is_const = idx < function.var_ref_is_const.len and function.var_ref_is_const[idx];
            const cell = try core.VarRef.createClosed(ctx.runtime, core.JSValue.uninitialized());
            cell.varRefIsConstSlot().* = is_const;
            cell.is_lexical = true;
            owned_refs[idx] = cell.valueRef();
        } else if (call_runtime.globalLexicalCell(ctx, var_name)) |cell_value| {
            owned_refs[idx] = cell_value;
        } else {
            const val = call_runtime.globalLexicalValueForGlobal(ctx, global, var_name) orelse global.getProperty(var_name);
            const cell = try core.VarRef.createClosed(ctx.runtime, val);
            owned_refs[idx] = cell.valueRef();
        }
        initialized += 1;
    }
    frame.var_refs = owned_refs;
}

fn initialClosureVarRef(ctx: *core.JSContext, global: *core.Object, cv: bytecode.function_def.ClosureVar) !core.JSValue {
    switch (cv.closure_type) {
        .global, .global_ref, .global_decl => {
            if (cv.is_lexical) {
                if (call_runtime.globalLexicalCell(ctx, cv.var_name)) |cell_value| return cell_value;
            } else if (call_runtime.globalObjectVarRefCell(global, cv.var_name)) |cell_value| {
                return cell_value;
            }
        },
        else => {},
    }
    const initial_value = switch (cv.closure_type) {
        .global, .global_ref, .global_decl => core.JSValue.uninitialized(),
        .module_decl, .module_import => core.JSValue.uninitialized(),
        .local, .arg, .ref => call_runtime.globalLexicalValueForGlobal(ctx, global, cv.var_name) orelse global.getProperty(cv.var_name),
    };
    const cell = try core.VarRef.createClosed(ctx.runtime, initial_value);
    cell.varRefIsConstSlot().* = cv.is_const;
    cell.is_lexical = cv.is_lexical;
    cell.varRefIsFunctionNameSlot().* = cv.var_kind == .function_name;
    return cell.valueRef();
}

pub noinline fn closure(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !Step {
    _ = output;
    _ = catch_target;
    const index: u32 = if (opc == op.fclosure) blk: {
        const value = readInt(u32, function.code[frame.pc..][0..4]);
        frame.pc += 4;
        break :blk value;
    } else blk: {
        const value: u32 = function.code[frame.pc];
        frame.pc += 1;
        break :blk value;
    };
    try collection_vm.pushFunctionClosure(ctx, frame, stack, function, global, index, opc, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs);
    return .done;
}

fn tryFastMathCall(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    argc: u16,
) !bool {
    if (stack.values.len < @as(usize, argc) + 1) return false;
    const base = stack.values.len - (@as(usize, argc) + 1);
    const func = stack.values[base];
    if (!func.isObject()) return false;
    const object = object_ops.functionObjectFromValue(func) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionIdSlot().*) orelse return false;
    if (native_ref.domain != .math) return false;

    const result = switch (native_ref.id) {
        1 => blk: { // Math.abs
            if (argc != 1) return false;
            const arg = stack.values[base + 1];
            if (arg.asInt32()) |val| {
                if (val == std.math.minInt(i32)) {
                    break :blk core.JSValue.float64(@abs(@as(f64, @floatFromInt(val))));
                } else {
                    break :blk core.JSValue.int32(@intCast(@abs(val)));
                }
            }
            if (arg.asFloat64()) |val| break :blk core.JSValue.float64(@abs(val));
            return false;
        },
        2 => blk: { // Math.floor
            if (argc != 1) return false;
            const arg = stack.values[base + 1];
            if (arg.asInt32()) |val| break :blk core.JSValue.int32(val);
            if (arg.asFloat64()) |val| break :blk core.JSValue.float64(@floor(val));
            return false;
        },
        7 => blk: { // Math.min
            if (argc == 1) {
                const arg = stack.values[base + 1];
                if (arg.isNumber()) break :blk arg.dup();
            } else if (argc == 2) {
                const arg0 = stack.values[base + 1];
                const arg1 = stack.values[base + 2];
                if (arg0.asInt32()) |v0| {
                    if (arg1.asInt32()) |v1| {
                        break :blk core.JSValue.int32(@min(v0, v1));
                    }
                }
                if (arg0.asFloat64()) |v0| {
                    if (arg1.asFloat64()) |v1| {
                        break :blk core.JSValue.float64(@min(v0, v1));
                    }
                }
            }
            return false;
        },
        8 => blk: { // Math.max
            if (argc == 1) {
                const arg = stack.values[base + 1];
                if (arg.isNumber()) break :blk arg.dup();
            } else if (argc == 2) {
                const arg0 = stack.values[base + 1];
                const arg1 = stack.values[base + 2];
                if (arg0.asInt32()) |v0| {
                    if (arg1.asInt32()) |v1| {
                        break :blk core.JSValue.int32(@max(v0, v1));
                    }
                }
                if (arg0.asFloat64()) |v0| {
                    if (arg1.asFloat64()) |v1| {
                        break :blk core.JSValue.float64(@max(v0, v1));
                    }
                }
            }
            return false;
        },
        else => return false,
    };

    var remaining = @as(usize, argc) + 1;
    while (remaining > 0) {
        remaining -= 1;
        const val = try stack.pop();
        val.free(ctx.runtime);
    }
    try stack.pushOwned(result);
    return true;
}

pub fn call(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    req_out: *call_runtime.InlineCallRequest,
) !CallStep {
    const argc = switch (opc) {
        op.call => blk: {
            const value = readInt(u16, function.code[frame.pc..][0..2]);
            frame.pc += 2;
            break :blk value;
        },
        op.call0 => 0,
        op.call1 => 1,
        op.call2 => 2,
        op.call3 => 3,
        else => unreachable,
    };
    return switch (try call_runtime.execCall(ctx, stack, function, frame, catch_target, argc, output, global, true, req_out)) {
        .done => .done,
        .continue_loop => .continue_loop,
        .inline_call => .inline_call,
    };
}

pub noinline fn tailCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    allow_inline: bool,
    req_out: *call_runtime.InlineCallRequest,
) !TailCallResult {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    switch (try call_runtime.execCall(ctx, stack, function, frame, catch_target, argc, output, global, allow_inline, req_out)) {
        .done => {},
        .continue_loop => return .handled,
        .inline_call => return .tail_inline,
    }
    if (stack.peek()) |value| return .{ .return_value = value };
    return .{ .return_value = core.JSValue.undefinedValue() };
}

pub noinline fn callMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    allow_inline: bool,
    req_out: *call_runtime.InlineCallRequest,
) !CallStep {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    // Inline frame fast path: a method call whose callable is a plain bytecode
    // function runs as an inline frame (like op.call), so method-position
    // recursion gets the logical call-depth limit instead of the shallow
    // native-recursion limit, and its tail-positioned method calls become
    // frame-reusing proper tail calls. Receiver, callable, and args stay on the
    // operand stack (zero-copy) at `[receiver, callable, args...]` until the
    // dispatch loop pushes the frame; the receiver becomes the callee's `this`
    // (arrow targets use their lexical `this`). Native builtin methods — the
    // common case — are not inline-eligible and fall through to the fast native
    // dispatch below. Class constructors (super() targets) are rejected by
    // `resolveInlineTarget`, so this never shadows the super-constructor path.
    if (allow_inline) {
        const total = @as(usize, argc) + 2;
        if (stack.values.len >= total) {
            const region_base = stack.values.len - total;
            const receiver = stack.values[region_base];
            const method = stack.values[region_base + 1];
            if (inline_calls.resolveInlineTarget(ctx, global, receiver, method)) |target| {
                req_out.* = .{ .target = target, .region_base = region_base, .argc = argc, .layout = .method };
                return .inline_call;
            }
        }
    }
    var inline_args: [4]core.JSValue = undefined;
    const args_buf: []core.JSValue = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.JSValue, args_buf);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args_buf[remaining] = try stack.pop();
    }
    defer for (args_buf) |arg| arg.free(ctx.runtime);
    const func = try stack.pop();
    defer func.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const fast_result = fastNativeMethodCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (fast_result) |value| {
        if (dropUnusedCallResult(ctx, function, frame, value)) return .done;
        errdefer value.free(ctx.runtime);
        try stack.pushOwned(value);
        return .done;
    }
    const maybe_array_result = collection_vm.qjsArrayMethodFastCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const result = if (maybe_array_result) |array_result|
        array_result
    else
        call_runtime.callValueOrBytecodeClassMode(ctx, output, global, obj, func, args_buf, function, frame, class_init_ops.isCurrentSuperConstructor(ctx, frame, func)) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    if (dropUnusedCallResult(ctx, function, frame, result)) return .done;
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    return .done;
}

fn dropUnusedCallResult(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    value: core.JSValue,
) bool {
    if (frame.pc >= function.code.len or function.code[frame.pc] != op.drop) return false;
    frame.pc += 1;
    value.free(ctx.runtime);
    return true;
}

pub noinline fn tailCallMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    allow_inline: bool,
    req_out: *call_runtime.InlineCallRequest,
) !TailCallMethodResult {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    // Inline frame-reuse fast path: a tail-positioned method call whose
    // callable is a plain bytecode function reuses the current inline frame
    // instead of recursing, mirroring op.tail_call. The receiver, callable,
    // and args stay on the operand stack (zero-copy) at
    // `[region_base ..][receiver, callable, args...]` until the dispatch loop
    // moves them into the reused frame; `resolveInlineTarget` binds the
    // receiver as the callee's `this` (or the arrow's lexical `this`). Native
    // builtin methods — the common case — are not inline-eligible and fall
    // through to the fast native dispatch below.
    if (allow_inline) {
        const total = @as(usize, argc) + 2;
        if (stack.values.len >= total) {
            const region_base = stack.values.len - total;
            const receiver = stack.values[region_base];
            const method = stack.values[region_base + 1];
            if (inline_calls.resolveInlineTarget(ctx, global, receiver, method)) |target| {
                req_out.* = .{ .target = target, .region_base = region_base, .argc = argc, .layout = .method };
                return .tail_inline;
            }
        }
    }
    var inline_args: [4]core.JSValue = undefined;
    const args_buf: []core.JSValue = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.JSValue, args_buf);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args_buf[remaining] = try stack.pop();
    }
    defer for (args_buf) |arg| arg.free(ctx.runtime);
    const func = try stack.pop();
    defer func.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const fast_result = fastNativeMethodCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .handled;
        return err;
    };
    if (fast_result) |value| {
        return .{ .return_value = value };
    }
    const maybe_array_result = collection_vm.qjsArrayMethodFastCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .handled;
        return err;
    };
    const result = if (maybe_array_result) |array_result|
        array_result
    else
        call_runtime.callValueOrBytecode(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .handled;
            return err;
        };
    return .{ .return_value = result };
}

fn fastNativeMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    // QuickJS uniform dispatch: the `call_method` opcode hot
    // path routes through the same builtins-owned internal record table the slow
    // record dispatch (`call.zig:callNativeFunctionRecord`) and the plain-call
    // VM fast path (`call_runtime.callNativeBuiltinRecordForVm`) use, so exec
    // carries zero compile-time knowledge of the migrated builtins. The retired
    // per-domain hot subset (math min/max primitives, the URI string fast path,
    // Number.parse{Int,Float}, String.fromCharCode / substring primitive, the
    // Array prototype hub, the collection / regexp / JSON record glue) is gone:
    // every one of those domains is table-backed, and the table handler is the
    // complete implementation, so a table HIT returns the final value here.
    //
    // This call site holds the materialized function object (pass non-null
    // `func_obj = function_object`). Resolve the realm global from the function
    // object (`objectRealmGlobal`, falling back to the caller `global`) exactly
    // as the plain-call VM fast path does before
    // `callNativeBuiltinRecordForVm` — a cross-realm method call
    // (`other.Object.keys(...)`) must create its result and throw its errors in
    // the callee's realm, not the caller's. The pre-table per-domain switch
    // never routed the realm-sensitive `.object` domain here (it fell through to
    // the realm-correct generic dispatch), so this resolution preserves that
    // behavior under the unified path. No `globals` slot array exists at this
    // site, so pass an empty slice; migrated handlers prefer `host_call.global`
    // and only consult `globals` on the bare-runtime `global == null` fallback,
    // which never triggers here.
    //
    // A table MISS returns null so the caller falls through to the array
    // fast-array storage fallback (`qjsArrayMethodFastCall`, which keeps the
    // name-based TypedArray slice/subarray path that has no native-builtin id)
    // and then the generic value/bytecode dispatch — the same fall-through the
    // non-table domains (`.atomics` / `.performance` / `.host` / `.promise`)
    // already relied on.
    const function_object = property_ops.expectObject(func) catch return null;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return null;
    const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
    return builtin_dispatch.callInternalRecord(ctx, output, function_global, &.{}, function_object, this_value, native_ref, args, caller_function, caller_frame);
}

pub noinline fn apply(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const is_new = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    const array_value = try stack.pop();
    defer array_value.free(ctx.runtime);
    const this_value = try stack.pop();
    defer this_value.free(ctx.runtime);
    const func = try stack.pop();
    defer func.free(ctx.runtime);
    const apply_args = try collection_vm.argsFromArray(ctx.runtime, array_value);
    defer call_runtime.freeArgs(ctx.runtime, apply_args);
    const allow_class_constructor_call = class_init_ops.isCurrentSuperConstructor(ctx, frame, func);
    const arrow_super_this = if (allow_class_constructor_call and !frame.function.flags.is_derived_class_constructor)
        class_init_ops.currentArrowLexicalSuperThis(ctx.runtime, frame)
    else
        null;
    defer if (arrow_super_this) |value| value.free(ctx.runtime);
    const arrow_constructor_this = if (allow_class_constructor_call and !frame.function.flags.is_derived_class_constructor)
        class_init_ops.currentArrowConstructorThis(ctx.runtime, frame)
    else
        null;
    defer if (arrow_constructor_this) |value| value.free(ctx.runtime);
    const is_arrow_super_constructor = allow_class_constructor_call and arrow_super_this != null;
    const effective_this = if (allow_class_constructor_call and frame.function.flags.is_derived_class_constructor)
        frame.constructorThisValue()
    else if (arrow_constructor_this) |value|
        value
    else if (arrow_super_this) |value|
        value
    else
        this_value;
    const result = if (is_new != 0) blk: {
        if (allow_class_constructor_call) {
            break :blk call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, this_value) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        }
        break :blk call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, func) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    } else call_runtime.callValueOrBytecodeClassMode(ctx, output, global, effective_this, func, apply_args, function, frame, allow_class_constructor_call) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (is_new != 0) {
        stack.pushOwned(result) catch |err| {
            result.free(ctx.runtime);
            return err;
        };
        return .done;
    }
    defer result.free(ctx.runtime);
    if (allow_class_constructor_call and frame.function.flags.is_derived_class_constructor) {
        if (slot_ops.varRefSlotIsUninitialized(frame.this_value)) {
            const next_this = if (result.isObject()) result else frame.constructorThisValue();
            try slot_ops.setSlotValue(ctx, &frame.this_value, next_this.dup());
            class_init_ops.initializeCurrentConstructorClassInstanceElements(ctx, output, global, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        } else {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        }
        try collection_vm.pushSlotValue(stack, frame.this_value);
        return .done;
    } else if (is_arrow_super_constructor) {
        if (arrow_super_this) |this_value_for_arrow| {
            if (!this_value_for_arrow.isUninitialized()) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
        }
        const next_this = if (result.isObject())
            result
        else if (arrow_constructor_this) |value|
            value
        else
            result;
        try class_init_ops.setCurrentArrowLexicalThis(ctx, frame, next_this.dup());
        try stack.push(next_this);
        return .done;
    }
    try stack.push(result);
    return .done;
}

pub noinline fn constructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    var inline_args: [4]core.JSValue = undefined;
    const args_buf: []core.JSValue = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.JSValue, args_buf);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args_buf[remaining] = try stack.pop();
    }
    defer for (args_buf) |arg| arg.free(ctx.runtime);
    const top = try stack.pop();
    const has_explicit_new_target = stack.len() != 0;
    const new_target = top;
    const func = if (has_explicit_new_target)
        stack.pop() catch |err| {
            top.free(ctx.runtime);
            return err;
        }
    else
        top;
    defer if (has_explicit_new_target) new_target.free(ctx.runtime);
    defer func.free(ctx.runtime);
    const result = call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, func, args_buf, function, frame, new_target) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    errdefer result.free(ctx.runtime);
    if (frame.function.flags.is_derived_class_constructor and class_init_ops.isCurrentSuperConstructor(ctx, frame, func)) {
        if (object_ops.functionObjectFromValue(frame.current_function)) |function_object| {
            if (function_object.functionHomeObjectSlot().*) |home_object| {
                const instance_object = try property_ops.expectObject(result);
                class_init_ops.initializeClassPrivateMethods(ctx.runtime, instance_object, home_object) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
            }
        }
    }
    try stack.pushOwned(result);
    return .done;
}

pub fn checkCtor(frame: *frame_mod.Frame) !void {
    if (frame.new_target.isUndefined()) return error.TypeError;
}

pub noinline fn checkCtorVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    checkCtor(frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn checkCtorReturn(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    if (value.isObject()) {
        try stack.pushOwned(core.JSValue.boolean(false));
    } else if (value.isUndefined()) {
        try stack.pushOwned(core.JSValue.boolean(true));
    } else {
        return error.TypeError;
    }
}

pub noinline fn checkCtorReturnVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    checkCtorReturn(ctx, stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn initCtor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    if (frame.new_target.isUndefined()) return error.TypeError;
    const function_object = try property_ops.expectObject(frame.current_function);
    const super = function_object.functionSuperConstructor() orelse return error.TypeError;
    const original_args = frame.originalArgs();
    const args = if (original_args.len != 0)
        original_args[0..@min(frame.actual_arg_count, original_args.len)]
    else
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)];
    const result = try call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, super, args, function, frame, frame.new_target);
    errdefer result.free(ctx.runtime);
    if (function_object.functionHomeObjectSlot().*) |home_object| {
        const instance_object = try property_ops.expectObject(result);
        try class_init_ops.initializeClassPrivateMethods(ctx.runtime, instance_object, home_object);
    }
    try stack.pushOwned(result);
}

pub noinline fn initCtorVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    initCtor(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

fn maxNativeJsCallDepth(ctx: *const core.JSContext) usize {
    return @max(@as(usize, 16), ctx.stack_limit / 16384);
}

/// Headroom (in native frames) before the recursive dispatcher must stop
/// growing the C stack and hand the deep sub-tree to the heap-frame Machine
/// path. The hard cap (`maxNativeJsCallDepth`, enforced by `enterCallDepth`)
/// still guarantees no native overflow; this only decides WHEN to fall back.
const native_depth_fallback_margin: usize = 8;

/// True when native recursion is close enough to the cap that the recursive
/// dispatcher should route the next call through the heap-frame `runWithArgsState`
/// path (which absorbs the remaining depth on the Machine at logical depth)
/// instead of recursing. See ARCH-RECURSIVE-REWRITE.md "S2a-v3".
pub fn nativeDepthNearCap(ctx: *const core.JSContext) bool {
    return ctx.native_call_depth + native_depth_fallback_margin >= maxNativeJsCallDepth(ctx);
}

fn maxLogicalJsCallDepth(ctx: *const core.JSContext) usize {
    return ctx.stack_limit;
}

fn maxJsCallDepth(ctx: *const core.JSContext) usize {
    return maxNativeJsCallDepth(ctx);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
