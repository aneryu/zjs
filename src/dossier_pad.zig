//! Layout-lineage padding for the 1A attribution dossier.
//!
//! A single A/B does not settle a mechanism question on this host: the same
//! source delta can flip sign across placements (D10 Zoo +0.53% / −0.58%).
//! Pads sample that interaction. They are not a shipped layout knob.
//!
//! Rigid translation of one binary is cheap (P4-01c ≤0.24%). What pads must
//! still move is the handler island, otherwise an A/B that only changes
//! dispatch leaves `.text.zjs.op_handlers` nailed and the lineage is blind.
//! On aarch64 ELF the slots live in `.text.zjs.layout_pad`, KEEP'd at the
//! start of the island *after* its page-aligned origin so pad N shifts
//! handler VAs by a non-page multiple. A section *before* the island is
//! absorbed by ALIGN(MAXPAGESIZE) and pad=3/7 collapse. Other targets
//! keep the default `.text` placement.
//!
//! At `zjs_dossier_layout_pad == 0` this file emits nothing whatsoever, so the
//! default binary is bit-for-bit what it would be without it.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const pad_slots: usize = build_options.zjs_dossier_layout_pad;

const pad_section = switch (builtin.target.ofmt) {
    .elf => ".text.zjs.layout_pad",
    .macho => "__TEXT,__text",
    else => ".text",
};

comptime {
    if (pad_slots != 0) {
        for (0..pad_slots) |slot| {
            const Slot = struct {
                fn body(seed: u64) linksection(pad_section) callconv(.c) u64 {
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
