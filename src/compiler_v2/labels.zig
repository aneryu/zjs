//! QCP-1 compiler-v2: parser-native label identity, mirroring the QuickJS
//! production model (`quickjs.c` LabelSlot / label relocation chains).
//!
//! V2 NEVER materializes absolute-PC jump operands in the parser. A jump is
//! emitted against a `LabelId` from the moment of creation; `resolve_labels_v2`
//! assigns final positions and rewrites operands once. Producing an absolute
//! PC first and converting later is forbidden — that would recreate the old
//! compiler's debt inside the new one.
//!
//! API-FROZEN (driver-owned): the shapes below are the contract every v2
//! agent codes against. Changes require a driver decision, not an agent one.

const std = @import("std");

/// Function-scoped logical label identity. Stable across detach/splice —
/// a moved block keeps its LabelIds; only slot offsets rebind.
pub const LabelId = enum(u32) {
    _,

    pub fn index(self: LabelId) u32 {
        return @intFromEnum(self);
    }
};

pub const unbound: u32 = std.math.maxInt(u32);
pub const no_reloc: u32 = std.math.maxInt(u32);

pub const LabelFlags = packed struct(u8) {
    /// Bound offsets refer to the temporary bytecode stream.
    bound: bool = false,
    /// At least one backward jump resolved through this label while retained
    /// (feeds resolve_labels_v2 short-form bookkeeping).
    backward_target: bool = false,
    /// The parser requested an explicit sequential-match barrier at this
    /// bind. This is the identity-native analogue of a physical `OP_label`:
    /// Stage 4 must not fold across it even after all incoming refs disappear.
    match_barrier: bool = false,
    reserved: u5 = 0,
};

/// One label. `ref_count` is retained qjs update_label bookkeeping for the
/// resolve_labels_v2 short-form pass; exact block-CFG reachability decides
/// liveness. `first_reloc` heads an intrusive chain of operand positions
/// awaiting the final relative rewrite.
pub const LabelSlot = struct {
    /// Offset into the temporary bytecode where the label binds, or
    /// `unbound`.
    bound_offset: u32 = unbound,
    /// Number of retained references. Resolve passes decrement when a
    /// referencing instruction is removed as dead; Stage 4 consumes the
    /// resulting count for short-form selection, never as a liveness oracle.
    ref_count: u32 = 0,
    /// Head of this label's relocation chain (`no_reloc` when empty).
    first_reloc: u32 = no_reloc,
    flags: LabelFlags = .{},
};

pub const RelocKind = enum(u8) {
    /// 32-bit operand in the temporary stream holding a LabelId, to be
    /// rewritten to a relative displacement at final emission.
    jump32,
    /// Auxiliary label operand of a compact scope instruction (the
    /// scope_make_ref-style secondary slot).
    aux32,
};

/// One pending operand rewrite. Chained per label via `next`.
pub const RelocEntry = struct {
    next: u32 = no_reloc,
    /// Offset of the 4-byte operand inside the temporary bytecode.
    operand_offset: u32,
    kind: RelocKind,
};
