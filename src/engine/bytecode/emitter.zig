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
        try self.function.retainAtomOperand(atom_id);
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

    pub fn emitGetVar(self: *Emitter, atom_id: atom.Atom) !void {
        try self.emitKnownAtom(known.get_var, atom_id);
    }

    pub fn emitDefineVar(self: *Emitter, atom_id: atom.Atom) !void {
        try self.emitKnownAtom(known.define_var, atom_id);
    }

    pub fn emitNewArray(self: *Emitter, count: u32) !void {
        try self.emitKnownU32(known.new_array, count);
    }

    pub fn emitGetIndex(self: *Emitter, index: u32) !void {
        try self.emitKnownU32(known.get_index, index);
    }

    pub fn emitArrayMapMul(self: *Emitter, multiplier: u32) !void {
        try self.emitKnownU32(known.array_map_mul, multiplier);
    }

    pub fn emitNewObject(self: *Emitter, count: u32) !void {
        try self.emitKnownU32(known.new_object, count);
    }

    pub fn emitNewPromise(self: *Emitter) !void {
        try self.emitKnown(known.new_promise);
    }

    pub fn emitPromiseStatic(self: *Emitter, mode: u32) !void {
        try self.emitKnownU32(known.promise_static, mode);
    }

    pub fn emitNewRegExp(self: *Emitter) !void {
        try self.emitKnown(known.new_regexp);
    }

    pub fn emitRegExpMethod(self: *Emitter, method: u32) !void {
        try self.emitKnownU32(known.regexp_method, method);
    }

    pub fn emitThrowTypeError(self: *Emitter) !void {
        try self.emitKnown(known.throw_type_error);
    }

    pub fn emitNewClosure(self: *Emitter, encoded: u32) !void {
        try self.emitKnownU32(known.new_closure, encoded);
    }

    pub fn emitCallClosure(self: *Emitter, argc: u32) !void {
        try self.emitKnownU32(known.call_closure, argc);
    }

    pub fn emitNewNamedObject(self: *Emitter, atom_id: atom.Atom) !void {
        try self.emitKnownAtom(known.new_named_object, atom_id);
    }

    pub fn emitInstanceofNamed(self: *Emitter, atom_id: atom.Atom) !void {
        try self.emitKnownAtom(known.instanceof_named, atom_id);
    }

    pub fn emitNewObjectProps(self: *Emitter, names: []const atom.Atom) !void {
        try self.emitKnownU32(known.new_object, @intCast(names.len));
        for (names) |name| try self.emitKnownAtom(0, name);
    }

    pub fn emitGetProp(self: *Emitter, atom_id: atom.Atom) !void {
        try self.emitKnownAtom(known.get_prop, atom_id);
    }

    pub fn emitOptionalGetProp(self: *Emitter, atom_id: atom.Atom) !void {
        try self.emitKnownAtom(known.optional_get_prop, atom_id);
    }

    pub fn emitMathCall(self: *Emitter, id: u32) !void {
        try self.emitKnownU32(known.math_call, id);
    }

    pub fn emitStringFromCharCode(self: *Emitter, argc: u32) !void {
        try self.emitKnownU32(known.string_from_char_code, argc);
    }

    pub fn emitStringMethod(self: *Emitter, id: u32, argc: u32) !void {
        try self.emitKnownU32(known.string_method, (id << 8) | argc);
    }

    pub fn emitBigIntAsN(self: *Emitter, unsigned: bool) !void {
        try self.emitKnown(if (unsigned) known.bigint_as_uint_n else known.bigint_as_int_n);
    }

    pub fn emitCall(self: *Emitter, argc: u32) !void {
        var bytes: [5]u8 = undefined;
        bytes[0] = known.call;
        std.mem.writeInt(u32, bytes[1..5], argc, .little);
        try self.append(&bytes);
    }

    pub fn emitSetProp(self: *Emitter, atom_id: atom.Atom) !void {
        try self.emitKnownAtom(known.set_prop, atom_id);
    }

    pub fn emitObjectKeys(self: *Emitter) !void {
        try self.emitKnown(known.object_keys);
    }

    pub fn emitObjectValues(self: *Emitter) !void {
        try self.emitKnown(known.object_values);
    }

    pub fn emitObjectEntries(self: *Emitter) !void {
        try self.emitKnown(known.object_entries);
    }

    pub fn emitArrayJoin(self: *Emitter) !void {
        try self.emitKnown(known.array_join);
    }

    pub fn emitForInConcat(self: *Emitter, atom_id: atom.Atom) !void {
        try self.emitKnownAtom(known.for_in_concat, atom_id);
    }

    pub fn emitNewArrayBuffer(self: *Emitter) !void {
        try self.emitKnown(known.new_array_buffer);
    }

    pub fn emitNewTypedArray(self: *Emitter, element_size: u32) !void {
        try self.emitKnownU32(known.new_typed_array, element_size);
    }

    pub fn emitNewDataView(self: *Emitter) !void {
        try self.emitKnown(known.new_dataview);
    }

    pub fn emitArrayBufferSlice(self: *Emitter) !void {
        try self.emitKnown(known.arraybuffer_slice);
    }

    pub fn emitDataViewGet(self: *Emitter, kind: u32) !void {
        try self.emitKnownU32(known.dataview_get, kind);
    }

    pub fn emitDataViewSet(self: *Emitter) !void {
        try self.emitKnown(known.dataview_set);
    }

    pub fn emitNewCollection(self: *Emitter, kind: u32) !void {
        try self.emitKnownU32(known.new_collection, kind);
    }

    pub fn emitCollectionMethod(self: *Emitter, method: u32) !void {
        try self.emitKnownU32(known.collection_method, method);
    }

    pub fn emitUriCall(self: *Emitter, mode: u32) !void {
        try self.emitKnownU32(known.uri_call, mode);
    }

    pub fn emitArrayMethod(self: *Emitter, method: u32) !void {
        try self.emitKnownU32(known.array_method, method);
    }

    pub fn emitParseInt(self: *Emitter, argc: u32) !void {
        try self.emitKnownU32(known.parse_int, argc);
    }

    pub fn emitParseFloat(self: *Emitter) !void {
        try self.emitKnown(known.parse_float);
    }

    pub fn emitNewDate(self: *Emitter, argc: u32) !void {
        try self.emitKnownU32(known.new_date, argc);
    }

    pub fn emitDateCall(self: *Emitter, argc: u32) !void {
        try self.emitKnownU32(known.date_call, argc);
    }

    pub fn emitDateStatic(self: *Emitter, encoded: u32) !void {
        try self.emitKnownU32(known.date_static, encoded);
    }

    pub fn emitDateMethod(self: *Emitter, encoded: u32) !void {
        try self.emitKnownU32(known.date_method, encoded);
    }

    pub fn emitThrowTest262Error(self: *Emitter) !void {
        try self.emitKnown(known.throw_test262_error);
    }

    pub fn emitThrowEvalError(self: *Emitter) !void {
        try self.emitKnown(known.throw_eval_error);
    }

    pub fn emitThrowReferenceError(self: *Emitter) !void {
        try self.emitKnown(known.throw_reference_error);
    }

    pub fn emitThrowSyntaxError(self: *Emitter) !void {
        try self.emitKnown(known.throw_syntax_error);
    }

    pub fn emitThrowRangeError(self: *Emitter) !void {
        try self.emitKnown(known.throw_range_error);
    }

    pub fn emitAssertSameValue(self: *Emitter) !void {
        try self.emitKnown(known.assert_same_value);
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
    pub const array_method: u8 = 169;
    pub const call: u8 = 170;
    pub const set_prop: u8 = 171;
    pub const object_keys: u8 = 172;
    pub const object_values: u8 = 173;
    pub const object_entries: u8 = 174;
    pub const array_join: u8 = 175;
    pub const for_in_concat: u8 = 176;
    pub const new_array_buffer: u8 = 177;
    pub const new_typed_array: u8 = 179;
    pub const new_dataview: u8 = 180;
    pub const arraybuffer_slice: u8 = 181;
    pub const dataview_get: u8 = 182;
    pub const dataview_set: u8 = 183;
    pub const new_collection: u8 = 184;
    pub const collection_method: u8 = 185;
    pub const uri_call: u8 = 186;
    pub const promise_static: u8 = 189;
    pub const new_regexp: u8 = 190;
    pub const regexp_method: u8 = 191;
    pub const new_closure: u8 = 166;
    pub const call_closure: u8 = 167;
    pub const throw_test262_error: u8 = 164;
    pub const throw_eval_error: u8 = 165;
    pub const throw_reference_error: u8 = 159;
    pub const parse_int: u8 = 187;
    pub const parse_float: u8 = 188;
    pub const new_date: u8 = 160;
    pub const date_call: u8 = 161;
    pub const date_static: u8 = 162;
    pub const date_method: u8 = 163;
    pub const instanceof_array: u8 = 192;
    pub const new_named_object: u8 = 193;
    pub const new_promise: u8 = 194;
    pub const instanceof_named: u8 = 195;
    pub const source_loc: u8 = 196;
    pub const throw_type_error: u8 = 168;
    pub const throw_syntax_error: u8 = 156;
    pub const throw_range_error: u8 = 157;
    pub const assert_same_value: u8 = 158;
    pub const bigint_as_int_n: u8 = 155;
    pub const bigint_as_uint_n: u8 = 154;
    pub const optional_get_prop: u8 = 207;
    pub const value_to_number: u8 = 208;
    pub const value_to_boolean: u8 = 209;
    pub const value_to_string: u8 = 210;
    pub const prop_in: u8 = 211;
    pub const instanceof_object: u8 = 212;
    pub const string_from_char_code: u8 = 213;
    pub const string_method: u8 = 214;
    pub const strict_neq: u8 = 206;
    pub const eq: u8 = 232;
    pub const strict_eq: u8 = 233;
    pub const value_length: u8 = 234;
    pub const new_array: u8 = 235;
    pub const get_index: u8 = 236;
    pub const array_map_mul: u8 = 237;
    pub const factorial: u8 = 238;
    pub const get_prop: u8 = 222;
    pub const json_stringify: u8 = 223;
    pub const math_call: u8 = 215;
    pub const typeof_value: u8 = 216;
    pub const object_is: u8 = 217;
    pub const gte: u8 = 218;
    pub const string_char_at: u8 = 219;
    pub const logical_and: u8 = 220;
    pub const logical_or: u8 = 221;
    pub const json_parse: u8 = 230;
    pub const nullish_coalesce: u8 = 231;
    pub const new_object: u8 = 239;
    pub const mul: u8 = 240;
    pub const div: u8 = 241;
    pub const mod: u8 = 242;
    pub const add: u8 = 243;
    pub const sub: u8 = 244;
};

const std = @import("std");
