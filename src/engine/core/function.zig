const atom = @import("atom.zig");
const memory = @import("memory.zig");
const Value = @import("value.zig").Value;

fn dupOwnedValue(atoms: *atom.AtomTable, value: Value) Value {
    if (value.asSymbolAtom()) |atom_id| return Value.symbol(atoms.dup(atom_id));
    return value.dup();
}

fn freeOwnedValue(atoms: *atom.AtomTable, value: Value, rt: anytype) void {
    if (value.asSymbolAtom()) |atom_id| {
        atoms.free(atom_id);
        return;
    }
    value.free(rt);
}

pub const NativeBuiltinDomain = enum(i32) {
    math = 1,
    number = 2,
    string = 3,
    date = 4,
    array = 5,
    regexp = 6,
    collection = 7,
    buffer = 8,
    uri = 9,
    performance = 10,
    json = 11,
    atomics = 12,
    reflect = 13,
    object = 14,
    primitive = 15,
    function = 16,
    error_object = 17,
    iterator = 18,
};

pub const NativeBuiltinRef = struct {
    domain: NativeBuiltinDomain,
    id: u32,
};

const native_builtin_domain_stride: i32 = 1024;

pub fn nativeBuiltinId(domain: NativeBuiltinDomain, id: u32) i32 {
    return @intFromEnum(domain) * native_builtin_domain_stride + @as(i32, @intCast(id));
}

pub fn decodeNativeBuiltinId(encoded: i32) ?NativeBuiltinRef {
    if (encoded <= 0) return null;
    const domain_code = @divTrunc(encoded, native_builtin_domain_stride);
    const local_id = @mod(encoded, native_builtin_domain_stride);
    if (local_id <= 0) return null;
    const domain: NativeBuiltinDomain = switch (domain_code) {
        1 => .math,
        2 => .number,
        3 => .string,
        4 => .date,
        5 => .array,
        6 => .regexp,
        7 => .collection,
        8 => .buffer,
        9 => .uri,
        10 => .performance,
        11 => .json,
        12 => .atomics,
        13 => .reflect,
        14 => .object,
        15 => .primitive,
        16 => .function,
        17 => .error_object,
        18 => .iterator,
        else => return null,
    };
    return .{ .domain = domain, .id = @intCast(local_id) };
}

pub const Kind = enum {
    native,
    bytecode,
    bound,
};

pub const FunctionKind = enum {
    normal,
    generator,
    async_function,
    async_generator,
};

pub const NativeCall = *const fn () Value;

pub const NativeRecord = struct {
    name: atom.Atom = atom.null_atom,
    length: u16 = 0,
    call: ?NativeCall = null,
};

pub const BytecodeRecord = struct {
    name: atom.Atom = atom.null_atom,
    bytecode: []u8 = &.{},
    constants: []Value = &.{},
};

pub const BoundRecord = struct {
    target: Value = Value.undefinedValue(),
    this_value: Value = Value.undefinedValue(),
    args: []Value = &.{},
};

pub const FunctionRecord = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    kind: Kind,
    function_kind: FunctionKind = .normal,
    is_constructor: bool = false,
    home_object: Value = Value.undefinedValue(),
    payload: Payload,

    const Payload = union(Kind) {
        native: NativeRecord,
        bytecode: BytecodeRecord,
        bound: BoundRecord,
    };

    pub fn createNative(
        account: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        name: atom.Atom,
        length: u16,
        call: ?NativeCall,
        is_constructor: bool,
    ) FunctionRecord {
        return .{
            .memory = account,
            .atoms = atoms,
            .kind = .native,
            .is_constructor = is_constructor,
            .payload = .{ .native = .{
                .name = atoms.dup(name),
                .length = length,
                .call = call,
            } },
        };
    }

    pub fn createBytecode(
        account: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        name: atom.Atom,
        bytecode: []const u8,
        constants: []const Value,
        function_kind: FunctionKind,
        is_constructor: bool,
        home_object: Value,
    ) !FunctionRecord {
        const owned_code: []u8 = if (bytecode.len == 0)
            &.{}
        else blk: {
            const owned = try account.alloc(u8, bytecode.len);
            @memcpy(owned, bytecode);
            break :blk owned;
        };
        var owned_code_owned = owned_code.len != 0;
        errdefer if (owned_code_owned) account.free(u8, owned_code);

        const owned_constants: []Value = if (constants.len == 0)
            &.{}
        else blk: {
            const owned = try account.alloc(Value, constants.len);
            errdefer account.free(Value, owned);
            for (constants, owned) |constant, *slot| slot.* = dupOwnedValue(atoms, constant);
            break :blk owned;
        };

        owned_code_owned = false;
        return .{
            .memory = account,
            .atoms = atoms,
            .kind = .bytecode,
            .function_kind = function_kind,
            .is_constructor = is_constructor,
            .home_object = dupOwnedValue(atoms, home_object),
            .payload = .{ .bytecode = .{
                .name = atoms.dup(name),
                .bytecode = owned_code,
                .constants = owned_constants,
            } },
        };
    }

    pub fn createBound(
        account: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        target: Value,
        this_value: Value,
        args: []const Value,
        is_constructor: bool,
    ) !FunctionRecord {
        const owned_args: []Value = if (args.len == 0)
            &.{}
        else blk: {
            const owned = try account.alloc(Value, args.len);
            errdefer account.free(Value, owned);
            for (args, owned) |arg, *slot| slot.* = dupOwnedValue(atoms, arg);
            break :blk owned;
        };

        return .{
            .memory = account,
            .atoms = atoms,
            .kind = .bound,
            .is_constructor = is_constructor,
            .payload = .{ .bound = .{
                .target = dupOwnedValue(atoms, target),
                .this_value = dupOwnedValue(atoms, this_value),
                .args = owned_args,
            } },
        };
    }

    pub fn destroy(self: *FunctionRecord, rt: anytype) void {
        const account = self.memory;
        const atoms = self.atoms;
        const home_object = self.home_object;
        const payload = self.payload;
        self.* = .{
            .memory = account,
            .atoms = atoms,
            .kind = .native,
            .payload = .{ .native = .{} },
        };

        freeOwnedValue(atoms, home_object, rt);
        switch (payload) {
            .native => |record| {
                if (record.name != atom.null_atom) atoms.free(record.name);
            },
            .bytecode => |record| {
                if (record.name != atom.null_atom) atoms.free(record.name);
                for (record.constants) |*constant| {
                    const value = constant.*;
                    constant.* = Value.undefinedValue();
                    freeOwnedValue(atoms, value, rt);
                }
                if (record.constants.len != 0) account.free(Value, record.constants);
                if (record.bytecode.len != 0) account.free(u8, record.bytecode);
            },
            .bound => |record| {
                freeOwnedValue(atoms, record.target, rt);
                freeOwnedValue(atoms, record.this_value, rt);
                for (record.args) |*arg| {
                    const value = arg.*;
                    arg.* = Value.undefinedValue();
                    freeOwnedValue(atoms, value, rt);
                }
                if (record.args.len != 0) account.free(Value, record.args);
            },
        }
    }
};
