const std = @import("std");
const builtin = @import("builtin");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const forof_ops = @import("forof_ops.zig");
const object_ops = @import("object_ops.zig");
const call_runtime = @import("call_runtime.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const op = bytecode.opcode.op;

pub const DropResult = union(enum) {
    value,
    catch_target: ?usize,
};

pub const Step = enum { done, continue_loop };

pub fn pushInt32Operand(stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void {
    const value = readInt(i32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    try pushImmediateInt32MaybeFuse(stack, function, frame, value);
}

pub fn pushBigIntI32Operand(stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void {
    const value = readInt(i32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    stack.pushOwnedAssumeCapacity(core.JSValue.shortBigInt(value));
}

pub fn pushI16Operand(stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void {
    const value = readInt(i16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    try pushImmediateInt32MaybeFuse(stack, function, frame, value);
}

pub fn pushI8Operand(stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void {
    const value: i8 = @bitCast(function.byteCode()[frame.pc]);
    frame.pc += 1;
    try pushImmediateInt32MaybeFuse(stack, function, frame, value);
}

pub fn pushSmallInt(stack: *stack_mod.Stack, value: i32) !void {
    try stack.pushOwned(core.JSValue.int32(value));
}

pub fn pushSmallIntMaybeFuse(stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, value: i32) !void {
    try pushImmediateInt32MaybeFuse(stack, function, frame, value);
}

fn pushImmediateInt32MaybeFuse(
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    value: i32,
) !void {
    // qjs has no runtime push+binop fusion: every push opcode is a standalone
    // `*sp++ = ...` and a following binop is a separate dispatch (quickjs.c
    // 17879-17910). The threaded fast path (zjs_vm.zig push_i32/i16/i8) already
    // pushes the immediate inline with no fusion; this is the non-threaded
    // fallback, kept byte-identical to it — a plain push, no stack-lhs fold.
    _ = function;
    _ = frame;
    stack.pushOwnedAssumeCapacity(core.JSValue.int32(value));
}

pub fn pushUndefined(stack: *stack_mod.Stack) !void {
    stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
}

pub fn pushNull(stack: *stack_mod.Stack) !void {
    stack.pushOwnedAssumeCapacity(core.JSValue.nullValue());
}

pub fn pushBoolean(stack: *stack_mod.Stack, value: bool) !void {
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(value));
}

pub noinline fn pushConst(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, opc: u8) !void {
    _ = opc;
    const index = readInt(u32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    const value = function.constantAt(index) orelse return error.TypeError;
    defer value.free(ctx.runtime);
    stack.pushAssumeCapacity(value);
}

pub noinline fn pushConst8(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, opc: u8) !void {
    _ = opc;
    const index = function.byteCode()[frame.pc];
    frame.pc += 1;
    const value = function.constantAt(index) orelse return error.TypeError;
    defer value.free(ctx.runtime);
    stack.pushAssumeCapacity(value);
}

pub fn pushAtomValue(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void {
    const atom_id = readInt(u32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    const value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
    errdefer value.free(ctx.runtime);
    stack.pushOwnedAssumeCapacity(value);
}

pub noinline fn pushPrivateSymbol(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void {
    const template_atom = readInt(u32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    const name = ctx.runtime.atoms.name(template_atom) orelse return error.InvalidAtom;
    const value = value: {
        const fresh_atom = try ctx.runtime.atoms.newSymbol(name, .private);
        errdefer ctx.runtime.atoms.free(fresh_atom);
        break :value try ctx.runtime.takeSymbolValue(fresh_atom);
    };
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub noinline fn pushEmptyString(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    const value = (try ctx.runtime.emptyString()).value().dup();
    errdefer value.free(ctx.runtime);
    stack.pushOwnedAssumeCapacity(value);
}

pub fn pushThis(stack: *stack_mod.Stack, this_value: core.JSValue) !void {
    if (adapterValueIsUninitialized(this_value)) return error.ReferenceError;
    pushAdapterValue(stack, this_value);
}

pub noinline fn pushThisVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    const this_value = object_ops.materializeFrameThisBinding(ctx, global, frame) catch |err| switch (err) {
        error.TypeError => {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
            return error.TypeError;
        },
        else => return err,
    };
    pushThis(stack, this_value) catch |err| switch (err) {
        error.ReferenceError => {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        },
    };
    return .done;
}

pub fn toObject(ctx: *core.JSContext, global: *core.Object, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    var object_value = if (value.isObject())
        value.dup()
    else
        try object_ops.primitiveObjectForAccess(ctx.runtime, global, value);
    errdefer object_value.free(ctx.runtime);
    stack.pushOwnedAssumeCapacity(object_value);
}

pub noinline fn toObjectVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    toObject(ctx, global, stack) catch |err| switch (err) {
        error.TypeError => {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
            return error.TypeError;
        },
        else => return err,
    };
    return .done;
}

pub noinline fn typeOf(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    // qjs `js_operator_typeof` returns a predefined atom and OP_typeof pushes
    // `JS_AtomToString` of it — a refcount dup of the interned atom string, not
    // a fresh allocation. The `typeof` result strings are all predefined string
    // atoms here too, so resolve to the atom and dup its cached interned string.
    const atom_id: core.Atom = if (value.isUndefined() or value_ops.isHTMLDDA(value))
        core.atom.ids.undefined_
    else if (value.isNull())
        core.atom.ids.type_object
    else if (value.isBool())
        core.atom.ids.type_boolean
    else if (value.isBigInt())
        core.atom.ids.type_bigint
    else if (value.isNumber())
        core.atom.ids.type_number
    else if (value.isString())
        core.atom.ids.type_string
    else if (value.isSymbol())
        core.atom.ids.type_symbol
    else if (value.isFunctionBytecode() or functionObjectFromValue(value) != null or callableObjectFromValue(value) != null or proxyTargetIsCallable(value))
        core.atom.ids.type_function
    else
        core.atom.ids.type_object;
    const out = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
    errdefer out.free(ctx.runtime);
    stack.pushOwnedAssumeCapacity(out);
}

pub noinline fn typeOfIsUndefined(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(value.isUndefined() or value_ops.isHTMLDDA(value)));
}

pub noinline fn typeOfIsFunction(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    // Keep the short comparison opcode exactly aligned with `typeOf`: native
    // c_functions, external host functions, and callable proxies all report
    // "function", not only bytecode function objects.
    const is_func = !value_ops.isHTMLDDA(value) and
        (value.isFunctionBytecode() or
            functionObjectFromValue(value) != null or
            callableObjectFromValue(value) != null or
            proxyTargetIsCallable(value));
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(is_func));
}

pub noinline fn logicalNot(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(!value_ops.isTruthy(value)));
}

pub noinline fn drop(rt: *core.JSRuntime, stack: *stack_mod.Stack) !DropResult {
    const value = try stack.pop();
    if (forof_ops.isIteratorCatchMarker(value)) {
        value.free(rt);
        return .value;
    }
    if (value.isCatchOffset()) {
        if ((value.asCatchOffset() orelse -1) == 0) {
            value.free(rt);
            return .value;
        }
        const target = catchTargetFromMarker(value);
        return .{ .catch_target = target };
    }
    value.free(rt);
    return .value;
}

pub noinline fn nipCatch(rt: *core.JSRuntime, stack: *stack_mod.Stack) !DropResult {
    const ret_value = try stack.pop();

    while (stack.len() != 0) {
        const value = try stack.pop();
        if (value.isCatchOffset()) {
            const result: DropResult = if (forof_ops.isIteratorCatchMarker(value) or
                (value.asCatchOffset() orelse -1) == 0)
                .value
            else
                .{ .catch_target = catchTargetFromMarker(value) };
            value.free(rt);
            stack.pushOwned(ret_value) catch |err| {
                ret_value.free(rt);
                return err;
            };
            return result;
        }
        value.free(rt);
    }

    ret_value.free(rt);
    return error.InvalidBytecode;
}

pub fn dup(ctx: *core.JSContext, stack: *stack_mod.Stack, opc: u8) !void {
    _ = ctx;
    _ = opc;
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    stack.pushAssumeCapacity(value);
}

pub fn swap(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 2);
    const a = try stack.pop();
    const b = try stack.pop();
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn nip(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    try requireStackLen(stack, 2);
    const top = try stack.pop();
    const second = try stack.pop();
    second.free(ctx.runtime);
    stack.pushOwnedAssumeCapacity(top);
}

pub fn nip1(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    a.free(ctx.runtime);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
}

pub fn dup2(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 2);
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(a);
    stack.pushAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn dup1(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 2);
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn dup3(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(a);
    stack.pushAssumeCapacity(b);
    stack.pushAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
}

pub fn insert2(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 2);
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn insert3(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
}

pub fn insert4(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 4);
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(d);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(d);
}

pub fn rot3l(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(a);
}

pub fn rot3r(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn rot4l(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 4);
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(d);
    stack.pushOwnedAssumeCapacity(a);
}

pub fn rot5l(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 5);
    const e = try stack.pop();
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(d);
    stack.pushOwnedAssumeCapacity(e);
    stack.pushOwnedAssumeCapacity(a);
}

pub fn perm3(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(c);
}

pub fn perm4(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 4);
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(d);
}

pub fn perm5(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 5);
    const e = try stack.pop();
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(d);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(e);
}

pub fn swap2(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 4);
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(d);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub noinline fn isUndefinedOrNull(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(value.isUndefined() or value.isNull()));
}

pub noinline fn isUndefined(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(value.isUndefined()));
}

pub noinline fn isNull(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(value.isNull()));
}

fn pushAdapterValue(stack: *stack_mod.Stack, slot: core.JSValue) void {
    stack.pushAssumeCapacity(adapterValueBorrow(slot));
}

fn adapterValueBorrow(slot: core.JSValue) core.JSValue {
    const cell = varRefCellFromValue(slot) orelse return slot;
    const value = cell.varRefValue();
    if (comptime builtin.mode == .Debug) {
        std.debug.assert(varRefCellFromValue(value) == null);
    }
    return value;
}

fn requireStackLen(stack: *const stack_mod.Stack, required: usize) !void {
    if (stack.len() < required) return error.StackUnderflow;
}

fn expectStackInt32s(stack: *const stack_mod.Stack, expected: []const i32) !void {
    try std.testing.expectEqual(expected.len, stack.len());
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(@as(?i32, value), stack.values[index].asInt32());
    }
}

fn adapterValueIsUninitialized(slot: core.JSValue) bool {
    return adapterValueBorrow(slot).isUninitialized();
}

fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef {
    return core.VarRef.fromValue(value);
}

fn functionObjectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (!core.class.isBytecodeFunctionClass(object.class_id)) return null;
    return object;
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn callableObjectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.c_function_data and
        object.class_id != core.class.ids.c_closure and
        object.class_id != core.class.ids.bound_function) return null;
    return object;
}

fn proxyTargetIsCallable(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    const target = object.proxyTarget() orelse return false;
    return target.isFunctionBytecode() or functionObjectFromValue(target) != null or callableObjectFromValue(target) != null or proxyTargetIsCallable(target);
}

fn catchTargetFromMarker(marker: core.JSValue) ?usize {
    const previous = marker.asCatchOffset() orelse -1;
    if (previous < 0) return null;
    return @intCast(previous);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn countLivePrivateAtomsNamed(rt: *core.JSRuntime, expected_name: []const u8) usize {
    var count: usize = 0;
    for (0..rt.atoms.entries.len) |index| {
        const atom_id: core.Atom = @intCast(core.atom.first_dynamic_atom + index);
        if (rt.atoms.kind(atom_id) != .private) continue;
        const name = rt.atoms.name(atom_id) orelse continue;
        if (std.mem.eql(u8, name, expected_name)) count += 1;
    }
    return count;
}

test "function object lookup recognizes every bytecode function class" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const class_ids = [_]core.ClassId{
        core.class.ids.bytecode_function,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
    };
    for (class_ids) |class_id| {
        const function_object = try core.Object.create(rt, class_id, null);
        defer function_object.value().free(rt);
        try std.testing.expectEqual(function_object, functionObjectFromValue(function_object.value()).?);
    }

    const plain_object = try core.Object.create(rt, core.class.ids.object, null);
    defer plain_object.value().free(rt);
    try std.testing.expect(functionObjectFromValue(plain_object.value()) == null);
}

test "push private symbol creates a fresh runtime atom per execution" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const function_name = try rt.internAtom("pushPrivateSymbolNoRetain");
    defer rt.atoms.free(function_name);
    const template_name = "pushPrivateSymbolNoRetainName";
    const template_atom = try rt.atoms.newSymbol(template_name, .private);
    var template_atom_released = false;
    defer if (!template_atom_released) rt.atoms.free(template_atom);
    const template_ref_count = rt.atoms.refCount(template_atom).?;

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, function_name);
    defer function.deinit(rt);
    var code: [4]u8 = undefined;
    std.mem.writeInt(u32, &code, template_atom, .little);
    try function.setCode(&code);

    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var frame = frame_mod.Frame.init(execution_function);
    var stack = stack_mod.Stack.init(&rt.memory, 8);
    defer stack.deinit(rt);

    try pushPrivateSymbol(ctx, &stack, execution_function, &frame);
    frame.pc = 0;
    try pushPrivateSymbol(ctx, &stack, execution_function, &frame);

    var first_atom: core.Atom = undefined;
    var second_atom: core.Atom = undefined;
    {
        const second_value = try stack.pop();
        defer second_value.free(rt);
        const first_value = try stack.pop();
        defer first_value.free(rt);
        first_atom = first_value.asSymbolAtom().?;
        second_atom = second_value.asSymbolAtom().?;

        try std.testing.expect(first_atom != template_atom);
        try std.testing.expect(second_atom != template_atom);
        try std.testing.expect(first_atom != second_atom);
        try std.testing.expectEqualStrings(template_name, rt.atoms.name(first_atom).?);
        try std.testing.expectEqualStrings(template_name, rt.atoms.name(second_atom).?);
        try std.testing.expectEqual(template_ref_count, rt.atoms.refCount(template_atom).?);
        try std.testing.expectEqual(@as(usize, 3), countLivePrivateAtomsNamed(rt, template_name));
    }

    try std.testing.expect(rt.atoms.name(first_atom) == null);
    try std.testing.expect(rt.atoms.name(second_atom) == null);
    try std.testing.expectEqual(@as(usize, 1), countLivePrivateAtomsNamed(rt, template_name));
    rt.atoms.free(template_atom);
    template_atom_released = true;
    try std.testing.expect(rt.atoms.name(template_atom) == null);
}

test "stack rearrange opcodes validate depth before mutating stack" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    var stack = stack_mod.Stack.init(&rt.memory, 8);
    defer stack.deinit(rt);

    try stack.pushOwned(core.JSValue.int32(1));
    try stack.pushOwned(core.JSValue.int32(2));
    try std.testing.expectError(error.StackUnderflow, dup3(ctx, &stack));
    try expectStackInt32s(&stack, &.{ 1, 2 });

    try stack.pushOwned(core.JSValue.int32(3));
    try std.testing.expectError(error.StackUnderflow, insert4(ctx, &stack));
    try expectStackInt32s(&stack, &.{ 1, 2, 3 });

    try std.testing.expectError(error.StackUnderflow, swap2(ctx, &stack));
    try expectStackInt32s(&stack, &.{ 1, 2, 3 });
}

test "push private symbol stack failure does not retain transient private atom" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const function_name = try rt.internAtom("pushPrivateSymbolStackFailure");
    defer rt.atoms.free(function_name);
    const template_name = "pushPrivateSymbolStackFailureName";
    const template_atom = try rt.atoms.newSymbol(template_name, .private);
    var template_atom_released = false;
    defer if (!template_atom_released) rt.atoms.free(template_atom);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, function_name);
    defer function.deinit(rt);
    var code: [4]u8 = undefined;
    std.mem.writeInt(u32, &code, template_atom, .little);
    try function.setCode(&code);

    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var frame = frame_mod.Frame.init(execution_function);
    var stack = stack_mod.Stack.init(&rt.memory, 0);
    defer stack.deinit(rt);

    const calibration_atom = try rt.atoms.newSymbol(template_name, .private);
    rt.atoms.free(calibration_atom);
    const allocated_before = rt.memory.allocated_bytes;
    try std.testing.expectError(error.StackOverflow, pushPrivateSymbol(ctx, &stack, execution_function, &frame));
    try std.testing.expectEqual(allocated_before, rt.memory.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), countLivePrivateAtomsNamed(rt, template_name));

    rt.atoms.free(template_atom);
    template_atom_released = true;
    try std.testing.expect(rt.atoms.name(template_atom) == null);
}

test "push private symbol releases fresh atom on allocation failure" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const function_name = try rt.internAtom("pushPrivateSymbolAllocationFailure");
    defer rt.atoms.free(function_name);
    const template_name = "pushPrivateSymbolAllocationFailureName";
    const template_atom = try rt.atoms.newSymbol(template_name, .private);
    defer rt.atoms.free(template_atom);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, function_name);
    defer function.deinit(rt);
    var code: [4]u8 = undefined;
    std.mem.writeInt(u32, &code, template_atom, .little);
    try function.setCode(&code);

    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    var frame = frame_mod.Frame.init(execution_function);
    var stack = stack_mod.Stack.init(&rt.memory, 1);
    defer stack.deinit(rt);
    defer rt.setMemoryLimit(null);

    // Warm one recyclable atom-table slot and measure the exact transient
    // description allocation. The following limit then admits newSymbol but
    // rejects the first symbol-body allocation in takeSymbolValue.
    const calibration_atom = try rt.atoms.newSymbol(template_name, .private);
    const allocated_with_atom = rt.memory.allocated_bytes;
    rt.atoms.free(calibration_atom);
    const allocated_before = rt.memory.allocated_bytes;
    try std.testing.expect(allocated_with_atom > allocated_before);
    const atom_allocation_bytes = allocated_with_atom - allocated_before;
    try std.testing.expectEqual(@as(usize, 1), countLivePrivateAtomsNamed(rt, template_name));

    rt.setMemoryLimit(allocated_before);
    try std.testing.expectError(error.OutOfMemory, pushPrivateSymbol(ctx, &stack, execution_function, &frame));
    rt.setMemoryLimit(null);
    try std.testing.expectEqual(allocated_before, rt.memory.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), countLivePrivateAtomsNamed(rt, template_name));

    frame.pc = 0;
    rt.setMemoryLimit(allocated_before + atom_allocation_bytes);
    try std.testing.expectError(error.OutOfMemory, pushPrivateSymbol(ctx, &stack, execution_function, &frame));
    rt.setMemoryLimit(null);
    try std.testing.expectEqual(allocated_before, rt.memory.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), countLivePrivateAtomsNamed(rt, template_name));

    frame.pc = 0;
    try pushPrivateSymbol(ctx, &stack, execution_function, &frame);
    const recovered = try stack.pop();
    defer recovered.free(rt);
    const recovered_atom = recovered.asSymbolAtom().?;
    try std.testing.expect(recovered_atom != template_atom);
    try std.testing.expectEqualStrings(template_name, rt.atoms.name(recovered_atom).?);
}
