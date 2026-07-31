//! Layout-lineage padding for the 1A attribution dossier.
//!
//! Build layout is not stable enough for a single A/B/C build to settle a
//! mechanism question: the same source and toolchain can produce `.text`
//! sections differing by several percent. A dossier therefore samples several
//! *layout lineages* and treats layout as a blocking factor, so that candidate
//! effect and codegen effect are estimated separately.
//!
//! This does not permit padding added to shape one favourable hot layout.
//! Here padding exists only to sample many layout lineages and average the
//! lottery out. It is never enabled in a shipped configuration.
//!
//! At `zjs_dossier_layout_pad == 0` this file emits nothing whatsoever, so the
//! default binary is bit-for-bit what it would be without it.

const std = @import("std");
const build_options = @import("build_options");

pub const pad_slots: usize = build_options.zjs_dossier_layout_pad;

comptime {
    if (pad_slots != 0) {
        for (0..pad_slots) |slot| {
            const Slot = struct {
                fn body(seed: u64) callconv(.c) u64 {
                    // Each slot gets a distinct, non-foldable body so the
                    // linker cannot merge them and every slot really occupies
                    // space in .text.
                    var acc = seed ^ (@as(u64, slot) *% 0x9e3779b97f4a7c15);
                    inline for (0..8) |round| {
                        acc = acc *% (0x100000001b3 +% @as(u64, round)) +% @as(u64, slot);
                        acc ^= acc >> 29;
                    }
                    return acc;
                }
            };
            @export(&Slot.body, .{ .name = std.fmt.comptimePrint("zjs_dossier_pad_{d}", .{slot}) });
        }
    }
}
