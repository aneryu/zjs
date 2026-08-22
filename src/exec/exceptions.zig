//! Compatibility names for the core engine-error authority and exception slot.
//!
//! `core.errors` owns the closed runtime/host sets; this module preserves the
//! historical exec aliases and the tiny throw/take facade. `throwValue`
//! transfers one owned JSValue into the context's pending-exception slot;
//! `takeException` transfers that owned value back to its caller.

const JSContext = @import("../core/context.zig").JSContext;
const JSValue = @import("../core/value.zig").JSValue;

const errors = @import("../core/errors.zig");

/// The engine error surface. Defined in `core.errors` so core-level surfaces can
/// name it too; these aliases keep the historical `exec.exceptions` names.
pub const RuntimeError = errors.RuntimeError;
pub const HostError = errors.HostError;

pub fn throwValue(ctx: *JSContext, value: JSValue) JSValue {
    return ctx.throwValue(value);
}

pub fn takeException(ctx: *JSContext) JSValue {
    return ctx.takeException();
}
