const atom = @import("atom.zig");
const memory = @import("memory.zig");
const Value = @import("value.zig").Value;

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
        const owned_code = try account.alloc(u8, bytecode.len);
        errdefer account.free(u8, owned_code);
        @memcpy(owned_code, bytecode);

        const owned_constants = try account.alloc(Value, constants.len);
        errdefer account.free(Value, owned_constants);
        for (constants, owned_constants) |constant, *slot| slot.* = constant.dup();

        return .{
            .memory = account,
            .atoms = atoms,
            .kind = .bytecode,
            .function_kind = function_kind,
            .is_constructor = is_constructor,
            .home_object = home_object.dup(),
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
        const owned_args = try account.alloc(Value, args.len);
        errdefer account.free(Value, owned_args);
        for (args, owned_args) |arg, *slot| slot.* = arg.dup();

        return .{
            .memory = account,
            .atoms = atoms,
            .kind = .bound,
            .is_constructor = is_constructor,
            .payload = .{ .bound = .{
                .target = target.dup(),
                .this_value = this_value.dup(),
                .args = owned_args,
            } },
        };
    }

    pub fn destroy(self: *FunctionRecord, rt: anytype) void {
        self.home_object.free(rt);
        switch (self.payload) {
            .native => |record| {
                if (record.name != atom.null_atom) self.atoms.free(record.name);
            },
            .bytecode => |record| {
                if (record.name != atom.null_atom) self.atoms.free(record.name);
                for (record.constants) |constant| constant.free(rt);
                if (record.constants.len != 0) self.memory.free(Value, record.constants);
                if (record.bytecode.len != 0) self.memory.free(u8, record.bytecode);
            },
            .bound => |record| {
                record.target.free(rt);
                record.this_value.free(rt);
                for (record.args) |arg| arg.free(rt);
                if (record.args.len != 0) self.memory.free(Value, record.args);
            },
        }
        self.* = .{
            .memory = self.memory,
            .atoms = self.atoms,
            .kind = .native,
            .payload = .{ .native = .{} },
        };
    }
};
