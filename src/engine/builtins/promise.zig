const core = @import("../core/root.zig");
const function_builtin = @import("function.zig");
const jobs = @import("../exec/jobs.zig");

/// QuickJS source map: narrow Promise constructor payload used by transitional
/// `new_promise` bytecode.
pub fn construct(rt: *core.Runtime) !core.Value {
    return constructWithPrototype(rt, null);
}

pub fn constructWithPrototype(rt: *core.Runtime, prototype: ?*core.Object) !core.Value {
    const object = try core.Object.create(rt, core.class.ids.promise, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (prototype == null) {
        try function_builtin.defineNativeMethod(rt, object, "then", 2);
        try function_builtin.defineNativeMethod(rt, object, "catch", 1);
    }
    return object.value();
}

/// QuickJS source map: selected Promise static helpers used by current smoke
/// coverage. This intentionally preserves the existing narrow behavior:
/// resolve/all/race ignore arguments, reject records an unhandled reason, and
/// every supported mode returns a Promise object.
pub fn staticCall(ctx: *core.Context, mode: u32, reason: ?core.Value) !core.Value {
    return staticCallWithPrototype(ctx, mode, reason, null);
}

pub fn staticCallWithPrototype(ctx: *core.Context, mode: u32, reason: ?core.Value, prototype: ?*core.Object) !core.Value {
    switch (mode) {
        1, 2, 3 => {},
        4 => {
            const value = reason orelse return error.UnsupportedPromiseCall;
            ctx.exception_slot.set(ctx.runtime, value.dup());
        },
        else => return error.UnsupportedPromiseCall,
    }
    return constructWithPrototype(ctx.runtime, prototype);
}

pub fn enqueueReaction(queue: *jobs.Queue, job: jobs.Job) !void {
    try queue.enqueue(job);
}
