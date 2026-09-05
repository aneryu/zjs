//! Unbounded segmented mark frontier.
//!
//! The collector's private LIFO (`MarkStack`) and the barrier's queue
//! (`Queue`) share 4 KiB segments; the queue's oldest segment moves into the
//! private stack whole (`steal`) when the stack runs dry. Everything runs on
//! the owner thread: the mutator's write barrier and the collector's slices
//! never overlap, so there are no locks (the helper-thread machinery this
//! file used to carry left with parallel marking). Segment storage comes
//! from the registry's backing allocator (`std.heap.smp_allocator`), which
//! is deliberately outside the JavaScript heap account and therefore cannot
//! recurse into GC.
//!
//! Allocation failure invalidates the current marking cycle. No address is
//! silently dropped and there is no whole-heap recovery scan: the next marker
//! boundary returns OutOfMemory, and the runtime's existing abort protocol
//! closes marking without sweeping. A later collection starts from fresh
//! marks. The same fail-closed rule covers the rare barrier edge that cannot
//! safely be queued because both endpoints are mutator-freeable kinds.

const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc.zig");

pub const segment_bytes = 4096;
pub const cached_segment_limit = 8;

pub const Segment = struct {
    older: ?*Segment = null,
    newer: ?*Segment = null,
    len: usize = 0,
    items: [item_capacity]*gc.Header = undefined,

    pub const item_capacity =
        (segment_bytes - 3 * @sizeOf(usize)) / @sizeOf(*gc.Header);
};

pub const entries_per_segment = Segment.item_capacity;

comptime {
    std.debug.assert(@sizeOf(Segment) == segment_bytes);
    std.debug.assert(entries_per_segment > 1);
}

pub const Failure = enum(u8) {
    none,
    out_of_memory,
    unqueueable_barrier,
};

pub const PoolStats = struct {
    active_segments: usize = 0,
    cached_segments: usize = 0,
    owned_segments: usize = 0,
    peak_active_segments: usize = 0,
    peak_owned_segments: usize = 0,
    allocations: usize = 0,
    frees: usize = 0,
    allocation_failures: usize = 0,
};

/// One runtime's segment allocator and bounded recycle cache.
pub const SegmentPool = struct {
    backing: ?std.mem.Allocator = null,
    cached_head: ?*Segment = null,
    stats_data: PoolStats = .{},
    test_fail_backing_allocations: if (builtin.is_test) usize else void =
        if (builtin.is_test) 0 else {},

    pub fn ensureBacking(self: *SegmentPool, allocator: std.mem.Allocator) void {
        if (self.backing == null) self.backing = allocator;
    }

    pub fn acquire(self: *SegmentPool) ?*Segment {
        if (self.cached_head) |segment| {
            self.cached_head = segment.older;
            self.stats_data.cached_segments -= 1;
            self.stats_data.active_segments += 1;
            self.stats_data.peak_active_segments = @max(
                self.stats_data.peak_active_segments,
                self.stats_data.active_segments,
            );
            segment.* = .{};
            return segment;
        }
        const allocator = self.backing orelse {
            self.stats_data.allocation_failures += 1;
            return null;
        };
        if (comptime builtin.is_test) {
            if (self.test_fail_backing_allocations != 0) {
                self.test_fail_backing_allocations -= 1;
                self.stats_data.allocation_failures += 1;
                return null;
            }
        }

        const segment = allocator.create(Segment) catch {
            self.stats_data.allocation_failures += 1;
            return null;
        };
        segment.* = .{};

        self.stats_data.allocations += 1;
        self.stats_data.owned_segments += 1;
        self.stats_data.active_segments += 1;
        self.stats_data.peak_owned_segments = @max(
            self.stats_data.peak_owned_segments,
            self.stats_data.owned_segments,
        );
        self.stats_data.peak_active_segments = @max(
            self.stats_data.peak_active_segments,
            self.stats_data.active_segments,
        );
        return segment;
    }

    pub fn release(self: *SegmentPool, segment: *Segment) void {
        segment.* = .{};
        std.debug.assert(self.stats_data.active_segments != 0);
        self.stats_data.active_segments -= 1;
        if (self.stats_data.cached_segments < cached_segment_limit) {
            segment.older = self.cached_head;
            self.cached_head = segment;
            self.stats_data.cached_segments += 1;
            return;
        }
        const allocator = self.backing.?;
        self.stats_data.owned_segments -= 1;
        self.stats_data.frees += 1;
        allocator.destroy(segment);
    }

    pub fn stats(self: *const SegmentPool) PoolStats {
        return self.stats_data;
    }

    pub fn failBackingAllocationsForTest(self: *SegmentPool, count: usize) void {
        if (comptime !builtin.is_test) unreachable;
        self.test_fail_backing_allocations = count;
    }

    pub fn deinit(self: *SegmentPool) void {
        const allocator = self.backing;
        var cached = self.cached_head;
        self.cached_head = null;
        self.stats_data.cached_segments = 0;

        while (cached) |segment| {
            const next = segment.older;
            if (allocator) |a| a.destroy(segment);
            cached = next;
        }
        self.* = .{};
    }
};

/// A private LIFO frontier. All segments except possibly the hot top are full
/// in ordinary push/pop use. `len` remains public because admission and
/// donation policy price the instantaneous frontier without walking links.
pub const MarkStack = struct {
    bottom: ?*Segment = null,
    top: ?*Segment = null,
    pool: ?*SegmentPool = null,
    len: usize = 0,
    segment_count: usize = 0,

    pub fn ensure(self: *MarkStack, pool: *SegmentPool) void {
        if (self.pool) |bound| std.debug.assert(bound == pool) else self.pool = pool;
    }

    pub fn reset(self: *MarkStack) void {
        const pool = self.pool orelse {
            self.* = .{};
            return;
        };
        var cursor = self.bottom;
        while (cursor) |segment| {
            const next = segment.newer;
            pool.release(segment);
            cursor = next;
        }
        self.bottom = null;
        self.top = null;
        self.len = 0;
        self.segment_count = 0;
    }

    pub fn deinitStack(self: *MarkStack) void {
        self.reset();
        self.* = .{};
    }

    pub inline fn push(self: *MarkStack, header: *gc.Header) bool {
        var segment = self.top;
        if (segment == null or segment.?.len == entries_per_segment) {
            const fresh = (self.pool orelse return false).acquire() orelse return false;
            fresh.older = self.top;
            if (self.top) |old_top| old_top.newer = fresh else self.bottom = fresh;
            self.top = fresh;
            self.segment_count += 1;
            segment = fresh;
        }
        segment.?.items[segment.?.len] = header;
        segment.?.len += 1;
        self.len += 1;
        return true;
    }

    pub inline fn pop(self: *MarkStack) ?*gc.Header {
        const segment = self.top orelse return null;
        std.debug.assert(segment.len != 0);
        segment.len -= 1;
        self.len -= 1;
        const result = segment.items[segment.len];
        if (segment.len == 0) self.releaseEmptyTop(segment);
        return result;
    }

    /// Pop and prefetch the next header across segment boundaries.
    pub inline fn popPrefetch(self: *MarkStack) ?*gc.Header {
        const segment = self.top orelse return null;
        std.debug.assert(segment.len != 0);
        segment.len -= 1;
        self.len -= 1;
        const result = segment.items[segment.len];
        if (segment.len != 0) {
            @prefetch(segment.items[segment.len - 1], .{ .rw = .read, .locality = 3, .cache = .data });
        } else if (segment.older) |older| {
            std.debug.assert(older.len != 0);
            @prefetch(older.items[older.len - 1], .{ .rw = .read, .locality = 3, .cache = .data });
        }
        if (segment.len == 0) self.releaseEmptyTop(segment);
        return result;
    }

    fn releaseEmptyTop(self: *MarkStack, segment: *Segment) void {
        std.debug.assert(self.top == segment);
        self.top = segment.older;
        if (self.top) |new_top| new_top.newer = null else self.bottom = null;
        self.segment_count -= 1;
        self.pool.?.release(segment);
    }

    /// Adopt a segment taken from the queue as the hot end without copying
    /// entries.
    pub fn adoptAsTop(self: *MarkStack, segment: *Segment) void {
        std.debug.assert(segment.older == null and segment.newer == null);
        std.debug.assert(segment.len != 0);
        segment.older = self.top;
        if (self.top) |old_top| old_top.newer = segment else self.bottom = segment;
        self.top = segment;
        self.len += segment.len;
        self.segment_count += 1;
    }
};

pub const Stats = struct {
    pool: PoolStats = .{},
};

/// The barrier's segmented worklist; tracing happens on private stacks that
/// take its segments whole.
pub const Queue = struct {
    oldest: ?*Segment = null,
    newest: ?*Segment = null,
    item_count: usize = 0,
    failure_state: Failure = .none,
    pool: SegmentPool = .{},

    pub fn ensureCapacity(self: *Queue, allocator: std.mem.Allocator) void {
        self.pool.ensureBacking(allocator);
    }

    pub fn segmentPool(self: *Queue) *SegmentPool {
        return &self.pool;
    }

    pub fn failBackingAllocationsForTest(self: *Queue, count: usize) void {
        if (comptime !builtin.is_test) unreachable;
        self.pool.failBackingAllocationsForTest(count);
    }

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.reset();
        self.pool.deinit();
        self.* = .{};
    }

    pub fn reset(self: *Queue) void {
        var cursor = self.oldest;
        self.oldest = null;
        self.newest = null;
        self.item_count = 0;
        self.failure_state = .none;
        while (cursor) |segment| {
            const next = segment.newer;
            self.pool.release(segment);
            cursor = next;
        }
    }

    pub fn len(self: *const Queue) usize {
        return self.item_count;
    }

    pub fn isEmpty(self: *const Queue) bool {
        return self.item_count == 0;
    }

    pub fn stats(self: *const Queue) Stats {
        return .{ .pool = self.pool.stats() };
    }

    pub fn failure(self: *const Queue) Failure {
        return self.failure_state;
    }

    pub fn invalidateBarrier(self: *Queue) void {
        if (self.failure_state == .none) self.failure_state = .unqueueable_barrier;
    }

    fn noteOutOfMemory(self: *Queue) void {
        if (self.failure_state == .none) self.failure_state = .out_of_memory;
    }

    /// Append one entry; the write barrier's push.
    pub noinline fn push(self: *Queue, header: *gc.Header) bool {
        if (self.newest) |segment| {
            if (segment.len != entries_per_segment) {
                segment.items[segment.len] = header;
                segment.len += 1;
                self.item_count += 1;
                return true;
            }
        }
        const fresh = self.pool.acquire() orelse {
            self.noteOutOfMemory();
            return false;
        };
        fresh.items[0] = header;
        fresh.len = 1;
        self.appendNewest(fresh);
        self.item_count += 1;
        return true;
    }

    /// Move the oldest segment into a private LIFO in O(1).
    pub fn steal(self: *Queue, local: *MarkStack) bool {
        const segment = self.oldest orelse return false;
        self.oldest = segment.newer;
        if (self.oldest) |new_oldest| new_oldest.older = null else self.newest = null;
        segment.older = null;
        segment.newer = null;
        self.item_count -= segment.len;
        local.adoptAsTop(segment);
        return true;
    }

    /// Single-item pop from the newest end (tests and the barrier-queue
    /// remark helper).
    pub fn pop(self: *Queue) ?*gc.Header {
        const segment = self.newest orelse return null;
        segment.len -= 1;
        const result = segment.items[segment.len];
        self.item_count -= 1;
        if (segment.len == 0) {
            self.newest = segment.older;
            if (self.newest) |newest| newest.newer = null else self.oldest = null;
            segment.older = null;
            segment.newer = null;
            self.pool.release(segment);
        }
        return result;
    }

    fn appendNewest(self: *Queue, segment: *Segment) void {
        std.debug.assert(segment.older == null and segment.newer == null);
        segment.older = self.newest;
        if (self.newest) |old_newest| old_newest.newer = segment else self.oldest = segment;
        self.newest = segment;
    }
};
