const memory = @import("memory.zig");
const atom = @import("atom.zig");
const Value = @import("value.zig").Value;

pub const default_stack_size = 1024 * 1024;

pub const Runtime = struct {
    memory: memory.MemoryAccount,
    atoms: atom.AtomTable,
    current_exception: Value = Value.uninitialized(),
    stack_size: usize = default_stack_size,
    interrupt_handler: ?*const fn (*Runtime) bool = null,
    random_state: u64 = 0x1234_5678_9abc_def0,

    /// Returns an owned runtime. Caller must release it with `destroy`.
    pub fn create(allocator: std.mem.Allocator) !*Runtime {
        var account = memory.MemoryAccount.init(allocator);
        const rt = try account.create(Runtime);
        rt.memory = account;
        rt.atoms = atom.AtomTable.init(&rt.memory);
        rt.current_exception = Value.uninitialized();
        rt.stack_size = default_stack_size;
        rt.interrupt_handler = null;
        rt.random_state = 0x1234_5678_9abc_def0;
        return rt;
    }

    pub fn destroy(self: *Runtime) void {
        self.current_exception.free(self);
        self.atoms.deinit();
        std.debug.assert(!self.memory.hasOutstandingAllocations() or self.memory.allocation_count == 1);

        var account = self.memory;
        account.destroy(Runtime, self);
        std.debug.assert(!account.hasOutstandingAllocations());
    }

    pub fn setStackSize(self: *Runtime, size: usize) void {
        self.stack_size = size;
    }

    pub fn stackSize(self: Runtime) usize {
        return self.stack_size;
    }

    pub fn internAtom(self: *Runtime, bytes: []const u8) !atom.Atom {
        return self.atoms.internString(bytes);
    }
};

const std = @import("std");
