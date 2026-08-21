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
