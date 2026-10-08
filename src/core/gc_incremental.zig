//! Mark epoch and morgue state of the tracing collector.
//!
//! The incremental major (and its target-shading barrier and sliced
//! destruction) is retired; collections are stop-the-world.

const gc = @import("gc.zig");
const registry_lists = @import("gc_registry_lists.zig");

/// Mark epoch for non-block trace carriers. Epoch 0 is reserved for
/// newborn/unmarked; a major advances this scalar, while minors keep it fixed
/// so sticky survivor marks remain valid. Unlike a global parity flip, a stale
/// nonzero epoch cannot make a newborn (0) read marked.
pub const Marking = struct {
    header_epoch: u16 = 1,
};

pub const Morgue = struct {
    /// Split by kind at condemnation.
    ///
    /// Destruction has to run objects before realms before modules before
    /// bytecode before var_refs before shapes. Bucketing at condemnation
    /// costs nothing extra -- that pass already visits every corpse -- and
    /// lets destruction visit each exactly once. Indexed by
    /// `@intFromEnum(kind)`.
    by_kind: [gc.gc_kind_count]registry_lists.IntrusiveHeaderList = @splat(.{}),

    /// Bind the per-kind cyclic sentinels. Must run before any condemnation,
    /// and is idempotent.
    pub fn init(self: *Morgue) void {
        for (&self.by_kind) |*head| head.init();
    }
};
