//! Per-runtime VM stack budgets and storage: the call-depth / frame-byte /
//! native-stack budget (`JSRuntime.stack`), the operand-stack storage word,
//! and the contiguous value-stack arena (`JSRuntime.vm_stack`).

const std = @import("std");
const runtime_mod = @import("../runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const thread_stack = @import("thread_stack.zig");
const native_allocation = runtime_mod.native_allocation;
const default_stack_size = runtime_mod.default_stack_size;
const default_native_stack_size = runtime_mod.default_native_stack_size;

/// Operand-stack limit and current backing ownership in one machine word.
/// Runtime caches the frame-window template; each Stack copies it and changes
/// ownership when installing resident storage or growing onto its own heap buffer.
pub const VmStackStorage = packed struct(u64) {
    pub const Ownership = enum(u2) {
        /// Stack releases this allocation.
        owned = 0,
        /// Borrowed from an arena chunk or a Frame-owned heap slab.
        frame_window = 1,
        /// Borrowed from a suspended execution's resident storage.
        resident_window = 2,
    };

    limit: u62,
    ownership: Ownership = .owned,

    pub fn forLimit(limit: usize) VmStackStorage {
        return .{ .limit = @intCast(@min(limit, std.math.maxInt(u62))) };
    }

    pub fn frameWindowForLimit(limit: usize) VmStackStorage {
        var storage = forLimit(limit);
        storage.ownership = .frame_window;
        return storage;
    }
};

/// Call-depth and stack-byte budgets of one runtime (`JSRuntime.stack`).
pub const StackBudget = struct {
    /// Runtime-shared logical call depth, including zero-byte nested entries.
    call_depth: usize = 0,
    /// Limit for both logical depth and accumulated planned VM-frame bytes.
    limit: usize = default_stack_size,
    /// Planned bytes for active bytecode frames, including tail-call callers
    /// whose physical Entry storage has been reused.
    bytecode_bytes: usize = 0,
    /// Nesting count for calls admitted through `enterCallDepth`; it bounds
    /// host C-stack recursion independently of inline VM call depth.
    native_call_depth: usize = 0,
    /// Lower bound for the current thread's call stack. Zero disables the
    /// check or means it has not yet been initialized.
    native_limit: usize = 0,
    /// Address captured in an outermost JS entry frame, not the OS stack's
    /// allocation start. GC uses it if the OS stack high bound is unavailable.
    native_top: usize = 0,
    /// Configured byte budget for descending below `native_top`.
    native_size: usize = default_native_stack_size,
    /// Frame-window template derived from `limit`; see `JSRuntime.setStackSize`.
    frame_storage: VmStackStorage = VmStackStorage.frameWindowForLimit(default_stack_size),

    /// Room the guard leaves at the low end of the thread's stack for the
    /// frames between two checks and for raising the overflow error.
    pub const thread_stack_reserve = 256 * 1024;

    /// Set the VM frame budget and the frame-window template derived from it.
    pub fn setLimit(self: *StackBudget, size: usize) void {
        self.limit = size;
        self.frame_storage = VmStackStorage.frameWindowForLimit(size);
    }

    /// Set the native stack budget. Idle, the current frame becomes the new
    /// base; during execution the active entry's base is kept.
    pub fn setNativeSize(self: *StackBudget, budget_bytes: usize) void {
        self.native_size = budget_bytes;
        if (self.isIdle()) {
            self.captureNativeTop();
        } else {
            self.armNativeLimit();
        }
    }

    /// Capture the current native frame pointer as the recursion base and
    /// derive the lower limit (QuickJS `JS_UpdateStackTop`). Must run at the
    /// outermost JS entry on the thread that will run the code (worker threads
    /// have their own C stack), so deeper native frames (parser / JSON /
    /// interpreter) measure against a real, same-stack base. Not inline: the
    /// captured frame is this call's. A zero `native_size` disables the limit.
    pub noinline fn captureNativeTop(self: *StackBudget) void {
        self.native_top = @frameAddress();
        self.armNativeLimit();
    }

    /// True if consuming `alloca_size` more native stack would cross the
    /// recursion limit (QuickJS `js_check_stack_overflow`). The stack grows
    /// down, so "below the limit" is overflow. A zero limit means "no limit"
    /// and needs no branch of its own: the saturating `sp` is never below 0.
    /// Inline, so `@frameAddress` is the caller's frame.
    pub inline fn checkNativeOverflow(self: *const StackBudget, alloca_size: usize) bool {
        const sp = @frameAddress() -| alloca_size;
        return sp < self.native_limit;
    }

    // Call accounting. Every change to `call_depth`, `native_call_depth` and
    // `bytecode_bytes` goes through these, so the counters move together and
    // a release always mirrors its charge.

    /// Whether a frame at `depth` that brings the planned VM bytes to
    /// `accumulated` (after adding `planned_stack_bytes`) breaks a ceiling:
    /// logical depth, planned bytes (including wraparound), or the native
    /// stack guard. Inline, so `@frameAddress` is the caller's frame.
    pub inline fn rejects(self: *const StackBudget, depth: usize, accumulated: usize, planned_stack_bytes: usize) bool {
        return self.budgetRejects(depth, accumulated, planned_stack_bytes) or
            @frameAddress() < self.native_limit;
    }

    /// `rejects` without the native stack guard.
    pub inline fn budgetRejects(self: *const StackBudget, depth: usize, accumulated: usize, planned_stack_bytes: usize) bool {
        return depth >= self.limit or accumulated < planned_stack_bytes or
            accumulated > self.limit;
    }

    /// Whether one more frame of `planned_stack_bytes` would be rejected now.
    pub inline fn wouldReject(self: *const StackBudget, planned_stack_bytes: usize) bool {
        return self.rejects(self.call_depth, self.bytecode_bytes +% planned_stack_bytes, planned_stack_bytes);
    }

    /// Charge one VM frame admitted against exactly these readings of
    /// `call_depth` and the accumulated bytes (callers that already loaded
    /// them for `rejects` commit without reloading).
    pub inline fn commitFrame(self: *StackBudget, depth: usize, accumulated: usize) void {
        self.bytecode_bytes = accumulated;
        self.call_depth = depth + 1;
    }

    /// Charge one admitted VM frame.
    pub inline fn enterFrame(self: *StackBudget, planned_stack_bytes: usize) void {
        std.debug.assert(std.math.maxInt(usize) - self.bytecode_bytes >= planned_stack_bytes);
        self.bytecode_bytes += planned_stack_bytes;
        self.call_depth += 1;
    }

    pub inline fn leaveFrame(self: *StackBudget, planned_stack_bytes: usize) void {
        self.releaseFrames(1, planned_stack_bytes);
    }

    /// Release `depth` frames worth `planned_stack_bytes` at once (a frame
    /// chain unwinding together).
    pub inline fn releaseFrames(self: *StackBudget, depth: usize, planned_stack_bytes: usize) void {
        std.debug.assert(self.call_depth >= depth);
        std.debug.assert(self.bytecode_bytes >= planned_stack_bytes);
        self.call_depth -= depth;
        self.bytecode_bytes -= planned_stack_bytes;
    }

    /// Charge one admitted frame entered through a native (re)entry: it also
    /// counts against the host C-stack recursion bound.
    pub inline fn enterNativeFrame(self: *StackBudget, planned_stack_bytes: usize) void {
        self.enterFrame(planned_stack_bytes);
        self.native_call_depth += 1;
    }

    pub inline fn leaveNativeFrame(self: *StackBudget, planned_stack_bytes: usize) void {
        self.leaveFrame(planned_stack_bytes);
        self.native_call_depth -= 1;
    }

    /// No frame of any kind is charged (outermost entry).
    pub inline fn isIdle(self: *const StackBudget) bool {
        return self.call_depth == 0 and self.native_call_depth == 0;
    }

    /// Derive `native_limit` from `native_top`; a zero budget disables it.
    /// The limit stays `thread_stack_reserve` above the low end of the
    /// thread's stack whatever the budget, so the guard's catchable error
    /// always comes before a real stack overflow.
    pub fn armNativeLimit(self: *StackBudget) void {
        if (self.native_size == 0) {
            self.native_limit = 0;
            return;
        }
        var limit = self.native_top -| self.native_size;
        if (thread_stack.bounds()) |stack| limit = @max(limit, stack.low +| thread_stack_reserve);
        self.native_limit = limit;
    }
};

/// Contiguous VM value-stack arena mirroring QuickJS's `alloca`-based
/// `JS_CallInternal` frame layout. Call frames carve LIFO windows for
/// `[args | locals | operand stack]` instead of per-call heap allocations.
/// Windows are stable for their lifetime (chunks never move); release is a
/// watermark restore. Frames manage the live values and all escaping references; their teardown
/// must finish before the watermark is restored. The arena manages storage only.
pub const VmStackArena = struct {
    pub const first_chunk_bytes: usize = 4 * 1024;
    pub const first_chunk_slots: usize = first_chunk_bytes / @sizeOf(JSValue);
    pub const chunk_slots: usize = 32 * 1024;
    pub const max_chunks: usize = 64;

    comptime {
        std.debug.assert(first_chunk_bytes % @sizeOf(JSValue) == 0);
        std.debug.assert(first_chunk_slots <= chunk_slots);
    }

    pub const Mark = struct {
        chunk: usize,
        used: usize,
    };

    pub const ActiveCarve = struct {
        mark: Mark,
        window: []JSValue,
    };

    // `active` selects the corresponding entries in `used` and `chunks`;
    // `chunk_count` bounds the active chunk index.
    chunk_count: usize = 0,
    active: usize = 0,
    used: [max_chunks]usize = @splat(0),
    chunks: [max_chunks][]JSValue = @splat(&.{}),

    /// `VmStackArena{}` is zeros plus 64 empty slices whose pointer is
    /// `@alignOf(JSValue)` (Zig `&.{}`), not null. Copying that typed default
    /// materializes a 1552-byte `.rodata` template. Zero the struct, then store
    /// the empty slices so every field still equals `VmStackArena{}`.
    fn initDefault(self: *VmStackArena) void {
        self.* = std.mem.zeroes(VmStackArena);
        const empty: []JSValue = &.{};
        for (&self.chunks) |*chunk| {
            chunk.* = empty;
        }
    }

    pub fn mark(self: *const VmStackArena) Mark {
        return .{ .chunk = self.active, .used = if (self.chunk_count == 0) 0 else self.used[self.active] };
    }

    /// Carve `n` slots from the arena. Returns null when the request cannot
    /// be served (oversized window or arena exhausted); callers fall back to
    /// heap storage.
    pub fn carve(self: *VmStackArena, rt: *JSRuntime, n: usize) ?[]JSValue {
        if (n == 0) return self.chunks[0][0..0];
        if (n > chunk_slots) return null;
        if (self.chunk_count != 0) {
            const active = self.active;
            const used = self.used[active];
            const capacity = self.chunks[active].len;
            std.debug.assert(used <= capacity);
            if (capacity - used >= n) {
                self.used[active] = used + n;
                return self.chunks[active][used .. used + n];
            }
        }
        return self.carveSlow(rt, n);
    }

    /// Allocation-free carve from the current chunk only, returning both the
    /// original watermark and the carved window from one state snapshot.
    /// Same-Machine hot frame constructors use this after their Entry storage
    /// is warm; a miss leaves the arena unchanged so the authoritative `carve`
    /// path can switch or allocate a chunk and preserve heap/OOM semantics.
    pub inline fn carveActiveMarked(self: *VmStackArena, n: usize) ?ActiveCarve {
        if (n == 0 or self.chunk_count == 0) return null;
        const active = self.active;
        const used = self.used[active];
        const capacity = self.chunks[active].len;
        std.debug.assert(used <= capacity);
        // The active chunk's actual length is authoritative: the compact
        // first chunk is 4 KiB, while every later chunk has chunk_slots.
        // Keeping one capacity predicate also rejects oversized warm carves
        // without duplicating the arena-wide maximum check.
        if (capacity - used < n) return null;
        self.used[active] = used + n;
        return .{
            .mark = .{ .chunk = active, .used = used },
            .window = self.chunks[active][used .. used + n],
        };
    }

    /// Switch to or allocate another arena chunk.  The active chunk satisfies
    /// virtually every ordinary call after the first one; keeping backing
    /// allocation and its memory-accounting/error machinery out of `carve`
    /// lets that steady arm remain a leaf, like QJS's `alloca` bump.
    noinline fn carveSlow(self: *VmStackArena, rt: *JSRuntime, n: usize) ?[]JSValue {
        const next_index = if (self.chunk_count == 0) 0 else self.active + 1;
        if (next_index >= max_chunks) return null;
        if (next_index >= self.chunk_count) {
            // Ordinary first-entry frames need only one 4 KiB page. A large
            // first request and every later chunk retain the 32K-slot ceiling
            // so deep or unusually wide calls do not turn into incremental
            // chunk churn. Publish no arena state until allocation succeeds.
            const allocation_slots = if (next_index == 0 and n <= first_chunk_slots)
                first_chunk_slots
            else
                chunk_slots;
            const chunk = rt.allocNative(JSValue, allocation_slots) catch return null;
            self.chunks[next_index] = chunk;
            self.chunk_count = next_index + 1;
        }
        std.debug.assert(n <= self.chunks[next_index].len);
        self.active = next_index;
        self.used[next_index] = n;
        return self.chunks[next_index][0..n];
    }

    pub fn carveTyped(self: *VmStackArena, rt: *JSRuntime, comptime T: type, n: usize) ?[]T {
        if (n == 0) return &.{};
        if (@alignOf(T) > @alignOf(JSValue)) return null;
        const byte_count = std.math.mul(usize, @sizeOf(T), n) catch return null;
        const slot_count = std.math.divCeil(usize, byte_count, @sizeOf(JSValue)) catch return null;
        const value_window = self.carve(rt, slot_count) orelse return null;
        const bytes = std.mem.sliceAsBytes(value_window);
        return std.mem.bytesAsSlice(T, bytes[0..byte_count]);
    }

    /// Restore a watermark in LIFO order after frame/stack teardown has
    /// retired the views and preserved any escaping values. Keeps chunks for reuse.
    pub fn restore(self: *VmStackArena, m: Mark) void {
        if (self.chunk_count == 0) return;
        var index = m.chunk + 1;
        while (index <= self.active) : (index += 1) self.used[index] = 0;
        self.active = m.chunk;
        self.used[m.chunk] = m.used;
    }

    pub fn deinit(self: *VmStackArena, allocator: std.mem.Allocator) void {
        for (self.chunks[0..self.chunk_count]) |chunk| {
            if (chunk.len != 0) allocator.free(chunk);
        }
        self.initDefault();
    }
};

test "VM stack arena default fill matches VmStackArena{}" {
    var arena: VmStackArena = undefined;
    arena.initDefault();
    try std.testing.expectEqualDeep(VmStackArena{}, arena);
    try std.testing.expectEqual(@as(usize, 1552), @sizeOf(VmStackArena));
    const empty: []JSValue = &.{};
    try std.testing.expectEqual(empty.ptr, arena.chunks[0].ptr);
    try std.testing.expectEqual(@as(usize, 0), arena.chunks[0].len);

    const account = try runtime_mod.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    arena.deinit(account.nativeAllocator());
    try std.testing.expectEqualDeep(VmStackArena{}, arena);
    try std.testing.expect(!account.hasOutstandingAllocations());
}

test "VM stack arena allocates and reuses a compact first chunk" {
    try std.testing.expectEqual(
        VmStackArena.first_chunk_bytes / @sizeOf(JSValue),
        VmStackArena.first_chunk_slots,
    );

    const account = try runtime_mod.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    const initial_mark = arena.mark();
    const first = arena.carve(account, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), arena.active);
    try std.testing.expectEqual(VmStackArena.first_chunk_slots, arena.chunks[0].len);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), account.allocation_diagnostics.allocation_count);

    arena.restore(initial_mark);
    const allocations_before_reuse = account.allocation_diagnostics.allocation_count;
    const reused = arena.carve(account, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused.ptr));
    try std.testing.expectEqual(allocations_before_reuse, account.allocation_diagnostics.allocation_count);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.allocation_diagnostics.allocated_bytes);
}

test "VM stack arena active miss is pure before authoritative second chunk carve" {
    const account = try runtime_mod.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    _ = arena.carve(account, VmStackArena.first_chunk_slots) orelse
        return error.TestUnexpectedResult;
    const full_mark = arena.mark();
    const bytes_before_miss = account.allocation_diagnostics.allocated_bytes;
    const allocations_before_miss = account.allocation_diagnostics.allocation_count;

    try std.testing.expect(arena.carveActiveMarked(1) == null);
    try std.testing.expectEqual(full_mark, arena.mark());
    try std.testing.expectEqual(bytes_before_miss, account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(allocations_before_miss, account.allocation_diagnostics.allocation_count);
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);

    const second = arena.carve(account, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(@as(usize, 2), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 1), arena.active);
    try std.testing.expectEqual(VmStackArena.chunk_slots, arena.chunks[1].len);
    try std.testing.expectEqual(@as(usize, 1), arena.used[1]);
    try std.testing.expectEqual(
        VmStackArena.first_chunk_bytes +
            VmStackArena.chunk_slots * @sizeOf(JSValue),
        account.allocation_diagnostics.allocated_bytes,
    );
    try std.testing.expectEqual(allocations_before_miss + 1, account.allocation_diagnostics.allocation_count);
}

test "VM stack arena large first carve retains the maximum chunk size" {
    const account = try runtime_mod.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    const requested = VmStackArena.first_chunk_slots + 1;
    const window = arena.carve(account, requested) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(requested, window.len);
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);
    try std.testing.expectEqual(VmStackArena.chunk_slots, arena.chunks[0].len);
    try std.testing.expectEqual(
        VmStackArena.chunk_slots * @sizeOf(JSValue),
        account.allocation_diagnostics.allocated_bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), account.allocation_diagnostics.allocation_count);
}

test "VM stack arena oversized carve is rejected without state or accounting changes" {
    const account = try runtime_mod.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    const before = arena.mark();
    try std.testing.expect(arena.carve(account, VmStackArena.chunk_slots + 1) == null);
    try std.testing.expectEqual(before, arena.mark());
    try std.testing.expectEqual(@as(usize, 0), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocation_count);
}

test "VM stack arena allocation failure is retryable and keeps accounting balanced" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const account = try runtime_mod.createAllocationTestRuntime(failing_allocator.allocator());
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    failing_allocator.fail_index = failing_allocator.alloc_index;
    const before = arena.mark();
    try std.testing.expect(arena.carve(account, 1) == null);
    try std.testing.expectEqual(before, arena.mark());
    try std.testing.expectEqual(@as(usize, 0), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocation_count);

    failing_allocator.fail_index = std.math.maxInt(usize);
    const retry = arena.carve(account, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), retry.len);
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), account.allocation_diagnostics.allocation_count);

    _ = arena.carve(account, VmStackArena.first_chunk_slots - 1) orelse
        return error.TestUnexpectedResult;
    const full_first_mark = arena.mark();
    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expect(arena.carve(account, 1) == null);
    try std.testing.expectEqual(full_first_mark, arena.mark());
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), arena.active);
    try std.testing.expectEqual(@as(usize, 0), arena.chunks[1].len);
    try std.testing.expectEqual(@as(usize, 0), arena.used[1]);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), account.allocation_diagnostics.allocation_count);

    failing_allocator.fail_index = std.math.maxInt(usize);
    const second_retry = arena.carve(account, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), second_retry.len);
    try std.testing.expectEqual(@as(usize, 2), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 1), arena.active);
    try std.testing.expectEqual(VmStackArena.chunk_slots, arena.chunks[1].len);
    try std.testing.expectEqual(@as(usize, 1), arena.used[1]);
    try std.testing.expectEqual(
        VmStackArena.first_chunk_bytes +
            VmStackArena.chunk_slots * @sizeOf(JSValue),
        account.allocation_diagnostics.allocated_bytes,
    );
    try std.testing.expectEqual(@as(usize, 2), account.allocation_diagnostics.allocation_count);

    arena.deinit(account.nativeAllocator());
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocation_count);
}
