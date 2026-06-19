const fusion_stats = @import("vm_fusion_stats.zig");
const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const call_mod = @import("call.zig");
const object_ops = @import("object_ops.zig");
const stack_mod = @import("stack.zig");

const op = bytecode.opcode.op;

pub const Step = enum { done, continue_loop };

pub noinline fn object(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    global: *core.Object,
) !void {
    const created = try core.Object.create(ctx.runtime, core.class.ids.object, object_ops.objectPrototypeFromGlobal(ctx.runtime, global));
    const value = created.value();
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub noinline fn arrayFrom(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
) !void {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    var stack_values: [8]core.JSValue = undefined;
    const values = if (argc <= stack_values.len)
        stack_values[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > stack_values.len) ctx.runtime.memory.free(core.JSValue, values);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        values[remaining] = try stack.pop();
    }
    defer for (values) |value| value.free(ctx.runtime);
    const array = try core.array.constructLiteralWithPrototype(ctx.runtime, values, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer array.free(ctx.runtime);
    try stack.pushOwned(array);
}

const DecodedFieldAtom = struct {
    atom_id: core.Atom,
    next_pc: usize,
};

fn decodeFieldAtom(code: []const u8, pc: usize, expected_op: u8) ?DecodedFieldAtom {
    if (pc + 5 > code.len or code[pc] != expected_op) return null;
    return .{
        .atom_id = readInt(u32, code[pc + 1 ..][0..4]),
        .next_pc = pc + 5,
    };
}

fn canFinishWithUndefinedAt(function: *const bytecode.Bytecode, pc: usize) bool {
    if (function.flags.is_generator or function.flags.is_async) return false;
    const code = function.code;
    if (pc >= code.len) return false;
    if (code[pc] == op.return_undef) return true;
    return pc + 2 == code.len and code[pc] == op.undefined and code[pc + 1] == op.return_async;
}

const DecodedGet = struct {
    idx: u16,
    next_pc: usize,
};

fn decodeLocalGet(code: []const u8, pc: usize) ?DecodedGet {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_loc0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.get_loc1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.get_loc2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.get_loc3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.get_loc, op.get_loc_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        op.get_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .idx = code[pc + 1], .next_pc = pc + 2 };
        },
        else => null,
    };
}

fn decodeVarRefGet(code: []const u8, pc: usize) ?DecodedGet {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_var_ref0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.get_var_ref1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.get_var_ref2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.get_var_ref3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.get_var_ref, op.get_var_ref_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        else => null,
    };
}

const ImmediateInt32 = struct {
    value: i32,
    next_pc: usize,
};

fn immediateInt32Operand(code: []const u8, pc: usize) ?ImmediateInt32 {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.push_0 => .{ .value = 0, .next_pc = pc + 1 },
        op.push_1 => .{ .value = 1, .next_pc = pc + 1 },
        op.push_2 => .{ .value = 2, .next_pc = pc + 1 },
        op.push_3 => .{ .value = 3, .next_pc = pc + 1 },
        op.push_4 => .{ .value = 4, .next_pc = pc + 1 },
        op.push_5 => .{ .value = 5, .next_pc = pc + 1 },
        op.push_6 => .{ .value = 6, .next_pc = pc + 1 },
        op.push_7 => .{ .value = 7, .next_pc = pc + 1 },
        op.push_i8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .value = @as(i8, @bitCast(code[pc + 1])), .next_pc = pc + 2 };
        },
        op.push_i16 => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .value = readInt(i16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        op.push_i32 => blk: {
            if (pc + 5 > code.len) return null;
            break :blk .{ .value = readInt(i32, code[pc + 1 ..][0..4]), .next_pc = pc + 5 };
        },
        else => null,
    };
}

fn canUseFastGlobalUndefinedLookup(
    function: *const bytecode.Bytecode,
    frame: *const frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    if (!eval_with_object.isUndefined()) return false;
    if (!frame.current_function.isUndefined()) return false;
    if (frameHasVarRefBinding(function, frame, core.atom.ids.undefined_)) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;
    return true;
}

fn frameHasVarRefBinding(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const count = @min(frame.var_refs.len, function.var_ref_names.len);
    for (function.var_ref_names[0..count]) |name| {
        if (name == atom_id) return true;
    }
    return false;
}

pub noinline fn defineField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const value = try stack.pop();
    const obj = stack.peekBorrowed() orelse return error.StackUnderflow;
    if (!value.requiresRefCount() and ctx.runtime.atoms.kind(atom_id) != .private) {
        if (property_ops.expectObject(obj)) |target| {
            if (target.class_id == core.class.ids.object and
                target.exotic == null and
                target.proxyTarget() == null and
                !target.flags.is_array and
                target.properties.len == 0)
            {
                try target.defineOwnPropertyAssumingNew(ctx.runtime, atom_id, core.Descriptor.data(value, true, true, true));
                return .done;
            }
        } else |_| {}
    }
    var rooted_value = value;
    defer value.free(ctx.runtime);
    var rooted_obj = obj;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &rooted_obj },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const target = try property_ops.expectObject(obj);
    const effective_atom = call_runtime.remapPrivateAtomForOperation(ctx.runtime, frame, target, atom_id);
    if (target.flags.is_array and effective_atom == core.atom.ids.length) {
        if (value.asInt32()) |length| {
            const new_len: u32 = @intCast(@max(length, 0));
            if (new_len > target.length) try target.convertDenseArrayElementsToSparseProperties(ctx.runtime);
            target.truncateArrayElements(ctx.runtime, new_len);
            target.length = new_len;
            return .done;
        }
    }
    if (target.flags.is_array) {
        if (core.array.arrayIndexFromAtom(&ctx.runtime.atoms, effective_atom)) |index| {
            if (try target.defineDenseArrayDataProperty(ctx.runtime, index, rooted_value)) return .done;
        }
    }
    if (ctx.runtime.atoms.kind(effective_atom) == .private) {
        try object_ops.defineClassFieldDataProperty(ctx.runtime, target, effective_atom, rooted_value);
        return .done;
    }
    if (target.class_id == core.class.ids.object and
        target.exotic == null and
        target.proxyTarget() == null and
        !target.flags.is_array and
        target.properties.len == 0)
    {
        try target.defineOwnPropertyAssumingNew(ctx.runtime, effective_atom, core.Descriptor.data(rooted_value, true, true, true));
        return .done;
    }
    object_ops.createDataPropertyOrThrow(ctx, output, global, rooted_obj, target, effective_atom, rooted_value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn setProto(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
) !void {
    const proto_value = try stack.pop();
    defer proto_value.free(ctx.runtime);
    const obj = stack.peek() orelse return error.StackUnderflow;
    defer obj.free(ctx.runtime);
    const object_value = try property_ops.expectObject(obj);
    if (proto_value.isNull()) {
        try object_value.setPrototype(ctx.runtime, null);
    } else if (proto_value.isObject()) {
        try object_value.setPrototype(ctx.runtime, try property_ops.expectObject(proto_value));
    }
}

pub noinline fn defineArrayEl(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const value = try stack.pop();
    var rooted_value = value;
    defer value.free(ctx.runtime);
    const index = try stack.pop();
    var rooted_index = index;
    defer index.free(ctx.runtime);
    const array_value = stack.peek() orelse return error.StackUnderflow;
    var rooted_array = array_value;
    defer array_value.free(ctx.runtime);

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &rooted_index },
        .{ .value = &rooted_array },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const object_value = property_ops.expectObject(rooted_array) catch |err|
        return try handleLiteralRuntimeError(ctx, stack, frame, catch_target, global, err);
    const atom_id = object_ops.toPropertyKeyAtom(ctx, output, global, rooted_index, function, frame) catch |err|
        return try handleLiteralRuntimeError(ctx, stack, frame, catch_target, global, err);
    defer ctx.runtime.atoms.free(atom_id);
    object_ops.createDataPropertyOrThrow(ctx, output, global, rooted_array, object_value, atom_id, rooted_value, function, frame) catch |err|
        return try handleLiteralRuntimeError(ctx, stack, frame, catch_target, global, err);
    try stack.push(rooted_index);
    return .done;
}

pub fn appendSpreadValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    opc: u8,
) !void {
    const iterable = try stack.pop();
    defer iterable.free(ctx.runtime);
    const index = try stack.pop();
    defer index.free(ctx.runtime);
    _ = opc;
    const array_value = stack.peek() orelse return error.StackUnderflow;
    defer array_value.free(ctx.runtime);
    const array = try property_ops.expectObject(array_value);
    var out_index = index.asInt32() orelse 0;
    const source = property_ops.expectObject(iterable) catch null;
    if (source) |source_object| {
        if (source_object.flags.is_array) {
            var source_index: u32 = 0;
            while (source_index < source_object.length) : (source_index += 1) {
                const item = source_object.getProperty(core.atom.atomFromUInt32(source_index));
                defer item.free(ctx.runtime);
                try property_ops.defineDataProperty(ctx.runtime, array, core.atom.atomFromUInt32(@intCast(out_index)), item);
                out_index += 1;
            }
        } else {
            out_index = try call_runtime.appendIteratorValues(ctx, output, global, array, iterable, out_index);
        }
    } else {
        out_index = try call_runtime.appendIteratorValues(ctx, output, global, array, iterable, out_index);
    }
    try stack.pushOwned(core.JSValue.int32(out_index));
}

pub noinline fn appendSpreadValuesVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    opc: u8,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    appendSpreadValues(ctx, output, global, stack, opc) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn copyDataProperties(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    mask: u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const rt = ctx.runtime;
    const target_value = try stackValueFromTop(stack, mask & 3);
    var rooted_target_value = target_value;
    defer target_value.free(rt);
    const source_value = try stackValueFromTop(stack, (mask >> 2) & 7);
    var rooted_source_value = source_value;
    defer source_value.free(rt);

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_target_value },
        .{ .value = &rooted_source_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (rooted_source_value.isNull() or rooted_source_value.isUndefined()) return .done;

    const target = property_ops.expectObject(rooted_target_value) catch |err|
        return try handleLiteralRuntimeError(ctx, stack, caller_frame, catch_target, global, err);
    const source = property_ops.expectObject(rooted_source_value) catch |err|
        return try handleLiteralRuntimeError(ctx, stack, caller_frame, catch_target, global, err);
    const keys = object_ops.objectRestOwnKeys(ctx, output, global, source) catch |err|
        return try handleLiteralRuntimeError(ctx, stack, caller_frame, catch_target, global, err);
    defer core.Object.freeKeys(rt, keys);

    for (keys) |key| {
        const maybe_desc = object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, source, key) catch |err|
            return try handleLiteralRuntimeError(ctx, stack, caller_frame, catch_target, global, err);
        const desc = maybe_desc orelse continue;
        defer desc.destroy(rt);
        if (!(desc.enumerable orelse false)) continue;
        const value = object_ops.getValueProperty(ctx, output, global, rooted_source_value, key, caller_function, caller_frame) catch |err|
            return try handleLiteralRuntimeError(ctx, stack, caller_frame, catch_target, global, err);
        var rooted_value = value;
        defer value.free(rt);
        var value_root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &rooted_value },
        };
        const value_root_frame = core.runtime.ValueRootFrame{
            .previous = rt.active_value_roots,
            .values = &value_root_values,
        };
        rt.active_value_roots = &value_root_frame;
        defer rt.active_value_roots = value_root_frame.previous;
        property_ops.defineDataProperty(rt, target, key, rooted_value) catch |err|
            return try handleLiteralRuntimeError(ctx, stack, caller_frame, catch_target, global, err);
    }
    return .done;
}

fn handleLiteralRuntimeError(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    err: anytype,
) !Step {
    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
    return err;
}

pub noinline fn specialObject(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !void {
    const subtype = function.code[frame.pc];
    frame.pc += 1;
    if (subtype == 0 or subtype == 1) {
        const arguments = object_ops.capturedArgumentsObject(ctx.runtime, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, frame) orelse
            try object_ops.frameArgumentsObjectForSpecialObject(ctx, global, frame, subtype);
        errdefer arguments.free(ctx.runtime);
        try stack.pushOwned(arguments);
    } else if (subtype == 2) {
        try stack.push(frame.current_function);
    } else if (subtype == 3) {
        try stack.push(frame.new_target);
    } else if (subtype == 4) {
        if (property_ops.expectObject(frame.current_function)) |function_object| {
            if (function_object.functionHomeObjectSlot().*) |home_object| {
                try stack.push(home_object.value());
                return;
            }
        } else |_| {}
        const import_meta = try object_ops.importMetaObject(ctx, global, function, frame);
        errdefer import_meta.free(ctx.runtime);
        try stack.pushOwned(import_meta);
    } else if (try object_ops.internalSpecialObjectValue(ctx.runtime, subtype)) |value| {
        try stack.pushOwned(value);
    } else {
        try stack.pushOwned(core.JSValue.undefinedValue());
    }
}

pub noinline fn getLength(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    if (fusion_stats.fusions_enabled and fusion_stats.counted(.tryFuseArrayLengthLessThanFalseBranch, tryFuseArrayLengthLessThanFalseBranch(ctx.runtime, stack, function, frame, value))) return .done;
    const length = object_ops.getValueProperty(ctx, output, global, value, core.atom.ids.length, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    errdefer length.free(ctx.runtime);
    try stack.pushOwned(length);
    return .done;
}

fn tryFuseArrayLengthLessThanFalseBranch(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    value: core.JSValue,
) bool {
    if (frame.pc + 3 > function.code.len) return false;
    if (function.code[frame.pc] != op.lt or function.code[frame.pc + 1] != op.if_false8) return false;
    const array_object = object_ops.objectFromValue(value) orelse return false;
    if (!array_object.flags.is_array or array_object.proxyTarget() != null) return false;
    const lhs = stack.peekBorrowed() orelse return false;
    const lhs_int = lhs.asInt32() orelse return false;

    const lhs_owned = stack.pop() catch return false;
    lhs_owned.free(rt);
    const operand_pc = frame.pc + 2;
    const diff: i8 = @bitCast(function.code[operand_pc]);
    const lhs_number: f64 = @floatFromInt(lhs_int);
    const rhs_number: f64 = @floatFromInt(array_object.length);
    frame.pc = if (lhs_number < rhs_number)
        frame.pc + 3
    else
        @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
    return true;
}

pub noinline fn rest(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    const first_arg_idx = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    const object_value = try core.Object.createArray(ctx.runtime, null);
    var array_value = object_value.value();
    var element_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &array_value },
        .{ .value = &element_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    errdefer {
        const failed_array = array_value;
        array_value = core.JSValue.undefinedValue();
        failed_array.free(ctx.runtime);
    }
    var source_index: usize = first_arg_idx;
    while (source_index < frame.actual_arg_count and source_index < frame.args.len) : (source_index += 1) {
        const value = slotValueDup(frame.args[source_index]);
        element_value = value;
        var value_owned = true;
        errdefer if (value_owned) {
            element_value = core.JSValue.undefinedValue();
            value.free(ctx.runtime);
        };
        try object_value.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(object_value.length), core.Descriptor.data(value, true, true, true));
        element_value = core.JSValue.undefinedValue();
        value.free(ctx.runtime);
        value_owned = false;
    }
    try stack.pushOwned(array_value);
}

fn slotValueDup(slot: core.JSValue) core.JSValue {
    return slotValueBorrow(slot).dup();
}

fn slotValueBorrow(slot: core.JSValue) core.JSValue {
    var current = slot;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const cell = varRefCellFromValue(current) orelse return current;
        current = cell.varRefValueSlot().* orelse return core.JSValue.undefinedValue();
    }
    return current;
}

fn varRefCellFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const cell: *core.Object = @fieldParentPtr("header", header);
    if (cell.class_payload_kind != .var_ref) return null;
    return cell;
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.values.len) return error.StackUnderflow;
    return stack.values[stack.values.len - 1 - index_from_top].dup();
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
