//! Seqlock snapshot for dynamically-laid-out objects (§6.3).
//!
//! A marker running beside the mutator cannot read a pointer/length/capacity
//! triple with plain loads: the writer may be replacing the backing while the
//! reader is halfway through it. A sequence counter alone is not enough
//! either, which is why every descriptor word here is atomic -- a torn read of
//! the *descriptor* is exactly as dangerous as a torn read of a slot.
//!
//! The writer marks the descriptor odd while changing it and even when it is
//! coherent. The marker accepts a read only if the counter was even before and
//! identical after, and gives up to the owner thread after a bounded number of
//! retries rather than spinning against a writer that keeps winning.

const std = @import("std");

pub const Outcome = enum { captured, retry, bailout };

pub const Stats = struct {
    captures: usize = 0,
    retries: usize = 0,
    bailouts: usize = 0,
    /// Writers that found a marker mid-read. Not an error -- it is the
    /// protocol working -- but a high rate means marking and mutation are
    /// contending on the same objects.
    writer_publishes: usize = 0,
};

/// Retries before handing the object to the owner thread. Small on purpose:
/// a marker that keeps losing to a writer should stop burning cycles and let
/// final remark deal with the object while stopped.
pub const max_retries: usize = 4;

pub const Descriptor = struct {
    backing: usize = 0,
    length: usize = 0,
    capacity: usize = 0,
    kind: usize = 0,
};

pub const Snapshot = struct {
    layout_seq: std.atomic.Value(u32) = .init(0),
    backing: std.atomic.Value(usize) = .init(0),
    length: std.atomic.Value(usize) = .init(0),
    capacity: std.atomic.Value(usize) = .init(0),
    kind: std.atomic.Value(usize) = .init(0),
    stats: Stats = .{},

    /// Writer side, steps 2-7. The caller is responsible for being inside a
    /// barrier-critical scope (step 1) and for shading newly exposed targets
    /// (step 6) -- both need context this type does not have.
    pub fn publish(self: *Snapshot, next: Descriptor) void {
        const seq = self.layout_seq.load(.monotonic);
        std.debug.assert(seq % 2 == 0);
        _ = self.layout_seq.fetchAdd(1, .acq_rel); // now odd: readers back off

        self.kind.store(next.kind, .release);
        self.backing.store(next.backing, .release);
        self.length.store(next.length, .release);
        self.capacity.store(next.capacity, .release);

        _ = self.layout_seq.fetchAdd(1, .release); // even again: coherent
        self.stats.writer_publishes += 1;
    }

    /// Marker side, steps 1-6. Returns `.retry` for a torn or in-progress
    /// read; the caller loops, and after `max_retries` gets `.bailout` and
    /// must enqueue the object for the owner thread instead.
    pub fn capture(self: *Snapshot, out: *Descriptor, attempt: usize) Outcome {
        const seq1 = self.layout_seq.load(.acquire);
        if (seq1 % 2 != 0) {
            self.stats.retries += 1;
            return if (attempt + 1 >= max_retries) blk: {
                self.stats.bailouts += 1;
                break :blk .bailout;
            } else .retry;
        }

        out.* = .{
            .kind = self.kind.load(.acquire),
            .backing = self.backing.load(.acquire),
            .length = self.length.load(.acquire),
            .capacity = self.capacity.load(.acquire),
        };

        const seq2 = self.layout_seq.load(.acquire);
        if (seq1 != seq2) {
            self.stats.retries += 1;
            return if (attempt + 1 >= max_retries) blk: {
                self.stats.bailouts += 1;
                break :blk .bailout;
            } else .retry;
        }

        self.stats.captures += 1;
        return .captured;
    }

    /// Convenience wrapper that runs the retry loop and reports the terminal
    /// outcome, which is what a marker actually wants.
    pub fn captureWithRetries(self: *Snapshot, out: *Descriptor) Outcome {
        var attempt: usize = 0;
        while (attempt < max_retries) : (attempt += 1) {
            switch (self.capture(out, attempt)) {
                .captured => return .captured,
                .retry => continue,
                .bailout => return .bailout,
            }
        }
        self.stats.bailouts += 1;
        return .bailout;
    }
};
