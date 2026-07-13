const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const stack_mod = @import("stack.zig");

// RegExp construct record keyed by native-builtin ref: the `OP_regexp` literal
// handler runs the builtin RegExp constructor body through the record table
// (Phase 6b-3 STEP 4) rather than naming the RegExp owner directly. The
// `.construct` ref validates the (pattern, flags) value pair; the construct
// branch reads only `args`/`new_target`, so no constructor function object or
// caller frame is threaded.
const regexp_construct_ref = core.function.NativeBuiltinRef{
    .domain = .regexp,
    .id = @intFromEnum(core.host_function.builtin_method_ids.regexp.ConstructorMethod.construct),
};

fn constructRegExpRecord(
    ctx: *core.JSContext,
    native_ref: core.function.NativeBuiltinRef,
    prototype: ?*core.Object,
    pattern: core.JSValue,
    flags: core.JSValue,
) !core.JSValue {
    const args = [_]core.JSValue{ pattern, flags };
    return (try builtin_dispatch.callConstructRecord(ctx, null, null, &.{}, null, native_ref, prototype, &args, null, null)) orelse error.TypeError;
}

pub noinline fn pushLiteral(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    prototype: ?*core.Object,
) !void {
    const flags = try stack.pop();
    defer flags.free(ctx.runtime);
    const pattern = try stack.pop();
    defer pattern.free(ctx.runtime);

    const value = try constructRegExpRecord(ctx, regexp_construct_ref, prototype, pattern, flags);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}
