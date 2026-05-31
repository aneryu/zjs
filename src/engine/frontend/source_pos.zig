const atom = @import("../core/atom.zig");
const memory = @import("../core/memory.zig");

pub const Position = struct {
    offset: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const SyntaxError = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    message: []u8,
    filename: atom.Atom = atom.null_atom,
    position: Position,

    pub fn create(account: *memory.MemoryAccount, atoms: *atom.AtomTable, filename: atom.Atom, position: Position, message: []const u8) !SyntaxError {
        const owned: []u8 = if (message.len == 0) &.{} else try account.alloc(u8, message.len);
        errdefer if (owned.len != 0) account.free(u8, owned);
        if (message.len != 0) @memcpy(owned, message);
        return .{
            .memory = account,
            .atoms = atoms,
            .message = owned,
            .filename = atoms.dup(filename),
            .position = position,
        };
    }

    pub fn deinit(self: *SyntaxError) void {
        const filename = self.filename;
        const message = self.message;
        self.filename = atom.null_atom;
        self.message = &.{};
        if (filename != atom.null_atom) self.atoms.free(filename);
        if (message.len != 0) self.memory.free(u8, message);
    }
};

pub fn advance(position: *Position, byte: u8) void {
    position.offset += 1;
    if (byte == '\n') {
        position.line += 1;
        position.column = 1;
    } else {
        position.column += 1;
    }
}
