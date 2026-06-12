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

pub const PreparedNativeCallTarget = struct {
    native_ref: core.function.NativeBuiltinRef,
    auto_init: ?core.property.AutoInit = null,
};

pub const PreparedCallTarget = struct {
    site_id: u16,
    stack_depth: usize,
    payload: Payload,

    pub const Payload = union(enum) {
        value: usize,
        native: PreparedNativeCallTarget,
    };
};

pub const PreparedCallTargetOwned = union(enum) {
    value: JSValue,
    native: PreparedNativeCallTarget,
};

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

    pub fn install(self: *EvalVarRefSnapshot, frame: *Frame) void {
        frame.eval_var_ref_names = self.names;
        frame.eval_var_refs = self.refs.values;
    }

    pub fn rootSlice(self: *EvalVarRefSnapshot) runtime.ValueRootSlice {
        return self.refs.slice();
    }

    pub fn deinit(self: *EvalVarRefSnapshot, rt: *JSRuntime) void {
        const names = self.names;
        self.names = &.{};
        self.refs.deinit(rt);
        freeAtomSlice(rt, names);
    }
};

pub const FrameRootScope = struct {
    rt: ?*JSRuntime = null,
    values: [4]runtime.ValueRootValue = undefined,
    slices: [8]runtime.ValueRootSlice = undefined,
    frame: runtime.ValueRootFrame = .{},

    pub fn init(self: *FrameRootScope, rt: *JSRuntime, stack: *stack_mod.Stack, exec_frame: *Frame, eval_var_refs: *EvalVarRefSnapshot) void {
        self.rt = rt;
        self.values = .{
            .{ .value = &exec_frame.this_value },
            .{ .value = &exec_frame.constructor_this_value },
            .{ .value = &exec_frame.current_function },
            .{ .value = &exec_frame.new_target },
        };
        self.slices = .{
            .{ .mutable = &stack.values },
            .{ .mutable = &exec_frame.locals },
            .{ .mutable = &exec_frame.args },
            .{ .mutable = &exec_frame.original_args },
            .{ .mutable = &exec_frame.var_refs },
            .{ .mutable = &exec_frame.eval_local_slots },
            eval_var_refs.rootSlice(),
            .{ .mutable = &exec_frame.prepared_call_values },
        };
        self.frame = .{
            .previous = rt.active_value_roots,
            .slices = &self.slices,
            .values = &self.values,
        };
        rt.active_value_roots = &self.frame;
    }

    pub fn deinit(self: *FrameRootScope) void {
        const rt = self.rt orelse return;
        rt.active_value_roots = self.frame.previous;
        self.* = .{};
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

pub const Frame = struct {
    function: *const bytecode.Bytecode,
    pc: usize = 0,
    this_value: JSValue = JSValue.undefinedValue(),
    constructor_this_value: JSValue = JSValue.undefinedValue(),
    current_function: JSValue = JSValue.undefinedValue(),
    new_target: JSValue = JSValue.undefinedValue(),
    arguments_object: ?JSValue = null,
    actual_arg_count: usize = 0,
    locals: []JSValue = &.{},
    args: []JSValue = &.{},
    original_args: []JSValue = &.{},
    inline_locals: [8]JSValue = undefined,
    inline_locals_uninit: [8]bool = undefined,
    inline_args: [4]JSValue = undefined,
    inline_original_args: [4]JSValue = undefined,
    inline_var_refs: [4]JSValue = undefined,
    inline_prepared_call_targets: [4]PreparedCallTarget = undefined,
    inline_prepared_call_values: [4]JSValue = undefined,
    locals_on_heap: bool = false,
    locals_uninit_on_heap: bool = false,
    args_on_heap: bool = false,
    original_args_on_heap: bool = false,
    var_refs: []JSValue = &.{},
    var_refs_on_heap: bool = false,
    eval_local_names: []const Atom = &.{},
    eval_local_slots: []JSValue = &.{},
    eval_var_ref_names: []const Atom = &.{},
    eval_var_refs: []JSValue = &.{},
    eval_var_refs_republished: bool = false,
    prepared_call_targets: []PreparedCallTarget = &.{},
    prepared_call_values: []JSValue = &.{},
    prepared_call_target_capacity: usize = 0,
    prepared_call_value_capacity: usize = 0,
    prepared_call_targets_on_heap: bool = false,
    prepared_call_values_on_heap: bool = false,
    /// Per-slot TDZ flag mirroring QuickJS's `JS_UNINITIALIZED`
    /// sentinel: `true` means the slot is in the temporal dead
    /// zone; reads via `get_loc_check` / `put_loc_check` throw
    /// `ReferenceError`, and `put_loc_check_init` clears the flag.
    /// `set_loc_uninitialized` (emitted by the resolve_variables
    /// prologue for every lexical local) sets it back to `true`.
    locals_uninit: []bool = &.{},
    locals_uninit_count: usize = 0,
    global_lexical_sync_env: ?*Object = null,
    global_lexical_sync_slots: []bool = &.{},
    global_lexical_sync_indices: []usize = &.{},
    global_lexical_sync_checked: bool = false,

    pub fn init(function: *const bytecode.Bytecode) Frame {
        return .{ .function = function };
    }

    pub fn initCallBindings(self: *Frame, rt: *JSRuntime, inputs: CallBindingInputs) !EvalVarRefSnapshot {
        self.this_value = inputs.initial_this_value.dup();
        self.constructor_this_value = inputs.constructor_this_value.dup();
        self.current_function = inputs.current_function_value.dup();
        self.new_target = inputs.new_target_value.dup();
        errdefer self.releaseCallBindings(rt);

        self.eval_local_names = if (inputs.inherited_eval_local_names.len != 0) inputs.inherited_eval_local_names else inputs.eval_local_names;
        self.eval_local_slots = if (inputs.inherited_eval_local_names.len != 0) inputs.inherited_eval_local_slots else inputs.eval_local_slots;
        const frame_eval_var_ref_names = if (inputs.inherited_eval_var_ref_names.len != 0) inputs.inherited_eval_var_ref_names else inputs.input_eval_var_ref_names;
        const frame_eval_var_refs = if (inputs.inherited_eval_var_ref_names.len != 0) inputs.inherited_eval_var_refs else inputs.input_eval_var_refs;

        var snapshot = try EvalVarRefSnapshot.init(rt, frame_eval_var_ref_names, frame_eval_var_refs);
        snapshot.install(self);
        return snapshot;
    }

    pub fn initArguments(
        self: *Frame,
        account: *memory.MemoryAccount,
        arena: ?*runtime.VmStackArena,
        args: []const JSValue,
        use_inline_storage: bool,
        need_original_snapshot: bool,
    ) !void {
        self.actual_arg_count = args.len;

        const frame_arg_count = @max(args.len, @as(usize, @intCast(self.function.arg_count)));
        if (frame_arg_count > 0) {
            const owned_args = try self.allocArgsSlice(account, arena, frame_arg_count, use_inline_storage);
            @memset(owned_args, JSValue.undefinedValue());
            for (args, 0..) |arg, idx| owned_args[idx] = arg.dup();
            self.args = owned_args;
        }

        try self.initOriginalArgsSnapshot(account, args, use_inline_storage, need_original_snapshot);
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
            const owned_args = try self.allocArgsSlice(account, arena, frame_arg_count, use_inline_storage);
            @memset(owned_args, JSValue.undefinedValue());
            var remaining = argc;
            while (remaining > 0) {
                remaining -= 1;
                owned_args[remaining] = try stack.pop();
            }
            self.args = owned_args;
        }
        if (argc > 0 and need_original_snapshot) {
            try self.initOriginalArgsSnapshot(account, self.args[0..argc], use_inline_storage, true);
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
    ) !void {
        self.actual_arg_count = args.len;
        const frame_arg_count = @max(args.len, @as(usize, @intCast(self.function.arg_count)));
        if (frame_arg_count > 0) {
            const owned_args = try self.allocArgsSlice(account, arena, frame_arg_count, use_inline_storage);
            @memset(owned_args[args.len..], JSValue.undefinedValue());
            @memcpy(owned_args[0..args.len], args);
            @memset(args, JSValue.undefinedValue());
            self.args = owned_args;
        }
        if (args.len > 0 and need_original_snapshot) {
            try self.initOriginalArgsSnapshot(account, self.args[0..args.len], use_inline_storage, true);
        }
    }

    fn allocArgsSlice(
        self: *Frame,
        account: *memory.MemoryAccount,
        arena: ?*runtime.VmStackArena,
        frame_arg_count: usize,
        use_inline_storage: bool,
    ) ![]JSValue {
        if (use_inline_storage and frame_arg_count <= self.inline_args.len) {
            return self.inline_args[0..frame_arg_count];
        }
        if (arena) |stack_arena| {
            if (stack_arena.carve(account, frame_arg_count)) |window| return window;
        }
        self.args_on_heap = true;
        return try account.alloc(JSValue, frame_arg_count);
    }

    fn initOriginalArgsSnapshot(
        self: *Frame,
        account: *memory.MemoryAccount,
        args: []const JSValue,
        use_inline_storage: bool,
        need_original_snapshot: bool,
    ) !void {
        if (args.len == 0 or !need_original_snapshot) return;
        const original_args = if (use_inline_storage and args.len <= self.inline_original_args.len)
            self.inline_original_args[0..args.len]
        else blk: {
            self.original_args_on_heap = true;
            break :blk try account.alloc(JSValue, args.len);
        };
        for (args, 0..) |arg, idx| original_args[idx] = arg.dup();
        self.original_args = original_args;
    }

    fn releaseCallBindings(self: *Frame, rt: *JSRuntime) void {
        const this_value = self.this_value;
        const constructor_this_value = self.constructor_this_value;
        const current_function = self.current_function;
        const new_target = self.new_target;
        self.this_value = JSValue.undefinedValue();
        self.constructor_this_value = JSValue.undefinedValue();
        self.current_function = JSValue.undefinedValue();
        self.new_target = JSValue.undefinedValue();
        self.eval_local_names = &.{};
        self.eval_local_slots = &.{};
        this_value.free(rt);
        constructor_this_value.free(rt);
        current_function.free(rt);
        new_target.free(rt);
    }

    pub fn deinit(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        const this_value = self.this_value;
        const constructor_this_value = self.constructor_this_value;
        const current_function = self.current_function;
        const new_target = self.new_target;
        const arguments_object = self.arguments_object;
        self.this_value = JSValue.undefinedValue();
        self.constructor_this_value = JSValue.undefinedValue();
        self.current_function = JSValue.undefinedValue();
        self.new_target = JSValue.undefinedValue();
        self.arguments_object = null;

        this_value.free(rt);
        constructor_this_value.free(rt);
        current_function.free(rt);
        new_target.free(rt);
        if (arguments_object) |value| value.free(rt);
        self.clearPreparedCallTargets(rt);

        self.releaseOwnedStorage(account, rt);
        self.eval_local_names = &.{};
        self.eval_local_slots = &.{};
        self.eval_var_ref_names = &.{};
        self.eval_var_refs = &.{};
        self.eval_var_refs_republished = false;
    }

    pub fn releaseOwnedStorage(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        const locals = self.locals;
        const args = self.args;
        const original_args = self.original_args;
        const locals_on_heap = self.locals_on_heap;
        const locals_uninit_on_heap = self.locals_uninit_on_heap;
        const args_on_heap = self.args_on_heap;
        const original_args_on_heap = self.original_args_on_heap;
        const var_refs = self.var_refs;
        const var_refs_on_heap = self.var_refs_on_heap;
        const locals_uninit = self.locals_uninit;
        const global_lexical_sync_slots = self.global_lexical_sync_slots;
        const global_lexical_sync_indices = self.global_lexical_sync_indices;
        const prepared_call_targets = self.prepared_call_targets;
        const prepared_call_values = self.prepared_call_values;
        const prepared_call_target_capacity = self.prepared_call_target_capacity;
        const prepared_call_value_capacity = self.prepared_call_value_capacity;
        const prepared_call_targets_on_heap = self.prepared_call_targets_on_heap;
        const prepared_call_values_on_heap = self.prepared_call_values_on_heap;

        self.locals = &.{};
        self.args = &.{};
        self.original_args = &.{};
        self.locals_on_heap = false;
        self.locals_uninit_on_heap = false;
        self.args_on_heap = false;
        self.original_args_on_heap = false;
        self.var_refs = &.{};
        self.var_refs_on_heap = false;
        self.locals_uninit = &.{};
        self.locals_uninit_count = 0;
        self.global_lexical_sync_env = null;
        self.global_lexical_sync_slots = &.{};
        self.global_lexical_sync_indices = &.{};
        self.global_lexical_sync_checked = false;
        self.prepared_call_targets = &.{};
        self.prepared_call_values = &.{};
        self.prepared_call_target_capacity = 0;
        self.prepared_call_value_capacity = 0;
        self.prepared_call_targets_on_heap = false;
        self.prepared_call_values_on_heap = false;

        releaseValueSlice(rt, locals);
        releaseValueSlice(rt, args);
        releaseValueSlice(rt, original_args);
        releaseValueSlice(rt, var_refs);

        if (locals.len != 0 and locals_on_heap) account.free(JSValue, locals);
        if (args.len != 0 and args_on_heap) account.free(JSValue, args);
        if (original_args.len != 0 and original_args_on_heap) account.free(JSValue, original_args);
        if (var_refs.len != 0 and var_refs_on_heap) account.free(JSValue, var_refs);
        if (locals_uninit.len != 0 and locals_uninit_on_heap) account.free(bool, locals_uninit);
        if (global_lexical_sync_slots.len != 0) account.free(bool, global_lexical_sync_slots);
        if (global_lexical_sync_indices.len != 0) account.free(usize, global_lexical_sync_indices);
        if (prepared_call_targets_on_heap and prepared_call_target_capacity != 0) account.free(PreparedCallTarget, prepared_call_targets.ptr[0..prepared_call_target_capacity]);
        if (prepared_call_values_on_heap and prepared_call_value_capacity != 0) account.free(JSValue, prepared_call_values.ptr[0..prepared_call_value_capacity]);
    }

    pub fn pushPreparedNativeCall(
        self: *Frame,
        account: *memory.MemoryAccount,
        site_id: u16,
        stack_depth: usize,
        native: PreparedNativeCallTarget,
    ) !void {
        try self.ensurePreparedCallTargetCapacity(account, self.prepared_call_targets.len + 1);
        const idx = self.prepared_call_targets.len;
        self.prepared_call_targets = self.prepared_call_targets.ptr[0 .. idx + 1];
        self.prepared_call_targets[idx] = .{
            .site_id = site_id,
            .stack_depth = stack_depth,
            .payload = .{ .native = native },
        };
    }

    pub fn pushPreparedValueCall(
        self: *Frame,
        account: *memory.MemoryAccount,
        site_id: u16,
        stack_depth: usize,
        value: JSValue,
    ) !void {
        try self.ensurePreparedCallTargetCapacity(account, self.prepared_call_targets.len + 1);
        try self.ensurePreparedCallValueCapacity(account, self.prepared_call_values.len + 1);
        const value_idx = self.prepared_call_values.len;
        self.prepared_call_values = self.prepared_call_values.ptr[0 .. value_idx + 1];
        self.prepared_call_values[value_idx] = value;
        const target_idx = self.prepared_call_targets.len;
        self.prepared_call_targets = self.prepared_call_targets.ptr[0 .. target_idx + 1];
        self.prepared_call_targets[target_idx] = .{
            .site_id = site_id,
            .stack_depth = stack_depth,
            .payload = .{ .value = value_idx },
        };
    }

    pub fn popPreparedCallTarget(self: *Frame) ?PreparedCallTargetOwned {
        if (self.prepared_call_targets.len == 0) return null;
        const target = self.prepared_call_targets[self.prepared_call_targets.len - 1];
        self.prepared_call_targets = self.prepared_call_targets.ptr[0 .. self.prepared_call_targets.len - 1];
        return switch (target.payload) {
            .native => |native| .{ .native = native },
            .value => |value_idx| blk: {
                std.debug.assert(value_idx + 1 == self.prepared_call_values.len);
                const value = self.prepared_call_values[value_idx];
                self.prepared_call_values[value_idx] = JSValue.undefinedValue();
                self.prepared_call_values = self.prepared_call_values.ptr[0..value_idx];
                break :blk .{ .value = value };
            },
        };
    }

    pub fn dropPreparedCallsForCatchDepth(self: *Frame, rt: anytype, stack_depth: usize) void {
        while (self.prepared_call_targets.len != 0) {
            const target = self.prepared_call_targets[self.prepared_call_targets.len - 1];
            if (target.stack_depth < stack_depth) break;
            const owned = self.popPreparedCallTarget() orelse break;
            switch (owned) {
                .value => |value| value.free(rt),
                .native => {},
            }
        }
    }

    pub fn clearPreparedCallTargets(self: *Frame, rt: anytype) void {
        while (self.popPreparedCallTarget()) |owned| {
            switch (owned) {
                .value => |value| value.free(rt),
                .native => {},
            }
        }
    }

    fn ensurePreparedCallTargetCapacity(self: *Frame, account: *memory.MemoryAccount, needed: usize) !void {
        const capacity = if (self.prepared_call_targets_on_heap) self.prepared_call_target_capacity else self.inline_prepared_call_targets.len;
        if (needed <= capacity) {
            if (self.prepared_call_targets.len == 0 and !self.prepared_call_targets_on_heap) {
                self.prepared_call_targets = self.inline_prepared_call_targets[0..0];
            }
            return;
        }
        if (needed <= self.inline_prepared_call_targets.len and !self.prepared_call_targets_on_heap) {
            if (self.prepared_call_targets.len == 0) self.prepared_call_targets = self.inline_prepared_call_targets[0..0];
            return;
        }
        var next_capacity = if (capacity == 0) @as(usize, 8) else capacity * 2;
        if (next_capacity < needed) next_capacity = needed;
        const next = try account.alloc(PreparedCallTarget, next_capacity);
        errdefer account.free(PreparedCallTarget, next);
        @memcpy(next[0..self.prepared_call_targets.len], self.prepared_call_targets);
        const old = self.prepared_call_targets;
        const old_on_heap = self.prepared_call_targets_on_heap;
        const old_capacity = self.prepared_call_target_capacity;
        self.prepared_call_targets = next[0..old.len];
        self.prepared_call_target_capacity = next_capacity;
        self.prepared_call_targets_on_heap = true;
        if (old_on_heap and old_capacity != 0) account.free(PreparedCallTarget, old.ptr[0..old_capacity]);
    }

    fn ensurePreparedCallValueCapacity(self: *Frame, account: *memory.MemoryAccount, needed: usize) !void {
        const capacity = if (self.prepared_call_values_on_heap) self.prepared_call_value_capacity else self.inline_prepared_call_values.len;
        if (needed <= capacity) {
            if (self.prepared_call_values.len == 0 and !self.prepared_call_values_on_heap) {
                self.prepared_call_values = self.inline_prepared_call_values[0..0];
            }
            return;
        }
        if (needed <= self.inline_prepared_call_values.len and !self.prepared_call_values_on_heap) {
            if (self.prepared_call_values.len == 0) self.prepared_call_values = self.inline_prepared_call_values[0..0];
            return;
        }
        var next_capacity = if (capacity == 0) @as(usize, 8) else capacity * 2;
        if (next_capacity < needed) next_capacity = needed;
        const next = try account.alloc(JSValue, next_capacity);
        errdefer account.free(JSValue, next);
        @memcpy(next[0..self.prepared_call_values.len], self.prepared_call_values);
        const old = self.prepared_call_values;
        const old_on_heap = self.prepared_call_values_on_heap;
        const old_capacity = self.prepared_call_value_capacity;
        self.prepared_call_values = next[0..old.len];
        self.prepared_call_value_capacity = next_capacity;
        self.prepared_call_values_on_heap = true;
        if (old_on_heap and old_capacity != 0) account.free(JSValue, old.ptr[0..old_capacity]);
    }

    pub fn setLocalUninitialized(self: *Frame, index: usize) void {
        if (!self.locals_uninit[index]) {
            self.locals_uninit[index] = true;
            self.locals_uninit_count += 1;
        }
    }

    pub fn clearLocalUninitialized(self: *Frame, index: usize) void {
        if (self.locals_uninit[index]) {
            self.locals_uninit[index] = false;
            self.locals_uninit_count -= 1;
        }
    }

    pub fn localIsUninitialized(self: *const Frame, index: usize) bool {
        return self.locals_uninit_count != 0 and self.locals_uninit[index];
    }

    pub fn recomputeLocalsUninitCount(self: *Frame) void {
        var count: usize = 0;
        for (self.locals_uninit) |is_uninit| {
            if (is_uninit) count += 1;
        }
        self.locals_uninit_count = count;
    }

    pub fn setLocal(self: *Frame, account: *memory.MemoryAccount, rt: anytype, index: usize, value: JSValue) !void {
        if (index >= self.locals.len) {
            const next_len = index + 1;
            const old_len = self.locals.len;
            const old_locals_on_heap = self.locals_on_heap;
            var next_on_heap = false;
            const next = if (!old_locals_on_heap and next_len <= self.inline_locals.len)
                self.inline_locals[0..next_len]
            else blk: {
                const allocated = try account.alloc(JSValue, next_len);
                next_on_heap = true;
                break :blk allocated;
            };
            errdefer if (next_on_heap) account.free(JSValue, next);
            const old_locals = self.locals;
            if (old_len != 0 and old_locals.ptr == next.ptr) {
                @memset(next[old_len..], JSValue.undefinedValue());
            } else {
                @memset(next, JSValue.undefinedValue());
                if (old_len != 0) @memcpy(next[0..old_len], old_locals);
            }
            self.locals = next;
            self.locals_on_heap = next_on_heap;
            if (old_locals_on_heap) account.free(JSValue, old_locals);
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
};

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
    try std.testing.expect(!exec_frame.locals_on_heap);
}

// Frame capacity helpers (moved from the dissolved exec/vm_utils.zig).

pub fn ensureLocalsCapacity(ctx: *core.JSContext, frame: *Frame, idx: usize) !void {
    if (idx < frame.locals.len and idx < frame.locals_uninit.len) return;
    const next_len = @max(idx + 1, @max(frame.locals.len, frame.locals_uninit.len));

    if (!frame.locals_on_heap and !frame.locals_uninit_on_heap and
        next_len <= frame.inline_locals.len and next_len <= frame.inline_locals_uninit.len)
    {
        const next_locals = frame.inline_locals[0..next_len];
        const next_uninit = frame.inline_locals_uninit[0..next_len];
        if (frame.locals.len != 0 and frame.locals.ptr != next_locals.ptr) {
            @memcpy(next_locals[0..frame.locals.len], frame.locals);
        }
        if (next_len > frame.locals.len) @memset(next_locals[frame.locals.len..next_len], core.JSValue.undefinedValue());
        if (frame.locals_uninit.len != 0 and frame.locals_uninit.ptr != next_uninit.ptr) {
            @memcpy(next_uninit[0..frame.locals_uninit.len], frame.locals_uninit);
        }
        if (next_len > frame.locals_uninit.len) @memset(next_uninit[frame.locals_uninit.len..next_len], false);
        frame.locals = next_locals;
        frame.locals_uninit = next_uninit;
        return;
    }

    const next_locals = try ctx.runtime.memory.alloc(core.JSValue, next_len);
    errdefer ctx.runtime.memory.free(core.JSValue, next_locals);
    const next_uninit = try ctx.runtime.memory.alloc(bool, next_len);
    errdefer ctx.runtime.memory.free(bool, next_uninit);

    for (frame.locals, 0..) |value, i| next_locals[i] = value;
    if (next_len > frame.locals.len) @memset(next_locals[frame.locals.len..next_len], core.JSValue.undefinedValue());
    for (frame.locals_uninit, 0..) |value, i| next_uninit[i] = value;
    if (next_len > frame.locals_uninit.len) @memset(next_uninit[frame.locals_uninit.len..next_len], false);

    const old_locals = frame.locals;
    const old_locals_uninit = frame.locals_uninit;
    const old_locals_on_heap = frame.locals_on_heap;
    const old_locals_uninit_on_heap = frame.locals_uninit_on_heap;
    frame.locals = next_locals;
    frame.locals_uninit = next_uninit;
    frame.locals_on_heap = true;
    frame.locals_uninit_on_heap = true;
    if (old_locals.len != 0 and old_locals_on_heap) ctx.runtime.memory.free(core.JSValue, old_locals);
    if (old_locals_uninit.len != 0 and old_locals_uninit_on_heap) ctx.runtime.memory.free(bool, old_locals_uninit);
}

pub fn ensureVarRefsCapacity(ctx: *core.JSContext, frame: *Frame, idx: usize) !void {
    if (idx < frame.var_refs.len) return;
    const next_len = idx + 1;
    if (!frame.var_refs_on_heap and next_len <= frame.inline_var_refs.len) {
        const next = frame.inline_var_refs[0..next_len];
        if (frame.var_refs.len != 0 and frame.var_refs.ptr != next.ptr) {
            @memcpy(next[0..frame.var_refs.len], frame.var_refs);
        }
        @memset(next[frame.var_refs.len..next_len], core.JSValue.undefinedValue());
        frame.var_refs = next;
        return;
    }

    const next = try ctx.runtime.memory.alloc(core.JSValue, next_len);
    errdefer ctx.runtime.memory.free(core.JSValue, next);
    for (frame.var_refs, 0..) |value, i| next[i] = value;
    @memset(next[frame.var_refs.len..next_len], core.JSValue.undefinedValue());
    const old_var_refs = frame.var_refs;
    const old_var_refs_on_heap = frame.var_refs_on_heap;
    frame.var_refs = next;
    frame.var_refs_on_heap = true;
    if (old_var_refs.len != 0 and old_var_refs_on_heap) ctx.runtime.memory.free(core.JSValue, old_var_refs);
}
