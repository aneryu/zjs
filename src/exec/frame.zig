const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const atom = @import("../core/atom.zig");
const Atom = atom.Atom;
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
    slices: [7]runtime.ValueRootSlice = undefined,
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
    inline_args: [4]JSValue = undefined,
    inline_original_args: [4]JSValue = undefined,
    args_on_heap: bool = false,
    original_args_on_heap: bool = false,
    var_refs: []JSValue = &.{},
    eval_local_names: []const Atom = &.{},
    eval_local_slots: []JSValue = &.{},
    eval_var_ref_names: []const Atom = &.{},
    eval_var_refs: []JSValue = &.{},
    eval_var_refs_republished: bool = false,
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

    pub fn initArguments(self: *Frame, account: *memory.MemoryAccount, args: []const JSValue, use_inline_storage: bool) !void {
        self.actual_arg_count = args.len;

        const frame_arg_count = @max(args.len, @as(usize, @intCast(self.function.arg_count)));
        if (frame_arg_count > 0) {
            const owned_args = if (use_inline_storage and frame_arg_count <= self.inline_args.len)
                self.inline_args[0..frame_arg_count]
            else blk: {
                self.args_on_heap = true;
                break :blk try account.alloc(JSValue, frame_arg_count);
            };
            @memset(owned_args, JSValue.undefinedValue());
            for (args, 0..) |arg, idx| owned_args[idx] = arg.dup();
            self.args = owned_args;
        }

        if (args.len > 0) {
            const original_args = if (use_inline_storage and args.len <= self.inline_original_args.len)
                self.inline_original_args[0..args.len]
            else blk: {
                self.original_args_on_heap = true;
                break :blk try account.alloc(JSValue, args.len);
            };
            for (args, 0..) |arg, idx| original_args[idx] = arg.dup();
            self.original_args = original_args;
        }
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
        const args_on_heap = self.args_on_heap;
        const original_args_on_heap = self.original_args_on_heap;
        const var_refs = self.var_refs;
        const locals_uninit = self.locals_uninit;
        const global_lexical_sync_slots = self.global_lexical_sync_slots;
        const global_lexical_sync_indices = self.global_lexical_sync_indices;

        self.locals = &.{};
        self.args = &.{};
        self.original_args = &.{};
        self.args_on_heap = false;
        self.original_args_on_heap = false;
        self.var_refs = &.{};
        self.locals_uninit = &.{};
        self.locals_uninit_count = 0;
        self.global_lexical_sync_env = null;
        self.global_lexical_sync_slots = &.{};
        self.global_lexical_sync_indices = &.{};
        self.global_lexical_sync_checked = false;

        releaseValueSlice(rt, locals);
        releaseValueSlice(rt, args);
        releaseValueSlice(rt, original_args);
        releaseValueSlice(rt, var_refs);

        if (locals.len != 0) account.free(JSValue, locals);
        if (args.len != 0 and args_on_heap) account.free(JSValue, args);
        if (original_args.len != 0 and original_args_on_heap) account.free(JSValue, original_args);
        if (var_refs.len != 0) account.free(JSValue, var_refs);
        if (locals_uninit.len != 0) account.free(bool, locals_uninit);
        if (global_lexical_sync_slots.len != 0) account.free(bool, global_lexical_sync_slots);
        if (global_lexical_sync_indices.len != 0) account.free(usize, global_lexical_sync_indices);
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
            const next = try account.alloc(JSValue, index + 1);
            errdefer account.free(JSValue, next);
            @memset(next, JSValue.undefinedValue());
            if (self.locals.len != 0) {
                const old_locals = self.locals;
                @memcpy(next[0..self.locals.len], self.locals);
                self.locals = next;
                account.free(JSValue, old_locals);
            } else {
                self.locals = next;
            }
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
