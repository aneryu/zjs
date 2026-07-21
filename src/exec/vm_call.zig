const std = @import("std");
const build_options = @import("build_options");

const bytecode = @import("../bytecode.zig");
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
const value_slot = @import("value_slot.zig");
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
        // QuickJS JS_CallInternal stack guard -> JS_ThrowStackOverflow =
        // InternalError "stack overflow" (quickjs.c:17837, 7789-7791).
        _ = exception_ops.throwInternalErrorMessage(ctx, global, "stack overflow") catch |err| return err;
        return error.StackOverflow;
    }
    ctx.call_depth += 1;
    ctx.native_call_depth += 1;
    return .{ .ctx = ctx };
}

/// Depth accounting for inline (same interpreter loop) call frames.
pub fn enterInlineCallDepth(ctx: *core.JSContext, global: *core.Object) !void {
    if (ctx.call_depth >= maxLogicalJsCallDepth(ctx)) {
        return inlineCallDepthOverflow(ctx, global);
    }
    ctx.call_depth += 1;
}

/// Stack exhaustion is exceptional and constructs a JS error.  Keep it out of
/// the same-native-stack inline-call prologue: otherwise LLVM couples the
/// thrower's large error-union frame and callee-saved register set to every
/// ordinary JS call.  QJS likewise keeps this behind the unlikely
/// `js_check_stack_overflow` arm of `JS_CallInternal`.
noinline fn inlineCallDepthOverflow(ctx: *core.JSContext, global: *core.Object) !void {
    _ = exception_ops.throwInternalErrorMessage(ctx, global, "stack overflow") catch |err| return err;
    return error.StackOverflow;
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
    const count = @min(function.vardefs.len, frame.locals.len);
    for (function.vardefs[0..count], 0..) |vd, idx| {
        if (!value_ops.atomNameEql(ctx.runtime, vd.var_name, "this")) continue;
        value_slot.replaceBorrowed(ctx.runtime, &frame.locals[idx], slot_ops.adapterValueBorrow(frame.this_value));
        const this_cell = try frame.captureLocal(ctx.runtime, idx);
        value_slot.replaceOwned(ctx.runtime, &frame.this_value, this_cell.valueRef());
        return;
    }
}

pub inline fn initFrameLocals(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
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

    storage_transferred = true;
}

pub inline fn initFrameVarRefs(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    var_refs: []const *core.VarRef,
    use_inline_storage: bool,
    windows: frame_mod.FrameStorageWindows,
) !void {
    if (var_refs.len > 0) {
        const owned_refs = if (windows.var_refs) |cells| blk: {
            std.debug.assert(cells.len == var_refs.len);
            break :blk cells;
        } else blk: {
            if (use_inline_storage) {
                if (ctx.runtime.vm_stack.carveTyped(&ctx.runtime.memory, *core.VarRef, var_refs.len)) |window| break :blk window;
            }
            break :blk try allocFrameVarRefWindow(ctx, frame, var_refs.len);
        };
        // Inherit: pointer copy + rc++ per slot (qjs JS_CLOSURE_REF form,
        // quickjs.c:17322-17324).
        for (var_refs, 0..) |cell, idx| owned_refs[idx] = cell.dupCell();
        frame.var_refs = owned_refs;
        return;
    }

    if (function.closure_var.len > 0) {
        const owned_refs = if (windows.var_refs) |cells| blk: {
            std.debug.assert(cells.len == function.closure_var.len);
            break :blk cells;
        } else blk: {
            if (use_inline_storage) {
                if (ctx.runtime.vm_stack.carveTyped(&ctx.runtime.memory, *core.VarRef, function.closure_var.len)) |window| break :blk window;
            }
            break :blk try allocFrameVarRefWindow(ctx, frame, function.closure_var.len);
        };
        var initialized: usize = 0;
        errdefer {
            for (owned_refs[0..initialized]) |cell| cell.freeCell(ctx.runtime);
        }
        for (function.closure_var, 0..) |cv, idx| {
            owned_refs[idx] = try initialClosureVarRef(ctx, global, cv);
            initialized += 1;
        }
        frame.var_refs = owned_refs;
        return;
    }

    if (function.varRefNamesLen() == 0) return;
    const owned_refs = if (windows.var_refs) |cells| blk: {
        std.debug.assert(cells.len == function.varRefNamesLen());
        break :blk cells;
    } else blk: {
        if (use_inline_storage) {
            if (ctx.runtime.vm_stack.carveTyped(&ctx.runtime.memory, *core.VarRef, function.varRefNamesLen())) |window| break :blk window;
        }
        break :blk try allocFrameVarRefWindow(ctx, frame, function.varRefNamesLen());
    };
    var initialized: usize = 0;
    errdefer {
        for (owned_refs[0..initialized]) |cell| cell.freeCell(ctx.runtime);
    }
    var idx: usize = 0;
    while (idx < function.varRefNamesLen()) : (idx += 1) {
        const var_name = function.varRefName(idx);
        // Top-level script let/const: share the cell that already lives in the
        // ctx.lexicals VARREF slot (qjs frame.var_refs[idx] aliases the global
        // lexical cell, js_closure_define_global_var). Falls back to building a
        // fresh cell for ordinary globals (and before the VARREF slot exists).
        // In the var_ref_names path (top-level script frame only; module/closure
        // frames take the var_refs-passed path above), a lexical var-ref is a
        // .global_decl top-level let/const (the top frame has no .ref captures).
        const is_global_decl = function.varRefIsGlobalDeclAt(idx);
        if (is_global_decl) {
            // qjs check-before-create: the redeclaration gate (check_define_var,
            // mirrors JS_CheckDefineGlobalVar PASS1) must run BEFORE the
            // ctx.lexicals cell exists — otherwise a fresh `let foo` would see
            // its own cell via globalLexicalHas and falsely throw. Reserve an
            // uninitialized (TDZ) placeholder cell here. The define_var opcode
            // creates/shares the real ctx.lexicals VARREF cell after the check
            // passes and rebinds frame.var_refs[idx] to alias it (qjs
            // js_closure_define_global_var PASS2).
            const is_const = function.varRefIsConstAt(idx);
            const cell = try core.VarRef.createClosed(ctx.runtime, core.JSValue.uninitialized());
            cell.varRefIsConstSlot().* = is_const;
            cell.is_lexical = true;
            owned_refs[idx] = cell;
        } else if (call_runtime.globalLexicalCell(ctx, var_name)) |cell_value| {
            // Owned ref to the shared ctx.lexicals cell (already a cell by
            // construction; the JSValue handle transfers its refcount).
            owned_refs[idx] = core.VarRef.fromValue(cell_value) orelse unreachable;
        } else {
            const val = call_runtime.globalLexicalValueForGlobal(ctx, global, var_name) orelse global.getProperty(var_name);
            owned_refs[idx] = try core.VarRef.createClosed(ctx.runtime, val);
        }
        initialized += 1;
    }
    frame.var_refs = owned_refs;
}

/// Heap fallback for an owned frame var_refs array: a []JSValue storage
/// allocation windowed as pointer slots, so the uniform storage_values
/// teardown owns the memory (same layout the FrameSlab carve produces).
fn allocFrameVarRefWindow(ctx: *core.JSContext, frame: *frame_mod.Frame, count: usize) ![]*core.VarRef {
    const ptr_bytes = try std.math.mul(usize, @sizeOf(*core.VarRef), count);
    const value_slots = try std.math.divCeil(usize, ptr_bytes, @sizeOf(core.JSValue));
    const values = try frame.allocOwnedStorage(&ctx.runtime.memory, value_slots);
    return std.mem.bytesAsSlice(*core.VarRef, std.mem.sliceAsBytes(values)[0..ptr_bytes]);
}

fn initialClosureVarRef(ctx: *core.JSContext, global: *core.Object, cv: bytecode.function_bytecode.BytecodeClosureVar) !*core.VarRef {
    switch (cv.closureType()) {
        .global, .global_ref, .global_decl => {
            // qjs js_closure_global_var (quickjs.c:17228-17260): lexical env
            // VARREF -> global object VARREF property -> shared side-table
            // uninitialized cell, regardless of the cv's own lexical bit.
            // The helpers hand back owned refs to cells by construction.
            if (call_runtime.globalLexicalCell(ctx, cv.var_name)) |cell_value| {
                return core.VarRef.fromValue(cell_value) orelse unreachable;
            }
            if (call_runtime.globalObjectVarRefCell(global, cv.var_name)) |cell_value| {
                return core.VarRef.fromValue(cell_value) orelse unreachable;
            }
            const cell_value = try call_runtime.globalObjectGetUninitializedVar(ctx, global, cv.var_name);
            const cell = core.VarRef.fromValue(cell_value) orelse unreachable;
            if (cv.varKind() == .function_name) {
                cell.varRefIsFunctionNameSlot().* = true;
            }
            return cell;
        },
        else => {},
    }
    const initial_value = switch (cv.closureType()) {
        .global, .global_ref, .global_decl => core.JSValue.uninitialized(),
        .module_decl, .module_import => core.JSValue.uninitialized(),
        .local, .arg, .ref => call_runtime.globalLexicalValueForGlobal(ctx, global, cv.var_name) orelse global.getProperty(cv.var_name),
    };
    const cell = try core.VarRef.createClosed(ctx.runtime, initial_value);
    cell.varRefIsConstSlot().* = cv.isConst();
    cell.is_lexical = cv.isLexical();
    cell.varRefIsFunctionNameSlot().* = cv.varKind() == .function_name;
    return cell;
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
    try collection_vm.pushFunctionClosure(ctx, frame, stack, function, global, index, opc);
    return .done;
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
        if (stack.len() >= total) {
            const region_base = stack.len() - total;
            const receiver = stack.values[region_base];
            const method = stack.values[region_base + 1];
            if (inline_calls.resolveInlineTarget(ctx, global, receiver, method)) |target| {
                req_out.* = .{ .target = target, .region_base = region_base, .argc = argc, .layout = .method };
                return .inline_call;
            }
        }
    }
    // Zero-copy method-call sequence (mirrors execCall + qjs OP_call_method):
    // borrow `obj | func | args...` directly from the caller-owned operand stack
    // instead of popping them into a duplicated staging buffer. The region stays
    // on the stack (rooting obj/func/args for the whole call), and is popped and
    // released only after the call completes.
    const total: usize = @as(usize, argc) + 2;
    if (stack.len() < total) return error.StackUnderflow;
    const region_base = stack.len() - total;
    const obj = stack.values[region_base];
    const func = stack.values[region_base + 1];
    const args: []const core.JSValue = stack.values[region_base + 2 ..][0..argc];
    const fast_result = fastNativeMethodCall(ctx, output, global, obj, func, args, function, frame) catch |err| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (fast_result) |value| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (dropUnusedCallResult(ctx, function, frame, value)) return .done;
        stack.pushOwnedAssumeCapacity(value);
        return .done;
    }
    const maybe_array_result = collection_vm.qjsArrayMethodFastCall(ctx, output, global, obj, func, args, function, frame) catch |err| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const result = if (maybe_array_result) |array_result|
        array_result
    else
        call_runtime.callValueOrBytecodeClassModePreRooted(ctx, output, global, obj, func, args, function, frame, class_init_ops.isCurrentSuperConstructor(ctx, frame, func)) catch |err| {
            call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
    if (dropUnusedCallResult(ctx, function, frame, result)) return .done;
    stack.pushOwnedAssumeCapacity(result);
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
        if (stack.len() >= total) {
            const region_base = stack.len() - total;
            const receiver = stack.values[region_base];
            const method = stack.values[region_base + 1];
            if (inline_calls.resolveInlineTarget(ctx, global, receiver, method)) |target| {
                req_out.* = .{ .target = target, .region_base = region_base, .argc = argc, .layout = .method };
                return .tail_inline;
            }
        }
    }
    // Zero-copy method-call sequence (mirrors execCall + qjs OP_call_method):
    // borrow `obj | func | args...` directly from the caller-owned operand stack
    // instead of popping them into a duplicated staging buffer. The region stays
    // on the stack (rooting obj/func/args for the whole call), and is popped and
    // released only after the call completes.
    const total: usize = @as(usize, argc) + 2;
    if (stack.len() < total) return error.StackUnderflow;
    const region_base = stack.len() - total;
    const obj = stack.values[region_base];
    const func = stack.values[region_base + 1];
    const args: []const core.JSValue = stack.values[region_base + 2 ..][0..argc];
    const fast_result = fastNativeMethodCall(ctx, output, global, obj, func, args, function, frame) catch |err| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .handled;
        return err;
    };
    if (fast_result) |value| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        return .{ .return_value = value };
    }
    const maybe_array_result = collection_vm.qjsArrayMethodFastCall(ctx, output, global, obj, func, args, function, frame) catch |err| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .handled;
        return err;
    };
    const result = if (maybe_array_result) |array_result|
        array_result
    else
        call_runtime.callValueOrBytecodeClassModePreRooted(ctx, output, global, obj, func, args, function, frame, false) catch |err| {
            call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .handled;
            return err;
        };
    call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
    return .{ .return_value = result };
}

inline fn fastNativeMethodCall(
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
    // path routes through the same exec-owned internal record table the general
    // record dispatch (`call.zig:callNativeFunctionRecord`) and the plain-call
    // VM fast path (`call_runtime.callNativeBuiltinRecordForVm`) use, so exec
    // carries zero compile-time knowledge of individual native domains. The retired
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
    // and then the generic value/bytecode dispatch. Among encoded native
    // domains, only the separate host mechanism intentionally has no standard
    // record table.
    const function_object = property_ops.expectObject(func) catch return null;
    // This is specifically the native c_function fast path. Bytecode functions
    // use the same FunctionPayload kind, but qjs discriminates their overlaid
    // union by class before reading `u.cfunc`; do the same before interpreting
    // the shared call-cache slot as an InternalRecord. Bound/proxy/closure
    // callables likewise fall through to the generic dispatcher.
    if (function_object.class_id != core.class.ids.c_function) return null;
    // Divergence B: cache the resolved `*const InternalRecord` on the func-object
    // payload so the hot call skips the per-call native-id DECODE + record-table
    // LOOKUP, mirroring qjs `func = p->u.cfunc.c_function` (the dispatchable
    // handle lives on the object). SAFE memoization: `native_function_id` is
    // write-once at registration, and the resolved record is a comptime
    // `pub const` in `rt.internal_builtins` (rodata) — program-lifetime stable,
    // identical across runtimes, never dangles, so the memo can never go stale.
    // A MISS falls through to null exactly as the pre-memo decode/probe did.
    const rec = function_object.nativeRecord() orelse blk: {
        const nref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
        const r = ctx.runtime.internalBuiltinRecord(@intCast(@intFromEnum(nref.domain)), nref.id) orelse return null;
        function_object.nativeRecordSlot().* = r;
        break :blk r;
    };
    // qjs `ctx = p->u.cfunc.realm` (quickjs.c:17586): the callee realm is a DIRECT field
    // on the c_function object, one load — not the ~18-arm functionRealmGlobalPtr payload
    // chain + bound-recursion of objectRealmGlobal. The .function guard above lets us read
    // realm_global_ptr straight off the payload; the objectRealmGlobal fallback covers the
    // rare payload whose ptr is unset (dead for native builtins — always set at
    // materialization) so behavior stays byte-identical.
    const function_global = (function_object.nativeFunctionRealmGlobalPtr() orelse
        object_ops.objectRealmGlobal(function_object)) orelse global;
    return try builtin_dispatch.callInternalRecordDirect(ctx, output, function_global, &.{}, function_object, this_value, rec, args, caller_function, caller_frame);
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
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        }
        break :blk call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, func) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    } else call_runtime.callValueOrBytecodeClassMode(ctx, output, global, effective_this, func, apply_args, function, frame, allow_class_constructor_call) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (is_new != 0) {
        // super(...spread) parity with op.call_constructor: brand the derived
        // instance with the class's private methods before the class-fields
        // init closure reads `this.#m` (mirrors vm_call.constructor's install;
        // `allow_class_constructor_call` is exactly isCurrentSuperConstructor).
        if (allow_class_constructor_call and frame.function.flags.is_derived_class_constructor) {
            if (object_ops.functionObjectFromValue(frame.current_function)) |function_object| {
                if (function_object.functionHomeObject()) |home_object| {
                    const instance_object = property_ops.expectObject(result) catch |err| {
                        result.free(ctx.runtime);
                        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                        return err;
                    };
                    class_init_ops.initializeClassPrivateMethods(ctx.runtime, instance_object, home_object) catch |err| {
                        result.free(ctx.runtime);
                        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                        return err;
                    };
                }
            }
        }
        stack.pushOwned(result) catch |err| {
            result.free(ctx.runtime);
            return err;
        };
        return .done;
    }
    defer result.free(ctx.runtime);
    if (allow_class_constructor_call and frame.function.flags.is_derived_class_constructor) {
        if (slot_ops.adapterValueIsUninitialized(frame.this_value)) {
            const next_this = if (result.isObject()) result else frame.constructorThisValue();
            slot_ops.replaceAdapterOwned(ctx, &frame.this_value, next_this.dup());
            class_init_ops.initializeCurrentConstructorClassInstanceElements(ctx, output, global, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        } else {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        }
        try collection_vm.pushAdapterValue(stack, frame.this_value);
        return .done;
    } else if (is_arrow_super_constructor) {
        if (arrow_super_this) |this_value_for_arrow| {
            if (!this_value_for_arrow.isUninitialized()) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
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
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    errdefer result.free(ctx.runtime);
    if (frame.function.flags.is_derived_class_constructor and class_init_ops.isCurrentSuperConstructor(ctx, frame, func)) {
        if (object_ops.functionObjectFromValue(frame.current_function)) |function_object| {
            if (function_object.functionHomeObject()) |home_object| {
                const instance_object = try property_ops.expectObject(result);
                class_init_ops.initializeClassPrivateMethods(ctx.runtime, instance_object, home_object) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
            }
        }
    }
    try stack.pushOwned(result);
    return .done;
}

pub fn checkCtor(frame: *frame_mod.Frame) !void {
    if (frame.newTargetValue().isUndefined()) return error.TypeError;
}

pub noinline fn checkCtorVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    checkCtor(frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
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
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    checkCtorReturn(ctx, stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
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
    if (frame.newTargetValue().isUndefined()) return error.TypeError;
    const function_object = try property_ops.expectObject(frame.current_function);
    const super = function_object.functionSuperConstructor() orelse return error.TypeError;
    const original_args = frame.originalArgs();
    const args = if (original_args.len != 0)
        original_args[0..@min(frame.actual_arg_count, original_args.len)]
    else
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)];
    const result = try call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, super, args, function, frame, frame.newTargetValue());
    errdefer result.free(ctx.runtime);
    if (function_object.functionHomeObject()) |home_object| {
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
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
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
