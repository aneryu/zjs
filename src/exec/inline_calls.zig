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
const builtin = @import("builtin");

const bytecode = @import("../bytecode.zig");
const op = bytecode.opcode.op;
const core = @import("../core/root.zig");
const exception_ops = @import("vm_exception_ops.zig");
const frame_mod = @import("frame.zig");
const object_ops = @import("object_ops.zig");
const call_runtime = @import("call_runtime.zig");
const forof_ops = @import("forof_ops.zig");
const stack_mod = @import("stack.zig");
const vm_call = @import("vm_call.zig");

const HostError = @import("exceptions.zig").HostError;

pub const MachineTestMetrics = struct {
    machine_inits: usize = 0,
    entry_chunk_allocations: usize = 0,
    same_machine_sync_calls: usize = 0,
    max_depth: usize = 0,
};

const TestMetricStorage = if (builtin.is_test) struct {
    var metrics: MachineTestMetrics = .{};
} else struct {};

pub fn resetMachineTestMetrics() void {
    if (!builtin.is_test) @compileError("test-only helper");
    TestMetricStorage.metrics = .{};
}

pub fn machineTestMetrics() MachineTestMetrics {
    if (!builtin.is_test) @compileError("test-only helper");
    return TestMetricStorage.metrics;
}

pub inline fn recordSameMachineSyncCall() void {
    if (comptime builtin.is_test) TestMetricStorage.metrics.same_machine_sync_calls += 1;
}

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
/// shape (plain vs method region) and the function's strict-mode flags,
/// mirroring qjs JS_CallInternal where `this_obj` is the caller-supplied
/// raw word and only OP_push_this consults the callee's strict flag
/// (quickjs.c:17924-17944).
pub const LeafThis = enum {
    /// Sloppy plain call: borrow the realm global as the frame's `this`.
    sloppy_global,
    /// Raw-`this` strict plain call: preserve undefined `this` (no
    /// substitution). Arrow bytecode never consults the frame slot —
    /// lexical `this`/`new.target` are ordinary closure cells — so arrows
    /// use either plain arm according to their enclosing strictness.
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
    /// Immutable call-policy snapshot loaded with the FunctionBytecode while
    /// resolving the callable.  The two 16-bit halves are adjacent in the
    /// W1c4 extension, so resolution pays one locator and one 32-bit load;
    /// frame selectors must not walk the optional tail again.
    call_facts: bytecode.CallFacts,
    /// Raw receiver before [[Call]] `this` boxing: `undefined` for plain calls,
    /// the property base for method calls, or Function.call's explicit thisArg.
    /// Arrow bytecode ignores this frame binding and reads its ordinary lexical
    /// capture instead. Borrowed from the rooted operand region.
    this_value: core.JSValue,
    pub inline fn captureSlice(self: InlineTarget) []*core.VarRef {
        return self.var_refs[0..self.fb.closureVarCount()];
    }
};

/// The receiver-independent result of proving that a callable is eligible for
/// same-Machine bytecode execution. Plain-call handlers may inspect the final
/// FunctionBytecode before binding the wider InlineTarget: the published empty
/// leaf shape needs only that record, while every other shape materializes the
/// receiver/callable/capture record on demand.
pub const ResolvedInlineFunction = struct {
    var_refs: [*]*core.VarRef,
    fb: *const bytecode.FunctionBytecode,
    call_facts: bytecode.CallFacts,

    pub inline fn bind(self: ResolvedInlineFunction, receiver: core.JSValue, func: core.JSValue) InlineTarget {
        return .{
            .var_refs = self.var_refs,
            .callable = func,
            .fb = self.fb,
            .call_facts = self.call_facts,
            .this_value = receiver,
        };
    }
};

/// Prove the receiver-independent portion of inline-call eligibility. Keeping
/// this prefix separate lets OP_call0 enter a published empty leaf without
/// first constructing fields that its dedicated frame constructor cannot use.
pub inline fn resolveInlineFunction(global: *core.Object, func: core.JSValue) ?ResolvedInlineFunction {
    // qjs single-compare admission (JS_CallInternal, quickjs.c:17816):
    // generator/async function classes fall to the slow path here instead of
    // passing the four-class set test only to be rejected by the kind check.
    const function_object = object_ops.plainBytecodeFunctionObjectFromValue(func) orelse return null;
    return resolveInlineFunctionFromObject(global, function_object);
}

/// Same as `resolveInlineFunction` but accepts a pre-unpacked `*Object` whose
/// `class_id == bytecode_function` the caller has already verified. Used by
/// `op_call_method`'s shared-unpacking dispatch: the caller does
/// `objectFromValue(method)` once, then branches on `class_id` to either this
/// resolver (bytecode_function) or the native c_function fast arm — avoiding
/// a redundant `objectFromValue` for the ~85% native-method case.
pub inline fn resolveInlineFunctionFromObject(global: *core.Object, function_object: *core.Object) ?ResolvedInlineFunction {
    const function_data = function_object.bytecodeFunctionStoragePtr();
    const fb = function_data.function_bytecode orelse return null;
    // Raw one-word capture-array load, deferring the empty-sentinel/len
    // normalization captureSlice performs: every consumer slices
    // `var_refs[0..fb.closureVarCount()]`, and a fully-published callable with
    // a non-zero count has already installed its allocated array, while a
    // zero-count callable keeps the aligned dangling sentinel that a
    // zero-length slice never dereferences (BytecodeFunctionStorage.var_refs
    // contract). The empty-leaf arms never touch captures, so the hot plain
    // call keeps one load where the checked slice cost a csel chain.
    const captures_raw: [*]*core.VarRef = @ptrCast(function_data.var_refs);
    if (comptime builtin.mode == .Debug) {
        const checked = function_data.captureSlice();
        std.debug.assert(checked.len == fb.closureVarCount());
        std.debug.assert(checked.len == 0 or checked.ptr == captures_raw);
    }
    if (fb.functionKind() != .normal) return null;
    // Production callable publication proves the exact non-empty FAM layout;
    // take the three-load code+len hot-tail path instead of rechecking the
    // optional fixture/legacy shapes on every call.
    const call_facts = fb.canonicalCallFacts();
    if (fb.isDerivedClassConstructor()) return null;
    // Base-class-constructor rejection: the entry-opcode probe
    // (`code[0] == op.check_ctor`) moved to publication time
    // (publishExecutionFlags) as a CallFacts bit, so plain-call resolution
    // reads it from the snapshot it already loads instead of touching the
    // bytecode array's first byte on every call. Canonical published code is
    // immutable, so the hoisted predicate is exact.
    if (call_facts.execution.entry_rejects_plain_call) return null;
    // Realm gate: qjs reads `ctx = b->realm` from the shared FB. With FB now
    // resident directly in Object.u.func this is one dependent load, without a
    // per-closure realm cache or borrowed-holder registration.
    const function_realm = fb.realmContext() orelse return null;
    const function_global = function_realm.global orelse return null;
    if (function_global != global) return null;
    return .{
        .var_refs = captures_raw,
        .fb = fb,
        .call_facts = call_facts,
    };
}

/// Direct-constructor same-Machine resolver. It admits ordinary functions and
/// derived constructors, but not base classes: paired PMU measurements show
/// that entering a base class through the resident generic frame costs more
/// than its authoritative construction adapter. Keep this separate from
/// resolveInlineFunction so ordinary [[Call]] admission and its generated code
/// stay untouched.
pub inline fn resolveInlineDirectConstructorFunction(global: *core.Object, func: core.JSValue) ?ResolvedInlineFunction {
    const function_object = object_ops.plainBytecodeFunctionObjectFromValue(func) orelse return null;
    const function_data = function_object.bytecodeFunctionStoragePtr();
    const fb = function_data.function_bytecode orelse return null;
    const captures_raw: [*]*core.VarRef = @ptrCast(function_data.var_refs);
    if (comptime builtin.mode == .Debug) {
        const checked = function_data.captureSlice();
        std.debug.assert(checked.len == fb.closureVarCount());
        std.debug.assert(checked.len == 0 or checked.ptr == captures_raw);
    }
    if (fb.functionKind() != .normal) return null;
    const call_facts = fb.canonicalCallFacts();
    if (!fb.isDerivedClassConstructor() and call_facts.execution.entry_rejects_plain_call) return null;
    const function_realm = fb.realmContext() orelse return null;
    const function_global = function_realm.global orelse return null;
    if (function_global != global) return null;
    return .{
        .var_refs = captures_raw,
        .fb = fb,
        .call_facts = call_facts,
    };
}

/// Constructor-spread resolver. Unlike the measured direct-constructor path,
/// spread must also admit a base-class body reached by `super(...args)`.
/// Plain-call rejection is irrelevant because this path enters with a real
/// `new.target`; function kind, function class, and Realm are still checked by
/// the caller before the operand transaction commits.
pub inline fn resolveInlineSpreadConstructorFunction(global: *core.Object, func: core.JSValue) ?ResolvedInlineFunction {
    const function_object = object_ops.plainBytecodeFunctionObjectFromValue(func) orelse return null;
    const function_data = function_object.bytecodeFunctionStoragePtr();
    const fb = function_data.function_bytecode orelse return null;
    const captures_raw: [*]*core.VarRef = @ptrCast(function_data.var_refs);
    if (comptime builtin.mode == .Debug) {
        const checked = function_data.captureSlice();
        std.debug.assert(checked.len == fb.closureVarCount());
        std.debug.assert(checked.len == 0 or checked.ptr == captures_raw);
    }
    if (fb.functionKind() != .normal) return null;
    const function_realm = fb.realmContext() orelse return null;
    const function_global = function_realm.global orelse return null;
    if (function_global != global) return null;
    return .{
        .var_refs = captures_raw,
        .fb = fb,
        .call_facts = fb.canonicalCallFacts(),
    };
}

/// Resolve `func` to an inline-eligible bytecode call target for a call with
/// receiver `receiver` (`undefined` for plain calls, the property base for
/// method calls). Mirrors the plain-call leg of
/// `callValueOrBytecodeDispatch`; any condition that path
/// special-cases (class constructors, cross-realm calls, and async/generator
/// kinds) disqualifies the target so the slow
/// path keeps handling it. Direct eval captures use the ordinary indexed
/// var-ref cells and need no function-object binding overlay.
///
/// Arrow targets ARE eligible: their lexical `this` / `new.target` are
/// ordinary closure cells, so call-target resolution has no arrow arm.
pub inline fn resolveInlineTarget(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, func: core.JSValue) ?InlineTarget {
    var target: InlineTarget = undefined;
    if (!resolveInlineTargetInto(&target, ctx, global, receiver, func)) return null;
    return target;
}

/// Out-parameter form for hot routes that already own stable target storage.
/// Avoids materializing and then copying the 56-byte optional InlineTarget.
pub inline fn resolveInlineTargetInto(
    target: *InlineTarget,
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
) bool {
    _ = ctx;
    const resolved = resolveInlineFunction(global, func) orelse return false;
    target.* = resolved.bind(receiver, func);
    return true;
}

/// One active inline call level. Entries live in chunked, pointer-stable
/// storage; `frame`, `stack`, and the frame's FunctionBytecode are referenced by
/// the dispatch loop and backtrace pc borrows while the level is alive.
/// Work the caller must finish after an inline callee returns. Ordinary calls
/// push the result and resume immediately. Proxy `get` validates the trap
/// result against the target's post-call descriptor; generic for-of consumes
/// the returned iterator-result object before resuming the loop body.
pub const ReturnAction = enum(u8) {
    next,
    proxy_get,
    for_of_next,
    constructor,
    /// Return to the still-running native builtin that synchronously entered
    /// this bytecode frame. The result must not reach the suspended outer
    /// bytecode caller stack or resume its next opcode.
    native_boundary,
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
        /// A return that must leave the ordinary `.next` resume path. This bit
        /// covers Function.call's forwarded leaf and a synchronous native
        /// fence; `has_native_caller` distinguishes the former. Reusing the
        /// established cold-return test keeps ordinary Entry returns on their
        /// exact branch sequence and does not grow Entry.
        special_return: bool = false,
        /// This frame carries the logical depth and planned bytecode-stack
        /// cost of tail-call callers whose physical Entry storage was reused.
        /// QuickJS keeps those callers blocked in nested JS_CallInternal
        /// invocations until the final callee completes; `popFrameMode`
        /// releases both accumulated budgets together. The record overlays
        /// storage that is dead for every tail-replacement frame.
        tail_chain: bool = false,
        /// This frame entered through a JS_Call/COPY_ARGV-shaped forwarding
        /// boundary. Persist the pricing mode so teardown releases the exact
        /// bytes charged even after the transient InlineTarget is gone.
        copy_argv: bool = false,
        /// This Entry needs constructor completion. For an ordinary
        /// constructor, `native_caller` owns the eager fallback instance while
        /// the frame's `this` binding borrows it; for a derived constructor the
        /// slot is undefined because there is no pre-super instance. Normal
        /// completion moves the slot out, while abrupt completion releases it.
        constructor_completion: bool = false,
    };

    /// The Entry's sole persistent FunctionBytecode source is `frame.function`;
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
    /// Tagged by teardown flags: the native Function.call record skipped by
    /// transparent forwarding, or the ordinary-constructor fallback instance
    /// (undefined for a derived constructor). The native record is owned by
    /// this entry so a captured stack still sees qjs frame order
    /// `target -> call (native) -> caller`.
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
        return self.teardown.special_return and self.teardown.has_native_caller;
    }

    pub inline fn hasSpecialReturn(self: *const Entry) bool {
        return self.teardown.special_return;
    }

    pub inline fn isNativeBoundaryReturn(self: *const Entry) bool {
        return self.teardown.special_return and
            !self.teardown.has_native_caller and
            self.return_action == .native_boundary;
    }

    pub inline fn completesConstructor(self: *const Entry) bool {
        return self.teardown.constructor_completion;
    }

    fn takeConstructorFallback(self: *Entry) core.JSValue {
        std.debug.assert(self.teardown.constructor_completion);
        std.debug.assert(self.return_action == .constructor);
        std.debug.assert(!self.teardown.has_native_caller);
        const fallback = self.native_caller;
        self.native_caller = core.JSValue.undefinedValue();
        self.teardown.constructor_completion = false;
        return fallback;
    }

    /// Caller-resume record for the empty-leaf return arm, overlaid on Entry
    /// storage that is dead for empty-leaf entries. Default repr: the 16-byte
    /// `native_caller` value is live under `teardown.has_native_caller` or
    /// `teardown.constructor_completion` (neither can be an empty leaf; every
    /// reader checks the corresponding flag). Nan-boxed repr:
    /// `_stride_padding` is pure layout padding. The record holds the
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

    const TailChainBudget = extern struct {
        extra_depth: usize,
        planned_stack_bytes: usize,
    };

    /// Budgets retained by callers retired through tail-frame reuse. Tail
    /// replacements are generic, non-leaf frames and never own the synthetic
    /// native Function.call record. The default 16-byte JSValue representation
    /// uses that dead slot; NaN boxing uses the 16-byte stride padding that is
    /// otherwise occupied only by leaf resume words. Entry's measured layout
    /// is unchanged in both representations.
    inline fn tailChainBudgetSlot(self: *Entry) *TailChainBudget {
        std.debug.assert(!self.teardown.has_native_caller);
        std.debug.assert(!self.teardown.empty_leaf);
        std.debug.assert(!self.teardown.exact_args_leaf);
        std.debug.assert(!self.isForwardedLeaf());
        if (comptime core.value.nan_boxing) {
            comptime std.debug.assert(@sizeOf(@TypeOf(self._stride_padding)) >= @sizeOf(TailChainBudget));
            // An array-of-u8's type alignment remains one even when its field
            // declaration carries stronger alignment. Prove the actual field
            // address instead of rejecting that deliberately aligned storage.
            comptime std.debug.assert(@alignOf(Entry) >= @alignOf(TailChainBudget));
            comptime std.debug.assert(@offsetOf(Entry, "_stride_padding") % @alignOf(TailChainBudget) == 0);
            return @ptrCast(@alignCast(&self._stride_padding));
        } else {
            comptime std.debug.assert(@sizeOf(core.JSValue) >= @sizeOf(TailChainBudget));
            comptime std.debug.assert(@alignOf(core.JSValue) >= @alignOf(TailChainBudget));
            return @ptrCast(@alignCast(&self.native_caller));
        }
    }

    /// Move post-call work from a retired frame into its tail-call replacement.
    fn adoptContinuation(self: *Entry, continuation: *ReturnContinuation) void {
        std.debug.assert(self.return_action == .next);
        std.debug.assert(self.continuation_payload == 0);
        self.return_action = continuation.action;
        self.continuation_payload = continuation.payload;
        if (continuation.action == .native_boundary) {
            self.teardown.special_return = true;
        }
        continuation.action = .next;
        continuation.payload = 0;
    }

    /// Teardown bits whose presence means this frame's completion is not the
    /// plain one. Listed by name rather than as a literal mask so that adding a
    /// completion kind forces a decision here instead of silently classifying
    /// as ordinary; the comptime check below fails if any bit goes unclassified.
    ///
    /// Two bits are deliberately absent. `simple` is a teardown-shape fact an
    /// ordinary return requires rather than one it excludes, and `copy_argv`
    /// only prices the frame's bytecode-stack charge and has no completion
    /// effect at all.
    const extended_completion_flags: TeardownFlags = .{
        .has_native_caller = true,
        .empty_leaf = true,
        .exact_args_leaf = true,
        // Merge resolution: main generalized the phase branch's
        // `forwarded_leaf` into `special_return` at the same bit position,
        // widening it from Function.call's forwarded leaf to that plus a
        // synchronous native fence. Both are returns that must leave the
        // ordinary `.next` resume path, so the classification is unchanged and
        // the wider meaning only makes including it more correct.
        .special_return = true,
        .tail_chain = true,
        .constructor_completion = true,
    };

    comptime {
        const ordinary_compatible: TeardownFlags = .{ .simple = true, .copy_argv = true };
        const covered = @as(u8, @bitCast(extended_completion_flags)) |
            @as(u8, @bitCast(ordinary_compatible));
        if (covered != std.math.maxInt(u8))
            @compileError("a TeardownFlags bit is unclassified for return-mode purposes");
    }

    /// Whether this frame retires through the plain completion: push the
    /// result, resume the caller, nothing else.
    ///
    /// The generic return path establishes this today by interrogating the same
    /// state one bit at a time -- three leaf arms, the constructor arm, the
    /// tail-chain arm, the native-caller release, the continuation tag -- on
    /// every return, although the answer is fixed the moment the frame is
    /// published. This derives it from the already-loaded `teardown` byte with
    /// one masked compare, so nothing is stored and Entry does not grow.
    ///
    /// Reads ONLY completion-type facts. `frame.cold`, storage ownership, and
    /// whether the operand stack still owns its arena window are all decided
    /// while the body runs -- a callee can materialize `arguments`, fall back to
    /// heap storage, or grow its stack -- so they stay out of the
    /// classification and the ordinary epilogue keeps testing them dynamically.
    /// `frame.cold` in particular is NOT a proxy for extended completion: a
    /// forwarded leaf, a native-caller frame, a Proxy or for-of continuation
    /// and a tail-chain frame all leave it null, while `arguments` sets it on
    /// frames that complete plainly.
    pub inline fn isOrdinaryReturn(self: *const Entry) bool {
        const bits: u8 = @bitCast(self.teardown);
        if (bits & @as(u8, @bitCast(extended_completion_flags)) != 0) return false;
        if (!self.teardown.simple) return false;
        return self.return_action == .next;
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
        std.debug.assert(!self.teardown.constructor_completion);
        self.native_caller.free(rt);
    }

    noinline fn releaseConstructorFallback(self: *Entry, rt: *core.JSRuntime) void {
        std.debug.assert(self.teardown.constructor_completion);
        std.debug.assert(!self.teardown.has_native_caller);
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
            self.isForwardedLeaf())
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
        self.deinitEmptyLeafInline(ctx.runtime);
    }

    /// Return epilogue for a published empty leaf. The FunctionBytecode proves
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
    inline fn deinitEmptyLeafInline(self: *Entry, rt: *core.JSRuntime) void {
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
    inline fn deinitExactArgsLeafInline(self: *Entry, rt: *core.JSRuntime) void {
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
    inline fn deinitForwardedLeafInline(self: *Entry, rt: *core.JSRuntime) void {
        const frame = &self.frame;
        std.debug.assert(self.teardown.simple);
        std.debug.assert(self.isForwardedLeaf() and !self.teardown.empty_leaf);
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
        self.deinitSimpleResources(ctx);
        ctx.runtime.vm_stack.restore(self.arena_mark);
        self.profile_guard.deinit();
    }

    /// Release every resource in a simple frame except the VM-stack watermark
    /// and profiling restore record. Tail replacement retains the caller's
    /// alloca-shaped arena window until the final callee completes, exactly as
    /// QuickJS's nested JS_CallInternal frames remain live.
    inline fn deinitSimpleResources(self: *Entry, ctx: *core.JSContext) void {
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
        if (self.teardown.constructor_completion) self.releaseConstructorFallback(rt);
    }

    /// `deinitSimpleResources` for a frame `isOrdinaryReturn` already cleared.
    /// Same sequence and same order; the native-caller release and the
    /// constructor-fallback release are gone because the classification proved
    /// both bits clear. The first of those two tests alone was 6.22% of
    /// op_return in fib_rec.
    inline fn deinitOrdinarySimpleResources(self: *Entry, ctx: *core.JSContext) void {
        const rt = ctx.runtime;
        const frame = &self.frame;
        std.debug.assert(self.isOrdinaryReturn());
        std.debug.assert(self.canUseSimpleTeardown());
        std.debug.assert(frame.ownership.var_refs == .borrowed or frame.var_refs.len == 0);
        std.debug.assert(frame.locals.ptr + frame.locals.len == self.stack.values);
        if (frame.ownership.this_value == .owned) frame.this_value.free(rt);
        if (frame.ownership.current_function == .owned) frame.current_function.free(rt);
        if (frame.open_var_refs.len != 0) frame.closeOpenVarRefs(rt);
        // qjs done: close var refs first, then free local_buf..sp (quickjs.c:20701-20706).
        const live_values = frame.locals.ptr[0 .. frame.locals.len + self.stack.len()];
        for (live_values) |v| v.free(rt);
        for (frame.args) |v| v.free(rt);
    }

    /// `deinitReturned` for a plain completion. The leaf routing is gone -- the
    /// classification proved all three leaf bits clear -- so the only decision
    /// left is the one that genuinely cannot be made before the body runs:
    /// whether the frame still has the arena-backed shape simple teardown
    /// needs. A frame that grew its stack or materialized `arguments` keeps the
    /// unchanged general body.
    inline fn deinitOrdinaryReturned(self: *Entry, ctx: *core.JSContext) void {
        if (self.canUseSimpleTeardown()) {
            self.deinitOrdinarySimpleResources(ctx);
            ctx.runtime.vm_stack.restore(self.arena_mark);
            self.profile_guard.deinit();
            return;
        }
        self.deinitGeneral(ctx);
    }

    /// General teardown for frames whose stack, cold state, or storage escaped
    /// the common arena-backed shape.
    fn deinitGeneral(self: *Entry, ctx: *core.JSContext) void {
        self.deinitGeneralResources(ctx);
        ctx.runtime.vm_stack.restore(self.arena_mark);
        self.profile_guard.deinit();
    }

    fn deinitGeneralResources(self: *Entry, ctx: *core.JSContext) void {
        const rt = ctx.runtime;
        if (self.teardown.has_native_caller) self.releaseNativeCaller(rt);
        self.stack.deinit(rt);
        self.frame.deinitInlineCall(&rt.memory, rt);
        if (self.teardown.constructor_completion) self.releaseConstructorFallback(rt);
    }

    /// Successful tail replacement has already built and linked the target
    /// frame above this caller. Release the caller's values and heap-owned
    /// storage without rewinding the shared arena or restoring its profiling
    /// activation: both records are transferred to the replacement Entry.
    inline fn deinitForTailReplacement(self: *Entry, ctx: *core.JSContext) void {
        if (self.teardown.empty_leaf or self.teardown.exact_args_leaf or
            self.isForwardedLeaf())
            self.deinitGeneralResources(ctx)
        else if (self.canUseSimpleTeardown())
            self.deinitSimpleResources(ctx)
        else
            self.deinitGeneralResources(ctx);
    }
};

comptime {
    const base_size: usize = if (core.value.nan_boxing) 248 else 256;
    const expected_size = base_size + @sizeOf(vm_call.CallProfileGuard);
    if (@sizeOf(Entry) != expected_size) @compileError(std.fmt.comptimePrint(
        "inline Entry layout drifted: expected {d} bytes, found {d}",
        .{ expected_size, @sizeOf(Entry) },
    ));
}

/// The mutable execution resources for one active bytecode level. `frame`
/// owns the authoritative FunctionBytecode pointer (`frame.function`); the operand
/// stack and catch slot stay separate only because their storage lifetimes
/// differ from the frame slab. The struct itself is a borrowed bundle.
pub const ExecutionLevel = struct {
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    catch_target: *?usize,

    pub inline fn function(self: ExecutionLevel) *const bytecode.FunctionBytecode {
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
    direct_eval_vars_reach_global: bool = false,
    strict_unresolved_get_var: bool = false,
    generator_state: ?*core.Object = null,
    stop_on_yield: bool = false,
    stop_before_pc: ?usize = null,
    suspend_on_module_await: bool = false,
};

const entries_per_chunk: usize = 16;
const max_chunks: usize = 512;

/// A stack-local view over one contiguous segment of a Machine. The outer
/// view is frozen at a native fence while a synchronous callback installs a
/// live inner view above the native backtrace node. Nested native -> JS calls
/// therefore compose as independent segments instead of enumerating the same
/// outer Entry chain more than once.
pub const MachineBacktraceView = struct {
    machine: *const Machine,
    frozen_top: ?*Entry = null,
    bottom_exclusive: ?*Entry = null,
    include_l0: bool,
    live: bool = true,

    pub fn root(machine: *const Machine) MachineBacktraceView {
        return .{
            .machine = machine,
            .include_l0 = true,
        };
    }

    pub fn segment(machine: *const Machine, bottom_exclusive: ?*Entry) MachineBacktraceView {
        return .{
            .machine = machine,
            // A live segment reads Machine.top, never frozen_top. Nested
            // native reentry calls freeze before flipping `live`, so the
            // field is initialized before its first possible read.
            .frozen_top = if (comptime builtin.mode == .ReleaseFast) undefined else null,
            .bottom_exclusive = bottom_exclusive,
            .include_l0 = false,
        };
    }

    fn freeze(self: *MachineBacktraceView, top: ?*Entry) void {
        std.debug.assert(self.live);
        self.frozen_top = top;
        self.live = false;
    }

    fn thaw(self: *MachineBacktraceView) void {
        std.debug.assert(!self.live);
        self.frozen_top = null;
        self.live = true;
    }
};

fn resolveMachineBacktraceRange(
    machine: *const Machine,
    top: ?*Entry,
    bottom_exclusive: ?*Entry,
    include_l0: bool,
    index: usize,
) ?core.ActiveBacktraceSnapshot {
    var remaining = index;
    var cursor = top;
    while (cursor) |entry| {
        if (bottom_exclusive) |bottom| {
            if (entry == bottom) break;
        }
        if (remaining == 0) return exception_ops.frameBacktraceSnapshot(&entry.frame);
        remaining -= 1;
        if (entry.teardown.has_native_caller) {
            if (remaining == 0) return nativeBacktraceSnapshot(entry.native_caller);
            remaining -= 1;
        }
        cursor = entry.prev;
    }
    if (include_l0 and remaining == 0) return exception_ops.frameBacktraceSnapshot(machine.l0.level.frame);
    return null;
}

/// Backwards-compatible whole-Machine resolver used by colocated machinery
/// tests. Active invocations publish `resolveMachineBacktraceView` instead so
/// synchronous native callbacks can split the chain at their fence.
pub fn resolveMachineBacktrace(data: ?*const anyopaque, index: usize) ?core.ActiveBacktraceSnapshot {
    const machine: *const Machine = @ptrCast(@alignCast(data.?));
    return resolveMachineBacktraceRange(machine, machine.top, null, true, index);
}

pub fn resolveMachineBacktraceView(data: ?*const anyopaque, index: usize) ?core.ActiveBacktraceSnapshot {
    const view: *const MachineBacktraceView = @ptrCast(@alignCast(data.?));
    const top = if (view.live) view.machine.top else view.frozen_top;
    return resolveMachineBacktraceRange(
        view.machine,
        top,
        view.bottom_exclusive,
        view.include_l0,
        index,
    );
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

/// Exec-owned authority published through JSRuntime.active_invocation for the
/// lifetime of one `runWithArgsState`. Runtime stores only an opaque borrowed
/// pointer; callback routing must recover this type rather than deriving
/// execution authority from the observable backtrace chain.
pub const ActiveInvocation = struct {
    machine: *Machine,
    current_backtrace_view: *MachineBacktraceView,
};

pub inline fn activeInvocation(rt: *core.JSRuntime) ?*ActiveInvocation {
    const invocation_ptr = rt.active_invocation orelse return null;
    return @ptrCast(@alignCast(invocation_ptr));
}

const NativeBoundaryValidation = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) struct {
    stack_top: [*]core.JSValue,
    stack_len: usize,
    arena_mark: core.VmStackArena.Mark,
    call_depth: usize,
    native_call_depth: usize,
    stack_bytes: usize,
} else struct {};

/// One synchronous native -> bytecode transaction. It freezes the currently
/// visible Machine segment, pushes a callback-only segment above the native
/// frame, and records every execution budget that the callback must restore.
/// `push` is separate from `init` because the active frame borrows `self.view`
/// and therefore may only be wired after this scope reaches its final address.
pub const NativeBoundaryScope = struct {
    invocation: *ActiveInvocation,
    outer_view: *MachineBacktraceView,
    rt: *core.JSRuntime,
    view: MachineBacktraceView,
    frame: core.ActiveBacktraceFrame = undefined,
    fence_depth: usize,
    validation: NativeBoundaryValidation,

    pub fn init(invocation: *ActiveInvocation) NativeBoundaryScope {
        const machine = invocation.machine;
        return .{
            .invocation = invocation,
            .outer_view = invocation.current_backtrace_view,
            .rt = machine.ctx.runtime,
            .view = MachineBacktraceView.segment(machine, machine.top),
            .fence_depth = machine.depth,
            .validation = if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) blk: {
                const stack = machine.currentLevel().stack;
                break :blk .{
                    .stack_top = stack.topPtr(),
                    .stack_len = stack.len(),
                    .arena_mark = machine.ctx.runtime.vm_stack.mark(),
                    .call_depth = machine.ctx.runtime.hot.call_depth,
                    .native_call_depth = machine.ctx.runtime.hot.native_call_depth,
                    .stack_bytes = machine.ctx.runtime.hot.active_bytecode_stack_bytes,
                };
            } else .{},
        };
    }

    pub fn push(self: *NativeBoundaryScope) void {
        self.outer_view.freeze(self.view.bottom_exclusive);
        self.frame = .{
            .data = &self.view,
            .resolver = resolveMachineBacktraceView,
        };
        self.frame.previous = self.rt.hot.current_backtrace_frame;
        self.rt.hot.current_backtrace_frame = &self.frame;
        self.invocation.current_backtrace_view = &self.view;
    }

    pub fn deinit(self: *NativeBoundaryScope) void {
        const machine = self.invocation.machine;
        if (machine.depth > self.fence_depth) {
            machine.discardToDepth(self.fence_depth);
        }
        std.debug.assert(machine.depth == self.fence_depth);
        std.debug.assert(machine.top == self.view.bottom_exclusive);
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            const stack = machine.currentLevel().stack;
            std.debug.assert(stack.len() == self.validation.stack_len);
            std.debug.assert(stack.topPtr() == self.validation.stack_top);
            const mark = machine.ctx.runtime.vm_stack.mark();
            std.debug.assert(mark.chunk == self.validation.arena_mark.chunk);
            std.debug.assert(mark.used == self.validation.arena_mark.used);
            std.debug.assert(machine.ctx.runtime.hot.call_depth == self.validation.call_depth);
            std.debug.assert(machine.ctx.runtime.hot.native_call_depth == self.validation.native_call_depth);
            std.debug.assert(machine.ctx.runtime.hot.active_bytecode_stack_bytes == self.validation.stack_bytes);
        }

        self.popBacktrace();
    }

    /// Successful callback completion has already popped exactly to the
    /// native fence. Keep that common leg branch-free in ReleaseFast; the
    /// error-only `deinit` path above retains bounded defensive cleanup.
    pub fn finish(self: *NativeBoundaryScope) void {
        const machine = self.invocation.machine;
        std.debug.assert(machine.depth == self.fence_depth);
        std.debug.assert(machine.top == self.view.bottom_exclusive);
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            const stack = machine.currentLevel().stack;
            std.debug.assert(stack.len() == self.validation.stack_len);
            std.debug.assert(stack.topPtr() == self.validation.stack_top);
            const mark = machine.ctx.runtime.vm_stack.mark();
            std.debug.assert(mark.chunk == self.validation.arena_mark.chunk);
            std.debug.assert(mark.used == self.validation.arena_mark.used);
            std.debug.assert(machine.ctx.runtime.hot.call_depth == self.validation.call_depth);
            std.debug.assert(machine.ctx.runtime.hot.native_call_depth == self.validation.native_call_depth);
            std.debug.assert(machine.ctx.runtime.hot.active_bytecode_stack_bytes == self.validation.stack_bytes);
        }
        self.popBacktrace();
    }

    inline fn popBacktrace(self: *NativeBoundaryScope) void {
        if (comptime builtin.mode == .ReleaseFast) {
            // Successful and error exits both unlink this stack-local node
            // permanently. Avoid clearing dead fields on the ReleaseFast hot
            // leg; the next freeze overwrites `frozen_top`, and a live view
            // never reads it.
            std.debug.assert(self.rt.hot.current_backtrace_frame == &self.frame);
            self.rt.hot.current_backtrace_frame = self.frame.previous;
            self.invocation.current_backtrace_view = self.outer_view;
            self.outer_view.live = true;
        } else {
            const machine = self.invocation.machine;
            machine.ctx.popActiveBacktraceFrame(&self.frame);
            self.invocation.current_backtrace_view = self.outer_view;
            self.outer_view.thaw();
        }
    }
};

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
        if (comptime builtin.is_test) TestMetricStorage.metrics.machine_inits += 1;
        return .{
            .ctx = ctx,
            .output = output,
            .global = global,
            .l0 = l0,
        };
    }

    /// Drains any leftover inline frames (error propagation out of the
    /// dispatch loop without a catch handler) and releases chunk storage.
    pub fn deinit(self: *Machine) void {
        while (self.depth > 0) {
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
        if (comptime builtin.is_test) TestMetricStorage.metrics.entry_chunk_allocations += 1;
        // Pre-define each slot's `frame.var_refs` so the warm borrowed-
        // iterator constructor's store-elision compare
        // (`finishBorrowedIteratorFrame`) reads defined memory even on a
        // slot's first-ever push. Everything else in a virgin Entry stays
        // undefined until its first constructor writes it.
        for (chunk) |*virgin| virgin.frame.var_refs = &.{};
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
    fn pushFrame(
        self: *Machine,
        comptime setup_path: FrameSetupPath,
        comptime stack_preflighted: bool,
        comptime copy_argv: bool,
        global: *core.Object,
        target: *const InlineTarget,
        source: ArgsSource,
    ) align(64) HostError!*Entry {
        // Keep the release token independent of target/source ownership:
        // setup failure may destroy the callable (and its FunctionBytecode)
        // before this function's accounting errdefer runs.
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(
            target.fb,
            source.argCount(),
            copy_argv,
        );
        if (stack_preflighted) {
            std.debug.assert(!copy_argv);
            vm_call.commitInlineCallDepthBytes(self.ctx, planned_stack_bytes);
        } else {
            vm_call.enterInlineCallDepthBytes(self.ctx, global, planned_stack_bytes) catch |err| {
                cleanupStackSource(self.ctx.runtime, source);
                return err;
            };
        }
        errdefer vm_call.leaveInlineCallDepthBytes(self.ctx, planned_stack_bytes);
        const entry = self.acquireSlot(global) catch |err| {
            cleanupStackSource(self.ctx.runtime, source);
            return err;
        };
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
        entry.teardown.copy_argv = copy_argv;
        entry.frame.planned_stack_bytes = @intCast(planned_stack_bytes);
        // Link the new frame into the chain — qjs `sf->prev_frame =
        // rt->current_stack_frame; rt->current_stack_frame = sf;`
        // (quickjs.c:17869-17870).
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        if (comptime builtin.is_test) {
            TestMetricStorage.metrics.max_depth = @max(TestMetricStorage.metrics.max_depth, self.depth);
        }
        return entry;
    }

    /// True when the frame takes the straight-line `setupSimpleInlineEntry` path:
    /// a sloppy plain call (no receiver, undefined frame `this` → global)
    /// with simple parameters (no original-args snapshot), no global-var rebinds,
    /// args that can be borrowed in place, and all-cell closure captures
    /// (borrowable as `var_refs`). Each rejected condition is exactly a branch
    /// the lean path elides; method, moved-method, arity-padding, and snapshot
    /// variants are selected by the outlined fallback. Arrow lexical `this`
    /// remains an ordinary capture cell and does not affect frame eligibility;
    /// `setupInlineEntry` remains authoritative for non-simple parameters.
    fn isSimpleInlineFrame(target: *const InlineTarget, source: ArgsSource) bool {
        const function = target.fb;
        const execution = target.call_facts.execution;
        // fb-derived half (normal, sloppy, simple params, no
        // global-var rebinds) is precomputed during FunctionBytecode finalization:
        // one byte test instead of ~6 scattered FunctionBytecode bool loads
        // (the `ldrb [fb,#…]` cluster that dominated op_call). The remaining
        // checks below depend on the call site, not the bytecode.
        if (!execution.simple_inline_eligible) return false;
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
        const function = target.fb;
        const execution = target.call_facts.execution;
        if (source.metadata.moved or source.metadata.has_receiver) return null;
        if (!target.this_value.isUndefined()) return null;
        if (source.argCount() >= function.arg_count) return null;
        if (execution.simple_inline_eligible) return .sloppy;
        if (execution.strict_simple_inline_eligible) return .strict;
        if (execution.strict_simple_snapshot_inline_eligible) return .strict_snapshot;
        return null;
    }

    /// Select a simple frame for `[receiver, callable, args...]`, whether the
    /// region still occupies the caller stack or was moved aside for a Proxy
    /// continuation/tail-call reuse. Object and primitive receivers both
    /// transfer verbatim: qjs stores raw `this_obj` in this same
    /// JS_CallInternal frame and performs sloppy substitution or boxing only
    /// at OP_push_this (quickjs.c:17924-17944).
    fn methodSimpleInlineMode(target: *const InlineTarget, source: ArgsSource) ?MethodSimpleInlineMode {
        const function = target.fb;
        const execution = target.call_facts.execution;
        if (!source.metadata.has_receiver) return null;
        if (!target.this_value.same(source.values[0])) return null;

        const snapshot = execution.strict_simple_snapshot_inline_eligible;
        const no_snapshot = execution.simple_inline_eligible or execution.strict_simple_inline_eligible;
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
        const function = target.fb;
        const execution = target.call_facts.execution;
        const eligible = if (snapshot_args)
            execution.strict_simple_snapshot_inline_eligible
        else
            execution.strict_simple_inline_eligible;
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
        return setupSimpleInlineEntryImpl(strict_this, snapshot_args, pad_args, method_receiver, move_args, false, ctx, global, entry, target, source);
    }

    /// Constructor member of the simple-frame family. qjs builds constructor
    /// frames with the byte-identical JS_CallInternal prologue used for method
    /// calls — JS_CallConstructorInternal (quickjs.c:20845) passes straight
    /// into the shared alloca prologue (quickjs.c:17828-17871) and
    /// JS_CALL_FLAG_CONSTRUCTOR is never consumed by that bytecode prologue.
    /// The `constructor_this` instantiation differs from the method arm in one
    /// ownership byte: the frame's `this` binding is written `.borrowed` ONCE
    /// (the eager fallback instance is owned by `Entry.native_caller` under
    /// `teardown.constructor_completion`, which `pushConstructorCall` publishes
    /// right after this returns), instead of the retired general-path
    /// `.owned`-then-flip pair.
    ///
    /// `noinline` is LOAD-BEARING exactly as for `setupSimpleInlineEntry`:
    /// this body must not fold back into `pushConstructorCall`, or its
    /// register allocation re-couples with the push shell (fib precedent
    /// 3.09x→3.26x).
    noinline fn setupSimpleConstructorEntry(comptime snapshot_args: bool, comptime pad_args: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        return setupSimpleInlineEntryImpl(false, snapshot_args, pad_args, true, false, true, ctx, global, entry, target, source);
    }

    inline fn setupSimpleInlineEntryImpl(comptime strict_this: bool, comptime snapshot_args: bool, comptime pad_args: bool, comptime method_receiver: bool, comptime move_args: bool, comptime constructor_this: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        const rt = ctx.runtime;
        const function = target.fb;
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
        // Constructors are method-shaped stack regions (op_call_constructor
        // recast `[instance, callable, args...]`); tail-call reuse never
        // replaces a constructor Entry, so the moved variant cannot occur.
        comptime std.debug.assert(!constructor_this or (method_receiver and !move_args and !strict_this));
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
        // against the active chunk's actual length (4 KiB for the compact
        // first chunk, chunk_slots thereafter), and `entry.arena_mark` is
        // published only after the carve, so LLVM no longer reloads
        // chunk_count/active/used across a may-alias Entry store the way the
        // previous mark()+carve() pair did. A miss is pure (arena untouched);
        // the authoritative carve below keeps chunk switching and first use,
        // with heap fallback only when the arena is exhausted.
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
            .actual_arg_count = @intCast(actual_arg_count),
            .locals = locals,
            .args = frame_args,
            .var_refs = captures,
            .open_var_refs = open_var_refs,
            .storage_values = if (storage_on_heap) slab_values else &.{},
            .ownership = .{
                // A constructor frame BORROWS the eager fallback instance: the
                // owned reference moved out of the receiver slot is recorded in
                // `Entry.native_caller` by `pushConstructorCall` immediately
                // after this returns (no failable step in between), and
                // constructor completion / abrupt teardown releases it there.
                // Written `.borrowed` once instead of the retired owned→flip.
                .this_value = if (method_receiver and !constructor_this) .owned else .borrowed,
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
            std.debug.assert(source.argCount() >= @as(usize, target.fb.arg_count));
            if (snapshot_args) {
                std.debug.assert(target.call_facts.execution.strict_simple_snapshot_inline_eligible);
            } else {
                std.debug.assert(target.call_facts.execution.simple_inline_eligible or
                    target.call_facts.execution.strict_simple_inline_eligible);
            }
        } else if (strict_this) {
            std.debug.assert(isStrictSimpleInlineFrame(false, target, source));
        } else {
            std.debug.assert(isSimpleInlineFrame(target, source));
        }
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(
            target.fb,
            source.argCount(),
            false,
        );
        vm_call.enterInlineCallDepthBytes(self.ctx, global, planned_stack_bytes) catch |err| {
            cleanupStackSource(self.ctx.runtime, source);
            return err;
        };
        errdefer vm_call.leaveInlineCallDepthBytes(self.ctx, planned_stack_bytes);
        const entry = self.acquireSlot(global) catch |err| {
            cleanupStackSource(self.ctx.runtime, source);
            return err;
        };
        entry.return_action = .next;
        entry.continuation_payload = 0;
        if (snapshot_args and method_receiver) {
            // Snapshot construction owns a cold FrameCold allocation. Reuse
            // its existing isolated implementation here; inlining that body
            // duplicates roughly a kilobyte of cold/error machinery merely to
            // remove one call instruction from this less common method shape.
            try setupSimpleInlineEntry(strict_this, snapshot_args, false, method_receiver, false, self.ctx, global, entry, target, source);
        } else {
            try setupSimpleInlineEntryImpl(strict_this, snapshot_args, false, method_receiver, false, false, self.ctx, global, entry, target, source);
        }
        entry.frame.planned_stack_bytes = @intCast(planned_stack_bytes);
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
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        region_start: [*]core.JSValue,
    ) HostError!*Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const ctx = self.ctx;
        const rt = ctx.runtime;
        assertLeafEligible(leaf_this, function, call_facts);
        std.debug.assert(function.arg_count == 0 and function.var_count == 0);
        std.debug.assert(function.openVarRefCount() == 0);

        // The caller already retreated its logical operand top. Until the last
        // infallible transfer below, these slots remain the sole owners and
        // must be released even when depth/Entry acquisition fails — the same
        // full-region cleanup `cleanupStackSource` performs for the general
        // setup's failure arm.
        errdefer {
            freeSourceSlot(rt, &region_start[@intFromBool(method_receiver)]);
            if (method_receiver) freeSourceSlot(rt, &region_start[0]);
        }
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(function, 0, false);
        try vm_call.enterInlineCallDepthBytes(ctx, global, planned_stack_bytes);
        errdefer vm_call.leaveInlineCallDepthBytes(ctx, planned_stack_bytes);
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

        return self.finishEmptyLeafFrame(leaf_this, rt, entry, global, function, region_start, stack_window, storage_on_heap, planned_stack_bytes, self.callerResumePc());
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
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
    ) HostError!*Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const ctx = self.ctx;
        const rt = ctx.runtime;
        assertExactArgsLeafEligible(leaf_this, function, call_facts);
        std.debug.assert(@as(usize, function.arg_count) == argc and argc > 0);
        std.debug.assert(function.var_count == 0);
        std.debug.assert(function.openVarRefCount() == 0);

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
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(function, argc, false);
        try vm_call.enterInlineCallDepthBytes(ctx, global, planned_stack_bytes);
        errdefer vm_call.leaveInlineCallDepthBytes(ctx, planned_stack_bytes);
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

        return self.finishExactArgsLeafFrame(leaf_this, rt, entry, global, function, captures, region_start, argc, stack_window, storage_on_heap, planned_stack_bytes, self.callerResumePc());
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
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
    ) HostError!*Entry {
        const method_receiver = comptime leaf_this == .receiver;
        const ctx = self.ctx;
        const rt = ctx.runtime;
        assertCaptureLeafEligible(leaf_this, function, call_facts);
        std.debug.assert(function.arg_count == 0 and function.var_count == 0);
        std.debug.assert(function.openVarRefCount() == 0);
        std.debug.assert(captures.len != 0);

        // Same sole-owner contract as the zero-arg constructor: the caller
        // already retreated its logical operand top, so these slots must be
        // released when depth/Entry acquisition fails.
        errdefer {
            freeSourceSlot(rt, &region_start[@intFromBool(method_receiver)]);
            if (method_receiver) freeSourceSlot(rt, &region_start[0]);
        }
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(function, 0, false);
        try vm_call.enterInlineCallDepthBytes(ctx, global, planned_stack_bytes);
        errdefer vm_call.leaveInlineCallDepthBytes(ctx, planned_stack_bytes);
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

        return self.finishCaptureLeafFrame(leaf_this, rt, entry, global, function, captures, region_start, stack_window, storage_on_heap, planned_stack_bytes, self.callerResumePc());
    }

    /// Debug-only proof that the comptime `this` arm matches the published
    /// per-policy eligibility bit and the callee's frame-`this` policy: the
    /// sloppy arm substitutes the realm global and the raw arm preserves
    /// undefined for strict functions (the same is_strict|runtime_strict
    /// disjunction execution-flag publication folds into `strict_mode`).
    /// Arrow lexical `this` is a capture cell, independent of this policy.
    /// The receiver arm is policy-independent: every leaf transfers the raw
    /// receiver.
    inline fn assertLeafEligible(comptime leaf_this: LeafThis, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts) void {
        const execution = call_facts.execution;
        switch (comptime leaf_this) {
            .sloppy_global => std.debug.assert(execution.simple_inline_empty_leaf),
            .raw_undefined => std.debug.assert(execution.raw_this_inline_empty_leaf),
            .receiver => std.debug.assert(execution.simple_inline_empty_leaf or
                execution.raw_this_inline_empty_leaf),
        }
        if (comptime leaf_this != .receiver) {
            std.debug.assert((function.isStrictMode() or function.runtimeStrictMode()) == (leaf_this == .raw_undefined));
        }
    }

    /// Exact-args twin of `assertLeafEligible` against the O1 policy bytes.
    inline fn assertExactArgsLeafEligible(comptime leaf_this: LeafThis, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts) void {
        const execution = call_facts.execution;
        switch (comptime leaf_this) {
            .sloppy_global => std.debug.assert(execution.simple_inline_exact_args_leaf),
            .raw_undefined => std.debug.assert(execution.raw_this_inline_exact_args_leaf),
            .receiver => std.debug.assert(execution.simple_inline_exact_args_leaf or
                execution.raw_this_inline_exact_args_leaf),
        }
        if (comptime leaf_this != .receiver) {
            std.debug.assert((function.isStrictMode() or function.runtimeStrictMode()) == (leaf_this == .raw_undefined));
        }
    }

    /// Capture-leaf twin of `assertLeafEligible` against the O2 fused kind
    /// byte (the sole published eligibility carrier for this family).
    inline fn assertCaptureLeafEligible(comptime leaf_this: LeafThis, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts) void {
        const capture_kind = call_facts.execution.capture_leaf_kind;
        switch (comptime leaf_this) {
            .sloppy_global => std.debug.assert(capture_kind == .sloppy),
            .raw_undefined => std.debug.assert(capture_kind == .raw_this),
            .receiver => std.debug.assert(capture_kind != .none),
        }
        if (comptime leaf_this != .receiver) {
            std.debug.assert((function.isStrictMode() or function.runtimeStrictMode()) == (leaf_this == .raw_undefined));
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
    /// mirroring `setupSimpleInlineEntryImpl`'s strict_this arm. Arrow lexical
    /// `this` remains in its capture cell under either frame policy.
    inline fn finishEmptyLeafFrame(
        self: *Machine,
        comptime leaf_this: LeafThis,
        rt: *core.JSRuntime,
        entry: *Entry,
        global: *core.Object,
        function: *const bytecode.FunctionBytecode,
        region_start: [*]core.JSValue,
        stack_window: []core.JSValue,
        storage_on_heap: bool,
        planned_stack_bytes: usize,
        resume_pc: [*]const u8,
    ) *Entry {
        const method_receiver = comptime leaf_this == .receiver;
        std.debug.assert(rt == self.ctx.runtime);
        const callable_slot = &region_start[@intFromBool(method_receiver)];
        // K1 single pricing, extended through publication: the constructor's
        // committed figure is passed in instead of re-deriving the three
        // function-header scalars here (LLVM cannot CSE the reload across the
        // intervening entry stores; qjs prices alloca_size exactly once,
        // quickjs.c:17828-17836).
        std.debug.assert(planned_stack_bytes == vm_call.qjsBytecodeLeafFrameAllocaSize(function));
        // No failable operation follows the ownership transfer.
        entry.frame = .{
            .function = function,
            .this_value = switch (comptime leaf_this) {
                .receiver => takeSourceSlot(&region_start[0]),
                .raw_undefined => core.JSValue.undefinedValue(),
                .sloppy_global => global.value(),
            },
            .current_function = takeSourceSlot(callable_slot),
            .planned_stack_bytes = @intCast(planned_stack_bytes),
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
        rt: *core.JSRuntime,
        entry: *Entry,
        global: *core.Object,
        function: *const bytecode.FunctionBytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
        stack_window: []core.JSValue,
        storage_on_heap: bool,
        planned_stack_bytes: usize,
        resume_pc: [*]const u8,
    ) *Entry {
        const method_receiver = comptime leaf_this == .receiver;
        std.debug.assert(rt == self.ctx.runtime);
        const callable_slot = &region_start[@intFromBool(method_receiver)];
        const args_window: []core.JSValue =
            (region_start + @as(usize, @intFromBool(method_receiver)) + 1)[0..argc];
        // K1 single pricing, extended through publication (see
        // finishEmptyLeafFrame): exact-args commits price the empty
        // padded-argv prefix, so the constructor figure IS the leaf figure.
        std.debug.assert(planned_stack_bytes == vm_call.qjsBytecodeLeafFrameAllocaSize(function));
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
            // Exact-args pricing: argc == arg_count, so the padded-argv
            // prefix is empty and the leaf figure is the committed charge.
            .planned_stack_bytes = @intCast(planned_stack_bytes),
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
        rt: *core.JSRuntime,
        entry: *Entry,
        global: *core.Object,
        function: *const bytecode.FunctionBytecode,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        stack_window: []core.JSValue,
        storage_on_heap: bool,
        planned_stack_bytes: usize,
        resume_pc: [*]const u8,
    ) *Entry {
        const method_receiver = comptime leaf_this == .receiver;
        std.debug.assert(rt == self.ctx.runtime);
        const callable_slot = &region_start[@intFromBool(method_receiver)];
        // K1 single pricing, extended through publication (see
        // finishEmptyLeafFrame).
        std.debug.assert(planned_stack_bytes == vm_call.qjsBytecodeLeafFrameAllocaSize(function));
        // No failable operation follows the ownership transfer.
        entry.frame = .{
            .function = function,
            .this_value = switch (comptime leaf_this) {
                .receiver => takeSourceSlot(&region_start[0]),
                .raw_undefined => core.JSValue.undefinedValue(),
                .sloppy_global => global.value(),
            },
            .current_function = takeSourceSlot(callable_slot),
            .planned_stack_bytes = @intCast(planned_stack_bytes),
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
        return caller_frame.function.byteCode().ptr + caller_frame.pc;
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
        rt: *core.JSRuntime,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        region_start: [*]core.JSValue,
        resume_pc: [*]const u8,
    ) ?*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertLeafEligible(leaf_this, function, call_facts);
        // Vm-resident rt (see tailcall_dispatch.Vm.rt): the caller hands the
        // runtime in so this body loads neither ctx nor ctx.runtime.
        std.debug.assert(rt == self.ctx.runtime);
        // K1 single pricing: one geometry derivation feeds admission, commit,
        // and the persisted Entry charge (M1 dossier: the triple recompute was
        // the top opCall residual).
        const planned_stack_bytes = vm_call.qjsBytecodeLeafFrameAllocaSize(function);
        // K2 admission-commit fusion: one rt load carries the budget check,
        // the commit RMW, the carve, and the profile guard (qjs
        // check-then-alloca: the check is the commitment, quickjs.c:17837/
        // 17845). The rare chunk/carve misses below retreat the committed
        // charge on their cold exits before honoring the pure-miss contract.
        if (!vm_call.tryCommitInlineCallDepthBytesRt(rt, planned_stack_bytes)) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        }
        const entry = self.entryAt(index);

        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(stack_count) orelse {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        };

        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        return self.finishEmptyLeafFrame(leaf_this, rt, entry, global, function, region_start, carve.window, false, planned_stack_bytes, resume_pc);
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
        rt: *core.JSRuntime,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
        resume_pc: [*]const u8,
    ) ?*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertExactArgsLeafEligible(leaf_this, function, call_facts);
        std.debug.assert(@as(usize, function.arg_count) == argc and argc > 0);
        // Vm-resident rt (see tryPushEmptyLeafCallFast).
        std.debug.assert(rt == self.ctx.runtime);
        // K1 single pricing (argc == arg_count: padded-argv prefix empty).
        const planned_stack_bytes = vm_call.qjsBytecodeLeafFrameAllocaSize(function);
        // K2 admission-commit fusion (see `tryPushEmptyLeafCallFast`): the
        // rare chunk/carve misses retreat the committed charge cold.
        if (!vm_call.tryCommitInlineCallDepthBytesRt(rt, planned_stack_bytes)) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        }
        const entry = self.entryAt(index);

        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(stack_count) orelse {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        };

        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        return self.finishExactArgsLeafFrame(leaf_this, rt, entry, global, function, captures, region_start, argc, carve.window, false, planned_stack_bytes, resume_pc);
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
        rt: *core.JSRuntime,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        resume_pc: [*]const u8,
    ) ?*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertCaptureLeafEligible(leaf_this, function, call_facts);
        std.debug.assert(captures.len != 0);
        // Vm-resident rt (see tryPushEmptyLeafCallFast).
        std.debug.assert(rt == self.ctx.runtime);
        // K1 single pricing: one geometry derivation feeds admission, commit,
        // and the persisted Entry charge (M1 dossier: the triple recompute was
        // the top opCall residual).
        const planned_stack_bytes = vm_call.qjsBytecodeLeafFrameAllocaSize(function);
        // K2 admission-commit fusion (see `tryPushEmptyLeafCallFast`): the
        // rare chunk/carve misses retreat the committed charge cold.
        if (!vm_call.tryCommitInlineCallDepthBytesRt(rt, planned_stack_bytes)) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        }
        const entry = self.entryAt(index);

        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(stack_count) orelse {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        };

        entry.return_action = .next;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        return self.finishCaptureLeafFrame(leaf_this, rt, entry, global, function, captures, region_start, carve.window, false, planned_stack_bytes, resume_pc);
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
        // Point directly at the pointer-stable final FunctionBytecode. Target
        // resolution and frame setup neither copy nor allocate bytecode state.
        const function = target.fb;
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
        // bindings materialize later through OP_push_this/eval. Arrow lexical
        // `this` is read from its capture cell, never this frame slot.
        const fb_strict = target.fb.isStrictMode() or target.fb.runtimeStrictMode();
        const receiver_slot = sourceReceiverSlot(source);
        // Plain calls choose only the strict/sloppy frame policy. Arrow
        // bytecode reads lexical this through its ordinary closure cell;
        // method/Function.call receiver slots are still transferred below so
        // the ignored value has one clear owner until teardown.
        const plain_undefined_this = receiver_slot == null and target.this_value.isUndefined();
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
        //   new_target keeps Frame.init's absent cold-state default
        //   this .borrow, unless taken raw from the receiver slot (method call)
        //   -> then .take/owned. Lazy materialization updates this slot once.
        // `takeSourceSlot` nulls the source slot so the popped stack region
        // never double-frees the value (the leak guard the method-call comment
        // below describes).
        entry.frame.current_function = takeSourceSlot(callable_slot);
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
        const borrow_var_refs = !function.isGlobalVar() and
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
        if (borrow_var_refs) {
            // Alias the closure's captures (mutable slice; no merge replaced it).
            // The function object stays alive via
            // `frame.current_function`, so the cells outlive the frame.
            entry.frame.var_refs = target.captureSlice();
            entry.frame.ownership.var_refs = .borrowed;
        } else if (frame_var_refs.len != 0 or function.varRefNamesLen() != 0) {
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
        const execution = target.call_facts.execution;
        return execution.simple_inline_eligible or
            execution.strict_simple_inline_eligible or
            execution.strict_simple_snapshot_inline_eligible;
    }

    /// Zero-argument method prologue for an iterator record borrowed from the
    /// suspended caller. qjs's JS_CallInternal assigns `sf->cur_func = func_obj`
    /// and reads `this_obj` without retaining either value; the caller operand
    /// stack remains their owner. Keep this body separate from the established
    /// plain/method setup instances so a narrow iterator optimization cannot
    /// perturb their selector or register allocation.
    noinline fn setupBorrowedIteratorEntry(ctx: *core.JSContext, entry: *Entry, target: *const InlineTarget) HostError!void {
        const rt = ctx.runtime;
        const function = target.fb;
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

    fn canBorrowSourceArgs(function: *const bytecode.FunctionBytecode, source: ArgsSource) bool {
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
        if (target.call_facts.execution.simple_inline_empty_leaf and argc == 0) {
            return self.pushEmptyLeafCall(.sloppy_global, global, caller_stack, target.fb, target.call_facts, region_start);
        }
        if (target.call_facts.execution.raw_this_inline_empty_leaf and argc == 0) {
            return self.pushEmptyLeafCall(.raw_undefined, global, caller_stack, target.fb, target.call_facts, region_start);
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
        return self.pushFrame(.generic_after_exact_plain, false, false, global, target, source);
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
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        region_start: [*]core.JSValue,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertLeafEligible(leaf_this, function, call_facts);
        return self.pushEmptyLeafFrame(leaf_this, global, function, call_facts, region_start);
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
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
        argc: u16,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertExactArgsLeafEligible(leaf_this, function, call_facts);
        return self.pushExactArgsLeafFrame(leaf_this, global, function, call_facts, captures, region_start, argc);
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
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        captures: []*core.VarRef,
        region_start: [*]core.JSValue,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertCaptureLeafEligible(leaf_this, function, call_facts);
        return self.pushCaptureLeafFrame(leaf_this, global, function, call_facts, captures, region_start);
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
        const function = target.fb;
        const execution = target.call_facts.execution;
        // Shared arity gate first: the padded (`argc < arg_count`) siblings
        // fail one comparison and branch straight to the generic selector
        // instead of walking every eligibility byte on their way out.
        if (argc >= function.arg_count) {
            if (execution.simple_inline_eligible) {
                return self.pushExactSimpleFrame(false, false, true, global, target, source);
            }
            if (execution.strict_simple_snapshot_inline_eligible) {
                return self.pushExactSimpleFrame(false, true, true, global, target, source);
            }
        }
        return self.pushFrame(.generic, false, false, global, target, source);
    }

    /// Enter an ordinary constructor in this Machine. The caller has rewritten
    /// its constructor region to `[instance, callable, args...]`; generic
    /// method-shaped setup therefore transfers the raw instance into `this`
    /// without adding a second argument staging format. After setup, ownership
    /// moves from Frame.this_value into Entry.native_caller: `this` borrows the
    /// live fallback instance while constructor completion or abrupt teardown
    /// remains its single owner.
    pub noinline fn pushConstructorCall(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: *const InlineTarget,
        region_start: [*]core.JSValue,
        argc: u16,
        /// Constructor spread's parser-owned `new.target` operand, consumed on
        /// success; `null` for direct `new F(...)`, whose new-target is the
        /// callable itself. On failure the caller still owns it.
        owned_new_target: ?core.JSValue,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        std.debug.assert(target.this_value.isObject());
        const source = ArgsSource.initStack(region_start, argc, true);
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(
            target.fb,
            argc,
            false,
        );
        vm_call.enterInlineCallDepthBytes(self.ctx, global, planned_stack_bytes) catch |err| {
            cleanupStackSource(self.ctx.runtime, source);
            return err;
        };
        errdefer vm_call.leaveInlineCallDepthBytes(self.ctx, planned_stack_bytes);
        const entry = self.acquireSlot(global) catch |err| {
            cleanupStackSource(self.ctx.runtime, source);
            return err;
        };
        entry.return_action = .constructor;
        entry.continuation_payload = 0;
        // qjs constructor frames are built by the byte-identical
        // JS_CallInternal prologue used for method calls:
        // JS_CallConstructorInternal (quickjs.c:20845) enters the shared
        // alloca prologue (quickjs.c:17828-17871) and JS_CALL_FLAG_CONSTRUCTOR
        // is never consumed by that bytecode prologue. The caller already
        // recast the region to method shape `[instance, callable, args...]`
        // with `target.this_value == values[0]`, so the ordinary method
        // simple-frame selector applies verbatim; every constructor-specific
        // fact lives in the completion tail below. The simple slab partitions
        // give `frame.locals` a valid pointer even at var_count == 0 (empty
        // slice AT the operand-stack base), so `deinitSimpleResources`'s
        // live-operand derivation holds — unlike the retired attempt that set
        // `teardown.simple` on a `Frame.init`-defaulted general frame and
        // aborted in ReleaseSafe inside `popConstructorReturn`.
        if (methodSimpleInlineMode(target, source)) |mode| {
            switch (mode) {
                .stack_exact => try setupSimpleConstructorEntry(false, false, self.ctx, global, entry, target, source),
                .stack_padded => try setupSimpleConstructorEntry(false, true, self.ctx, global, entry, target, source),
                .stack_snapshot_exact => try setupSimpleConstructorEntry(true, false, self.ctx, global, entry, target, source),
                .stack_snapshot_padded => try setupSimpleConstructorEntry(true, true, self.ctx, global, entry, target, source),
                // `source` is built by initStack above: `moved` is statically
                // false, so the temporary-region variants cannot be selected.
                .moved_exact, .moved_padded, .moved_snapshot_exact, .moved_snapshot_padded => unreachable,
            }
        } else {
            setupInlineEntry(self.ctx, global, entry, target, source) catch |err| return err;
            // General setup took the receiver `.owned` (its method arm); move
            // to the same write-once `.borrowed` the simple variants publish,
            // BEFORE the fallback slot takes ownership below.
            std.debug.assert(entry.frame.ownership.this_value == .owned);
            entry.frame.ownership.this_value = .borrowed;
        }
        errdefer entry.deinit(self.ctx);

        // Publish the fallback-instance ownership before the failable
        // new-target transfer: with `constructor_completion` + `native_caller`
        // set, `entry.deinit` releases the instance exactly once through
        // `releaseConstructorFallback` on either teardown route, while the
        // frame's `.borrowed` this can never double-free it. The bit is set
        // AFTER setup because both setup families assign the whole teardown
        // byte.
        std.debug.assert(entry.frame.this_value.same(target.this_value));
        entry.native_caller = entry.frame.this_value;
        entry.teardown.constructor_completion = true;
        // qjs keeps `new_target` in a JS_CallInternal register and gives
        // JSStackFrame no field for it (quickjs.c:405-417); only a function
        // that actually reads `new.target` pays anything, at the
        // OP_special_object dup (quickjs.c:17984). Direct construction has
        // `new.target == current_function`, so record the alias instead of
        // heap-allocating a cold box on every `new`.
        entry.frame.ownership.new_target = .aliases_function;
        if (owned_new_target) |value| {
            try entry.frame.takeConstructorNewTarget(&self.ctx.runtime.memory, self.ctx.runtime, value);
        }
        entry.frame.planned_stack_bytes = @intCast(planned_stack_bytes);

        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        return entry;
    }

    /// Derived twin of pushConstructorCall. Direct construction has
    /// `new.target == current_function`, but no eager instance: the frame owns
    /// an uninitialized `this` binding until parser-emitted super()/return
    /// bytecode resolves it. The constructor-completion bit uses an undefined
    /// native_caller slot as the no-fallback sentinel.
    pub noinline fn pushDerivedConstructorCall(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: *const InlineTarget,
        region_start: [*]core.JSValue,
        argc: u16,
        /// See `pushConstructorCall`: consumed on success, caller-owned on failure.
        owned_new_target: ?core.JSValue,
    ) HostError!*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        std.debug.assert(target.this_value.isUninitialized());
        const source = ArgsSource.initStack(region_start, argc, true);
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(
            target.fb,
            argc,
            false,
        );
        vm_call.enterInlineCallDepthBytes(self.ctx, global, planned_stack_bytes) catch |err| {
            cleanupStackSource(self.ctx.runtime, source);
            return err;
        };
        errdefer vm_call.leaveInlineCallDepthBytes(self.ctx, planned_stack_bytes);
        const entry = self.acquireSlot(global) catch |err| {
            cleanupStackSource(self.ctx.runtime, source);
            return err;
        };
        entry.return_action = .constructor;
        entry.continuation_payload = 0;
        setupInlineEntry(self.ctx, global, entry, target, source) catch |err| return err;
        errdefer entry.deinit(self.ctx);

        entry.frame.ownership.new_target = .aliases_function;
        if (owned_new_target) |value| {
            try entry.frame.takeConstructorNewTarget(&self.ctx.runtime.memory, self.ctx.runtime, value);
        }
        std.debug.assert(entry.frame.this_value.isUninitialized());
        entry.native_caller = core.JSValue.undefinedValue();
        entry.teardown.constructor_completion = true;
        entry.frame.planned_stack_bytes = @intCast(planned_stack_bytes);

        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        return entry;
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

    pub fn nativeBoundarySimpleEligible(target: *const InlineTarget) bool {
        const execution = target.call_facts.execution;
        return execution.simple_inline_eligible or
            execution.strict_simple_inline_eligible or
            execution.strict_simple_snapshot_inline_eligible;
    }

    /// Synchronous native callbacks keep receiver/callable rooted in the
    /// still-live native algorithm, so a simple bytecode frame can borrow both
    /// bindings and materialize only its writable arguments. This is the
    /// general native-fence prologue — it is selected by Function.apply and
    /// every later callback cohort, not by argument count or receiver value.
    pub fn pushNativeBoundaryCopiedArgs(
        self: *Machine,
        global: *core.Object,
        target: *const InlineTarget,
        args: []const core.JSValue,
    ) HostError!?*Entry {
        return self.pushNativeBoundarySimple(false, global, target, args, &.{});
    }

    /// Owned-argument twin. Setup moves only the argument tail after every
    /// fallible allocation succeeds; receiver/callable remain borrowed from
    /// the caller's rooted transaction prefix.
    pub fn pushNativeBoundaryMovedArgs(
        self: *Machine,
        global: *core.Object,
        target: *const InlineTarget,
        args: []core.JSValue,
    ) HostError!?*Entry {
        return self.pushNativeBoundarySimple(true, global, target, args, args);
    }

    /// Allocation-free native-fence prologue for already-warmed Entry and VM
    /// arena storage. A null result is a pure miss: budgets, ownership, arena
    /// watermarks, and Machine links are unchanged, so the caller must take
    /// the authoritative `pushNativeBoundaryCopiedArgs` path.
    pub inline fn tryPushNativeBoundaryCopiedArgsFast(
        self: *Machine,
        rt: *core.JSRuntime,
        target: *const InlineTarget,
        args: []const core.JSValue,
    ) ?*Entry {
        return self.tryPushNativeBoundaryArgsFast(false, rt, target, args, &.{});
    }

    /// Owned-argument twin. Arguments move only after every admission and
    /// capacity check succeeds; a miss leaves the caller's transaction intact.
    pub inline fn tryPushNativeBoundaryMovedArgsFast(
        self: *Machine,
        rt: *core.JSRuntime,
        target: *const InlineTarget,
        args: []core.JSValue,
    ) ?*Entry {
        return self.tryPushNativeBoundaryArgsFast(true, rt, target, args, args);
    }

    inline fn tryPushNativeBoundaryArgsFast(
        self: *Machine,
        comptime move_args: bool,
        rt: *core.JSRuntime,
        target: *const InlineTarget,
        args: []const core.JSValue,
        moved_args: []core.JSValue,
    ) ?*Entry {
        std.debug.assert(rt == self.ctx.runtime);
        if (!nativeBoundarySimpleEligible(target)) return null;
        const execution = target.call_facts.execution;
        if (execution.simple_inline_empty_leaf or
            execution.raw_this_inline_empty_leaf)
        {
            return self.tryPushNativeBoundaryEmptyFast(rt, target, args.len);
        }
        if (execution.exact_args_leaf_kind != .none) {
            return self.tryPushNativeBoundaryLeafArgsFast(
                move_args,
                rt,
                target,
                args,
                moved_args,
            );
        }
        // NB2-C: the moved general shape (e.g. RayTrace's `initialize` via
        // Function.apply — materializes arguments, var_count > 0) has a warm
        // twin too. Copied callers keep the authoritative path: the copied
        // variant is inlined at three call sites with zero measured events,
        // and widening a shared hot body has regressed layout before.
        if (comptime move_args) {
            return self.tryPushNativeBoundarySimpleGeneralFast(rt, target, moved_args);
        }
        return null;
    }

    inline fn tryPushNativeBoundaryEmptyFast(
        self: *Machine,
        rt: *core.JSRuntime,
        target: *const InlineTarget,
        actual_arg_count: usize,
    ) ?*Entry {
        const function = target.fb;
        const execution = target.call_facts.execution;
        std.debug.assert(execution.simple_inline_empty_leaf or
            execution.raw_this_inline_empty_leaf);
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(
            function,
            actual_arg_count,
            true,
        );
        if (!vm_call.tryCommitInlineCallDepthBytesRt(rt, planned_stack_bytes)) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        }
        const entry = self.entryAt(index);
        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(stack_count) orelse {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        };

        entry.return_action = .native_boundary;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        entry.frame = .{
            .function = function,
            .this_value = target.this_value,
            .current_function = target.callable,
            .actual_arg_count = @intCast(actual_arg_count),
            .planned_stack_bytes = @intCast(planned_stack_bytes),
            .locals = carve.window[0..0],
            .storage_values = &.{},
            .ownership = .{
                .this_value = .borrowed,
                .current_function = .borrowed,
                .storage = .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(
            &rt.memory,
            rt.vm_stack_arena_policy,
            carve.window,
        );
        entry.teardown = .{
            .simple = true,
            .special_return = true,
            .copy_argv = true,
        };
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        if (comptime builtin.is_test) {
            TestMetricStorage.metrics.max_depth = @max(TestMetricStorage.metrics.max_depth, self.depth);
        }
        return entry;
    }

    /// Warm form of `pushNativeBoundaryLeafArgs`: exact-leaf publication
    /// proves the frame has no arguments/rest/eval consumer, so extra actual
    /// arguments need not be copied into writable parameter slots. The full
    /// actual argc and qjs stack-budget charge remain authoritative.
    inline fn tryPushNativeBoundaryLeafArgsFast(
        self: *Machine,
        comptime move_args: bool,
        rt: *core.JSRuntime,
        target: *const InlineTarget,
        args: []const core.JSValue,
        moved_args: []core.JSValue,
    ) ?*Entry {
        const function = target.fb;
        std.debug.assert(target.call_facts.execution.exact_args_leaf_kind != .none);
        if (move_args) std.debug.assert(args.ptr == moved_args.ptr and args.len == moved_args.len) else std.debug.assert(moved_args.len == 0);
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(
            function,
            args.len,
            true,
        );
        if (!vm_call.tryCommitInlineCallDepthBytesRt(rt, planned_stack_bytes)) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        }
        const entry = self.entryAt(index);
        const frame_arg_count: usize = @intCast(function.arg_count);
        const copied_arg_count = @min(args.len, frame_arg_count);
        const stack_count = @as(usize, function.stack_size) + 1;
        const total = frame_arg_count + stack_count;
        const carve = rt.vm_stack.carveActiveMarked(total) orelse {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        };

        const frame_args = carve.window[0..frame_arg_count];
        const stack_window = carve.window[frame_arg_count..];
        if (move_args) {
            @memcpy(frame_args[0..copied_arg_count], moved_args[0..copied_arg_count]);
            @memset(moved_args[0..copied_arg_count], core.JSValue.undefinedValue());
        } else {
            for (args[0..copied_arg_count], 0..) |arg, arg_index| frame_args[arg_index] = arg.dup();
        }
        @memset(frame_args[copied_arg_count..], core.JSValue.undefinedValue());
        const captures = target.captureSlice();
        entry.return_action = .native_boundary;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        entry.frame = .{
            .function = function,
            .this_value = target.this_value,
            .current_function = target.callable,
            .actual_arg_count = @intCast(args.len),
            .locals = stack_window[0..0],
            .args = frame_args,
            .var_refs = captures,
            .planned_stack_bytes = @intCast(planned_stack_bytes),
            .storage_values = &.{},
            .ownership = .{
                .this_value = .borrowed,
                .current_function = .borrowed,
                .var_refs = if (captures.len > 0) .borrowed else .owned,
                .storage = .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(
            &rt.memory,
            rt.vm_stack_arena_policy,
            stack_window,
        );
        entry.teardown = .{
            .simple = true,
            .special_return = true,
            .copy_argv = true,
        };
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        if (comptime builtin.is_test) {
            TestMetricStorage.metrics.max_depth = @max(TestMetricStorage.metrics.max_depth, self.depth);
        }
        return entry;
    }

    /// Warm form of the general `setupNativeBoundarySimpleEntry` shape for
    /// MOVED arguments (NB2-C): eligibility is already proven, the Entry slot
    /// and VM arena are warm, and the frame carries no original-args snapshot
    /// (sloppy simple-parameter functions — the mapped-arguments shape — plus
    /// any zero-argument call), so the FrameCold allocation, the fallback
    /// carve/heap legs, and the errdefer unwind machinery all vanish. The
    /// geometry is exactly the authoritative slab: args | locals | operand
    /// stack | open-var-ref tail. Unlike the exact-leaf twin, the argument
    /// window is `max(actual, declared)` and ALL actuals are copied —
    /// `arguments` observes extra actual arguments. A null result is a pure
    /// miss with every budget and watermark unchanged.
    inline fn tryPushNativeBoundarySimpleGeneralFast(
        self: *Machine,
        rt: *core.JSRuntime,
        target: *const InlineTarget,
        moved_args: []core.JSValue,
    ) ?*Entry {
        const function = target.fb;
        std.debug.assert(nativeBoundarySimpleEligible(target));
        const actual_arg_count = moved_args.len;
        // Snapshot-carrying shapes (strict / derived ctor / non-simple
        // parameter lists with argc > 0) allocate a FrameCold box; they keep
        // the authoritative path.
        if (frame_mod.originalArgCount(
            actual_arg_count,
            frame_mod.argumentsNeedsOriginalSnapshot(function),
        ) != 0) return null;
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(
            function,
            actual_arg_count,
            true,
        );
        if (!vm_call.tryCommitInlineCallDepthBytesRt(rt, planned_stack_bytes)) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        }
        const entry = self.entryAt(index);

        const frame_arg_count = frame_mod.frameArgCount(function, actual_arg_count);
        const var_count: usize = function.var_count;
        const stack_count = @as(usize, function.stack_size) + 1;
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(function);
        const open_slots = if (open_var_ref_count == 0)
            0
        else
            (open_var_ref_count * @sizeOf(?*core.VarRef) + (@sizeOf(core.JSValue) - 1)) / @sizeOf(core.JSValue);
        const total = frame_arg_count + var_count + stack_count + open_slots;
        const carve = rt.vm_stack.carveActiveMarked(total) orelse {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        };

        const frame_args = carve.window[0..frame_arg_count];
        const locals = carve.window[frame_arg_count..][0..var_count];
        const stack_window = carve.window[frame_arg_count + var_count ..][0..stack_count];
        const open_start = frame_arg_count + var_count + stack_count;
        const open_var_refs: []?*core.VarRef = if (open_slots == 0)
            &.{}
        else
            std.mem.bytesAsSlice(
                ?*core.VarRef,
                std.mem.sliceAsBytes(carve.window[open_start..][0..open_slots]),
            )[0..open_var_ref_count];

        @memset(locals, core.JSValue.undefinedValue());
        if (open_var_refs.len != 0) @memset(open_var_refs, null);
        @memcpy(frame_args[0..actual_arg_count], moved_args);
        @memset(moved_args, core.JSValue.undefinedValue());
        @memset(frame_args[actual_arg_count..], core.JSValue.undefinedValue());

        const captures = target.captureSlice();
        entry.return_action = .native_boundary;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        entry.frame = .{
            .function = function,
            .this_value = target.this_value,
            .current_function = target.callable,
            .actual_arg_count = @intCast(actual_arg_count),
            .locals = locals,
            .args = frame_args,
            .var_refs = captures,
            .open_var_refs = open_var_refs,
            .planned_stack_bytes = @intCast(planned_stack_bytes),
            .storage_values = &.{},
            .ownership = .{
                .this_value = .borrowed,
                .current_function = .borrowed,
                .var_refs = if (captures.len > 0) .borrowed else .owned,
                .storage = .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(
            &rt.memory,
            rt.vm_stack_arena_policy,
            stack_window,
        );
        entry.teardown = .{
            .simple = true,
            .special_return = true,
            .copy_argv = true,
        };
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        if (comptime builtin.is_test) {
            TestMetricStorage.metrics.max_depth = @max(TestMetricStorage.metrics.max_depth, self.depth);
        }
        return entry;
    }

    fn pushNativeBoundarySimple(
        self: *Machine,
        comptime move_args: bool,
        global: *core.Object,
        target: *const InlineTarget,
        args: []const core.JSValue,
        moved_args: []core.JSValue,
    ) HostError!?*Entry {
        if (!nativeBoundarySimpleEligible(target)) return null;
        if (move_args) std.debug.assert(args.ptr == moved_args.ptr and args.len == moved_args.len) else std.debug.assert(moved_args.len == 0);
        if (target.call_facts.execution.simple_inline_empty_leaf or
            target.call_facts.execution.raw_this_inline_empty_leaf)
        {
            return try self.pushNativeBoundaryEmpty(global, target, args.len);
        }
        if (target.call_facts.execution.exact_args_leaf_kind != .none) {
            return try self.pushNativeBoundaryLeafArgs(
                move_args,
                global,
                target,
                args,
                moved_args,
            );
        }

        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(
            target.fb,
            args.len,
            true,
        );
        try vm_call.enterInlineCallDepthBytes(self.ctx, global, planned_stack_bytes);
        errdefer vm_call.leaveInlineCallDepthBytes(self.ctx, planned_stack_bytes);
        const entry = try self.acquireSlot(global);
        entry.return_action = .native_boundary;
        entry.continuation_payload = 0;
        try setupNativeBoundarySimpleEntry(
            move_args,
            self.ctx,
            entry,
            target,
            args,
            moved_args,
        );
        entry.teardown.copy_argv = true;
        entry.frame.planned_stack_bytes = @intCast(planned_stack_bytes);
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        if (comptime builtin.is_test) {
            TestMetricStorage.metrics.max_depth = @max(TestMetricStorage.metrics.max_depth, self.depth);
        }
        return entry;
    }

    /// Leaf-geometry native-fence twin of `pushNativeBoundaryEmpty`. Published
    /// exact-leaf facts prove there are no locals, open refs, arguments/rest
    /// consumer, or direct eval. Unlike the ordinary exact-arity leaf
    /// epilogue, a native callback may supply fewer or extra arguments; this
    /// path materializes the writable declared-parameter window and still
    /// records the full actual argc before returning through the native
    /// special continuation.
    fn pushNativeBoundaryLeafArgs(
        self: *Machine,
        comptime move_args: bool,
        global: *core.Object,
        target: *const InlineTarget,
        args: []const core.JSValue,
        moved_args: []core.JSValue,
    ) HostError!*Entry {
        const function = target.fb;
        std.debug.assert(target.call_facts.execution.exact_args_leaf_kind != .none);
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(
            function,
            args.len,
            true,
        );
        try vm_call.enterInlineCallDepthBytes(self.ctx, global, planned_stack_bytes);
        errdefer vm_call.leaveInlineCallDepthBytes(self.ctx, planned_stack_bytes);

        const entry = try self.acquireSlot(global);
        entry.return_action = .native_boundary;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(self.ctx.runtime);
        errdefer entry.profile_guard.deinit();

        const rt = self.ctx.runtime;
        const frame_arg_count: usize = @intCast(function.arg_count);
        const copied_arg_count = @min(args.len, frame_arg_count);
        const stack_count = @as(usize, function.stack_size) + 1;
        const total = try std.math.add(usize, frame_arg_count, stack_count);
        var storage_on_heap = false;
        const slab_values = if (rt.vm_stack.carveActiveMarked(total)) |active_carve| blk: {
            entry.arena_mark = active_carve.mark;
            break :blk active_carve.window;
        } else blk: {
            entry.arena_mark = rt.vm_stack.mark();
            break :blk rt.vm_stack.carve(&rt.memory, total) orelse heap: {
                storage_on_heap = true;
                break :heap try rt.memory.alloc(core.JSValue, total);
            };
        };
        errdefer rt.vm_stack.restore(entry.arena_mark);
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, slab_values);

        const frame_args = slab_values[0..frame_arg_count];
        const stack_window = slab_values[frame_arg_count..];
        if (move_args) {
            @memcpy(frame_args[0..copied_arg_count], moved_args[0..copied_arg_count]);
            @memset(moved_args[0..copied_arg_count], core.JSValue.undefinedValue());
        } else {
            for (args[0..copied_arg_count], 0..) |arg, index| frame_args[index] = arg.dup();
        }
        @memset(frame_args[copied_arg_count..], core.JSValue.undefinedValue());
        const captures = target.captureSlice();
        entry.frame = .{
            .function = function,
            .this_value = target.this_value,
            .current_function = target.callable,
            .actual_arg_count = @intCast(args.len),
            .locals = stack_window[0..0],
            .args = frame_args,
            .var_refs = captures,
            .planned_stack_bytes = @intCast(planned_stack_bytes),
            .storage_values = if (storage_on_heap) slab_values else &.{},
            .ownership = .{
                .this_value = .borrowed,
                .current_function = .borrowed,
                .var_refs = if (captures.len > 0) .borrowed else .owned,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(
            &rt.memory,
            rt.vm_stack_arena_policy,
            stack_window,
        );
        entry.teardown = .{
            .simple = true,
            .special_return = true,
            .copy_argv = true,
        };
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        if (comptime builtin.is_test) {
            TestMetricStorage.metrics.max_depth = @max(TestMetricStorage.metrics.max_depth, self.depth);
        }
        return entry;
    }

    /// Native-fence prologue for a published zero-parameter empty geometry.
    /// It deliberately does not set the ordinary empty-leaf bit: return still
    /// uses the native special-return arm, while publication skips the generic
    /// args/locals/open-ref/snapshot partitioning that the call facts prove is
    /// empty. Extra actual arguments are unobservable without arguments/rest/
    /// eval, but their full count and qjs stack-budget charge remain recorded.
    /// Receiver and callable remain borrowed from the native algorithm.
    fn pushNativeBoundaryEmpty(
        self: *Machine,
        global: *core.Object,
        target: *const InlineTarget,
        actual_arg_count: usize,
    ) HostError!*Entry {
        const function = target.fb;
        const execution = target.call_facts.execution;
        std.debug.assert(execution.simple_inline_empty_leaf or
            execution.raw_this_inline_empty_leaf);
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(
            function,
            actual_arg_count,
            true,
        );
        try vm_call.enterInlineCallDepthBytes(self.ctx, global, planned_stack_bytes);
        errdefer vm_call.leaveInlineCallDepthBytes(self.ctx, planned_stack_bytes);

        const entry = try self.acquireSlot(global);
        const rt = self.ctx.runtime;
        entry.return_action = .native_boundary;
        entry.continuation_payload = 0;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        const stack_count = @as(usize, function.stack_size) + 1;
        var storage_on_heap = false;
        const stack_window = if (rt.vm_stack.carveActiveMarked(stack_count)) |active_carve| blk: {
            entry.arena_mark = active_carve.mark;
            break :blk active_carve.window;
        } else blk: {
            entry.arena_mark = rt.vm_stack.mark();
            break :blk rt.vm_stack.carve(&rt.memory, stack_count) orelse heap: {
                storage_on_heap = true;
                break :heap try rt.memory.alloc(core.JSValue, stack_count);
            };
        };
        errdefer rt.vm_stack.restore(entry.arena_mark);
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, stack_window);

        entry.frame = .{
            .function = function,
            .this_value = target.this_value,
            .current_function = target.callable,
            .actual_arg_count = @intCast(actual_arg_count),
            .planned_stack_bytes = @intCast(planned_stack_bytes),
            .locals = stack_window[0..0],
            .storage_values = if (storage_on_heap) stack_window else &.{},
            .ownership = .{
                .this_value = .borrowed,
                .current_function = .borrowed,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(
            &rt.memory,
            rt.vm_stack_arena_policy,
            stack_window,
        );
        entry.teardown = .{
            .simple = true,
            .special_return = true,
            .copy_argv = true,
        };
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        if (comptime builtin.is_test) {
            TestMetricStorage.metrics.max_depth = @max(TestMetricStorage.metrics.max_depth, self.depth);
        }
        return entry;
    }

    noinline fn setupNativeBoundarySimpleEntry(
        comptime move_args: bool,
        ctx: *core.JSContext,
        entry: *Entry,
        target: *const InlineTarget,
        args: []const core.JSValue,
        moved_args: []core.JSValue,
    ) HostError!void {
        const rt = ctx.runtime;
        const function = target.fb;
        std.debug.assert(nativeBoundarySimpleEligible(target));
        entry.catch_target = null;
        entry.teardown = .{
            .simple = true,
            .special_return = true,
        };
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        const actual_arg_count = args.len;
        const frame_arg_count = frame_mod.frameArgCount(function, actual_arg_count);
        const snapshot_count = frame_mod.originalArgCount(
            actual_arg_count,
            frame_mod.argumentsNeedsOriginalSnapshot(function),
        );
        const var_count: usize = function.var_count;
        const stack_count = @as(usize, function.stack_size) + 1;
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(function);
        const open_slots = if (open_var_ref_count == 0)
            0
        else
            (open_var_ref_count * @sizeOf(?*core.VarRef) + (@sizeOf(core.JSValue) - 1)) / @sizeOf(core.JSValue);
        const args_and_locals = try std.math.add(usize, frame_arg_count, var_count);
        const through_stack = try std.math.add(usize, args_and_locals, stack_count);
        const through_open = try std.math.add(usize, through_stack, open_slots);
        const total = try std.math.add(usize, through_open, snapshot_count);

        var storage_on_heap = false;
        const slab_values = if (rt.vm_stack.carveActiveMarked(total)) |active_carve| blk: {
            entry.arena_mark = active_carve.mark;
            break :blk active_carve.window;
        } else blk: {
            entry.arena_mark = rt.vm_stack.mark();
            break :blk rt.vm_stack.carve(&rt.memory, total) orelse heap: {
                const heap_values = try rt.memory.alloc(core.JSValue, total);
                storage_on_heap = true;
                break :heap heap_values;
            };
        };
        errdefer rt.vm_stack.restore(entry.arena_mark);
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, slab_values);

        const frame_args = slab_values[0..frame_arg_count];
        const locals_start = frame_arg_count;
        const stack_start = locals_start + var_count;
        const open_start = stack_start + stack_count;
        const snapshot_start = open_start + open_slots;
        const locals = slab_values[locals_start..][0..var_count];
        const stack_window = slab_values[stack_start..][0..stack_count];
        const original_args = slab_values[snapshot_start..][0..snapshot_count];
        const open_var_refs: []?*core.VarRef = if (open_slots == 0)
            &.{}
        else
            std.mem.bytesAsSlice(
                ?*core.VarRef,
                std.mem.sliceAsBytes(slab_values[open_start..][0..open_slots]),
            )[0..open_var_ref_count];

        @memset(locals, core.JSValue.undefinedValue());
        if (open_var_refs.len != 0) @memset(open_var_refs, null);

        // FrameCold allocation is the final failable operation. Source owners
        // therefore remain untouched on every setup failure.
        const cold: ?*frame_mod.Frame.FrameCold = if (snapshot_count == 0) null else blk: {
            const box = try rt.memory.create(frame_mod.Frame.FrameCold);
            for (args, 0..) |arg, index| original_args[index] = arg.dup();
            box.* = .{ .original_args = original_args };
            break :blk box;
        };

        if (move_args) {
            @memcpy(frame_args[0..actual_arg_count], moved_args);
            @memset(moved_args, core.JSValue.undefinedValue());
        } else {
            for (args, 0..) |arg, index| frame_args[index] = arg.dup();
        }
        @memset(frame_args[actual_arg_count..], core.JSValue.undefinedValue());

        const captures = target.captureSlice();
        entry.frame = .{
            .function = function,
            .this_value = target.this_value,
            .current_function = target.callable,
            .actual_arg_count = @intCast(actual_arg_count),
            .locals = locals,
            .args = frame_args,
            .var_refs = captures,
            .open_var_refs = open_var_refs,
            .storage_values = if (storage_on_heap) slab_values else &.{},
            .ownership = .{
                .this_value = .borrowed,
                .current_function = .borrowed,
                .var_refs = if (captures.len > 0) .borrowed else .owned,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
            .cold = cold,
        };
        entry.stack = stack_mod.Stack.initArenaWindow(
            &rt.memory,
            rt.vm_stack_arena_policy,
            stack_window,
        );
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
            try self.pushFrame(.moved_method, false, true, global, target, source)
        else
            try self.pushFrame(.generic, false, true, global, target, source);
        entry.return_action = return_action;
        if (return_action == .native_boundary) {
            entry.teardown.special_return = true;
        }
        entry.continuation_payload = switch (return_action) {
            .next => 0,
            .proxy_get => self.ctx.runtime.atoms.dup(@intCast(continuation_payload)),
            .for_of_next => continuation_payload,
            .native_boundary => 0,
            .constructor => unreachable,
        };
        std.debug.assert(return_action != .native_boundary or
            (!entry.isEmptyLeaf() and !entry.isExactArgsLeaf() and !entry.isForwardedLeaf()));
        return entry;
    }

    /// Try to push a simple bytecode iterator `next()` while borrowing the
    /// persistent `[iterator, next]` record from the suspended caller frame.
    /// A non-simple target returns null and retains the established dup/move
    /// path, whose general setup may outlive or mutate its source bindings.
    pub inline fn pushBorrowedIteratorNext(
        self: *Machine,
        global: *core.Object,
        target: *const InlineTarget,
        iterator_record: []core.JSValue,
        depth: u8,
    ) HostError!?*Entry {
        if (!isBorrowedIteratorSimpleInlineFrame(target, iterator_record)) return null;
        // The borrowed setup path ignores ArgsSource; pass the caller record as
        // a diagnostic witness without changing or taking either slot.
        const entry = try self.pushFrame(.borrowed_iterator, false, false, global, target, ArgsSource.initMoved(iterator_record, true));
        entry.return_action = .for_of_next;
        entry.continuation_payload = depth;
        return entry;
    }

    /// Warm-eligibility witness for the borrowed-iterator fast constructor:
    /// the dispatch arm gates on the borrowed-simple eligibility byte the
    /// authoritative selector (`isBorrowedIteratorSimpleInlineFrame`) would
    /// re-derive, plus a slab with no open var-ref tail — the shape whose
    /// authoritative slab (`setupBorrowedIteratorEntry`) is exactly the
    /// contiguous args/locals/operand windows carved below. `arg_count` and
    /// `var_count` may be non-zero (the dominant sloppy `next()` lowers its
    /// materialized `this` into loc0), both filled with undefined in place.
    inline fn assertBorrowedIteratorWarmEligible(function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts) void {
        const execution = call_facts.execution;
        std.debug.assert(execution.simple_inline_eligible or
            execution.strict_simple_inline_eligible or
            execution.strict_simple_snapshot_inline_eligible);
        std.debug.assert(frame_mod.frameOpenVarRefStorageCount(function) == 0);
    }

    /// Integer-pair JSValue read — the `loadValueAsIntPair` discipline from
    /// the return chain, applied at frame construction: left to itself LLVM
    /// copies the 16-byte record bindings through a q register, and the
    /// callee's very next opcodes read the freshly-built frame with integer
    /// loads (`push_this` reads the `this` tag word within a handful of
    /// dispatches), so the SIMD store fails store-to-load forwarding across
    /// the vector/integer domain. Two u64 loads keep the copy on integer
    /// registers and the stores x-pair-shaped.
    inline fn readValueAsIntPair(slot: *const core.JSValue) core.JSValue {
        if (comptime @sizeOf(core.JSValue) != 2 * @sizeOf(u64)) {
            return slot.*;
        }
        const words: *const [2]u64 = @ptrCast(@alignCast(slot));
        const lo = words[0];
        const hi = words[1];
        return @bitCast([2]u64{ lo, hi });
    }

    /// Warm, allocation-free borrowed-iterator `next()` construction (M2
    /// knife 3) — the borrowed_iterator family's twin of
    /// `tryPushCaptureLeafCallFast`, kept as an INDEPENDENT instance with its
    /// own publication tail (hot arms are never shared, including at the
    /// template layer; see `pushExactArgsLeafFrame` for the tail-merge
    /// re-scheduling hazard). The dispatch arm proved the borrowed-simple
    /// eligibility byte plus an open-var-ref-free slab, so ONE active-chunk
    /// carve covers the contiguous args/locals/operand windows and the
    /// undefined fill happens in place — the same frame
    /// `setupBorrowedIteratorEntry` builds, minus its noinline bl, the
    /// generic depth-accounting shell, the acquireSlot round-trip, and the
    /// mark/carve split. qjs anchor: JS_CallInternal's whole frame for
    /// this shape is one alloca plus seven sf stores (quickjs.c:17841-17871).
    /// A null result is the established pure miss contract: call depth,
    /// arena watermark, the untouched caller iterator record, and Machine
    /// links are unchanged, so the caller can invoke
    /// `pushBorrowedIteratorNext` for first-use Entry allocation, chunk
    /// switching, heap fallback, OOM, or stack-overflow handling.
    pub inline fn tryPushBorrowedIteratorNextFast(
        self: *Machine,
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        captures: []*core.VarRef,
        iterator_record: []core.JSValue,
        depth: u8,
    ) ?*Entry {
        assertBorrowedIteratorWarmEligible(function, call_facts);
        std.debug.assert(iterator_record.len == 2);
        const ctx = self.ctx;
        // K1 single pricing: one geometry derivation feeds admission, commit,
        // and the persisted Entry charge — the exact figure the generic path
        // prices for its argc==0 borrowed source, so the teardown release
        // stays in lockstep.
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(function, 0, false);
        if (!vm_call.canEnterInlineCallDepthBytes(ctx, planned_stack_bytes)) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) return null;
        const entry = self.entryAt(index);

        const rt = ctx.runtime;
        const frame_arg_count: usize = @intCast(function.arg_count);
        const var_count: usize = function.var_count;
        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(frame_arg_count + var_count + stack_count) orelse return null;

        vm_call.commitInlineCallDepthBytes(ctx, planned_stack_bytes);
        entry.return_action = .for_of_next;
        entry.continuation_payload = depth;
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        entry.arena_mark = carve.mark;
        return self.finishBorrowedIteratorFrame(entry, function, captures, iterator_record, carve.window, frame_arg_count, var_count);
    }

    /// Infallible publication tail for the warm borrowed-iterator frame —
    /// SEPARATE body from every established finish tail (hot arms are never
    /// shared). Field-for-field the frame `setupBorrowedIteratorEntry`
    /// publishes for the zero-storage geometry: both call bindings borrow
    /// the caller's iterator record (qjs JS_CallInternal reads
    /// `func_obj`/`this_obj` without retaining either, quickjs.c:17815-17849;
    /// the record slots stay untouched on the suspended caller stack and
    /// root both values until the continuation returns), `var_refs` aliases
    /// the closure's cell array (qjs `var_refs = p->u.func.var_refs`,
    /// quickjs.c:17844), and the `.for_of_next` continuation was published
    /// by the warm constructor above before this tail linked the Entry.
    /// `teardown = {simple}` (no leaf bit): returns MUST route through the
    /// general continuation-carrying pop so `popAndResume` hands the result
    /// to the `.for_of_next` trampoline arm, and no teardown ever releases
    /// the borrowed bindings.
    inline fn finishBorrowedIteratorFrame(
        self: *Machine,
        entry: *Entry,
        function: *const bytecode.FunctionBytecode,
        captures: []*core.VarRef,
        iterator_record: []core.JSValue,
        slab: []core.JSValue,
        frame_arg_count: usize,
        var_count: usize,
    ) *Entry {
        const rt = self.ctx.runtime;
        const args = slab[0..frame_arg_count];
        const locals = slab[frame_arg_count..][0..var_count];
        const stack_window = slab[frame_arg_count + var_count ..];
        // One contiguous undefined fill for the adjacent args+locals prefix
        // (qjs 17855-17865; zero for the capture-only `next()` shape, one
        // slot for the dominant sloppy this-in-loc0 lowering).
        @memset(slab[0 .. frame_arg_count + var_count], core.JSValue.undefinedValue());
        // No failable operation follows; both bindings stay caller-owned.
        // Field stores instead of a whole-struct literal so the one frame
        // field the callee's per-op hot path reloads at its head —
        // `frame.var_refs`, read by every get/put_var_ref dispatch — can be
        // ELIDED when the Entry slot still holds the same slice from the
        // previous iteration (the steady for-of state): re-storing it every
        // push put the callee's first var-ref bound/pointer loads on a
        // just-stored slot, and the measured stall on that head chain cost
        // more cycles than the whole warm-entry instruction win. The elision
        // is value-based (bitwise compare against defined slot contents —
        // chunk allocation pre-defines the field), so it holds regardless of
        // which frame shape last occupied the slot.
        const frame = &entry.frame;
        frame.function = function;
        frame.pc = 0;
        frame.this_value = readValueAsIntPair(&iterator_record[0]);
        frame.current_function = readValueAsIntPair(&iterator_record[1]);
        frame.actual_arg_count = 0;
        frame.planned_stack_bytes = @intCast(vm_call.qjsBytecodeFrameAllocaSize(function, 0, false));
        frame.locals = locals;
        frame.args = args;
        if (frame.var_refs.ptr != captures.ptr or frame.var_refs.len != captures.len) {
            frame.var_refs = captures;
        }
        frame.open_var_refs = &.{};
        frame.storage_values = &.{};
        frame.ownership = .{
            .this_value = .borrowed,
            .current_function = .borrowed,
            .var_refs = if (captures.len > 0) .borrowed else .owned,
            .storage = .borrowed,
        };
        frame.cold = null;
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.vm_stack_arena_policy, stack_window);
        entry.teardown = .{ .simple = true };
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
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
        function: *const bytecode.FunctionBytecode,
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
            // Forwarded leaves commit with copy_argv pricing, but the body is
            // zero-arg, so the figure equals the leaf form either way.
            .planned_stack_bytes = @intCast(vm_call.qjsBytecodeLeafFrameAllocaSize(function)),
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
            .special_return = true,
            .copy_argv = true,
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
        function: *const bytecode.FunctionBytecode,
        call_facts: bytecode.CallFacts,
        region_start: [*]core.JSValue,
    ) ?*Entry {
        std.debug.assert(caller_stack.topPtr() == region_start);
        assertLeafEligible(leaf_this, function, call_facts);
        const ctx = self.ctx;
        // K1 single pricing: one geometry derivation feeds admission, commit,
        // and the persisted Entry charge (M1 dossier: the triple recompute was
        // the top opCall residual).
        const planned_stack_bytes = vm_call.qjsBytecodeLeafFrameAllocaSize(function);
        // K2 admission-commit fusion (see `tryPushEmptyLeafCallFast`): the
        // rare chunk/carve misses retreat the committed charge cold.
        const rt = ctx.runtime;
        if (!vm_call.tryCommitInlineCallDepthBytesRt(rt, planned_stack_bytes)) return null;

        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= self.chunk_count) {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        }
        const entry = self.entryAt(index);

        const stack_count = @as(usize, function.stack_size) + 1;
        const carve = rt.vm_stack.carveActiveMarked(stack_count) orelse {
            vm_call.retreatInlineCallDepthBytesMiss(rt, planned_stack_bytes);
            return null;
        };

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
        const entry = try self.pushFrame(.generic, false, true, global, target, ArgsSource.initStack(caller_stack.topPtr(), argc, layout == .method));
        entry.native_caller = native_caller;
        entry.teardown.has_native_caller = true;
        return entry;
    }

    /// Tail-call execution: transactionally replace the top inline frame with
    /// a fresh frame for `target` while retaining the retired caller's logical
    /// stack unit. QuickJS performs a nested JS_CallInternal for OP_tail_call
    /// and only releases the caller after the callee returns. Build the target
    /// in the next reusable Entry while the caller remains current, then move
    /// the fully-prepared target into the caller's slot with no fallible work
    /// left. Thus every target setup error is caught at the original call site
    /// while successful chains still occupy one physical live Entry.
    /// The operand
    /// region starting at `region_base` lives on the dying frame's own
    /// operand stack, so it is moved into a scratch buffer before the frame
    /// (and the arena window backing its stack) is torn down. The region is
    /// `[callable, args...]`, or `[receiver, callable, args...]` when
    /// `has_receiver` (a tail-positioned method call, where the receiver
    /// becomes the reused frame's `this`).
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
        // Check before moving operands or retiring the caller so overflow is
        // delivered at the intact tail-call site, like QuickJS's callee-entry
        // stack guard.
        const planned_stack_bytes = vm_call.qjsBytecodeFrameAllocaSize(target.fb, argc, false);
        try vm_call.checkTailCallChainStackBudget(self.ctx, global, planned_stack_bytes);
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

        // Keep inherited logical units occupied while replacing the physical
        // Entry. The prepared target temporarily occupies the next slot, but
        // pushFrame does not link it until every fallible setup step succeeds.
        const dying = self.topEntry();
        const dying_prev = dying.prev;
        const dying_arena_mark = dying.arena_mark;
        // Committed charge persisted at construction; the recompute is the
        // Debug lockstep guard against any constructor missing the store.
        const dying_stack_bytes: usize = dying.frame.planned_stack_bytes;
        std.debug.assert(dying_stack_bytes == vm_call.qjsBytecodeFrameAllocaSize(
            dying.frame.function,
            dying.frame.actual_arg_count,
            dying.teardown.copy_argv,
        ));
        const inherited_budget: Entry.TailChainBudget = if (dying.teardown.tail_chain)
            dying.tailChainBudgetSlot().*
        else
            .{ .extra_depth = 0, .planned_stack_bytes = 0 };

        const entry = try self.pushFrame(
            .generic,
            true,
            false,
            global,
            target,
            ArgsSource.initMoved(moved, has_receiver),
        );
        // From here through publication there are no fallible operations.
        // Fold the caller's continuation, logical budget, arena watermark and
        // profiling restore level into the target before retiring its values.
        var continuation = dying.takeContinuation();
        entry.adoptContinuation(&continuation);
        // Generic setup leaves the dead native-caller slot unspecified. The
        // default representation overwrites it with TailChainBudget below;
        // NaN boxing stores that budget in stride padding, so initialize the
        // remaining field before moving the whole Entry into the reused slot.
        entry.native_caller = core.JSValue.undefinedValue();
        entry.teardown.tail_chain = true;
        entry.tailChainBudgetSlot().* = .{
            .extra_depth = inherited_budget.extra_depth + 1,
            .planned_stack_bytes = inherited_budget.planned_stack_bytes + dying_stack_bytes,
        };
        entry.arena_mark = dying_arena_mark;
        entry.profile_guard.adoptRetiredCaller(dying.profile_guard);

        dying.deinitForTailReplacement(self.ctx);
        entry.prev = dying_prev;
        dying.* = entry.*;
        self.top = dying;
        self.depth -= 1;
        return dying;
    }

    /// Retire the top inline frame through the single qjs-style `done:`
    /// epilogue. The returned continuation owns its atom until it is consumed,
    /// transferred to a tail-call replacement, or explicitly deinitialized.
    inline fn popFrameMode(self: *Machine, comptime returned: bool) ReturnContinuation {
        const dying = self.topEntry();
        // A frame that carries retired tail callers releases their accumulated
        // budget too, which means reading an overlay before teardown and a
        // second pass over the runtime's depth and byte counters. An ordinary
        // frame's budget is statically {0, 0}, so it used to build that struct,
        // hold it live across teardown, and subtract zero from two hot runtime
        // fields on every single return. The whole shape now lives in the
        // outlined twin below and this path never mentions it again; the bit
        // tested here is in the same `teardown` byte deinitReturned already
        // loads for its own flags.
        if (dying.teardown.tail_chain) return self.popTailChainFrameMode(returned);
        // Committed charge persisted at construction; the recompute is the
        // Debug lockstep guard against any constructor missing the store.
        const dying_stack_bytes: usize = dying.frame.planned_stack_bytes;
        std.debug.assert(dying_stack_bytes == vm_call.qjsBytecodeFrameAllocaSize(
            dying.frame.function,
            dying.frame.actual_arg_count,
            dying.teardown.copy_argv,
        ));
        const continuation = dying.takeContinuation();
        if (returned)
            dying.deinitReturned(self.ctx)
        else
            dying.deinit(self.ctx);
        vm_call.leaveInlineCallDepthBytes(self.ctx, dying_stack_bytes);
        self.depth -= 1;
        // Unlink — qjs `rt->current_stack_frame = sf->prev_frame;` at the
        // done: epilogue (quickjs.c:20709).
        self.top = dying.prev;
        return continuation;
    }

    /// `popFrameMode` for a frame that inherited the logical depth and planned
    /// bytecode-stack cost of tail callers whose Entry storage was reused. Same
    /// sequence as the ordinary twin plus the inherited-budget release, kept out
    /// of line so an ordinary return neither materializes the overlay nor pays
    /// the second counter pass. `returned` is runtime here rather than comptime:
    /// this path is entered once per tail chain, not once per call.
    noinline fn popTailChainFrameMode(self: *Machine, returned: bool) ReturnContinuation {
        const dying = self.topEntry();
        std.debug.assert(dying.teardown.tail_chain);
        // Read the overlay before teardown. The final replacement releases
        // its own unit and every retired tail caller it represents.
        const chain_budget: Entry.TailChainBudget = dying.tailChainBudgetSlot().*;
        const dying_stack_bytes: usize = dying.frame.planned_stack_bytes;
        std.debug.assert(dying_stack_bytes == vm_call.qjsBytecodeFrameAllocaSize(
            dying.frame.function,
            dying.frame.actual_arg_count,
            dying.teardown.copy_argv,
        ));
        const continuation = dying.takeContinuation();
        if (returned)
            dying.deinitReturned(self.ctx)
        else
            dying.deinit(self.ctx);
        vm_call.leaveInlineCallDepthBytes(self.ctx, dying_stack_bytes);
        std.debug.assert(self.ctx.runtime.hot.call_depth >= chain_budget.extra_depth);
        std.debug.assert(self.ctx.runtime.hot.active_bytecode_stack_bytes >= chain_budget.planned_stack_bytes);
        self.ctx.runtime.hot.call_depth -= chain_budget.extra_depth;
        self.ctx.runtime.hot.active_bytecode_stack_bytes -= chain_budget.planned_stack_bytes;
        self.depth -= 1;
        self.top = dying.prev;
        return continuation;
    }

    /// `popFrameMode` for a frame `isOrdinaryReturn` already cleared. No
    /// tail-chain budget to release, no continuation to move out, no special
    /// completion to discriminate -- so none of that is re-asked. Returns
    /// nothing because a plain completion carries no payload for the caller.
    pub inline fn popOrdinaryFrame(self: *Machine) void {
        const dying = self.topEntry();
        std.debug.assert(dying.isOrdinaryReturn());
        // The classification never reads the payload, so this is the one check
        // on this path that is not circular: it catches a producer that
        // installed a continuation payload without the tag that goes with it,
        // which is exactly the frame this path would drop on the floor.
        std.debug.assert(dying.continuation_payload == 0);
        // Committed charge persisted at construction; the recompute is the
        // Debug lockstep guard against any constructor missing the store.
        const dying_stack_bytes: usize = dying.frame.planned_stack_bytes;
        std.debug.assert(dying_stack_bytes == vm_call.qjsBytecodeFrameAllocaSize(
            dying.frame.function,
            dying.frame.actual_arg_count,
            dying.teardown.copy_argv,
        ));
        dying.deinitOrdinaryReturned(self.ctx);
        vm_call.leaveInlineCallDepthBytes(self.ctx, dying_stack_bytes);
        self.depth -= 1;
        // Unlink — qjs `rt->current_stack_frame = sf->prev_frame;` at the
        // done: epilogue (quickjs.c:20709).
        self.top = dying.prev;
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

    /// Retire a synchronous callback at its native fence without routing the
    /// already-known continuation through the ordinary `.next` selector.
    /// This is deliberately not an empty/exact leaf epilogue: every simple
    /// frame still releases its complete locals/args/open-ref resource set,
    /// while non-simple and tail-replacement frames retain the authoritative
    /// returned-frame cleanup. Only the cold `.native_boundary` continuation
    /// selects this adapter, so ordinary return layout is unchanged.
    pub inline fn popReturnedNativeBoundary(self: *Machine, rt: *core.JSRuntime) void {
        const dying = self.topEntry();
        std.debug.assert(rt == self.ctx.runtime);
        std.debug.assert(dying.isNativeBoundaryReturn());
        std.debug.assert(dying.continuation_payload == 0);

        const chain_budget: Entry.TailChainBudget = if (dying.teardown.tail_chain)
            dying.tailChainBudgetSlot().*
        else
            .{ .extra_depth = 0, .planned_stack_bytes = 0 };
        const dying_stack_bytes: usize = dying.frame.planned_stack_bytes;
        std.debug.assert(dying_stack_bytes == vm_call.qjsBytecodeFrameAllocaSize(
            dying.frame.function,
            dying.frame.actual_arg_count,
            dying.teardown.copy_argv,
        ));

        if (dying.canUseSimpleTeardown())
            dying.deinitSimple(self.ctx)
        else
            dying.deinitReturned(self.ctx);
        vm_call.leaveInlineCallDepthBytesRt(rt, dying_stack_bytes);
        std.debug.assert(rt.hot.call_depth >= chain_budget.extra_depth);
        std.debug.assert(rt.hot.active_bytecode_stack_bytes >= chain_budget.planned_stack_bytes);
        rt.hot.call_depth -= chain_budget.extra_depth;
        rt.hot.active_bytecode_stack_bytes -= chain_budget.planned_stack_bytes;
        self.depth -= 1;
        self.top = dying.prev;
    }

    /// Retire the proven ordinary empty-leaf return without materializing its
    /// statically fixed `.next/0` continuation. This is intentionally separate
    /// from popFrame: abrupt completion must still inspect and release the
    /// callee's live operand window through general teardown.
    pub inline fn popReturnedEmptyLeaf(self: *Machine, rt: *core.JSRuntime) void {
        const dying = self.topEntry();
        // Vm-resident rt (see tailcall_dispatch.Vm.rt): the return handler
        // hands the runtime in, replacing the machine→ctx→runtime chain.
        std.debug.assert(rt == self.ctx.runtime);
        std.debug.assert(dying.isEmptyLeaf());
        std.debug.assert(!dying.teardown.tail_chain);
        std.debug.assert(dying.return_action == .next);
        std.debug.assert(dying.continuation_payload == 0);
        // Published empty-leaf geometry is zero-arg (bytecode.zig
        // empty_leaf_geometry) and never copy_argv-priced, so the padded-argv
        // prefix is statically empty.
        std.debug.assert(!dying.teardown.copy_argv);
        std.debug.assert(dying.frame.function.arg_count == 0);
        const dying_stack_bytes: usize = dying.frame.planned_stack_bytes;
        std.debug.assert(dying_stack_bytes == vm_call.qjsBytecodeLeafFrameAllocaSize(dying.frame.function));
        // Inline epilogue: the hot leg is an rc decrement plus the arena
        // watermark restore; keeping it in the return handler removes the
        // only bl/ret on the empty-leaf return path (destroyZeroRef stays
        // outline behind the rc==0 branch).
        dying.deinitEmptyLeafInline(rt);
        vm_call.leaveInlineCallDepthBytesRt(rt, dying_stack_bytes);
        self.depth -= 1;
        self.top = dying.prev;
    }

    /// Exact-args twin of `popReturnedEmptyLeaf`. Its inline epilogue adds
    /// only the caller-region args release loop; abrupt completion still
    /// inspects and releases the callee through general teardown.
    pub inline fn popReturnedExactArgsLeaf(self: *Machine, rt: *core.JSRuntime) void {
        const dying = self.topEntry();
        // Vm-resident rt (see popReturnedEmptyLeaf).
        std.debug.assert(rt == self.ctx.runtime);
        std.debug.assert(dying.isExactArgsLeaf());
        std.debug.assert(!dying.teardown.tail_chain);
        std.debug.assert(dying.return_action == .next);
        std.debug.assert(dying.continuation_payload == 0);
        // This bit also covers the capture (argc==0) family, so the release
        // stays argc-aware; only the copy_argv pricing select is statically
        // false here (neither the exact nor the capture finisher sets it).
        std.debug.assert(!dying.teardown.copy_argv);
        const dying_stack_bytes: usize = dying.frame.planned_stack_bytes;
        std.debug.assert(dying_stack_bytes == vm_call.qjsBytecodeFrameAllocaSize(
            dying.frame.function,
            dying.frame.actual_arg_count,
            false,
        ));
        dying.deinitExactArgsLeafInline(rt);
        vm_call.leaveInlineCallDepthBytesRt(rt, dying_stack_bytes);
        self.depth -= 1;
        self.top = dying.prev;
    }

    /// Forwarded-leaf twin of `popReturnedEmptyLeaf` (O3). Its inline
    /// epilogue adds only the owned native `call` frame release; abrupt
    /// completion still inspects and releases the callee through general
    /// teardown (whose cold `releaseNativeCaller` arm handles the same
    /// ownership).
    pub inline fn popReturnedForwardedLeaf(self: *Machine, rt: *core.JSRuntime) void {
        const dying = self.topEntry();
        // Vm-resident rt (see popReturnedEmptyLeaf).
        std.debug.assert(rt == self.ctx.runtime);
        std.debug.assert(dying.isForwardedLeaf());
        std.debug.assert(!dying.teardown.tail_chain);
        std.debug.assert(dying.return_action == .next);
        std.debug.assert(dying.continuation_payload == 0);
        // Forwarded leaves commit with copy_argv pricing, but the published
        // body is zero-arg, so the padded-argv prefix is empty either way and
        // the leaf figure releases the exact bytes charged.
        std.debug.assert(dying.frame.function.arg_count == 0);
        const dying_stack_bytes: usize = dying.frame.planned_stack_bytes;
        std.debug.assert(dying_stack_bytes == vm_call.qjsBytecodeLeafFrameAllocaSize(dying.frame.function));
        dying.deinitForwardedLeafInline(rt);
        vm_call.leaveInlineCallDepthBytesRt(rt, dying_stack_bytes);
        self.depth -= 1;
        self.top = dying.prev;
    }

    /// Pop the top inline frame after a completed return. Ordinary calls push
    /// `result` onto the caller stack; continuations retain it in the driver's
    /// return slot until their post-call action runs. Takes ownership of
    /// `result` either way and returns the selected action.
    pub fn popReturn(self: *Machine, result: core.JSValue) ReturnContinuation {
        if (self.topEntry().isNativeBoundaryReturn()) {
            self.popReturnedNativeBoundary(self.ctx.runtime);
            return .{ .action = .native_boundary, .payload = 0 };
        }
        if (self.topEntry().completesConstructor()) {
            const completed = self.popConstructorReturn(result);
            self.currentLevel().stack.pushOwnedAssumeCapacity(completed);
            return .{ .action = .next, .payload = 0 };
        }
        const continuation = self.popReturnedFrame();
        if (continuation.action == .next) {
            std.debug.assert(continuation.payload == 0);
            self.currentLevel().stack.pushOwnedAssumeCapacity(result);
        }
        return continuation;
    }

    /// Apply constructor return completion. A base Entry still owns its
    /// fallback instance: an object result replaces it, while every primitive
    /// is discarded in favor of the instance. A derived Entry has no fallback;
    /// its compiler/control helper has already enforced derived-return
    /// legality and produced the final object.
    pub fn popConstructorReturn(self: *Machine, result: core.JSValue) core.JSValue {
        const dying = self.topEntry();
        const fallback = dying.takeConstructorFallback();
        const is_derived = fallback.isUndefined();
        const continuation = self.popReturnedFrame();
        std.debug.assert(continuation.action == .constructor);
        std.debug.assert(continuation.payload == 0);
        if (is_derived) return result;
        if (result.isObject()) {
            fallback.free(self.ctx.runtime);
            return result;
        }
        result.free(self.ctx.runtime);
        return fallback;
    }

    /// Abruptly retire every Entry above `depth` without attempting another
    /// observable catch/IteratorClose operation. This is the recovery tail for
    /// an error raised while the bounded unwind itself is already cleaning up.
    pub fn discardToDepth(self: *Machine, depth: usize) void {
        std.debug.assert(depth <= self.depth);
        while (self.depth > depth) {
            var continuation = self.popFrame();
            continuation.deinit(self.ctx.runtime);
        }
    }

    /// Native-fence variant of `unwindForError`: catches remain visible inside
    /// the callback segment, but an uncaught callback error stops exactly at
    /// `fence_depth`. The suspended outer bytecode frame cannot catch until
    /// the native builtin has regained control and run its cleanup.
    pub fn unwindForErrorToDepth(
        self: *Machine,
        global: *core.Object,
        fence_depth: usize,
        err: anyerror,
    ) HostError!bool {
        std.debug.assert(fence_depth <= self.depth);
        errdefer self.discardToDepth(fence_depth);
        const ctx = self.ctx;
        while (self.depth > fence_depth) {
            var continuation = self.popFrame();
            const iterator_next_depth: ?u8 = if (continuation.action == .for_of_next)
                continuation.takeForOfDepth()
            else
                null;
            continuation.deinit(ctx.runtime);

            // The outer level belongs to the still-running native builtin.
            // Do not close its iterators or consult its catch markers yet.
            if (self.depth == fence_depth) return false;

            const level = self.currentLevel();
            if (iterator_next_depth) |depth| {
                try forof_ops.abandonForOfIteratorAtDepth(ctx.runtime, level.stack, depth);
            }
            try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, self.output, global, level.stack);
            if (try call_runtime.tryCatchInFrame(ctx, self.output, level.stack, level.frame, level.catch_target, global, err)) return true;
        }
        return false;
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
            var continuation = self.popFrame();
            const iterator_next_depth: ?u8 = if (continuation.action == .for_of_next)
                continuation.takeForOfDepth()
            else
                null;
            continuation.deinit(ctx.runtime);

            const level = self.currentLevel();
            // The continuation survives proper-tail-call replacement, so an
            // abrupt bytecode `next()` can retire exactly its own record before
            // ordinary unwind closes any enclosing iterators.
            if (iterator_next_depth) |depth| {
                try forof_ops.abandonForOfIteratorAtDepth(ctx.runtime, level.stack, depth);
            }
            try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, self.output, global, level.stack);
            if (try call_runtime.tryCatchInFrame(ctx, self.output, level.stack, level.frame, level.catch_target, global, err)) return true;
            if (self.depth == 0) return false;
        }
        return false;
    }
};
