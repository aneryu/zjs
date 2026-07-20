//! Inline bytecode-to-bytecode call machinery.
//! Same-loop frame push/pop for eligible plain bytecode calls.
//!
//! Mirrors QuickJS `JS_CallInternal`'s `OP_call` handling: when a bytecode
//! function calls another plain bytecode function, the dispatch loop pushes a
//! new frame onto this machine and keeps executing in the same loop instead
//! of recursing into a nested `runWithArgsState`. `op.return` pops the frame
//! and continues in the caller; exception unwinding walks the inline frames
//! looking for catch targets before the error escapes the loop.
//!
//! Only the common fast shape is inlined (normal function kind, no class
//! constructor, and same realm). Everything else keeps using the recursive slow path, which stays
//! fully supported; the two paths share all frame setup primitives.

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const exception_ops = @import("vm_exception_ops.zig");
const frame_mod = @import("frame.zig");
const object_ops = @import("object_ops.zig");
const call_runtime = @import("call_runtime.zig");
const forof_ops = @import("forof_ops.zig");
const stack_mod = @import("stack.zig");
const vm_call = @import("vm_call.zig");

const HostError = @import("exceptions.zig").HostError;

/// An eligible bytecode-to-bytecode call target resolved from a callable
/// value on the operand stack. All values are borrowed from the caller's
/// (rooted) operand stack region.
/// Operand-stack layout of an inline call's region, as seen by `pushFrame`.
pub const RegionLayout = enum {
    /// `[callable, args...]` — plain call; `this` defaults to undefined.
    plain,
    /// `[receiver, callable, args...]` — method call; receiver becomes `this`.
    method,
};

/// Compile-time `this` arm of an empty-leaf frame constructor. The published
/// leaf bit is mode-independent; the call adapter picks the arm from the call
/// shape (plain vs method region) and the view's is_strict/runtime_strict
/// bits, mirroring qjs JS_CallInternal where `this_obj` is the caller-supplied
/// raw word and only OP_push_this consults the callee's strict flag
/// (quickjs.c:17924-17944).
pub const LeafThis = enum {
    /// Sloppy plain call: borrow the realm global as the frame's `this`.
    sloppy_global,
    /// Raw-`this` plain call (strict function or arrow): preserve undefined
    /// `this` (no substitution). Arrow bytecode never consults the frame
    /// slot — lexical `this`/`new.target` are ordinary closure cells — so
    /// both modes share this arm.
    raw_undefined,
    /// Method call: move the raw receiver into the frame's owned `this`;
    /// identical for strict and sloppy callees (coercion, when sloppy,
    /// stays deferred to the this-reading opcodes).
    receiver,
};

pub const InlineTarget = struct {
    /// qjs `p->u.func.var_refs`, resolved once while the callable Object is hot.
    /// The callable below roots the owning Object; the immutable count lives on
    /// `fb`, exactly like qjs's `closure_var_count`. Keeping the bare pointer in
    /// the target avoids reloading the whole on-object union arm in each frame
    /// setup specialization.
    var_refs: [*]*core.VarRef,
    /// The callable closure value (becomes `frame.current_function`).
    callable: core.JSValue,
    fb: *const bytecode.FunctionBytecode,
    /// The pointer-stable per-FB cached execution view (`cachedBytecodeView`,
    /// built once per FB). Cache construction failure declines the same-Machine
    /// path before an InlineTarget exists; the authoritative generic call can
    /// execute the FB without this compatibility cache. qjs's OP_call hands
    /// `JS_CallInternal` only the 16B `func_obj` and the callee prologue
    /// dereferences `p->u.func.function_bytecode` (quickjs.c:17800) — zero
    /// struct freight. Keeping only pointers here keeps the target (and the
    /// `InlineCallRequest` riding through the dispatch driver) at qjs's
    /// scalars-only scale instead of dragging a by-value `Bytecode` through
    /// every call.
    view: *const bytecode.Bytecode,
    /// Raw receiver before [[Call]] `this` boxing: `undefined` for plain calls,
    /// the property base for method calls, or Function.call's explicit thisArg.
    /// Arrow bytecode ignores this frame binding and reads its ordinary lexical
    /// capture instead. Borrowed from the rooted operand region.
    this_value: core.JSValue,
    /// `new.target` is undefined for ordinary [[Call]]. Arrow bytecode reads
    /// its lexical value through the ordinary closure capture installed at
    /// creation time.
    new_target: core.JSValue,
    pub inline fn captureSlice(self: InlineTarget) []*core.VarRef {
        return self.var_refs[0..self.fb.var_refs_len];
    }
};

/// The receiver-independent result of proving that a callable is eligible for
/// same-Machine bytecode execution. Plain-call handlers may inspect the cached
/// execution view before binding the wider InlineTarget: the published empty
/// leaf shape needs only that view, while every other shape materializes the
/// receiver/callable/capture record on demand.
pub const ResolvedInlineFunction = struct {
    var_refs: [*]*core.VarRef,
    fb: *const bytecode.FunctionBytecode,
    view: *const bytecode.Bytecode,

    pub inline fn bind(self: ResolvedInlineFunction, receiver: core.JSValue, func: core.JSValue) InlineTarget {
        return .{
            .var_refs = self.var_refs,
            .callable = func,
            .fb = self.fb,
            .view = self.view,
            .this_value = receiver,
            .new_target = core.JSValue.undefinedValue(),
        };
    }
};

/// Prove the receiver-independent portion of inline-call eligibility. Keeping
/// this prefix separate lets OP_call0 enter a published empty leaf without
/// first constructing fields that its dedicated frame constructor cannot use.
pub inline fn resolveInlineFunction(global: *core.Object, func: core.JSValue) ?ResolvedInlineFunction {
    const function_object = object_ops.functionObjectFromValue(func) orelse return null;
    const function_data = function_object.bytecodeFunctionStoragePtr();
    const fb = function_data.function_bytecode orelse return null;
    std.debug.assert(function_data.captureSlice().len == fb.var_refs_len);
    if (fb.flags.func_kind != .normal) return null;
    if (fb.flags.is_class_constructor or fb.flags.is_derived_class_constructor) return null;
    // Realm gate: qjs reads `ctx = b->realm` from the shared FB. With FB now
    // resident directly in Object.u.func this is one dependent load, without a
    // per-closure realm cache or borrowed-holder registration.
    const function_global = if (fb.realm_global_header) |realm_header|
        @as(*core.Object, @fieldParentPtr("header", realm_header))
    else
        global;
    if (function_global != global) return null;
    // Bytecode-function publication creates this immutable compatibility view
    // once. qjs executes the FB directly; until zjs does too, a proven function
    // object makes the cached pointer non-null by construction.
    std.debug.assert(fb.cached_view != null);
    return .{
        .var_refs = function_data.var_refs,
        .fb = fb,
        .view = fb.cached_view.?,
    };
}

/// Resolve `func` to an inline-eligible bytecode call target for a call with
/// receiver `receiver` (`undefined` for plain calls, the property base for
/// method calls). Mirrors the plain-call leg of
/// `callValueOrBytecodeClassModeDispatch`; any condition that path
/// special-cases (class constructors, cross-realm calls, and async/generator
/// kinds) disqualifies the target so the slow
/// path keeps handling it. Direct eval captures use the ordinary indexed
/// var-ref cells and need no function-object binding overlay.
///
/// Arrow targets ARE eligible: their lexical `this` / `new.target` are
/// ordinary closure cells, so call-target resolution has no arrow arm.
pub inline fn resolveInlineTarget(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, func: core.JSValue) ?InlineTarget {
    _ = ctx;
    const resolved = resolveInlineFunction(global, func) orelse return null;
    return resolved.bind(receiver, func);
}

/// One active inline call level. Entries live in chunked, pointer-stable
/// storage; `frame`, `stack`, and the frame's execution view are referenced by
/// the dispatch loop and backtrace pc borrows while the level is alive.
/// Work the caller must finish after an inline callee returns. Ordinary calls
/// push the result and resume immediately. Proxy `get` validates the trap
/// result against the target's post-call descriptor; generic for-of consumes
/// the returned iterator-result object before resuming the loop body.
pub const ReturnAction = enum(u8) {
    next,
    proxy_get,
    for_of_next,
};

pub const ReturnContinuation = struct {
    action: ReturnAction,
    /// Tagged by `action`: an owned Atom for `.proxy_get`, the for-of bytecode
    /// depth operand for `.for_of_next`, and zero for `.next`.
    payload: u32,

    pub fn deinit(self: *ReturnContinuation, rt: *core.JSRuntime) void {
        if (self.action == .proxy_get and self.payload != core.atom.null_atom) {
            rt.atoms.free(@intCast(self.payload));
        }
        self.action = .next;
        self.payload = 0;
    }

    /// Move the owned atom into the caller's continuation slot.
    pub fn takeAtom(self: *ReturnContinuation) core.Atom {
        std.debug.assert(self.action == .proxy_get);
        std.debug.assert(self.payload != core.atom.null_atom);
        const atom_id: core.Atom = @intCast(self.payload);
        self.payload = 0;
        return atom_id;
    }

    pub fn takeForOfDepth(self: *ReturnContinuation) u8 {
        std.debug.assert(self.action == .for_of_next);
        const depth: u8 = @intCast(self.payload);
        self.payload = 0;
        return depth;
    }
};

pub const Entry = struct {
    const TeardownFlags = packed struct(u8) {
        simple: bool = false,
        has_native_caller: bool = false,
        empty_leaf: bool = false,
        /// Exact-args leaf twin of `empty_leaf`: same warm construction and
        /// one-ldp resume record, plus a caller-region args window whose
        /// values the return epilogue releases. Kept as a separate bit so
        /// the established zero-arg return arm retains its exact single-bit
        /// test (no args len probe on the argc==0 leaf family).
        exact_args_leaf: bool = false,
        /// Function.prototype.call forwarding into a published zero-arg leaf
        /// (O3): empty-leaf frame geometry PLUS the owned synthetic native
        /// `call` frame. A separate bit (never combined with `empty_leaf`)
        /// because the default-repr resume record overlays `native_caller`
        /// storage, which this shape needs live for observable backtraces —
        /// its return arm re-derives the caller resume through `prev`
        /// instead of reading the record, and the established leaf arms keep
        /// their exact single-bit tests.
        forwarded_leaf: bool = false,
        _padding: u3 = 0,
    };

    /// The Entry's sole persistent execution-view source is `frame.function`;
    /// `Vm.function` is only a reloadable hot dispatch cache. qjs likewise
    /// dispatches through one `JSFunctionBytecode *b` instead of mirroring it
    /// in an outer frame wrapper.
    frame: frame_mod.Frame,
    /// Keep Stack and the trailing control fields at their measured offsets
    /// after moving `new.target` out of the hot Frame. The extra default-repr
    /// word restores the 248-byte Entry whose closure/negative-control layout
    /// is stable; a 240-byte layout regressed those probes despite fewer ops.
    _stride_padding: [if (core.value.nan_boxing) 2 * @sizeOf(usize) else 0]u8 align(if (core.value.nan_boxing) @alignOf(usize) else 1),
    stack: stack_mod.Stack,
    catch_target: ?usize,
    arena_mark: core.VmStackArena.Mark,
    profile_guard: vm_call.CallProfileGuard,
    /// Static teardown shape plus ownership of the optional synthetic native
    /// Function.call frame. Both fit in the byte that previously held the
    /// simple-teardown boolean, so ordinary calls clear native ownership while
    /// publishing their existing setup shape. The frame's
    /// `OwnershipDisposition` remains the source of truth for `this`.
    teardown: TeardownFlags,
    return_action: ReturnAction,
    continuation_payload: u32,
    /// Native Function.call record skipped by transparent forwarding. Owned by
    /// this entry so a stack captured inside the bytecode target still sees the
    /// qjs frame order `target -> call (native) -> caller`.
    native_caller: core.JSValue,
    /// Caller's Entry, or null when the caller is the L0 frame — qjs
    /// `JSStackFrame.prev_frame` (quickjs.c:408, "NULL if first stack
    /// frame"). Together with `Machine.top` (≅ rt->current_stack_frame)
    /// this is the frame-navigation mechanism: qjs never derives a frame
    /// address from an index, it follows this pointer pair (set at
    /// quickjs.c:17869-17870, restored at the done: epilogue 20709).
    prev: ?*Entry,

    /// Move the post-call work out before this frame releases its resources.
    /// The returned value owns its action-tagged payload. The retired Entry keeps
    /// stale, non-owning bits until its slot is initialized by the next push;
    /// clearing them here only added two stores to every ordinary return.
    fn takeContinuation(self: *Entry) ReturnContinuation {
        return .{
            .action = self.return_action,
            .payload = self.continuation_payload,
        };
    }

    pub inline fn isEmptyLeaf(self: *const Entry) bool {
        return self.teardown.empty_leaf;
    }

    pub inline fn isExactArgsLeaf(self: *const Entry) bool {
        return self.teardown.exact_args_leaf;
    }

    pub inline fn isForwardedLeaf(self: *const Entry) bool {
        return self.teardown.forwarded_leaf;
    }

    /// Caller-resume record for the empty-leaf return arm, overlaid on Entry
    /// storage that is dead for empty-leaf entries. Default repr: the 16-byte
    /// `native_caller` value is live ONLY under `teardown.has_native_caller`
    /// (Function.prototype.call forwarding — never an empty leaf; every reader
    /// checks the flag first, including the backtrace resolver). Nan-boxed
    /// repr: `_stride_padding` is pure layout padding. The record holds the
    /// caller's {resume pc, resume sp} so the return arm restores them with
    /// one ldp instead of re-deriving them through the
    /// prev→frame.function→code.ptr→(+frame.pc) load chain that feeds the
    /// caller's next dispatch branch. Written once per empty-leaf push by
    /// `finishEmptyLeafFrame` (the single constructor tail for the shape).
    inline fn emptyLeafResumeWords(self: *Entry) *[2]usize {
        if (comptime core.value.nan_boxing) {
            comptime std.debug.assert(@sizeOf(@TypeOf(self._stride_padding)) == 2 * @sizeOf(usize));
            return @ptrCast(@alignCast(&self._stride_padding));
        }
        comptime std.debug.assert(@sizeOf(core.JSValue) == 2 * @sizeOf(usize));
        return @ptrCast(@alignCast(&self.native_caller));
    }

    pub inline fn setEmptyLeafResume(self: *Entry, resume_pc: [*]const u8, resume_sp: [*]core.JSValue) void {
        std.debug.assert(!self.teardown.has_native_caller);
        const words = self.emptyLeafResumeWords();
        words[0] = @intFromPtr(resume_pc);
        words[1] = @intFromPtr(resume_sp);
    }

    pub inline fn emptyLeafResumePc(self: *Entry) [*]const u8 {
        std.debug.assert(self.isEmptyLeaf() or self.isExactArgsLeaf());
        return @ptrFromInt(self.emptyLeafResumeWords()[0]);
    }

    pub inline fn emptyLeafResumeSp(self: *Entry) [*]core.JSValue {
        std.debug.assert(self.isEmptyLeaf() or self.isExactArgsLeaf());
        return @ptrFromInt(self.emptyLeafResumeWords()[1]);
    }

    /// Move post-call work from a retired frame into its tail-call replacement.
    fn adoptContinuation(self: *Entry, continuation: *ReturnContinuation) void {
        std.debug.assert(self.return_action == .next);
        std.debug.assert(self.continuation_payload == 0);
        self.return_action = continuation.action;
        self.continuation_payload = continuation.payload;
        continuation.action = .next;
        continuation.payload = 0;
    }

    inline fn canUseSimpleTeardown(self: *const Entry) bool {
        return self.teardown.simple and self.frame.cold == null and
            self.frame.ownership.storage == .borrowed and self.stack.isArenaWindow();
    }

    /// The synthetic native frame exists only for the transparent
    /// Function.prototype.call forwarding path. Keep its full JSValue release
    /// classifier out of every ordinary return instantiation; the hot caller
    /// performs only the ownership-bit test.
    noinline fn releaseNativeCaller(self: *Entry, rt: *core.JSRuntime) void {
        std.debug.assert(self.teardown.has_native_caller);
        self.native_caller.free(rt);
    }

    /// Release this frame after its continuation has been moved out. This is
    /// the abrupt/tail-replacement teardown: an empty-layout frame may still
    /// have live operand values when an opcode throws, so it must retain the
    /// authoritative Stack/Frame cleanup instead of using the normal-return
    /// leaf epilogue.
    inline fn deinit(self: *Entry, ctx: *core.JSContext) void {
        // Exact-args leaves must ALSO route through general teardown here:
        // their `frame.locals` is the empty-slice default (not the stack
        // base deinitSimple's live_values derivation assumes), and general
        // teardown releases the caller-region args window exactly once via
        // `deinitInlineCall` while leaving its borrowed backing untouched.
        // Forwarded leaves (O3) share the empty-slice geometry and rely on
        // general teardown's established `has_native_caller` release.
        if (self.teardown.empty_leaf or self.teardown.exact_args_leaf or
            self.teardown.forwarded_leaf)
            self.deinitGeneral(ctx)
        else if (self.canUseSimpleTeardown())
            self.deinitSimple(ctx)
        else
            self.deinitGeneral(ctx);
    }

    /// Normal-return teardown. The narrow leaf epilogue additionally requires
    /// an EMPTY callee operand window: the parser elides trailing
    /// expression-statement drops and leaves switch discriminants on the
    /// stack at `return` (qjs frees them in the done: local_buf..sp loop,
    /// quickjs.c:20701-20706), and the driver-side falloff completion peeks
    /// its result without popping. Those returns route through general
    /// teardown, which releases the remaining operand values exactly once.
    inline fn deinitReturned(self: *Entry, ctx: *core.JSContext) void {
        if (self.teardown.empty_leaf and self.stack.len() == 0)
            self.deinitEmptyLeaf(ctx)
        else
            self.deinit(ctx);
    }

    /// Outline wrapper for the cold consumers of the empty-leaf epilogue
    /// (driver-side `.returned` / falloff completions). The hot in-handler
    /// return arm uses `deinitEmptyLeafInline` directly so its non-zero
    /// refcount leg and arena restore run without a bl/ret round trip, with
    /// `destroyZeroRef` remaining the only (cold) call.
    noinline fn deinitEmptyLeaf(self: *Entry, ctx: *core.JSContext) void {
        self.deinitEmptyLeafInline(ctx);
    }

    /// Return epilogue for a published empty leaf. The bytecode view proves
    /// this frame has no arguments/local/capture/open-ref windows and cannot
    /// materialize FrameCold through arguments or direct eval — and, via the
    /// static return-balance proof gating publication
    /// (`codeProvesLeafReturnBalance`), that every return site completes with
    /// an EMPTY operand window (parser-elided leftover shapes are refused the
    /// flag), so the len==0 assert below holds without a runtime guard on the
    /// hot return arm. Exact argc=0 is
    /// checked by the call adapter before setting the flag. The callable —
    /// plus, for the method shape, the moved-in receiver (`this` `.owned`,
    /// mirroring `setupSimpleInlineEntryImpl`'s method arm and `deinitSimple`'s
    /// conditional release) — are the only owned JSValues; the arena watermark
    /// and optional profile guard are the only remaining resources. Plain
    /// leaves keep the borrowed sloppy-global `this`, so their ownership test
    /// stays a predicted-not-taken branch.
    inline fn deinitEmptyLeafInline(self: *Entry, ctx: *core.JSContext) void {
        const rt = ctx.runtime;
        const frame = &self.frame;
        std.debug.assert(self.teardown.simple);
        std.debug.assert(!self.teardown.has_native_caller);
        std.debug.assert(frame.cold == null);
        std.debug.assert(frame.ownership.current_function == .owned);
        std.debug.assert(frame.ownership.storage == .borrowed);
        std.debug.assert(frame.locals.len == 0 and frame.args.len == 0);
        std.debug.assert(frame.var_refs.len == 0 and frame.open_var_refs.len == 0);
        std.debug.assert(self.stack.isArenaWindow() and self.stack.len() == 0);
        if (frame.ownership.this_value == .owned) frame.this_value.free(rt);
        frame.current_function.freeObjectAssumeObject(rt);
        rt.vm_stack.restore(self.arena_mark);
        self.profile_guard.deinit();
    }

    /// Exact-args twin of `deinitEmptyLeafInline`: identical narrow normal-
    /// return epilogue plus the caller-region args release — qjs OP_call's
    /// post-return `for(i = -1; i < call_argc; i++) JS_FreeValue(ctx,
    /// call_argv[i])` (quickjs.c:18229-18232) collapsed into the callee
    /// teardown that runs at the same point on this path. The args window
    /// borrows the caller's operand slots above the retreated top, so only
    /// the VALUES are released; the backing region is reused by the caller's
    /// next push. Only the normal-return arm may use this: abrupt completion
    /// keeps general teardown (live operand values, cold state).
    ///
    /// Capture leaves (O2) publish the same teardown bit: their frame is the
    /// zero-arg member of this family (args window empty — the release loop
    /// zero-trips — with the same borrowed capture array), and they need this
    /// arm's operand-window guard because inherited-capture bodies read free
    /// names and may carry parser-elided leftovers at `return`.
    inline fn deinitExactArgsLeafInline(self: *Entry, ctx: *core.JSContext) void {
        const rt = ctx.runtime;
        const frame = &self.frame;
        std.debug.assert(self.teardown.simple);
        std.debug.assert(self.teardown.exact_args_leaf and !self.teardown.empty_leaf);
        std.debug.assert(!self.teardown.has_native_caller);
        std.debug.assert(frame.cold == null);
        std.debug.assert(frame.ownership.current_function == .owned);
        std.debug.assert(frame.ownership.storage == .borrowed);
        std.debug.assert(frame.locals.len == 0);
        std.debug.assert(frame.args.len == frame.function.arg_count);
        std.debug.assert(frame.args.len != 0 or frame.var_refs.len != 0);
        // Inherited captures are borrowed from the closure's cell array and
        // are never released here (deinitSimple's exact contract for
        // borrowed var_refs); the callee can never CREATE cells.
        std.debug.assert(frame.ownership.var_refs == .borrowed);
        std.debug.assert(frame.open_var_refs.len == 0);
        std.debug.assert(self.stack.isArenaWindow() and self.stack.len() == 0);
        if (frame.ownership.this_value == .owned) frame.this_value.free(rt);
        frame.current_function.freeObjectAssumeObject(rt);
        for (frame.args) |v| v.free(rt);
        rt.vm_stack.restore(self.arena_mark);
        self.profile_guard.deinit();
    }

    /// Forwarded-leaf twin of `deinitEmptyLeafInline` (O3): identical narrow
    /// normal-return epilogue plus the owned synthetic native `call` frame
    /// release. The forwarding adapter proved `native_caller` is a callable
    /// object (its record's `forwards_call` gate), so the release skips the
    /// full JSValue classifier exactly like the callable itself — qjs frees
    /// both the argument buffer entry for the target and the native frame's
    /// func_obj with plain object decrements on the same return edge
    /// (js_call_c_function done:, quickjs.c:18229-18232). Only the
    /// normal-return arm may use this: abrupt completion keeps general
    /// teardown, whose established cold `releaseNativeCaller` handles the
    /// same ownership.
    inline fn deinitForwardedLeafInline(self: *Entry, ctx: *core.JSContext) void {
        const rt = ctx.runtime;
        const frame = &self.frame;
        std.debug.assert(self.teardown.simple);
        std.debug.assert(self.teardown.forwarded_leaf and !self.teardown.empty_leaf);
        std.debug.assert(!self.teardown.exact_args_leaf);
        std.debug.assert(self.teardown.has_native_caller);
        std.debug.assert(frame.cold == null);
        std.debug.assert(frame.ownership.current_function == .owned);
        std.debug.assert(frame.ownership.storage == .borrowed);
        std.debug.assert(frame.locals.len == 0 and frame.args.len == 0);
        std.debug.assert(frame.var_refs.len == 0 and frame.open_var_refs.len == 0);
        std.debug.assert(self.stack.isArenaWindow() and self.stack.len() == 0);
        if (frame.ownership.this_value == .owned) frame.this_value.free(rt);
        frame.current_function.freeObjectAssumeObject(rt);
        self.native_caller.freeObjectAssumeObject(rt);
        rt.vm_stack.restore(self.arena_mark);
        self.profile_guard.deinit();
    }

    /// Straight-line qjs `done:` epilogue for the common arena-backed frame.
    inline fn deinitSimple(self: *Entry, ctx: *core.JSContext) void {
        const rt = ctx.runtime;
        const frame = &self.frame;
        std.debug.assert(self.canUseSimpleTeardown());
        std.debug.assert(frame.ownership.var_refs == .borrowed or frame.var_refs.len == 0);
        std.debug.assert(frame.locals.ptr + frame.locals.len == self.stack.values);
        if (frame.ownership.this_value == .owned) frame.this_value.free(rt);
        if (frame.ownership.current_function == .owned) frame.current_function.free(rt);
        if (self.teardown.has_native_caller) self.releaseNativeCaller(rt);
        if (frame.open_var_refs.len != 0) frame.closeOpenVarRefs(rt);
        // qjs done: close var refs first, then free local_buf..sp (quickjs.c:20701-20706).
        const live_values = frame.locals.ptr[0 .. frame.locals.len + self.stack.len()];
        for (live_values) |v| v.free(rt);
        for (frame.args) |v| v.free(rt);
        rt.vm_stack.restore(self.arena_mark);
        self.profile_guard.deinit();
    }

    /// General teardown for frames whose stack, cold state, or storage escaped
    /// the common arena-backed shape.
    fn deinitGeneral(self: *Entry, ctx: *core.JSContext) void {
        const rt = ctx.runtime;
        if (self.teardown.has_native_caller) self.releaseNativeCaller(rt);
        self.stack.deinit(rt);
        self.frame.deinitInlineCall(&rt.memory, rt);
        rt.vm_stack.restore(self.arena_mark);
        self.profile_guard.deinit();
    }
};

comptime {
    const expected_size: usize = if (core.value.nan_boxing) 248 else 256;
    if (@sizeOf(Entry) != expected_size) @compileError(std.fmt.comptimePrint(
        "inline Entry layout drifted: expected {d} bytes, found {d}",
        .{ expected_size, @sizeOf(Entry) },
    ));
}

/// The mutable execution resources for one active bytecode level. `frame`
/// owns the authoritative execution view (`frame.function`); the operand
/// stack and catch slot stay separate only because their storage lifetimes
/// differ from the frame slab. The struct itself is a borrowed view.
pub const ExecutionLevel = struct {
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    catch_target: *?usize,

    pub inline fn function(self: ExecutionLevel) *const bytecode.Bytecode {
        return self.frame.function;
    }
};

/// Invocation-root state shared by the inline-frame Machine and the dispatch
/// driver. There is exactly one instance per `runWithArgsState` invocation;
/// Machine and Vm borrow it instead of mirroring the L0 frame/stack/catch
/// pointers and entry policy in parallel fields.
pub const L0State = struct {
    level: ExecutionLevel,
    is_eval_code: bool = false,
    eval_global_var_bindings: bool = false,
    strict_unresolved_get_var: bool = false,
    generator_state: ?*core.Object = null,
    stop_on_yield: bool = false,
    stop_before_pc: ?usize = null,
    suspend_on_module_await: bool = false,
};

const entries_per_chunk: usize = 16;
const max_chunks: usize = 512;

/// Indexed resolver for an invocation node backed directly by Machine: index
/// 0 is the innermost inline frame, walking outward through Entry.prev to the
/// L0 frame; null past the end. Machine is initialized at its final address
/// before this resolver is published, so `data` has no parallel holder state.
pub fn resolveMachineBacktrace(data: ?*const anyopaque, index: usize) ?core.ActiveBacktraceSnapshot {
    const machine: *const Machine = @ptrCast(@alignCast(data.?));
    var remaining = index;
    var cursor = machine.top;
    while (cursor) |entry| {
        if (remaining == 0) return exception_ops.frameBacktraceSnapshot(&entry.frame);
        remaining -= 1;
        if (entry.teardown.has_native_caller) {
            if (remaining == 0) return nativeBacktraceSnapshot(entry.native_caller);
            remaining -= 1;
        }
        cursor = entry.prev;
    }
    if (remaining == 0) return exception_ops.frameBacktraceSnapshot(machine.l0.level.frame);
    return null;
}

fn nativeBacktraceSnapshot(function_value: core.JSValue) core.ActiveBacktraceSnapshot {
    return .{
        .function_name = core.atom.null_atom,
        .filename = core.atom.null_atom,
        .line_num = 0,
        .col_num = 0,
        .function_value = function_value,
        .is_native = true,
    };
}

pub const Machine = struct {
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    /// Borrowed invocation root, used when the inline chain reaches depth 0.
    l0: *const L0State,
    /// Chunked entry storage; only the first `chunk_count` slots are valid.
    /// The chunk-pointer array is heap-allocated lazily on the first inline
    /// push (capacity `max_chunks`), so a Machine that never pushes carries
    /// only a 16-byte empty slice instead of a 4 KiB inline array.
    chunks: []*[entries_per_chunk]Entry = &.{},
    chunk_count: usize = 0,
    depth: usize = 0,
    /// Current (innermost) live Entry, or null at depth 0 — qjs
    /// `rt->current_stack_frame` (quickjs.c:358). All frame ADDRESSES come
    /// from this pointer and the `Entry.prev` chain; `depth` stays purely
    /// for accounting (L0 boundary tests, backtrace length, slot reuse).
    /// Maintained in lockstep with `depth` by pushFrame/popFrame.
    top: ?*Entry = null,
    pub fn init(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, l0: *const L0State) Machine {
        return .{
            .ctx = ctx,
            .output = output,
            .global = global,
            .l0 = l0,
        };
    }

    /// Drains any leftover inline frames (error propagation out of the
    /// dispatch loop without a catch handler) and releases chunk storage.
    /// Draining mirrors the per-level `errdefer` of the recursive path:
    /// abrupt-completion destructuring iterators are closed before each
    /// frame is torn down.
    pub fn deinit(self: *Machine) void {
        while (self.depth > 0) {
            const entry = self.topEntry();
            call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(self.ctx, self.output, self.global, &entry.stack, &entry.frame);
            var continuation = self.popFrame();
            continuation.deinit(self.ctx.runtime);
        }
        for (self.chunks[0..self.chunk_count]) |chunk| {
            self.ctx.runtime.memory.destroy(@TypeOf(chunk.*), chunk);
        }
        self.chunk_count = 0;
        if (self.chunks.len != 0) {
            self.ctx.runtime.memory.free(*[entries_per_chunk]Entry, self.chunks);
            self.chunks = &.{};
        }
    }

    /// The current Entry — the cached `top` pointer (qjs reads
    /// `rt->current_stack_frame` directly, quickjs.c:2864), NOT re-derived
    /// from the depth index: `entryAt`'s chunk math costs a umaddl chain on
    /// every use, and qjs never computes a frame address from an index.
    pub fn topEntry(self: *Machine) *Entry {
        std.debug.assert(self.depth > 0);
        return self.top.?;
    }

    /// Load the current execution resources without materializing a 24-byte
    /// aggregate. This shape is load-bearing for the tail-call driver, which
    /// refreshes these caches on every reused frame.
    pub inline fn loadCurrentLevel(
        self: *Machine,
        frame: **frame_mod.Frame,
        stack: **stack_mod.Stack,
        catch_target: **?usize,
    ) void {
        if (self.depth == 0) {
            frame.* = self.l0.level.frame;
            stack.* = self.l0.level.stack;
            catch_target.* = self.l0.level.catch_target;
        } else {
            const entry = self.topEntry();
            frame.* = &entry.frame;
            stack.* = &entry.stack;
            catch_target.* = &entry.catch_target;
        }
    }

    /// Borrowed current-level view for cold setup, return, and unwind paths.
    pub inline fn currentLevel(self: *Machine) ExecutionLevel {
        var level: ExecutionLevel = undefined;
        self.loadCurrentLevel(&level.frame, &level.stack, &level.catch_target);
        return level;
    }

    pub fn entryAt(self: *Machine, index: usize) *Entry {
        return &self.chunks[index / entries_per_chunk][index % entries_per_chunk];
    }

    fn acquireSlot(self: *Machine, global: *core.Object) HostError!*Entry {
        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index < self.chunk_count) return self.entryAt(index);
        return self.acquireSlotSlow(global, index, chunk_index);
    }

    /// Allocate the first slot in a new chunk, or report logical stack
    /// exhaustion.  Once a depth has been visited, `acquireSlot` stays entirely
    /// on its pointer-arithmetic fast arm; keeping allocation/error construction
    /// here prevents their register pressure from entering every call frame.
    noinline fn acquireSlotSlow(self: *Machine, global: *core.Object, index: usize, chunk_index: usize) HostError!*Entry {
        if (chunk_index >= max_chunks) {
            // QuickJS throws InternalError "stack overflow" for call-depth
            // exhaustion (JS_ThrowStackOverflow at the JS_CallInternal guard,
            // quickjs.c:17837/7789), not a RangeError.
            _ = exception_ops.throwInternalErrorMessage(self.ctx, global, "stack overflow") catch |err| return err;
            return error.StackOverflow;
        }
        if (self.chunks.len == 0) {
            self.chunks = try self.ctx.runtime.memory.alloc(*[entries_per_chunk]Entry, max_chunks);
        }
        std.debug.assert(chunk_index == self.chunk_count);
        const chunk = try self.ctx.runtime.memory.create([entries_per_chunk]Entry);
        self.chunks[chunk_index] = chunk;
        self.chunk_count += 1;
        return self.entryAt(index);
    }

    /// A compact view of the receiver/callable/argument window consumed by a
    /// new frame. Both caller-stack and temporary-owned sources use the same
    /// pointer + packed metadata representation; this avoids a 32-byte tagged
    /// union at the hottest setup boundary while retaining the ownership bit.
    pub const ArgsSource = struct {
        const Metadata = packed struct(u64) {
            arg_count: u62,
            has_receiver: bool,
            moved: bool,
        };

        /// First source slot. For caller-stack sources the caller has already
        /// retreated the Stack's authoritative top to this pointer, leaving
        /// the source window addressable in backing capacity during transfer.
        values: [*]core.JSValue,
        metadata: Metadata,

        fn initStack(start: [*]core.JSValue, argc: u16, has_receiver: bool) ArgsSource {
            return ArgsSource.init(start, argc, has_receiver, false);
        }

        fn initMoved(moved_values: []core.JSValue, has_receiver: bool) ArgsSource {
            const binding_count = 1 + @as(usize, @intFromBool(has_receiver));
            std.debug.assert(moved_values.len >= binding_count);
            return ArgsSource.init(moved_values.ptr, moved_values.len - binding_count, has_receiver, true);
        }

        fn init(values: [*]core.JSValue, arg_count: usize, has_receiver: bool, moved: bool) ArgsSource {
            return .{
                .values = values,
                .metadata = .{
                    .arg_count = @intCast(arg_count),
                    .has_receiver = has_receiver,
                    .moved = moved,
                },
            };
        }

        inline fn valueCount(self: ArgsSource) usize {
            return self.argCount() + 1 + @as(usize, @intFromBool(self.metadata.has_receiver));
        }

        inline fn slice(self: ArgsSource) []core.JSValue {
            return self.values[0..self.valueCount()];
        }

        inline fn argCount(self: ArgsSource) usize {
            return @intCast(self.metadata.arg_count);
        }
    };

    const FrameSetupPath = enum {
        generic,
        /// `pushCall` already proved both exact plain simple shapes false.
        /// Method, padded, snapshot, and general setup remain authoritative.
        generic_after_exact_plain,
        moved_method,
        borrowed_iterator,
    };

    /// Push an inline call frame for `target`. Shared between plain inline
    /// calls (`pushCall`) and tail-call frame reuse (`tailCallReuse`).
    /// `target` rides by pointer end-to-end (qjs OP_call passes only the 16B
    /// func_obj; nothing struct-sized is copied per call).
    /// Returns the new top entry so the caller can enter it directly — qjs's
    /// callee frame address is the `alloca` result already in a register
    /// (quickjs.c:17846); re-deriving it from the depth index (`topEntry()`)
    /// would redo the chunk multiply for nothing.
    fn pushFrame(self: *Machine, comptime setup_path: FrameSetupPath, global: *core.Object, target: *const InlineTarget, source: ArgsSource) align(64) HostError!*Entry {
        try vm_call.enterInlineCallDepth(self.ctx, global);
        errdefer self.ctx.call_depth -= 1;
        const entry = try self.acquireSlot(global);
        // Generic calls own an ordinary `.next` continuation immediately.
        // The moved and borrowed-iterator instances are reached only through
        // scoped push helpers, which publish their real action/payload after
        // setup succeeds. Until then the Entry is unlinked, so
        // initializing `.next/0` here merely writes two values that its sole
        // owner overwrites before any read.
        if (setup_path == .generic or setup_path == .generic_after_exact_plain) {
            entry.return_action = .next;
            entry.continuation_payload = 0;
        }
        if (setup_path == .borrowed_iterator) {
            try setupBorrowedIteratorEntry(self.ctx, entry, target);
        } else if (setup_path == .moved_method) {
            if (methodSimpleInlineMode(target, source)) |mode| switch (mode) {
                .moved_exact => try setupSimpleInlineEntry(false, false, false, true, true, self.ctx, global, entry, target, source),
                .moved_padded => try setupSimpleInlineEntry(false, false, true, true, true, self.ctx, global, entry, target, source),
                .moved_snapshot_exact => try setupSimpleInlineEntry(false, true, false, true, true, self.ctx, global, entry, target, source),
                .moved_snapshot_padded => try setupSimpleInlineEntry(false, true, true, true, true, self.ctx, global, entry, target, source),
                .stack_exact, .stack_padded, .stack_snapshot_exact, .stack_snapshot_padded => unreachable,
            } else {
                try setupInlineEntry(self.ctx, global, entry, target, source);
            }
        } else if (setup_path == .generic_after_exact_plain) {
            try setupFallbackInlineEntry(self.ctx, global, entry, target, source);
        } else if (isSimpleInlineFrame(target, source)) {
            try setupSimpleInlineEntry(false, false, false, false, false, self.ctx, global, entry, target, source);
        } else if (isStrictSimpleInlineFrame(false, target, source)) {
            try setupSimpleInlineEntry(true, false, false, false, false, self.ctx, global, entry, target, source);
        } else {
            try setupFallbackInlineEntry(self.ctx, global, entry, target, source);
        }
        // Link the new frame into the chain — qjs `sf->prev_frame =
        // rt->current_stack_frame; rt->current_stack_frame = sf;`
        // (quickjs.c:17869-17870).
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        return entry;
    }

    /// True when the frame takes the straight-line `setupSimpleInlineEntry` path:
    /// a sloppy, non-arrow plain call (no receiver, undefined `this` → global)
    /// with simple parameters (no original-args snapshot), no global-var rebinds,
    /// args that can be borrowed in place, and all-cell closure captures
    /// (borrowable as `var_refs`). Each rejected condition is exactly a branch
    /// the lean path elides; method, moved-method, arity-padding, and snapshot
    /// variants are selected by the outlined fallback. `setupInlineEntry`
    /// remains authoritative for arrows and non-simple parameters.
    fn isSimpleInlineFrame(target: *const InlineTarget, source: ArgsSource) bool {
        const function = target.view;
        // fb-derived half (normal, non-arrow, sloppy, simple params, no
        // global-var rebinds) is precomputed at view build:
        // one byte test instead of ~6 scattered FunctionBytecode bool loads
        // (the `ldrb [fb,#…]` cluster that dominated op_call). The remaining
        // checks below depend on the call site, not the bytecode.
        if (!function.simple_inline_eligible) return false;
        if (source.metadata.moved) return false; // tail-call reuse keeps the general path
        if (source.metadata.has_receiver) return false;
        if (!target.this_value.isUndefined()) return false;
        if (!canBorrowSourceArgs(function, source)) return false;
        // No captures check: `[]*core.VarRef` makes "every capture is a cell"
        // a type invariant (qjs js_closure2 slots are always JSVarRef*,
        // quickjs.c:17297-17331) — the allCapturesAreCellsCached memo and its
        // per-closure header-load loop are deleted by the phase-D flip.
        return true;
    }

    const PaddedSimpleInlineMode = enum {
        sloppy,
        strict,
        strict_snapshot,
    };

    const MethodSimpleInlineMode = enum {
        stack_exact,
        stack_padded,
        stack_snapshot_exact,
        stack_snapshot_padded,
        moved_exact,
        moved_padded,
        moved_snapshot_exact,
        moved_snapshot_padded,
    };

    /// Select the qjs `argc < arg_count` twin of a simple frame. qjs does not
    /// switch to a second frame constructor for this case: it prefixes the
    /// existing alloca region with `arg_count` slots, moves the supplied argv,
    /// and fills the missing tail with undefined (quickjs.c:17828-17861).
    /// Keep this call-site-dependent classification in the outlined fallback
    /// so exact-arity `pushFrame` retains its established hot shape.
    fn paddedSimpleInlineMode(target: *const InlineTarget, source: ArgsSource) ?PaddedSimpleInlineMode {
        const function = target.view;
        if (source.metadata.moved or source.metadata.has_receiver) return null;
        if (!target.this_value.isUndefined()) return null;
        if (source.argCount() >= function.arg_count) return null;
        if (function.simple_inline_eligible) return .sloppy;
        if (function.strict_simple_inline_eligible) return .strict;
        if (function.strict_simple_snapshot_inline_eligible) return .strict_snapshot;
        return null;
    }

    /// Select a simple frame for `[receiver, callable, args...]`, whether the
    /// region still occupies the caller stack or was moved aside for a Proxy
    /// continuation/tail-call reuse. Object and primitive receivers both
    /// transfer verbatim: qjs stores raw `this_obj` in this same
    /// JS_CallInternal frame and performs sloppy substitution or boxing only
    /// at OP_push_this (quickjs.c:17924-17944).
    fn methodSimpleInlineMode(target: *const InlineTarget, source: ArgsSource) ?MethodSimpleInlineMode {
        const function = target.view;
        if (!source.metadata.has_receiver) return null;
        if (!target.this_value.same(source.values[0])) return null;

        const snapshot = function.strict_simple_snapshot_inline_eligible;
        const no_snapshot = function.simple_inline_eligible or function.strict_simple_inline_eligible;
        if (!snapshot and !no_snapshot) return null;
        const padded = sourceArgCount(source) < function.arg_count;
        return if (!source.metadata.moved)
            if (snapshot)
                if (padded) .stack_snapshot_padded else .stack_snapshot_exact
            else if (padded)
                .stack_padded
            else
                .stack_exact
        else if (snapshot)
            if (padded) .moved_snapshot_padded else .moved_snapshot_exact
        else if (padded)
            .moved_padded
        else
            .moved_exact;
    }

    /// Strict-mode twin of `isSimpleInlineFrame`. qjs uses the same
    /// JS_CallInternal frame layout for strict and sloppy functions; the only
    /// plain-call difference is that strict preserves undefined `this` while
    /// sloppy substitutes the realm global. A separate precomputed flag and
    /// setup instantiation keep that choice off the established sloppy path.
    fn isStrictSimpleInlineFrame(comptime snapshot_args: bool, target: *const InlineTarget, source: ArgsSource) bool {
        const function = target.view;
        const eligible = if (snapshot_args)
            function.strict_simple_snapshot_inline_eligible
        else
            function.strict_simple_inline_eligible;
        if (!eligible) return false;
        if (source.metadata.moved or source.metadata.has_receiver) return false;
        if (!target.this_value.isUndefined()) return false;
        if (!canBorrowSourceArgs(function, source)) return false;
        return true;
    }

    /// Keep the arguments-snapshot specialization out of `pushFrame`: it is
    /// cold relative to the established sloppy and strict/no-arguments paths,
    /// and inlining its eligibility block grew the common dispatcher by 84B.
    /// All setup callees are noinline and this function only returns their
    /// result, allowing ReleaseFast to use a tail branch rather than another
    /// frame.
    noinline fn setupFallbackInlineEntry(ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        if (methodSimpleInlineMode(target, source)) |mode| switch (mode) {
            .stack_exact => return setupSimpleInlineEntry(false, false, false, true, false, ctx, global, entry, target, source),
            .stack_padded => return setupSimpleInlineEntry(false, false, true, true, false, ctx, global, entry, target, source),
            .stack_snapshot_exact => return setupSimpleInlineEntry(false, true, false, true, false, ctx, global, entry, target, source),
            .stack_snapshot_padded => return setupSimpleInlineEntry(false, true, true, true, false, ctx, global, entry, target, source),
            .moved_exact => return setupSimpleInlineEntry(false, false, false, true, true, ctx, global, entry, target, source),
            .moved_padded => return setupSimpleInlineEntry(false, false, true, true, true, ctx, global, entry, target, source),
            .moved_snapshot_exact => return setupSimpleInlineEntry(false, true, false, true, true, ctx, global, entry, target, source),
            .moved_snapshot_padded => return setupSimpleInlineEntry(false, true, true, true, true, ctx, global, entry, target, source),
        };
        if (paddedSimpleInlineMode(target, source)) |mode| switch (mode) {
            .sloppy => return setupSimpleInlineEntry(false, false, true, false, false, ctx, global, entry, target, source),
            .strict => return setupSimpleInlineEntry(true, false, true, false, false, ctx, global, entry, target, source),
            .strict_snapshot => return setupSimpleInlineEntry(true, true, true, false, false, ctx, global, entry, target, source),
        };
        if (isStrictSimpleInlineFrame(true, target, source)) {
            return setupSimpleInlineEntry(true, true, false, false, false, ctx, global, entry, target, source);
        }
        return setupInlineEntry(ctx, global, entry, target, source);
    }

    /// Straight-line frame setup for the plain/method simple-inline shapes —
    /// the hot fib/closure/method-call paths, a line-for-line mirror of qjs
    /// `JS_CallInternal`'s
    /// prologue (quickjs.c:17828-17871): compute the storage need, carve ONE
    /// contiguous slab, partition it by pointer arithmetic, bind every frame
    /// field exactly once. No shared-primitive calls, no `Frame.init`
    /// default-then-overwrite pass, no by-value `FrameSlab` /
    /// `FrameStorageWindows` round-trips. Every simple-case branch is resolved
    /// at compile time: a plain call borrows global/undefined `this`, while a
    /// method moves its receiver into the frame; original-args snapshot absent
    /// or arena-backed, exact-arity args borrowed or missing args padded at the
    /// slab front, borrowed all-cell var_refs. Lives
    /// in its OWN function so its register allocation is not coupled to the
    /// general path (whose register pressure spilled the hot fields). Ownership
    /// flags MUST mirror the general path exactly: current_function .take,
    /// plain this .borrow / method this .take, new_target borrowed, stack exact
    /// args borrowed / padded and temporary-region args moved, var_refs
    /// borrowed.
    ///
    /// `noinline` is LOAD-BEARING: the whole point is to keep this register
    /// allocation OFF the general `setupInlineEntry`/`pushFrame` chain. If LLVM
    /// inlines it back into `pushFrame`, the simple path's spills re-couple with
    /// the general path and the win evaporates (measured: 3.09x→3.26x qjs on fib).
    noinline fn setupSimpleInlineEntry(comptime strict_this: bool, comptime snapshot_args: bool, comptime pad_args: bool, comptime method_receiver: bool, comptime move_args: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        return setupSimpleInlineEntryImpl(strict_this, snapshot_args, pad_args, method_receiver, move_args, ctx, global, entry, target, source);
    }

    inline fn setupSimpleInlineEntryImpl(comptime strict_this: bool, comptime snapshot_args: bool, comptime pad_args: bool, comptime method_receiver: bool, comptime move_args: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        const rt = ctx.runtime;
        const function = target.view;
        entry.catch_target = null;
        // Whole-byte assignment also clears the native-caller ownership bit
        // left by any prior occupant of this reusable Entry slot.
        entry.teardown = .{ .simple = true };
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        // `move_args` makes the source variant compile-time fixed: ordinary
        // calls borrow/move out of their caller stack region, while Proxy
        // continuations and tail-call reuse consume a temporary owned region.
        // Both share `[receiver, callable, args...]` for method calls.
        comptime std.debug.assert(!move_args or method_receiver);
        std.debug.assert(source.metadata.moved == move_args);
        std.debug.assert(source.metadata.has_receiver == method_receiver);
        const receiver_count: usize = @intFromBool(method_receiver);
        const argc = source.argCount();
        const actual_arg_count = argc;
        const frame_arg_count: usize = if (pad_args) @intCast(function.arg_count) else actual_arg_count;
        const arg_storage_count: usize = if (pad_args or move_args) frame_arg_count else 0;
        const snapshot_count: usize = if (snapshot_args) actual_arg_count else 0;
        if (pad_args) {
            std.debug.assert(actual_arg_count < frame_arg_count);
        } else {
            std.debug.assert(actual_arg_count >= @as(usize, @intCast(function.arg_count)));
        }
        // Stack-region callers retreat top_ptr before crossing into frame
        // setup. `source.values` is that raw VM sp, so the call seam neither
        // reloads the backing base nor rebuilds a slice index. Source slots
        // remain addressable in backing capacity while ownership transfers;
        // refcounts keep them rooted, just as in the previous early-retreat
        // implementation.
        // On failure below nothing has been bound yet (`takeSourceSlot` runs
        // in the frame literal, after the last failable point). Release the
        // off-window source region directly, matching the general path's
        // `.full` cleanup without temporarily republishing it to the GC view.
        errdefer if (!move_args) {
            cleanupStackSource(rt, source);
        };

        // alloca_size (quickjs.c:17834-17836): optional padded args | locals |
        // operand stack | open var-ref slots | zjs original-args snapshot.
        // Exact args are borrowed in place (`arg_buf = argv`, 17841). Missing
        // args use qjs's `arg_allocated_size = b->arg_count` prefix (17828,
        // 17848-17857). var_refs remain borrowed from the closure (17844).
        const var_count: usize = function.var_count;
        const stack_count = @as(usize, function.stack_size) + 1;
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(function);
        const open_slots = if (open_var_ref_count == 0)
            0
        else
            (open_var_ref_count * @sizeOf(?*core.VarRef) + (@sizeOf(core.JSValue) - 1)) / @sizeOf(core.JSValue);
        const total = arg_storage_count + var_count + stack_count + open_slots + snapshot_count;

        // `local_buf = alloca(alloca_size)` (17846); the VM stack arena is
        // zjs's C stack. Warm arm first: one `carveActiveMarked` snapshot
        // yields the watermark and the window behind a single capacity branch
        // (the oversized-frame bound is subsumed — used never exceeds
        // chunk_slots), and `entry.arena_mark` is published only after the
        // carve, so LLVM no longer reloads chunk_count/active/used across a
        // may-alias Entry store the way the previous mark()+carve() pair did.
        // A miss is pure (arena untouched); the authoritative carve below
        // keeps chunk switching and first use, with heap fallback only when
        // the arena is exhausted.
        var storage_on_heap = false;
        const slab_values = if (rt.vm_stack.carveActiveMarked(total)) |active_carve| blk: {
            entry.arena_mark = active_carve.mark;
            break :blk active_carve.window;
        } else blk: {
            entry.arena_mark = rt.vm_stack.mark();
            break :blk rt.vm_stack.carve(&rt.memory, total) orelse heap: {
                const heap = try rt.memory.alloc(core.JSValue, total);
                storage_on_heap = true;
                break :heap heap;
            };
        };
        errdefer rt.vm_stack.restore(entry.arena_mark);
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, slab_values);

        // Pointer-arithmetic partition (17855-17866). Padded args occupy the
        // prefix exactly as qjs's `arg_buf = local_buf`; the zero-sized exact
        // specialization retains the prior locals-first layout.
        const arg_storage = slab_values[0..arg_storage_count];
        const locals_start = arg_storage_count;
        const stack_start = locals_start + var_count;
        const open_start = stack_start + stack_count;
        const snapshot_start = open_start + open_slots;
        const locals = slab_values[locals_start..][0..var_count];
        const stack_window = slab_values[stack_start..][0..stack_count];
        const open_var_refs: []?*core.VarRef = if (open_slots == 0)
            &.{}
        else
            std.mem.bytesAsSlice(?*core.VarRef, std.mem.sliceAsBytes(slab_values[open_start..][0..open_slots]))[0..open_var_ref_count];
        const original_args = slab_values[snapshot_start..][0..snapshot_count];

        @memset(locals, core.JSValue.undefinedValue()); // 17859-17860
        if (open_var_refs.len != 0) @memset(open_var_refs, null); // 17866-17867

        // The source slots stay live in the caller's arena capacity after its
        // logical stack length retreats. Rebuild their view only after the
        // slab carve, matching qjs's late argv consumption and avoiding an
        // args-start scalar live across every failable allocation point.
        const values = source.slice();
        const receiver_slot: ?*core.JSValue = if (method_receiver) &values[0] else null;
        const callable_slot = &values[receiver_count];
        const args = values[receiver_count + 1 ..][0..actual_arg_count];

        // zjs parameter writes update frame.args in place. An unmapped strict
        // arguments object must nevertheless expose the incoming values, so
        // its dedicated specialization snapshots them before the frame starts.
        // Allocate the cold box before takeSourceSlot: this is the final
        // failable point, preserving the source-restoration errdefer above.
        const cold: ?*frame_mod.Frame.FrameCold = if (snapshot_count == 0) null else blk: {
            const box = try rt.memory.create(frame_mod.Frame.FrameCold);
            for (args, 0..) |arg, index| original_args[index] = arg.dup();
            box.* = .{ .original_args = original_args };
            break :blk box;
        };

        // All failable setup is complete. Transfer supplied argument ownership
        // into the padded/moved prefix, clear the source slots, then initialize
        // only a missing tail. Exact caller-stack args continue borrowing the
        // original operand slots.
        const frame_args = if (pad_args or move_args) arg_storage else args;
        if (pad_args or move_args) {
            @memcpy(frame_args[0..actual_arg_count], args);
            @memset(args, core.JSValue.undefinedValue());
            if (pad_args) @memset(frame_args[actual_arg_count..], core.JSValue.undefinedValue());
        }

        const captures = target.captureSlice();
        // Bind the frame in ONE shot — qjs sets sf's handful of fields
        // (17838-17845) with no default-init-then-overwrite pass. The setup
        // instantiation makes the receiver choice at compile time: a method
        // takes the operand receiver; a strict plain call preserves undefined;
        // a sloppy plain call borrows the global (17933, sloppy leg). `pc`
        // keeps its struct default; `cold` is either null or the prebuilt
        // original-args snapshot box.
        entry.frame = .{
            .function = function,
            .this_value = if (method_receiver)
                takeSourceSlot(receiver_slot.?)
            else if (strict_this)
                core.JSValue.undefinedValue()
            else
                global.value(),
            .current_function = takeSourceSlot(callable_slot),
            .actual_arg_count = actual_arg_count,
            .locals = locals,
            .args = frame_args,
            .var_refs = captures,
            .open_var_refs = open_var_refs,
            .storage_values = if (storage_on_heap) slab_values else &.{},
            .ownership = .{
                .this_value = if (method_receiver) .owned else .borrowed,
                .var_refs = if (captures.len > 0) .borrowed else .owned,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
            .cold = cold,
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.vm_stack_arena_policy, stack_window);
    }

    /// Deep constructor for an exact simple frame. The common call path used to
    /// cross `pushFrame` and then `setupSimpleInlineEntry`, exposing the same
    /// target/source invariants at two seams. Keep this owner beside its
    /// straight-line setup implementation: depth guard, stable slot, frame
    /// setup, and link are one unit; every other shape retains the generic
    /// fallback above.
    ///
    /// The out-of-line symbol stays authoritative for every cold caller
    /// (driver fallback, strict/method shapes). The fixed-arity hot call
    /// handlers alone expand `pushExactSimpleFrameImpl` in place, so their
    /// steady-state loop crosses no bl/outparam seam: the error-union result
    /// otherwise round-trips through a caller stack slot (`strh`+`str` in the
    /// callee epilogue against an immediate `ldrh`+`ldr` readback after the
    /// return — a store-to-load forward across the call boundary) and the
    /// callee re-saves the caller's entire callee-saved register file.
    noinline fn pushExactSimpleFrame(
        self: *Machine,
        comptime strict_this: bool,
        comptime snapshot_args: bool,
        comptime method_receiver: bool,
        global: *core.Object,
        target: *const InlineTarget,
        source: ArgsSource,
    ) HostError!*Entry {
        return pushExactSimpleFrameImpl(self, strict_this, snapshot_args, method_receiver, global, target, source);
    }

    /// Shared straight-line body of `pushExactSimpleFrame`. `inline` is the
    /// point: the sloppy-exact instantiation expands directly inside the
    /// fixed-arity call opcode handlers while the noinline owner above keeps
    /// the single cold symbol for every other caller.
    inline fn pushExactSimpleFrameImpl(
        self: *Machine,
        comptime strict_this: bool,
        comptime snapshot_args: bool,
        comptime method_receiver: bool,
        global: *core.Object,
        target: *const InlineTarget,
        source: ArgsSource,
    ) HostError!*Entry {
        comptime std.debug.assert(!method_receiver or !strict_this);
        if (method_receiver) {
            std.debug.assert(!source.metadata.moved and source.metadata.has_receiver);
            std.debug.assert(target.this_value.same(source.values[0]));
            std.debug.assert(source.argCount() >= @as(usize, target.view.arg_count));
            if (snapshot_args) {
                std.debug.assert(target.view.strict_simple_snapshot_inline_eligible);
            } else {
                std.debug.assert(target.view.simple_inline_eligible or target.view.strict_simple_inline_eligible);
            }
        } else if (strict_this) {
            std.debug.assert(isStrictSimpleInlineFrame(false, target, source));
        } else {
            std.debug.assert(isSimpleInlineFrame(target, source));
        }
        try vm_call.enterInlineCallDepth(self.ctx, global);
        errdefer self.ctx.call_depth -= 1;
        const entry = try self.acquireSlot(global);
        entry.return_action = .next;
        entry.continuation_payload = 0;
        if (snapshot_args and method_receiver) {
            // Snapshot construction owns a cold FrameCold allocation. Reuse
            // its existing isolated implementation here; inlining that body
            // duplicates roughly a kilobyte of cold/error machinery merely to
            // remove one call instruction from this less common method shape.
            try setupSimpleInlineEntry(strict_this, snapshot_args, false, method_receiver, false, self.ctx, global, entry, target, source);
        } else {
            try setupSimpleInlineEntryImpl(strict_this, snapshot_args, false, method_receiver, false, self.ctx, global, entry, target, source);
        }
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        return entry;
    }

    /// Deep constructor for the published empty-leaf shape. Its adapter has
    /// already proved a call with exact argc (0 for the empty family,
    /// == arg_count for the exact-args family) and no locals,
    /// captures, open bindings, arguments materialization, or direct eval.
    /// Keeping that proof at this interface removes the general setup's
    /// geometry/capture selectors and initializes only the operand-stack arena
    /// that executing the leaf can actually use. `leaf_this` selects the
    /// region layout and the frame's `this` arm: `[callable, args...]` for
    /// plain calls (sloppy borrows the realm global, strict preserves
    /// undefined), `[receiver, callable, args...]` for method calls whose
    /// receiver becomes the callee's raw `this`. `exact_args` frames borrow
    /// the args window in place from the caller region (qjs `arg_buf = argv`,
    /// quickjs.c:17841).
    noinline fn pushEmptyLeafFrame(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        function: *const bytecode.Bytecode,
        region_start: [*]core.JSValue,
    ) HostError!*Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const ctx = self.ctx;
        const rt = ctx.runtime;
        assertLeafEligible(leaf_this, function);
        std.debug.assert(function.arg_count == 0 and function.var_count == 0);
        std.debug.assert(function.open_var_ref_count == 0);

        // The caller already retreated its logical operand top. Until the last
        // infallible transfer below, these slots remain the sole owners and
        // must be released even when depth/Entry acquisition fails — the same
        // full-region cleanup `cleanupStackSource` performs for the general
        // setup's failure arm.
        errdefer {
            freeSourceSlot(rt, &region_start[@intFromBool(method_receiver)]);
            if (method_receiver) freeSourceSlot(rt, &region_start[0]);
        }
        try vm_call.enterInlineCallDepth(ctx, global);
        errdefer ctx.call_depth -= 1;
        const entry = try self.acquireSlot(global);
        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);
        const stack_count = @as(usize, function.stack_size) + 1;
        var storage_on_heap = false;
        const stack_window = rt.vm_stack.carve(&rt.memory, stack_count) orelse blk: {
            const heap = try rt.memory.alloc(core.JSValue, stack_count);
            storage_on_heap = true;
            break :blk heap;
        };
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, stack_window);

        return self.finishEmptyLeafFrame(leaf_this, entry, global, function, region_start, stack_window, storage_on_heap, self.callerResumePc());
    }

    /// Exact-args authoritative constructor (O1) — the deep fallible twin of
    /// `pushEmptyLeafFrame` for a leaf whose call supplies exactly
    /// `arg_count > 0` arguments in the caller region
    /// (`[callable, args...]` / `[receiver, callable, args...]`). Kept as a
    /// SEPARATE body (not a comptime variant of the zero-arg constructor) so
    /// the established empty-leaf instantiations compile from byte-identical
    /// source: sharing one parameterized body measurably re-scheduled the
    /// zero-arg warm arms (LLVM tail-merged their frame-store blocks, adding
    /// a branch to the established sloppy const path).
    noinline fn pushExactArgsLeafFrame(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
    ) HostError!*Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const ctx = self.ctx;
        const rt = ctx.runtime;
        assertExactArgsLeafEligible(leaf_this, function);
        std.debug.assert(@as(usize, function.arg_count) == argc and argc > 0);
        std.debug.assert(function.var_count == 0);
        std.debug.assert(function.open_var_ref_count == 0);

        // Same sole-owner contract as the zero-arg constructor, extended over
        // the args window (reverse index order, mirroring cleanupStackSource).
        errdefer {
            var index: usize = argc;
            while (index > 0) {
                index -= 1;
                freeSourceSlot(rt, &region_start[@as(usize, @intFromBool(method_receiver)) + 1 + index]);
            }
            freeSourceSlot(rt, &region_start[@intFromBool(method_receiver)]);
            if (method_receiver) freeSourceSlot(rt, &region_start[0]);
        }
        try vm_call.enterInlineCallDepth(ctx, global);
        errdefer ctx.call_depth -= 1;
        const entry = try self.acquireSlot(global);
        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);
        const stack_count = @as(usize, function.stack_size) + 1;
        var storage_on_heap = false;
        const stack_window = rt.vm_stack.carve(&rt.memory, stack_count) orelse blk: {
            const heap = try rt.memory.alloc(core.JSValue, stack_count);
            storage_on_heap = true;
            break :blk heap;
        };
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, stack_window);

        return self.finishExactArgsLeafFrame(leaf_this, entry, global, function, captures, region_start, argc, stack_window, storage_on_heap, self.callerResumePc());
    }

    /// Capture-leaf authoritative constructor (O2) — the deep fallible twin
    /// of `pushEmptyLeafFrame` for the zero-arg leaf whose only frame window
    /// is the inherited capture array (`() => this.x`, zero-arg closures
    /// over upvalues). Region layout is the zero-arg `[callable]` /
    /// `[receiver, callable]` — no args window, so the sole-owner errdefer
    /// is the zero-arg form. Kept as a SEPARATE body (not a comptime variant
    /// of either established constructor) for the same reason the exact-args
    /// twin is: sharing one parameterized body measurably re-scheduled the
    /// established zero-arg warm arms.
    noinline fn pushCaptureLeafFrame(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
    ) HostError!*Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const ctx = self.ctx;
        const rt = ctx.runtime;
        assertCaptureLeafEligible(leaf_this, function);
        std.debug.assert(function.arg_count == 0 and function.var_count == 0);
        std.debug.assert(function.open_var_ref_count == 0);
        std.debug.assert(captures.len != 0);

        // Same sole-owner contract as the zero-arg constructor: the caller
        // already retreated its logical operand top, so these slots must be
        // released when depth/Entry acquisition fails.
        errdefer {
            freeSourceSlot(rt, &region_start[@intFromBool(method_receiver)]);
            if (method_receiver) freeSourceSlot(rt, &region_start[0]);
        }
        try vm_call.enterInlineCallDepth(ctx, global);
        errdefer ctx.call_depth -= 1;
        const entry = try self.acquireSlot(global);
        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);
        const stack_count = @as(usize, function.stack_size) + 1;
        var storage_on_heap = false;
        const stack_window = rt.vm_stack.carve(&rt.memory, stack_count) orelse blk: {
            const heap = try rt.memory.alloc(core.JSValue, stack_count);
            storage_on_heap = true;
            break :blk heap;
        };
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, stack_window);

        return self.finishCaptureLeafFrame(leaf_this, entry, global, function, captures, region_start, stack_window, storage_on_heap, self.callerResumePc());
    }

    /// Padded-args authoritative constructor (Q3) — the deep fallible twin
    /// of `pushExactArgsLeafFrame` for the `argc < arg_count` call shape.
    /// The dispatch arm's capacity gate covers this path too (a warm miss
    /// re-enters with the same already-proved region), and the pad fill
    /// happens only inside the infallible publication tail
    /// (`finishPaddedArgsLeafFrame`), so the sole-owner errdefer below
    /// releases exactly the supplied `argc` values plus callable/receiver —
    /// a pad slot is never written on a failure path. Kept as a SEPARATE
    /// body (see `pushExactArgsLeafFrame` for the tail-merge re-scheduling
    /// hazard).
    noinline fn pushPaddedArgsLeafFrame(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
    ) HostError!*Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const ctx = self.ctx;
        const rt = ctx.runtime;
        assertPaddedArgsLeafEligible(leaf_this, function);
        std.debug.assert(argc < function.arg_count);
        std.debug.assert(function.var_count == 0);
        std.debug.assert(function.open_var_ref_count == 0);

        // Same sole-owner contract as the exact-args constructor, over the
        // SUPPLIED args window only (reverse index order, mirroring
        // cleanupStackSource). The missing tail has not been written.
        errdefer {
            var index: usize = argc;
            while (index > 0) {
                index -= 1;
                freeSourceSlot(rt, &region_start[@as(usize, @intFromBool(method_receiver)) + 1 + index]);
            }
            freeSourceSlot(rt, &region_start[@intFromBool(method_receiver)]);
            if (method_receiver) freeSourceSlot(rt, &region_start[0]);
        }
        try vm_call.enterInlineCallDepth(ctx, global);
        errdefer ctx.call_depth -= 1;
        const entry = try self.acquireSlot(global);
        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);
        const stack_count = @as(usize, function.stack_size) + 1;
        var storage_on_heap = false;
        const stack_window = rt.vm_stack.carve(&rt.memory, stack_count) orelse blk: {
            const heap = try rt.memory.alloc(core.JSValue, stack_count);
            storage_on_heap = true;
            break :blk heap;
        };
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, stack_window);

        return self.finishPaddedArgsLeafFrame(leaf_this, entry, global, function, captures, region_start, argc, stack_window, storage_on_heap, self.callerResumePc());
    }

    /// Debug-only proof that the comptime `this` arm matches the published
    /// per-policy eligibility bit and the callee's `this` policy: the sloppy
    /// arm substitutes the realm global for non-arrow sloppy functions; the
    /// raw arm preserves undefined for strict functions (the same
    /// is_strict|runtime_strict disjunction the view publication folds into
    /// `strict_mode`) and for arrows in either mode. The receiver arm is
    /// policy-independent: every leaf transfers the raw receiver.
    inline fn assertLeafEligible(comptime leaf_this: LeafThis, function: *const bytecode.Bytecode) void {
        switch (comptime leaf_this) {
            .sloppy_global => std.debug.assert(function.flags.simple_inline_empty_leaf),
            .raw_undefined => std.debug.assert(function.raw_this_inline_empty_leaf),
            .receiver => std.debug.assert(function.flags.simple_inline_empty_leaf or
                function.raw_this_inline_empty_leaf),
        }
        if (comptime leaf_this != .receiver) {
            std.debug.assert((function.flags.is_strict or function.flags.runtime_strict or
                function.flags.is_arrow_function) == (leaf_this == .raw_undefined));
        }
    }

    /// Exact-args twin of `assertLeafEligible` against the O1 policy bytes.
    inline fn assertExactArgsLeafEligible(comptime leaf_this: LeafThis, function: *const bytecode.Bytecode) void {
        switch (comptime leaf_this) {
            .sloppy_global => std.debug.assert(function.simple_inline_exact_args_leaf),
            .raw_undefined => std.debug.assert(function.raw_this_inline_exact_args_leaf),
            .receiver => std.debug.assert(function.simple_inline_exact_args_leaf or
                function.raw_this_inline_exact_args_leaf),
        }
        if (comptime leaf_this != .receiver) {
            std.debug.assert((function.flags.is_strict or function.flags.runtime_strict or
                function.flags.is_arrow_function) == (leaf_this == .raw_undefined));
        }
    }

    /// Capture-leaf twin of `assertLeafEligible` against the O2 fused kind
    /// byte (the sole published eligibility carrier for this family).
    inline fn assertCaptureLeafEligible(comptime leaf_this: LeafThis, function: *const bytecode.Bytecode) void {
        switch (comptime leaf_this) {
            .sloppy_global => std.debug.assert(function.capture_leaf_kind == .sloppy),
            .raw_undefined => std.debug.assert(function.capture_leaf_kind == .raw_this),
            .receiver => std.debug.assert(function.capture_leaf_kind != .none),
        }
        if (comptime leaf_this != .receiver) {
            std.debug.assert((function.flags.is_strict or function.flags.runtime_strict or
                function.flags.is_arrow_function) == (leaf_this == .raw_undefined));
        }
    }

    /// Padded-args twin of `assertExactArgsLeafEligible` (Q3): the padded
    /// call shape reuses the O1 family's publication byte verbatim — the
    /// published conditions already prove what padding relies on
    /// (`has_simple_parameter_list` excludes default/rest parameter
    /// initializers via `simple_inline_base`, and the leaf body geometry
    /// excludes `arguments` materialization/rescue), so a missing parameter
    /// slot is exactly the spec's plain `undefined` binding.
    inline fn assertPaddedArgsLeafEligible(comptime leaf_this: LeafThis, function: *const bytecode.Bytecode) void {
        switch (comptime leaf_this) {
            .sloppy_global => std.debug.assert(function.simple_inline_exact_args_leaf),
            .raw_undefined => std.debug.assert(function.raw_this_inline_exact_args_leaf),
            .receiver => std.debug.assert(function.simple_inline_exact_args_leaf or
                function.raw_this_inline_exact_args_leaf),
        }
        if (comptime leaf_this != .receiver) {
            std.debug.assert((function.flags.is_strict or function.flags.runtime_strict or
                function.flags.is_arrow_function) == (leaf_this == .raw_undefined));
        }
    }

    /// Infallible publication tail shared by the cold authoritative
    /// constructor and the warm active-chunk constructor below.
    /// `resume_pc` is the caller's post-operand resume pointer
    /// (`caller_code_base + caller_frame.pc`), captured here together with the
    /// caller's operand top (`region_start`, asserted == topPtr by both
    /// constructors) as the empty-leaf resume record: the return arm restores
    /// both with one ldp instead of chasing prev→function→code.ptr→frame.pc.
    /// The receiver instantiation moves the receiver into the frame's raw
    /// `this` exactly like `setupSimpleInlineEntryImpl`'s method arm
    /// (take + `.owned`; sloppy coercion stays deferred to the this-reading
    /// opcodes); the sloppy plain instantiation keeps the borrowed sloppy
    /// global and the raw plain instantiation preserves undefined —
    /// mirroring `setupSimpleInlineEntryImpl`'s strict_this arm and the
    /// generic constructor's arrow this-preservation.
    inline fn finishEmptyLeafFrame(
        self: *Machine,
        comptime leaf_this: LeafThis,
        entry: *Entry,
        global: *core.Object,
        function: *const bytecode.Bytecode,
        region_start: [*]core.JSValue,
        stack_window: []core.JSValue,
        storage_on_heap: bool,
        resume_pc: [*]const u8,
    ) *Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const rt = self.ctx.runtime;
        const callable_slot = &region_start[@intFromBool(method_receiver)];
        // No failable operation follows the ownership transfer.
        entry.frame = .{
            .function = function,
            .this_value = switch (comptime leaf_this) {
                .receiver => takeSourceSlot(&region_start[0]),
                .raw_undefined => core.JSValue.undefinedValue(),
                .sloppy_global => global.value(),
            },
            .current_function = takeSourceSlot(callable_slot),
            .storage_values = if (storage_on_heap) stack_window else &.{},
            .ownership = .{
                .this_value = if (method_receiver) .owned else .borrowed,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.vm_stack_arena_policy, stack_window);
        entry.teardown = .{
            .simple = true,
            .empty_leaf = !storage_on_heap,
        };
        // Dead bytes for the heap-fallback (non-leaf) shape; the generic
        // return path never reads the record.
        entry.setEmptyLeafResume(resume_pc, region_start);
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        return entry;
    }

    /// Exact-args publication tail (O1) — the parallel twin of
    /// `finishEmptyLeafFrame` (separate body; see `pushExactArgsLeafFrame`
    /// for why the zero-arg source is not shared). Adds exactly the args
    /// window binding: the frame borrows the caller-region slots in place —
    /// qjs `arg_buf = argv` (quickjs.c:17841). Value ownership transfers to
    /// the frame (the caller's logical top already retreated below the
    /// window); the backing slots stay caller storage, the same
    /// `initArgumentsBorrowedSlots` contract the exact simple frame uses.
    /// The teardown publishes the `exact_args_leaf` bit instead of
    /// `empty_leaf`, so the zero-arg return arm keeps its single-bit test
    /// and abrupt completion routes to general teardown (which releases the
    /// args values exactly once and never frees their borrowed backing).
    inline fn finishExactArgsLeafFrame(
        self: *Machine,
        comptime leaf_this: LeafThis,
        entry: *Entry,
        global: *core.Object,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
        stack_window: []core.JSValue,
        storage_on_heap: bool,
        resume_pc: [*]const u8,
    ) *Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const rt = self.ctx.runtime;
        const callable_slot = &region_start[@intFromBool(method_receiver)];
        const args_window: []core.JSValue =
            (region_start + @as(usize, @intFromBool(method_receiver)) + 1)[0..argc];
        // No failable operation follows the ownership transfer. `var_refs`
        // borrows the closure's cell array (qjs `var_refs =
        // p->u.func.var_refs`, quickjs.c:17844), rooted by the owned
        // `current_function` until teardown. Unconditionally `.borrowed`
        // (the general path publishes `.owned` for the empty slice, but both
        // dispositions are teardown no-ops at len 0 and the constant byte
        // keeps a len test off this path).
        entry.frame = .{
            .function = function,
            .this_value = switch (comptime leaf_this) {
                .receiver => takeSourceSlot(&region_start[0]),
                .raw_undefined => core.JSValue.undefinedValue(),
                .sloppy_global => global.value(),
            },
            .current_function = takeSourceSlot(callable_slot),
            .actual_arg_count = argc,
            .args = args_window,
            .var_refs = captures,
            .storage_values = if (storage_on_heap) stack_window else &.{},
            .ownership = .{
                .this_value = if (method_receiver) .owned else .borrowed,
                .var_refs = .borrowed,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.vm_stack_arena_policy, stack_window);
        entry.teardown = .{
            .simple = true,
            .exact_args_leaf = !storage_on_heap,
        };
        // Dead bytes for the heap-fallback (non-leaf) shape; the generic
        // return path never reads the record.
        entry.setEmptyLeafResume(resume_pc, region_start);
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        return entry;
    }

    /// Capture-leaf publication tail (O2) — the parallel twin of
    /// `finishEmptyLeafFrame` plus exactly the capture binding: `var_refs`
    /// borrows the closure's cell array (qjs `var_refs = p->u.func.var_refs`,
    /// quickjs.c:17844), rooted by the owned `current_function` until
    /// teardown, `.borrowed` so no teardown path ever releases or closes the
    /// cells (they belong to the still-live closure). No args window binds:
    /// `args` keeps the empty default, so the published `exact_args_leaf`
    /// teardown's release loop zero-trips and its
    /// `args.len == function.arg_count` invariant holds at 0 == 0. The
    /// teardown bit buys this family the GUARDED return arm — inherited-
    /// capture bodies read free names, so leftover-carrying returns
    /// (parser-elided trailing drops, switch discriminants) must route
    /// through general teardown — while the zero-arg empty-leaf return arm
    /// keeps its established unguarded single-bit form. Separate body from
    /// both established tails (see `pushExactArgsLeafFrame`).
    inline fn finishCaptureLeafFrame(
        self: *Machine,
        comptime leaf_this: LeafThis,
        entry: *Entry,
        global: *core.Object,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        stack_window: []core.JSValue,
        storage_on_heap: bool,
        resume_pc: [*]const u8,
    ) *Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const rt = self.ctx.runtime;
        const callable_slot = &region_start[@intFromBool(method_receiver)];
        // No failable operation follows the ownership transfer.
        entry.frame = .{
            .function = function,
            .this_value = switch (comptime leaf_this) {
                .receiver => takeSourceSlot(&region_start[0]),
                .raw_undefined => core.JSValue.undefinedValue(),
                .sloppy_global => global.value(),
            },
            .current_function = takeSourceSlot(callable_slot),
            .var_refs = captures,
            .storage_values = if (storage_on_heap) stack_window else &.{},
            .ownership = .{
                .this_value = if (method_receiver) .owned else .borrowed,
                .var_refs = .borrowed,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.vm_stack_arena_policy, stack_window);
        entry.teardown = .{
            .simple = true,
            .exact_args_leaf = !storage_on_heap,
        };
        // Dead bytes for the heap-fallback (non-leaf) shape; the generic
        // return path never reads the record.
        entry.setEmptyLeafResume(resume_pc, region_start);
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        return entry;
    }

    /// Padded-args publication tail (Q3) — the parallel twin of
    /// `finishExactArgsLeafFrame` for the `argc < arg_count` call shape of a
    /// published exact-args leaf callee (separate body; see
    /// `pushExactArgsLeafFrame` for the tail-merge re-scheduling hazard).
    /// The ONLY divergence from the exact tail: the args window spans the
    /// full `arg_count` parameter slots of the caller region and the missing
    /// tail `[argc..arg_count)` is filled with undefined HERE, after the
    /// last failable point — the leaf form of qjs's `arg_buf` missing-tail
    /// fill (`for(i = argc; i < arg_count; i++) arg_buf[i] = JS_UNDEFINED`,
    /// quickjs.c:17856-17857) without the argv copy: the supplied prefix
    /// already lives where the borrowed window wants it, and the dispatch
    /// arm's capacity gate (`paddedLeafRegionHasCapacity`) proved the pad
    /// slots stay inside the caller's fixed operand backing. Constructor
    /// failure paths therefore release exactly the supplied `argc` values
    /// (their errdefers never see a pad), while every teardown that runs
    /// after publication releases the whole window exactly once (undefined
    /// frees are tag-test no-ops). The teardown publishes the SAME
    /// `exact_args_leaf` bit: after construction the frame is
    /// indistinguishable from an exact-args leaf (`args.len == arg_count`),
    /// so the O1 return arm and both teardown epilogues apply unchanged.
    /// `actual_arg_count = argc` stays truthful for the
    /// excluded-by-publication consumers (arguments/rest/super never
    /// materialize in a leaf body).
    inline fn finishPaddedArgsLeafFrame(
        self: *Machine,
        comptime leaf_this: LeafThis,
        entry: *Entry,
        global: *core.Object,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
        stack_window: []core.JSValue,
        storage_on_heap: bool,
        resume_pc: [*]const u8,
    ) *Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const rt = self.ctx.runtime;
        const callable_slot = &region_start[@intFromBool(method_receiver)];
        const args_base = region_start + @as(usize, @intFromBool(method_receiver)) + 1;
        const args_window: []core.JSValue = args_base[0..function.arg_count];
        // Missing-tail fill, in place. No failable operation follows (or
        // precedes, within this tail), so an abandoned construction can
        // never leave a written pad behind for a source-cleanup errdefer to
        // double-free.
        @memset(args_base[argc..function.arg_count], core.JSValue.undefinedValue());
        // Ownership transfers mirror `finishExactArgsLeafFrame` exactly:
        // `var_refs` borrows the closure's cell array (qjs `var_refs =
        // p->u.func.var_refs`, quickjs.c:17844), rooted by the owned
        // `current_function` until teardown.
        entry.frame = .{
            .function = function,
            .this_value = switch (comptime leaf_this) {
                .receiver => takeSourceSlot(&region_start[0]),
                .raw_undefined => core.JSValue.undefinedValue(),
                .sloppy_global => global.value(),
            },
            .current_function = takeSourceSlot(callable_slot),
            .actual_arg_count = argc,
            .args = args_window,
            .var_refs = captures,
            .storage_values = if (storage_on_heap) stack_window else &.{},
            .ownership = .{
                .this_value = if (method_receiver) .owned else .borrowed,
                .var_refs = .borrowed,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.vm_stack_arena_policy, stack_window);
        entry.teardown = .{
            .simple = true,
            .exact_args_leaf = !storage_on_heap,
        };
        // Dead bytes for the heap-fallback (non-leaf) shape; the generic
        // return path never reads the record.
        entry.setEmptyLeafResume(resume_pc, region_start);
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        return entry;
    }

    /// The caller's post-operand resume pointer, exactly what
    /// `reloadAfterPop` re-derives on return. Every empty-leaf constructor
    /// runs after the call opcode published the caller's resume offset
    /// (handlers sync frame.pc before target resolution; driver-side pushes
    /// run after the cold call helpers advanced it past the operand).
    inline fn callerResumePc(self: *const Machine) [*]const u8 {
        const caller_frame: *const frame_mod.Frame = if (self.top) |caller| &caller.frame else self.l0.level.frame;
        return caller_frame.function.code.ptr + caller_frame.pc;
    }

    /// Warm, allocation-free empty-leaf construction. A null result is a pure
    /// miss: call depth, arena watermark, source ownership, and Machine links
    /// are unchanged, so the caller can invoke pushEmptyLeafCall to handle
    /// first-use Entry allocation, chunk switching, heap fallback, OOM, or a
    /// logical stack-overflow exception. `resume_pc` is the caller's
    /// register-resident post-operand pc (== what `callerResumePc` derives);
    /// the warm adapter passes it through so the resume record is stored
    /// without reloading frame state.
    pub inline fn tryPushEmptyLeafCallFast(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.Bytecode,
        region_start: [*]core.JSValue,
        resume_pc: [*]const u8,
    ) ?*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertLeafEligible(leaf_this, function);
        const ctx = self.ctx;
        if (ctx.call_depth >= ctx.stack_limit) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) return null;
        const entry = self.entryAt(index);

        const rt = ctx.runtime;
        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(stack_count) orelse return null;

        ctx.call_depth += 1;
        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        return self.finishEmptyLeafFrame(leaf_this, entry, global, function, region_start, carve.window, false, resume_pc);
    }

    /// Warm, allocation-free exact-args leaf construction (O1) — the
    /// parallel twin of `tryPushEmptyLeafCallFast` (separate body; see
    /// `pushExactArgsLeafFrame` for why the zero-arg source is not shared).
    /// A null result is the same pure miss contract: call depth, arena
    /// watermark, source ownership (callable, optional receiver, and the
    /// args window), and Machine links are unchanged, so the caller can
    /// invoke `pushExactArgsLeafCall` for first-use Entry allocation, chunk
    /// switching, heap fallback, OOM, or stack-overflow handling.
    pub inline fn tryPushExactArgsLeafCallFast(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
        resume_pc: [*]const u8,
    ) ?*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertExactArgsLeafEligible(leaf_this, function);
        std.debug.assert(@as(usize, function.arg_count) == argc and argc > 0);
        const ctx = self.ctx;
        if (ctx.call_depth >= ctx.stack_limit) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) return null;
        const entry = self.entryAt(index);

        const rt = ctx.runtime;
        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(stack_count) orelse return null;

        ctx.call_depth += 1;
        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        return self.finishExactArgsLeafFrame(leaf_this, entry, global, function, captures, region_start, argc, carve.window, false, resume_pc);
    }

    /// Warm, allocation-free capture-leaf construction (O2) — the parallel
    /// twin of `tryPushEmptyLeafCallFast` plus the borrowed capture binding.
    /// A null result is the same pure miss contract: call depth, arena
    /// watermark, source ownership (callable and optional receiver), and
    /// Machine links are unchanged, so the caller can invoke
    /// `pushCaptureLeafCall` for first-use Entry allocation, chunk
    /// switching, heap fallback, OOM, or stack-overflow handling. Separate
    /// body from both established warm constructors (see
    /// `pushExactArgsLeafFrame`).
    pub inline fn tryPushCaptureLeafCallFast(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        resume_pc: [*]const u8,
    ) ?*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertCaptureLeafEligible(leaf_this, function);
        std.debug.assert(captures.len != 0);
        const ctx = self.ctx;
        if (ctx.call_depth >= ctx.stack_limit) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) return null;
        const entry = self.entryAt(index);

        const rt = ctx.runtime;
        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(stack_count) orelse return null;

        ctx.call_depth += 1;
        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        return self.finishCaptureLeafFrame(leaf_this, entry, global, function, captures, region_start, carve.window, false, resume_pc);
    }

    /// Warm, allocation-free padded-args leaf construction (Q3) — the
    /// `argc < arg_count` sibling of `tryPushExactArgsLeafCallFast`. The
    /// dispatch arm has already proved the caller's operand backing keeps
    /// `arg_count` slots addressable at the region's args base
    /// (`paddedLeafRegionHasCapacity` — asserted below), so the publication
    /// tail fills the missing slots with undefined IN PLACE and the frame
    /// binds the same borrowed caller-region args window as the exact
    /// family. Same pure-miss contract: a null result leaves call depth,
    /// arena watermark, source ownership, the untouched pad slots, and
    /// Machine links unchanged, so the caller can invoke
    /// `pushPaddedArgsLeafCall` for first-use Entry allocation, chunk
    /// switching, heap fallback, OOM, or stack-overflow handling. Kept as a
    /// SEPARATE body (see `pushExactArgsLeafFrame` for the tail-merge
    /// re-scheduling hazard).
    pub inline fn tryPushPaddedArgsLeafCallFast(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
        resume_pc: [*]const u8,
    ) ?*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertPaddedArgsLeafEligible(leaf_this, function);
        std.debug.assert(argc < function.arg_count);
        std.debug.assert(@intFromPtr(region_start + @as(usize, @intFromBool(leaf_this == .receiver)) + 1 + @as(usize, function.arg_count)) <=
            @intFromPtr(caller_stack.basePtr() + caller_stack.capacity));
        const ctx = self.ctx;
        if (ctx.call_depth >= ctx.stack_limit) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) return null;
        const entry = self.entryAt(index);

        const rt = ctx.runtime;
        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(stack_count) orelse return null;

        ctx.call_depth += 1;
        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        return self.finishPaddedArgsLeafFrame(leaf_this, entry, global, function, captures, region_start, argc, carve.window, false, resume_pc);
    }

    /// Optimized inline-call frame setup, factored out of `pushFrame` so the
    /// Machine shares the zero-copy arg move (`initArgumentsMoved`), this-boxing
    /// and arena carve — NOT the dup-heavy
    /// `callFunctionBytecodeModeState` path.
    /// The caller owns depth accounting (enterInlineCallDepth / enterCallDepth)
    /// and any push/pop bookkeeping; on error every partially-initialized
    /// resource is released via the errdefers below.
    pub noinline fn setupInlineEntry(ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        const rt = ctx.runtime;
        // Point at the pointer-stable per-FB cached view (no copy). Target
        // resolution declines this same-Machine path if the once-per-FB cache
        // allocation fails, so general frame setup has no nullable-view arm.
        const function = target.view;
        entry.catch_target = null;
        entry.teardown = .{};
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        const callable_slot = sourceCallableSlot(source);
        const frame_var_refs: []const *core.VarRef = target.captureSlice();

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);

        entry.frame = frame_mod.Frame.init(function);
        errdefer entry.frame.deinit(&rt.memory, rt);
        // No per-call backtrace node: the invocation's Machine-owned node
        // walks this Entry directly through the execution chain.

        // Keep qjs's raw `this_obj` for method receivers, including sloppy
        // primitives. The established plain-undefined specialization remains
        // allocation-free (strict undefined / sloppy global); observed method
        // bindings materialize later through OP_push_this/arrow/eval.
        const fb_strict = target.fb.flags.is_strict_mode or target.fb.flags.runtime_strict_mode;
        const receiver_slot = sourceReceiverSlot(source);
        // Arrow bytecode reads lexical this through its ordinary closure cell.
        // Preserve the empty frame binding used before that capture conversion;
        // method/Function.call receiver slots are still transferred below so
        // the ignored value has one clear owner until teardown.
        const plain_undefined_this = !target.fb.flags.is_arrow_function and receiver_slot == null and target.this_value.isUndefined();
        const effective_this = if (plain_undefined_this)
            if (fb_strict) core.JSValue.undefinedValue() else global.value()
        else
            target.this_value;

        var take_receiver_as_this = false;
        if (receiver_slot) |slot| {
            if (effective_this.same(slot.*)) {
                take_receiver_as_this = true;
            }
        }

        var cleanup_source: SourceCleanupMode = if (sourceHasStackRegion(source)) .full else .none;
        errdefer cleanupSource(rt, source, cleanup_source);

        // Bind the frame values INLINE — qjs's JS_CallInternal sets cur_func /
        // this / new_target directly rather than threading a 14-field
        // CallBindingInputs descriptor through initCallBindingValues. This is
        // the common-path equivalent; ownership flags must mirror the old
        // bindCallValue/modeOwnsValue result EXACTLY (Frame.deinit frees by
        // these flags, and the frame.deinit errdefer above covers a later
        // failure):
        //   current_function .take -> owns the callable's transferred ref
        //   new_target .borrow -> not owned
        //   constructor_this keeps Frame.init's undefined/unowned default
        //   this .borrow, unless taken raw from the receiver slot (method call)
        //   -> then .take/owned. Lazy materialization updates this slot once.
        // `takeSourceSlot` nulls the source slot so the popped stack region
        // never double-frees the value (the leak guard the method-call comment
        // below describes).
        entry.frame.current_function = takeSourceSlot(callable_slot);
        std.debug.assert(target.new_target.isUndefined());
        if (take_receiver_as_this) {
            entry.frame.this_value = takeSourceSlot(receiver_slot.?);
            entry.frame.ownership.this_value = .owned;
        } else {
            entry.frame.this_value = effective_this;
            entry.frame.ownership.this_value = .borrowed;
        }

        const argc = sourceArgCount(source);
        const frame_arg_count = frame_mod.frameArgCount(function, argc);
        const need_original_snapshot = frame_mod.argumentsNeedsOriginalSnapshot(function);
        const borrow_source_args = canBorrowSourceArgs(function, source);
        const storage_arg_count: usize = if (borrow_source_args) 0 else frame_arg_count;
        // qjs `var_refs = p->u.func.var_refs` (quickjs.c:17844): borrow the callee's
        // closure captures array directly instead of carving + dup-ing a per-frame
        // copy. Only when every mutation of `frame.var_refs` is provably routed
        // through a cell (never the array element) and the shared array is never
        // realloced. Global declarations are the remaining element-rebinding
        // escape; direct eval captures only alias the existing indexed cells.
        // "All captures are cells" is now the `[]*core.VarRef` type invariant
        // (phase-D flip; qjs js_closure2, quickjs.c:17297-17331), so writes
        // always go through the cell — the former allVarRefCells scan is gone.
        // Captures.len == closure_var.len ≥ every bytecode var_ref idx, so
        // `ensureVarRefsCapacity` never fires either. Teardown skips the per-element
        // free (the still-live function object owns the cells).
        const borrow_var_refs = !function.flags.is_global_var and
            frame_var_refs.len > 0;
        const var_ref_storage_count: usize = if (borrow_var_refs) 0 else frame_mod.frameVarRefStorageCount(function, frame_var_refs);
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(function);
        const slab = frame_mod.FrameSlab.carve(
            &rt.memory,
            &rt.vm_stack,
            storage_arg_count,
            frame_mod.originalArgCount(argc, need_original_snapshot),
            function.var_count,
            @as(usize, function.stack_size) + 1,
            var_ref_storage_count,
            open_var_ref_count,
        ) orelse blk: {
            const heap_windows = try frame_mod.FrameSlab.allocHeap(
                &rt.memory,
                storage_arg_count,
                frame_mod.originalArgCount(argc, need_original_snapshot),
                function.var_count,
                @as(usize, function.stack_size) + 1,
                var_ref_storage_count,
                open_var_ref_count,
            );
            entry.frame.installOwnedStorage(heap_windows.storage);
            break :blk heap_windows;
        };
        const frame_windows = frame_mod.FrameStorageWindows{
            .args = if (slab.args.len != 0) slab.args else null,
            .original_args = if (slab.original_args.len != 0) slab.original_args else null,
            .locals = if (slab.locals.len != 0) slab.locals else null,
            .var_refs = if (slab.var_refs.len != 0) slab.var_refs else null,
            .open_var_refs = if (slab.open_var_refs.len != 0) slab.open_var_refs else null,
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.vm_stack_arena_policy, slab.stack);
        errdefer entry.stack.deinit(rt);

        try vm_call.initFrameLocals(ctx, function, &entry.frame, true, frame_windows);
        if (borrow_source_args) {
            try entry.frame.initArgumentsBorrowedSlots(
                &rt.memory,
                sourceArgs(source),
                true,
                need_original_snapshot,
                frame_windows,
            );
            cleanup_source = .non_args;
        } else {
            try entry.frame.initArgumentsMoved(
                &rt.memory,
                &rt.vm_stack,
                sourceArgs(source),
                true,
                need_original_snapshot,
                frame_windows,
            );
        }
        cleanupSource(rt, source, cleanup_source);
        cleanup_source = .none;

        if (frame_windows.open_var_refs) |open_refs| {
            try entry.frame.installOpenVarRefSlots(open_refs);
        } else if (open_var_ref_count != 0) {
            try entry.frame.ensureOpenVarRefSlots(&rt.memory, &rt.vm_stack, true);
        }
        try vm_call.linkDerivedConstructorThisLocal(ctx, function, &entry.frame);
        if (borrow_var_refs) {
            // Alias the closure's captures (mutable slice; no merge replaced it).
            // The function object stays alive via
            // `frame.current_function`, so the cells outlive the frame.
            entry.frame.var_refs = target.captureSlice();
            entry.frame.ownership.var_refs = .borrowed;
        } else if (frame_var_refs.len != 0 or function.var_ref_names.len != 0) {
            try vm_call.initFrameVarRefs(ctx, global, function, &entry.frame, frame_var_refs, true, frame_windows);
        }
    }

    /// Eligibility for the qjs internal-IteratorNext binding contract. The
    /// ordinary method selector proves the same FB conditions; this form has no
    /// source-union switch because argc is statically zero and the receiver and
    /// callable remain rooted in the suspended caller's iterator record.
    inline fn isBorrowedIteratorSimpleInlineFrame(target: *const InlineTarget, iterator_record: []const core.JSValue) bool {
        if (iterator_record.len != 2) return false;
        if (!target.this_value.same(iterator_record[0])) return false;
        if (!target.callable.same(iterator_record[1])) return false;
        const function = target.view;
        return function.simple_inline_eligible or
            function.strict_simple_inline_eligible or
            function.strict_simple_snapshot_inline_eligible;
    }

    /// Zero-argument method prologue for an iterator record borrowed from the
    /// suspended caller. qjs's JS_CallInternal assigns `sf->cur_func = func_obj`
    /// and reads `this_obj` without retaining either value; the caller operand
    /// stack remains their owner. Keep this body separate from the established
    /// plain/method setup instances so a narrow iterator optimization cannot
    /// perturb their selector or register allocation.
    noinline fn setupBorrowedIteratorEntry(ctx: *core.JSContext, entry: *Entry, target: *const InlineTarget) HostError!void {
        const rt = ctx.runtime;
        const function = target.view;
        entry.catch_target = null;
        entry.teardown = .{ .simple = true };
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        const frame_arg_count: usize = @intCast(function.arg_count);
        const var_count: usize = function.var_count;
        const stack_count = @as(usize, function.stack_size) + 1;
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(function);
        const open_slots = if (open_var_ref_count == 0)
            0
        else
            (open_var_ref_count * @sizeOf(?*core.VarRef) + (@sizeOf(core.JSValue) - 1)) / @sizeOf(core.JSValue);
        const total = frame_arg_count + var_count + stack_count + open_slots;

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);

        var storage_on_heap = false;
        const slab_values = rt.vm_stack.carve(&rt.memory, total) orelse blk: {
            const heap = try rt.memory.alloc(core.JSValue, total);
            storage_on_heap = true;
            break :blk heap;
        };
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, slab_values);

        const args = slab_values[0..frame_arg_count];
        const locals_start = frame_arg_count;
        const stack_start = locals_start + var_count;
        const open_start = stack_start + stack_count;
        const locals = slab_values[locals_start..][0..var_count];
        const stack_window = slab_values[stack_start..][0..stack_count];
        const open_var_refs: []?*core.VarRef = if (open_slots == 0)
            &.{}
        else
            std.mem.bytesAsSlice(?*core.VarRef, std.mem.sliceAsBytes(slab_values[open_start..][0..open_slots]))[0..open_var_ref_count];

        @memset(args, core.JSValue.undefinedValue());
        @memset(locals, core.JSValue.undefinedValue());
        if (open_var_refs.len != 0) @memset(open_var_refs, null);

        const captures = target.captureSlice();
        // All failable work is complete. Both call bindings borrow the caller
        // iterator record; only the slab contents belong to this frame.
        entry.frame = .{
            .function = function,
            .this_value = target.this_value,
            .current_function = target.callable,
            .actual_arg_count = 0,
            .locals = locals,
            .args = args,
            .var_refs = captures,
            .open_var_refs = open_var_refs,
            .storage_values = if (storage_on_heap) slab_values else &.{},
            .ownership = .{
                .this_value = .borrowed,
                .current_function = .borrowed,
                .var_refs = if (captures.len > 0) .borrowed else .owned,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.vm_stack_arena_policy, stack_window);
    }

    fn sourceCallableSlot(source: ArgsSource) *core.JSValue {
        return &source.values[@intFromBool(source.metadata.has_receiver)];
    }

    fn sourceReceiverSlot(source: ArgsSource) ?*core.JSValue {
        return if (source.metadata.has_receiver) &source.values[0] else null;
    }

    fn takeSourceSlot(slot: *core.JSValue) core.JSValue {
        const value = slot.*;
        slot.* = core.JSValue.undefinedValue();
        return value;
    }

    fn sourceHasStackRegion(source: ArgsSource) bool {
        return !source.metadata.moved;
    }

    fn sourceArgCount(source: ArgsSource) usize {
        return source.argCount();
    }

    fn sourceArgs(source: ArgsSource) []core.JSValue {
        const args_start = 1 + @as(usize, @intFromBool(source.metadata.has_receiver));
        return source.values[args_start..][0..source.argCount()];
    }

    fn canBorrowSourceArgs(function: *const bytecode.Bytecode, source: ArgsSource) bool {
        const argc = sourceArgCount(source);
        if (@max(argc, @as(usize, @intCast(function.arg_count))) != argc) return false;
        return !source.metadata.moved;
    }

    const SourceCleanupMode = enum {
        none,
        full,
        non_args,
    };

    fn cleanupSource(rt: *core.JSRuntime, source: ArgsSource, mode: SourceCleanupMode) void {
        switch (mode) {
            .none => {},
            .full => cleanupStackSource(rt, source),
            .non_args => cleanupStackSourcePreserveArgs(rt, source),
        }
    }

    fn cleanupStackSource(rt: *core.JSRuntime, source: ArgsSource) void {
        if (source.metadata.moved) return;
        var index = source.valueCount();
        while (index > 0) {
            index -= 1;
            freeSourceSlot(rt, &source.values[index]);
        }
    }

    fn cleanupStackSourcePreserveArgs(rt: *core.JSRuntime, source: ArgsSource) void {
        if (source.metadata.moved) return;
        if (source.metadata.has_receiver) freeSourceSlot(rt, &source.values[0]);
        freeSourceSlot(rt, &source.values[@intFromBool(source.metadata.has_receiver)]);
    }

    inline fn freeSourceSlot(rt: *core.JSRuntime, slot: *core.JSValue) void {
        const value = slot.*;
        slot.* = core.JSValue.undefinedValue();
        value.free(rt);
    }

    /// Push a plain inline call whose raw source is `[callable, args...]`.
    /// Exact sloppy/strict frames enter the deep constructor; all remaining
    /// plain shapes retain the authoritative generic setup implementation.
    /// `inline_exact` (fixed-arity hot call handlers only) expands the
    /// sloppy-exact constructor body in place of its out-of-line symbol; the
    /// strict and generic arms always keep their cold calls.
    pub inline fn pushPlainCall(
        self: *Machine,
        comptime inline_exact: bool,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: *const InlineTarget,
        region_start: [*]core.JSValue,
        argc: u16,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        if (target.view.flags.simple_inline_empty_leaf and argc == 0) {
            return self.pushEmptyLeafCall(.sloppy_global, global, caller_stack, target.view, region_start);
        }
        if (target.view.raw_this_inline_empty_leaf and argc == 0) {
            return self.pushEmptyLeafCall(.raw_undefined, global, caller_stack, target.view, region_start);
        }
        const source = ArgsSource.initStack(region_start, argc, false);
        if (isSimpleInlineFrame(target, source)) {
            if (inline_exact) {
                return self.pushExactSimpleFrameImpl(false, false, false, global, target, source);
            }
            return self.pushExactSimpleFrame(false, false, false, global, target, source);
        }
        if (isStrictSimpleInlineFrame(false, target, source)) {
            return self.pushExactSimpleFrame(true, false, false, global, target, source);
        }
        return self.pushFrame(.generic_after_exact_plain, global, target, source);
    }

    /// Enter an argc=0 leaf after resolveInlineFunction published its
    /// eligibility proof. The bytecode flag carries the remaining static
    /// facts (normal function, no captures/locals/arguments/eval).
    /// `leaf_this` selects the `[callable]` / `[receiver, callable]` region
    /// layout and the frame's `this` arm; the receiver instantiation rides
    /// the receiver into the frame's raw `this`.
    pub inline fn pushEmptyLeafCall(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.Bytecode,
        region_start: [*]core.JSValue,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertLeafEligible(leaf_this, function);
        return self.pushEmptyLeafFrame(leaf_this, global, function, region_start);
    }

    /// Exact-args twin of `pushEmptyLeafCall`: authoritative fallible entry
    /// for a leaf whose call supplies exactly `arg_count > 0` arguments in
    /// the caller region. Region layout gains the trailing args window that
    /// the frame borrows in place.
    pub inline fn pushExactArgsLeafCall(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertExactArgsLeafEligible(leaf_this, function);
        return self.pushExactArgsLeafFrame(leaf_this, global, function, captures, region_start, argc);
    }

    /// Capture-leaf twin of `pushEmptyLeafCall`: authoritative fallible
    /// entry for the zero-arg leaf whose frame borrows the closure's cell
    /// array. Region layout stays the zero-arg `[callable]` /
    /// `[receiver, callable]`.
    pub inline fn pushCaptureLeafCall(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertCaptureLeafEligible(leaf_this, function);
        return self.pushCaptureLeafFrame(leaf_this, global, function, captures, region_start);
    }

    /// Padded-args twin of `pushExactArgsLeafCall` (Q3): authoritative
    /// fallible entry for a leaf call that supplies `argc < arg_count`
    /// arguments in the caller region, with the missing tail padded in
    /// place by the publication tail (capacity proved by the dispatch arm's
    /// gate — asserted here).
    pub inline fn pushPaddedArgsLeafCall(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.Bytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertPaddedArgsLeafEligible(leaf_this, function);
        std.debug.assert(@intFromPtr(region_start + @as(usize, @intFromBool(leaf_this == .receiver)) + 1 + @as(usize, function.arg_count)) <=
            @intFromPtr(caller_stack.basePtr() + caller_stack.capacity));
        return self.pushPaddedArgsLeafFrame(leaf_this, global, function, captures, region_start, argc);
    }

    /// Push a method inline call whose raw source is
    /// `[receiver, callable, args...]`. Sloppy simple methods with their
    /// complete argv — the established `recv.m(x)` hot shape — and strict
    /// functions that need an unmapped arguments snapshot both use the deep
    /// constructor; all other shapes retain the established generic selector.
    /// Each guard is deliberately limited to one precomputed eligibility byte
    /// plus the arity comparison (the receiver/`this` identity is a caller
    /// invariant: every method-layout producer binds `values[0]` as the
    /// target's `this_value`), so unmatched methods still branch directly
    /// to their established `pushFrame` instantiation.
    ///
    /// The sloppy-exact arm collapses the retired three-deep chain (bl
    /// `pushFrame` -> bl `setupFallbackInlineEntry` -> b
    /// `setupSimpleInlineEntry`) into one bl: qjs OP_call_method enters the
    /// same single JS_CallInternal prologue as OP_call (quickjs.c:18201);
    /// there is no second/third setup hop to re-save callee-saved registers
    /// or re-classify the shape `methodSimpleInlineMode` already proved. The
    /// shell stays outline (`pushExactSimpleFrame` is noinline): the win is
    /// the two deleted bl round-trips and their freight reloads, not an
    /// in-place expansion of the constructor body in the handler.
    pub inline fn pushMethodCall(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: *const InlineTarget,
        region_start: [*]core.JSValue,
        argc: u16,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        const source = ArgsSource.initStack(region_start, argc, true);
        const function = target.view;
        // Shared arity gate first: the padded (`argc < arg_count`) siblings
        // fail one comparison and branch straight to the generic selector
        // instead of walking every eligibility byte on their way out.
        if (argc >= function.arg_count) {
            if (function.simple_inline_eligible) {
                return self.pushExactSimpleFrame(false, false, true, global, target, source);
            }
            if (function.strict_simple_snapshot_inline_eligible) {
                return self.pushExactSimpleFrame(false, true, true, global, target, source);
            }
        }
        return self.pushFrame(.generic, global, target, source);
    }

    /// Dynamic adapter used by the driver-side fallback. Hot threaded handlers
    /// call the concrete plain/method adapters directly.
    pub inline fn pushCall(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: *const InlineTarget,
        region_start: [*]core.JSValue,
        argc: u16,
        layout: RegionLayout,
    ) HostError!*Entry {
        return switch (layout) {
            .plain => self.pushPlainCall(false, global, caller_stack, target, region_start, argc),
            .method => self.pushMethodCall(global, caller_stack, target, region_start, argc),
        };
    }

    /// Push a call whose owned receiver/callable/arguments already live in a
    /// temporary moved region. The frame setup consumes entries by replacing
    /// them with undefined; the caller remains responsible for freeing any
    /// entries left behind on setup failure.
    pub fn pushMovedCall(
        self: *Machine,
        global: *core.Object,
        target: *const InlineTarget,
        moved_values: []core.JSValue,
        layout: RegionLayout,
        return_action: ReturnAction,
        continuation_payload: u32,
    ) HostError!*Entry {
        const source = ArgsSource.initMoved(moved_values, layout == .method);
        const entry = if (layout == .method)
            try self.pushFrame(.moved_method, global, target, source)
        else
            try self.pushFrame(.generic, global, target, source);
        entry.return_action = return_action;
        entry.continuation_payload = switch (return_action) {
            .next => 0,
            .proxy_get => self.ctx.runtime.atoms.dup(@intCast(continuation_payload)),
            .for_of_next => continuation_payload,
        };
        return entry;
    }

    /// Try to push a simple bytecode iterator `next()` while borrowing the
    /// persistent `[iterator, next]` record from the suspended caller frame.
    /// A non-simple target returns null and retains the established dup/move
    /// path, whose general setup may outlive or mutate its source bindings.
    pub fn pushBorrowedIteratorNext(
        self: *Machine,
        global: *core.Object,
        target: *const InlineTarget,
        iterator_record: []core.JSValue,
        depth: u8,
    ) HostError!?*Entry {
        if (!isBorrowedIteratorSimpleInlineFrame(target, iterator_record)) return null;
        // The borrowed setup path ignores ArgsSource; pass the caller record as
        // a diagnostic witness without changing or taking either slot.
        const entry = try self.pushFrame(.borrowed_iterator, global, target, ArgsSource.initMoved(iterator_record, true));
        entry.return_action = .for_of_next;
        entry.continuation_payload = depth;
        return entry;
    }

    /// Infallible publication tail for the forwarded empty leaf (O3) —
    /// SEPARATE body from `finishEmptyLeafFrame` (sharing one parameterized
    /// body measurably re-scheduled established arms; see
    /// `pushExactArgsLeafFrame`). Region is `[target, call, thisArg?]` with
    /// the caller top already retreated to `region_start`: the target
    /// transfers into the frame callable exactly like the plain leaf, the
    /// skipped native `call` function transfers into the entry's owned
    /// `native_caller` (same slot `pushForwardedCall` publishes; the
    /// backtrace resolver's `has_native_caller` arm reads it unchanged), and
    /// the undefined `thisArg` slot needs no release. No resume record is
    /// stored: its default-repr storage IS `native_caller`, so the return
    /// arm re-derives the caller resume through `prev`. The sloppy `this`
    /// arm borrows the realm global — identical to the plain sloppy leaf;
    /// Function.prototype.call with an undefined thisArg reaches the same
    /// deferred-coercion state as a plain call of the same target.
    inline fn finishForwardedEmptyLeafFrame(
        self: *Machine,
        comptime leaf_this: LeafThis,
        entry: *Entry,
        global: *core.Object,
        function: *const bytecode.Bytecode,
        region_start: [*]core.JSValue,
        stack_window: []core.JSValue,
    ) *Entry {
        comptime std.debug.assert(leaf_this == .sloppy_global);
        const rt = self.ctx.runtime;
        // No failable operation follows the ownership transfers.
        entry.frame = .{
            .function = function,
            .this_value = global.value(),
            .current_function = takeSourceSlot(&region_start[0]),
            .storage_values = &.{},
            .ownership = .{
                .this_value = .borrowed,
                .storage = .borrowed,
            },
        };
        entry.native_caller = takeSourceSlot(&region_start[1]);
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.vm_stack_arena_policy, stack_window);
        entry.teardown = .{
            .simple = true,
            .has_native_caller = true,
            .forwarded_leaf = true,
        };
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        return entry;
    }

    /// Warm, allocation-free forwarded empty-leaf construction (O3) — the
    /// Function.prototype.call twin of `tryPushEmptyLeafCallFast` (separate
    /// body; see `pushExactArgsLeafFrame` for why the established zero-arg
    /// source is not shared). A null result is the same pure miss contract:
    /// call depth, arena watermark, source ownership (target, native `call`
    /// function, and the optional undefined thisArg all still owned by their
    /// region slots), and Machine links are unchanged, so the caller can
    /// restore its operand top and take the authoritative generic forwarding
    /// path (`pushForwardedCall`), which owns first-use Entry allocation,
    /// chunk switching, heap fallback, OOM, and stack-overflow recovery.
    pub inline fn tryPushForwardedEmptyLeafCallFast(
        self: *Machine,
        comptime leaf_this: LeafThis,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.Bytecode,
        region_start: [*]core.JSValue,
    ) ?*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertLeafEligible(leaf_this, function);
        const ctx = self.ctx;
        if (ctx.call_depth >= ctx.stack_limit) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) return null;
        const entry = self.entryAt(index);

        const rt = ctx.runtime;
        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(stack_count) orelse return null;

        ctx.call_depth += 1;
        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        return self.finishForwardedEmptyLeafFrame(leaf_this, entry, global, function, region_start, carve.window);
    }

    /// Push a bytecode target reached through Function.prototype.call. Takes
    /// ownership of `native_caller` only on success; the caller retains and
    /// frees it when frame setup fails.
    pub fn pushForwardedCall(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: *const InlineTarget,
        region_base: usize,
        argc: u16,
        layout: RegionLayout,
        native_caller: core.JSValue,
    ) HostError!*Entry {
        caller_stack.setLen(region_base);
        const entry = try self.pushFrame(.generic, global, target, ArgsSource.initStack(caller_stack.topPtr(), argc, layout == .method));
        entry.native_caller = native_caller;
        entry.teardown.has_native_caller = true;
        return entry;
    }

    /// Proper tail call: replace the top inline frame with a fresh frame
    /// for `target`, keeping the logical call depth constant. The operand
    /// region starting at `region_base` lives on the dying frame's own
    /// operand stack, so it is moved into a scratch buffer before the frame
    /// (and the arena window backing its stack) is torn down. The region is
    /// `[callable, args...]`, or `[receiver, callable, args...]` when
    /// `has_receiver` (a tail-positioned method call, where the receiver
    /// becomes the reused frame's `this`). On error the dying frame is
    /// already gone; the error propagates as if thrown by the callee before
    /// executing any code.
    pub fn tailCallReuse(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: *const InlineTarget,
        region_base: usize,
        argc: u16,
        layout: RegionLayout,
    ) HostError!*Entry {
        std.debug.assert(self.depth > 0);
        const has_receiver = layout == .method;
        const rt = self.ctx.runtime;

        const total = @as(usize, argc) + 1 + @as(usize, @intFromBool(has_receiver));
        var inline_buf: [10]core.JSValue = undefined;
        const moved: []core.JSValue = if (total <= inline_buf.len)
            inline_buf[0..total]
        else
            try rt.memory.alloc(core.JSValue, total);
        defer if (total > inline_buf.len) rt.memory.free(core.JSValue, moved);
        @memcpy(moved, caller_stack.values[region_base..][0..total]);
        caller_stack.setLen(region_base);
        // `moved` now owns the call region (the receiver and callable plus any
        // args not yet transferred into the new frame).
        defer for (moved) |value| value.free(rt);

        var continuation = self.popFrame();
        defer continuation.deinit(rt);
        const entry = try self.pushFrame(.generic, global, target, ArgsSource.initMoved(moved, has_receiver));
        entry.adoptContinuation(&continuation);
        return entry;
    }

    /// Retire the top inline frame through the single qjs-style `done:`
    /// epilogue. The returned continuation owns its atom until it is consumed,
    /// transferred to a tail-call replacement, or explicitly deinitialized.
    inline fn popFrameMode(self: *Machine, comptime returned: bool) ReturnContinuation {
        const dying = self.topEntry();
        const continuation = dying.takeContinuation();
        if (returned)
            dying.deinitReturned(self.ctx)
        else
            dying.deinit(self.ctx);
        self.ctx.call_depth -= 1;
        self.depth -= 1;
        // Unlink — qjs `rt->current_stack_frame = sf->prev_frame;` at the
        // done: epilogue (quickjs.c:20709).
        self.top = dying.prev;
        return continuation;
    }

    /// Retire an abruptly-completed or tail-replaced frame.
    pub inline fn popFrame(self: *Machine) ReturnContinuation {
        return self.popFrameMode(false);
    }

    /// Retire a frame after its return value has been moved out of the callee
    /// operand window.
    pub inline fn popReturnedFrame(self: *Machine) ReturnContinuation {
        return self.popFrameMode(true);
    }

    /// Retire the proven ordinary empty-leaf return without materializing its
    /// statically fixed `.next/0` continuation. This is intentionally separate
    /// from popFrame: abrupt completion must still inspect and release the
    /// callee's live operand window through general teardown.
    pub inline fn popReturnedEmptyLeaf(self: *Machine) void {
        const dying = self.topEntry();
        std.debug.assert(dying.isEmptyLeaf());
        std.debug.assert(dying.return_action == .next);
        std.debug.assert(dying.continuation_payload == 0);
        // Inline epilogue: the hot leg is an rc decrement plus the arena
        // watermark restore; keeping it in the return handler removes the
        // only bl/ret on the empty-leaf return path (destroyZeroRef stays
        // outline behind the rc==0 branch).
        dying.deinitEmptyLeafInline(self.ctx);
        self.ctx.call_depth -= 1;
        self.depth -= 1;
        self.top = dying.prev;
    }

    /// Exact-args twin of `popReturnedEmptyLeaf`. Its inline epilogue adds
    /// only the caller-region args release loop; abrupt completion still
    /// inspects and releases the callee through general teardown.
    pub inline fn popReturnedExactArgsLeaf(self: *Machine) void {
        const dying = self.topEntry();
        std.debug.assert(dying.isExactArgsLeaf());
        std.debug.assert(dying.return_action == .next);
        std.debug.assert(dying.continuation_payload == 0);
        dying.deinitExactArgsLeafInline(self.ctx);
        self.ctx.call_depth -= 1;
        self.depth -= 1;
        self.top = dying.prev;
    }

    /// Forwarded-leaf twin of `popReturnedEmptyLeaf` (O3). Its inline
    /// epilogue adds only the owned native `call` frame release; abrupt
    /// completion still inspects and releases the callee through general
    /// teardown (whose cold `releaseNativeCaller` arm handles the same
    /// ownership).
    pub inline fn popReturnedForwardedLeaf(self: *Machine) void {
        const dying = self.topEntry();
        std.debug.assert(dying.isForwardedLeaf());
        std.debug.assert(dying.return_action == .next);
        std.debug.assert(dying.continuation_payload == 0);
        dying.deinitForwardedLeafInline(self.ctx);
        self.ctx.call_depth -= 1;
        self.depth -= 1;
        self.top = dying.prev;
    }

    /// Pop the top inline frame after a completed return. Ordinary calls push
    /// `result` onto the caller stack; continuations retain it in the driver's
    /// return slot until their post-call action runs. Takes ownership of
    /// `result` either way and returns the selected action.
    pub fn popReturn(self: *Machine, result: core.JSValue) ReturnContinuation {
        const continuation = self.popReturnedFrame();
        if (continuation.action == .next) {
            std.debug.assert(continuation.payload == 0);
            self.currentLevel().stack.pushOwnedAssumeCapacity(result);
        }
        return continuation;
    }

    /// Unwind inline frames looking for a catch handler for `err`. The top
    /// (faulting) frame has already had its in-frame catch attempt fail.
    /// Returns true when some lower frame caught the error; the machine's
    /// current level is then the handling frame. Returns false when the
    /// error must propagate out of the dispatch loop (all inline frames are
    /// then already torn down).
    pub fn unwindForError(self: *Machine, global: *core.Object, err: anyerror) HostError!bool {
        const ctx = self.ctx;
        while (self.depth > 0) {
            {
                const failing = self.topEntry();
                call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(ctx, self.output, global, &failing.stack, &failing.frame);
            }
            var continuation = self.popFrame();
            const iterator_next_abrupt = continuation.action == .for_of_next;
            continuation.deinit(ctx.runtime);

            const level = self.currentLevel();
            // A throw from IteratorNext propagates directly; IteratorClose is
            // required for abrupt loop-body completion, not for a failing
            // `next()` call itself. The continuation survives proper-tail-call
            // replacement, so this remains exact even when next tail-calls.
            if (!iterator_next_abrupt) {
                try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, self.output, global, level.stack);
            }
            if (try call_runtime.tryCatchInFrame(ctx, level.stack, level.frame, level.catch_target, global, err)) return true;
            if (self.depth == 0) return false;
        }
        return false;
    }
};
