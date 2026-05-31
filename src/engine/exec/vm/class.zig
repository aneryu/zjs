const std = @import("std");

const bytecode = @import("../../bytecode/root.zig");
const core = @import("../../core/root.zig");
const frame_mod = @import("../frame.zig");
const property_ops = @import("../property_ops.zig");
const stack_mod = @import("../stack.zig");

const op = bytecode.opcode.op;

pub fn getSuper(
    ctx: *core.Context,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
) !void {
    const source_from_stack = stack.len() != 0;
    const source = if (source_from_stack) try stack.pop() else frame.current_function.dup();
    defer source.free(ctx.runtime);
    const function_object = property_ops.expectObject(source) catch {
        try stack.pushOwned(core.Value.undefinedValue());
        return;
    };
    if (function_object.functionSuperConstructor()) |super_constructor| {
        if (function_object.functionLexicalThisSlot().* != null) {
            try stack.push(super_constructor);
        } else if (function_object.getPrototype()) |prototype| {
            try stack.push(prototype.value());
        } else {
            try stack.pushOwned(core.Value.nullValue());
        }
        return;
    }
    if (source_from_stack) {
        if (function_object.getPrototype()) |prototype| {
            try stack.push(prototype.value());
        } else {
            try stack.pushOwned(core.Value.nullValue());
        }
        return;
    }
    const home_object = function_object.functionHomeObjectSlot().* orelse {
        if (function_object.getPrototype()) |prototype| {
            try stack.push(prototype.value());
        } else {
            try stack.pushOwned(core.Value.nullValue());
        }
        return;
    };
    if (home_object.getPrototype()) |prototype| {
        try stack.push(prototype.value());
    } else {
        try stack.pushOwned(core.Value.nullValue());
    }
}

pub fn getSuperValue(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime varRefSlotIsUninitialized: anytype,
    comptime handleCatchableRuntimeError: anytype,
    comptime slotValueDup: anytype,
    comptime toPropertyKeyAtom: anytype,
    comptime sameObjectIdentity: anytype,
    comptime getSuperPropertyValue: anytype,
) !void {
    _ = slotValueDup;
    const prop_value = try stack.pop();
    defer prop_value.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const receiver = try stack.pop();
    defer receiver.free(ctx.runtime);
    if (varRefSlotIsUninitialized(receiver)) {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return;
        return error.ReferenceError;
    }
    const atom_id = toPropertyKeyAtom(ctx, output, global, prop_value, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
    defer ctx.runtime.atoms.free(atom_id);
    if (obj.isUndefined() or obj.isNull()) {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return;
        return error.TypeError;
    }

    var prototype = try property_ops.expectObject(obj);
    if (property_ops.expectObject(frame.current_function)) |function_object| {
        if (function_object.functionSuperConstructor()) |super_constructor| {
            if (sameObjectIdentity(super_constructor, obj)) {
                if (function_object.functionHomeObjectSlot().*) |home_object| {
                    prototype = home_object.getPrototype() orelse {
                        try stack.pushOwned(core.Value.undefinedValue());
                        return;
                    };
                }
            }
        }
    } else |_| {}
    const value = getSuperPropertyValue(ctx, output, global, receiver, prototype, atom_id, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
    defer value.free(ctx.runtime);
    try stack.push(value);
}

pub fn putSuperValue(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime varRefSlotIsUninitialized: anytype,
    comptime handleCatchableRuntimeError: anytype,
    comptime slotValueDup: anytype,
    comptime toPropertyKeyAtom: anytype,
    comptime sameObjectIdentity: anytype,
    comptime setSuperPropertyValue: anytype,
) !void {
    _ = slotValueDup;
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const prop_value = try stack.pop();
    defer prop_value.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const receiver = try stack.pop();
    defer receiver.free(ctx.runtime);
    if (varRefSlotIsUninitialized(receiver)) {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return;
        return error.ReferenceError;
    }
    if (obj.isUndefined() or obj.isNull()) {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return;
        return error.TypeError;
    }
    const atom_id = toPropertyKeyAtom(ctx, output, global, prop_value, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
    defer ctx.runtime.atoms.free(atom_id);
    var prototype = try property_ops.expectObject(obj);
    if (property_ops.expectObject(frame.current_function)) |function_object| {
        if (function_object.functionSuperConstructor()) |super_constructor| {
            if (sameObjectIdentity(super_constructor, obj)) {
                if (function_object.functionHomeObjectSlot().*) |home_object| {
                    prototype = home_object.getPrototype() orelse {
                        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return;
                        return error.TypeError;
                    };
                }
            }
        }
    } else |_| {}
    setSuperPropertyValue(ctx, output, global, receiver, prototype, atom_id, value, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
}

pub fn setHomeObject(
    ctx: *core.Context,
    stack: *stack_mod.Stack,
    comptime functionBytecodeFromValue: anytype,
) !void {
    const func_value = try stackValueFromTop(stack, 0);
    defer func_value.free(ctx.runtime);
    const home_value = try stackValueFromTop(stack, 1);
    defer home_value.free(ctx.runtime);
    if (func_value.isObject() and home_value.isObject()) {
        const func_object = try property_ops.expectObject(func_value);
        var can_set_home_object = true;
        var is_arrow_function = false;
        if (func_object.functionBytecodeSlot().*) |function_bytecode_value| {
            if (functionBytecodeFromValue(function_bytecode_value)) |fb| {
                can_set_home_object = !fb.is_class_constructor;
                is_arrow_function = fb.is_arrow_function;
            }
        }
        if (can_set_home_object) {
            func_object.setFunctionHomeObject(ctx.runtime, try property_ops.expectObject(home_value));
            if (is_arrow_function) {
                const next_this = home_value.dup();
                const slot = func_object.functionLexicalThisSlot();
                const old_this = slot.*;
                slot.* = next_this;
                if (old_this) |stored| stored.free(ctx.runtime);
            }
        }
    }
}

pub fn checkBrand(ctx: *core.Context, stack: *stack_mod.Stack) !void {
    if (stack.values.len < 2) return error.StackUnderflow;
    const obj = stack.values[stack.values.len - 2].dup();
    defer obj.free(ctx.runtime);
    const func = stack.values[stack.values.len - 1].dup();
    defer func.free(ctx.runtime);
    if (!try hasPrivateBrand(ctx.runtime, obj, func)) return error.TypeError;
}

pub fn addBrand(ctx: *core.Context, stack: *stack_mod.Stack) !void {
    const home_value = try stack.pop();
    var rooted_home = home_value;
    defer home_value.free(ctx.runtime);
    const obj = try stack.pop();
    var rooted_obj = obj;
    defer obj.free(ctx.runtime);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_home },
        .{ .value = &rooted_obj },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const home = try property_ops.expectObject(rooted_home);
    const brand_atom = try ensureHomeObjectBrand(ctx.runtime, home);
    if (rooted_obj.isObject()) {
        const object = try property_ops.expectObject(rooted_obj);
        if (object.hasOwnProperty(brand_atom)) return error.TypeError;
        object.defineOwnProperty(ctx.runtime, brand_atom, core.Descriptor.data(core.Value.undefinedValue(), true, true, true)) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            else => return err,
        };
    }
}

pub fn privateIn(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toPropertyKeyAtom: anytype,
    comptime throwTypeErrorMessage: anytype,
) !void {
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    if (!obj.isObject()) {
        _ = try throwTypeErrorMessage(ctx, global, "invalid 'in' operand");
        return;
    }
    const found = if (key.isObject())
        try hasPrivateBrand(ctx.runtime, obj, key)
    else blk: {
        const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
        defer ctx.runtime.atoms.free(atom_id);
        const object = try property_ops.expectObject(obj);
        break :blk object.hasOwnProperty(atom_id);
    };
    try stack.pushOwned(core.Value.boolean(found));
}

pub fn defineClass(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.Value,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.Value,
    comptime handleCatchableRuntimeError: anytype,
    comptime createBytecodeFunctionObject: anytype,
    comptime objectPrototypeFromGlobal: anytype,
    comptime isConstructorLike: anytype,
    comptime getValueProperty: anytype,
    comptime toPropertyKeyAtom: anytype,
    comptime functionBytecodeFromValue: anytype,
    comptime clearPrivateNameRemap: anytype,
    comptime installLexicalPrivateNameRemap: anytype,
    comptime installFreshPrivateNameRemap: anytype,
    comptime copyPrivateNameRemap: anytype,
    comptime objectFromValue: anytype,
    comptime functionNameValueFromAtom: anytype,
    comptime defineFunctionNameProperty: anytype,
    is_computed_name: bool,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const flags = function.code[frame.pc + 4];
    frame.pc += 5;
    var ctor_source = try stack.pop();
    defer ctor_source.free(ctx.runtime);
    var parent_value = try stack.pop();
    defer parent_value.free(ctx.runtime);
    var saved_class_binding = core.Value.undefinedValue();
    var saved_class_binding_active = false;
    defer if (saved_class_binding_active) saved_class_binding.free(ctx.runtime);
    var superclass_value = core.Value.undefinedValue();
    var superclass_value_active = false;
    defer if (superclass_value_active) superclass_value.free(ctx.runtime);
    var ctor = core.Value.undefinedValue();
    defer ctor.free(ctx.runtime);
    var computed_key = core.Value.undefinedValue();
    defer computed_key.free(ctx.runtime);
    var name_value = core.Value.undefinedValue();
    defer name_value.free(ctx.runtime);
    var superclass_proto = core.Value.undefinedValue();
    defer superclass_proto.free(ctx.runtime);
    var proto_value = core.Value.undefinedValue();
    defer proto_value.free(ctx.runtime);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &ctor_source },
        .{ .value = &parent_value },
        .{ .value = &saved_class_binding },
        .{ .value = &superclass_value },
        .{ .value = &ctor },
        .{ .value = &computed_key },
        .{ .value = &name_value },
        .{ .value = &superclass_proto },
        .{ .value = &proto_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if ((flags & 1) != 0) {
        superclass_value = parent_value;
        superclass_value_active = true;
        parent_value = core.Value.undefinedValue();
        if (superclass_value.isUndefined() and stack.len() > 0) {
            saved_class_binding = superclass_value;
            saved_class_binding_active = true;
            superclass_value = try stack.pop();
        }
        if (!(superclass_value.isObject() or superclass_value.isNull())) {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return;
            return error.TypeError;
        }
    }
    ctor = try createBytecodeFunctionObject(ctx, frame, function, global, ctor_source, atom_id, op.define_class, false, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, &.{});
    const ctor_object = try property_ops.expectObject(ctor);
    if (is_computed_name) {
        computed_key = try stackValueFromTop(stack, 0);
        const name_atom = toPropertyKeyAtom(ctx, output, global, computed_key, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
            return err;
        };
        defer ctx.runtime.atoms.free(name_atom);
        name_value = try functionNameValueFromAtom(ctx.runtime, name_atom, null);
        try defineFunctionNameProperty(ctx.runtime, ctor_object, name_value);
        name_value.free(ctx.runtime);
        name_value = core.Value.undefinedValue();
        computed_key.free(ctx.runtime);
        computed_key = core.Value.undefinedValue();
    }
    var proto_parent: ?*core.Object = objectPrototypeFromGlobal(ctx.runtime, global);
    if (superclass_value_active) {
        if (superclass_value.isObject()) {
            if (!isConstructorLike(ctx, superclass_value)) {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return;
                return error.TypeError;
            }
            const superclass_object = try property_ops.expectObject(superclass_value);
            try ctor_object.setPrototype(ctx.runtime, superclass_object);
            ctor_object.functionSuperConstructorSlot().* = superclass_value.dup();
            superclass_proto = getValueProperty(ctx, output, global, superclass_value, core.atom.ids.prototype, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
                return err;
            };
            if (superclass_proto.isObject()) {
                proto_parent = try property_ops.expectObject(superclass_proto);
            } else if (!superclass_proto.isNull()) {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return;
                return error.TypeError;
            }
        } else {
            proto_parent = null;
        }
    }
    const proto = try core.Object.create(ctx.runtime, core.class.ids.object, proto_parent);
    proto_value = proto.value();
    try proto.defineOwnProperty(ctx.runtime, core.atom.ids.constructor, core.Descriptor.data(ctor_object.value(), true, false, true));
    try ctor_object.defineOwnProperty(ctx.runtime, core.atom.ids.prototype, core.Descriptor.data(proto_value, false, false, false));
    if (functionBytecodeFromValue(ctor_source)) |ctor_fb| {
        if (ctor_fb.private_bound_names.len != 0 or ctor_fb.class_private_names.len != 0) {
            clearPrivateNameRemap(ctx.runtime, proto);
            try installLexicalPrivateNameRemap(ctx.runtime, proto, frame, ctor_fb.private_bound_names);
            try installFreshPrivateNameRemap(ctx.runtime, proto, ctor_fb.class_private_names);
            try copyPrivateNameRemap(ctx.runtime, ctor_object, proto);
        }
    }
    ctor_object.setFunctionHomeObject(ctx.runtime, proto);
    if (ctor_object.functionClassFieldsInitSlot().*) |init_value| {
        if (objectFromValue(init_value)) |init_object| {
            init_object.setFunctionHomeObject(ctx.runtime, proto);
        }
    }
    if (saved_class_binding_active) {
        try stack.push(saved_class_binding);
    }
    try stack.push(ctor);
    try stack.push(proto_value);
}

pub fn defineMethod(
    ctx: *core.Context,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime remapPrivateAtomFromObject: anytype,
    comptime functionBytecodeFromValue: anytype,
    comptime installLexicalPrivateNameRemap: anytype,
    comptime functionNameValueFromAtom: anytype,
    comptime defineFunctionNameProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const flags = function.code[frame.pc];
    frame.pc += 1;
    defineObjectMethod(ctx.runtime, stack, atom_id, flags, frame, remapPrivateAtomFromObject, functionBytecodeFromValue, installLexicalPrivateNameRemap, functionNameValueFromAtom, defineFunctionNameProperty) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
}

pub fn defineMethodComputed(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime toPropertyKeyAtom: anytype,
    comptime remapPrivateAtomFromObject: anytype,
    comptime functionBytecodeFromValue: anytype,
    comptime installLexicalPrivateNameRemap: anytype,
    comptime functionNameValueFromAtom: anytype,
    comptime defineFunctionNameProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !void {
    const flags = function.code[frame.pc];
    frame.pc += 1;
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const key_value = try stack.pop();
    defer key_value.free(ctx.runtime);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    defineObjectMethodValue(ctx.runtime, stack, atom_id, value, flags, frame, remapPrivateAtomFromObject, functionBytecodeFromValue, installLexicalPrivateNameRemap, functionNameValueFromAtom, defineFunctionNameProperty) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
}

fn defineObjectMethod(
    rt: *core.Runtime,
    stack: *stack_mod.Stack,
    atom_id: core.Atom,
    flags: u8,
    caller_frame: ?*frame_mod.Frame,
    comptime remapPrivateAtomFromObject: anytype,
    comptime functionBytecodeFromValue: anytype,
    comptime installLexicalPrivateNameRemap: anytype,
    comptime functionNameValueFromAtom: anytype,
    comptime defineFunctionNameProperty: anytype,
) !void {
    if (stack.values.len < 2) {
        const maybe_object = stack.peek() orelse return error.StackUnderflow;
        defer maybe_object.free(rt);
        _ = property_ops.expectObject(maybe_object) catch return error.StackUnderflow;
        return;
    }
    const value = try stack.pop();
    defer value.free(rt);
    try defineObjectMethodValue(rt, stack, atom_id, value, flags, caller_frame, remapPrivateAtomFromObject, functionBytecodeFromValue, installLexicalPrivateNameRemap, functionNameValueFromAtom, defineFunctionNameProperty);
}

fn defineObjectMethodValue(
    rt: *core.Runtime,
    stack: *stack_mod.Stack,
    atom_id: core.Atom,
    value: core.Value,
    flags: u8,
    caller_frame: ?*frame_mod.Frame,
    comptime remapPrivateAtomFromObject: anytype,
    comptime functionBytecodeFromValue: anytype,
    comptime installLexicalPrivateNameRemap: anytype,
    comptime functionNameValueFromAtom: anytype,
    comptime defineFunctionNameProperty: anytype,
) !void {
    const obj = stack.peek() orelse return error.StackUnderflow;
    var rooted_obj = obj;
    defer obj.free(rt);
    var rooted_value = value;
    var name_value = core.Value.undefinedValue();
    defer name_value.free(rt);
    var getter = core.Value.undefinedValue();
    defer getter.free(rt);
    var setter = core.Value.undefinedValue();
    defer setter.free(rt);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_obj },
        .{ .value = &rooted_value },
        .{ .value = &name_value },
        .{ .value = &getter },
        .{ .value = &setter },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try property_ops.expectObject(obj);
    const effective_atom = remapPrivateAtomFromObject(rt, object, atom_id);
    if (rooted_value.isObject()) {
        const function_object = try property_ops.expectObject(rooted_value);
        function_object.setFunctionHomeObject(rt, object);
        if (function_object.functionBytecodeSlot().*) |function_bytecode_value| {
            if (functionBytecodeFromValue(function_bytecode_value)) |fb| {
                try installLexicalPrivateNameRemap(rt, object, caller_frame, fb.private_bound_names);
            }
        }
        const prefix: ?[]const u8 = switch (flags & 3) {
            1 => "get",
            2 => "set",
            else => null,
        };
        name_value = try functionNameValueFromAtom(rt, effective_atom, prefix);
        try defineFunctionNameProperty(rt, function_object, name_value);
        name_value.free(rt);
        name_value = core.Value.undefinedValue();
    }
    const enumerable = (flags & 4) != 0;
    if ((flags & 3) == 1 or (flags & 3) == 2) {
        if (object.getOwnProperty(effective_atom)) |existing| {
            defer existing.destroy(rt);
            if (existing.kind == .accessor) {
                getter = existing.getter.dup();
                setter = existing.setter.dup();
            }
        }
        const desc = if ((flags & 3) == 1)
            core.Descriptor.accessor(rooted_value, setter, enumerable, true)
        else
            core.Descriptor.accessor(getter, rooted_value, enumerable, true);
        object.defineOwnProperty(rt, effective_atom, desc) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            else => return err,
        };
        getter.free(rt);
        getter = core.Value.undefinedValue();
        setter.free(rt);
        setter = core.Value.undefinedValue();
        return;
    }
    const writable = rt.atoms.kind(atom_id) != .private;
    object.defineOwnProperty(rt, effective_atom, core.Descriptor.data(rooted_value, writable, enumerable, true)) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        else => return err,
    };
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.Value {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.values.len) return error.StackUnderflow;
    return stack.values[stack.values.len - 1 - index_from_top].dup();
}

fn ensureHomeObjectBrand(rt: *core.Runtime, home: *core.Object) !core.Atom {
    if (home.getOwnProperty(core.atom.ids.Private_brand)) |desc| {
        defer desc.destroy(rt);
        if (desc.value.asSymbolAtom()) |brand_atom| return brand_atom;
        return error.TypeError;
    }
    const name = rt.atoms.name(core.atom.ids.Private_brand) orelse "<brand>";
    if (!home.isExtensible()) return error.NotExtensible;
    const brand_atom = try rt.atoms.newSymbol(name, .private);
    defer rt.atoms.free(brand_atom);
    try home.defineOwnProperty(rt, core.atom.ids.Private_brand, core.Descriptor.data(core.Value.symbol(brand_atom), true, true, true));
    return brand_atom;
}

fn hasPrivateBrand(rt: *core.Runtime, obj: core.Value, func: core.Value) !bool {
    const object = try property_ops.expectObject(obj);
    const func_object = try property_ops.expectObject(func);
    const home = func_object.functionHomeObjectSlot().* orelse return error.TypeError;
    const desc = home.getOwnProperty(core.atom.ids.Private_brand) orelse return error.TypeError;
    defer desc.destroy(rt);
    const brand_atom = desc.value.asSymbolAtom() orelse return error.TypeError;
    return object.hasOwnProperty(brand_atom);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

test "private brand atom is released with home object" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const home = try core.Object.create(rt, core.class.ids.object, null);
    const brand_atom = try ensureHomeObjectBrand(rt, home);
    try std.testing.expectEqual(core.atom.AtomKind.private, rt.atoms.kind(brand_atom).?);

    home.value().free(rt);
    try std.testing.expect(rt.atoms.name(brand_atom) == null);
}

test "private brand creation does not allocate atom for non-extensible home object" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const home = try core.Object.create(rt, core.class.ids.object, null);
    defer home.value().free(rt);
    home.preventExtensions();
    const before_entries = rt.atoms.entries.len;

    try std.testing.expectError(error.NotExtensible, ensureHomeObjectBrand(rt, home));
    try std.testing.expectEqual(before_entries, rt.atoms.entries.len);
}
