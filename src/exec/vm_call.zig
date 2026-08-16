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
const stack_mod = @import("stack.zig");

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
    /// OP_apply(1) materialized `[callable, new_target, args...]` in the
    /// caller's operand region. The constructor opcode adapter consumes the
    /// shared request metadata and enters with a constructor continuation.
    inline_constructor,
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
    planned_stack_bytes: usize,

    pub fn deinit(self: CallDepthGuard) void {
        const rt = self.ctx.runtime;
        std.debug.assert(rt.hot.active_bytecode_stack_bytes >= self.planned_stack_bytes);
        rt.hot.active_bytecode_stack_bytes -= self.planned_stack_bytes;
        rt.hot.call_depth -= 1;
        rt.hot.native_call_depth -= 1;
    }
};

pub const CallProfileGuard = if (false) struct {
    rt: *core.JSRuntime,
    previous: ?*core.profile.OpcodeProfile,

    pub fn deinit(self: @This()) void {
        if (self.rt.opcode_profile != null) {
            _ = core.profile.activate(self.previous);
        }
    }

    /// A proper-tail-call replacement enters the callee while the caller is
    /// still current so every fallible setup edge remains catchable by that
    /// caller. Once setup succeeds, only the callee guard survives; make its
    /// eventual restore skip the retired caller's activation level.
    pub fn adoptRetiredCaller(self: *@This(), retired: @This()) void {
        std.debug.assert(self.rt == retired.rt);
        self.previous = retired.previous;
    }
} else struct {
    pub fn deinit(_: @This()) void {}

    pub fn adoptRetiredCaller(_: *@This(), _: @This()) void {}
};

pub fn enterCallDepth(
    ctx: *core.JSContext,
    global: *core.Object,
    planned_stack_bytes: usize,
) !CallDepthGuard {
    const rt = ctx.runtime;
    if (rt.hot.native_call_depth >= maxNativeJsCallDepth(ctx) or
        rt.hot.call_depth >= maxLogicalJsCallDepth(ctx) or
        bytecodeStackBudgetWouldOverflow(rt, planned_stack_bytes))
    {
        // QuickJS JS_CallInternal stack guard -> JS_ThrowStackOverflow =
        // InternalError "stack overflow" (quickjs.c:17837, 7789-7791).
        _ = exception_ops.throwInternalErrorMessage(ctx, global, "stack overflow") catch |err| return err;
        return error.StackOverflow;
    }
    rt.hot.active_bytecode_stack_bytes += planned_stack_bytes;
    rt.hot.call_depth += 1;
    rt.hot.native_call_depth += 1;
    return .{ .ctx = ctx, .planned_stack_bytes = planned_stack_bytes };
}

/// Accounting for inline (same interpreter loop) bytecode call frames.
pub fn enterInlineCallDepth(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    argc: usize,
) !void {
    return enterInlineCallDepthMode(ctx, global, function, argc, false);
}

pub fn enterInlineCallDepthMode(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    argc: usize,
    copy_argv: bool,
) !void {
    if (!canEnterInlineCallDepthMode(ctx, function, argc, copy_argv)) {
        return inlineCallDepthOverflow(ctx, global);
    }
    commitInlineCallDepthMode(ctx, function, argc, copy_argv);
}

/// QuickJS JS_CallInternal's planned `alloca_size` for a normal bytecode
/// target called without COPY_ARGV (quickjs.c:17828-17836). Tail opcodes use
/// flags=0, so only missing arguments allocate the padded argv prefix.
pub fn qjsBytecodeFrameAllocaSize(
    function: *const bytecode.FunctionBytecode,
    argc: usize,
    copy_argv: bool,
) usize {
    const allocated_arg_count: usize = if (copy_argv or argc < @as(usize, function.arg_count))
        function.arg_count
    else
        0;
    const value_slots = allocated_arg_count +
        @as(usize, function.var_count) +
        @as(usize, function.stack_size);
    return value_slots * @sizeOf(core.JSValue) +
        @as(usize, function.var_ref_count) * @sizeOf(*core.VarRef);
}

/// Leaf-family pricing of `qjsBytecodeFrameAllocaSize`. Every published leaf
/// commits with copy_argv=false and argc >= arg_count (empty/forwarded leaves
/// are zero-arg bodies; the exact-args family asserts argc == arg_count), so
/// the qjs padded-argv prefix is always empty and the figure collapses to
/// function-header scalars — no argc load and no pricing select on the
/// per-return release path.
pub inline fn qjsBytecodeLeafFrameAllocaSize(
    function: *const bytecode.FunctionBytecode,
) usize {
    const value_slots = @as(usize, function.var_count) + @as(usize, function.stack_size);
    return value_slots * @sizeOf(core.JSValue) +
        @as(usize, function.var_ref_count) * @sizeOf(*core.VarRef);
}

inline fn bytecodeStackBudgetWouldOverflow(
    rt: *const core.JSRuntime,
    planned_stack_bytes: usize,
) bool {
    const accumulated = std.math.add(
        usize,
        rt.hot.active_bytecode_stack_bytes,
        planned_stack_bytes,
    ) catch return true;
    return rt.checkNativeStackOverflow(accumulated);
}

pub inline fn canEnterInlineCallDepth(
    ctx: *const core.JSContext,
    function: *const bytecode.FunctionBytecode,
    argc: usize,
) bool {
    return canEnterInlineCallDepthMode(ctx, function, argc, false);
}

pub inline fn canEnterInlineCallDepthMode(
    ctx: *const core.JSContext,
    function: *const bytecode.FunctionBytecode,
    argc: usize,
    copy_argv: bool,
) bool {
    return canEnterInlineCallDepthBytes(ctx, qjsBytecodeFrameAllocaSize(function, argc, copy_argv));
}

/// Byte-priced variants: constructors that already hold the planned frame
/// bytes (to persist them into the Entry for the O(1) teardown release) check
/// and commit that exact figure instead of re-deriving it from the function
/// header.
pub inline fn canEnterInlineCallDepthBytes(
    ctx: *const core.JSContext,
    planned_stack_bytes: usize,
) bool {
    const rt = ctx.runtime;
    return rt.hot.call_depth < maxLogicalJsCallDepth(ctx) and
        !bytecodeStackBudgetWouldOverflow(rt, planned_stack_bytes);
}

pub inline fn commitInlineCallDepth(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    argc: usize,
) void {
    commitInlineCallDepthMode(ctx, function, argc, false);
}

pub inline fn commitInlineCallDepthMode(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    argc: usize,
    copy_argv: bool,
) void {
    commitInlineCallDepthBytes(ctx, qjsBytecodeFrameAllocaSize(function, argc, copy_argv));
}

pub inline fn commitInlineCallDepthBytes(
    ctx: *core.JSContext,
    planned_stack_bytes: usize,
) void {
    const rt = ctx.runtime;
    std.debug.assert(std.math.maxInt(usize) - rt.hot.active_bytecode_stack_bytes >= planned_stack_bytes);
    rt.hot.active_bytecode_stack_bytes += planned_stack_bytes;
    rt.hot.call_depth += 1;
}

/// K2 fused admission+commit for the warm leaf constructors: the check and
/// the commit RMW run back-to-back on one caller-supplied `rt` (no chunk or
/// carve stores in between), so the whole budget transaction is a single
/// hot-line load cluster instead of the admission/commit split that reloaded
/// ctx→runtime after the arena carve's aliasing store (M1 dossier K2: rt
/// reloads #3/#4). Mirrors qjs check-then-alloca where the check IS the
/// commitment (quickjs.c:17837/17845); a later chunk/carve miss must retreat
/// the charge via `retreatInlineCallDepthBytesMiss` before the pure-miss
/// null return. `bytecodeStackBudgetWouldOverflow` already rejects a wrapping
/// add, so the commit needs no second overflow assert.
pub inline fn tryCommitInlineCallDepthBytesRt(
    rt: *core.JSRuntime,
    planned_stack_bytes: usize,
) bool {
    if (rt.hot.call_depth >= maxLogicalJsCallDepthRt(rt) or
        bytecodeStackBudgetWouldOverflow(rt, planned_stack_bytes)) return false;
    rt.hot.active_bytecode_stack_bytes += planned_stack_bytes;
    rt.hot.call_depth += 1;
    return true;
}

/// K2 cold unwind: commit-before-carve means a warm constructor's rare
/// chunk/carve miss holds an already-committed budget charge; retreat it so
/// the authoritative slow constructor re-enters from balanced accounting.
/// noinline keeps the unwind bl-only on the warm body's miss exits.
pub noinline fn retreatInlineCallDepthBytesMiss(
    rt: *core.JSRuntime,
    planned_stack_bytes: usize,
) void {
    leaveInlineCallDepthBytesRt(rt, planned_stack_bytes);
}

/// Bytes-priced sibling of `enterInlineCallDepthMode` for callers that keep
/// the planned figure alive across the push (Entry persistence + errdefer).
pub inline fn enterInlineCallDepthBytes(
    ctx: *core.JSContext,
    global: *core.Object,
    planned_stack_bytes: usize,
) !void {
    if (!canEnterInlineCallDepthBytes(ctx, planned_stack_bytes)) {
        return inlineCallDepthOverflow(ctx, global);
    }
    commitInlineCallDepthBytes(ctx, planned_stack_bytes);
}

pub inline fn leaveInlineCallDepthBytes(
    ctx: *core.JSContext,
    planned_stack_bytes: usize,
) void {
    leaveInlineCallDepthBytesRt(ctx.runtime, planned_stack_bytes);
}

/// rt-threaded sibling: the leaf pops load `rt` once BEFORE their inline
/// teardown's arena store, whose aliasing otherwise blocks CSE of the
/// ctx->runtime reload on the release path (M1 dossier K3).
pub inline fn leaveInlineCallDepthBytesRt(
    rt: *core.JSRuntime,
    planned_stack_bytes: usize,
) void {
    std.debug.assert(rt.hot.active_bytecode_stack_bytes >= planned_stack_bytes);
    rt.hot.active_bytecode_stack_bytes -= planned_stack_bytes;
    rt.hot.call_depth -= 1;
}

pub inline fn leaveInlineCallDepth(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    argc: usize,
) void {
    const planned_stack_bytes = qjsBytecodeFrameAllocaSize(function, argc, false);
    leaveInlineCallDepthBytes(ctx, planned_stack_bytes);
}

/// Preflight for a tail-call frame replacement. QuickJS's OP_tail_call enters
/// a nested JS_CallInternal, checks native SP minus the callee's planned
/// alloca, and leaves every caller blocked until the final callee returns.
/// zjs reuses physical Entry storage, so it carries those planned bytes in a
/// separate Runtime budget while also preserving logical call-depth balance.
/// Neither budget aliases the per-Realm interrupt counter.
pub fn checkTailCallChainStackBudget(
    ctx: *core.JSContext,
    global: *core.Object,
    planned_stack_bytes: usize,
) !void {
    const rt = ctx.runtime;
    if (rt.hot.call_depth >= maxLogicalJsCallDepth(ctx) or
        bytecodeStackBudgetWouldOverflow(rt, planned_stack_bytes))
    {
        return inlineCallDepthOverflow(ctx, global);
    }
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
    if (comptime true) {
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

pub inline fn initFrameLocals(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
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
    function: *const bytecode.FunctionBytecode,
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

    if (function.closureVar().len > 0) {
        // Canonical functions receive their complete capture array from their
        // function object. Reconstructing cells at frame entry would create a
        // second identity and revive the retired placeholder/copy/replace
        // path. Only the W1e legacy mutable module/fixture adapter may enter
        // without closure2 captures.
        if (function.legacyBytecodeAdapter() == null) return error.InvalidBytecode;
        const owned_refs = if (windows.var_refs) |cells| blk: {
            std.debug.assert(cells.len == function.closureVar().len);
            break :blk cells;
        } else blk: {
            if (use_inline_storage) {
                if (ctx.runtime.vm_stack.carveTyped(&ctx.runtime.memory, *core.VarRef, function.closureVar().len)) |window| break :blk window;
            }
            break :blk try allocFrameVarRefWindow(ctx, frame, function.closureVar().len);
        };
        var initialized: usize = 0;
        errdefer {
            for (owned_refs[0..initialized]) |cell| cell.freeCell(ctx.runtime);
        }
        for (function.closureVar(), 0..) |cv, idx| {
            owned_refs[idx] = try legacyInitialClosureVarRef(ctx, global, cv);
            initialized += 1;
        }
        frame.var_refs = owned_refs;
        return;
    }

    if (function.varRefNamesLen() == 0) return;
    if (function.legacyBytecodeAdapter() == null) return error.InvalidBytecode;
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
            const val = call_runtime.globalLexicalValueForGlobal(ctx, global, var_name) orelse try global.getProperty(var_name);
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

fn legacyInitialClosureVarRef(ctx: *core.JSContext, global: *core.Object, cv: bytecode.function_bytecode.BytecodeClosureVar) !*core.VarRef {
    switch (cv.closureType()) {
        .global, .global_ref, .global_decl => {
            const cell_value = try call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, cv.var_name);
            return core.VarRef.fromValue(cell_value) orelse {
                cell_value.free(ctx.runtime);
                return error.InvalidBytecode;
            };
        },
        else => {},
    }
    const initial_value = switch (cv.closureType()) {
        .global, .global_ref, .global_decl => core.JSValue.uninitialized(),
        .module_decl, .module_import => core.JSValue.uninitialized(),
        .local, .arg, .ref => call_runtime.globalLexicalValueForGlobal(ctx, global, cv.var_name) orelse try global.getProperty(cv.var_name),
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
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !Step {
    _ = output;
    _ = catch_target;
    const index: u32 = if (opc == op.fclosure) blk: {
        const value = readInt(u32, function.byteCode()[frame.pc..][0..4]);
        frame.pc += 4;
        break :blk value;
    } else blk: {
        const value: u32 = function.byteCode()[frame.pc];
        frame.pc += 1;
        break :blk value;
    };
    try collection_vm.pushFunctionClosure(ctx, frame, stack, function, global, index);
    return .done;
}

pub fn call(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    req_out: *call_runtime.InlineCallRequest,
) !CallStep {
    const argc = switch (opc) {
        op.call => blk: {
            const value = readInt(u16, function.byteCode()[frame.pc..][0..2]);
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

/// Generic tail-call helper. Source-emitted `op.tail_call` no longer
/// enters here — the dispatch table aliases it to `op_call` so the
/// empty-leaf / exact-args / simple_inline / pushExactSimple chain
/// stays on the same I-cache copy (X-89 rework).
pub noinline fn tailCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    allow_inline: bool,
    req_out: *call_runtime.InlineCallRequest,
) !TailCallResult {
    const argc = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    // Inline is allowed so JS→JS tails stay on the same Machine (qjs nested
    // JS_CallInternal). a4a301e0 forced allow_inline=false and broke
    // machine_inits==1 (forEach/JSON reviver `return helper()`). The
    // dispatch `.tail` arm must still pushCall, not tailCallReuse: reuse
    // is the H3 TCO pit (Error.stack drops outer, 20000-deep does not overflow).
    switch (try call_runtime.execCall(ctx, stack, function, frame, catch_target, argc, output, global, allow_inline, req_out)) {
        .done => {},
        .continue_loop => return .handled,
        .inline_call => return .tail_inline,
    }
    if (stack.peek()) |value| return .{ .return_value = value };
    return .{ .return_value = core.JSValue.undefinedValue() };
}

/// Result of `nativeMethodFastDispatch` — the outlined native c_function arm
/// of `op_call_method` (Phase 2a). `hit`/`caught` re-dispatch via `coldNext`;
/// `miss` falls through to the forwarding arm / `callMethod`.
pub const NativeFastDispatchResult = enum { hit, caught, miss };

/// Resolve the C-function record carried by a concrete native method object.
/// QuickJS reaches the same terminal through the class call hook, which reads
/// `p->u.cfunc.c_function` directly (quickjs.c:17746-17791). Keep the record
/// memoization shared by every opcode that already holds the method object.
pub inline fn resolvedNativeMethodRecord(
    ctx: *core.JSContext,
    method_obj: *core.Object,
) ?*const core.host_function.InternalRecord {
    if (method_obj.class_id != core.class.ids.c_function) return null;
    return method_obj.nativeRecord() orelse blk: {
        const native_id = method_obj.nativeFunctionId();
        const nref = core.function.decodeNativeBuiltinId(native_id) orelse return null;
        const record = ctx.runtime.internalBuiltinRecord(@intCast(@intFromEnum(nref.domain)), nref.id) orelse return null;
        method_obj.nativeRecordSlot().* = record;
        break :blk record;
    };
}

/// Call a record returned by `resolvedNativeMethodRecord`. The caller owns the
/// single call-entry interrupt poll and must keep receiver, method, and args
/// rooted across this observable call.
pub inline fn callResolvedNativeMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    method_obj: *core.Object,
    record: *const core.host_function.InternalRecord,
    receiver: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return builtin_dispatch.callInternalRecordDirect(
        ctx,
        output,
        global,
        &.{},
        method_obj,
        receiver,
        record,
        args,
        caller_function,
        caller_frame,
    );
}

/// Exec_direct hit twin of `callResolvedNativeMethod`. Stays off the
/// NativeCallEnvironment / typed-cproto tail so the internal-method seam
/// does not inherit the 0x1c0→0x1d0 frame tax.
pub inline fn callResolvedExecDirect(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    method_obj: *core.Object,
    receiver: core.JSValue,
    direct_ptr: *const anyopaque,
    args: []const core.JSValue,
    formal_length: usize,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return builtin_dispatch.callResolvedExecDirect(
        ctx,
        output,
        global,
        method_obj,
        receiver,
        direct_ptr,
        args,
        formal_length,
        caller_function,
        caller_frame,
    );
}

/// Outlined native c_function fast dispatch for `op_call_method`. Mirrors
/// `callMethod`'s native leg exactly (pollInterrupt → fastNativeMethodCall →
/// popOwnedStackRegion → dropUnusedCallResult → push) but skips callMethod's
/// call boundary for the ~85% native-method case (Phase 1 measurement). The
/// caller has already verified `method_obj.class_id == c_function`, so this
/// helper skips the `expectObject` + `class_id` re-check that `callMethod` →
/// `fastNativeMethodCall` would repeat. `forwards_call` records
/// (Function.prototype.call) return `.miss` so the forwarding arm in
/// `op_call_method` keeps its fused-frame optimization. On `.miss`, `frame.pc`
/// is restored to the argc operand so the fallthrough paths read it correctly.
pub noinline fn nativeMethodFastDispatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    method_obj: *core.Object,
    argc: u16,
) !NativeFastDispatchResult {
    const total: usize = @as(usize, argc) + 2;
    if (stack.len() < total) return error.StackUnderflow;
    const region_base = stack.len() - total;
    const receiver = stack.values[region_base];
    const args: []const core.JSValue = stack.values[region_base + 2 ..][0..argc];
    // Resolve the native record BEFORE polling or advancing pc. The record
    // resolution is side-effect-free (memoization is not user-observable), so
    // it is safe to do before the interrupt poll. On miss, no poll was done
    // and pc is untouched, so the fallthrough to callMethod sees the exact
    // same state as if this arm never ran — no double-poll hazard.
    const rec = resolvedNativeMethodRecord(ctx, method_obj) orelse return .miss;
    // Protect the forwarding optimization: Function.prototype.call's record
    // has forwards_call=true. Return miss so the forwarding arm in
    // op_call_method handles it with the fused-frame optimization.
    if (rec.forwards_call) return .miss;
    // Committed to native dispatch: advance pc and poll interrupts before
    // entering user-observable code (mirrors callMethod's poll-then-call).
    frame.pc += 2; // consume argc operand
    exception_ops.pollInterrupt(ctx, global) catch |err| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .caught;
        return err;
    };
    const result = callResolvedNativeMethod(
        ctx,
        output,
        global,
        method_obj,
        rec,
        receiver,
        args,
        function,
        frame,
    ) catch |err| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .caught;
        return err;
    };
    call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
    if (dropUnusedCallResult(ctx, function, frame, result)) return .hit;
    stack.pushOwnedAssumeCapacity(result);
    return .hit;
}

pub noinline fn callMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    allow_inline: bool,
    req_out: *call_runtime.InlineCallRequest,
) !CallStep {
    const argc = readInt(u16, function.byteCode()[frame.pc..][0..2]);
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
    exception_ops.pollInterrupt(ctx, global) catch |err| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
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
        call_runtime.callValueOrBytecodeRootPreRootedAfterInterruptPoll(ctx, output, global, obj, func, args, function, frame) catch |err| {
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
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    value: core.JSValue,
) bool {
    if (frame.pc >= function.byteCode().len or function.byteCode()[frame.pc] != op.drop) return false;
    frame.pc += 1;
    value.free(ctx.runtime);
    return true;
}

/// Generic tail method helper. Source-emitted `op.tail_call_method`
/// aliases `op_call_method` (same admission, including native fast
/// dispatch). Kept for handwritten/internal callers.
pub noinline fn tailCallMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    allow_inline: bool,
    req_out: *call_runtime.InlineCallRequest,
) !TailCallMethodResult {
    const argc = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    // Same as tailCall: allow inline so JS→JS tails stay on one Machine
    // (a4a301e0's allow_inline=false broke machine_inits). Dispatch must
    // pushCall, not reuse (H3 TCO pit).
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
    exception_ops.pollInterrupt(ctx, global) catch |err| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .handled;
        return err;
    };
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
        call_runtime.callValueOrBytecodeRootPreRootedAfterInterruptPoll(ctx, output, global, obj, func, args, function, frame) catch |err| {
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
    caller_function: ?*const bytecode.FunctionBytecode,
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
    // `func_obj = function_object`). Realm selection belongs to the final
    // record terminal: it loads the C_FUNCTION's owned RealmContext and global
    // as one view. Keep the caller global here so no fast-path-only fallback
    // can switch authority before record selection and stack preflight.
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
    const rec = resolvedNativeMethodRecord(ctx, function_object) orelse return null;
    return try callResolvedNativeMethod(ctx, output, global, function_object, rec, this_value, args, caller_function, caller_frame);
}

pub noinline fn apply(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    req_out: *call_runtime.InlineCallRequest,
) !CallStep {
    const is_new = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    if (is_new != 0) {
        // Parser-emitted constructor spread owns one operand transaction:
        // `[callable, new_target, materialized-array]`. Preserve it through
        // observable list creation. An eligible target rewrites only the array
        // suffix into final args; every fallback retains the authoritative
        // recursive [[Construct]] path.
        if (stack.len() < 3) return error.StackUnderflow;
        const region_base = stack.len() - 3;
        const func = stack.values[region_base];
        const new_target = stack.values[region_base + 1];
        const array_value = stack.values[region_base + 2];
        var apply_args = collection_vm.argsFromArray(ctx.runtime, array_value) catch |err| {
            call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
        defer call_runtime.freeArgs(ctx.runtime, apply_args);
        var apply_args_root = collection_vm.ValueSliceRoot{};
        apply_args_root.init(ctx.runtime, &apply_args);
        defer apply_args_root.deinit();

        if (call_runtime.resolveSameMachineSpreadConstructor(global, func, new_target)) |candidate| {
            const final_len = try std.math.add(usize, region_base + 2, apply_args.len);
            const current_len = stack.len();
            if (final_len > current_len) {
                stack.reserveAdditional(final_len - current_len) catch |err| {
                    call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
            }

            // reserveAdditional may relocate the backing. Keep the callable
            // and new.target in their original owned slots; replace only the
            // materialized-array suffix with the final moved argument list.
            const rooted_func = stack.values[region_base];
            const rooted_array = stack.values[region_base + 2];
            stack.values[region_base + 2] = core.JSValue.undefinedValue();
            stack.setLen(region_base + 2);
            rooted_array.free(ctx.runtime);
            for (apply_args, 0..) |*arg, index| {
                stack.values[region_base + 2 + index] = arg.*;
                arg.* = core.JSValue.undefinedValue();
            }
            stack.setLen(final_len);
            req_out.* = .{
                // The constructor adapter uses the receiver-independent
                // witness after reloading the committed operand region.
                .target = candidate.resolved.bind(core.JSValue.undefinedValue(), rooted_func),
                .region_base = region_base,
                .argc = @intCast(apply_args.len),
                .layout = .method,
            };
            return .inline_constructor;
        }

        const result = call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, new_target) catch |err| {
            call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
        errdefer result.free(ctx.runtime);
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        stack.pushOwnedAssumeCapacity(result);
        return .done;
    }

    // Parser-emitted ordinary spread has one rooted operand region:
    // `[callable, receiver, materialized-array]`. Build the argument snapshot
    // first. On an eligible target, recast that same region to
    // `[receiver, callable, args...]` and let the current Machine's ordinary
    // `.next` call driver consume it. This is an opcode call, not a native
    // Function.apply bridge, so no native fence or synthetic apply frame is
    // involved.
    if (stack.len() < 3) return error.StackUnderflow;
    const region_base = stack.len() - 3;
    const func = stack.values[region_base];
    const this_value = stack.values[region_base + 1];
    const array_value = stack.values[region_base + 2];
    var apply_args = collection_vm.argsFromArray(ctx.runtime, array_value) catch |err| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    defer call_runtime.freeArgs(ctx.runtime, apply_args);
    var apply_args_root = collection_vm.ValueSliceRoot{};
    apply_args_root.init(ctx.runtime, &apply_args);
    defer apply_args_root.deinit();

    if (inline_calls.resolveInlineTarget(ctx, global, this_value, func)) |target| {
        const final_len = try std.math.add(usize, region_base + 2, apply_args.len);
        const current_len = stack.len();
        if (final_len > current_len) {
            stack.reserveAdditional(final_len - current_len) catch |err| {
                call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        }

        // reserveAdditional may relocate the backing, so reload every slot.
        const rooted_func = stack.values[region_base];
        const rooted_this = stack.values[region_base + 1];
        const rooted_array = stack.values[region_base + 2];
        stack.values[region_base] = rooted_this;
        stack.values[region_base + 1] = rooted_func;
        stack.values[region_base + 2] = core.JSValue.undefinedValue();
        stack.setLen(region_base + 2);
        rooted_array.free(ctx.runtime);

        for (apply_args, 0..) |*arg, index| {
            stack.values[region_base + 2 + index] = arg.*;
            arg.* = core.JSValue.undefinedValue();
        }
        stack.setLen(final_len);
        req_out.* = .{
            .target = target,
            .region_base = region_base,
            .argc = @intCast(apply_args.len),
            .layout = .method,
        };
        return .inline_call;
    }

    const result = call_runtime.callValueOrBytecodeRootPreRooted(ctx, output, global, this_value, func, apply_args, function, frame) catch |err| {
        call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    call_runtime.popOwnedStackRegion(ctx.runtime, stack, region_base);
    stack.pushOwnedAssumeCapacity(result);
    return .done;
}

pub noinline fn constructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const argc = readInt(u16, function.byteCode()[frame.pc..][0..2]);
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
    const result = call_runtime.constructValueOrBytecodeWithNewTargetInternal(ctx, output, global, func, args_buf, function, frame, new_target) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    return .done;
}

fn throwCtorTypeError(ctx: *core.JSContext, global: *core.Object, message: []const u8) !void {
    _ = exception_ops.throwTypeErrorMessage(ctx, global, message) catch |err| return err;
    return error.TypeError;
}

pub fn checkCtor(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame) !void {
    if (frame.newTargetValue().isUndefined()) {
        return throwCtorTypeError(ctx, global, "class constructors must be invoked with 'new'");
    }
}

pub noinline fn checkCtorVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    checkCtor(ctx, global, frame) catch |err| {
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
        // qjs constructs this error in JS_CallInternal's caller_ctx, not the
        // derived constructor's own realm. A distinct sentinel preserves that
        // delayed materialization while carrying the exact qjs message.
        return error.DerivedConstructorReturn;
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
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    if (frame.newTargetValue().isUndefined()) {
        return throwCtorTypeError(ctx, global, "class constructors must be invoked with 'new'");
    }
    const function_object = try property_ops.expectObject(frame.current_function);
    // qjs OP_init_ctor performs JS_GetPrototype(ctx, func_obj) on every entry.
    // The class-definition-time super carrier is intentionally not
    // authoritative: Object.setPrototypeOf may have replaced the constructor's
    // live [[Prototype]]. Retain the live value across the observable
    // constructor call exactly as JS_GetPrototype's owned result does.
    const super_object = function_object.getPrototype() orelse
        return throwCtorTypeError(ctx, global, "not a function");
    const super = super_object.value().dup();
    defer super.free(ctx.runtime);
    const original_args = frame.originalArgs();
    const args = if (original_args.len != 0)
        original_args[0..@min(frame.actual_arg_count, original_args.len)]
    else
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)];
    const result = try call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, super, args, function, frame, frame.newTargetValue());
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
}

pub noinline fn initCtorVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
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
    return @max(@as(usize, 16), ctx.stackLimit() / 16384);
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
    return ctx.runtime.hot.native_call_depth + native_depth_fallback_margin >= maxNativeJsCallDepth(ctx);
}

fn maxLogicalJsCallDepth(ctx: *const core.JSContext) usize {
    return ctx.stackLimit();
}

/// rt-threaded twin of `maxLogicalJsCallDepth` (`ctx.stackLimit()` is exactly
/// `ctx.runtime.stackSize()` == `rt.hot.stack_size`); the fused K2 admission
/// already holds `rt`, and the direct field read avoids the by-value
/// `stackSize(self: JSRuntime)` receiver copy in unoptimized builds.
inline fn maxLogicalJsCallDepthRt(rt: *const core.JSRuntime) usize {
    return rt.hot.stack_size;
}

fn maxJsCallDepth(ctx: *const core.JSContext) usize {
    return maxNativeJsCallDepth(ctx);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
