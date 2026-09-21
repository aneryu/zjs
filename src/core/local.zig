//! `Local`: a heap pointer held by native code, and the discipline that makes
//! holding one checkable.
//!
//! The engine's precise roots have never been complete. Production links only
//! container/window `ValueRootFrame`s; every other Zig local that holds a heap
//! reference across an allocation is covered by the conservative stack scan
//! (`gc-invariants.md`, "Roots"). A non-moving collector makes that a cost --
//! some garbage survives. A moving one makes it a bug: the object is somewhere
//! else and the local still names where it was.
//!
//! `Effect.may_alloc` is the design's answer (target design T6): a function
//! that cannot allocate may hold bare pointers freely, and only the ones that
//! CAN need their references in slots. Zig has no effect system to enforce
//! that, but it does not need one -- the property is observable. A collection
//! bumps `Registry.collection_epoch`, so "did anything happen between taking
//! this pointer and using it" is a comparison, and a function that cannot
//! allocate cannot fail it.
//!
//! So the annotation is the type. `Local(*Object)` cannot be dereferenced
//! without naming the runtime, and naming the runtime is what lets the check
//! run. In safety builds a stale read fails AT THE USE, with the stack that
//! names the function that should have rooted it. In ReleaseFast the wrapper
//! is the pointer and `get` is the field read.
//!
//! What this is NOT: a root. A `Local` does not keep anything alive and does
//! not get updated. It is the detector that says "this one needed a root",
//! which is the part that cannot be found by reading code -- there are
//! hundreds of these and they only matter on the paths that actually collect.

const std = @import("std");
const builtin = @import("builtin");

const checked = std.debug.runtime_safety;

/// A native-held reference that must not outlive a collection.
///
/// `T` is a pointer type (`*Object`, `*String`, ...) or `JSValue`; anything
/// whose meaning depends on where the object currently is.
pub fn Local(comptime T: type) type {
    return struct {
        raw: T,
        epoch: if (checked) u64 else void = if (checked) 0 else {},

        const Self = @This();

        /// Take a reference. `epoch_source` is anything with a
        /// `collectionEpoch()` method -- the runtime, the registry, a context.
        pub inline fn take(epoch_source: anytype, value: T) Self {
            return .{
                .raw = value,
                .epoch = if (checked) epoch_source.collectionEpoch() else {},
            };
        }

        /// Read it back. Fails in safety builds when a collection has happened
        /// since `take`, because then this reference names the old address and
        /// the caller owed it a root.
        pub inline fn get(self: Self, epoch_source: anytype) T {
            if (comptime checked) {
                if (self.epoch != epoch_source.collectionEpoch()) {
                    @panic("gc: a native local outlived a collection -- it needed a root (see core/local.zig)");
                }
            }
            return self.raw;
        }

        /// Read it WITHOUT the check, for the one case that is legitimate:
        /// comparing identity, or reading a field whose meaning does not
        /// depend on the object still being at this address. Spelled
        /// differently so it cannot be reached by accident.
        pub inline fn rawUnchecked(self: Self) T {
            return self.raw;
        }

        /// Re-anchor to the current epoch after the caller has re-derived the
        /// reference from a root. This is what a fix looks like: the value
        /// comes back from a slot, and the local is taken again.
        pub inline fn reanchor(self: *Self, epoch_source: anytype, value: T) void {
            self.raw = value;
            if (comptime checked) self.epoch = epoch_source.collectionEpoch();
        }
    };
}

test "a local read after a collection fails, and a re-anchored one does not" {
    const Source = struct {
        epoch: u64 = 0,
        fn collectionEpoch(self: *const @This()) u64 {
            return self.epoch;
        }
    };
    var source: Source = .{};
    var marker: u32 = 7;

    var local = Local(*u32).take(&source, &marker);
    try std.testing.expectEqual(@as(u32, 7), local.get(&source).*);

    source.epoch += 1;
    // `rawUnchecked` still answers; `get` is the one that would fail.
    try std.testing.expectEqual(@as(u32, 7), local.rawUnchecked().*);

    local.reanchor(&source, &marker);
    try std.testing.expectEqual(@as(u32, 7), local.get(&source).*);
}

test "an unchecked build carries no epoch" {
    if (checked) return error.SkipZigTest;
    try std.testing.expectEqual(@sizeOf(*u32), @sizeOf(Local(*u32)));
}
