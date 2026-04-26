const core = @import("../core/root.zig");

pub fn ordinaryObject(rt: *core.Runtime) !*core.Object {
    return core.Object.create(rt, core.class.ids.object, null);
}

pub fn functionObject(rt: *core.Runtime, name: core.Atom) !core.Value {
    const function = try core.Object.create(rt, core.class.ids.c_function, null);
    errdefer core.Object.destroyFromHeader(rt, &function.header);

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &prototype.header);
    const prototype_value = prototype.value();
    defer prototype_value.free(rt);

    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    try function.defineOwnProperty(rt, prototype_key, core.Descriptor.data(prototype_value, true, false, false));

    if (rt.atoms.name(name)) |function_name| {
        const name_string = try core.string.String.createUtf8(rt, function_name);
        const name_value = name_string.value();
        defer name_value.free(rt);
        const name_key = try rt.internAtom("name");
        defer rt.atoms.free(name_key);
        try function.defineOwnProperty(rt, name_key, core.Descriptor.data(name_value, false, false, true));
    }

    return function.value();
}

pub fn constructValue(rt: *core.Runtime, callee: core.Value, args: []const core.Value) !core.Value {
    _ = args;
    const constructor = try expectConstructor(callee);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const prototype_value = constructor.getProperty(prototype_key);
    defer prototype_value.free(rt);

    const prototype = if (prototype_value.isObject()) object: {
        const header = prototype_value.refHeader() orelse break :object null;
        break :object @as(*core.Object, @fieldParentPtr("header", header));
    } else null;

    const instance = try core.Object.create(rt, core.class.ids.object, prototype);
    return instance.value();
}

fn expectConstructor(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.bytecode_function and
        object.class_id != core.class.ids.bound_function and
        object.class_id != core.class.ids.c_function_data and
        object.class_id != core.class.ids.c_closure)
    {
        return error.TypeError;
    }
    return object;
}
