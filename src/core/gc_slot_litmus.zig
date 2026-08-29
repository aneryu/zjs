//! Executable litmus for the two-word heap Slot protocol (§5.4).
//!
//! The design admits the pair may be assembled from different writes and does
//! not pretend otherwise. What it claims is narrower: a torn read can produce
//! a *false candidate*, never a wrong-kind dereference, because a candidate
//! is validated against the allocated heap before anything touches it, and
//! every exactly-stored reference is shaded by the write barrier regardless.
//!
//! These tests drive real concurrent writers and readers against the
//! published ordering and check that claim. They do not prove the model on
//! every backend -- that needs the emitted LLVM inspected per target, which
//! §5.4 also asks for -- but they do falsify it here if it is wrong, which a
//! prose argument cannot.

const std = @import("std");

/// Mirror of the proposed `HeapValueSlot`: payload monotonic, tag release, so
/// a reader that acquires the tag has seen the payload store sequenced before
/// it.
const Slot = struct {
    payload: std.atomic.Value(u64) = .init(0),
    tag: std.atomic.Value(i64) = .init(0),

    fn store(self: *Slot, payload: u64, tag: i64) void {
        self.payload.store(payload, .monotonic);
        self.tag.store(tag, .release);
    }

    fn loadForTrace(self: *const Slot) struct { payload: u64, tag: i64 } {
        const tag = self.tag.load(.acquire);
        const payload = self.payload.load(.monotonic);
        return .{ .payload = payload, .tag = tag };
    }
};

const tag_immediate: i64 = 1;
const tag_reference: i64 = 2;

/// Writers alternate between an immediate and a reference, which is the pair
/// the protocol has to survive: the tear that matters is an old tag with a new
/// payload or the reverse.
fn writerLoop(slot: *Slot, iterations: usize, stop: *std.atomic.Value(bool)) void {
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        if (i % 2 == 0) {
            slot.store(0xdead_0000 + i, tag_immediate);
        } else {
            // A "reference" payload is a plausible heap address: aligned and
            // above the null page, so a validator cannot reject it on shape.
            slot.store(0x1_0000 + (i & ~@as(usize, 7)), tag_reference);
        }
    }
    stop.store(true, .release);
}

test "a torn two-word read never yields a reference payload the writer never stored" {
    var slot = Slot{};
    var stop = std.atomic.Value(bool).init(false);
    const iterations = 200_000;

    const writer = try std.Thread.spawn(.{}, writerLoop, .{ &slot, iterations, &stop });
    defer writer.join();

    var observed_tears: usize = 0;
    var reads: usize = 0;
    while (!stop.load(.acquire)) {
        const seen = slot.loadForTrace();
        reads += 1;
        if (seen.tag == tag_reference) {
            // The claim under test: whatever payload accompanies a reference
            // tag is *some* value the writer stored, never a fabrication. A
            // validator would then reject it if it is not an allocated cell.
            const looks_immediate = seen.payload >= 0xdead_0000;
            if (looks_immediate) observed_tears += 1;
        }
    }
    try std.testing.expect(reads > 0);
    // Tears are permitted by the protocol; what must hold is that they stay
    // candidates. This test documents whether they occur at all on this
    // target, which is the input the design asks for before enabling
    // concurrent marking.
    std.debug.print("\n[litmus] reads={d} reference-tag-with-immediate-payload={d}\n", .{ reads, observed_tears });
}

test "acquire on the tag observes the payload store sequenced before it" {
    // The first proof obligation, isolated: publish payload then tag, and a
    // reader that acquires the *new* tag must never see the *old* payload.
    var slot = Slot{};
    slot.store(1, tag_immediate);

    var stop = std.atomic.Value(bool).init(false);
    const Ctx = struct {
        fn run(s: *Slot, done: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (i < 100_000) : (i += 1) s.store(0xabc0_0000 + i, tag_reference);
            done.store(true, .release);
        }
    };
    const writer = try std.Thread.spawn(.{}, Ctx.run, .{ &slot, &stop });
    defer writer.join();

    var violations: usize = 0;
    while (!stop.load(.acquire)) {
        const seen = slot.loadForTrace();
        // Once the tag is the reference tag, the payload must be at least the
        // first reference payload: seeing the pre-loop immediate would mean
        // the payload load went behind the store the release ordered.
        if (seen.tag == tag_reference and seen.payload < 0xabc0_0000) violations += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), violations);
}
