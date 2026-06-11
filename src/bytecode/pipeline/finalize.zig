//! Finalization: js_create_function equivalent
//!
//! Mirrors `js_create_function` at `quickjs.c:35401`.
//!
//! This walks the child_list of FunctionDefs, runs all pipeline phases,
//! and installs the final FunctionBytecode into the parent's cpool.

const std = @import("std");
const atom = @import("../../core/atom.zig");
const fb_mod = @import("../../core/function_bytecode.zig");
const bytecode_function = @import("../function.zig");
const function_def_mod = @import("../function_def.zig");
const opcode = @import("../opcode.zig");
const resolve_variables = @import("resolve_variables.zig");
const resolve_labels = @import("resolve_labels.zig");
const prepared_calls = @import("prepared_calls.zig");
const pc2line = @import("pc2line.zig");
const stack_size = @import("stack_size.zig");
const JSValue = @import("../../core/value.zig").JSValue;

pub const FinalizeError = error{
    OutOfMemory,
    InvalidBytecode,
    InvalidOpcode,
    BytecodeOverflow,
    StackUnderflow,
    StackOverflow,
    StackMismatch,
    ClosureVarNotFound,
    Pc2LineTruncated,
    Pc2LineOverflow,
};

/// JSContext for finalization.
pub const JSContext = struct {
    // For the interim Bytecode-based implementation, we just need
    // the function to process. The full FunctionDef-based version
    // will include parent/child relationship tracking.
};

/// Create a FunctionBytecode from a FunctionDef.
///
/// This mirrors `js_create_function` at `quickjs.c:35401`. It:
/// 1. Recursively processes child functions (child_list walk)
/// 2. Runs all pipeline phases on the FunctionDef
/// 3. Allocates and populates a FunctionBytecode structure
/// 4. Returns the FunctionBytecode
///
pub fn createFunctionBytecode(fd: *function_def_mod.FunctionDef, rt: anytype) FinalizeError![]bytecode_function.FunctionBytecode {
    try installChildFunctionBytecodes(fd, rt);

    var lowered = bytecode_function.Bytecode.init(fd.memory, fd.atoms, fd.func_name);
    defer lowered.deinit(rt);
    lowered.line_num = fd.line_num;
    lowered.col_num = fd.col_num;
    // Move the parser-built buffers instead of copying them. QuickJS runs
    // its passes directly on `fd->byte_code` and performs a single copy
    // into the packed JSFunctionBytecode (quickjs.c:36188/36226); moving
    // ownership of the growable code and atom-operand buffers into the
    // lowered carrier gives the same copy count. The FunctionDef keeps
    // only the variable/scope metadata the passes consult.
    lowered.code = fd.byte_code;
    lowered.code_capacity = fd.byte_code_capacity;
    fd.byte_code = &.{};
    fd.byte_code_capacity = 0;
    lowered.atom_operands = fd.atom_operands;
    lowered.atom_operands_capacity = fd.atom_operands_capacity;
    fd.atom_operands = &.{};
    fd.atom_operands_capacity = 0;
    for (fd.direct_call_sites) |site| {
        try lowered.appendDirectCallSite(.{
            .kind = .prop_atom,
            .prepare_pc = site.prepare_pc,
            .call_pc = site.call_pc,
            .atom_id = site.atom_id,
            .argc = site.argc,
        });
    }
    for (fd.source_loc_slots) |slot| try lowered.appendSourceLoc(slot.pc, slot.line_num, slot.col_num);
    try runPhases(&lowered, fd, fd);

    // Allocate FunctionBytecode as a single-element slice. Caller is
    // responsible for releasing the returned GC object.
    const slice = try fd.memory.alloc(bytecode_function.FunctionBytecode, 1);
    const fb = &slice[0];
    fb.* = bytecode_function.FunctionBytecode.init(fd.memory, fd.atoms, fd.func_name);

    var registered = false;
    var committed = false;
    errdefer if (!committed) {
        if (registered) rt.gc.unlinkObject(&fb.header);
        fb.deinit(rt);
        fd.memory.free(bytecode_function.FunctionBytecode, slice);
    };

    // Copy flags and metadata
    fb.is_strict_mode = fd.is_strict_mode;
    fb.has_prototype = fd.has_prototype;
    fb.has_simple_parameter_list = fd.has_simple_parameter_list;
    fb.is_class_constructor = fd.func_type == .class_constructor or fd.func_type == .derived_class_constructor;
    fb.is_derived_class_constructor = fd.is_derived_class_constructor;
    fb.need_home_object = fd.need_home_object;
    fb.func_kind = fd.func_kind;
    fb.is_arrow_function = fd.func_type == .arrow;
    fb.new_target_allowed = fd.new_target_allowed;
    fb.super_call_allowed = fd.super_call_allowed;
    fb.super_allowed = fd.super_allowed;
    fb.arguments_allowed = fd.arguments_allowed;
    fb.backtrace_barrier = fd.backtrace_barrier;
    fb.is_indirect_eval = fd.is_indirect_eval;

    // Pack all read-only artifact slices into a single block allocation.
    // Segments are reserved largest-alignment-first to minimize padding;
    // the slice fields below point into `fb.block` and `deinit` releases
    // the whole block at once.
    const source_len: usize = if (fd.source_text) |source| source.len else 0;
    var layout = fb_mod.BlockBuilder{};
    const cpool_off = layout.reserve(JSValue, fd.cpool.len);
    const call_sites_off = layout.reserve(bytecode_function.CallSite, lowered.call_sites.len);
    const vardefs_off = layout.reserve(function_def_mod.VarDef, fd.vars.len);
    const closure_var_off = layout.reserve(function_def_mod.ClosureVar, fd.closure_var.len);
    const atom_operands_off = layout.reserve(atom.Atom, lowered.atom_operands.len);
    const arg_names_off = layout.reserve(atom.Atom, fd.args.len);
    const var_names_off = layout.reserve(atom.Atom, fd.vars.len);
    const var_ref_names_off = layout.reserve(atom.Atom, fd.closure_var.len);
    const global_var_names_off = layout.reserve(atom.Atom, fd.global_vars.len);
    const class_instance_fields_off = layout.reserve(atom.Atom, fd.class_instance_fields.len);
    const private_bound_names_off = layout.reserve(atom.Atom, fd.private_bound_names.len);
    const class_private_names_off = layout.reserve(atom.Atom, fd.class_private_names.len);
    const byte_code_off = layout.reserve(u8, lowered.code.len);
    const fusion_cold_off = layout.reserve(u8, lowered.code.len);
    const pc2line_off = layout.reserve(u8, lowered.pc2line_buf.len);
    const source_off = layout.reserve(u8, source_len);
    const var_is_lexical_off = layout.reserve(bool, fd.vars.len);
    const var_is_const_off = layout.reserve(bool, fd.vars.len);
    const var_ref_is_lexical_off = layout.reserve(bool, fd.closure_var.len);
    const var_ref_is_const_off = layout.reserve(bool, fd.closure_var.len);
    fb.block = try fd.memory.allocAlignedBytes(layout.size, fb_mod.block_alignment);
    const block = fb.block;

    // Copy lowered bytecode.
    if (lowered.code.len > 0) {
        fb.byte_code = fb_mod.blockSlice(block, u8, byte_code_off, lowered.code.len);
        @memcpy(fb.byte_code, lowered.code);
        fb.byte_code_len = @intCast(lowered.code.len);
        if (fd.func_kind == .generator or fd.func_kind == .async_generator) {
            fb.generator_body_pc = findGeneratorBodyMarker(lowered.code) orelse 0;
        }
        const fusion_cold = fb_mod.blockSlice(block, u8, fusion_cold_off, lowered.code.len);
        @memset(fusion_cold, 0);
        fb.fusion_cold = fusion_cold;
    }
    if (lowered.atom_operands.len > 0) {
        const atom_operands = fb_mod.blockSlice(block, atom.Atom, atom_operands_off, lowered.atom_operands.len);
        for (lowered.atom_operands, atom_operands) |atom_id, *out| out.* = fd.atoms.dup(atom_id);
        fb.atom_operands = atom_operands;
    }
    if (lowered.call_sites.len > 0) {
        const call_sites = fb_mod.blockSlice(block, bytecode_function.CallSite, call_sites_off, lowered.call_sites.len);
        for (lowered.call_sites, call_sites) |site, *out| {
            out.* = site;
            out.atom_id = fd.atoms.dup(site.atom_id);
        }
        fb.call_sites = call_sites;
    }
    if (fd.args.len > 0) {
        const arg_names = fb_mod.blockSlice(block, atom.Atom, arg_names_off, fd.args.len);
        for (fd.args, arg_names) |arg, *out| out.* = fd.atoms.dup(arg.var_name);
        fb.arg_names = arg_names;
    }

    // Copy vardefs plus the var-name metadata views.
    if (fd.vars.len > 0) {
        const var_names = fb_mod.blockSlice(block, atom.Atom, var_names_off, fd.vars.len);
        const var_is_lexical = fb_mod.blockSlice(block, bool, var_is_lexical_off, fd.vars.len);
        const var_is_const = fb_mod.blockSlice(block, bool, var_is_const_off, fd.vars.len);
        for (fd.vars, var_names, var_is_lexical, var_is_const) |v, *name, *is_lexical, *is_const| {
            name.* = fd.atoms.dup(v.var_name);
            is_lexical.* = v.is_lexical;
            is_const.* = v.is_const;
        }
        fb.var_names = var_names;
        fb.var_is_lexical = var_is_lexical;
        fb.var_is_const = var_is_const;

        const vardefs = fb_mod.blockSlice(block, function_def_mod.VarDef, vardefs_off, fd.vars.len);
        @memcpy(vardefs, fd.vars);
        for (vardefs) |*v| v.var_name = fd.atoms.dup(v.var_name);
        fb.vardefs = vardefs;
    }

    // Copy closure_var plus the var-ref metadata views.
    if (fd.closure_var.len > 0) {
        const var_ref_names = fb_mod.blockSlice(block, atom.Atom, var_ref_names_off, fd.closure_var.len);
        const var_ref_is_lexical = fb_mod.blockSlice(block, bool, var_ref_is_lexical_off, fd.closure_var.len);
        const var_ref_is_const = fb_mod.blockSlice(block, bool, var_ref_is_const_off, fd.closure_var.len);
        for (fd.closure_var, var_ref_names, var_ref_is_lexical, var_ref_is_const) |cv, *name, *is_lexical, *is_const| {
            name.* = fd.atoms.dup(cv.var_name);
            is_lexical.* = cv.is_lexical;
            is_const.* = cv.is_const;
        }
        fb.var_ref_names = var_ref_names;
        fb.var_ref_is_lexical = var_ref_is_lexical;
        fb.var_ref_is_const = var_ref_is_const;

        const closure_var = fb_mod.blockSlice(block, function_def_mod.ClosureVar, closure_var_off, fd.closure_var.len);
        @memcpy(closure_var, fd.closure_var);
        for (closure_var) |*cv| cv.var_name = fd.atoms.dup(cv.var_name);
        fb.closure_var = closure_var;
    }

    if (fd.global_vars.len > 0) {
        const global_var_names = fb_mod.blockSlice(block, atom.Atom, global_var_names_off, fd.global_vars.len);
        for (fd.global_vars, global_var_names) |gv, *out| out.* = fd.atoms.dup(gv.var_name);
        fb.global_var_names = global_var_names;
    }
    if (fd.class_instance_fields.len > 0) {
        const fields = fb_mod.blockSlice(block, atom.Atom, class_instance_fields_off, fd.class_instance_fields.len);
        for (fd.class_instance_fields, fields) |atom_id, *out| out.* = fd.atoms.dup(atom_id);
        fb.class_instance_fields = fields;
    }
    if (fd.private_bound_names.len > 0) {
        const names = fb_mod.blockSlice(block, atom.Atom, private_bound_names_off, fd.private_bound_names.len);
        for (fd.private_bound_names, names) |atom_id, *out| out.* = fd.atoms.dup(atom_id);
        fb.private_bound_names = names;
    }
    if (fd.class_private_names.len > 0) {
        const names = fb_mod.blockSlice(block, atom.Atom, class_private_names_off, fd.class_private_names.len);
        for (fd.class_private_names, names) |atom_id, *out| out.* = fd.atoms.dup(atom_id);
        fb.class_private_names = names;
    }

    // Copy metadata counts
    fb.arg_count = @intCast(fd.arg_count);
    fb.var_count = @intCast(fd.var_count);
    fb.defined_arg_count = @intCast(fd.defined_arg_count);
    fb.var_ref_count = @intCast(fd.var_ref_count);
    fb.closure_var_count = @intCast(fd.closure_var_count);
    fb.stack_size = lowered.stack_size;
    try bytecode_function.allocateFunctionBytecodeIcSlots(fb);

    // Copy source location
    fb.atoms.replace(&fb.filename, fd.filename);
    fb.line_num = fd.line_num;
    fb.col_num = fd.col_num;
    if (lowered.pc2line_buf.len != 0) {
        fb.pc2line_buf = fb_mod.blockSlice(block, u8, pc2line_off, lowered.pc2line_buf.len);
        @memcpy(fb.pc2line_buf, lowered.pc2line_buf);
        fb.pc2line_len = @intCast(lowered.pc2line_buf.len);
    }
    if (fd.source_text) |source| {
        const owned = fb_mod.blockSlice(block, u8, source_off, source.len);
        @memcpy(owned, source);
        fb.source = owned;
        fb.source_len = @intCast(source.len);
    }

    // Copy constants.
    if (fd.cpool.len > 0) {
        const cpool = fb_mod.blockSlice(block, JSValue, cpool_off, fd.cpool.len);
        fb.cpool_count = @intCast(fd.cpool.len);
        for (fd.cpool, cpool) |value, *out| out.* = value.dup();
        fb.cpool = cpool;
    }
    cacheSimpleNumericBytecode(fb);

    try rt.gc.addWithSize(&fb.header, fb.heapByteSize());
    registered = true;

    committed = true;
    return slice;
}

fn findGeneratorBodyMarker(code: []const u8) ?usize {
    const op = @import("../opcode.zig").op;
    var i: usize = 0;
    while (i + 4 <= code.len) : (i += 1) {
        if (code[i] == op.push_false and
            code[i + 1] == op.drop and
            code[i + 2] == op.push_true and
            code[i + 3] == op.drop)
        {
            return i + 4;
        }
    }
    return null;
}

fn cacheSimpleNumericBytecode(fb: *bytecode_function.FunctionBytecode) void {
    fb.simple_numeric_kind = .none;
    fb.simple_numeric_op = 0;
    fb.simple_numeric_rhs = 0;
    fb.simple_string_kind = .none;

    const op = opcode.op;
    if (fb.is_class_constructor or fb.func_kind != .normal) return;

    if (fb.var_count == 0 and fb.var_ref_count == 0 and fb.cpool_count == 0) {
        if (simpleNumericArg0Const(fb.byte_code)) |simple| {
            fb.simple_numeric_kind = .arg0_const;
            fb.simple_numeric_op = simple.binop;
            fb.simple_numeric_rhs = simple.rhs;
            return;
        }
        if (fb.byte_code.len == 4 and
            fb.byte_code[0] == op.get_arg0 and
            fb.byte_code[1] == op.get_arg1 and
            isSimpleNumericBinop(fb.byte_code[2]) and
            fb.byte_code[3] == op.@"return")
        {
            fb.simple_numeric_kind = .arg0_arg1;
            fb.simple_numeric_op = fb.byte_code[2];
            return;
        }
    }

    if (fb.var_count == 0 and fb.cpool_count == 0 and
        fb.byte_code.len == 4 and
        fb.byte_code[0] == op.get_var_ref0 and
        fb.byte_code[1] == op.get_arg0 and
        isSimpleNumericBinop(fb.byte_code[2]) and
        fb.byte_code[3] == op.@"return")
    {
        fb.simple_numeric_kind = .capture0_arg0;
        fb.simple_numeric_op = fb.byte_code[2];
        return;
    }

    if (simpleCapture0PostIncReturn(fb)) {
        fb.simple_numeric_kind = .capture0_post_inc_return;
        return;
    }

    if (simplePercentHexBytecode(fb)) fb.simple_string_kind = .percent_hex_byte;
}

const SimpleNumericArg0Const = struct {
    binop: u8,
    rhs: i32,
};

fn simpleNumericArg0Const(code: []const u8) ?SimpleNumericArg0Const {
    const op = opcode.op;
    if (code.len < 4 or code[0] != op.get_arg0) return null;

    var pc: usize = 1;
    const rhs = simpleInlineIntConstant(code, &pc) orelse return null;
    if (pc >= code.len) return null;
    const binop = code[pc];
    pc += 1;
    if (!isSimpleNumericBinop(binop)) return null;
    if (pc >= code.len or code[pc] != op.@"return") return null;
    pc += 1;
    if (pc != code.len) return null;
    return .{ .binop = binop, .rhs = rhs };
}

fn simpleInlineIntConstant(code: []const u8, pc: *usize) ?i32 {
    const op = opcode.op;
    if (pc.* >= code.len) return null;
    const opcode_id = code[pc.*];
    pc.* += 1;
    return switch (opcode_id) {
        op.push_minus1 => -1,
        op.push_0 => 0,
        op.push_1 => 1,
        op.push_2 => 2,
        op.push_3 => 3,
        op.push_4 => 4,
        op.push_5 => 5,
        op.push_6 => 6,
        op.push_7 => 7,
        op.push_i8 => blk: {
            if (pc.* >= code.len) return null;
            const value: i8 = @bitCast(code[pc.*]);
            pc.* += 1;
            break :blk @as(i32, value);
        },
        op.push_i16 => blk: {
            if (pc.* + 2 > code.len) return null;
            const value = std.mem.readInt(i16, code[pc.*..][0..2], .little);
            pc.* += 2;
            break :blk @as(i32, value);
        },
        else => null,
    };
}

fn isSimpleNumericBinop(opcode_id: u8) bool {
    const op = opcode.op;
    return switch (opcode_id) {
        op.add, op.sub, op.mul, op.div, op.mod => true,
        else => false,
    };
}

const VarRefOp = struct {
    idx: u16,
    next_pc: usize,
};

fn decodeVarRefGet(code: []const u8, pc: usize) ?VarRefOp {
    const op = opcode.op;
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_var_ref, op.get_var_ref_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{
                .idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little),
                .next_pc = pc + 3,
            };
        },
        op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3 => .{
            .idx = @intCast(code[pc] - op.get_var_ref0),
            .next_pc = pc + 1,
        },
        else => null,
    };
}

fn decodeVarRefPut(code: []const u8, pc: usize) ?VarRefOp {
    const op = opcode.op;
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.put_var_ref, op.put_var_ref_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{
                .idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little),
                .next_pc = pc + 3,
            };
        },
        op.put_var_ref0, op.put_var_ref1, op.put_var_ref2, op.put_var_ref3 => .{
            .idx = @intCast(code[pc] - op.put_var_ref0),
            .next_pc = pc + 1,
        },
        else => null,
    };
}

fn simpleCapture0PostIncReturn(fb: *const bytecode_function.FunctionBytecode) bool {
    const op = opcode.op;
    if (fb.is_class_constructor or fb.func_kind != .normal) return false;
    if (fb.var_count != 0 or fb.cpool_count != 0) return false;

    const code = fb.byte_code;
    const first_get = decodeVarRefGet(code, 0) orelse return false;
    if (first_get.idx != 0) return false;
    var pc = first_get.next_pc;
    if (pc >= code.len or code[pc] != op.post_inc) return false;
    pc += 1;
    const put = decodeVarRefPut(code, pc) orelse return false;
    if (put.idx != 0) return false;
    pc = put.next_pc;
    if (pc >= code.len or code[pc] != op.drop) return false;
    pc += 1;
    const second_get = decodeVarRefGet(code, pc) orelse return false;
    if (second_get.idx != 0) return false;
    pc = second_get.next_pc;
    if (pc >= code.len or code[pc] != op.@"return") return false;
    pc += 1;
    return pc == code.len;
}

fn simplePercentHexBytecode(fb: *const bytecode_function.FunctionBytecode) bool {
    const op = opcode.op;
    const code = fb.byte_code;
    if (fb.var_count != 1 or fb.var_ref_count != 0 or fb.cpool_count != 0) return false;
    if (code.len != 28) return false;
    if (code[0] != op.push_atom_value or
        code[5] != op.put_loc0 or
        code[6] != op.push_atom_value or
        code[11] != op.get_loc0 or
        code[12] != op.get_arg0 or
        code[13] != op.push_4 or
        code[14] != op.sar or
        code[15] != op.push_i8 or
        code[16] != 15 or
        code[17] != op.@"and" or
        code[18] != op.get_array_el or
        code[19] != op.add or
        code[20] != op.get_loc0 or
        code[21] != op.get_arg0 or
        code[22] != op.push_i8 or
        code[23] != 15 or
        code[24] != op.@"and" or
        code[25] != op.get_array_el or
        code[26] != op.add or
        code[27] != op.@"return")
    {
        return false;
    }

    const hex_atom = std.mem.readInt(atom.Atom, code[1..][0..4], .little);
    const percent_atom = std.mem.readInt(atom.Atom, code[7..][0..4], .little);
    const hex = fb.atoms.name(hex_atom) orelse return false;
    const percent = fb.atoms.name(percent_atom) orelse return false;
    return std.mem.eql(u8, hex, "0123456789ABCDEF") and std.mem.eql(u8, percent, "%");
}

/// Run all pipeline phases on a compile/execution `Bytecode`.
///
/// This path is used by callers that execute a `Bytecode` object directly
/// instead of first materialising a GC-owned `FunctionBytecode` artifact:
/// 1. Run Phase 2 (resolve_variables)
/// 2. Run Phase 3a (resolve_labels)
/// 3. Run Phase 3b (pc2line)
/// 4. Run Phase 3c (stack_size)
///
/// `createFunctionBytecode` is the QuickJS-style storage path. It lowers a
/// `FunctionDef`, stores the result in `FunctionBytecode`, and the VM obtains
/// a borrowed execution view with `bytecode.function.asBytecodeView`.
pub fn run(function: *bytecode_function.Bytecode) !void {
    return runWithFunctionDef(function, null);
}

/// Variant that consumes a `FunctionDef` for local-slot lookup. When
/// `fd` is non-null, `resolve_variables` lowers `scope_get_var` /
/// `scope_put_var` to `get_loc` / `put_loc` for any atom found in
/// `fd.vars`; this also propagates `fd.var_count` onto the produced
/// `Bytecode.var_count` so the VM frame can size its locals array.
/// Also processes child FunctionDefs recursively.
pub fn runWithFunctionDef(
    function: *bytecode_function.Bytecode,
    fd: ?*const function_def_mod.FunctionDef,
) !void {
    // const FD: caller cannot mutate, pass through as-is.
    try runPhases(function, fd, null);
    if (fd) |def| try syncFunctionDefCpool(function, def);
}

/// JSRuntime-aware variant used when the parser produced FunctionDef child
/// entries. It recursively materialises child FunctionBytecode objects and
/// installs them into the executable Bytecode constant pool so `fclosure*`
/// operands have real callees.
pub fn runWithFunctionDefRuntime(
    function: *bytecode_function.Bytecode,
    fd: ?*function_def_mod.FunctionDef,
    rt: anytype,
) !void {
    if (fd) |def| {
        try installChildFunctionBytecodes(def, rt);
        try syncFunctionDefCpool(function, def);
    }
    try runPhases(function, fd, fd);
}

fn runPhases(
    function: *bytecode_function.Bytecode,
    fd: ?*const function_def_mod.FunctionDef,
    fd_mut: ?*function_def_mod.FunctionDef,
) !void {
    // Phase 2: resolve_variables (with optional FunctionDef).
    var resolve_ctx = if (fd) |def|
        resolve_variables.JSContext.initWithFunctionDef(function, def)
    else
        resolve_variables.JSContext.init(function);
    try resolve_variables.run(&resolve_ctx);

    // After resolve_variables, enable short opcodes for resolve_labels
    // (mirrors quickjs.c:35101 where use_short_opcodes is set after
    // the resolve_variables pass completes).
    if (fd_mut) |def| {
        def.use_short_opcodes = true;
    }

    // Phase 3a: resolve_labels (with optional FunctionDef prologue metadata).
    var labels_ctx = if (fd) |def|
        resolve_labels.JSContext.initWithFunctionDef(function, def)
    else
        resolve_labels.JSContext.init(function);
    try resolve_labels.run(&labels_ctx);

    // Propagate locals count so the VM frame can size its `locals`
    // array. `createFunctionBytecode` copies the same lowered metadata
    // into the final GC-owned function artifact.
    if (fd) |def| {
        if (def.var_count >= 0) {
            function.var_count = @intCast(def.var_count);
        }
        if (def.arg_count >= 0) {
            function.arg_count = @intCast(def.arg_count);
        }
        try syncBytecodeVarNames(function, def);
        try syncBytecodeVarRefNames(function, def);
        try syncBytecodeGlobalVarNames(function, def);
        try removeUncapturedCloseLoc(function, def);
    }

    try prepared_calls.run(function);

    // Phase 3b: pc2line from remapped Bytecode source slots.
    try encodePc2Line(function);

    // Phase 3c: compute_stack_size over resolved QuickJS-format bytecode.
    function.stack_size = try computeStackSizeForCurrentBytecode(function.code);
    try function.allocateIcSlots();
    try function.allocateFusionCold();
}

fn computeStackSizeForCurrentBytecode(code: []const u8) !u16 {
    return stack_size.compute(code, .{});
}

fn removeUncapturedCloseLoc(
    function: *bytecode_function.Bytecode,
    fd: *const function_def_mod.FunctionDef,
) !void {
    var remove_count: usize = 0;
    var pc: usize = 0;
    while (pc < function.code.len) {
        const op_id = function.code[pc];
        const size = opcode.sizeOf(op_id);
        if (size == 0 or pc + size > function.code.len) return error.InvalidBytecode;
        if (op_id == opcode.op.close_loc) {
            const loc_idx = std.mem.readInt(u16, function.code[pc + 1 ..][0..2], .little);
            if (!localIsCapturedByChild(fd, loc_idx)) remove_count += size;
        }
        pc += size;
    }
    if (remove_count == 0) return;

    const old_code = function.code;
    const next_len = old_code.len - remove_count;
    const next = try function.memory.alloc(u8, next_len);
    errdefer function.memory.free(u8, next);
    const pc_map = try function.memory.alloc(usize, old_code.len + 1);
    defer function.memory.free(usize, pc_map);

    pc = 0;
    var out: usize = 0;
    while (pc < old_code.len) {
        const op_id = old_code[pc];
        const size = opcode.sizeOf(op_id);
        if (size == 0 or pc + size > old_code.len) return error.InvalidBytecode;

        var boundary = pc;
        while (boundary < pc + size) : (boundary += 1) pc_map[boundary] = out;
        if (op_id == opcode.op.close_loc) {
            const loc_idx = std.mem.readInt(u16, old_code[pc + 1 ..][0..2], .little);
            if (!localIsCapturedByChild(fd, loc_idx)) {
                pc += size;
                continue;
            }
        }

        @memcpy(next[out..][0..size], old_code[pc..][0..size]);
        out += size;
        pc += size;
    }
    pc_map[old_code.len] = out;
    try patchRelativeJumpsAfterPcMap(old_code, next, pc_map);
    function.remapSourceLocs(pc_map);
    function.remapDirectCallSites(pc_map);
    function.installCode(next);
}

fn patchRelativeJumpsAfterPcMap(old_code: []const u8, new_code: []u8, pc_map: []const usize) !void {
    var pc: usize = 0;
    while (pc < old_code.len) {
        const op_id = old_code[pc];
        const size = opcode.sizeOf(op_id);
        if (size == 0 or pc + size > old_code.len) return error.InvalidBytecode;
        if (relativeJumpWidth(op_id)) |width| {
            const old_operand_pc = pc + 1;
            const old_target = relativeTarget(old_code, old_operand_pc, width);
            if (old_target < 0 or old_target > old_code.len) return error.InvalidBytecode;
            const new_pc = pc_map[pc];
            if (new_pc + size <= new_code.len) {
                const new_operand_pc = new_pc + 1;
                const new_target = pc_map[@intCast(old_target)];
                const diff = @as(i64, @intCast(new_target)) - @as(i64, @intCast(new_operand_pc));
                try writeRelativeDiff(new_code[new_operand_pc..], width, diff);
            }
        }
        pc += size;
    }
}

fn relativeJumpWidth(op_id: u8) ?usize {
    return switch (op_id) {
        opcode.op.if_false8, opcode.op.if_true8, opcode.op.goto8 => 1,
        opcode.op.goto16 => 2,
        opcode.op.if_false, opcode.op.if_true, opcode.op.goto, opcode.op.@"catch", opcode.op.gosub => 4,
        else => null,
    };
}

fn relativeTarget(code: []const u8, operand_pc: usize, width: usize) i64 {
    const diff: i64 = switch (width) {
        1 => @as(i8, @bitCast(code[operand_pc])),
        2 => std.mem.readInt(i16, code[operand_pc..][0..2], .little),
        4 => std.mem.readInt(i32, code[operand_pc..][0..4], .little),
        else => unreachable,
    };
    return @as(i64, @intCast(operand_pc)) + diff;
}

fn writeRelativeDiff(bytes: []u8, width: usize, diff: i64) !void {
    switch (width) {
        1 => bytes[0] = @bitCast(@as(i8, @intCast(diff))),
        2 => std.mem.writeInt(i16, bytes[0..2], @intCast(diff), .little),
        4 => std.mem.writeInt(i32, bytes[0..4], @intCast(diff), .little),
        else => return error.InvalidBytecode,
    }
}

const localIsCapturedByChild = resolve_variables.localIsCaptured;

fn encodePc2Line(function: *bytecode_function.Bytecode) !void {
    if (function.source_loc_slots.len == 0) {
        function.installPc2Line(&.{}, function.line_num, function.col_num);
        return;
    }
    var encoded = try pc2line.encode(function.memory, function.source_loc_slots, function.line_num, function.col_num);
    defer encoded.deinit();
    if (encoded.bytes.len == 0) {
        function.installPc2Line(&.{}, encoded.line_num, encoded.col_num);
        return;
    }
    const owned = try function.memory.alloc(u8, encoded.bytes.len);
    @memcpy(owned, encoded.bytes);
    function.installPc2Line(owned, encoded.line_num, encoded.col_num);
}

fn syncBytecodeVarNames(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
    if (function.var_names.len != 0) {
        const var_names = function.var_names;
        function.var_names = &.{};
        for (var_names) |atom_id| function.atoms.free(atom_id);
        function.memory.free(atom.Atom, var_names);
    }
    if (function.var_is_lexical.len != 0) {
        const var_is_lexical = function.var_is_lexical;
        function.var_is_lexical = &.{};
        function.memory.free(bool, var_is_lexical);
    }
    if (function.var_is_const.len != 0) {
        const var_is_const = function.var_is_const;
        function.var_is_const = &.{};
        function.memory.free(bool, var_is_const);
    }
    if (fd.vars.len == 0) return;

    const metadata = try copyVarNameMetadata(function.memory, function.atoms, fd.vars);
    function.var_names = metadata.names;
    function.var_is_lexical = metadata.is_lexical;
    function.var_is_const = metadata.is_const;
}

const VarNameMetadata = struct {
    names: []atom.Atom,
    is_lexical: []bool,
    is_const: []bool,
};

fn copyVarNameMetadata(memory: anytype, atoms: *atom.AtomTable, vars: []const function_def_mod.VarDef) !VarNameMetadata {
    const names = try memory.alloc(atom.Atom, vars.len);
    var initialized: usize = 0;
    errdefer {
        for (names[0..initialized]) |atom_id| atoms.free(atom_id);
        memory.free(atom.Atom, names);
    }
    const is_lexical = try memory.alloc(bool, vars.len);
    errdefer memory.free(bool, is_lexical);
    const is_const = try memory.alloc(bool, vars.len);
    errdefer memory.free(bool, is_const);

    for (vars, 0..) |v, idx| {
        names[idx] = atoms.dup(v.var_name);
        is_lexical[idx] = v.is_lexical;
        is_const[idx] = v.is_const;
        initialized += 1;
    }

    return .{ .names = names, .is_lexical = is_lexical, .is_const = is_const };
}

fn syncBytecodeVarRefNames(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
    if (function.var_ref_names.len != 0) {
        const var_ref_names = function.var_ref_names;
        function.var_ref_names = &.{};
        for (var_ref_names) |atom_id| function.atoms.free(atom_id);
        function.memory.free(atom.Atom, var_ref_names);
    }
    if (function.var_ref_is_lexical.len != 0) {
        const var_ref_is_lexical = function.var_ref_is_lexical;
        function.var_ref_is_lexical = &.{};
        function.memory.free(bool, var_ref_is_lexical);
    }
    if (function.var_ref_is_const.len != 0) {
        const var_ref_is_const = function.var_ref_is_const;
        function.var_ref_is_const = &.{};
        function.memory.free(bool, var_ref_is_const);
    }
    if (fd.closure_var.len == 0) return;
    const names = try function.memory.alloc(atom.Atom, fd.closure_var.len);
    errdefer function.memory.free(atom.Atom, names);
    const is_lexical = try function.memory.alloc(bool, fd.closure_var.len);
    errdefer function.memory.free(bool, is_lexical);
    const is_const = try function.memory.alloc(bool, fd.closure_var.len);
    var initialized: usize = 0;
    errdefer {
        for (names[0..initialized]) |atom_id| function.atoms.free(atom_id);
        function.memory.free(bool, is_const);
    }
    for (fd.closure_var, 0..) |cv, idx| {
        names[idx] = fd.atoms.dup(cv.var_name);
        is_lexical[idx] = cv.is_lexical;
        is_const[idx] = cv.is_const;
        initialized += 1;
    }
    function.var_ref_names = names;
    function.var_ref_is_lexical = is_lexical;
    function.var_ref_is_const = is_const;
}

fn syncBytecodeGlobalVarNames(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
    if (function.global_var_names.len != 0) {
        const global_var_names = function.global_var_names;
        function.global_var_names = &.{};
        for (global_var_names) |atom_id| function.atoms.free(atom_id);
        function.memory.free(atom.Atom, global_var_names);
    }
    if (fd.global_vars.len == 0) return;
    function.global_var_names = try function.memory.alloc(atom.Atom, fd.global_vars.len);
    for (fd.global_vars, 0..) |gv, idx| {
        function.global_var_names[idx] = fd.atoms.dup(gv.var_name);
    }
}

fn installChildFunctionBytecodes(fd: *function_def_mod.FunctionDef, rt: anytype) FinalizeError!void {
    for (fd.child_list) |*child| {
        const cpool_idx = child.parent_cpool_idx;
        if (cpool_idx < 0 or @as(usize, @intCast(cpool_idx)) >= fd.cpool.len) {
            return error.InvalidBytecode;
        }
        const fb_slice = try createFunctionBytecode(child, rt);
        const fb = &fb_slice[0];
        const value = JSValue.functionBytecode(&fb.header);
        const idx: usize = @intCast(cpool_idx);
        const old_value = fd.cpool[idx];
        fd.cpool[idx] = value;
        old_value.free(rt);
    }

    for (fd.child_list) |*child| {
        if (child.class_fields_init_cpool_idx < 0) continue;
        if (child.parent_cpool_idx < 0 or
            @as(usize, @intCast(child.parent_cpool_idx)) >= fd.cpool.len or
            @as(usize, @intCast(child.class_fields_init_cpool_idx)) >= fd.cpool.len)
        {
            return error.InvalidBytecode;
        }
        const ctor_value = fd.cpool[@intCast(child.parent_cpool_idx)];
        const init_value = fd.cpool[@intCast(child.class_fields_init_cpool_idx)];
        const ctor_fb = functionBytecodeFromValueMutable(ctor_value) orelse return error.InvalidBytecode;
        const next_value = init_value.dup();
        const old_value = ctor_fb.class_fields_init;
        ctor_fb.class_fields_init = next_value;
        if (old_value) |stored| stored.free(rt);
    }
}

fn functionBytecodeFromValueMutable(value: JSValue) ?*bytecode_function.FunctionBytecode {
    const header = value.objectHeader() orelse return null;
    if (header.kind != .function_bytecode) return null;
    return @fieldParentPtr("header", header);
}

fn syncFunctionDefCpool(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
    if (fd.cpool.len == 0) return;
    if (function.constants.values.len != 0) return error.InvalidBytecode;
    for (fd.cpool) |value| {
        _ = try function.addConstant(value);
    }
}
