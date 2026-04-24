const atom = @import("atom.zig");
const memory = @import("memory.zig");

comptime {
    @setEvalBranchQuota(5000);
}

pub const ClassId = u16;
pub const invalid_class_id: ClassId = 0;

pub const ids = struct {
    pub const object: ClassId = 1;
    pub const array: ClassId = 2;
    pub const error_: ClassId = 3;
    pub const number: ClassId = 4;
    pub const string: ClassId = 5;
    pub const boolean: ClassId = 6;
    pub const symbol: ClassId = 7;
    pub const arguments: ClassId = 8;
    pub const mapped_arguments: ClassId = 9;
    pub const date: ClassId = 10;
    pub const module_ns: ClassId = 11;
    pub const c_function: ClassId = 12;
    pub const bytecode_function: ClassId = 13;
    pub const bound_function: ClassId = 14;
    pub const c_function_data: ClassId = 15;
    pub const c_closure: ClassId = 16;
    pub const generator_function: ClassId = 17;
    pub const for_in_iterator: ClassId = 18;
    pub const regexp: ClassId = 19;
    pub const array_buffer: ClassId = 20;
    pub const shared_array_buffer: ClassId = 21;
    pub const uint8c_array: ClassId = 22;
    pub const int8_array: ClassId = 23;
    pub const uint8_array: ClassId = 24;
    pub const int16_array: ClassId = 25;
    pub const uint16_array: ClassId = 26;
    pub const int32_array: ClassId = 27;
    pub const uint32_array: ClassId = 28;
    pub const big_int64_array: ClassId = 29;
    pub const big_uint64_array: ClassId = 30;
    pub const float16_array: ClassId = 31;
    pub const float32_array: ClassId = 32;
    pub const float64_array: ClassId = 33;
    pub const dataview: ClassId = 34;
    pub const big_int: ClassId = 35;
    pub const map: ClassId = 36;
    pub const set: ClassId = 37;
    pub const weakmap: ClassId = 38;
    pub const weakset: ClassId = 39;
    pub const iterator: ClassId = 40;
    pub const iterator_concat: ClassId = 41;
    pub const iterator_helper: ClassId = 42;
    pub const iterator_wrap: ClassId = 43;
    pub const map_iterator: ClassId = 44;
    pub const set_iterator: ClassId = 45;
    pub const array_iterator: ClassId = 46;
    pub const string_iterator: ClassId = 47;
    pub const regexp_string_iterator: ClassId = 48;
    pub const generator: ClassId = 49;
    pub const proxy: ClassId = 50;
    pub const promise: ClassId = 51;
    pub const promise_resolve_function: ClassId = 52;
    pub const promise_reject_function: ClassId = 53;
    pub const async_function: ClassId = 54;
    pub const async_function_resolve: ClassId = 55;
    pub const async_function_reject: ClassId = 56;
    pub const async_from_sync_iterator: ClassId = 57;
    pub const async_generator_function: ClassId = 58;
    pub const async_generator: ClassId = 59;
    pub const weak_ref: ClassId = 60;
    pub const finalization_registry: ClassId = 61;
    pub const dom_exception: ClassId = 62;
    pub const call_site: ClassId = 63;
    pub const raw_json: ClassId = 64;
    pub const init_count: ClassId = 65;
};

pub const Finalizer = *const fn () void;
pub const Mark = *const fn () void;
pub const Call = *const fn () void;

pub const Definition = struct {
    class_name: []const u8,
    finalizer: ?Finalizer = null,
    mark: ?Mark = null,
    call: ?Call = null,
    has_exotic: bool = false,
};

pub const Record = struct {
    id: ClassId = invalid_class_id,
    class_name: atom.Atom = atom.null_atom,
    finalizer: ?Finalizer = null,
    mark: ?Mark = null,
    call: ?Call = null,
    has_exotic: bool = false,

    pub fn isRegistered(self: Record) bool {
        return self.id != invalid_class_id;
    }
};

pub const Table = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    records: []Record = &.{},
    next_dynamic_id: ClassId = ids.init_count,

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) !Table {
        var table = Table{ .memory = account, .atoms = atoms };
        errdefer table.deinit();
        try table.ensureCapacity(ids.init_count);
        for (standard_classes) |entry| {
            try table.registerAtom(entry.id, entry.name_atom, .{ .class_name = "" });
        }
        return table;
    }

    pub fn deinit(self: *Table) void {
        for (self.records) |rec| {
            if (rec.isRegistered()) self.atoms.free(rec.class_name);
        }
        if (self.records.len != 0) self.memory.free(Record, self.records);
        self.records = &.{};
    }

    pub fn newClassId(self: *Table, requested: ClassId) ClassId {
        if (requested != invalid_class_id) return requested;
        const id = self.next_dynamic_id;
        self.next_dynamic_id += 1;
        return id;
    }

    pub fn register(self: *Table, id: ClassId, def: Definition) !void {
        const name_atom = try self.atoms.internString(def.class_name);
        defer self.atoms.free(name_atom);
        try self.registerAtom(id, name_atom, def);
    }

    pub fn isRegistered(self: Table, id: ClassId) bool {
        if (id >= self.records.len) return false;
        return self.records[id].isRegistered();
    }

    pub fn className(self: *Table, id: ClassId) ?atom.Atom {
        if (!self.isRegistered(id)) return null;
        return self.atoms.dup(self.records[id].class_name);
    }

    pub fn record(self: *const Table, id: ClassId) ?Record {
        if (id >= self.records.len) return null;
        const rec = self.records[id];
        if (!rec.isRegistered()) return null;
        return rec;
    }

    fn registerAtom(self: *Table, id: ClassId, name_atom: atom.Atom, def: Definition) !void {
        if (id == invalid_class_id or id >= std.math.maxInt(ClassId)) return error.InvalidClassId;
        try self.ensureCapacity(id + 1);
        if (self.records[id].isRegistered()) return error.DuplicateClass;
        self.records[id] = .{
            .id = id,
            .class_name = self.atoms.dup(name_atom),
            .finalizer = def.finalizer,
            .mark = def.mark,
            .call = def.call,
            .has_exotic = def.has_exotic,
        };
    }

    fn ensureCapacity(self: *Table, needed: usize) !void {
        if (needed <= self.records.len) return;
        var new_len = if (self.records.len == 0) @as(usize, ids.init_count) else self.records.len + self.records.len / 2;
        if (new_len < needed) new_len = needed;

        const next = try self.memory.alloc(Record, new_len);
        errdefer self.memory.free(Record, next);
        @memset(next, .{});
        if (self.records.len != 0) {
            @memcpy(next[0..self.records.len], self.records);
            self.memory.free(Record, self.records);
        }
        self.records = next;
    }
};

const StandardClass = struct {
    id: ClassId,
    name_atom: atom.Atom,
};

pub const standard_classes = [_]StandardClass{
    .{ .id = ids.object, .name_atom = atom.ids.Object },
    .{ .id = ids.array, .name_atom = atom.ids.Array },
    .{ .id = ids.error_, .name_atom = atom.ids.Error },
    .{ .id = ids.number, .name_atom = atom.predefinedId("Number", .string).? },
    .{ .id = ids.string, .name_atom = atom.predefinedId("String", .string).? },
    .{ .id = ids.boolean, .name_atom = atom.predefinedId("Boolean", .string).? },
    .{ .id = ids.symbol, .name_atom = atom.predefinedId("Symbol", .string).? },
    .{ .id = ids.arguments, .name_atom = atom.predefinedId("Arguments", .string).? },
    .{ .id = ids.mapped_arguments, .name_atom = atom.predefinedId("Arguments", .string).? },
    .{ .id = ids.date, .name_atom = atom.predefinedId("Date", .string).? },
    .{ .id = ids.module_ns, .name_atom = atom.ids.Object },
    .{ .id = ids.c_function, .name_atom = atom.ids.Function },
    .{ .id = ids.bytecode_function, .name_atom = atom.ids.Function },
    .{ .id = ids.bound_function, .name_atom = atom.ids.Function },
    .{ .id = ids.c_function_data, .name_atom = atom.ids.Function },
    .{ .id = ids.c_closure, .name_atom = atom.ids.Function },
    .{ .id = ids.generator_function, .name_atom = atom.predefinedId("GeneratorFunction", .string).? },
    .{ .id = ids.for_in_iterator, .name_atom = atom.predefinedId("ForInIterator", .string).? },
    .{ .id = ids.regexp, .name_atom = atom.predefinedId("RegExp", .string).? },
    .{ .id = ids.array_buffer, .name_atom = atom.predefinedId("ArrayBuffer", .string).? },
    .{ .id = ids.shared_array_buffer, .name_atom = atom.predefinedId("SharedArrayBuffer", .string).? },
    .{ .id = ids.uint8c_array, .name_atom = atom.predefinedId("Uint8ClampedArray", .string).? },
    .{ .id = ids.int8_array, .name_atom = atom.predefinedId("Int8Array", .string).? },
    .{ .id = ids.uint8_array, .name_atom = atom.predefinedId("Uint8Array", .string).? },
    .{ .id = ids.int16_array, .name_atom = atom.predefinedId("Int16Array", .string).? },
    .{ .id = ids.uint16_array, .name_atom = atom.predefinedId("Uint16Array", .string).? },
    .{ .id = ids.int32_array, .name_atom = atom.predefinedId("Int32Array", .string).? },
    .{ .id = ids.uint32_array, .name_atom = atom.predefinedId("Uint32Array", .string).? },
    .{ .id = ids.big_int64_array, .name_atom = atom.predefinedId("BigInt64Array", .string).? },
    .{ .id = ids.big_uint64_array, .name_atom = atom.predefinedId("BigUint64Array", .string).? },
    .{ .id = ids.float16_array, .name_atom = atom.predefinedId("Float16Array", .string).? },
    .{ .id = ids.float32_array, .name_atom = atom.predefinedId("Float32Array", .string).? },
    .{ .id = ids.float64_array, .name_atom = atom.predefinedId("Float64Array", .string).? },
    .{ .id = ids.dataview, .name_atom = atom.predefinedId("DataView", .string).? },
    .{ .id = ids.big_int, .name_atom = atom.predefinedId("BigInt", .string).? },
    .{ .id = ids.map, .name_atom = atom.ids.Map },
    .{ .id = ids.set, .name_atom = atom.ids.Set },
    .{ .id = ids.weakmap, .name_atom = atom.ids.WeakMap },
    .{ .id = ids.weakset, .name_atom = atom.ids.WeakSet },
    .{ .id = ids.iterator, .name_atom = atom.predefinedId("Iterator", .string).? },
    .{ .id = ids.iterator_concat, .name_atom = atom.predefinedId("Iterator Concat", .string).? },
    .{ .id = ids.iterator_helper, .name_atom = atom.predefinedId("Iterator Helper", .string).? },
    .{ .id = ids.iterator_wrap, .name_atom = atom.predefinedId("Iterator Wrap", .string).? },
    .{ .id = ids.map_iterator, .name_atom = atom.predefinedId("Map Iterator", .string).? },
    .{ .id = ids.set_iterator, .name_atom = atom.predefinedId("Set Iterator", .string).? },
    .{ .id = ids.array_iterator, .name_atom = atom.predefinedId("Array Iterator", .string).? },
    .{ .id = ids.string_iterator, .name_atom = atom.predefinedId("String Iterator", .string).? },
    .{ .id = ids.regexp_string_iterator, .name_atom = atom.predefinedId("RegExp String Iterator", .string).? },
    .{ .id = ids.generator, .name_atom = atom.predefinedId("Generator", .string).? },
};

const std = @import("std");
