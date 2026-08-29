//! Candidate validation for concurrent tracing (§5.4, §7.2).
//!
//! The two-word Slot protocol admits torn reads, and the litmus measured the
//! rate on this target at 6.2%: a reference tag paired with a payload from a
//! different write. The design's answer is that such a pair is a *candidate*,
//! never a value -- it may cause floating retention, it may never cause a
//! wrong-kind dereference. This module is where that promise is kept.
//!
//! Every check here runs before anything dereferences the address. The order
//! matters: cheap arithmetic rejections first, then the address registry,
//! and only then anything that reads through the pointer.

const std = @import("std");
const gc = @import("gc.zig");

pub const Rejection = enum {
    null_or_low,
    misaligned,
    not_registered,
    kind_mismatch,
    accepted,
};

pub const Stats = struct {
    examined: usize = 0,
    accepted: usize = 0,
    rejected_low: usize = 0,
    rejected_misaligned: usize = 0,
    rejected_unregistered: usize = 0,
    rejected_kind: usize = 0,

    pub fn note(self: *Stats, outcome: Rejection) void {
        self.examined += 1;
        switch (outcome) {
            .accepted => self.accepted += 1,
            .null_or_low => self.rejected_low += 1,
            .misaligned => self.rejected_misaligned += 1,
            .not_registered => self.rejected_unregistered += 1,
            .kind_mismatch => self.rejected_kind += 1,
        }
    }
};

/// Validate a candidate address that arrived with a claimed GC kind.
///
/// `claimed_kind` is what the *tag* said. Under a torn read the tag and the
/// payload can come from different writes, so agreement between the claimed
/// kind and the kind recorded in the registered object's own header is the
/// check that catches it. A mismatch means the pair was assembled across two
/// writes and the address is discarded rather than traced.
pub fn validate(
    registry: *gc.Registry,
    addr: usize,
    claimed_kind: ?gc.GcKind,
    stats: ?*Stats,
) ?*gc.Header {
    const outcome = struct {
        fn reject(s: ?*Stats, r: Rejection) ?*gc.Header {
            if (s) |st| st.note(r);
            return null;
        }
    };

    // The null page and anything below it cannot be a heap object, and this
    // rejection costs one compare.
    if (addr < 4096) return outcome.reject(stats, .null_or_low);
    if (!std.mem.isAligned(addr, @alignOf(gc.Header))) return outcome.reject(stats, .misaligned);

    // The registry is authoritative for "is this an allocated object". Nothing
    // before this point has dereferenced the address.
    const header = registry.address_registry.resolve(addr) orelse
        return outcome.reject(stats, .not_registered);

    // Now the address is known to be a live registered object, so reading its
    // header is safe. If the tag claimed a kind, it has to agree.
    if (claimed_kind) |kind| {
        if (header.metaConst().flags.kind != kind) return outcome.reject(stats, .kind_mismatch);
    }

    if (stats) |st| st.note(.accepted);
    return header;
}
