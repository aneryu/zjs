const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const atom = @import("../core/atom.zig");
const Atom = atom.Atom;
const core = @import("../core/root.zig");
const memory = @import("../core/memory.zig");
const Object = @import("../core/object.zig").Object;
const runtime = @import("../core/runtime.zig");
const JSRuntime = runtime.JSRuntime;
const JSValue = @import("../core/value.zig").JSValue;
const stack_mod = @import("stack.zig");

pub const no_global_lexical_sync_index: usize = std.math.maxInt(usize);

pub const EvalVarRefSnapshot = struct {
    names: []Atom = &.{},
    refs: runtime.ValueRootBuffer = .{},

    pub fn init(rt: *JSRuntime, names: []const Atom, refs: []const JSValue) !EvalVarRefSnapshot {
        var snapshot = EvalVarRefSnapshot{};
        errdefer snapshot.deinit(rt);

        snapshot.names = try dupAtomSlice(rt, names);
        snapshot.refs = try runtime.ValueRootBuffer.initCopy(rt, refs);
        return snapshot;
    }

    pub fn install(self: *EvalVarRefSnapshot, cold: *Frame.FrameCold) void {
        cold.eval_var_ref_names = self.names;
        cold.eval_var_refs = self.refs.values;
    }

    pub fn deinit(self: *EvalVarRefSnapshot, rt: *JSRuntime) void {
        const names = self.names;
        self.names = &.{};
        self.refs.deinit(rt);
        freeAtomSlice(rt, names);
    }
};

pub const FrameSlab = struct {
    storage: []JSValue = &.{},
    args: []JSValue = &.{},
    original_args: []JSValue = &.{},
    locals: []JSValue = &.{},
    stack: []JSValue = &.{},
    var_refs: []JSValue = &.{},
    open_var_refs: []?*core.VarRef = &.{},

    pub fn carve(
        account: *memory.MemoryAccount,
        arena: *runtime.VmStackArena,
        arg_count: usize,
        original_arg_count: usize,
        local_count: usize,
        stack_count: usize,
        var_ref_count: usize,
        open_var_ref_count: usize,
    ) ?FrameSlab {
        const count_1 = std.math.add(usize, arg_count, original_arg_count) catch return null;
        const count_2 = std.math.add(usize, count_1, local_count) catch return null;
        const count_3 = std.math.add(usize, count_2, stack_count) catch return null;
        const value_count = std.math.add(usize, count_3, var_ref_count) catch return null;
        const open_bytes = std.math.mul(usize, @sizeOf(?*core.VarRef), open_var_ref_count) catch return null;
        const open_value_slots = std.math.divCeil(usize, open_bytes, @sizeOf(JSValue)) catch return null;
        const slab_values = arena.carve(account, value_count + open_value_slots) orelse return null;

        var cursor: usize = 0;
        const args = slab_values[cursor .. cursor + arg_count];
        cursor += arg_count;
        const original_args = slab_values[cursor .. cursor + original_arg_count];
        cursor += original_arg_count;
        const locals = slab_values[cursor .. cursor + local_count];
        cursor += local_count;
        const stack = slab_values[cursor .. cursor + stack_count];
        cursor += stack_count;
        const var_refs = slab_values[cursor .. cursor + var_ref_count];
        cursor += var_ref_count;

        const open_var_refs: []?*core.VarRef = if (open_var_ref_count == 0)
            &.{}
        else blk: {
            const bytes = std.mem.sliceAsBytes(slab_values[cursor .. cursor + open_value_slots]);
            break :blk std.mem.bytesAsSlice(?*core.VarRef, bytes[0..open_bytes]);
        };
        if (open_var_refs.len != 0) @memset(open_var_refs, null);

        return .{
            .storage = slab_values,
            .args = args,
            .original_args = original_args,
            .locals = locals,
            .stack = stack,
            .var_refs = var_refs,
            .open_var_refs = open_var_refs,
        };
    }

    pub fn allocHeap(
        account: *memory.MemoryAccount,
        arg_count: usize,
        original_arg_count: usize,
        local_count: usize,
        stack_count: usize,
        var_ref_count: usize,
        open_var_ref_count: usize,
    ) !FrameSlab {
        const count_1 = try std.math.add(usize, arg_count, original_arg_count);
        const count_2 = try std.math.add(usize, count_1, local_count);
        const count_3 = try std.math.add(usize, count_2, stack_count);
        const value_count = try std.math.add(usize, count_3, var_ref_count);
        const open_bytes = try std.math.mul(usize, @sizeOf(?*core.VarRef), open_var_ref_count);
        const open_value_slots = try std.math.divCeil(usize, open_bytes, @sizeOf(JSValue));
        const total_value_slots = value_count + open_value_slots;
        if (total_value_slots == 0) return .{};
        const storage = try account.alloc(JSValue, total_value_slots);
        errdefer account.free(JSValue, storage);

        var cursor: usize = 0;
        const args = storage[cursor .. cursor + arg_count];
        cursor += arg_count;
        const original_args = storage[cursor .. cursor + original_arg_count];
        cursor += original_arg_count;
        const locals = storage[cursor .. cursor + local_count];
        cursor += local_count;
        const stack = storage[cursor .. cursor + stack_count];
        cursor += stack_count;
        const var_refs = storage[cursor .. cursor + var_ref_count];
        cursor += var_ref_count;
        const open_var_refs: []?*core.VarRef = if (open_var_ref_count == 0)
            &.{}
        else blk: {
            const bytes = std.mem.sliceAsBytes(storage[cursor .. cursor + open_value_slots]);
            break :blk std.mem.bytesAsSlice(?*core.VarRef, bytes[0..open_bytes]);
        };
        if (open_var_refs.len != 0) @memset(open_var_refs, null);

        return .{
            .storage = storage,
            .args = args,
            .original_args = original_args,
            .locals = locals,
            .stack = stack,
            .var_refs = var_refs,
            .open_var_refs = open_var_refs,
        };
    }
};

pub const CallBindingInputs = struct {
    initial_this_value: JSValue,
    current_function_value: JSValue,
    new_target_value: JSValue,
    constructor_this_value: JSValue,
    eval_local_names: []const Atom,
    eval_local_slots: []JSValue,
    input_eval_var_ref_names: []const Atom,
    input_eval_var_refs: []const JSValue,
    inherited_eval_local_names: []const Atom,
    inherited_eval_local_slots: []JSValue,
    inherited_eval_var_ref_names: []const Atom,
    inherited_eval_var_refs: []const JSValue,
};

pub const CallBindingValueMode = enum {
    /// Retain a new frame-owned reference to the value.
    dup,
    /// Transfer an already-owned value into the frame.
    take,
    /// Keep a borrowed value rooted by the frame but do not release it.
    borrow,
};

pub const CallBindingModes = struct {
    this_value: CallBindingValueMode = .dup,
    constructor_this_value: CallBindingValueMode = .dup,
    current_function: CallBindingValueMode = .dup,
    new_target: CallBindingValueMode = .dup,
};

/// `original_args` (a pre-mutation snapshot of the call arguments) is only
/// observable through the unmapped arguments object and implicit derived
/// constructor calls. Sloppy simple-parameter functions always use the
/// mapped arguments object, which reads live `frame.args`, so the snapshot
/// duplication can be skipped for them.
pub fn argumentsNeedsOriginalSnapshot(function: *const bytecode.Bytecode) bool {
    return function.flags.is_derived_class_constructor or
        function.flags.is_strict or
        function.flags.runtime_strict or
        !function.flags.has_simple_parameter_list;
}

pub fn frameArgCount(function: *const bytecode.Bytecode, argc: usize) usize {
    return @max(argc, @as(usize, @intCast(function.arg_count)));
}

pub fn originalArgCount(argc: usize, need_original_snapshot: bool) usize {
    return if (argc != 0 and need_original_snapshot) argc else 0;
}

pub fn frameVarRefStorageCount(function: *const bytecode.Bytecode, inherited_var_refs: []const JSValue) usize {
    if (inherited_var_refs.len != 0) return inherited_var_refs.len;
    if (function.closure_var.len != 0) return function.closure_var.len;
    return function.var_ref_names.len;
}

pub fn frameOpenVarRefStorageCount(function: *const bytecode.Bytecode, frame_arg_count: usize) usize {
    const slot_count = @as(usize, function.var_count) + frame_arg_count;
    if (slot_count == 0) return 0;
    if (function.flags.is_generator or function.flags.is_async) return 0;
    if (function.constants.values.len != 0) return slot_count;
    if (function.flags.has_eval_call) return slot_count;
    return 0;
}

pub const FrameStorageWindows = struct {
    args: ?[]JSValue = null,
    original_args: ?[]JSValue = null,
    locals: ?[]JSValue = null,
    var_refs: ?[]JSValue = null,
    open_var_refs: ?[]?*core.VarRef = null,
};

pub const Frame = struct {
    function: *const bytecode.Bytecode,
    pc: usize = 0,
    this_value: JSValue = JSValue.undefinedValue(),
    current_function: JSValue = JSValue.undefinedValue(),
    new_target: JSValue = JSValue.undefinedValue(),
    actual_arg_count: usize = 0,
    locals: []JSValue = &.{},
    args: []JSValue = &.{},
    var_refs: []JSValue = &.{},
    /// True when `var_refs` aliases the callee's closure captures array
    /// (`functionCapturesSlot`) instead of an owned per-frame copy — qjs's
    /// `var_refs = p->u.func.var_refs` borrow (quickjs.c:17844). Set only for a
    /// no-eval, no-global-var inline call whose captures are all VarRef cells, so
    /// every var_ref write goes through a cell (never the array element) and the
    /// shared array is never mutated/realloced. Teardown then skips the per-element
    /// free (the closure still owns the cells).
    var_refs_borrowed: bool = false,
    open_var_refs: []?*core.VarRef = &.{},
    storage_values: []JSValue = &.{},
    storage_on_heap: bool = false,
    /// Lazily-allocated side-struct holding the cold per-frame state a plain
    /// inline call (fib, ordinary closures) never touches: direct-eval bindings,
    /// global-lexical-sync, the derived-constructor `this`, and the `arguments`
    /// object / original-args snapshot. `null` on the common path, so `Frame.init`
    /// writes one null pointer instead of ~13 default fields and the hot Frame is
    /// ~190B narrower — qjs keeps these off its 72B JSStackFrame (quickjs.c:407).
    cold: ?*FrameCold = null,
    this_value_owned: bool = true,

    pub const FrameCold = struct {
        eval_local_names: []const Atom = &.{},
        eval_local_slots: []JSValue = &.{},
        eval_var_ref_names: []const Atom = &.{},
        eval_var_refs: []JSValue = &.{},
        eval_var_refs_republished: bool = false,
        global_lexical_sync_env: ?*Object = null,
        global_lexical_sync_slots: []bool = &.{},
        global_lexical_sync_indices: []usize = &.{},
        global_lexical_sync_checked: bool = false,
        constructor_this_value: JSValue = JSValue.undefinedValue(),
        constructor_this_value_owned: bool = false,
        arguments_object: ?JSValue = null,
        original_args: []JSValue = &.{},
    };

    /// Allocate `cold` on first use (a frame that takes the eval / sync / ctor /
    /// arguments path). The new struct is fully defaulted.
    pub fn ensureCold(self: *Frame, account: *memory.MemoryAccount) !*FrameCold {
        if (self.cold) |c| return c;
        const c = try account.create(FrameCold);
        c.* = .{};
        self.cold = c;
        return c;
    }

    pub fn freeColdBox(self: *Frame, account: *memory.MemoryAccount) void {
        if (self.cold) |c| {
            account.destroy(FrameCold, c);
            self.cold = null;
        }
    }

    /// Release every owned value/allocation held in `cold` (the derived-ctor
    /// `this`, the `arguments` object, the original-args snapshot VALUES, and the
    /// global-lexical-sync slice allocations) then free the box. Idempotent.
    /// `eval_var_refs` is owned by the frame's `EvalVarRefSnapshot`, never here.
    /// `original_args` VALUES must be released BEFORE the storage backing them is
    /// reclaimed — call this before freeing `storage_values`.
    pub fn freeCold(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        const c = self.cold orelse return;
        if (c.constructor_this_value_owned) c.constructor_this_value.free(rt);
        if (c.arguments_object) |value| value.free(rt);
        releaseValueSliceNoReset(rt, c.original_args);
        if (c.global_lexical_sync_slots.len != 0) account.free(bool, c.global_lexical_sync_slots);
        if (c.global_lexical_sync_indices.len != 0) account.free(usize, c.global_lexical_sync_indices);
        account.destroy(FrameCold, c);
        self.cold = null;
    }

    /// Release ONLY the storage-coupled cold state — the original-args snapshot
    /// VALUES and the global-lexical-sync allocations — resetting those fields to
    /// their defaults while KEEPING the box and the eval / ctor / arguments state.
    /// This matches the old `releaseOwnedStorage` semantics, which reset
    /// original_args/sync but left eval_*/ctor_this/arguments_object intact so a
    /// suspended generator retains them across resume.
    pub fn releaseColdStorage(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        const c = self.cold orelse return;
        releaseValueSliceNoReset(rt, c.original_args);
        c.original_args = &.{};
        if (c.global_lexical_sync_slots.len != 0) account.free(bool, c.global_lexical_sync_slots);
        if (c.global_lexical_sync_indices.len != 0) account.free(usize, c.global_lexical_sync_indices);
        c.global_lexical_sync_slots = &.{};
        c.global_lexical_sync_indices = &.{};
        c.global_lexical_sync_env = null;
        c.global_lexical_sync_checked = false;
    }

    // ---- Cold-field read accessors (return the default when `cold == null`) ----
    pub inline fn evalLocalNames(self: *const Frame) []const Atom {
        return if (self.cold) |c| c.eval_local_names else &.{};
    }
    pub inline fn evalLocalSlots(self: *const Frame) []JSValue {
        return if (self.cold) |c| c.eval_local_slots else &.{};
    }
    pub inline fn evalVarRefNames(self: *const Frame) []const Atom {
        return if (self.cold) |c| c.eval_var_ref_names else &.{};
    }
    pub inline fn evalVarRefs(self: *const Frame) []JSValue {
        return if (self.cold) |c| c.eval_var_refs else &.{};
    }
    pub inline fn evalVarRefsRepublished(self: *const Frame) bool {
        return if (self.cold) |c| c.eval_var_refs_republished else false;
    }
    pub inline fn globalLexicalSyncEnv(self: *const Frame) ?*Object {
        return if (self.cold) |c| c.global_lexical_sync_env else null;
    }
    pub inline fn globalLexicalSyncSlots(self: *const Frame) []bool {
        return if (self.cold) |c| c.global_lexical_sync_slots else &.{};
    }
    pub inline fn globalLexicalSyncIndices(self: *const Frame) []usize {
        return if (self.cold) |c| c.global_lexical_sync_indices else &.{};
    }
    pub inline fn globalLexicalSyncChecked(self: *const Frame) bool {
        return if (self.cold) |c| c.global_lexical_sync_checked else false;
    }
    pub inline fn constructorThisValue(self: *const Frame) JSValue {
        return if (self.cold) |c| c.constructor_this_value else JSValue.undefinedValue();
    }
    pub inline fn constructorThisValueOwned(self: *const Frame) bool {
        return if (self.cold) |c| c.constructor_this_value_owned else false;
    }
    pub inline fn argumentsObject(self: *const Frame) ?JSValue {
        return if (self.cold) |c| c.arguments_object else null;
    }
    pub inline fn originalArgs(self: *const Frame) []JSValue {
        return if (self.cold) |c| c.original_args else &.{};
    }

    pub inline fn init(function: *const bytecode.Bytecode) Frame {
        return .{ .function = function };
    }

    pub fn initCallBindings(self: *Frame, rt: *JSRuntime, inputs: CallBindingInputs) !EvalVarRefSnapshot {
        try self.initCallBindingValues(&rt.memory, inputs, .{});
        errdefer self.releaseCallBindings(rt);

        return try self.initCallEvalBindings(rt, inputs);
    }

    pub fn initCallBindingValues(self: *Frame, account: *memory.MemoryAccount, inputs: CallBindingInputs, modes: CallBindingModes) !void {
        self.this_value = bindCallValue(inputs.initial_this_value, modes.this_value);
        self.current_function = bindCallValue(inputs.current_function_value, modes.current_function);
        self.new_target = inputs.new_target_value;
        self.this_value_owned = modeOwnsValue(modes.this_value);
        // ctor_this is undefined for every non-derived-constructor frame (owned
        // undefined is a no-op to free), so only materialize `cold` when it is a
        // real value. The inline path never reaches here (no derived ctors inline).
        const ctor_value = bindCallValue(inputs.constructor_this_value, modes.constructor_this_value);
        if (!ctor_value.isUndefined()) {
            const c = try self.ensureCold(account);
            c.constructor_this_value = ctor_value;
            c.constructor_this_value_owned = modeOwnsValue(modes.constructor_this_value);
        }
    }

    pub fn initCallEvalBindings(self: *Frame, rt: *JSRuntime, inputs: CallBindingInputs) !EvalVarRefSnapshot {
        const eval_local_names = if (inputs.inherited_eval_local_names.len != 0) inputs.inherited_eval_local_names else inputs.eval_local_names;
        const eval_local_slots = if (inputs.inherited_eval_local_names.len != 0) inputs.inherited_eval_local_slots else inputs.eval_local_slots;
        const frame_eval_var_ref_names = if (inputs.inherited_eval_var_ref_names.len != 0) inputs.inherited_eval_var_ref_names else inputs.input_eval_var_ref_names;
        const frame_eval_var_refs = if (inputs.inherited_eval_var_ref_names.len != 0) inputs.inherited_eval_var_refs else inputs.input_eval_var_refs;

        const has_eval = eval_local_names.len != 0 or eval_local_slots.len != 0 or
            frame_eval_var_ref_names.len != 0 or frame_eval_var_refs.len != 0;
        if (!has_eval) return .{};

        const c = try self.ensureCold(&rt.memory);
        c.eval_local_names = eval_local_names;
        c.eval_local_slots = eval_local_slots;
        if (frame_eval_var_ref_names.len == 0 and frame_eval_var_refs.len == 0) {
            c.eval_var_ref_names = &.{};
            c.eval_var_refs = &.{};
            return .{};
        }

        var snapshot = try EvalVarRefSnapshot.init(rt, frame_eval_var_ref_names, frame_eval_var_refs);
        snapshot.install(c);
        return snapshot;
    }

    pub fn initArguments(
        self: *Frame,
        account: *memory.MemoryAccount,
        arena: ?*runtime.VmStackArena,
        args: []const JSValue,
        use_inline_storage: bool,
        need_original_snapshot: bool,
        windows: FrameStorageWindows,
    ) !void {
        self.actual_arg_count = args.len;

        const frame_arg_count = @max(args.len, @as(usize, @intCast(self.function.arg_count)));
        if (frame_arg_count > 0) {
            const owned_args = try self.allocArgsSlice(account, arena, frame_arg_count, use_inline_storage, windows.args);
            if (frame_arg_count > args.len) @memset(owned_args[args.len..], JSValue.undefinedValue());
            for (args, 0..) |arg, idx| owned_args[idx] = arg.dup();
            self.args = owned_args;
        }

        try self.initOriginalArgsSnapshot(account, args, use_inline_storage, need_original_snapshot, windows.original_args);
    }

    /// Move `argc` call arguments from the operand stack into frame slots
    /// without refcount duplication. Only writes undefined for slots where
    /// `argc < arg_count`. Mirrors QuickJS `JS_CallInternal` arg setup.
    pub fn initArgumentsFromStack(
        self: *Frame,
        account: *memory.MemoryAccount,
        arena: ?*runtime.VmStackArena,
        stack: *stack_mod.Stack,
        argc: usize,
        use_inline_storage: bool,
        need_original_snapshot: bool,
    ) !void {
        self.actual_arg_count = argc;
        const frame_arg_count = @max(argc, @as(usize, @intCast(self.function.arg_count)));
        if (frame_arg_count > 0) {
            if (stack.values.len < argc) return error.StackUnderflow;
            const owned_args = try self.allocArgsSlice(account, arena, frame_arg_count, use_inline_storage, null);
            if (frame_arg_count > argc) @memset(owned_args[argc..], JSValue.undefinedValue());
            var remaining = argc;
            while (remaining > 0) {
                remaining -= 1;
                owned_args[remaining] = try stack.pop();
            }
            self.args = owned_args;
        }
        if (argc > 0 and need_original_snapshot) {
            try self.initOriginalArgsSnapshot(account, self.args[0..argc], use_inline_storage, true, null);
        }
    }

    /// Move already-owned argument values (extracted from a torn-down
    /// frame's operand stack before a tail-call frame reuse) into frame
    /// slots without refcount duplication. Entries in `args` transfer to
    /// the frame and are replaced with undefined as they move; the caller
    /// stays responsible for freeing whatever is left in `args`.
    pub fn initArgumentsMoved(
        self: *Frame,
        account: *memory.MemoryAccount,
        arena: ?*runtime.VmStackArena,
        args: []JSValue,
        use_inline_storage: bool,
        need_original_snapshot: bool,
        windows: FrameStorageWindows,
    ) !void {
        self.actual_arg_count = args.len;
        const frame_arg_count = @max(args.len, @as(usize, @intCast(self.function.arg_count)));
        if (frame_arg_count > 0) {
            const owned_args = try self.allocArgsSlice(account, arena, frame_arg_count, use_inline_storage, windows.args);
            @memset(owned_args[args.len..], JSValue.undefinedValue());
            @memcpy(owned_args[0..args.len], args);
            @memset(args, JSValue.undefinedValue());
            self.args = owned_args;
        }
        if (args.len > 0 and need_original_snapshot) {
            try self.initOriginalArgsSnapshot(account, self.args[0..args.len], use_inline_storage, true, windows.original_args);
        }
    }

    /// Transfer already-owned argument slots into the frame without copying the
    /// slot payloads. The source slice must remain allocated until frame
    /// teardown; the frame releases the values but does not free the backing
    /// storage. Used for stack-backed JS->JS calls where no arity padding is
    /// needed, matching QuickJS's `arg_buf = argv` fast path.
    pub fn initArgumentsBorrowedSlots(
        self: *Frame,
        account: *memory.MemoryAccount,
        args: []JSValue,
        use_inline_storage: bool,
        need_original_snapshot: bool,
        windows: FrameStorageWindows,
    ) !void {
        self.actual_arg_count = args.len;
        std.debug.assert(args.len >= @as(usize, @intCast(self.function.arg_count)));
        if (args.len > 0 and need_original_snapshot) {
            try self.initOriginalArgsSnapshot(account, args, use_inline_storage, true, windows.original_args);
        }
        self.args = args;
    }

    fn allocArgsSlice(
        self: *Frame,
        account: *memory.MemoryAccount,
        arena: ?*runtime.VmStackArena,
        frame_arg_count: usize,
        use_inline_storage: bool,
        window: ?[]JSValue,
    ) ![]JSValue {
        if (window) |values| {
            std.debug.assert(values.len == frame_arg_count);
            return values;
        }
        if (arena) |stack_arena| {
            if (stack_arena.carve(account, frame_arg_count)) |arg_window| return arg_window;
        }
        _ = use_inline_storage;
        return try self.allocOwnedStorage(account, frame_arg_count);
    }

    fn initOriginalArgsSnapshot(
        self: *Frame,
        account: *memory.MemoryAccount,
        args: []const JSValue,
        use_inline_storage: bool,
        need_original_snapshot: bool,
        window: ?[]JSValue,
    ) !void {
        if (args.len == 0 or !need_original_snapshot) return;
        const original_args = if (window) |values| blk: {
            std.debug.assert(values.len == args.len);
            break :blk values;
        } else blk: {
            _ = use_inline_storage;
            break :blk try self.allocOwnedStorage(account, args.len);
        };
        for (args, 0..) |arg, idx| original_args[idx] = arg.dup();
        (try self.ensureCold(account)).original_args = original_args;
    }

    pub fn installOwnedStorage(self: *Frame, storage: []JSValue) void {
        std.debug.assert(!self.storage_on_heap);
        self.storage_values = storage;
        self.storage_on_heap = storage.len != 0;
    }

    pub fn allocOwnedStorage(self: *Frame, account: *memory.MemoryAccount, count: usize) ![]JSValue {
        const values = try account.alloc(JSValue, count);
        if (self.storage_on_heap and self.storage_values.len != 0) {
            // Dynamic growth paths that do not receive pre-carved windows are
            // intentionally rare. Keep ownership explicit instead of silently
            // leaking a second backing allocation.
            account.free(JSValue, values);
            return error.OutOfMemory;
        }
        self.installOwnedStorage(values);
        return values;
    }

    fn releaseCallBindings(self: *Frame, rt: *JSRuntime) void {
        const this_value = self.this_value;
        const current_function = self.current_function;
        const new_target = self.new_target;
        const this_value_owned = self.this_value_owned;
        self.this_value = JSValue.undefinedValue();
        self.current_function = JSValue.undefinedValue();
        self.new_target = JSValue.undefinedValue();
        self.this_value_owned = true;
        // Frees ctor_this (if owned) + the box; eval_local_* are borrowed.
        self.freeCold(&rt.memory, rt);
        if (this_value_owned) this_value.free(rt);
        current_function.free(rt);
        _ = new_target;
    }

    pub fn deinit(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        const this_value = self.this_value;
        const current_function = self.current_function;
        const new_target = self.new_target;
        const this_value_owned = self.this_value_owned;
        self.this_value = JSValue.undefinedValue();
        self.current_function = JSValue.undefinedValue();
        self.new_target = JSValue.undefinedValue();
        self.this_value_owned = true;

        if (this_value_owned) this_value.free(rt);
        current_function.free(rt);
        _ = new_target;

        // releaseOwnedStorage frees the storage slices + clears the storage-coupled
        // cold state (original_args/sync). Then free the rest of cold (ctor_this,
        // arguments_object) + the box — full teardown, no resume to retain it for.
        self.releaseOwnedStorage(account, rt);
        self.freeCold(account, rt);
    }

    pub inline fn deinitInlineCall(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        if (self.this_value_owned) self.this_value.free(rt);
        self.current_function.free(rt);

        if (self.open_var_refs.len != 0) self.closeOpenVarRefs(rt);

        releaseValueSliceNoReset(rt, self.locals);
        releaseValueSliceNoReset(rt, self.args);
        // freeCold releases original_args VALUES before the storage backing them
        // is freed below; also frees ctor_this/arguments_object + sync allocs + box.
        if (self.cold != null) self.freeCold(account, rt);
        // Borrowed var_refs alias the closure's captures (owned by the still-live
        // function object); freeing them here would double-free on the next call.
        if (!self.var_refs_borrowed) releaseValueSliceNoReset(rt, self.var_refs);

        if (self.storage_on_heap and self.storage_values.len != 0) account.free(JSValue, self.storage_values);
    }

    pub fn releaseOwnedStorage(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        self.closeOpenVarRefs(rt);
        const locals = self.locals;
        const args = self.args;
        // A borrowed var_refs aliases the closure captures (not owned here).
        const var_refs: []JSValue = if (self.var_refs_borrowed) &.{} else self.var_refs;
        const storage_values = self.storage_values;
        const storage_on_heap = self.storage_on_heap;

        self.locals = &.{};
        self.args = &.{};
        self.var_refs = &.{};
        self.var_refs_borrowed = false;
        self.open_var_refs = &.{};
        self.storage_values = &.{};
        self.storage_on_heap = false;

        releaseValueSlice(rt, locals);
        releaseValueSlice(rt, args);
        releaseValueSlice(rt, var_refs);
        // Frees original_args VALUES (which alias `storage_values`/the arena slab)
        // + the sync allocs, BEFORE the storage backing is reclaimed below. KEEPS
        // the box + eval/ctor/arguments so a generator retains them across resume.
        if (self.cold != null) self.releaseColdStorage(account, rt);

        if (storage_on_heap and storage_values.len != 0) account.free(JSValue, storage_values);
    }

    pub fn findOpenVarRef(self: *Frame, slot: *JSValue) ?*core.VarRef {
        const idx = self.openVarRefIndex(slot) orelse return null;
        if (idx >= self.open_var_refs.len) return null;
        return self.open_var_refs[idx];
    }

    pub fn addOpenVarRef(self: *Frame, ref: *core.VarRef) void {
        std.debug.assert(ref.is_open);
        const idx = self.openVarRefIndex(ref.pvalue) orelse return;
        std.debug.assert(idx < self.open_var_refs.len);
        self.open_var_refs[idx] = ref;
    }

    pub fn closeOpenVarRefForSlot(self: *Frame, rt: anytype, slot: *JSValue) void {
        const idx = self.openVarRefIndex(slot) orelse return;
        if (idx >= self.open_var_refs.len) return;
        const ref = self.open_var_refs[idx] orelse return;
        self.open_var_refs[idx] = null;
        ref.close(rt);
        ref.valueRef().free(rt);
    }

    pub fn closeOpenVarRefs(self: *Frame, rt: anytype) void {
        for (self.open_var_refs) |*slot| {
            const ref = slot.* orelse continue;
            slot.* = null;
            ref.close(rt);
            ref.valueRef().free(rt);
        }
    }

    pub fn installOpenVarRefSlots(self: *Frame, slots: []?*core.VarRef) void {
        self.open_var_refs = slots;
        @memset(self.open_var_refs, null);
    }

    pub fn ensureOpenVarRefSlots(
        self: *Frame,
        account: *memory.MemoryAccount,
        arena: ?*runtime.VmStackArena,
        use_inline_storage: bool,
    ) !void {
        const count = self.locals.len + self.args.len;
        if (count == 0 or self.open_var_refs.len >= count) return;
        _ = use_inline_storage;
        const slots = blk: {
            if (arena) |stack_arena| {
                if (stack_arena.carveTyped(account, ?*core.VarRef, count)) |window| break :blk window;
            }
            const bytes = try std.math.mul(usize, @sizeOf(?*core.VarRef), count);
            const value_slots = try std.math.divCeil(usize, bytes, @sizeOf(JSValue));
            const values = try self.allocOwnedStorage(account, value_slots);
            break :blk std.mem.bytesAsSlice(?*core.VarRef, std.mem.sliceAsBytes(values)[0..bytes]);
        };
        @memset(slots, null);
        self.open_var_refs = slots;
    }

    fn openVarRefIndex(self: *const Frame, slot: *const JSValue) ?usize {
        if (slotIndexInSlice(slot, self.locals)) |idx| return idx;
        if (slotIndexInSlice(slot, self.args)) |idx| return self.locals.len + idx;
        return null;
    }

    pub fn setLocal(self: *Frame, account: *memory.MemoryAccount, rt: anytype, index: usize, value: JSValue) !void {
        if (index >= self.locals.len) {
            const next_len = index + 1;
            const old_len = self.locals.len;
            const next = try account.alloc(JSValue, next_len);
            errdefer account.free(JSValue, next);
            const old_locals = self.locals;
            if (old_len != 0 and old_locals.ptr == next.ptr) {
                @memset(next[old_len..], JSValue.undefinedValue());
            } else {
                @memset(next, JSValue.undefinedValue());
                if (old_len != 0) @memcpy(next[0..old_len], old_locals);
            }
            const old_storage = self.storage_values;
            const old_storage_on_heap = self.storage_on_heap;
            self.locals = next;
            self.storage_values = next;
            self.storage_on_heap = true;
            if (old_storage_on_heap and old_storage.len != 0) account.free(JSValue, old_storage);
        } else {
            const next_value = value.dup();
            const old_value = self.locals[index];
            self.locals[index] = next_value;
            old_value.free(rt);
            return;
        }
        self.locals[index] = value.dup();
    }

    fn releaseValueSlice(rt: anytype, values: []JSValue) void {
        for (values) |*slot| {
            const value = slot.*;
            slot.* = JSValue.undefinedValue();
            value.free(rt);
        }
    }

    inline fn releaseValueSliceNoReset(rt: anytype, values: []JSValue) void {
        for (values) |value| {
            value.free(rt);
        }
    }

    fn slotIndexInSlice(slot: *const JSValue, values: []const JSValue) ?usize {
        if (values.len == 0) return null;
        const slot_addr = @intFromPtr(slot);
        const start = @intFromPtr(values.ptr);
        const byte_len = values.len * @sizeOf(JSValue);
        const end = start + byte_len;
        if (slot_addr < start or slot_addr >= end) return null;
        const byte_offset = slot_addr - start;
        if (byte_offset % @sizeOf(JSValue) != 0) return null;
        return byte_offset / @sizeOf(JSValue);
    }
};

fn bindCallValue(value: JSValue, mode: CallBindingValueMode) JSValue {
    return switch (mode) {
        .dup => value.dup(),
        .take, .borrow => value,
    };
}

fn modeOwnsValue(mode: CallBindingValueMode) bool {
    return mode != .borrow;
}

fn dupAtomSlice(rt: *JSRuntime, atoms: []const Atom) ![]Atom {
    if (atoms.len == 0) return &.{};
    const duped = try rt.memory.alloc(Atom, atoms.len);
    errdefer rt.memory.free(Atom, duped);
    var initialized: usize = 0;
    errdefer {
        for (duped[0..initialized]) |atom_id| rt.atoms.free(atom_id);
    }
    for (atoms, 0..) |atom_id, idx| {
        duped[idx] = rt.atoms.dup(atom_id);
        initialized += 1;
    }
    return duped;
}

fn freeAtomSlice(rt: *JSRuntime, atoms: []Atom) void {
    for (atoms) |atom_id| rt.atoms.free(atom_id);
    if (atoms.len != 0) rt.memory.free(Atom, atoms);
}

test "Frame setLocal preserves inline locals while growing" {
    var rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("frame-inline-local-growth-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var exec_frame = Frame.init(&function);
    defer exec_frame.deinit(&rt.memory, rt);

    try exec_frame.setLocal(&rt.memory, rt, 0, JSValue.int32(11));
    try exec_frame.setLocal(&rt.memory, rt, 1, JSValue.int32(22));

    try std.testing.expectEqual(@as(?i32, 11), exec_frame.locals[0].asInt32());
    try std.testing.expectEqual(@as(?i32, 22), exec_frame.locals[1].asInt32());
    try std.testing.expect(exec_frame.storage_on_heap);
}

// Frame capacity helpers (moved from the dissolved exec/vm_utils.zig).

pub fn ensureLocalsCapacity(ctx: *core.JSContext, frame: *Frame, idx: usize) !void {
    if (idx < frame.locals.len) return;
    const next_len = idx + 1;

    const next_locals = try ctx.runtime.memory.alloc(core.JSValue, next_len);
    errdefer ctx.runtime.memory.free(core.JSValue, next_locals);

    for (frame.locals, 0..) |value, i| next_locals[i] = value;
    if (next_len > frame.locals.len) @memset(next_locals[frame.locals.len..next_len], core.JSValue.undefinedValue());

    const old_storage = frame.storage_values;
    const old_storage_on_heap = frame.storage_on_heap;
    frame.locals = next_locals;
    frame.storage_values = next_locals;
    frame.storage_on_heap = true;
    if (old_storage.len != 0 and old_storage_on_heap) ctx.runtime.memory.free(core.JSValue, old_storage);
}

pub fn ensureVarRefsCapacity(ctx: *core.JSContext, frame: *Frame, idx: usize) !void {
    if (idx < frame.var_refs.len) return;
    const next_len = idx + 1;
    const next = try ctx.runtime.memory.alloc(core.JSValue, next_len);
    errdefer ctx.runtime.memory.free(core.JSValue, next);
    for (frame.var_refs, 0..) |value, i| next[i] = value;
    @memset(next[frame.var_refs.len..next_len], core.JSValue.undefinedValue());
    const old_storage = frame.storage_values;
    const old_storage_on_heap = frame.storage_on_heap;
    frame.var_refs = next;
    frame.storage_values = next;
    frame.storage_on_heap = true;
    if (old_storage.len != 0 and old_storage_on_heap) ctx.runtime.memory.free(core.JSValue, old_storage);
}
