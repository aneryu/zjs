const std = @import("std");

const bytecode = @import("../../bytecode/root.zig");
const builtins = @import("../../builtins/root.zig");
const core = @import("../../core/root.zig");
const frame_mod = @import("../frame.zig");
const property_ops = @import("../property_ops.zig");
const value_ops = @import("../value_ops.zig");
const shared_vm = @import("shared.zig");

const SetMethodMode = enum {
    difference,
    intersection,
    is_disjoint_from,
    is_subset_of,
    is_superset_of,
    symmetric_difference,
    union_,
};

const SetLikeRecordVm = struct {
    object_value: core.Value,
    size: f64,
    has: core.Value,
    keys: core.Value,
    native_kind: enum { none, set, map },

    fn deinit(self: *const SetLikeRecordVm, rt: *core.Runtime) void {
        self.object_value.free(rt);
        self.has.free(rt);
        self.keys.free(rt);
    }
};

pub fn qjsCollectionIteratorMethodCall(
    ctx: *core.Context,
    global: *core.Object,
    this_value: core.Value,
    function_object: *core.Object,
    name: []const u8,
    args: []const core.Value,
) !?core.Value {
    _ = args;
    const owner_class = collectionMethodOwnerClass(function_object) orelse return null;
    if (owner_class != core.class.ids.map and owner_class != core.class.ids.set) return null;
    const method_id: u32 = if (std.mem.eql(u8, name, "keys"))
        7
    else if (std.mem.eql(u8, name, "values"))
        8
    else if (std.mem.eql(u8, name, "entries"))
        9
    else
        return null;
    const receiver = shared_vm.objectFromValue(this_value) orelse return @as(?core.Value, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    if (receiver.class_id != owner_class) return @as(?core.Value, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    return try builtins.collection.methodCallWithGlobal(ctx, global, this_value, method_id, &.{}, &.{});
}

pub fn qjsCollectionForEachCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.Value,
    function_object: *core.Object,
    name: []const u8,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Value {
    if (!std.mem.eql(u8, name, "forEach")) return null;
    const owner_class = collectionMethodOwnerClass(function_object) orelse return null;
    if (owner_class != core.class.ids.map and owner_class != core.class.ids.set) return null;
    const receiver = shared_vm.objectFromValue(this_value) orelse return @as(?core.Value, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    if (receiver.class_id != owner_class) return @as(?core.Value, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    if (args.len < 1 or !shared_vm.isCallableValue(args[0])) return error.TypeError;
    const callback = args[0];
    const this_arg = if (args.len >= 2) args[1] else core.Value.undefinedValue();
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        const callback_args = if (receiver.class_id == core.class.ids.set)
            [_]core.Value{ entry.key, entry.key, receiver.value() }
        else
            [_]core.Value{ entry.value, entry.key, receiver.value() };
        const result = try shared_vm.callValueOrBytecode(ctx, output, global, this_arg, callback, &callback_args, caller_function, caller_frame);
        result.free(ctx.runtime);
    }
    return core.Value.undefinedValue();
}

pub fn qjsSetMethodCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.Value,
    function_object: *core.Object,
    name: []const u8,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Value {
    const owner_class = collectionMethodOwnerClass(function_object) orelse return null;
    if (owner_class != core.class.ids.set) return null;
    const mode = qjsSetMethodMode(name) orelse return null;
    const receiver = shared_vm.objectFromValue(this_value) orelse return @as(?core.Value, try throwCollectionReceiverTypeError(ctx, global, core.class.ids.set));
    if (receiver.class_id != core.class.ids.set) return @as(?core.Value, try throwCollectionReceiverTypeError(ctx, global, core.class.ids.set));
    const other_value = if (args.len >= 1) args[0] else return error.TypeError;
    var other_record = try qjsGetSetRecord(ctx, output, global, other_value, caller_function, caller_frame);
    defer other_record.deinit(ctx.runtime);
    return switch (mode) {
        .difference => try qjsSetDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .intersection => try qjsSetIntersection(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_disjoint_from => try qjsSetIsDisjointFrom(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_subset_of => try qjsSetIsSubsetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_superset_of => try qjsSetIsSupersetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .symmetric_difference => try qjsSetSymmetricDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .union_ => try qjsSetUnion(ctx, output, global, receiver, other_record, caller_function, caller_frame),
    };
}

pub fn qjsCollectionNativeRecord(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.Value,
    function_object: *core.Object,
    id: u32,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Value {
    const receiver = shared_vm.objectFromValue(this_value) orelse {
        if (collectionMethodOwnerClass(function_object)) |owner_class| {
            return @as(?core.Value, try throwCollectionReceiverTypeError(ctx, global, owner_class));
        }
        return error.TypeError;
    };
    if (collectionMethodOwnerClass(function_object)) |owner_class| {
        if (receiver.class_id != owner_class) return @as(?core.Value, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    }

    const method: builtins.collection.PrototypeMethod = switch (id) {
        @intFromEnum(builtins.collection.PrototypeMethod.set) => .set,
        @intFromEnum(builtins.collection.PrototypeMethod.get) => .get,
        @intFromEnum(builtins.collection.PrototypeMethod.has) => .has,
        @intFromEnum(builtins.collection.PrototypeMethod.delete) => .delete,
        @intFromEnum(builtins.collection.PrototypeMethod.clear) => .clear,
        @intFromEnum(builtins.collection.PrototypeMethod.add) => .add,
        @intFromEnum(builtins.collection.PrototypeMethod.keys) => .keys,
        @intFromEnum(builtins.collection.PrototypeMethod.values) => .values,
        @intFromEnum(builtins.collection.PrototypeMethod.entries) => .entries,
        @intFromEnum(builtins.collection.PrototypeMethod.for_each) => .for_each,
        @intFromEnum(builtins.collection.PrototypeMethod.get_or_insert) => .get_or_insert,
        @intFromEnum(builtins.collection.PrototypeMethod.get_or_insert_computed) => .get_or_insert_computed,
        @intFromEnum(builtins.collection.PrototypeMethod.size_getter) => .size_getter,
        @intFromEnum(builtins.collection.PrototypeMethod.difference) => .difference,
        @intFromEnum(builtins.collection.PrototypeMethod.intersection) => .intersection,
        @intFromEnum(builtins.collection.PrototypeMethod.is_disjoint_from) => .is_disjoint_from,
        @intFromEnum(builtins.collection.PrototypeMethod.is_subset_of) => .is_subset_of,
        @intFromEnum(builtins.collection.PrototypeMethod.is_superset_of) => .is_superset_of,
        @intFromEnum(builtins.collection.PrototypeMethod.symmetric_difference) => .symmetric_difference,
        @intFromEnum(builtins.collection.PrototypeMethod.union_) => .union_,
        else => return null,
    };

    if (collectionCallResultIsDropped(caller_function, caller_frame)) {
        const handled = builtins.collection.methodCallDroppedResult(ctx.runtime, receiver, id, args) catch |err| switch (err) {
            error.TypeError => return @as(?core.Value, try throwCollectionMethodTypeError(ctx, global, receiver, method, args)),
            else => return err,
        };
        if (handled) return core.Value.undefinedValue();
    }

    return switch (method) {
        .set,
        .get,
        .has,
        .delete,
        .clear,
        .add,
        .keys,
        .values,
        .entries,
        .get_or_insert,
        .size_getter,
        => builtins.collection.methodCallWithGlobal(ctx, global, this_value, id, args, &.{}) catch |err| switch (err) {
            error.TypeError => return @as(?core.Value, try throwCollectionMethodTypeError(ctx, global, receiver, method, args)),
            else => err,
        },
        .for_each => try qjsCollectionForEachRecord(ctx, output, global, this_value, receiver, args, caller_function, caller_frame),
        .get_or_insert_computed => try qjsMapGetOrInsertComputed(ctx, output, global, this_value, function_object, args, caller_function, caller_frame),
        .difference,
        .intersection,
        .is_disjoint_from,
        .is_subset_of,
        .is_superset_of,
        .symmetric_difference,
        .union_,
        => try qjsSetMethodRecord(ctx, output, global, receiver, method, args, caller_function, caller_frame),
        .iterator_next => return null,
    };
}

fn collectionCallResultIsDropped(caller_function: ?*const bytecode.Bytecode, caller_frame: ?*frame_mod.Frame) bool {
    const function = caller_function orelse return false;
    const frame = caller_frame orelse return false;
    return frame.pc < function.code.len and function.code[frame.pc] == bytecode.opcode.op.drop;
}

fn qjsCollectionForEachRecord(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.Value,
    receiver: *core.Object,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    if (receiver.class_id != core.class.ids.map and receiver.class_id != core.class.ids.set) return throwCollectionReceiverTypeError(ctx, global, receiver.class_id);
    if (args.len < 1 or !shared_vm.isCallableValue(args[0])) return error.TypeError;
    const callback = args[0];
    const this_arg = if (args.len >= 2) args[1] else core.Value.undefinedValue();
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        const callback_args = if (receiver.class_id == core.class.ids.set)
            [_]core.Value{ entry.key, entry.key, this_value }
        else
            [_]core.Value{ entry.value, entry.key, this_value };
        const result = try shared_vm.callValueOrBytecode(ctx, output, global, this_arg, callback, &callback_args, caller_function, caller_frame);
        result.free(ctx.runtime);
    }
    return core.Value.undefinedValue();
}

fn qjsSetMethodRecord(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    method: builtins.collection.PrototypeMethod,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    if (receiver.class_id != core.class.ids.set) return throwCollectionReceiverTypeError(ctx, global, core.class.ids.set);
    const other_value = if (args.len >= 1) args[0] else return error.TypeError;
    var other_record = try qjsGetSetRecord(ctx, output, global, other_value, caller_function, caller_frame);
    defer other_record.deinit(ctx.runtime);
    const mode = qjsSetMethodModeFromRecord(method) orelse return error.TypeError;
    return switch (mode) {
        .difference => try qjsSetDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .intersection => try qjsSetIntersection(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_disjoint_from => try qjsSetIsDisjointFrom(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_subset_of => try qjsSetIsSubsetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_superset_of => try qjsSetIsSupersetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .symmetric_difference => try qjsSetSymmetricDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .union_ => try qjsSetUnion(ctx, output, global, receiver, other_record, caller_function, caller_frame),
    };
}

fn qjsSetMethodMode(name: []const u8) ?SetMethodMode {
    if (std.mem.eql(u8, name, "difference")) return .difference;
    if (std.mem.eql(u8, name, "intersection")) return .intersection;
    if (std.mem.eql(u8, name, "isDisjointFrom")) return .is_disjoint_from;
    if (std.mem.eql(u8, name, "isSubsetOf")) return .is_subset_of;
    if (std.mem.eql(u8, name, "isSupersetOf")) return .is_superset_of;
    if (std.mem.eql(u8, name, "symmetricDifference")) return .symmetric_difference;
    if (std.mem.eql(u8, name, "union")) return .union_;
    return null;
}

fn qjsSetMethodModeFromRecord(method: builtins.collection.PrototypeMethod) ?SetMethodMode {
    return switch (method) {
        .difference => .difference,
        .intersection => .intersection,
        .is_disjoint_from => .is_disjoint_from,
        .is_subset_of => .is_subset_of,
        .is_superset_of => .is_superset_of,
        .symmetric_difference => .symmetric_difference,
        .union_ => .union_,
        else => null,
    };
}

fn qjsGetSetRecord(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    other_value: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !SetLikeRecordVm {
    const object = shared_vm.objectFromValue(other_value) orelse return error.TypeError;
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) {
        return .{
            .object_value = other_value.dup(),
            .size = @floatFromInt(qjsSetStrongSize(object)),
            .has = core.Value.undefinedValue(),
            .keys = core.Value.undefinedValue(),
            .native_kind = if (object.class_id == core.class.ids.set) .set else .map,
        };
    }

    const raw_size = try shared_vm.getValueProperty(ctx, output, global, other_value, core.atom.predefinedId("size", .string).?, caller_function, caller_frame);
    defer raw_size.free(ctx.runtime);
    const size_value = if (raw_size.isObject())
        try shared_vm.toPrimitiveForNumber(ctx, output, global, raw_size)
    else
        raw_size.dup();
    defer size_value.free(ctx.runtime);
    const number_value = try value_ops.toNumberValue(ctx.runtime, size_value);
    defer number_value.free(ctx.runtime);
    const size_number = value_ops.numberValue(number_value) orelse return error.TypeError;
    if (std.math.isNan(size_number)) return error.TypeError;

    const has_key = try ctx.runtime.internAtom("has");
    defer ctx.runtime.atoms.free(has_key);
    const has_value = try shared_vm.getValueProperty(ctx, output, global, other_value, has_key, caller_function, caller_frame);
    errdefer has_value.free(ctx.runtime);
    if (!shared_vm.isCallableValue(has_value)) return error.TypeError;

    const keys_key = try ctx.runtime.internAtom("keys");
    defer ctx.runtime.atoms.free(keys_key);
    const keys_value = try shared_vm.getValueProperty(ctx, output, global, other_value, keys_key, caller_function, caller_frame);
    errdefer keys_value.free(ctx.runtime);
    if (!shared_vm.isCallableValue(keys_value)) return error.TypeError;

    return .{
        .object_value = other_value.dup(),
        .size = size_number,
        .has = has_value,
        .keys = keys_value,
        .native_kind = .none,
    };
}

fn qjsSetStrongSize(object: *core.Object) usize {
    var count: usize = 0;
    for (object.collectionEntriesSlot().*) |entry| {
        if (entry.active) count += 1;
    }
    return count;
}

fn qjsConstructPlainSet(ctx: *core.Context, global: *core.Object) !core.Value {
    const set_proto = shared_vm.constructorPrototypeFromGlobal(ctx.runtime, global, "Set") orelse return error.TypeError;
    return builtins.collection.constructWithPrototype(ctx.runtime, 2, set_proto);
}

fn qjsSetAddValue(rt: *core.Runtime, set_value: core.Value, key: core.Value) !void {
    const out = try builtins.collection.methodCall(rt, set_value, 6, &.{key});
    out.free(rt);
}

fn qjsSetDeleteValue(rt: *core.Runtime, set_value: core.Value, key: core.Value) !void {
    const out = try builtins.collection.methodCall(rt, set_value, 4, &.{key});
    out.free(rt);
}

fn qjsSetHasValue(rt: *core.Runtime, set_value: core.Value, key: core.Value) !bool {
    const out = try builtins.collection.methodCall(rt, set_value, 3, &.{key});
    defer out.free(rt);
    return shared_vm.valueTruthy(out);
}

fn qjsSetLikeHas(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    record: SetLikeRecordVm,
    key: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (record.native_kind != .none) {
        const out = try builtins.collection.methodCall(ctx.runtime, record.object_value, 3, &.{key});
        defer out.free(ctx.runtime);
        return shared_vm.valueTruthy(out);
    }
    const out = try shared_vm.callValueOrBytecode(ctx, output, global, record.object_value, record.has, &.{key}, caller_function, caller_frame);
    defer out.free(ctx.runtime);
    return shared_vm.valueTruthy(out);
}

fn qjsSetLikeKeysIterator(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    const source = if (record.native_kind != .none)
        try builtins.collection.methodCall(ctx.runtime, record.object_value, 7, &.{})
    else
        try shared_vm.callValueOrBytecode(ctx, output, global, record.object_value, record.keys, &.{}, caller_function, caller_frame);
    errdefer source.free(ctx.runtime);
    const iterator_object = shared_vm.objectFromValue(source) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try shared_vm.getValueProperty(ctx, output, global, source, next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!shared_vm.isCallableValue(next_method)) return error.TypeError;
    const cached = iterator_object.cachedIteratorNextSlot();
    const next_cached = next_method.dup();
    const old_cached = cached.*;
    cached.* = next_cached;
    if (old_cached) |stored| stored.free(ctx.runtime);
    return source;
}

fn qjsSetCloneReceiver(ctx: *core.Context, global: *core.Object, receiver: *core.Object) !core.Value {
    const result_value = try qjsConstructPlainSet(ctx, global);
    errdefer result_value.free(ctx.runtime);
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        try qjsSetAddValue(ctx.runtime, result_value, entry.key);
    }
    return result_value;
}

fn qjsSetSnapshotKeys(rt: *core.Runtime, receiver: *core.Object) ![]core.Value {
    const count = qjsSetStrongSize(receiver);
    if (count == 0) return &.{};
    const keys = try rt.memory.alloc(core.Value, count);
    errdefer rt.memory.free(core.Value, keys);
    var out: usize = 0;
    errdefer {
        for (keys[0..out]) |key| key.free(rt);
    }
    for (receiver.collectionEntriesSlot().*) |entry| {
        if (!entry.active) continue;
        keys[out] = entry.key.dup();
        out += 1;
    }
    return keys;
}

fn qjsFreeValueList(rt: *core.Runtime, values: []core.Value) void {
    for (values) |value| value.free(rt);
    if (values.len != 0) rt.memory.free(core.Value, values);
}

fn qjsSetDifference(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    const result_value = try qjsConstructPlainSet(ctx, global);
    errdefer result_value.free(ctx.runtime);
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) > other_record.size) {
        var copy_index: usize = 0;
        while (copy_index < receiver.collectionEntriesSlot().*.len) : (copy_index += 1) {
            const entry = receiver.collectionEntriesSlot().*[copy_index];
            if (!entry.active) continue;
            try qjsSetAddValue(ctx.runtime, result_value, entry.key);
        }
        var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
        defer iterator_value.free(ctx.runtime);
        var iterator_done = false;
        while (true) {
            const step = shared_vm.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
                if (!iterator_done) shared_vm.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
                return err;
            };
            defer step.value.free(ctx.runtime);
            if (step.done) {
                iterator_done = true;
                break;
            }
            try qjsSetDeleteValue(ctx.runtime, result_value, step.value);
        }
    } else {
        const keys = try qjsSetSnapshotKeys(ctx.runtime, receiver);
        defer qjsFreeValueList(ctx.runtime, keys);
        for (keys) |key| {
            if (!try qjsSetLikeHas(ctx, output, global, other_record, key, caller_function, caller_frame)) {
                try qjsSetAddValue(ctx.runtime, result_value, key);
            }
        }
    }
    return result_value;
}

fn qjsSetIntersection(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    const result_value = try qjsConstructPlainSet(ctx, global);
    errdefer result_value.free(ctx.runtime);
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) <= other_record.size) {
        var index: usize = 0;
        while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
            const entry = receiver.collectionEntriesSlot().*[index];
            if (!entry.active) continue;
            if (try qjsSetLikeHas(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
                try qjsSetAddValue(ctx.runtime, result_value, entry.key);
            }
        }
    } else {
        var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
        defer iterator_value.free(ctx.runtime);
        var iterator_done = false;
        while (true) {
            const step = shared_vm.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
                if (!iterator_done) shared_vm.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
                return err;
            };
            defer step.value.free(ctx.runtime);
            if (step.done) {
                iterator_done = true;
                break;
            }
            if (try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
                try qjsSetAddValue(ctx.runtime, result_value, step.value);
            }
        }
    }
    return result_value;
}

fn qjsSetUnion(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    const result_value = try qjsSetCloneReceiver(ctx, global, receiver);
    errdefer result_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = shared_vm.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) shared_vm.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            break;
        }
        try qjsSetAddValue(ctx.runtime, result_value, step.value);
    }
    return result_value;
}

fn qjsSetSymmetricDifference(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    const result_value = try qjsSetCloneReceiver(ctx, global, receiver);
    errdefer result_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = shared_vm.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) shared_vm.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            break;
        }
        if (try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
            try qjsSetDeleteValue(ctx.runtime, result_value, step.value);
        } else if (!try qjsSetHasValue(ctx.runtime, result_value, step.value)) {
            try qjsSetAddValue(ctx.runtime, result_value, step.value);
        }
    }
    return result_value;
}

fn qjsSetIsDisjointFrom(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) <= other_record.size) {
        var index: usize = 0;
        while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
            const entry = receiver.collectionEntriesSlot().*[index];
            if (!entry.active) continue;
            if (try qjsSetLikeHas(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
                return core.Value.boolean(false);
            }
        }
        return core.Value.boolean(true);
    }

    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = shared_vm.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) shared_vm.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            return core.Value.boolean(true);
        }
        if (try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
            shared_vm.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            iterator_done = true;
            return core.Value.boolean(false);
        }
    }
}

fn qjsSetIsSubsetOf(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) > other_record.size) return core.Value.boolean(false);
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        if (!try qjsSetLikeHas(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
            return core.Value.boolean(false);
        }
    }
    return core.Value.boolean(true);
}

fn qjsSetIsSupersetOf(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) < other_record.size) return core.Value.boolean(false);
    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = shared_vm.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) shared_vm.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            return core.Value.boolean(true);
        }
        if (!try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
            shared_vm.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            iterator_done = true;
            return core.Value.boolean(false);
        }
    }
}

pub fn qjsMapGroupByCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Value {
    const map_proto = shared_vm.constructorPrototypeFromGlobal(ctx.runtime, global, "Map") orelse return error.TypeError;
    return qjsMapGroupByRecord(ctx, output, global, args, map_proto, caller_function, caller_frame);
}

pub fn qjsMapGroupByRecord(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.Value,
    prototype: ?*core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Value {
    if (args.len < 2) return error.TypeError;
    if (!shared_vm.isCallableValue(args[1])) return error.TypeError;

    const map_value = try builtins.collection.constructWithPrototype(ctx.runtime, 1, prototype);
    errdefer map_value.free(ctx.runtime);

    const iterator_value = try shared_vm.iteratorForValue(ctx, output, global, args[0], caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);

    var index: usize = 0;
    while (true) {
        const max_safe_integer: usize = 9007199254740991;
        if (index >= max_safe_integer) {
            try shared_vm.closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return error.TypeError;
        }

        const step = try shared_vm.iteratorStepValue(ctx, output, global, iterator_value);
        defer step.value.free(ctx.runtime);
        if (step.done) return map_value;

        const index_value = value_ops.numberToValue(@floatFromInt(index));
        const key = shared_vm.callValueOrBytecode(
            ctx,
            output,
            global,
            core.Value.undefinedValue(),
            args[1],
            &.{ step.value, index_value },
            caller_function,
            caller_frame,
        ) catch |err| {
            try shared_vm.closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer key.free(ctx.runtime);

        qjsMapAppendGroupByValue(ctx, global, map_value, key, step.value) catch |err| {
            try shared_vm.closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        index += 1;
    }
}

pub fn qjsMapGetOrInsertComputed(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.Value,
    function_object: *core.Object,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Value {
    const receiver = property_ops.expectObject(receiver_value) catch return null;
    if (receiver.class_id != core.class.ids.weakmap and receiver.class_id != core.class.ids.map) return null;
    if (collectionMethodOwnerClass(function_object)) |owner_class| {
        if (receiver.class_id != owner_class) return @as(?core.Value, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    }
    if (args.len < 2) return error.TypeError;
    if (!shared_vm.isCallableValue(args[1])) return error.TypeError;

    const key = if (receiver.class_id == core.class.ids.map)
        canonicalizeMapKey(args[0])
    else
        args[0].dup();
    defer key.free(ctx.runtime);
    if (receiver.class_id == core.class.ids.weakmap and !canBeHeldWeakly(ctx.runtime, key)) {
        return @as(?core.Value, try shared_vm.throwTypeErrorMessage(ctx, global, "invalid value used as WeakMap key"));
    }

    const has_value = try builtins.collection.methodCall(ctx.runtime, receiver_value, 3, &.{key});
    defer has_value.free(ctx.runtime);
    if (has_value.asBool() == true) {
        return try builtins.collection.methodCall(ctx.runtime, receiver_value, 2, &.{key});
    }

    const computed = try shared_vm.callValueOrBytecode(
        ctx,
        output,
        global,
        core.Value.undefinedValue(),
        args[1],
        &.{key},
        caller_function,
        caller_frame,
    );
    errdefer computed.free(ctx.runtime);
    const set_result = try builtins.collection.methodCall(ctx.runtime, receiver_value, 1, &.{ key, computed });
    set_result.free(ctx.runtime);
    return computed;
}

pub fn canBeHeldWeakly(rt: *core.Runtime, value: core.Value) bool {
    if (value.isObject()) return true;
    if (value.asSymbolAtom()) |atom_id| {
        return rt.atoms.kind(atom_id) == .symbol and builtins.symbol.registryKey(&rt.atoms, atom_id) == null;
    }
    return false;
}

pub fn collectionMethodOwnerClass(function_object: *core.Object) ?core.ClassId {
    const cached = function_object.collectionMethodOwnerClass();
    if (cached != core.class.invalid_class_id) return cached;
    return null;
}

fn canonicalizeMapKey(key: core.Value) core.Value {
    if (key.asFloat64()) |number| {
        if (number == 0) return core.Value.int32(0);
    }
    return key.dup();
}

fn throwCollectionReceiverTypeError(ctx: *core.Context, global: *core.Object, owner_class: core.ClassId) !core.Value {
    return shared_vm.throwTypeErrorMessage(ctx, global, collectionReceiverMessage(owner_class));
}

fn throwCollectionMethodTypeError(
    ctx: *core.Context,
    global: *core.Object,
    receiver: *core.Object,
    method: builtins.collection.PrototypeMethod,
    args: []const core.Value,
) !core.Value {
    if (receiver.class_id == core.class.ids.weakmap and
        (method == .set or method == .get_or_insert or method == .get_or_insert_computed) and
        args.len >= 1 and !canBeHeldWeakly(ctx.runtime, args[0]))
    {
        return shared_vm.throwTypeErrorMessage(ctx, global, "invalid value used as WeakMap key");
    }
    if (receiver.class_id == core.class.ids.weakset and
        method == .add and
        args.len >= 1 and !canBeHeldWeakly(ctx.runtime, args[0]))
    {
        return shared_vm.throwTypeErrorMessage(ctx, global, "invalid value used in weak set");
    }
    return shared_vm.throwTypeErrorMessage(ctx, global, collectionReceiverMessage(receiver.class_id));
}

fn collectionReceiverMessage(owner_class: core.ClassId) []const u8 {
    if (owner_class == core.class.ids.map) return "Map object expected";
    if (owner_class == core.class.ids.set) return "Set object expected";
    if (owner_class == core.class.ids.weakmap) return "WeakMap object expected";
    if (owner_class == core.class.ids.weakset) return "WeakSet object expected";
    return "not an object";
}

fn qjsMapAppendGroupByValue(
    ctx: *core.Context,
    global: *core.Object,
    map_value: core.Value,
    key: core.Value,
    value: core.Value,
) !void {
    const existing = try builtins.collection.methodCall(ctx.runtime, map_value, 2, &.{key});
    defer existing.free(ctx.runtime);

    if (!existing.isUndefined()) {
        const group = try property_ops.expectObject(existing);
        if (!group.is_array) return error.TypeError;
        try group.defineOwnProperty(
            ctx.runtime,
            core.atom.atomFromUInt32(group.length),
            core.Descriptor.data(value, true, true, true),
        );
        return;
    }

    const group = try core.Object.createArray(ctx.runtime, shared_vm.arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &group.header);
    try group.defineOwnProperty(
        ctx.runtime,
        core.atom.atomFromUInt32(group.length),
        core.Descriptor.data(value, true, true, true),
    );
    const set_result = try builtins.collection.methodCall(ctx.runtime, map_value, 1, &.{ key, group.value() });
    defer set_result.free(ctx.runtime);
    group.value().free(ctx.runtime);
}
