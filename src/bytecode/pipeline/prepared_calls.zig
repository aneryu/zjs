const std = @import("std");

const atom = @import("../../core/atom.zig");
const bytecode_function = @import("../function.zig");
const opcode = @import("../opcode.zig");

const atom_date = atom.predefinedId("Date", .string).?;
const atom_math = atom.predefinedId("Math", .string).?;
const atom_number = atom.predefinedId("Number", .string).?;
const atom_string = atom.predefinedId("String", .string).?;

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
    BytecodeOverflow,
};

const no_site: usize = std.math.maxInt(usize);

fn instrSize(op_id: u8) usize {
    const total = opcode.sizeOf(op_id);
    return if (total == 0) 1 else total;
}

fn hasAtomOperand(op_id: u8) bool {
    const fmt = opcode.formatOf(op_id);
    return fmt == .atom or fmt == .atom_u8 or fmt == .atom_u16 or
        fmt == .atom_label_u8 or fmt == .atom_label_u16;
}

fn validDirectCallSite(function: *const bytecode_function.Bytecode, site: bytecode_function.DirectCallSite) bool {
    if (site.kind != .prop_atom) return false;
    const prepare_pc: usize = site.prepare_pc;
    const call_pc: usize = site.call_pc;
    if (prepare_pc + 5 > function.code.len or call_pc + 3 > function.code.len) return false;
    if (function.code[prepare_pc] != opcode.op.get_field2) return false;
    if (function.code[call_pc] != opcode.op.call_method) return false;
    const encoded_atom = std.mem.readInt(u32, function.code[prepare_pc + 1 ..][0..4], .little);
    if (encoded_atom != site.atom_id) return false;
    const encoded_argc = std.mem.readInt(u16, function.code[call_pc + 1 ..][0..2], .little);
    return encoded_argc == site.argc;
}

const LocalGet = struct {
    idx: u16,
    next_pc: usize,
};

const Latin1PrefixIntLocalKey = struct {
    idx: u16,
    next_pc: usize,
};

const StringLiteralRef = struct {
    next_pc: usize,
};

fn receiverIsGlobalAtom(function: *const bytecode_function.Bytecode, site: bytecode_function.DirectCallSite, expected_atom: atom.Atom) bool {
    if (site.prepare_pc < 5) return false;
    const receiver_pc: usize = site.prepare_pc - 5;
    if (receiver_pc + 5 > function.code.len) return false;

    const receiver_op = function.code[receiver_pc];
    if (receiver_op != opcode.op.get_var and receiver_op != opcode.op.get_var_undef) return false;
    const receiver_atom = std.mem.readInt(u32, function.code[receiver_pc + 1 ..][0..4], .little);
    return receiver_atom == expected_atom;
}

fn decodeLocalGet(code: []const u8, pc: usize) ?LocalGet {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        opcode.op.get_loc0 => .{ .idx = 0, .next_pc = pc + 1 },
        opcode.op.get_loc1 => .{ .idx = 1, .next_pc = pc + 1 },
        opcode.op.get_loc2 => .{ .idx = 2, .next_pc = pc + 1 },
        opcode.op.get_loc3 => .{ .idx = 3, .next_pc = pc + 1 },
        opcode.op.get_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .idx = code[pc + 1], .next_pc = pc + 2 };
        },
        opcode.op.get_loc, opcode.op.get_loc_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{
                .idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little),
                .next_pc = pc + 3,
            };
        },
        else => null,
    };
}

fn immediateInt32NextPc(code: []const u8, pc: usize) ?usize {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        opcode.op.push_minus1,
        opcode.op.push_0,
        opcode.op.push_1,
        opcode.op.push_2,
        opcode.op.push_3,
        opcode.op.push_4,
        opcode.op.push_5,
        opcode.op.push_6,
        opcode.op.push_7,
        => pc + 1,
        opcode.op.push_i8 => if (pc + 2 <= code.len) pc + 2 else null,
        opcode.op.push_i16 => if (pc + 3 <= code.len) pc + 3 else null,
        opcode.op.push_i32 => if (pc + 5 <= code.len) pc + 5 else null,
        else => null,
    };
}

fn decodeStringLiteralRef(code: []const u8, pc: usize) ?StringLiteralRef {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        opcode.op.push_atom_value => if (pc + 5 <= code.len) .{ .next_pc = pc + 5 } else null,
        opcode.op.push_empty_string => .{ .next_pc = pc + 1 },
        else => null,
    };
}

fn simpleCallArgNextPc(code: []const u8, pc: usize) ?usize {
    if (decodeLocalGet(code, pc)) |get| return get.next_pc;
    if (immediateInt32NextPc(code, pc)) |next_pc| return next_pc;
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        opcode.op.get_var, opcode.op.get_var_undef => if (pc + 5 <= code.len) pc + 5 else null,
        opcode.op.get_var_ref, opcode.op.get_var_ref_check => if (pc + 3 <= code.len) pc + 3 else null,
        opcode.op.get_var_ref0,
        opcode.op.get_var_ref1,
        opcode.op.get_var_ref2,
        opcode.op.get_var_ref3,
        => pc + 1,
        else => null,
    };
}

fn decodeLatin1PrefixIntLocalKey(code: []const u8, pc: usize) ?Latin1PrefixIntLocalKey {
    if (pc + 5 > code.len or code[pc] != opcode.op.push_atom_value) return null;
    const index_get = decodeLocalGet(code, pc + 5) orelse return null;
    if (index_get.next_pc >= code.len or code[index_get.next_pc] != opcode.op.add) return null;
    return .{
        .idx = index_get.idx,
        .next_pc = index_get.next_pc + 1,
    };
}

fn preservesExistingStaticFuse(function: *const bytecode_function.Bytecode, site: bytecode_function.DirectCallSite, method_name: []const u8) bool {
    if (receiverIsGlobalAtom(function, site, atom_number)) {
        return std.mem.eql(u8, method_name, "parseInt") or
            std.mem.eql(u8, method_name, "parseFloat");
    }
    if (receiverIsGlobalAtom(function, site, atom_math)) {
        return std.mem.eql(u8, method_name, "min") or
            std.mem.eql(u8, method_name, "max");
    }
    if (receiverIsGlobalAtom(function, site, atom_string)) {
        return std.mem.eql(u8, method_name, "fromCharCode");
    }
    if (receiverIsGlobalAtom(function, site, atom_date)) {
        return std.mem.eql(u8, method_name, "now");
    }
    return false;
}

fn preservesExistingMapPrefixRangeFuse(function: *const bytecode_function.Bytecode, site: bytecode_function.DirectCallSite, method_name: []const u8) bool {
    const args_pc = site.prepare_pc + 5;
    const key = decodeLatin1PrefixIntLocalKey(function.code, args_pc) orelse return false;
    if (std.mem.eql(u8, method_name, "get")) {
        return site.argc == 1 and key.next_pc == site.call_pc;
    }
    if (std.mem.eql(u8, method_name, "set")) {
        if (site.argc != 2) return false;
        const value_get = decodeLocalGet(function.code, key.next_pc) orelse return false;
        return value_get.idx == key.idx and value_get.next_pc == site.call_pc;
    }
    return false;
}

fn preservesExistingArrayMethodFuse(function: *const bytecode_function.Bytecode, site: bytecode_function.DirectCallSite, method_name: []const u8) bool {
    const args_pc = site.prepare_pc + 5;
    if (std.mem.eql(u8, method_name, "map")) {
        if (site.argc != 1 or args_pc >= function.code.len) return false;
        const next_pc: usize = switch (function.code[args_pc]) {
            opcode.op.fclosure8 => if (args_pc + 2 <= function.code.len) args_pc + 2 else return false,
            opcode.op.fclosure => if (args_pc + 5 <= function.code.len) args_pc + 5 else return false,
            else => return false,
        };
        return next_pc == site.call_pc;
    }
    if (std.mem.eql(u8, method_name, "push")) {
        if (site.argc != 1) return false;
        const next_pc = simpleCallArgNextPc(function.code, args_pc) orelse return false;
        return next_pc == site.call_pc;
    }
    return false;
}

fn preservesExistingStringSliceFuse(function: *const bytecode_function.Bytecode, site: bytecode_function.DirectCallSite, method_name: []const u8) bool {
    if (!std.mem.eql(u8, method_name, "slice") or site.argc != 1) return false;
    const next_pc = immediateInt32NextPc(function.code, site.prepare_pc + 5) orelse return false;
    return next_pc == site.call_pc;
}

fn receiverIsRegExpLiteral(function: *const bytecode_function.Bytecode, site: bytecode_function.DirectCallSite) bool {
    if (site.prepare_pc == 0) return false;
    const regexp_pc = @as(usize, site.prepare_pc) - 1;
    return regexp_pc < function.code.len and function.code[regexp_pc] == opcode.op.regexp;
}

fn preservesExistingRegExpFuse(function: *const bytecode_function.Bytecode, site: bytecode_function.DirectCallSite, method_name: []const u8) bool {
    if (site.argc != 1) return false;
    if (!std.mem.eql(u8, method_name, "test") and !std.mem.eql(u8, method_name, "exec")) return false;
    if (!receiverIsRegExpLiteral(function, site)) return false;
    const input_ref = decodeStringLiteralRef(function.code, site.prepare_pc + 5) orelse return false;
    return input_ref.next_pc == site.call_pc;
}

fn preservesExistingSpecializedFuse(function: *const bytecode_function.Bytecode, site: bytecode_function.DirectCallSite) bool {
    const method_name = function.atoms.name(site.atom_id) orelse return false;
    return preservesExistingStaticFuse(function, site, method_name) or
        preservesExistingMapPrefixRangeFuse(function, site, method_name) or
        preservesExistingArrayMethodFuse(function, site, method_name) or
        preservesExistingStringSliceFuse(function, site, method_name) or
        preservesExistingRegExpFuse(function, site, method_name);
}

fn suspendOpcode(op_id: u8) bool {
    return op_id == opcode.op.await or
        op_id == opcode.op.yield or
        op_id == opcode.op.yield_star or
        op_id == opcode.op.async_yield_star;
}

fn argumentEvaluationCanSuspend(function: *const bytecode_function.Bytecode, site: bytecode_function.DirectCallSite) bool {
    const begin: usize = site.prepare_pc + 5;
    const end: usize = site.call_pc;
    if (begin > end or end > function.code.len) return true;
    var pc = begin;
    while (pc < end) {
        const op_id = function.code[pc];
        if (suspendOpcode(op_id)) return true;
        const size = instrSize(op_id);
        if (size == 0 or pc + size > end) return true;
        pc += size;
    }
    return pc != end;
}

pub fn run(function: *bytecode_function.Bytecode) Error!void {
    function.deinitCallSites();
    if (function.direct_call_sites.len == 0 or function.code.len == 0) return;

    var prepare_sites = try function.memory.alloc(usize, function.code.len);
    defer function.memory.free(usize, prepare_sites);
    var call_sites = try function.memory.alloc(usize, function.code.len);
    defer function.memory.free(usize, call_sites);
    @memset(prepare_sites, no_site);
    @memset(call_sites, no_site);

    var valid_count: usize = 0;
    for (function.direct_call_sites, 0..) |site, idx| {
        if (!validDirectCallSite(function, site)) continue;
        if (argumentEvaluationCanSuspend(function, site)) continue;
        if (preservesExistingSpecializedFuse(function, site)) continue;
        const prepare_pc: usize = site.prepare_pc;
        const call_pc: usize = site.call_pc;
        if (prepare_sites[prepare_pc] != no_site or call_sites[call_pc] != no_site) continue;
        prepare_sites[prepare_pc] = idx;
        call_sites[call_pc] = idx;
        valid_count += 1;
    }
    if (valid_count == 0) return;

    var lowered_site_ids = try function.memory.alloc(usize, function.direct_call_sites.len);
    defer function.memory.free(usize, lowered_site_ids);
    @memset(lowered_site_ids, no_site);

    var output_atoms: []atom.Atom = if (function.atom_operands.len == 0)
        &.{}
    else
        try function.memory.alloc(atom.Atom, function.atom_operands.len);
    var output_atoms_owned = output_atoms.len != 0;
    var output_atom_count: usize = 0;
    errdefer {
        for (output_atoms[0..output_atom_count]) |atom_id| function.atoms.free(atom_id);
        if (output_atoms_owned) function.memory.free(atom.Atom, output_atoms);
    }

    var pc: usize = 0;
    var atom_idx: usize = 0;
    while (pc < function.code.len) {
        const op_id = function.code[pc];
        const size = instrSize(op_id);
        if (size == 0 or pc + size > function.code.len) return error.InvalidBytecode;

        const lower_prepare_idx = if (op_id == opcode.op.get_field2 and prepare_sites[pc] != no_site)
            prepare_sites[pc]
        else
            no_site;

        if (lower_prepare_idx != no_site) {
            const direct_site = function.direct_call_sites[lower_prepare_idx];
            const site_id = try function.appendCallSite(.{
                .kind = .prop_atom,
                .atom_id = direct_site.atom_id,
                .prepare_pc = @intCast(pc),
                .call_pc = direct_site.call_pc,
            });
            lowered_site_ids[lower_prepare_idx] = site_id;
            function.code[pc] = opcode.op.prepare_call_prop_atom;
            std.mem.writeInt(u32, function.code[pc + 1 ..][0..4], site_id, .little);
            if (hasAtomOperand(op_id)) {
                if (atom_idx >= function.atom_operands.len) return error.InvalidBytecode;
                atom_idx += 1;
            }
            pc += size;
            continue;
        }

        if (op_id == opcode.op.call_method and call_sites[pc] != no_site) {
            const direct_idx = call_sites[pc];
            const site_id = lowered_site_ids[direct_idx];
            if (site_id != no_site) {
                function.code[pc] = opcode.op.call_prepared;
                if (site_id < function.call_sites.len) {
                    function.call_sites[site_id].call_pc = @intCast(pc);
                }
            }
        }

        if (hasAtomOperand(op_id)) {
            if (atom_idx >= function.atom_operands.len) return error.InvalidBytecode;
            output_atoms[output_atom_count] = function.atoms.dup(function.atom_operands[atom_idx]);
            output_atom_count += 1;
            atom_idx += 1;
        }
        pc += size;
    }

    if (atom_idx > function.atom_operands.len) return error.InvalidBytecode;

    const atoms_to_install: []atom.Atom = if (output_atom_count == 0) blk: {
        if (output_atoms_owned) {
            function.memory.free(atom.Atom, output_atoms);
            output_atoms_owned = false;
        }
        break :blk &.{};
    } else if (output_atom_count < output_atoms.len) blk: {
        const trimmed = try function.memory.alloc(atom.Atom, output_atom_count);
        @memcpy(trimmed, output_atoms[0..output_atom_count]);
        if (output_atoms_owned) function.memory.free(atom.Atom, output_atoms);
        output_atoms_owned = false;
        break :blk trimmed;
    } else output_atoms;

    for (function.atom_operands) |old_atom| function.atoms.free(old_atom);
    function.installAtomOperands(atoms_to_install);
    output_atoms_owned = false;
}
