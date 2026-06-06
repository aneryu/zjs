const core = @import("../core/root.zig");
const builtins = @import("../builtins/root.zig");

pub fn detachArrayBuffer(ctx: *core.JSContext, value: core.JSValue) !core.JSValue {
    return builtins.buffer.detachArrayBuffer(ctx.runtimePtr(), value);
}

test {
    _ = detachArrayBuffer;
}
