//! Bounded mark queue with a discoverable overflow path (§8.4).
//!
//! The queue is fixed-size on purpose: a marker that allocates is a marker
//! that can fail during a phase where failure has nowhere to go. The design's
//! rule for exhaustion is precise -- "queue exhaustion can increase scanning;
//! it cannot leave a marked object undiscoverable" -- so overflow does not
//! drop work, it downgrades to a coarser way of finding it.
//!
//! When the ring is full the object stays marked and its *block* is flagged
//! instead. Overflow processing then rescans every marked cell in a flagged
//! block. That is strictly more scanning and strictly no less discovery,
//! which is the trade the design asks for.

const std = @import("std");
const gc = @import("gc.zig");

/// 65536 entries (512 KB, lazily allocated). The ring became the incremental
/// cycle's persistent frontier in Phase 2, and a BFS frontier over a tens-of-
/// MB heap routinely exceeds the old 4096. Overflow is still sound -- it
/// downgrades the remark to a rescan of every marked object -- but every
/// overflow turns one bounded remark into an O(live) pass, so the ring is
/// sized to make that rare rather than routine.
pub const capacity = 65536;

pub const Stats = struct {
    pushed: usize = 0,
    popped: usize = 0,
    overflowed: usize = 0,
    high_water: usize = 0,
};

pub const Queue = struct {
    /// Heap-allocated rather than embedded. At 4096 entries the ring is 32 KB,
    /// and a `Registry` lives inside every `JSRuntime`: embedding it made
    /// runtime construction 32 KB heavier, which is fine once and fatal when a
    /// corpus builds tens of thousands of runtimes. Allocated lazily so a
    /// runtime that never marks concurrently never pays for it.
    buffer: ?[]?*gc.Header = null,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),
    /// Set when a push found the ring full. Cleared only by a full overflow
    /// sweep, so it cannot be lost by a racing push.
    overflowed: std.atomic.Value(bool) = .init(false),
    stats: Stats = .{},

    /// Allocate the ring on first use. Failure is not fatal: a queue with no
    /// buffer reports every push as overflow, which downgrades to rescan --
    /// the same safe path exhaustion already takes.
    pub fn ensureCapacity(self: *Queue, allocator: std.mem.Allocator) void {
        if (self.buffer != null) return;
        self.buffer = allocator.alloc(?*gc.Header, capacity) catch null;
    }

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        if (self.buffer) |buf| allocator.free(buf);
        self.buffer = null;
    }

    pub fn reset(self: *Queue) void {
        self.head.store(0, .release);
        self.tail.store(0, .release);
        self.overflowed.store(false, .release);
        self.stats = .{};
    }

    pub fn len(self: *const Queue) usize {
        const t = self.tail.load(.acquire);
        const h = self.head.load(.acquire);
        return t -% h;
    }

    /// Returns false when the ring is full. The caller must not treat that as
    /// "work lost": the object is already marked, and the overflow flag makes
    /// it findable by rescan.
    pub fn push(self: *Queue, header: *gc.Header) bool {
        const buf = self.buffer orelse {
            self.overflowed.store(true, .release);
            self.stats.overflowed += 1;
            return false;
        };
        const t = self.tail.load(.monotonic);
        const h = self.head.load(.acquire);
        if (t -% h >= capacity) {
            self.overflowed.store(true, .release);
            self.stats.overflowed += 1;
            return false;
        }
        buf[t % capacity] = header;
        self.tail.store(t +% 1, .release);
        self.stats.pushed += 1;
        const depth = t -% h + 1;
        if (depth > self.stats.high_water) self.stats.high_water = depth;
        return true;
    }

    pub fn pop(self: *Queue) ?*gc.Header {
        const buf = self.buffer orelse return null;
        const h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);
        if (h == t) return null;
        const item = buf[h % capacity];
        self.head.store(h +% 1, .release);
        self.stats.popped += 1;
        return item;
    }

    pub fn hasOverflowed(self: *const Queue) bool {
        return self.overflowed.load(.acquire);
    }

    /// Cleared only after a rescan has actually covered the flagged work, so
    /// an interleaved push cannot have its flag dropped by this call.
    pub fn clearOverflow(self: *Queue) void {
        self.overflowed.store(false, .release);
    }
};
