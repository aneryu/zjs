const atom = @import("../core/atom.zig");
const memory = @import("../core/memory.zig");

pub const SourcePosition = struct {
    pc: u32,
    line: u32,
    column: u32 = 0,
};

pub const Table = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    filename: atom.Atom = atom.null_atom,
    positions: []SourcePosition = &.{},

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, filename: atom.Atom) Table {
        return .{
            .memory = account,
            .atoms = atoms,
            .filename = atoms.dup(filename),
        };
    }

    pub fn deinit(self: *Table) void {
        const filename = self.filename;
        const positions = self.positions;
        self.filename = atom.null_atom;
        self.positions = &.{};
        if (filename != atom.null_atom) self.atoms.free(filename);
        if (positions.len != 0) self.memory.free(SourcePosition, positions);
    }

    pub fn add(self: *Table, position: SourcePosition) !void {
        const old_positions = self.positions;
        const next = try self.memory.alloc(SourcePosition, self.positions.len + 1);
        errdefer self.memory.free(SourcePosition, next);
        @memcpy(next[0..old_positions.len], old_positions);
        next[old_positions.len] = position;
        self.positions = next;
        if (old_positions.len != 0) self.memory.free(SourcePosition, old_positions);
    }

    pub fn lineForPc(self: Table, pc: u32) ?u32 {
        var best: ?SourcePosition = null;
        for (self.positions) |position| {
            if (position.pc <= pc and (best == null or position.pc >= best.?.pc)) best = position;
        }
        return if (best) |position| position.line else null;
    }
};
