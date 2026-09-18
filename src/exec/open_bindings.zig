//! Cold binding-identity table for frame locals and arguments.
//!
//! The table names the unique live open cell of each captured binding. Closing
//! detaches the cell from frame storage without changing its identity.
//!
//! The acquire half (qjs get_var_ref, qjs:16997-17044) is NOT here: it is
//! inlined once each into `Frame.captureLocal` and `Frame.captureArg`
//! (exec/frame.zig) so the nested js_closure2 loop keeps a single helper
//! boundary. Keep those two bodies in step with each other.

const core = @import("../core/root.zig");

pub const Table = struct {
    cells: []?*core.VarRef = &.{},

    pub fn close(self: *Table, rt: anytype, binding_index: u16) !void {
        const index: usize = binding_index;
        if (index >= self.cells.len) return error.InvalidBytecode;
        const cell = self.cells[index] orelse return;
        self.cells[index] = null;
        cell.close(rt);
    }

    pub fn closeAll(self: *Table, rt: anytype) void {
        for (self.cells) |*entry| {
            const cell = entry.* orelse continue;
            entry.* = null;
            cell.close(rt);
        }
    }

    pub fn hasOpen(self: *const Table) bool {
        for (self.cells) |cell| if (cell != null) return true;
        return false;
    }
};
