const atom = @import("../core/atom.zig");
const Value = @import("../core/value.zig").Value;
const bytecode_function = @import("function.zig");

pub const Emitter = struct {
    function: *bytecode_function.Bytecode,

    pub fn init(function: *bytecode_function.Bytecode) Emitter {
        return .{ .function = function };
    }

    pub fn emitKnown(self: *Emitter, op_index: u8) !void {
        try self.append(&.{op_index});
    }

    pub fn emitKnownU32(self: *Emitter, op_index: u8, value: u32) !void {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_index;
        std.mem.writeInt(u32, bytes[1..5], value, .little);
        try self.append(&bytes);
    }

    pub fn emitKnownAtom(self: *Emitter, op_index: u8, atom_id: atom.Atom) !void {
        try self.emitKnownU32(op_index, atom_id);
    }

    pub fn emitPushInt32(self: *Emitter, value: i32) !void {
        var bytes: [5]u8 = undefined;
        bytes[0] = known.push_i32;
        std.mem.writeInt(i32, bytes[1..5], value, .little);
        try self.append(&bytes);
    }

    pub fn emitPushConst(self: *Emitter, value: Value) !u32 {
        const index = try self.function.addConstant(value);
        try self.emitKnownU32(known.push_const, index);
        return index;
    }

    pub fn emitSourceLoc(self: *Emitter, pc: u32, line: u32) !void {
        var bytes: [9]u8 = undefined;
        bytes[0] = known.source_loc;
        std.mem.writeInt(u32, bytes[1..5], pc, .little);
        std.mem.writeInt(u32, bytes[5..9], line, .little);
        try self.append(&bytes);
    }

    pub fn emitReturnUndefined(self: *Emitter) !void {
        try self.emitKnown(known.return_undef);
    }

    fn append(self: *Emitter, bytes: []const u8) !void {
        const old_len = self.function.code.len;
        const next = try self.function.memory.alloc(u8, old_len + bytes.len);
        errdefer self.function.memory.free(u8, next);
        @memcpy(next[0..old_len], self.function.code);
        @memcpy(next[old_len..], bytes);
        if (self.function.code.len != 0) self.function.memory.free(u8, self.function.code);
        self.function.code = next;
    }
};

pub const known = struct {
    pub const push_i32: u8 = 1;
    pub const push_const: u8 = 2;
    pub const undefined_value: u8 = 6;
    pub const null_value: u8 = 7;
    pub const push_false: u8 = 9;
    pub const push_true: u8 = 10;
    pub const return_undef: u8 = 45;
    pub const import: u8 = 59;
    pub const get_var: u8 = 61;
    pub const define_var: u8 = 66;
    pub const define_class: u8 = 91;
    pub const goto: u8 = 117;
    pub const source_loc: u8 = 196;
};

const std = @import("std");
