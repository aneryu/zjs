const Context = @import("../core/context.zig").Context;
const Value = @import("../core/value.zig").Value;

pub fn throwValue(ctx: *Context, value: Value) Value {
    return ctx.throwValue(value);
}

pub fn takeException(ctx: *Context) Value {
    return ctx.takeException();
}
