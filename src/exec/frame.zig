const std = @import("std");

const bytecode = @import("../bytecode.zig");
const atom = @import("../core/atom.zig");
const Atom = atom.Atom;
const core = @import("../core/root.zig");
const memory = @import("../core/memory.zig");
const runtime = @import("../core/runtime.zig");
const JSRuntime = runtime.JSRuntime;
const JSValue = @import("../core/value.zig").JSValue;
const open_bindings_mod = @import("open_bindings.zig");
const stack_mod = @import("stack.zig");
const value_slot = @import("value_slot.zig");

pub const FrameSlab = struct {
    storage: []JSValue = &.{},
    args: []JSValue = &.{},
    original_args: []JSValue = &.{},
    locals: []JSValue = &.{},
    stack: []JSValue = &.{},
    /// Slot-typed var-ref window (`JSVarRef **`, 8-byte pointer slots) carved
    /// from the JSValue slab tail alongside `open_var_refs` — same
    /// bytesAsSlice reinterpretation, half the pre-typed 16B/slot footprint
    /// (VARREFS-SLOT-TYPING-BLUEPRINT phase D, qjs alloca partition
    /// quickjs.c:17834-17866).
    var_refs: []*core.VarRef = &.{},
    open_var_refs: []?*core.VarRef = &.{},

    pub fn requiredStorageSlots(
        arg_count: usize,
        original_arg_count: usize,
        local_count: usize,
        stack_count: usize,
        var_ref_count: usize,
        open_var_ref_count: usize,
    ) !usize {
        const count_1 = try std.math.add(usize, arg_count, original_arg_count);
        const count_2 = try std.math.add(usize, count_1, local_count);
        const value_count = try std.math.add(usize, count_2, stack_count);
        const var_ref_bytes = try std.math.mul(usize, @sizeOf(*core.VarRef), var_ref_count);
        const open_bytes = try std.math.mul(usize, @sizeOf(?*core.VarRef), open_var_ref_count);
        const ptr_bytes = try std.math.add(usize, var_ref_bytes, open_bytes);
        const ptr_value_slots = try std.math.divCeil(usize, ptr_bytes, @sizeOf(JSValue));
        return try std.math.add(usize, value_count, ptr_value_slots);
    }

    /// Partition caller-owned backing into the same typed windows as
    /// `allocHeap`. The caller retains the allocation itself; Frame teardown
    /// releases only the values/cells stored in the windows.
    pub fn partitionStorage(
        storage: []JSValue,
        arg_count: usize,
        original_arg_count: usize,
        local_count: usize,
        stack_count: usize,
        var_ref_count: usize,
        open_var_ref_count: usize,
    ) FrameSlab {
        const value_count = arg_count + original_arg_count + local_count + stack_count;
        const var_ref_bytes = @sizeOf(*core.VarRef) * var_ref_count;
        const open_bytes = @sizeOf(?*core.VarRef) * open_var_ref_count;
        const ptr_value_slots = std.math.divCeil(usize, var_ref_bytes + open_bytes, @sizeOf(JSValue)) catch unreachable;
        std.debug.assert(storage.len == value_count + ptr_value_slots);

        var cursor: usize = 0;
        const args = storage[cursor .. cursor + arg_count];
        cursor += arg_count;
        const original_args = storage[cursor .. cursor + original_arg_count];
        cursor += original_arg_count;
        const locals = storage[cursor .. cursor + local_count];
        cursor += local_count;
        const stack = storage[cursor .. cursor + stack_count];
        cursor += stack_count;

        const ptr_region = std.mem.sliceAsBytes(storage[cursor .. cursor + ptr_value_slots]);
        const var_refs: []*core.VarRef = if (var_ref_count == 0)
            &.{}
        else
            std.mem.bytesAsSlice(*core.VarRef, ptr_region[0..var_ref_bytes]);
        const open_var_refs: []?*core.VarRef = if (open_var_ref_count == 0)
            &.{}
        else
            @alignCast(std.mem.bytesAsSlice(?*core.VarRef, ptr_region[var_ref_bytes..][0..open_bytes]));
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
        const value_count = std.math.add(usize, count_2, stack_count) catch return null;
        const var_ref_bytes = std.math.mul(usize, @sizeOf(*core.VarRef), var_ref_count) catch return null;
        const open_bytes = std.math.mul(usize, @sizeOf(?*core.VarRef), open_var_ref_count) catch return null;
        const ptr_bytes = std.math.add(usize, var_ref_bytes, open_bytes) catch return null;
        const ptr_value_slots = std.math.divCeil(usize, ptr_bytes, @sizeOf(JSValue)) catch return null;
        const slab_values = arena.carve(account, value_count + ptr_value_slots) orelse return null;

        var cursor: usize = 0;
        const args = slab_values[cursor .. cursor + arg_count];
        cursor += arg_count;
        const original_args = slab_values[cursor .. cursor + original_arg_count];
        cursor += original_arg_count;
        const locals = slab_values[cursor .. cursor + local_count];
        cursor += local_count;
        const stack = slab_values[cursor .. cursor + stack_count];
        cursor += stack_count;

        const ptr_region = std.mem.sliceAsBytes(slab_values[cursor .. cursor + ptr_value_slots]);
        const var_refs: []*core.VarRef = if (var_ref_count == 0)
            &.{}
        else
            std.mem.bytesAsSlice(*core.VarRef, ptr_region[0..var_ref_bytes]);
        // The open window starts at var_ref_bytes (a multiple of 8) inside the
        // 16-aligned region; the runtime offset erases the comptime alignment,
        // so re-assert the pointer alignment explicitly.
        const open_var_refs: []?*core.VarRef = if (open_var_ref_count == 0)
            &.{}
        else
            @alignCast(std.mem.bytesAsSlice(?*core.VarRef, ptr_region[var_ref_bytes..][0..open_bytes]));
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
        const total_value_slots = try requiredStorageSlots(arg_count, original_arg_count, local_count, stack_count, var_ref_count, open_var_ref_count);
        if (total_value_slots == 0) return .{};
        const storage = try account.alloc(JSValue, total_value_slots);
        errdefer account.free(JSValue, storage);
        return partitionStorage(storage, arg_count, original_arg_count, local_count, stack_count, var_ref_count, open_var_ref_count);
    }
};

pub const CallBindingInputs = struct {
    initial_this_value: JSValue,
    current_function_value: JSValue,
    new_target_value: JSValue,
    constructor_this_value: JSValue,
};

pub const CallBindingValueMode = enum {
    /// Retain a new frame-owned reference to the value.
    dup,
    /// Transfer an already-owned value into the frame.
    take,
    /// Keep a borrowed value rooted by the frame but do not release it.
    borrow,
};

/// Whether a live frame must release a reference when the binding/storage is
/// torn down. Keeping this as a type instead of a collection of unrelated
/// booleans makes every transfer site state its ownership decision explicitly.
pub const Ownership = enum(u1) {
    borrowed,
    owned,
};

/// The ordinary frame's three independent ownership decisions. This is the
/// execution-time counterpart of qjs's implicit call-frame contract:
///
/// - `this_value` may borrow a realm/lexical value or own a moved receiver;
/// - `var_refs` may borrow the closure capture array or own retained cells;
/// - `storage` borrows an arena window or owns a heap allocation.
///
/// One packed disposition replaces three booleans that previously had to stay
/// synchronized with Entry's fast-teardown discriminator.
pub const OwnershipDisposition = packed struct(u8) {
    this_value: Ownership = .owned,
    current_function: Ownership = .owned,
    var_refs: Ownership = .owned,
    storage: Ownership = .borrowed,
    _reserved: u4 = 0,
};

comptime {
    std.debug.assert(@sizeOf(OwnershipDisposition) == 1);
}

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

pub fn frameVarRefStorageCount(function: *const bytecode.Bytecode, inherited_var_refs: []const *core.VarRef) usize {
    if (inherited_var_refs.len != 0) return inherited_var_refs.len;
    if (function.closure_var.len != 0) return function.closure_var.len;
    return function.varRefNamesLen();
}

pub fn frameOpenVarRefStorageCount(function: *const bytecode.Bytecode) usize {
    return function.open_var_ref_count;
}

pub const FrameStorageWindows = struct {
    args: ?[]JSValue = null,
    original_args: ?[]JSValue = null,
    locals: ?[]JSValue = null,
    var_refs: ?[]*core.VarRef = null,
    open_var_refs: ?[]?*core.VarRef = null,
};

pub const Frame = struct {
    function: *const bytecode.Bytecode,
    pc: usize = 0,
    this_value: JSValue = JSValue.undefinedValue(),
    current_function: JSValue = JSValue.undefinedValue(),
    actual_arg_count: usize = 0,
    locals: []JSValue = &.{},
    args: []JSValue = &.{},
    /// Slot-typed var-ref array — qjs `JSVarRef **var_refs` (JS_CallInternal
    /// prologue `var_refs = p->u.func.var_refs`, quickjs.c:17844). Every
    /// element is a live cell by construction (js_closure2 fills every slot
    /// with a real JSVarRef*, quickjs.c:17297-17331); the pre-typed per-read
    /// "is this slot a cell" discrimination is gone with the type
    /// (VARREFS-SLOT-TYPING-BLUEPRINT phase D).
    var_refs: []*core.VarRef = &.{},
    open_var_refs: []?*core.VarRef = &.{},
    storage_values: []JSValue = &.{},
    /// Records whether `this_value`, `var_refs`, and `storage_values` are
    /// borrowed or owned. A borrowed var-ref slice aliases the callee captures;
    /// borrowed storage is an arena window. Teardown consults only this value.
    ownership: OwnershipDisposition = .{},
    /// Lazily-allocated side-struct holding the cold per-frame state a plain
    /// inline call (fib, ordinary closures) never touches: the
    /// derived-constructor `this`, the `arguments` object, and the original-args
    /// snapshot. `null` on the common path, so `Frame.init` writes one null
    /// pointer and keeps this state off the hot frame.
    cold: ?*FrameCold = null,

    pub const FrameCold = struct {
        new_target: JSValue = JSValue.undefinedValue(),
        constructor_this_value: JSValue = JSValue.undefinedValue(),
        constructor_this_value_ownership: Ownership = .borrowed,
        arguments_object: ?JSValue = null,
        original_args: []JSValue = &.{},
    };

    /// Allocate `cold` on first use. The new struct is fully defaulted.
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
    /// `this`, the `arguments` object, and the original-args snapshot VALUES)
    /// then free the box. Idempotent. `original_args` VALUES must be released
    /// BEFORE the storage backing them is reclaimed — call this before freeing
    /// `storage_values`.
    pub fn freeCold(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        const c = self.cold orelse return;
        if (c.constructor_this_value_ownership == .owned) c.constructor_this_value.free(rt);
        if (c.arguments_object) |value| value.free(rt);
        releaseValueSliceNoReset(rt, c.original_args);
        account.destroy(FrameCold, c);
        self.cold = null;
    }

    /// Release ONLY the storage-coupled cold state — the original-args snapshot
    /// VALUES — resetting that field to its default while KEEPING the box and the
    /// ctor / arguments state. This matches the old `releaseOwnedStorage`
    /// semantics, which reset original_args but left ctor_this/
    /// arguments_object intact so a suspended generator retains them across resume.
    pub fn releaseColdStorage(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        _ = account;
        const c = self.cold orelse return;
        releaseValueSliceNoReset(rt, c.original_args);
        c.original_args = &.{};
    }

    // ---- Cold-field read accessors (return the default when `cold == null`) ----
    pub inline fn constructorThisValue(self: *const Frame) JSValue {
        return if (self.cold) |c| c.constructor_this_value else JSValue.undefinedValue();
    }
    pub inline fn newTargetValue(self: *const Frame) JSValue {
        return if (self.cold) |c| c.new_target else JSValue.undefinedValue();
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

    /// Build the borrowed call-binding shell used to resume a resident
    /// generator/async frame. The execution record owns `this` and `cur_func`;
    /// unlike a fresh call there is no constructor binding to allocate and no
    /// reference-count traffic to perform.
    pub inline fn initResidentExecution(
        function: *const bytecode.Bytecode,
        this_value: JSValue,
        current_function: JSValue,
        actual_arg_count: usize,
    ) Frame {
        return .{
            .function = function,
            .this_value = this_value,
            .current_function = current_function,
            .actual_arg_count = actual_arg_count,
            .ownership = .{
                .this_value = .borrowed,
                .current_function = .borrowed,
            },
        };
    }

    /// A suspension (and the resident completion handoff) moves every storage
    /// window back to GeneratorExecutionState before this temporary Frame
    /// unwinds. The two call bindings are borrowed from that same record, so an
    /// empty shell has no teardown work at all.
    pub inline fn isEmptyResidentExecutionShell(self: *const Frame) bool {
        return self.ownership.this_value == .borrowed and
            self.ownership.current_function == .borrowed and
            self.ownership.storage == .borrowed and
            self.storage_values.len == 0 and
            self.locals.len == 0 and
            self.args.len == 0 and
            self.var_refs.len == 0 and
            self.open_var_refs.len == 0 and
            self.cold == null;
    }

    pub fn initCallBindings(self: *Frame, rt: *JSRuntime, inputs: CallBindingInputs) !void {
        errdefer self.releaseCallBindings(rt);
        try self.initCallBindingValues(&rt.memory, inputs, .{});
    }

    pub fn initCallBindingValues(self: *Frame, account: *memory.MemoryAccount, inputs: CallBindingInputs, modes: CallBindingModes) !void {
        // Allocate the only fallible part before retaining or taking any call
        // binding. On OOM the caller must still own every input unchanged.
        const binding_cold = if (inputs.constructor_this_value.isUndefined() and inputs.new_target_value.isUndefined())
            null
        else
            try self.ensureCold(account);
        self.this_value = bindCallValue(inputs.initial_this_value, modes.this_value);
        self.current_function = bindCallValue(inputs.current_function_value, modes.current_function);
        self.ownership.this_value = modeOwnership(modes.this_value);
        self.ownership.current_function = modeOwnership(modes.current_function);
        // ctor_this is undefined for every non-derived-constructor frame (owned
        // undefined is a no-op to free), so only materialize `cold` when it is a
        // real value. The inline path never reaches here (no derived ctors inline).
        if (binding_cold) |c| {
            c.new_target = inputs.new_target_value;
            if (!inputs.constructor_this_value.isUndefined()) {
                c.constructor_this_value = bindCallValue(inputs.constructor_this_value, modes.constructor_this_value);
                c.constructor_this_value_ownership = modeOwnership(modes.constructor_this_value);
            }
        }
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
            if (stack.len() < argc) return error.StackUnderflow;
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
        // Publish the destructor owner before copying any references into the
        // snapshot window. If allocating the cold box fails, every source and
        // pre-carved destination slot must remain untouched.
        const cold = try self.ensureCold(account);
        const original_args = if (window) |values| blk: {
            std.debug.assert(values.len == args.len);
            break :blk values;
        } else blk: {
            _ = use_inline_storage;
            break :blk try self.allocOwnedStorage(account, args.len);
        };
        for (args, 0..) |arg, idx| original_args[idx] = arg.dup();
        cold.original_args = original_args;
    }

    pub fn installOwnedStorage(self: *Frame, storage: []JSValue) void {
        std.debug.assert(self.ownership.storage == .borrowed);
        self.storage_values = storage;
        self.ownership.storage = if (storage.len != 0) .owned else .borrowed;
    }

    pub fn installResidentStorage(self: *Frame, storage: []JSValue) void {
        std.debug.assert(self.ownership.storage == .borrowed);
        self.storage_values = storage;
    }

    pub fn allocOwnedStorage(self: *Frame, account: *memory.MemoryAccount, count: usize) ![]JSValue {
        const values = try account.alloc(JSValue, count);
        if (self.ownership.storage == .owned and self.storage_values.len != 0) {
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
        const this_value_ownership = self.ownership.this_value;
        const current_function_ownership = self.ownership.current_function;
        self.this_value = JSValue.undefinedValue();
        self.current_function = JSValue.undefinedValue();
        self.ownership.this_value = .owned;
        self.ownership.current_function = .owned;
        // Frees constructor/arguments cold state and the box.
        self.freeCold(&rt.memory, rt);
        if (this_value_ownership == .owned) this_value.free(rt);
        if (current_function_ownership == .owned) current_function.free(rt);
    }

    pub fn deinit(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        const this_value = self.this_value;
        const current_function = self.current_function;
        const this_value_ownership = self.ownership.this_value;
        const current_function_ownership = self.ownership.current_function;
        self.this_value = JSValue.undefinedValue();
        self.current_function = JSValue.undefinedValue();
        self.ownership.this_value = .owned;
        self.ownership.current_function = .owned;

        if (this_value_ownership == .owned) this_value.free(rt);
        if (current_function_ownership == .owned) current_function.free(rt);

        // releaseOwnedStorage frees the storage slices + clears the storage-coupled
        // cold state (original_args/sync). Then free the rest of cold (ctor_this,
        // arguments_object) + the box — full teardown, no resume to retain it for.
        self.releaseOwnedStorage(account, rt);
        self.freeCold(account, rt);
    }

    pub inline fn deinitInlineCall(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        if (self.ownership.this_value == .owned) self.this_value.free(rt);
        if (self.ownership.current_function == .owned) self.current_function.free(rt);

        if (self.open_var_refs.len != 0) self.closeOpenVarRefs(rt);

        releaseValueSliceNoReset(rt, self.locals);
        releaseValueSliceNoReset(rt, self.args);
        // freeCold releases original_args VALUES before the storage backing them
        // is freed below; also frees ctor_this/arguments_object + sync allocs + box.
        if (self.cold != null) self.freeCold(account, rt);
        // Borrowed var_refs alias the closure's captures (owned by the still-live
        // function object); freeing them here would double-free on the next call.
        // Owned slots release per cell (qjs free_var_ref, quickjs.c:16199).
        if (self.ownership.var_refs == .owned) releaseCellSliceNoReset(rt, self.var_refs);

        if (self.ownership.storage == .owned and self.storage_values.len != 0) account.free(JSValue, self.storage_values);
    }

    pub fn releaseOwnedStorage(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        self.closeOpenVarRefs(rt);
        const locals = self.locals;
        const args = self.args;
        // A borrowed var_refs aliases the closure captures (not owned here).
        const var_refs: []*core.VarRef = if (self.ownership.var_refs == .borrowed) &.{} else self.var_refs;
        const storage_values = self.storage_values;
        const storage_ownership = self.ownership.storage;

        self.locals = &.{};
        self.args = &.{};
        self.var_refs = &.{};
        self.ownership.var_refs = .owned;
        self.open_var_refs = &.{};
        self.storage_values = &.{};
        self.ownership.storage = .borrowed;

        releaseValueSlice(rt, locals);
        releaseValueSlice(rt, args);
        releaseCellSliceNoReset(rt, var_refs);
        // Frees original_args VALUES (which alias `storage_values`/the arena slab)
        // before the storage backing is reclaimed below. Keeps the cold box so a
        // generator retains constructor/arguments state across resume.
        if (self.cold != null) self.releaseColdStorage(account, rt);

        if (storage_ownership == .owned and storage_values.len != 0) account.free(JSValue, storage_values);
    }

    pub fn closeOpenVarRefs(self: *Frame, rt: anytype) void {
        var table = open_bindings_mod.Table{ .cells = self.open_var_refs };
        table.closeAll(rt);
    }

    pub fn captureLocal(self: *Frame, rt: anytype, local_idx: usize) !*core.VarRef {
        if (local_idx >= self.locals.len or local_idx >= self.function.vardefs.len) return error.InvalidBytecode;
        if (core.VarRef.fromValue(self.locals[local_idx]) != null) return error.InvalidBytecode;
        const binding_idx = self.function.localOpenBindingIndex(local_idx) orelse return error.InvalidBytecode;
        const vd = self.function.vardefs[local_idx];
        var table = open_bindings_mod.Table{ .cells = self.open_var_refs };
        return table.acquire(rt, binding_idx, &self.locals[local_idx], .{
            .is_const = vd.is_const,
            .is_lexical = vd.is_lexical,
            .is_function_name = vd.var_kind == .function_name,
        });
    }

    pub fn captureArg(self: *Frame, rt: anytype, arg_idx: usize) !*core.VarRef {
        if (arg_idx >= self.args.len) return error.InvalidBytecode;
        if (core.VarRef.fromValue(self.args[arg_idx]) != null) return error.InvalidBytecode;
        const binding_idx = self.function.argOpenBindingIndex(arg_idx) orelse return error.InvalidBytecode;
        var table = open_bindings_mod.Table{ .cells = self.open_var_refs };
        return table.acquire(rt, binding_idx, &self.args[arg_idx], .{});
    }

    pub fn closeLocalBinding(self: *Frame, rt: anytype, local_idx: usize) !void {
        if (local_idx >= self.locals.len or local_idx >= self.function.vardefs.len) return error.InvalidBytecode;
        const binding_idx = self.function.localOpenBindingIndex(local_idx) orelse return;
        var table = open_bindings_mod.Table{ .cells = self.open_var_refs };
        try table.close(rt, binding_idx);
    }

    /// Close parameter-environment aliases at the generator body boundary
    /// while retaining aliases into the resident argument backing.
    pub fn closeParameterEnvironmentVarRefs(self: *Frame, rt: anytype) !void {
        var table = open_bindings_mod.Table{ .cells = self.open_var_refs };
        for (self.function.vardefs) |vd| {
            if (vd.open_binding_idx == bytecode.function_bytecode.no_open_binding) continue;
            try table.close(rt, vd.open_binding_idx);
        }
    }

    pub fn installOpenVarRefSlots(self: *Frame, slots: []?*core.VarRef) !void {
        if (slots.len != self.function.open_var_ref_count) return error.InvalidBytecode;
        self.open_var_refs = slots;
        @memset(self.open_var_refs, null);
    }

    pub fn ensureOpenVarRefSlots(
        self: *Frame,
        account: *memory.MemoryAccount,
        arena: ?*runtime.VmStackArena,
        use_inline_storage: bool,
    ) !void {
        const count = self.function.open_var_ref_count;
        if (self.open_var_refs.len != 0) {
            if (self.open_var_refs.len != count) return error.InvalidBytecode;
            return;
        }
        if (count == 0) return;
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

    pub fn setLocal(self: *Frame, account: *memory.MemoryAccount, rt: anytype, index: usize, value: JSValue) !void {
        try growLocalsCapacity(account, self, index);
        value_slot.replaceBorrowed(rt, &self.locals[index], value);
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

    /// Per-cell release for an owned var_refs slice (qjs frees each
    /// `var_refs[i]` via free_var_ref at frame exit, quickjs.c:16199/20698).
    /// The slice memory itself lives in the frame slab / storage_values.
    inline fn releaseCellSliceNoReset(rt: anytype, cells: []*core.VarRef) void {
        for (cells) |cell| {
            cell.freeCell(rt);
        }
    }
};

fn bindCallValue(value: JSValue, mode: CallBindingValueMode) JSValue {
    return switch (mode) {
        .dup => value.dup(),
        .take, .borrow => value,
    };
}

fn modeOwnership(mode: CallBindingValueMode) Ownership {
    return if (mode == .borrow) .borrowed else .owned;
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
    try std.testing.expectEqual(Ownership.owned, exec_frame.ownership.storage);
}

// Frame capacity helpers (moved from the dissolved exec/vm_utils.zig).

pub fn ensureLocalsCapacity(ctx: *core.JSContext, frame: *Frame, idx: usize) !void {
    try growLocalsCapacity(&ctx.runtime.memory, frame, idx);
}

pub fn ensureVarRefsCapacity(ctx: *core.JSContext, frame: *Frame, idx: usize) !void {
    if (idx < frame.var_refs.len) return;
    const next_len = try std.math.add(usize, idx, 1);
    const old_storage = frame.storage_values;
    const old_storage_ownership = frame.ownership.storage;
    // A heap FrameSlab is one allocation shared by locals/args/stack and the
    // typed pointer tails. Replacing only var_refs cannot free that slab while
    // the other live windows still point into it. Normal compiled bytecode is
    // sized exactly, so reject this malformed/synthetic growth case instead of
    // manufacturing dangling frame slices.
    if (old_storage_ownership == .owned and old_storage.len != 0 and !ownedStorageContainsOnlyVarRefs(frame)) {
        return error.InvalidBytecode;
    }
    // The typed window keeps the "var_refs lives inside a []JSValue storage
    // allocation" invariant (like the slab carve), so the uniform
    // storage_values free path still owns the memory: allocate value slots
    // covering next_len pointer slots and window them.
    const ptr_bytes = try std.math.mul(usize, @sizeOf(*core.VarRef), next_len);
    const value_slots = try std.math.divCeil(usize, ptr_bytes, @sizeOf(core.JSValue));
    const next_storage = try ctx.runtime.memory.alloc(core.JSValue, value_slots);
    errdefer ctx.runtime.memory.free(core.JSValue, next_storage);
    const next: []*core.VarRef = std.mem.bytesAsSlice(*core.VarRef, std.mem.sliceAsBytes(next_storage)[0..ptr_bytes]);
    // Backfill slots are fresh closed cells holding undefined, never raw
    // slots: the slot contract is "every slot is a live JSVarRef*" (qjs
    // js_closure2 fills every slot with a real cell, quickjs.c:17297-17331).
    // Legacy/synthetic bytecode may still request a sparse index; normal parser
    // output sizes var_refs once during frame construction like qjs.
    const old_len = frame.var_refs.len;
    const borrowed_cells = frame.ownership.var_refs == .borrowed;
    for (frame.var_refs, 0..) |cell, i| {
        next[i] = if (borrowed_cells) cell.dupCell() else cell;
    }
    var filled: usize = old_len;
    errdefer {
        if (borrowed_cells) {
            for (next[0..old_len]) |cell| cell.freeCell(ctx.runtime);
        }
        for (next[old_len..filled]) |cell| cell.freeCell(ctx.runtime);
    }
    while (filled < next_len) : (filled += 1) {
        next[filled] = try core.VarRef.createClosed(ctx.runtime, core.JSValue.undefinedValue());
    }
    frame.var_refs = next;
    frame.ownership.var_refs = .owned;
    frame.storage_values = next_storage;
    frame.ownership.storage = .owned;
    if (old_storage.len != 0 and old_storage_ownership == .owned) ctx.runtime.memory.free(core.JSValue, old_storage);
}

fn growLocalsCapacity(account: *memory.MemoryAccount, frame: *Frame, idx: usize) !void {
    if (idx < frame.locals.len) return;
    const next_len = try std.math.add(usize, idx, 1);
    const old_storage = frame.storage_values;
    const old_storage_ownership = frame.ownership.storage;
    if (old_storage_ownership == .owned and old_storage.len != 0 and !ownedStorageContainsOnlyLocals(frame)) {
        return error.InvalidBytecode;
    }

    // Published local addresses are stable for the lifetime of an open cell.
    // Production frames are pre-sized; synthetic builders may grow only before
    // the first capture. Check before allocating so malformed bytecode cannot
    // turn this invariant failure into an allocation-dependent error.
    var open_table = open_bindings_mod.Table{ .cells = frame.open_var_refs };
    if (open_table.hasOpen()) return error.InvalidBytecode;

    const old_locals = frame.locals;
    const next = try account.alloc(JSValue, next_len);
    errdefer account.free(JSValue, next);
    if (old_locals.len != 0) @memcpy(next[0..old_locals.len], old_locals);
    @memset(next[old_locals.len..], JSValue.undefinedValue());

    frame.locals = next;
    frame.storage_values = next;
    frame.ownership.storage = .owned;
    if (old_storage.len != 0 and old_storage_ownership == .owned) account.free(JSValue, old_storage);
}

fn ownedStorageContainsOnlyLocals(frame: *const Frame) bool {
    const storage = frame.storage_values;
    if (storage.len == 0 or frame.locals.len == 0) return false;
    if (@intFromPtr(storage.ptr) != @intFromPtr(frame.locals.ptr)) return false;
    if (storage.len != frame.locals.len) return false;
    return !sliceOverlapsStorage(JSValue, frame.args, storage) and
        !sliceOverlapsStorage(JSValue, frame.originalArgs(), storage) and
        !sliceOverlapsStorage(*core.VarRef, frame.var_refs, storage) and
        !sliceOverlapsStorage(?*core.VarRef, frame.open_var_refs, storage);
}

fn ownedStorageContainsOnlyVarRefs(frame: *const Frame) bool {
    const storage = frame.storage_values;
    if (storage.len == 0 or frame.var_refs.len == 0) return false;
    if (@intFromPtr(storage.ptr) != @intFromPtr(frame.var_refs.ptr)) return false;
    const ptr_bytes = std.math.mul(usize, @sizeOf(*core.VarRef), frame.var_refs.len) catch return false;
    const value_slots = std.math.divCeil(usize, ptr_bytes, @sizeOf(JSValue)) catch return false;
    if (storage.len != value_slots) return false;
    return !sliceOverlapsStorage(JSValue, frame.locals, storage) and
        !sliceOverlapsStorage(JSValue, frame.args, storage) and
        !sliceOverlapsStorage(JSValue, frame.originalArgs(), storage) and
        !sliceOverlapsStorage(?*core.VarRef, frame.open_var_refs, storage);
}

fn sliceOverlapsStorage(comptime T: type, values: []const T, storage: []const JSValue) bool {
    if (values.len == 0 or storage.len == 0) return false;
    const value_bytes = std.math.mul(usize, @sizeOf(T), values.len) catch return true;
    const storage_bytes = std.math.mul(usize, @sizeOf(JSValue), storage.len) catch return true;
    const value_start = @intFromPtr(values.ptr);
    const storage_start = @intFromPtr(storage.ptr);
    const value_end = std.math.add(usize, value_start, value_bytes) catch return true;
    const storage_end = std.math.add(usize, storage_start, storage_bytes) catch return true;
    return value_start < storage_end and storage_start < value_end;
}
