//! Compatibility names for the core engine-error authority.

const errors = @import("../core/errors.zig");

/// The engine error surface. Defined in `core.errors` so core-level surfaces can
/// name it too; these aliases keep the historical `exec.exceptions` names.
pub const RuntimeError = errors.RuntimeError;
pub const HostError = errors.HostError;
