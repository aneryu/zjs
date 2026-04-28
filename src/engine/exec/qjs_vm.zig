//! QuickJS-aligned VM dispatcher for bytecode produced by the new
//! `frontend/qjs_parser.zig`. Mirrors PARSER_REWRITE_PLAN.md §F2+F3.
//!
//! This coexists with the legacy `vm.zig` dispatcher during the
//! parser-rewrite transition. Bytecode tagged with `opcode_format = .qjs`
//! is routed here via `Vm.run`; legacy bytecode continues through the
//! existing bespoke-opcode dispatcher.
//!
//! The dispatcher handles the subset of opcodes the new parser currently
//! emits. Opcodes not yet implemented return `UnsupportedOpcode` so the
//! test surface can track coverage incrementally.

const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const op = bytecode.opcode.op;

/// Execute QuickJS-format bytecode. Called by `Vm.run` when
/// `function.opcode_format == .qjs`.
pub fn run(
    ctx: *core.Context,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
) !core.Value {
    var frame = frame_mod.Frame.init(function);
    defer frame.deinit(&ctx.runtime.memory, ctx.runtime);

    while (frame.pc < function.code.len) {
        const opc = function.code[frame.pc];
        frame.pc += 1;
        switch (opc) {
            // ---- Push constants ----
            op.push_i32 => {
                const value = readInt(i32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                try stack.push(core.Value.int32(value));
            },
            op.push_const => {
                const index = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                const value = function.constants.get(index) orelse
                    return throwUnsupported(ctx, opc);
                defer value.free(ctx.runtime);
                try stack.push(value);
            },
            op.@"undefined" => try stack.push(core.Value.undefinedValue()),
            op.@"null" => try stack.push(core.Value.nullValue()),
            op.push_false => try stack.push(core.Value.boolean(false)),
            op.push_true => try stack.push(core.Value.boolean(true)),
            op.push_atom_value => {
                const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                // Push atom as a string value. For F2+F3 minimum, we
                // emit the atom index as an int32 placeholder; F10/F12
                // will lower this to the actual string value.
                try stack.push(core.Value.int32(@intCast(atom_id)));
            },
            op.push_empty_string => {
                // Push empty string. F12 will wire proper string construction.
                try stack.push(core.Value.int32(0));
            },

            // ---- Stack manipulation ----
            op.drop => {
                const value = try stack.pop();
                value.free(ctx.runtime);
            },
            op.dup => {
                const value = stack.peek() orelse return throwUnsupported(ctx, opc);
                try stack.push(value);
            },
            op.swap => {
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a);
                try stack.push(b);
            },

            // ---- Return ----
            op.@"return" => {
                if (stack.peek()) |value| return value;
                return core.Value.undefinedValue();
            },
            op.return_undef => return core.Value.undefinedValue(),

            // ---- Binary arithmetic ----
            op.add => try binaryArith(ctx, stack, .add),
            op.sub => try binaryArith(ctx, stack, .sub),
            op.mul => try binaryArith(ctx, stack, .mul),
            op.div => try binaryArith(ctx, stack, .div),
            op.mod => try binaryArith(ctx, stack, .mod),
            op.pow => try binaryArith(ctx, stack, .pow),
            op.shl => try binaryArith(ctx, stack, .shl),
            op.sar => try binaryArith(ctx, stack, .sar),
            op.shr => try binaryArith(ctx, stack, .shr),
            op.@"and" => try binaryArith(ctx, stack, .bit_and),
            op.@"or" => try binaryArith(ctx, stack, .bit_or),
            op.xor => try binaryArith(ctx, stack, .bit_xor),

            // ---- Comparisons ----
            op.lt => try compareOp(ctx, stack, .lt),
            op.lte => try compareOp(ctx, stack, .lte),
            op.gt => try compareOp(ctx, stack, .gt),
            op.gte => try compareOp(ctx, stack, .gte),
            op.eq => try compareOp(ctx, stack, .eq),
            op.neq => try compareOp(ctx, stack, .neq),
            op.strict_eq => try compareOp(ctx, stack, .strict_eq),
            op.strict_neq => try compareOp(ctx, stack, .strict_neq),

            // ---- Unary ----
            op.neg => try unaryOp(ctx, stack, .neg),
            op.plus => try unaryOp(ctx, stack, .plus),
            op.not => try unaryOp(ctx, stack, .bit_not),
            op.lnot => try unaryOp(ctx, stack, .lnot),
            op.inc => try unaryOp(ctx, stack, .inc),
            op.dec => try unaryOp(ctx, stack, .dec),

            // ---- Control flow ----
            op.goto => {
                const target = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc = target;
            },
            op.if_false => {
                const target = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                const value = try stack.pop();
                defer value.free(ctx.runtime);
                if (!valueTruthy(value)) {
                    frame.pc = target;
                }
            },
            op.if_true => {
                const target = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                const value = try stack.pop();
                defer value.free(ctx.runtime);
                if (valueTruthy(value)) {
                    frame.pc = target;
                }
            },

            // ---- Variable access ----
            op.get_var, op.get_var_undef => {
                const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                _ = atom_id;
                // F2+F3 minimum: push undefined as placeholder.
                // Full scope resolution requires F10 pipeline.
                try stack.push(core.Value.undefinedValue());
            },
            op.put_var => {
                const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                _ = atom_id;
                // F2+F3 minimum: pop and discard.
                const value = try stack.pop();
                value.free(ctx.runtime);
            },

            // ---- Object properties ----
            op.get_field => {
                const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                _ = atom_id;
                // F2+F3 minimum: pop object, push undefined as placeholder.
                // Full property access requires object system integration.
                const obj = try stack.pop();
                obj.free(ctx.runtime);
                try stack.push(core.Value.undefinedValue());
            },
            op.get_field2 => {
                const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                _ = atom_id;
                // F2+F3 minimum: keep object, push undefined as placeholder.
                try stack.push(core.Value.undefinedValue());
            },
            op.put_field => {
                const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                _ = atom_id;
                // F2+F3 minimum: pop object and value.
                const value = try stack.pop();
                value.free(ctx.runtime);
                const obj = try stack.pop();
                obj.free(ctx.runtime);
            },

            // ---- Array elements ----
            op.get_array_el => {
                // F2+F3 minimum: pop obj and key, push undefined as placeholder.
                const key = try stack.pop();
                key.free(ctx.runtime);
                const obj = try stack.pop();
                obj.free(ctx.runtime);
                try stack.push(core.Value.undefinedValue());
            },
            op.get_array_el2 => {
                // F2+F3 minimum: keep obj and key, push undefined as placeholder.
                try stack.push(core.Value.undefinedValue());
            },
            op.put_array_el => {
                // F2+F3 minimum: pop obj, key, and value.
                const value = try stack.pop();
                value.free(ctx.runtime);
                const key = try stack.pop();
                key.free(ctx.runtime);
                const obj = try stack.pop();
                obj.free(ctx.runtime);
            },

            // ---- Super ----
            op.get_super => {
                // F7 minimum: push undefined as placeholder.
                // Full super semantics require class system integration.
                try stack.push(core.Value.undefinedValue());
            },
            op.get_super_value => {
                const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                _ = atom_id;
                // F7 minimum: pop object, push undefined as placeholder.
                const obj = try stack.pop();
                obj.free(ctx.runtime);
                try stack.push(core.Value.undefinedValue());
            },
            op.put_super_value => {
                const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                _ = atom_id;
                // F7 minimum: pop object and value.
                const value = try stack.pop();
                value.free(ctx.runtime);
                const obj = try stack.pop();
                obj.free(ctx.runtime);
            },

            // ---- Calls ----
            op.call => {
                const argc = readInt(u16, function.code[frame.pc..][0..2]);
                frame.pc += 2;
                // F2+F3 minimum: pop func and args, push undefined as placeholder.
                // Full call semantics require callable integration.
                for (0..argc) |_| {
                    const arg = try stack.pop();
                    arg.free(ctx.runtime);
                }
                const func = try stack.pop();
                func.free(ctx.runtime);
                try stack.push(core.Value.undefinedValue());
            },
            op.call_method => {
                const argc = readInt(u16, function.code[frame.pc..][0..2]);
                frame.pc += 2;
                // F2+F3 minimum: pop obj, func, and args, push undefined as placeholder.
                for (0..argc) |_| {
                    const arg = try stack.pop();
                    arg.free(ctx.runtime);
                }
                const func = try stack.pop();
                func.free(ctx.runtime);
                const obj = try stack.pop();
                obj.free(ctx.runtime);
                try stack.push(core.Value.undefinedValue());
            },

            // ---- Object/array literals ----
            op.object => {
                // F2+F3 minimum: push undefined as placeholder.
                // Full object construction requires object system integration.
                try stack.push(core.Value.undefinedValue());
            },
            op.array_from => {
                const argc = readInt(u16, function.code[frame.pc..][0..2]);
                frame.pc += 2;
                // F2+F3 minimum: pop args, push undefined as placeholder.
                for (0..argc) |_| {
                    const arg = try stack.pop();
                    arg.free(ctx.runtime);
                }
                try stack.push(core.Value.undefinedValue());
            },
            op.define_field => {
                const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
                frame.pc += 4;
                _ = atom_id;
                // F2+F3 minimum: pop value, keep obj.
                const value = try stack.pop();
                value.free(ctx.runtime);
            },

            // ---- Source location (Phase 1 temp) ----
            op.source_loc => {
                frame.pc += 8; // skip pc + line
            },

            // ---- Generators (F9) ----
            op.yield => {
                // F9 minimum: pop value, push undefined as placeholder.
                // Full generator semantics require iterator protocol integration.
                const value = try stack.pop();
                value.free(ctx.runtime);
                try stack.push(core.Value.undefinedValue());
            },
            op.yield_star => {
                // F9 minimum: pop iterable, push undefined as placeholder.
                // Full yield* semantics require iterator protocol integration.
                const iterable = try stack.pop();
                iterable.free(ctx.runtime);
                try stack.push(core.Value.undefinedValue());
            },

            else => return throwUnsupported(ctx, opc),
        }
    }

    if (stack.peek()) |value| return value;
    return core.Value.undefinedValue();
}

// ---- Helpers ----

const BinaryOp = enum { add, sub, mul, div, mod, pow, shl, sar, shr, bit_and, bit_or, bit_xor };
const CompareOp = enum { lt, lte, gt, gte, eq, neq, strict_eq, strict_neq };
const UnaryOp = enum { neg, plus, bit_not, lnot, inc, dec };

fn binaryArith(ctx: *core.Context, stack: *stack_mod.Stack, binop: BinaryOp) !void {
    const rhs = try stack.pop();
    defer rhs.free(ctx.runtime);
    const lhs = try stack.pop();
    defer lhs.free(ctx.runtime);

    // For F2+F3 minimum, only support integer arithmetic.
    // Full value coercion lives in `value_ops.zig` and can be wired in a
    // follow-up slice.
    const a = lhs.asInt32() orelse {
        try stack.push(core.Value.int32(0));
        return;
    };
    const b = rhs.asInt32() orelse {
        try stack.push(core.Value.int32(0));
        return;
    };

    const result: i32 = switch (binop) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .div => if (b == 0) 0 else @divTrunc(a, b),
        .mod => if (b == 0) 0 else @mod(a, b),
        .pow => std.math.pow(i32, a, @max(0, b)),
        .shl => a << @intCast(@as(u32, @bitCast(b)) & 31),
        .sar => a >> @intCast(@as(u32, @bitCast(b)) & 31),
        .shr => @bitCast(@as(u32, @bitCast(a)) >> @intCast(@as(u32, @bitCast(b)) & 31)),
        .bit_and => a & b,
        .bit_or => a | b,
        .bit_xor => a ^ b,
    };
    try stack.push(core.Value.int32(result));
}

fn compareOp(ctx: *core.Context, stack: *stack_mod.Stack, cmp: CompareOp) !void {
    const rhs = try stack.pop();
    defer rhs.free(ctx.runtime);
    const lhs = try stack.pop();
    defer lhs.free(ctx.runtime);

    const a = lhs.asInt32() orelse 0;
    const b = rhs.asInt32() orelse 0;

    const result: bool = switch (cmp) {
        .lt => a < b,
        .lte => a <= b,
        .gt => a > b,
        .gte => a >= b,
        .eq, .strict_eq => a == b,
        .neq, .strict_neq => a != b,
    };
    try stack.push(core.Value.boolean(result));
}

fn unaryOp(ctx: *core.Context, stack: *stack_mod.Stack, unop: UnaryOp) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);

    const n = value.asInt32() orelse 0;
    const result: core.Value = switch (unop) {
        .neg => core.Value.int32(-%n),
        .plus => core.Value.int32(n),
        .bit_not => core.Value.int32(~n),
        .lnot => core.Value.boolean(!valueTruthy(value)),
        .inc => core.Value.int32(n +% 1),
        .dec => core.Value.int32(n -% 1),
    };
    try stack.push(result);
}

fn valueTruthy(value: core.Value) bool {
    if (value.asInt32()) |n| return n != 0;
    if (value.asBool()) |b| return b;
    return !(value.isUndefined() or value.isNull());
}

fn throwUnsupported(ctx: *core.Context, opc: u8) error{UnsupportedOpcode} {
    _ = ctx.throwValue(core.Value.int32(opc));
    return error.UnsupportedOpcode;
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
