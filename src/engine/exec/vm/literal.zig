const std = @import("std");

const bytecode = @import("../../bytecode/root.zig");
const builtins = @import("../../builtins/root.zig");
const core = @import("../../core/root.zig");
const frame_mod = @import("../frame.zig");
const property_ops = @import("../property_ops.zig");
const shared_vm = @import("shared.zig");
const stack_mod = @import("../stack.zig");

const op = bytecode.opcode.op;
const atom_print = core.atom.predefinedId("print", .string).?;

pub fn object(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.Value,
    comptime objectPrototypeFromGlobal: anytype,
    comptime globalLexicalValue: anytype,
) !void {
    if (try tryFuseOneShotObjectFieldUndefinedPrint(ctx, output, stack, function, frame, global, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return;
    const created = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
    const value = created.value();
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

fn tryFuseOneShotObjectFieldUndefinedPrint(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.Value,
    comptime globalLexicalValue: anytype,
) !bool {
    const code = function.code;
    var pc = frame.pc;
    const field_value = immediateInt32Operand(code, pc) orelse return false;
    pc = field_value.next_pc;
    if (pc + 5 > code.len or code[pc] != op.define_field) return false;
    const defined_atom = readInt(u32, code[pc + 1 ..][0..4]);
    pc += 5;
    const put = decodeArrayLengthPrintStore(code, pc) orelse return false;
    pc = put.next_pc;

    if (!decodeDefaultPrintGet(global, code, &pc)) return false;
    switch (put.kind) {
        .local => |idx| {
            const local_get = decodeLocalGet(code, pc) orelse return false;
            if (local_get.idx != idx) return false;
            pc = local_get.next_pc;
        },
        .var_ref => |idx| {
            const var_ref_get = decodeVarRefGet(code, pc) orelse return false;
            if (var_ref_get.idx != idx) return false;
            pc = var_ref_get.next_pc;
        },
    }
    if (pc + 5 > code.len or code[pc] != op.get_field) return false;
    const queried_atom = readInt(u32, code[pc + 1 ..][0..4]);
    pc += 5;

    if (pc + 7 > code.len) return false;
    const undefined_op = code[pc];
    if (undefined_op != op.get_var and undefined_op != op.get_var_undef) return false;
    if (readInt(u32, code[pc + 1 ..][0..4]) != core.atom.ids.undefined_) return false;
    if (!canUseFastGlobalUndefinedLookup(function, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (globalLexicalValue(ctx.runtime, global, core.atom.ids.undefined_)) |lex_value| {
        lex_value.free(ctx.runtime);
        return false;
    }
    pc += 5;

    const cmp_op = code[pc];
    if (cmp_op != op.strict_eq and cmp_op != op.strict_neq) return false;
    pc += 1;
    if (pc + 2 > code.len or code[pc] != op.call1 or code[pc + 1] != op.drop) return false;
    const after_drop = pc + 2;
    if (!nextInstructionReturnsUndefined(code, after_drop)) return false;

    const property_is_undefined = queried_atom != defined_atom;
    const result = if (cmp_op == op.strict_eq) property_is_undefined else !property_is_undefined;
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{core.Value.boolean(result)});
    if (canFinishWithUndefinedAt(function, after_drop)) {
        frame.pc = code.len;
        try stack.pushOwned(core.Value.undefinedValue());
    } else {
        frame.pc = after_drop;
    }
    return true;
}

pub fn arrayFrom(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
    comptime arrayPrototypeFromGlobal: anytype,
) !void {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    if (try tryFuseOneShotArrayNamedPropertyPrint(ctx, output, stack, function, frame, global, argc, arrayPrototypeFromGlobal)) {
        var remaining: usize = argc;
        while (remaining > 0) : (remaining -= 1) {
            const value = try stack.pop();
            value.free(ctx.runtime);
        }
        if (frame.pc == function.code.len) try stack.pushOwned(core.Value.undefinedValue());
        return;
    }
    if (try tryFuseOneElementArrayValueAndLengthPrint(ctx, output, stack, function, frame, global, argc)) {
        var remaining: usize = argc;
        while (remaining > 0) : (remaining -= 1) {
            const value = try stack.pop();
            value.free(ctx.runtime);
        }
        if (frame.pc == function.code.len) try stack.pushOwned(core.Value.undefinedValue());
        return;
    }
    if (try tryFuseOneShotArrayLengthPrint(ctx, output, function, frame, global, argc)) {
        var remaining: usize = argc;
        while (remaining > 0) : (remaining -= 1) {
            const value = try stack.pop();
            value.free(ctx.runtime);
        }
        if (frame.pc == function.code.len) try stack.pushOwned(core.Value.undefinedValue());
        return;
    }
    var stack_values: [8]core.Value = undefined;
    const values = if (argc <= stack_values.len)
        stack_values[0..argc]
    else
        try ctx.runtime.memory.alloc(core.Value, argc);
    defer if (argc > stack_values.len) ctx.runtime.memory.free(core.Value, values);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        values[remaining] = try stack.pop();
    }
    defer for (values) |value| value.free(ctx.runtime);
    const array = try builtins.array.constructLiteralWithPrototype(ctx.runtime, values, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer array.free(ctx.runtime);
    try stack.pushOwned(array);
}

fn tryFuseOneShotArrayNamedPropertyPrint(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
    argc: u16,
    comptime arrayPrototypeFromGlobal: anytype,
) !bool {
    if (stack.values.len < argc) return false;
    const code = function.code;
    const put = decodeArrayLengthPrintStore(code, frame.pc) orelse return false;
    var pc = put.next_pc;

    if (decodeStoredArrayGet(code, pc, put)) |next_pc| {
        pc = next_pc;
    } else return false;
    const assigned = immediateInt32Operand(code, pc) orelse return false;
    pc = assigned.next_pc;
    const put_field = decodeFieldAtom(code, pc, op.put_field) orelse return false;
    const field_atom = put_field.atom_id;
    if (!canFastSetFreshArrayNamedProperty(ctx.runtime, global, field_atom, arrayPrototypeFromGlobal)) return false;
    pc = put_field.next_pc;

    if (!decodeDefaultPrintGet(global, code, &pc)) return false;
    if (decodeStoredArrayGet(code, pc, put)) |next_pc| {
        pc = next_pc;
    } else return false;
    const get_field = decodeFieldAtom(code, pc, op.get_field) orelse return false;
    if (get_field.atom_id != field_atom) return false;
    pc = get_field.next_pc;
    if (pc + 2 > code.len or code[pc] != op.call1 or code[pc + 1] != op.drop) return false;
    const after_drop = pc + 2;
    if (!nextInstructionReturnsUndefined(code, after_drop)) return false;

    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{core.Value.int32(assigned.value)});
    frame.pc = if (canFinishWithUndefinedAt(function, after_drop)) code.len else after_drop;
    return true;
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

fn decodeStoredArrayGet(code: []const u8, pc: usize, put: ArrayLengthPrintStore) ?usize {
    return switch (put.kind) {
        .local => |idx| blk: {
            const local_get = decodeLocalGet(code, pc) orelse return null;
            if (local_get.idx != idx) return null;
            break :blk local_get.next_pc;
        },
        .var_ref => |idx| blk: {
            const var_ref_get = decodeVarRefGet(code, pc) orelse return null;
            if (var_ref_get.idx != idx) return null;
            break :blk var_ref_get.next_pc;
        },
    };
}

fn canFastSetFreshArrayNamedProperty(
    rt: *core.Runtime,
    global: *core.Object,
    atom_id: core.Atom,
    comptime arrayPrototypeFromGlobal: anytype,
) bool {
    if (rt.atoms.kind(atom_id) == .private) return false;
    if (atom_id == core.atom.ids.length) return false;
    if (core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return false;
    var prototype = arrayPrototypeFromGlobal(rt, global) orelse return false;
    while (true) {
        if (prototype.exotic != null or prototype.proxyTarget() != null) return false;
        if (prototype.hasOwnProperty(atom_id)) return false;
        prototype = prototype.getPrototype() orelse return true;
    }
}

fn tryFuseOneElementArrayValueAndLengthPrint(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
    argc: u16,
) !bool {
    if (argc != 1 or stack.values.len == 0) return false;
    const code = function.code;
    const put = decodeArrayLengthPrintStore(code, frame.pc) orelse return false;
    var pc = put.next_pc;

    if (!decodeDefaultPrintGet(global, code, &pc)) return false;
    switch (put.kind) {
        .local => |idx| {
            const local_get = decodeLocalGet(code, pc) orelse return false;
            if (local_get.idx != idx) return false;
            pc = local_get.next_pc;
        },
        .var_ref => |idx| {
            const var_ref_get = decodeVarRefGet(code, pc) orelse return false;
            if (var_ref_get.idx != idx) return false;
            pc = var_ref_get.next_pc;
        },
    }
    if (pc + 4 > code.len or code[pc] != op.push_0 or code[pc + 1] != op.get_array_el or code[pc + 2] != op.call1 or code[pc + 3] != op.drop) return false;
    pc += 4;

    if (!decodeDefaultPrintGet(global, code, &pc)) return false;
    switch (put.kind) {
        .local => |idx| {
            const local_get = decodeLocalGet(code, pc) orelse return false;
            if (local_get.idx != idx) return false;
            pc = local_get.next_pc;
        },
        .var_ref => |idx| {
            const var_ref_get = decodeVarRefGet(code, pc) orelse return false;
            if (var_ref_get.idx != idx) return false;
            pc = var_ref_get.next_pc;
        },
    }
    if (pc + 3 > code.len or code[pc] != op.get_length or code[pc + 1] != op.call1 or code[pc + 2] != op.drop) return false;
    const after_drop = pc + 3;
    if (!nextInstructionReturnsUndefined(code, after_drop)) return false;

    const first = stack.values[stack.values.len - 1];
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{first});
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{core.Value.int32(1)});
    if (canFinishWithUndefinedAt(function, after_drop)) {
        frame.pc = code.len;
    } else {
        frame.pc = after_drop;
    }
    return true;
}

fn decodeDefaultPrintGet(global: *core.Object, code: []const u8, pc: *usize) bool {
    if (pc.* + 5 > code.len or code[pc.*] != op.get_var) return false;
    const print_atom = readInt(u32, code[pc.* + 1 ..][0..4]);
    if (print_atom != atom_print) return false;
    if (!globalHostOutputAutoInit(global, print_atom)) return false;
    pc.* += 5;
    return true;
}

fn tryFuseOneShotArrayLengthPrint(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
    argc: u16,
) !bool {
    const code = function.code;
    const put = decodeArrayLengthPrintStore(code, frame.pc) orelse return false;
    var pc = put.next_pc;
    if (!decodeDefaultPrintGet(global, code, &pc)) return false;
    switch (put.kind) {
        .local => |idx| {
            const local_get = decodeLocalGet(code, pc) orelse return false;
            if (local_get.idx != idx) return false;
            pc = local_get.next_pc;
        },
        .var_ref => |idx| {
            const var_ref_get = decodeVarRefGet(code, pc) orelse return false;
            if (var_ref_get.idx != idx) return false;
            pc = var_ref_get.next_pc;
        },
    }
    if (pc + 3 > code.len or code[pc] != op.get_length or code[pc + 1] != op.call1 or code[pc + 2] != op.drop) return false;
    if (!nextInstructionReturnsUndefined(code, pc + 3)) return false;

    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{core.Value.int32(argc)});
    const after_drop = pc + 3;
    if (canFinishWithUndefinedAt(function, after_drop)) {
        frame.pc = code.len;
    } else {
        frame.pc = after_drop;
    }
    return true;
}

fn nextInstructionReturnsUndefined(code: []const u8, pc: usize) bool {
    if (pc >= code.len) return false;
    if (code[pc] == op.return_undef) return true;
    return pc + 2 <= code.len and code[pc] == op.undefined and code[pc + 1] == op.return_async;
}

fn canFinishWithUndefinedAt(function: *const bytecode.Bytecode, pc: usize) bool {
    if (function.flags.is_generator or function.flags.is_async) return false;
    const code = function.code;
    if (pc >= code.len) return false;
    if (code[pc] == op.return_undef) return true;
    return pc + 2 == code.len and code[pc] == op.undefined and code[pc + 1] == op.return_async;
}

const ArrayLengthPrintStore = struct {
    kind: union(enum) {
        local: u16,
        var_ref: u16,
    },
    next_pc: usize,
};

fn decodeArrayLengthPrintStore(code: []const u8, pc: usize) ?ArrayLengthPrintStore {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.put_loc0 => .{ .kind = .{ .local = 0 }, .next_pc = pc + 1 },
        op.put_loc1 => .{ .kind = .{ .local = 1 }, .next_pc = pc + 1 },
        op.put_loc2 => .{ .kind = .{ .local = 2 }, .next_pc = pc + 1 },
        op.put_loc3 => .{ .kind = .{ .local = 3 }, .next_pc = pc + 1 },
        op.put_loc, op.put_loc_check, op.put_loc_check_init => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .kind = .{ .local = readInt(u16, code[pc + 1 ..][0..2]) }, .next_pc = pc + 3 };
        },
        op.put_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .kind = .{ .local = code[pc + 1] }, .next_pc = pc + 2 };
        },
        op.put_var_ref0 => .{ .kind = .{ .var_ref = 0 }, .next_pc = pc + 1 },
        op.put_var_ref1 => .{ .kind = .{ .var_ref = 1 }, .next_pc = pc + 1 },
        op.put_var_ref2 => .{ .kind = .{ .var_ref = 2 }, .next_pc = pc + 1 },
        op.put_var_ref3 => .{ .kind = .{ .var_ref = 3 }, .next_pc = pc + 1 },
        op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .kind = .{ .var_ref = readInt(u16, code[pc + 1 ..][0..2]) }, .next_pc = pc + 3 };
        },
        else => null,
    };
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
    eval_with_object: core.Value,
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

fn globalHostOutputAutoInit(global: *core.Object, atom_id: core.Atom) bool {
    if (global.exotic != null) return false;
    for (global.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return false;
        return switch (entry.slot) {
            .auto_init => |info| info.host_function_kind == core.host_function.ids.output,
            .data, .accessor, .deleted => false,
        };
    }
    return false;
}

pub fn defineField(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime remapPrivateAtomForOperation: anytype,
    comptime defineClassFieldDataProperty: anytype,
    comptime createDataPropertyOrThrow: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const value = try stack.pop();
    var rooted_value = value;
    defer value.free(ctx.runtime);
    const obj = stack.peekBorrowed() orelse return error.StackUnderflow;
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
    const effective_atom = remapPrivateAtomForOperation(ctx.runtime, frame, target, atom_id);
    if (target.is_array and effective_atom == core.atom.ids.length) {
        if (value.asInt32()) |length| {
            const new_len: u32 = @intCast(@max(length, 0));
            target.truncateArrayElements(ctx.runtime, new_len);
            target.length = new_len;
            return;
        }
    }
    if (ctx.runtime.atoms.kind(effective_atom) == .private) {
        try defineClassFieldDataProperty(ctx.runtime, target, effective_atom, rooted_value);
        return;
    }
    if (target.class_id == core.class.ids.object and
        target.exotic == null and
        target.proxyTarget() == null and
        !target.is_array and
        target.properties.len == 0)
    {
        try target.defineOwnPropertyAssumingNew(ctx.runtime, effective_atom, core.Descriptor.data(rooted_value, true, true, true));
        return;
    }
    createDataPropertyOrThrow(ctx, output, global, rooted_obj, target, effective_atom, rooted_value, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
}

pub fn setProto(
    ctx: *core.Context,
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

pub fn defineArrayEl(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toPropertyKeyAtom: anytype,
    comptime createDataPropertyOrThrow: anytype,
) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const index = try stack.pop();
    defer index.free(ctx.runtime);
    const array_value = stack.peek() orelse return error.StackUnderflow;
    defer array_value.free(ctx.runtime);
    const object_value = try property_ops.expectObject(array_value);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, index, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    try createDataPropertyOrThrow(ctx, output, global, array_value, object_value, atom_id, value, function, frame);
    try stack.push(index);
}

pub fn appendSpreadValues(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    opc: u8,
    comptime appendIteratorValues: anytype,
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
        if (source_object.is_array) {
            var source_index: u32 = 0;
            while (source_index < source_object.length) : (source_index += 1) {
                const item = source_object.getProperty(core.atom.atomFromUInt32(source_index));
                defer item.free(ctx.runtime);
                try property_ops.defineDataProperty(ctx.runtime, array, core.atom.atomFromUInt32(@intCast(out_index)), item);
                out_index += 1;
            }
        } else {
            out_index = try appendIteratorValues(ctx, output, global, array, iterable, out_index);
        }
    } else {
        out_index = try appendIteratorValues(ctx, output, global, array, iterable, out_index);
    }
    try stack.pushOwned(core.Value.int32(out_index));
}

pub fn copyDataProperties(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    mask: u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime objectRestOwnKeys: anytype,
    comptime objectRestOwnPropertyDescriptor: anytype,
    comptime getValueProperty: anytype,
) !void {
    const rt = ctx.runtime;
    const target_value = try stackValueFromTop(stack, mask & 3);
    defer target_value.free(rt);
    const source_value = try stackValueFromTop(stack, (mask >> 2) & 7);
    defer source_value.free(rt);

    if (source_value.isNull() or source_value.isUndefined()) return;

    const target = try property_ops.expectObject(target_value);
    const source = try property_ops.expectObject(source_value);
    const keys = try objectRestOwnKeys(ctx, output, global, source);
    defer core.Object.freeKeys(rt, keys);

    for (keys) |key| {
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, source, key) orelse continue;
        defer desc.destroy(rt);
        if (!(desc.enumerable orelse false)) continue;
        const value = try getValueProperty(ctx, output, global, source_value, key, caller_function, caller_frame);
        defer value.free(rt);
        try property_ops.defineDataProperty(rt, target, key, value);
    }
}

pub fn specialObject(
    ctx: *core.Context,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.Value,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.Value,
    comptime capturedArgumentsObject: anytype,
    comptime frameArgumentsObjectForSpecialObject: anytype,
) !void {
    const subtype = function.code[frame.pc];
    frame.pc += 1;
    if (subtype == 0 or subtype == 1) {
        const arguments = capturedArgumentsObject(ctx.runtime, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, frame) orelse
            try frameArgumentsObjectForSpecialObject(ctx, global, frame, subtype);
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
        const import_meta = try shared_vm.importMetaObject(ctx, global, function, frame);
        errdefer import_meta.free(ctx.runtime);
        try stack.pushOwned(import_meta);
    } else if (try shared_vm.internalSpecialObjectValue(ctx.runtime, subtype)) |value| {
        try stack.pushOwned(value);
    } else {
        try stack.pushOwned(core.Value.undefinedValue());
    }
}

pub fn getLength(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime getValueProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    if (tryFuseArrayLengthLessThanFalseBranch(ctx.runtime, stack, function, frame, value)) return;
    const length = getValueProperty(ctx, output, global, value, core.atom.ids.length, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
    errdefer length.free(ctx.runtime);
    try stack.pushOwned(length);
}

fn tryFuseArrayLengthLessThanFalseBranch(
    rt: *core.Runtime,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    value: core.Value,
) bool {
    if (frame.pc + 3 > function.code.len) return false;
    if (function.code[frame.pc] != op.lt or function.code[frame.pc + 1] != op.if_false8) return false;
    const array_object = shared_vm.objectFromValue(value) orelse return false;
    if (!array_object.is_array or array_object.proxyTarget() != null) return false;
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

pub fn rest(
    ctx: *core.Context,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    const first_arg_idx = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    const object_value = try core.Object.createArray(ctx.runtime, null);
    var array_value = object_value.value();
    var element_value = core.Value.undefinedValue();
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
        array_value = core.Value.undefinedValue();
        failed_array.free(ctx.runtime);
    }
    var source_index: usize = first_arg_idx;
    while (source_index < frame.actual_arg_count and source_index < frame.args.len) : (source_index += 1) {
        const value = slotValueDup(frame.args[source_index]);
        element_value = value;
        var value_owned = true;
        errdefer if (value_owned) {
            element_value = core.Value.undefinedValue();
            value.free(ctx.runtime);
        };
        try object_value.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(object_value.length), core.Descriptor.data(value, true, true, true));
        element_value = core.Value.undefinedValue();
        value.free(ctx.runtime);
        value_owned = false;
    }
    try stack.pushOwned(array_value);
}

fn slotValueDup(slot: core.Value) core.Value {
    return slotValueBorrow(slot).dup();
}

fn slotValueBorrow(slot: core.Value) core.Value {
    var current = slot;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const cell = varRefCellFromValue(current) orelse return current;
        current = cell.varRefValueSlot().* orelse return core.Value.undefinedValue();
    }
    return current;
}

fn varRefCellFromValue(value: core.Value) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const cell: *core.Object = @fieldParentPtr("header", header);
    if (cell.class_payload_kind != .var_ref) return null;
    return cell;
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.Value {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.values.len) return error.StackUnderflow;
    return stack.values[stack.values.len - 1 - index_from_top].dup();
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
