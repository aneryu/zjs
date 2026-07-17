//! Cold binding-identity table for frame locals and arguments.
//!
//! The table owns one reference to every live open cell. Callers acquiring a
//! binding receive their own retained reference. Closing detaches the cell from
//! frame storage without changing its identity, then releases the table owner.

const core = @import("../core/root.zig");

pub const Flags = struct {
    is_const: bool = false,
    is_lexical: bool = false,
    is_function_name: bool = false,
};

pub const Table = struct {
    cells: []?*core.VarRef = &.{},

    /// Acquire the unique live cell for `binding_index`.
    ///
    /// The table retains the initial reference; the returned pointer is a
    /// separate caller-owned reference.
    pub fn acquire(
        self: *Table,
        rt: anytype,
        binding_index: u16,
        value_slot: *core.JSValue,
        flags: Flags,
    ) !*core.VarRef {
        const index: usize = binding_index;
        if (index >= self.cells.len) return error.InvalidBytecode;
        if (self.cells[index]) |cell| {
            if (!cell.is_open or cell.pvalue != value_slot) return error.InvalidBytecode;
            return cell.retain();
        }

        const cell = try core.VarRef.createOpen(rt, value_slot);
        cell.is_const = flags.is_const;
        cell.is_lexical = flags.is_lexical;
        cell.is_function_name = flags.is_function_name;
        self.cells[index] = cell;
        return cell.retain();
    }

    pub fn close(self: *Table, rt: anytype, binding_index: u16) !void {
        const index: usize = binding_index;
        if (index >= self.cells.len) return error.InvalidBytecode;
        const cell = self.cells[index] orelse return;
        self.cells[index] = null;
        cell.close(rt);
        cell.release(rt);
    }

    pub fn closeAll(self: *Table, rt: anytype) void {
        for (self.cells) |*entry| {
            const cell = entry.* orelse continue;
            entry.* = null;
            cell.close(rt);
            cell.release(rt);
        }
    }

    pub fn hasOpen(self: *const Table) bool {
        for (self.cells) |cell| if (cell != null) return true;
        return false;
    }
};
