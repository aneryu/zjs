//! Bounded mark queue with a discoverable overflow path (§8.4).
//!
//! The queue is fixed-size on purpose: a marker that allocates is a marker
//! that can fail during a phase where failure has nowhere to go. The design's
//! rule for exhaustion is precise -- "queue exhaustion can increase scanning;
//! it cannot leave a marked object undiscoverable" -- so overflow does not
//! drop work, it downgrades to a coarser way of finding it.
//!
//! When the ring is full the object stays marked and the overflow flag is
//! set instead. Overflow processing then rescans every marked object. That
//! is strictly more scanning and strictly no less discovery, which is the
//! trade the design asks for.
//!
//! The ring is a Vyukov bounded MPMC queue: parallel marking has several
//! threads popping (and pushing spilled local work) inside a stop-the-world
//! slice, and the previous head/tail ring was single-producer/single-
//! consumer -- two poppers could both advance `head` past each other's item.
//! Each slot carries a sequence number; a producer claims a slot by CAS on
//! `tail` only after the slot's sequence says it is free, and a consumer
//! symmetrically on `head`. The uncontended cost is one CAS plus one
//! sequence load per operation, which disappears under the tens-of-
//! nanoseconds cost of tracing an object.

const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc.zig");

/// Queue traffic accounting is consumed only by the queue unit tests. Keep
/// the production queue's synchronization protocol and overflow downgrade,
/// but erase the observer storage and every counter update from non-test
/// builds: these counters do not feed marking policy or `--gc-stats`.
pub const stats_enabled = builtin.is_test;

/// 65536 entries (1 MB with sequence numbers, lazily allocated). The ring
/// became the incremental cycle's persistent frontier in Phase 2, and a BFS
/// frontier over a tens-of-MB heap routinely exceeds the old 4096. Overflow
/// is still sound -- it downgrades the remark to a rescan of every marked
/// object -- but every overflow turns one bounded remark into an O(live)
/// pass, so the ring is sized to make that rare rather than routine.
pub const capacity = 65536;

const Slot = struct {
    seq: std.atomic.Value(usize),
    item: *gc.Header,
};

pub const Stats = struct {
    pushed: usize = 0,
    popped: usize = 0,
    overflowed: usize = 0,
    high_water: usize = 0,
};

const StatsStorage = if (stats_enabled) struct {
    pushed: std.atomic.Value(usize) = .init(0),
    popped: std.atomic.Value(usize) = .init(0),
    overflowed: std.atomic.Value(usize) = .init(0),
} else [3]usize;

pub const Queue = struct {
    /// Heap-allocated rather than embedded: a `Registry` lives inside every
    /// `JSRuntime`, and embedding the ring made runtime construction that
    /// much heavier -- fine once, fatal when a corpus builds tens of
    /// thousands of runtimes. Allocated lazily so a runtime that never
    /// marks concurrently never pays for it.
    slots: ?[]Slot = null,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),
    /// Set when a push found the ring full. Cleared only by a full overflow
    /// sweep, so it cannot be lost by a racing push.
    overflowed: std.atomic.Value(bool) = .init(false),
    /// The ReleaseFast arm is inert, uninitialised layout reserve. Keeping the
    /// former 24-byte extent stable avoids shifting Registry fields consumed
    /// by resident VM handlers; only test builds give the bytes meaning.
    stats_storage: StatsStorage = if (stats_enabled) .{} else undefined,

    /// Allocate the ring on first use. Failure is not fatal: a queue with no
    /// buffer reports every push as overflow, which downgrades to rescan --
    /// the same safe path exhaustion already takes.
    pub fn ensureCapacity(self: *Queue, allocator: std.mem.Allocator) void {
        if (self.slots != null) return;
        const slots = allocator.alloc(Slot, capacity) catch return;
        for (slots, 0..) |*slot, i| slot.seq = .init(i);
        self.slots = slots;
    }

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        if (self.slots) |slots| allocator.free(slots);
        self.slots = null;
    }

    /// Ready the ring for a new marking cycle.
    ///
    /// Positions are monotonic, so an EMPTY ring is already reset: leaving
    /// head and tail where they are keeps every slot's sequence consistent
    /// with them, and only the flag and the counters need clearing. Rewinding
    /// to zero would force all `capacity` sequence numbers to be rewritten to
    /// match -- 65,536 stores per cycle, which on earley-boyer's 7,772 cycles
    /// is 509 M stores and 3.8 GiB of sequential traffic through L2, every
    /// byte of it to restore a state the ring was already in. The rewrite is
    /// only needed when a cycle is abandoned with entries still queued.
    pub fn reset(self: *Queue) void {
        self.overflowed.store(false, .release);
        if (comptime stats_enabled) {
            self.stats_storage.pushed.store(0, .monotonic);
            self.stats_storage.popped.store(0, .monotonic);
            self.stats_storage.overflowed.store(0, .monotonic);
        }
        // Abandoned with work still in it: drain what is left through the
        // ordinary protocol, which costs O(residual) and leaves every
        // sequence number consistent by construction. Re-seeding the whole
        // array instead is both O(capacity) and easy to get wrong -- the
        // first attempt wrote logical positions in PHYSICAL slot order,
        // which is only correct when `head % capacity == 0` (adversarial
        // review, codex, 2026-08-27).
        while (self.popSingle()) |_| {}
        if (comptime stats_enabled) self.stats_storage.popped.store(0, .monotonic);
    }

    pub fn len(self: *const Queue) usize {
        const t = self.tail.load(.acquire);
        const h = self.head.load(.acquire);
        return t -% h;
    }

    pub fn stats(self: *const Queue) Stats {
        if (comptime !stats_enabled) return .{};
        return .{
            .pushed = self.stats_storage.pushed.load(.monotonic),
            .popped = self.stats_storage.popped.load(.monotonic),
            .overflowed = self.stats_storage.overflowed.load(.monotonic),
            .high_water = 0,
        };
    }

    /// Returns false when the ring is full. The caller must not treat that as
    /// "work lost": the object is already marked, and the overflow flag makes
    /// it findable by rescan.
    pub fn push(self: *Queue, header: *gc.Header) bool {
        const slots = self.slots orelse {
            self.overflowed.store(true, .release);
            if (comptime stats_enabled) _ = self.stats_storage.overflowed.fetchAdd(1, .monotonic);
            return false;
        };
        var pos = self.tail.load(.monotonic);
        while (true) {
            const slot = &slots[pos % capacity];
            const seq = slot.seq.load(.acquire);
            if (seq == pos) {
                if (self.tail.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                    continue;
                }
                slot.item = header;
                slot.seq.store(pos +% 1, .release);
                if (comptime stats_enabled) _ = self.stats_storage.pushed.fetchAdd(1, .monotonic);
                return true;
            }
            if (seq < pos) {
                // The slot still holds an unconsumed item from a lap ago:
                // the ring is full.
                self.overflowed.store(true, .release);
                if (comptime stats_enabled) _ = self.stats_storage.overflowed.fetchAdd(1, .monotonic);
                return false;
            }
            // Another producer claimed this position; reload and retry.
            pos = self.tail.load(.monotonic);
        }
    }

    pub fn pop(self: *Queue) ?*gc.Header {
        const slots = self.slots orelse return null;
        var pos = self.head.load(.monotonic);
        while (true) {
            const slot = &slots[pos % capacity];
            const seq = slot.seq.load(.acquire);
            if (seq == pos +% 1) {
                if (self.head.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                    continue;
                }
                const item = slot.item;
                slot.seq.store(pos +% capacity, .release);
                if (comptime stats_enabled) _ = self.stats_storage.popped.fetchAdd(1, .monotonic);
                return item;
            }
            if (seq <= pos) return null; // empty at this position
            pos = self.head.load(.monotonic);
        }
    }

    /// Single-consumer pop: protocol-compatible with the MPMC form (same
    /// sequence handshake) but claims the head with a plain store instead of
    /// a CAS. Safe ONLY while no other thread pops -- the owner uses it for
    /// ordinary single-threaded slices, where the CAS was a measured 3.4%
    /// of fixed-work splay; parallel slices use `pop`.
    pub fn popSingle(self: *Queue) ?*gc.Header {
        const slots = self.slots orelse return null;
        const pos = self.head.load(.monotonic);
        const slot = &slots[pos % capacity];
        const seq = slot.seq.load(.acquire);
        if (seq != pos +% 1) return null;
        const item = slot.item;
        slot.seq.store(pos +% capacity, .release);
        self.head.store(pos +% 1, .monotonic);
        if (comptime stats_enabled) {
            self.stats_storage.popped.store(
                self.stats_storage.popped.load(.monotonic) + 1,
                .monotonic,
            );
        }
        return item;
    }

    /// Single-producer push, same caveat as `popSingle`.
    /// Keep the resident write-barrier callers on one shared queue body. Once
    /// test-only accounting is erased this becomes small enough for WPO to
    /// inline into `op_put_field`, growing that handler despite doing less.
    pub noinline fn pushSingle(self: *Queue, header: *gc.Header) bool {
        const slots = self.slots orelse {
            self.overflowed.store(true, .release);
            if (comptime stats_enabled) _ = self.stats_storage.overflowed.fetchAdd(1, .monotonic);
            return false;
        };
        const pos = self.tail.load(.monotonic);
        const slot = &slots[pos % capacity];
        const seq = slot.seq.load(.acquire);
        if (seq != pos) {
            self.overflowed.store(true, .release);
            if (comptime stats_enabled) _ = self.stats_storage.overflowed.fetchAdd(1, .monotonic);
            return false;
        }
        slot.item = header;
        slot.seq.store(pos +% 1, .release);
        self.tail.store(pos +% 1, .monotonic);
        if (comptime stats_enabled) {
            self.stats_storage.pushed.store(
                self.stats_storage.pushed.load(.monotonic) + 1,
                .monotonic,
            );
        }
        return true;
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

comptime {
    // The production reserve and test counters must occupy exactly the same
    // extent so switching instrumentation cannot shift Registry hot fields.
    std.debug.assert(@sizeOf(StatsStorage) == 3 * @sizeOf(usize));
    std.debug.assert(
        @offsetOf(Queue, "overflowed") ==
            @offsetOf(Queue, "stats_storage") + @sizeOf(StatsStorage),
    );
}
