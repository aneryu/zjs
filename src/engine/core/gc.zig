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

    pub fn retain(self: *ObjectHeader) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count += 1;
        self.in_zero_ref = false;
    }
};

pub const Registry = struct {
    memory: *memory.MemoryAccount,
    objects: []*ObjectHeader = &.{},
    zero_ref: []*ObjectHeader = &.{},
    phase: Phase = .none,

    pub fn init(account: *memory.MemoryAccount) Registry {
        return .{ .memory = account };
    }

    pub fn deinit(self: *Registry) void {
        if (self.zero_ref.len != 0) self.memory.free(*ObjectHeader, self.zero_ref);
        if (self.objects.len != 0) self.memory.free(*ObjectHeader, self.objects);
        self.zero_ref = &.{};
        self.objects = &.{};
        self.phase = .none;
    }

    pub fn add(self: *Registry, header: *ObjectHeader) !void {
        header.ref_count = 1;
        header.marked = false;
        header.in_zero_ref = false;
        try append(self.memory, *ObjectHeader, &self.objects, header);
    }

    pub fn retainObject(_: *Registry, header: *ObjectHeader) void {
        header.retain();
    }

    pub fn releaseObject(self: *Registry, header: *ObjectHeader) !bool {
        std.debug.assert(header.ref_count > 0);
        header.ref_count -= 1;
        if (header.ref_count != 0) return false;
        if (!header.in_zero_ref) {
            try append(self.memory, *ObjectHeader, &self.zero_ref, header);
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

    pub fn runCycleRemovalPlaceholder(self: *Registry) void {
        self.phase = .remove_cycles;
        for (self.objects) |header| header.marked = false;
        self.phase = .none;
    }

    pub fn liveCount(self: Registry) usize {
        return self.objects.len;
    }

    pub fn zeroRefCount(self: Registry) usize {
        return self.zero_ref.len;
    }

    fn removeFrom(self: *Registry, list: *[]*ObjectHeader, header: *ObjectHeader) void {
        var found: ?usize = null;
        for (list.*, 0..) |candidate, index| {
            if (candidate == header) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        if (list.*.len == 1) {
            self.memory.free(*ObjectHeader, list.*);
            list.* = &.{};
            return;
        }
        const next = self.memory.alloc(*ObjectHeader, list.*.len - 1) catch unreachable;
        @memcpy(next[0..index], list.*[0..index]);
        @memcpy(next[index..], list.*[index + 1 ..]);
        self.memory.free(*ObjectHeader, list.*);
        list.* = next;
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

fn append(account: *memory.MemoryAccount, comptime T: type, slice: *[]T, item: T) !void {
    const next = try account.alloc(T, slice.*.len + 1);
    errdefer account.free(T, next);
    @memcpy(next[0..slice.*.len], slice.*);
    next[slice.*.len] = item;
    if (slice.*.len != 0) account.free(T, slice.*);
    slice.* = next;
}

const memory = @import("memory.zig");
const bigint = @import("bigint.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const std = @import("std");
