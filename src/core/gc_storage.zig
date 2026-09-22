//! GC-owned slab, carrier audit state, and borrowed block/nursery routes.
//! There is exactly one cell store per Registry; ordinary native allocations
//! and the Runtime body do not enter these routes.

const gc_block_heap = @import("gc_block_heap.zig");
const gc_nursery = @import("gc_nursery.zig");
const gc_carrier = @import("gc_carrier.zig");

const carrier_audit_enabled = gc_carrier.audit_enabled;

pub const Owner = struct {
    slab: @import("gc_slab.zig").Slab = .{},
    slab_enabled: bool = false,
    block_heap: ?*gc_block_heap.Heap = null,
    nursery: ?*gc_nursery.Nursery = null,
    extent_identity: if (carrier_audit_enabled) gc_carrier.ExtentIdentityAuthority else void =
        if (carrier_audit_enabled) .{} else {},
    extent_lifecycle: if (carrier_audit_enabled) gc_carrier.ExtentLifecycleAuthority else void =
        if (carrier_audit_enabled) .{} else {},
    heap_oracle: if (carrier_audit_enabled) ?*gc_carrier.HeapAccountingOracle else void =
        if (carrier_audit_enabled) null else {},

    pub fn detach(self: *Owner) void {
        self.block_heap = null;
        self.nursery = null;
        if (comptime carrier_audit_enabled) {
            self.extent_identity.deinit(std_heap());
            self.extent_lifecycle.deinit(std_heap());
            self.heap_oracle = null;
        }
    }
};

fn std_heap() @import("std").mem.Allocator {
    return @import("std").heap.page_allocator;
}
