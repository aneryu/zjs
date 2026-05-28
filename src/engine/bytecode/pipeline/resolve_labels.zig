//! Phase 3a: resolve_labels
//!
//! Mirrors `resolve_labels` at `quickjs.c:34197`.
//!
//! This phase injects function prologue, rewrites absolute jumps to
//! relative forms, and selects short-form opcodes.

const std = @import("std");
const atom = @import("../../core/atom.zig");
const memory = @import("../../core/memory.zig");
const bytecode_function = @import("../function.zig");
const function_def_mod = @import("../function_def.zig");
const opcode = @import("../opcode.zig");

// Special object subtypes (mirrors quickjs.c:17410-17416)
const SPECIAL_OBJECT_ARGUMENTS: u8 = 0;
const SPECIAL_OBJECT_MAPPED_ARGUMENTS: u8 = 1;
const SPECIAL_OBJECT_THIS_FUNC: u8 = 2;
const SPECIAL_OBJECT_NEW_TARGET: u8 = 3;
const SPECIAL_OBJECT_HOME_OBJECT: u8 = 4;
const SPECIAL_OBJECT_VAR_OBJECT: u8 = 5;
const SPECIAL_OBJECT_IMPORT_META: u8 = 6;
const SPECIAL_OBJECT_NULL_PROTO: u8 = 7;

pub const Error = error{
    InvalidBytecode,
};

/// Context for label resolution.
pub const Context = struct {
    function: *bytecode_function.Bytecode,
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    /// Optional FunctionDef for function prologue emission. When non-null,
    /// `resolve_labels` emits OP_special_object sequences for special
    /// variables (home_object, this_active_func, new_target, arguments, etc.).
    function_def: ?*const function_def_mod.FunctionDef = null,

    pub fn init(function: *bytecode_function.Bytecode) Context {
        return .{
            .function = function,
            .memory = function.memory,
            .atoms = function.atoms,
        };
    }

    pub fn initWithFunctionDef(
        function: *bytecode_function.Bytecode,
        fd: *const function_def_mod.FunctionDef,
    ) Context {
        return .{
            .function = function,
            .memory = function.memory,
            .atoms = function.atoms,
            .function_def = fd,
        };
    }
};

/// Run Phase 3a label resolution on a function.
///
/// Input: a Bytecode with Phase 2 output (no temp opcodes except label).
/// Output: the same Bytecode with label opcodes dropped.
///
/// This simplified implementation:
/// - Drops OP_label opcodes (5 bytes: opcode + label:u32)
/// - Preserves all other opcodes
///
/// Full QuickJS alignment (prologue, jump rewriting, short-form selection,
/// coalescing) will be added when FunctionDef is integrated into the parser.
/// Total byte length (opcode + operands) for `op_id`. Driven by the
/// comptime-baked `opcode.opcode_size` table so every opcode in
/// `quickjs-opcode.h` is recognised. Unknown ids fall back to 1 to
/// keep the walker progressing.
fn instrSize(op_id: u8) usize {
    const total = opcode.sizeOf(op_id);
    return if (total == 0) 1 else total;
}

fn isJumpOp(op_id: u8) bool {
    return op_id == opcode.op.if_false or
        op_id == opcode.op.if_true or
        op_id == opcode.op.goto or
        op_id == opcode.op.@"catch";
}

fn isAtomLabelU8Op(op_id: u8) bool {
    return op_id == opcode.op.with_get_var or
        op_id == opcode.op.with_put_var or
        op_id == opcode.op.with_delete_var or
        op_id == opcode.op.with_make_ref or
        op_id == opcode.op.with_get_ref or
        op_id == opcode.op.with_get_ref_undef;
}

const ShortSlotForm = struct {
    op_id: u8,
    size: u8,
    operand_size: u8,
};

fn selectShortSlot(op_id: u8, idx: u16) ?ShortSlotForm {
    const short_base: ?u8 = switch (op_id) {
        opcode.op.get_loc => opcode.op.get_loc0,
        opcode.op.put_loc => opcode.op.put_loc0,
        opcode.op.set_loc => opcode.op.set_loc0,
        opcode.op.get_arg => opcode.op.get_arg0,
        opcode.op.put_arg => opcode.op.put_arg0,
        opcode.op.set_arg => opcode.op.set_arg0,
        opcode.op.get_var_ref => opcode.op.get_var_ref0,
        opcode.op.put_var_ref => opcode.op.put_var_ref0,
        opcode.op.set_var_ref => opcode.op.set_var_ref0,
        else => null,
    };
    const base = short_base orelse return null;
    if (idx < 4) {
        return .{
            .op_id = base + @as(u8, @intCast(idx)),
            .size = 1,
            .operand_size = 0,
        };
    }

    const loc8_op: ?u8 = switch (op_id) {
        opcode.op.get_loc => opcode.op.get_loc8,
        opcode.op.put_loc => opcode.op.put_loc8,
        opcode.op.set_loc => opcode.op.set_loc8,
        else => null,
    };
    if (loc8_op) |loc_op| {
        if (idx < 256) {
            return .{ .op_id = loc_op, .size = 2, .operand_size = 1 };
        }
    }
    return .{ .op_id = op_id, .size = 3, .operand_size = 2 };
}

fn jumpTarget(code: []const u8, pc: usize) !usize {
    if (pc + 5 > code.len) return error.InvalidBytecode;
    const target = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
    if (target > code.len) return error.InvalidBytecode;
    return @intCast(target);
}

fn atomLabelTarget(code: []const u8, pc: usize) !usize {
    if (pc + 10 > code.len) return error.InvalidBytecode;
    const target = std.mem.readInt(u32, code[pc + 5 ..][0..4], .little);
    if (target > code.len) return error.InvalidBytecode;
    return @intCast(target);
}

fn relOffset(from_pc: usize, target_pc: usize) i64 {
    return @as(i64, @intCast(target_pc)) - @as(i64, @intCast(from_pc + 1));
}

fn jumpSizeForOffset(op_id: u8, diff: i64, use_short_opcodes: bool) usize {
    if (op_id == opcode.op.@"catch") return 5;
    if (use_short_opcodes) {
        if (diff >= std.math.minInt(i8) and diff <= std.math.maxInt(i8)) return 2;
        if (op_id == opcode.op.goto and diff >= std.math.minInt(i16) and diff <= std.math.maxInt(i16)) return 3;
    }
    return 5;
}

fn jumpOpForSize(op_id: u8, size: usize) u8 {
    return switch (size) {
        2 => switch (op_id) {
            opcode.op.if_false => opcode.op.if_false8,
            opcode.op.if_true => opcode.op.if_true8,
            opcode.op.goto => opcode.op.goto8,
            else => unreachable,
        },
        3 => switch (op_id) {
            opcode.op.goto => opcode.op.goto16,
            else => op_id,
        },
        5 => op_id,
        else => unreachable,
    };
}

fn loweredInstrSize(code: []const u8, pc: usize, use_short_opcodes: bool) usize {
    const op = code[pc];
    if (!use_short_opcodes) return instrSize(op);
    if (op == opcode.op.push_i32 and pc + 5 <= code.len) {
        const value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little);
        if (value >= -1 and value <= 7) return 1;
        if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) return 2;
        if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) return 3;
    }
    if (op == opcode.op.call and pc + 3 <= code.len) {
        const argc = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
        if (argc <= 3) return 1;
    }
    if ((op == opcode.op.push_const or op == opcode.op.fclosure) and pc + 5 <= code.len) {
        const idx = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
        if (idx < 256) return 2;
    }
    if (pc + 3 <= code.len) {
        const idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
        if (selectShortSlot(op, idx)) |form| return form.size;
    }
    return instrSize(op);
}

const GetLocShort = struct {
    idx: u2,
    size: usize,
};

fn getLocShort(code: []const u8, pc: usize, use_short_opcodes: bool) ?GetLocShort {
    if (!use_short_opcodes or pc >= code.len) return null;
    const op = code[pc];
    if (op >= opcode.op.get_loc0 and op <= opcode.op.get_loc3) {
        return .{ .idx = @intCast(op - opcode.op.get_loc0), .size = 1 };
    }
    if (op == opcode.op.get_loc and pc + 3 <= code.len) {
        const idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
        if (idx < 4) return .{ .idx = @intCast(idx), .size = 3 };
    }
    return null;
}

fn getLoc0Loc1PairSize(code: []const u8, pc: usize, use_short_opcodes: bool) ?usize {
    const first = getLocShort(code, pc, use_short_opcodes) orelse return null;
    if (first.idx != 0) return null;
    const second_pc = pc + first.size;
    if (hasJumpTargetTo(code, second_pc)) return null;
    const second = getLocShort(code, second_pc, use_short_opcodes) orelse return null;
    if (second.idx != 1) return null;
    return first.size + second.size;
}

fn undefinedDropPairSize(code: []const u8, pc: usize) ?usize {
    if (pc + 2 > code.len) return null;
    if (code[pc] == opcode.op.undefined and code[pc + 1] == opcode.op.drop) return 2;
    return null;
}

fn isTerminalOp(op_id: u8) bool {
    return switch (op_id) {
        opcode.op.goto,
        opcode.op.@"return",
        opcode.op.return_undef,
        opcode.op.return_async,
        opcode.op.tail_call,
        opcode.op.tail_call_method,
        opcode.op.throw,
        => true,
        else => false,
    };
}

fn isCleanupOp(op_id: u8) bool {
    return op_id == opcode.op.label or op_id == opcode.op.leave_scope or op_id == opcode.op.close_loc;
}

fn hasJumpTargetTo(code: []const u8, target_pc: usize) bool {
    var scan_pc: usize = 0;
    while (scan_pc < code.len) {
        const op_id = code[scan_pc];
        const size = if (op_id == opcode.op.label) 5 else instrSize(op_id);
        if (size == 0 or scan_pc + size > code.len) return false;
        if (isJumpOp(op_id)) {
            if ((jumpTarget(code, scan_pc) catch return false) == target_pc) return true;
        } else if (isAtomLabelU8Op(op_id)) {
            if ((atomLabelTarget(code, scan_pc) catch return false) == target_pc) return true;
        }
        scan_pc += size;
    }
    return false;
}

fn redundantReturnUndefSize(code: []const u8, pc: usize) ?usize {
    if (pc >= code.len or code[pc] != opcode.op.return_undef) return null;
    if (hasJumpTargetTo(code, pc)) return null;
    var scan_pc: usize = 0;
    var last_non_cleanup: ?u8 = null;
    while (scan_pc < pc) {
        const op_id = code[scan_pc];
        const size = if (op_id == opcode.op.label) 5 else instrSize(op_id);
        if (size == 0 or scan_pc + size > code.len) return null;
        if (!isCleanupOp(op_id)) last_non_cleanup = op_id;
        scan_pc += size;
    }
    if (last_non_cleanup) |op_id| {
        if (isTerminalOp(op_id)) return 1;
    }
    return null;
}

fn emitLoweredInstruction(code: []const u8, pc: usize, output: []u8, out_idx: *usize, use_short_opcodes: bool) !void {
    const op = code[pc];
    if (use_short_opcodes and op == opcode.op.push_i32 and pc + 5 <= code.len) {
        const value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little);
        if (value >= -1 and value <= 7) {
            output[out_idx.*] = switch (value) {
                -1 => opcode.op.push_minus1,
                0 => opcode.op.push_0,
                1 => opcode.op.push_1,
                2 => opcode.op.push_2,
                3 => opcode.op.push_3,
                4 => opcode.op.push_4,
                5 => opcode.op.push_5,
                6 => opcode.op.push_6,
                7 => opcode.op.push_7,
                else => unreachable,
            };
            out_idx.* += 1;
            return;
        }
        if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) {
            output[out_idx.*] = opcode.op.push_i8;
            output[out_idx.* + 1] = @bitCast(@as(i8, @intCast(value)));
            out_idx.* += 2;
            return;
        }
        if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
            output[out_idx.*] = opcode.op.push_i16;
            std.mem.writeInt(i16, output[out_idx.* + 1 ..][0..2], @intCast(value), .little);
            out_idx.* += 3;
            return;
        }
    }
    if (use_short_opcodes and op == opcode.op.call and pc + 3 <= code.len) {
        const argc = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
        if (argc <= 3) {
            output[out_idx.*] = switch (argc) {
                0 => opcode.op.call0,
                1 => opcode.op.call1,
                2 => opcode.op.call2,
                3 => opcode.op.call3,
                else => unreachable,
            };
            out_idx.* += 1;
            return;
        }
    }
    if (use_short_opcodes and (op == opcode.op.push_const or op == opcode.op.fclosure) and pc + 5 <= code.len) {
        const idx = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
        if (idx < 256) {
            output[out_idx.*] = if (op == opcode.op.push_const) opcode.op.push_const8 else opcode.op.fclosure8;
            output[out_idx.* + 1] = @intCast(idx);
            out_idx.* += 2;
            return;
        }
    }
    if (use_short_opcodes and pc + 3 <= code.len) {
        const idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
        if (selectShortSlot(op, idx)) |form| {
            output[out_idx.*] = form.op_id;
            switch (form.operand_size) {
                0 => {},
                1 => output[out_idx.* + 1] = @intCast(idx),
                2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], idx, .little),
                else => return error.InvalidBytecode,
            }
            out_idx.* += form.size;
            return;
        }
    }
    const size = instrSize(op);
    if (pc + size > code.len) return error.InvalidBytecode;
    @memcpy(output[out_idx.* .. out_idx.* + size], code[pc .. pc + size]);
    out_idx.* += size;
}

fn computeLayout(ctx: *const Context, positions: []usize, sizes: []usize, use_short_opcodes: bool, initial_pc: usize) !usize {
    const code = ctx.function.code;
    @memset(positions, 0);
    @memset(sizes, 0);

    var changed = true;
    var final_size: usize = 0;
    var pass: usize = 0;
    // Short-form jumps and instruction shrinkage can cascade through large
    // generated files; keep iterating past the old small fixed cap, while
    // still retaining a hard guard against accidental oscillation.
    const max_passes = 64;
    while (changed and pass < max_passes) : (pass += 1) {
        changed = false;
        var out_pc: usize = initial_pc;
        var pc: usize = 0;
        while (pc < code.len) {
            positions[pc] = out_pc;
            const op = code[pc];
            const old_size = sizes[pc];
            const in_size = if (op == opcode.op.label) 5 else instrSize(op);
            if (pc + in_size > code.len) return error.InvalidBytecode;

            const new_size: usize = if (op == opcode.op.label)
                0
            else if (undefinedDropPairSize(code, pc) != null)
                0
            else if (redundantReturnUndefSize(code, pc) != null)
                0
            else if (getLoc0Loc1PairSize(code, pc, use_short_opcodes) != null)
                1
            else if (isAtomLabelU8Op(op))
                instrSize(op)
            else if (isJumpOp(op)) blk: {
                const target = try jumpTarget(code, pc);
                const target_pc = positions[target];
                const diff = relOffset(out_pc, target_pc);
                break :blk jumpSizeForOffset(op, diff, use_short_opcodes);
            } else loweredInstrSize(code, pc, use_short_opcodes);

            sizes[pc] = new_size;
            if (old_size != new_size) changed = true;
            const next_pc = pc + (undefinedDropPairSize(code, pc) orelse (redundantReturnUndefSize(code, pc) orelse (getLoc0Loc1PairSize(code, pc, use_short_opcodes) orelse in_size)));
            var boundary_pc = pc + 1;
            while (boundary_pc <= next_pc and boundary_pc < positions.len) : (boundary_pc += 1) {
                positions[boundary_pc] = out_pc + new_size;
            }
            out_pc += new_size;
            pc = next_pc;
        }
        positions[code.len] = out_pc;
        final_size = out_pc;
    }
    if (changed) return error.InvalidBytecode;
    return final_size;
}

fn emitJump(code: []const u8, pc: usize, output: []u8, out_idx: *usize, positions: []const usize, size: usize) !void {
    const op = code[pc];
    const target = try jumpTarget(code, pc);
    const target_pc = positions[target];
    const current_pc = out_idx.*;
    const diff = relOffset(current_pc, target_pc);
    output[out_idx.*] = jumpOpForSize(op, size);
    switch (size) {
        2 => {
            output[out_idx.* + 1] = @bitCast(@as(i8, @intCast(diff)));
        },
        3 => {
            std.mem.writeInt(i16, output[out_idx.* + 1 ..][0..2], @intCast(diff), .little);
        },
        5 => {
            std.mem.writeInt(i32, output[out_idx.* + 1 ..][0..4], @intCast(diff), .little);
        },
        else => return error.InvalidBytecode,
    }
    out_idx.* += size;
}

fn emitAtomLabelU8(code: []const u8, pc: usize, output: []u8, out_idx: *usize, positions: []const usize) !void {
    if (pc + 10 > code.len) return error.InvalidBytecode;
    const target = try atomLabelTarget(code, pc);
    const target_pc = positions[target];
    const current_pc = out_idx.*;
    const diff = @as(i64, @intCast(target_pc)) - @as(i64, @intCast(current_pc + 5));
    if (diff < std.math.minInt(i32) or diff > std.math.maxInt(i32)) return error.InvalidBytecode;
    output[out_idx.*] = code[pc];
    @memcpy(output[out_idx.* + 1 .. out_idx.* + 5], code[pc + 1 .. pc + 5]);
    std.mem.writeInt(i32, output[out_idx.* + 5 ..][0..4], @intCast(diff), .little);
    output[out_idx.* + 9] = code[pc + 9];
    out_idx.* += 10;
}

/// Emit the function prologue with OP_special_object sequences.
/// Mirrors `quickjs.c:34232-34294`.
fn emitFunctionPrologue(ctx: *const Context, output: []u8, out_idx: *usize) !void {
    const fd = ctx.function_def orelse return;

    // home_object
    if (fd.home_object_var_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_HOME_OBJECT;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.home_object_var_idx), .little);
        out_idx.* += 5;
    }

    // this_active_func
    if (fd.this_active_func_var_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_THIS_FUNC;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.this_active_func_var_idx), .little);
        out_idx.* += 5;
    }

    // new_target
    if (fd.new_target_var_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_NEW_TARGET;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.new_target_var_idx), .little);
        out_idx.* += 5;
    }

    // this (special handling for derived class constructors)
    if (fd.this_var_idx >= 0) {
        if (fd.is_derived_class_constructor) {
            output[out_idx.*] = opcode.op.set_loc_uninitialized;
            std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.this_var_idx), .little);
            out_idx.* += 3;
        } else {
            output[out_idx.*] = opcode.op.push_this;
            out_idx.* += 1;
            output[out_idx.*] = opcode.op.put_loc;
            std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.this_var_idx), .little);
            out_idx.* += 3;
        }
    }

    // arguments
    if (fd.arguments_var_idx >= 0) {
        if (fd.is_strict_mode or !fd.has_simple_parameter_list) {
            output[out_idx.*] = opcode.op.special_object;
            output[out_idx.* + 1] = SPECIAL_OBJECT_ARGUMENTS;
            out_idx.* += 2;
        } else {
            // Mapped arguments - capture all args (simplified)
            output[out_idx.*] = opcode.op.special_object;
            output[out_idx.* + 1] = SPECIAL_OBJECT_MAPPED_ARGUMENTS;
            out_idx.* += 2;
        }
        if (fd.arguments_arg_idx >= 0) {
            output[out_idx.*] = opcode.op.set_loc;
            std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.arguments_arg_idx), .little);
            out_idx.* += 3;
        }
        output[out_idx.*] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.arguments_var_idx), .little);
        out_idx.* += 3;
    }

    // func_var (reference to current function)
    if (fd.func_var_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_THIS_FUNC;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.func_var_idx), .little);
        out_idx.* += 5;
    }

    // var_object
    if (fd.var_object_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_VAR_OBJECT;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.var_object_idx), .little);
        out_idx.* += 5;
    }

    // arg_var_object
    if (fd.arg_var_object_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_VAR_OBJECT;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.arg_var_object_idx), .little);
        out_idx.* += 5;
    }
}

pub fn run(ctx: *Context) !void {
    const func = ctx.function;
    const use_short_opcodes = if (ctx.function_def) |fd| fd.use_short_opcodes else false;

    // Calculate function prologue size
    var prologue_size: usize = 0;
    if (ctx.function_def) |fd| {
        if (fd.home_object_var_idx >= 0) prologue_size += 5;
        if (fd.this_active_func_var_idx >= 0) prologue_size += 5;
        if (fd.new_target_var_idx >= 0) prologue_size += 5;
        if (fd.this_var_idx >= 0) {
            if (fd.is_derived_class_constructor) {
                prologue_size += 3;
            } else {
                prologue_size += 4; // push_this (1) + put_loc (3)
            }
        }
        if (fd.arguments_var_idx >= 0) {
            prologue_size += 2; // special_object
            if (fd.arguments_arg_idx >= 0) prologue_size += 3;
            prologue_size += 3; // put_loc
        }
        if (fd.func_var_idx >= 0) prologue_size += 5;
        if (fd.var_object_idx >= 0) prologue_size += 5;
        if (fd.arg_var_object_idx >= 0) prologue_size += 5;
    }

    const positions = try ctx.memory.alloc(usize, func.code.len + 1);
    defer ctx.memory.free(usize, positions);
    const sizes = try ctx.memory.alloc(usize, func.code.len + 1);
    defer ctx.memory.free(usize, sizes);

    // First pass: compute the old-pc -> new-pc layout. OP_label is
    // dropped; jumps are rewritten from parser absolute targets to the
    // pc-relative form expected after resolve_labels.
    const output_size = try computeLayout(ctx, positions, sizes, use_short_opcodes, prologue_size);

    // Keep empty output as an inert slice so bytecode ownership stays explicit
    // without touching allocator accounting.
    const output: []u8 = if (output_size == 0)
        &.{}
    else
        try ctx.memory.alloc(u8, output_size);
    errdefer if (output.len != 0) ctx.memory.free(u8, output);

    // Second pass: emit prologue and copy (dropping labels).
    var out_idx: usize = 0;
    try emitFunctionPrologue(ctx, output, &out_idx);
    var i: usize = 0;
    while (i < func.code.len) {
        const op = func.code[i];
        if (op == opcode.op.label) {
            i += 5;
        } else if (undefinedDropPairSize(func.code, i)) |pair_size| {
            i += pair_size;
        } else if (redundantReturnUndefSize(func.code, i)) |return_size| {
            i += return_size;
        } else if (getLoc0Loc1PairSize(func.code, i, use_short_opcodes)) |pair_size| {
            output[out_idx] = opcode.op.get_loc0_loc1;
            out_idx += 1;
            i += pair_size;
        } else if (isJumpOp(op)) {
            const size = sizes[i];
            try emitJump(func.code, i, output, &out_idx, positions, size);
            i += instrSize(op);
        } else if (isAtomLabelU8Op(op)) {
            try emitAtomLabelU8(func.code, i, output, &out_idx, positions);
            i += instrSize(op);
        } else {
            const size = instrSize(op);
            if (i + size > func.code.len) return error.InvalidBytecode;
            try emitLoweredInstruction(func.code, i, output, &out_idx, use_short_opcodes);
            i += size;
        }
    }

    // Replace the old code. `output` is sized to `output_size`, the
    // worst-case post-lowering layout; trim it to `out_idx` before
    // installing so capacity tracking stays accurate.
    func.remapSourceLocs(positions);
    if (out_idx < output.len) {
        const trimmed = try ctx.memory.alloc(u8, out_idx);
        @memcpy(trimmed, output[0..out_idx]);
        ctx.memory.free(u8, output);
        func.installCode(trimmed);
    } else {
        func.installCode(output);
    }
}
