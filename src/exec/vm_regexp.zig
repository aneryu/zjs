const core = @import("../core/root.zig");
const stack_mod = @import("stack.zig");

/// qjs OP_regexp consumes `[pattern, compiled-bytecode]` constants and creates
/// a fresh object from the realm's fixed regexp shape. It does not call or
/// consult a possibly-replaced global `RegExp` constructor.
fn constructCompiledLiteralInRealm(
    rt: *core.JSRuntime,
    global: *core.Object,
    source: core.JSValue,
    compiled_value: core.JSValue,
) !core.JSValue {
    if (!compiled_value.isString()) return error.TypeError;
    const compiled_string = compiled_value.asStringBodyRaw() orelse return error.TypeError;
    if (compiled_string.isWide() or compiled_string.len() == 0) return error.TypeError;
    const realm = rt.contextForGlobal(global) orelse return error.TypeError;
    const initial_shape = realm.regexp_shape orelse return error.TypeError;

    var source_val = source;
    var compiled_root = compiled_value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &source_val },
        .{ .value = &compiled_root },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.createRegExpFromShape(rt, initial_shape);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try object.setRegexpSource(rt, source_val);
    try object.setRegexpCompiledBytecodeString(rt, compiled_string);
    return object.value();
}

pub noinline fn pushLiteral(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    global: *core.Object,
) !void {
    const compiled = try stack.pop();
    defer compiled.free(ctx.runtime);
    const pattern = try stack.pop();
    defer pattern.free(ctx.runtime);

    const value = try constructCompiledLiteralInRealm(ctx.runtime, global, pattern, compiled);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}
