pub const RefKind = enum {
    string,
    object,
    big_int,
};

pub const ObjectKind = enum {
    object,
    function_bytecode,
    module,
    shape,
    string,
};

pub const ObjectDestroyFn = *const fn (header: *ObjectHeader, destroy_ctx: *anyopaque) void;

pub const Phase = enum {
    none,
    decref,
    remove_cycles,
};

pub const Header = struct {
    kind: RefKind,
    ref_count: usize = 1,
};

pub const ObjectHeader = struct {
    kind: ObjectKind,
    ref_count: usize = 1,
    marked: bool = false,
    in_zero_ref: bool = false,
    destroy_fn: ?ObjectDestroyFn = null,
    destroy_ctx: ?*anyopaque = null,

    pub fn retain(self: *ObjectHeader) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count += 1;
        self.in_zero_ref = false;
    }
};

pub const Registry = struct {
    memory: *memory.MemoryAccount,
    objects: []*ObjectHeader = &.{},
    objects_capacity: usize = 0,
    zero_ref: []*ObjectHeader = &.{},
    zero_ref_capacity: usize = 0,
    phase: Phase = .none,

    pub fn init(account: *memory.MemoryAccount) Registry {
        return .{ .memory = account };
    }

    pub fn deinit(self: *Registry) void {
        if (self.zero_ref_capacity != 0) self.memory.free(*ObjectHeader, self.zero_ref.ptr[0..self.zero_ref_capacity]);
        if (self.objects_capacity != 0) self.memory.free(*ObjectHeader, self.objects.ptr[0..self.objects_capacity]);
        self.zero_ref = &.{};
        self.zero_ref_capacity = 0;
        self.objects = &.{};
        self.objects_capacity = 0;
        self.phase = .none;
    }

    pub fn add(self: *Registry, header: *ObjectHeader) !void {
        header.ref_count = 1;
        header.marked = false;
        header.in_zero_ref = false;
        header.destroy_fn = null;
        header.destroy_ctx = null;
        try append(self.memory, *ObjectHeader, &self.objects, &self.objects_capacity, header);
    }

    pub fn retainObject(_: *Registry, header: *ObjectHeader) void {
        header.retain();
    }

    pub fn releaseObject(self: *Registry, header: *ObjectHeader) !bool {
        std.debug.assert(header.ref_count > 0);
        header.ref_count -= 1;
        if (header.ref_count != 0) return false;

        // Callback-owned objects (for example FunctionBytecode) are released
        // immediately. They are not placed in the zero-ref queue because the
        // registry is used only for bookkeeping; immediate release avoids
        // needing a GC graph traversal for parser-owned bytecode objects.
        if (header.destroy_fn) |destroy_fn| {
            if (header.destroy_ctx) |ctx| {
                self.remove(header);
                destroy_fn(header, ctx);
                return true;
            }
            self.remove(header);
            return true;
        }

        if (!header.in_zero_ref) {
            try append(self.memory, *ObjectHeader, &self.zero_ref, &self.zero_ref_capacity, header);
            header.in_zero_ref = true;
        }
        return true;
    }

    pub fn remove(self: *Registry, header: *ObjectHeader) void {
        self.removeFrom(&self.zero_ref, header);
        self.removeFrom(&self.objects, header);
        header.in_zero_ref = false;
        header.marked = false;
    }

    pub fn mark(_: *Registry, header: *ObjectHeader) void {
        header.marked = true;
    }

    pub fn clearMark(_: *Registry, header: *ObjectHeader) void {
        header.marked = false;
    }

    pub const CycleRemovalStats = struct {
        scanned: usize = 0,
        zero_ref_candidates: usize = 0,
        unlinked_zero_ref: usize = 0,
    };

    pub fn runCycleRemoval(self: *Registry) CycleRemovalStats {
        self.phase = .remove_cycles;
        var stats = CycleRemovalStats{
            .scanned = self.objects.len,
            .zero_ref_candidates = self.zero_ref.len,
        };
        for (self.objects) |header| header.marked = false;
        while (self.zero_ref.len != 0) {
            const header = self.zero_ref[0];
            self.remove(header);
            stats.unlinked_zero_ref += 1;
        }
        self.phase = .none;
        return stats;
    }

    pub fn liveCount(self: Registry) usize {
        return self.objects.len;
    }

    pub fn zeroRefCount(self: Registry) usize {
        return self.zero_ref.len;
    }

    fn removeFrom(self: *Registry, list: *[]*ObjectHeader, header: *ObjectHeader) void {
        _ = self;
        var found: ?usize = null;
        for (list.*, 0..) |candidate, index| {
            if (candidate == header) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        if (index + 1 < list.*.len) {
            std.mem.copyForwards(*ObjectHeader, list.*[index .. list.*.len - 1], list.*[index + 1 ..]);
        }
        list.* = list.*[0 .. list.*.len - 1];
    }
};

pub fn retain(header: *Header) void {
    header.ref_count += 1;
}

pub fn release(rt: anytype, header: *Header) void {
    std.debug.assert(header.ref_count > 0);
    header.ref_count -= 1;
    if (header.ref_count != 0) return;

    switch (header.kind) {
        .string => string.String.destroyFromHeader(rt, header),
        .object => object.Object.destroyFromHeader(rt, header),
        .big_int => bigint.BigInt.destroyFromHeader(rt, header),
    }
}

fn append(account: *memory.MemoryAccount, comptime T: type, slice: *[]T, capacity: *usize, item: T) !void {
    if (slice.*.len == capacity.*) {
        const next_capacity = if (capacity.* == 0) 4 else capacity.* * 2;
        const next = try account.alloc(T, next_capacity);
        errdefer account.free(T, next);
        @memcpy(next[0..slice.*.len], slice.*);
        if (capacity.* != 0) account.free(T, slice.*.ptr[0..capacity.*]);
        slice.* = next[0..slice.*.len];
        capacity.* = next_capacity;
    }
    const len = slice.*.len;
    slice.* = slice.*.ptr[0 .. len + 1];
    slice.*[len] = item;
}

const memory = @import("memory.zig");
const bigint = @import("bigint.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const std = @import("std");
