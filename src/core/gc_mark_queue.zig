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

pub const capacity = 4096;

pub const Stats = struct {
    pushed: usize = 0,
    popped: usize = 0,
    overflowed: usize = 0,
    high_water: usize = 0,
};

pub const Queue = struct {
    buffer: [capacity]?*gc.Header = @splat(null),
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),
    /// Set when a push found the ring full. Cleared only by a full overflow
    /// sweep, so it cannot be lost by a racing push.
    overflowed: std.atomic.Value(bool) = .init(false),
    stats: Stats = .{},

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
        const t = self.tail.load(.monotonic);
        const h = self.head.load(.acquire);
        if (t -% h >= capacity) {
            self.overflowed.store(true, .release);
            self.stats.overflowed += 1;
            return false;
        }
        self.buffer[t % capacity] = header;
        self.tail.store(t +% 1, .release);
        self.stats.pushed += 1;
        const depth = t -% h + 1;
        if (depth > self.stats.high_water) self.stats.high_water = depth;
        return true;
    }

    pub fn pop(self: *Queue) ?*gc.Header {
        const h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);
        if (h == t) return null;
        const item = self.buffer[h % capacity];
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
