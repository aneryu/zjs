//! Owned execution state parked while generators and async functions suspend.

const payloads = @import("object_payloads.zig");
const runtime_mod = @import("runtime.zig");
const var_ref_mod = @import("var_ref.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const std = @import("std");
const builtin = @import("builtin");

const closeOpenVarRefCellSlots = payloads.closeOpenVarRefCellSlots;
const callVisitValue = payloads.callVisitValue;
const destroyOptionalValue = payloads.destroyOptionalValue;
const traceOptValue = payloads.traceOptValue;
const destroyOwnedValue = payloads.destroyOwnedValue;
const destroyValueSlice = payloads.destroyValueSlice;
const destroyValueSliceValuesOnly = payloads.destroyValueSliceValuesOnly;
const destroyValueSliceWithCapacity = payloads.destroyValueSliceWithCapacity;
const destroyVarRefCellSliceValuesOnly = payloads.destroyVarRefCellSliceValuesOnly;

/// One queued async-generator request (mirrors qjs JSAsyncGeneratorRequest,
/// quickjs.c:21354): completion type (GEN_MAGIC next=0 / return=1 / throw=2),
/// the completion argument, and the request's promise capability.
pub const AsyncGeneratorRequest = struct {
    completion_type: i32,
    result: JSValue,
    promise: JSValue,
    resolve: JSValue,
    reject: JSValue,
};

/// How a generator/async frame last suspended (zjs adaptation of qjs
/// FUNC_RET_YIELD / FUNC_RET_YIELD_STAR / FUNC_RET_AWAIT return codes,
/// quickjs.c:17735-17738): written by the save sites in vm_gen_async.zig,
/// read by the async-generator driver to discriminate the suspension.
pub const GeneratorSuspendKind = enum(u8) {
    none = 0,
    yield = 1,
    yield_star = 2,
    await_op = 3,
};

/// Owned operand-stack buffer parked while a generator/async frame is
/// suspended. `values` is the live prefix; `capacity` describes the backing
/// allocation when non-zero.
pub const SuspendedStackStorage = struct {
    values: []JSValue = &.{},
    capacity: usize = 0,

    /// Grow the parked stack without changing ownership on failure. Values are
    /// moved as raw slots (no dup/free); only the backing allocation changes.
    pub fn ensureAdditional(self: *SuspendedStackStorage, rt: *JSRuntime, limit: usize, additional: usize) !void {
        return self.ensureAdditionalWithResidentBacking(rt, limit, additional, false);
    }

    /// `resident_backing` means the current buffer is trailing storage in its
    /// GeneratorExecutionState allocation. Growth migrates the live prefix to
    /// a normal owned buffer but leaves that region for the record destructor.
    pub fn ensureAdditionalWithResidentBacking(self: *SuspendedStackStorage, rt: *JSRuntime, limit: usize, additional: usize, resident_backing: bool) !void {
        if (self.values.len > limit) return error.StackOverflow;
        if (additional > limit - self.values.len) return error.StackOverflow;
        const needed = self.values.len + additional;
        if (needed <= self.capacity) return;

        var next_capacity = if (self.capacity == 0) @min(@as(usize, 8), limit) else self.capacity;
        while (next_capacity < needed) {
            if (next_capacity > limit / 2) {
                next_capacity = limit;
                break;
            }
            next_capacity *= 2;
        }
        const next = try rt.memory.alloc(JSValue, next_capacity);
        errdefer rt.memory.free(JSValue, next);
        if (comptime builtin.is_test or std.mem.eql(u8, @import("build_options").zjs_gc, "shadow")) {
            @import("gc_write_audit.zig").hit(.memcpy_bulk, .generator_values_memcpy);
        }
        @memcpy(next[0..self.values.len], self.values);
        const old_values = self.values;
        const old_capacity = self.capacity;
        self.values = next[0..old_values.len];
        self.capacity = next_capacity;
        if (old_capacity != 0 and !resident_backing) {
            rt.memory.free(JSValue, old_values.ptr[0..old_capacity]);
        } else if (old_capacity == 0 and old_values.len != 0) {
            rt.memory.free(JSValue, old_values);
        }
    }

    pub fn deinit(self: *SuspendedStackStorage, rt: *JSRuntime) void {
        destroyValueSliceWithCapacity(rt, &self.values, &self.capacity);
    }

    pub fn isEmpty(self: *const SuspendedStackStorage) bool {
        return self.values.len == 0 and self.capacity == 0;
    }
};

/// Owned frame slab and its typed live windows while execution is suspended.
/// When `storage` is non-empty the other slices borrow windows inside it; a
/// storage-less state may own separate locals/args slices, while var-ref and
/// open-var-ref slots release cells only because their slot memory is never
/// standalone. Open cells continue pointing into `locals`/`args`; preserving
/// the unchanged slab therefore preserves their qjs-style live aliases.
pub const SuspendedFrameStorage = struct {
    storage: []JSValue = &.{},
    locals: []JSValue = &.{},
    args: []JSValue = &.{},
    var_refs: []*var_ref_mod.VarRef = &.{},
    open_var_refs: []?*var_ref_mod.VarRef = &.{},

    pub fn deinit(self: *SuspendedFrameStorage, rt: *JSRuntime) void {
        const owned = self.*;
        self.* = .{};
        var locals = owned.locals;
        var args = owned.args;
        var var_refs = owned.var_refs;
        // Close while the aliased local/argument slots are still live, then
        // release their values and finally the shared slab backing.
        closeOpenVarRefCellSlots(rt, owned.open_var_refs);
        if (owned.storage.len != 0) {
            destroyValueSliceValuesOnly(rt, &locals);
            destroyValueSliceValuesOnly(rt, &args);
            destroyVarRefCellSliceValuesOnly(rt, &var_refs);
            rt.memory.free(JSValue, owned.storage);
            return;
        }
        destroyValueSlice(rt, &locals);
        destroyValueSlice(rt, &args);
        destroyVarRefCellSliceValuesOnly(rt, &var_refs);
    }

    /// Release the live window contents while leaving the backing bytes to the
    /// surrounding GeneratorExecutionState FAM allocation.
    pub fn deinitResident(self: *SuspendedFrameStorage, rt: *JSRuntime) void {
        const owned = self.*;
        self.* = .{};
        var locals = owned.locals;
        var args = owned.args;
        var var_refs = owned.var_refs;
        closeOpenVarRefCellSlots(rt, owned.open_var_refs);
        destroyValueSliceValuesOnly(rt, &locals);
        destroyValueSliceValuesOnly(rt, &args);
        destroyVarRefCellSliceValuesOnly(rt, &var_refs);
    }

    pub fn isEmpty(self: *const SuspendedFrameStorage) bool {
        return self.storage.len == 0 and self.locals.len == 0 and
            self.args.len == 0 and self.var_refs.len == 0 and
            self.open_var_refs.len == 0;
    }
};

/// All buffer ownership parked while a generator is suspended. Program-counter
/// state intentionally lives one level above this record: resume moves these
/// buffers into live exec owners while finally/catch drivers continue reading
/// the payload's pc, matching qjs retaining `cur_pc` while `cur_sp == NULL`.
pub const SuspendedExecutionStorage = struct {
    stack: SuspendedStackStorage = .{},
    frame: SuspendedFrameStorage = .{},

    /// Exchange ownership field-wise. `std.mem.swap` lowers this wide
    /// record to a short-element loop in ReleaseFast, and save sites execute
    /// that loop at every yield/await suspension.
    fn swapOwned(self: *SuspendedExecutionStorage, other: *SuspendedExecutionStorage) void {
        const stack_values = self.stack.values;
        self.stack.values = other.stack.values;
        other.stack.values = stack_values;

        const stack_capacity = self.stack.capacity;
        self.stack.capacity = other.stack.capacity;
        other.stack.capacity = stack_capacity;

        const frame_storage = self.frame.storage;
        self.frame.storage = other.frame.storage;
        other.frame.storage = frame_storage;

        const frame_locals = self.frame.locals;
        self.frame.locals = other.frame.locals;
        other.frame.locals = frame_locals;

        const frame_args = self.frame.args;
        self.frame.args = other.frame.args;
        other.frame.args = frame_args;

        const frame_var_refs = self.frame.var_refs;
        self.frame.var_refs = other.frame.var_refs;
        other.frame.var_refs = frame_var_refs;

        const frame_open_var_refs = self.frame.open_var_refs;
        self.frame.open_var_refs = other.frame.open_var_refs;
        other.frame.open_var_refs = frame_open_var_refs;
    }

    pub fn deinit(self: *SuspendedExecutionStorage, rt: *JSRuntime) void {
        // Resume normally takes every parked buffer before the next save. In
        // that overwhelmingly common case there is no previous owner to tear
        // down; avoid copying/resetting the full record just to discover that
        // all seven ownership fields are empty.
        if (self.isEmpty()) return;
        const owned = self.*;
        self.* = .{};
        var stack = owned.stack;
        var frame = owned.frame;
        stack.deinit(rt);
        frame.deinit(rt);
    }

    /// Move this storage into an empty destination.
    pub fn moveInto(self: *SuspendedExecutionStorage, destination: *SuspendedExecutionStorage) void {
        std.debug.assert(self != destination);
        std.debug.assert(destination.isEmpty());
        self.swapOwned(destination);
    }

    pub fn isEmpty(self: *const SuspendedExecutionStorage) bool {
        return self.stack.isEmpty() and self.frame.isEmpty();
    }
};

/// The single execution record parked in a generator payload. This is a
/// core-neutral precursor to qjs's resident `JSAsyncFunctionState.frame`.
pub const SuspendedExecutionState = struct {
    pc: usize = 0,
    storage: SuspendedExecutionStorage = .{},
    /// Authoritative dynamic catch target observed when the frame was parked.
    /// `maxInt(u32)` is the null sentinel; bytecode offsets are u32-addressable.
    /// A shared finalizer PC has multiple possible incoming catch states, so
    /// resume must restore this scalar instead of inferring it from `pc`.
    catch_target_pc: u32 = no_suspended_catch_target,
    /// A resident frame exists even when every window is zero length and pc is
    /// zero. This is the zjs counterpart of qjs `func_state != NULL`; neither
    /// the program counter nor storage emptiness can represent that state.
    has_frame: bool = false,
    /// While true, the parked storage is installed in a live exec Frame/Stack.
    /// Legacy/standalone states temporarily hand ownership to those views;
    /// FAM-backed generator states keep ownership resident and lend borrowed
    /// views, matching qjs `JSAsyncFunctionState.frame` with `cur_sp == NULL`.
    running_aliases: bool = false,
    /// The parked record remains the backing owner while `running_aliases` is
    /// true. This is enabled after the first suspension proves that the normal
    /// generator's stack and frame still occupy their combined FAM windows.
    resident_storage_owner: bool = false,

    pub fn deinit(self: *SuspendedExecutionState, rt: *JSRuntime) void {
        if (self.running_aliases) {
            std.debug.assert(!self.resident_storage_owner);
            // The active Frame/Stack owns these aliases and tears them down.
            // A running generator is normally rooted, but keeping deinit
            // ownership-safe prevents a double free if teardown is forced.
            self.storage = .{};
            self.running_aliases = false;
        } else {
            self.storage.deinit(rt);
        }
        self.pc = 0;
        self.catch_target_pc = no_suspended_catch_target;
        self.has_frame = false;
        self.resident_storage_owner = false;
    }

    /// Mark the parked storage as aliases of the newly-installed live owners.
    /// No GC point may occur between installing the views and this call.
    pub fn beginRunningAliases(self: *SuspendedExecutionState) void {
        std.debug.assert(!self.running_aliases);
        self.running_aliases = true;
    }

    /// A run completed or failed without suspending. Drop the stale aliases;
    /// the live Frame/Stack remains responsible for releasing the buffers.
    pub fn finishRunningAliases(self: *SuspendedExecutionState) void {
        if (!self.running_aliases) return;
        self.running_aliases = false;
        self.has_frame = false;
        self.catch_target_pc = no_suspended_catch_target;
        if (self.resident_storage_owner) return;
        self.storage = .{};
    }

    pub fn catchTarget(self: *const SuspendedExecutionState) ?usize {
        if (self.catch_target_pc == no_suspended_catch_target) return null;
        return self.catch_target_pc;
    }

    /// Publish replacement storage and pc before destroying the old buffers;
    /// cleanup-time GC therefore observes the new authoritative state.
    pub fn replaceStorageOwned(self: *SuspendedExecutionState, pc: usize, catch_target_pc: u32, replacement: *SuspendedExecutionStorage, rt: *JSRuntime) void {
        std.debug.assert(&self.storage != replacement);
        if (self.running_aliases) {
            // The old fields are aliases of the same live owners (and may be
            // stale if the operand stack grew). Publish the current views with
            // direct ownership transfer; never inspect or destroy the aliases.
            self.storage = replacement.*;
            replacement.* = .{};
            self.pc = pc;
            self.catch_target_pc = catch_target_pc;
            self.has_frame = true;
            self.running_aliases = false;
            self.resident_storage_owner = false;
            return;
        }
        self.storage.swapOwned(replacement);
        self.pc = pc;
        self.catch_target_pc = catch_target_pc;
        self.has_frame = true;
        self.resident_storage_owner = false;
        // The normal resume path emptied the previous parked owner. Test at
        // the publication seam so that case does not enter the heavyweight
        // generic destructor prologue at all.
        if (!replacement.isEmpty()) replacement.deinit(rt);
    }
};

const no_suspended_catch_target = std.math.maxInt(u32);

pub const empty_suspended_execution_state: SuspendedExecutionState = .{};

/// The separately-owned qjs `JSAsyncFunctionState` analogue.  A live
/// generator points at one of these; completion destroys it and leaves only
/// the compact `GeneratorPayload` state discriminator on the iterator object,
/// matching `JSGeneratorData { state, func_state }`.
pub const GeneratorExecutionState = struct {
    suspended: SuspendedExecutionState = .{},
    // qjs stores these as raw JSValue slots with JS_UNDEFINED as the empty
    // sentinel. Avoiding Zig optionals keeps the resident state in the same
    // 160-byte slab class as its qjs-style field set.
    this_value: JSValue = JSValue.undefinedValue(),
    current_function: JSValue = JSValue.undefinedValue(),
    yield_star_iterator: JSValue = JSValue.undefinedValue(),
    /// qjs JSAsyncFunctionState.argc. Once parameter initialization parks the
    /// resident frame, the separate input slice is gone; this scalar preserves
    /// mapped/unmapped `arguments` actual-count semantics on resume.
    actual_arg_count: u16 = 0,
    /// Operand-stack slots trailing this record in the same allocation. Zero
    /// denotes the standalone record used by internal hand-built continuations.
    combined_stack_slots: u16 = 0,
    /// Frame args/locals/var-ref slots immediately following the stack region.
    /// The high bit is the completion-pending flag, keeping the record's tail
    /// at four bytes while allowing strict generators with >32K actual args to
    /// retain both args and their required original-args snapshot. A u16 count
    /// incorrectly rejected those ordinary calls even though qjs accepts up to
    /// JS_MAX_LOCAL_VARS (65534) actual arguments.
    combined_frame_metadata: u32 = 0,

    const completion_pending_bit: u32 = 1 << 31;
    const frame_slot_count_mask: u32 = completion_pending_bit - 1;

    fn combinedFrameSlotCount(self: *const GeneratorExecutionState) usize {
        return self.combined_frame_metadata & frame_slot_count_mask;
    }

    pub fn completionPending(self: *const GeneratorExecutionState) bool {
        return self.combined_frame_metadata & completion_pending_bit != 0;
    }

    pub fn setCompletionPending(self: *GeneratorExecutionState, pending: bool) void {
        if (pending) {
            self.combined_frame_metadata |= completion_pending_bit;
        } else {
            self.combined_frame_metadata &= frame_slot_count_mask;
        }
    }

    fn combinedStackStorage(self: *GeneratorExecutionState) []JSValue {
        if (self.combined_stack_slots == 0) return &.{};
        const base: [*]u8 = @ptrCast(self);
        const slots: [*]JSValue = @ptrCast(@alignCast(base + generator_execution_storage_offset));
        return slots[0..self.combined_stack_slots];
    }

    pub fn combinedFrameStorage(self: *GeneratorExecutionState) []JSValue {
        const frame_slot_count = self.combinedFrameSlotCount();
        if (frame_slot_count == 0) return &.{};
        const base: [*]u8 = @ptrCast(self);
        const stack_bytes = @as(usize, self.combined_stack_slots) * @sizeOf(JSValue);
        const slots: [*]JSValue = @ptrCast(@alignCast(base + generator_execution_storage_offset + stack_bytes));
        return slots[0..frame_slot_count];
    }

    /// Full byte extent of this execution record's allocation, including the
    /// optional resident stack/frame FAM. Used by the GC structural census;
    /// ownership teardown computes the same expression below.
    pub fn allocationSize(self: *const GeneratorExecutionState) usize {
        const slots = @as(usize, self.combined_stack_slots) + self.combinedFrameSlotCount();
        if (slots == 0) return @sizeOf(GeneratorExecutionState);
        return generator_execution_storage_offset + slots * @sizeOf(JSValue);
    }

    pub fn stackUsesCombinedStorage(self: *GeneratorExecutionState) bool {
        const combined = self.combinedStackStorage();
        if (combined.len == 0) return false;
        const stack = self.suspended.storage.stack;
        return stack.capacity != 0 and stack.values.ptr == combined.ptr;
    }

    pub fn frameUsesCombinedStorage(self: *GeneratorExecutionState) bool {
        const combined = self.combinedFrameStorage();
        if (combined.len == 0) return false;
        const frame = self.suspended.storage.frame;
        return frame.storage.len != 0 and frame.storage.ptr == combined.ptr;
    }

    pub fn canRetainResidentStorageOwnership(self: *GeneratorExecutionState) bool {
        if (!self.stackUsesCombinedStorage()) return false;
        return self.combinedFrameSlotCount() == 0 or self.frameUsesCombinedStorage();
    }

    pub fn destroy(self: *GeneratorExecutionState, rt: *JSRuntime) void {
        // qjs async_func_free_frame releases the resident frame before cur_func
        // and this_val. Keep the same ownership order; yield-star's separate
        // zjs root belongs to this execution record as well.
        if (!self.suspended.running_aliases and self.stackUsesCombinedStorage()) {
            var live_values = self.suspended.storage.stack.values;
            destroyValueSliceValuesOnly(rt, &live_values);
            self.suspended.storage.stack = .{};
        }
        if (!self.suspended.running_aliases and self.frameUsesCombinedStorage()) {
            self.suspended.storage.frame.deinitResident(rt);
        }
        self.suspended.deinit(rt);
        destroyOwnedValue(rt, &self.current_function);
        destroyOwnedValue(rt, &self.this_value);
        destroyOwnedValue(rt, &self.yield_star_iterator);
        self.* = .{};
    }
};

const generator_execution_alignment = blk: {
    const state_alignment = std.mem.Alignment.of(GeneratorExecutionState);
    const value_alignment = std.mem.Alignment.of(JSValue);
    break :blk if (state_alignment.compare(.gt, value_alignment)) state_alignment else value_alignment;
};
const generator_execution_storage_offset = std.mem.alignForward(usize, @sizeOf(GeneratorExecutionState), @alignOf(JSValue));

pub fn createGeneratorExecutionStateWithStorage(rt: *JSRuntime, stack_slots: usize, frame_slots: usize) !*GeneratorExecutionState {
    const stack_slot_count = std.math.cast(u16, stack_slots) orelse return error.StackOverflow;
    if (frame_slots > GeneratorExecutionState.frame_slot_count_mask) return error.StackOverflow;
    const frame_slot_count: u32 = @intCast(frame_slots);
    const total_slots = try std.math.add(usize, stack_slots, frame_slots);
    const slot_bytes = try std.math.mul(usize, total_slots, @sizeOf(JSValue));
    const allocation_size = try std.math.add(usize, generator_execution_storage_offset, slot_bytes);
    const bytes = try rt.allocRuntimeAlignedBytes(allocation_size, generator_execution_alignment);
    const execution: *GeneratorExecutionState = @ptrCast(@alignCast(bytes.ptr));
    execution.* = .{
        .combined_stack_slots = stack_slot_count,
        .combined_frame_metadata = frame_slot_count,
    };
    const combined_stack = execution.combinedStackStorage();
    execution.suspended.storage.stack = .{
        .values = combined_stack.ptr[0..0],
        .capacity = combined_stack.len,
    };
    execution.suspended.storage.frame.storage = execution.combinedFrameStorage();
    return execution;
}

fn freeGeneratorExecutionState(rt: *JSRuntime, execution: *GeneratorExecutionState) void {
    const combined_stack_slots = execution.combined_stack_slots;
    const combined_frame_slots = execution.combinedFrameSlotCount();
    execution.destroy(rt);
    if (combined_stack_slots == 0 and combined_frame_slots == 0) {
        rt.memory.destroy(GeneratorExecutionState, execution);
        return;
    }
    const total_slots = @as(usize, combined_stack_slots) + combined_frame_slots;
    const slot_bytes = total_slots * @sizeOf(JSValue);
    const allocation_size = generator_execution_storage_offset + slot_bytes;
    const bytes: [*]u8 = @ptrCast(execution);
    rt.memory.freeAlignedBytes(bytes[0..allocation_size], generator_execution_alignment);
}

pub fn destroyGeneratorExecutionState(rt: *JSRuntime, slot: *?*GeneratorExecutionState) void {
    const execution = slot.* orelse return;
    // Publish completion before releasing graph edges so re-entrant GC sees
    // the compact completed state, never a half-destroyed execution record.
    slot.* = null;
    std.debug.assert(!execution.completionPending());
    freeGeneratorExecutionState(rt, execution);
}

pub const GeneratorPayload = struct {
    execution: ?*GeneratorExecutionState = null,
    async_promise: ?JSValue = null,
    /// Async-generator request queue (mirrors JSAsyncGeneratorData.queue,
    /// quickjs.c:21362): FIFO of pending next/return/throw requests.
    async_queue: []AsyncGeneratorRequest = &.{},
    async_queue_capacity: usize = 0,
    resume_completion_type: i32 = 0,
    /// Async-generator state machine (mirrors JSAsyncGeneratorStateEnum,
    /// quickjs.c:21345). Only meaningful for JS_CLASS_ASYNC_GENERATOR objects.
    async_state: u8 = 0,
    /// GeneratorSuspendKind of the last suspension.
    suspend_kind: u8 = 0,
    done: bool = false,
    executing: bool = false,
    started: bool = false,
    just_yielded: bool = false,
    yield_star_suspended: bool = false,

    pub fn destroy(self: *GeneratorPayload, rt: *JSRuntime) void {
        destroyGeneratorExecutionState(rt, &self.execution);
        destroyOptionalValue(rt, &self.async_promise);
        for (self.async_queue) |*req| {
            req.result.free(rt);
            req.promise.free(rt);
            req.resolve.free(rt);
            req.reject.free(rt);
        }
        if (self.async_queue_capacity != 0) {
            rt.memory.free(AsyncGeneratorRequest, self.async_queue.ptr[0..self.async_queue_capacity]);
        }
        self.async_queue = &.{};
        self.async_queue_capacity = 0;
        self.* = .{};
    }

    pub fn traceChildEdges(self: *GeneratorPayload, visitor: anytype) !void {
        if (self.execution) |execution| {
            try callVisitValue(visitor, &execution.this_value);
            if (!execution.suspended.running_aliases) {
                for (execution.suspended.storage.stack.values) |*stored| try callVisitValue(visitor, stored);
                for (execution.suspended.storage.frame.locals) |*stored| try callVisitValue(visitor, stored);
                for (execution.suspended.storage.frame.args) |*stored| try callVisitValue(visitor, stored);
                // qjs marks the resident JSAsyncFunctionState frame's var_refs;
                // there is no second generator-payload capture array.
                for (execution.suspended.storage.frame.var_refs) |cell| {
                    var cell_value = cell.valueRef();
                    try callVisitValue(visitor, &cell_value);
                }
                for (execution.suspended.storage.frame.open_var_refs) |maybe_cell| {
                    const cell = maybe_cell orelse continue;
                    var cell_value = cell.valueRef();
                    try callVisitValue(visitor, &cell_value);
                }
            }
            try callVisitValue(visitor, &execution.current_function);
            try callVisitValue(visitor, &execution.yield_star_iterator);
        }
        try traceOptValue(visitor, &self.async_promise);
        // Async-generator request queue values (mirrors
        // js_async_generator_mark, quickjs.c:21400-21418).
        for (self.async_queue) |*req| {
            try callVisitValue(visitor, &req.result);
            try callVisitValue(visitor, &req.promise);
            try callVisitValue(visitor, &req.resolve);
            try callVisitValue(visitor, &req.reject);
        }
    }
};
