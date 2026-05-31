const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const atom = @import("../core/atom.zig");
const Atom = atom.Atom;
const memory = @import("../core/memory.zig");
const Object = @import("../core/object.zig").Object;
const Value = @import("../core/value.zig").Value;

pub const no_global_lexical_sync_index: usize = std.math.maxInt(usize);

pub const Frame = struct {
    function: *const bytecode.Bytecode,
    pc: usize = 0,
    this_value: Value = Value.undefinedValue(),
    constructor_this_value: Value = Value.undefinedValue(),
    current_function: Value = Value.undefinedValue(),
    new_target: Value = Value.undefinedValue(),
    arguments_object: ?Value = null,
    actual_arg_count: usize = 0,
    locals: []Value = &.{},
    args: []Value = &.{},
    original_args: []Value = &.{},
    inline_args: [4]Value = undefined,
    inline_original_args: [4]Value = undefined,
    args_on_heap: bool = false,
    original_args_on_heap: bool = false,
    var_refs: []Value = &.{},
    eval_local_names: []const Atom = &.{},
    eval_local_slots: []Value = &.{},
    eval_var_ref_names: []const Atom = &.{},
    eval_var_refs: []const Value = &.{},
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

    pub fn deinit(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        const this_value = self.this_value;
        const constructor_this_value = self.constructor_this_value;
        const current_function = self.current_function;
        const new_target = self.new_target;
        const arguments_object = self.arguments_object;
        self.this_value = Value.undefinedValue();
        self.constructor_this_value = Value.undefinedValue();
        self.current_function = Value.undefinedValue();
        self.new_target = Value.undefinedValue();
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

        if (locals.len != 0) account.free(Value, locals);
        if (args.len != 0 and args_on_heap) account.free(Value, args);
        if (original_args.len != 0 and original_args_on_heap) account.free(Value, original_args);
        if (var_refs.len != 0) account.free(Value, var_refs);
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

    pub fn setLocal(self: *Frame, account: *memory.MemoryAccount, rt: anytype, index: usize, value: Value) !void {
        if (index >= self.locals.len) {
            const next = try account.alloc(Value, index + 1);
            errdefer account.free(Value, next);
            @memset(next, Value.undefinedValue());
            if (self.locals.len != 0) {
                const old_locals = self.locals;
                @memcpy(next[0..self.locals.len], self.locals);
                self.locals = next;
                account.free(Value, old_locals);
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

    fn releaseValueSlice(rt: anytype, values: []Value) void {
        for (values) |*slot| {
            const value = slot.*;
            slot.* = Value.undefinedValue();
            value.free(rt);
        }
    }
};
