//! Type-erased `std.ArrayList.append` matching Zig 0.16 unmanaged growth.
//!
//! Leftover outlined `array_list.Aligned(T).append` copies share one
//! `addOneErased` walk. Growth is `growCapacity` plus `remap` / `rawAlloc`
//! with the element's alignment — not `alloc(u8)` and not GC `TraceHeader`
//! lists. `u8` / `[]const u8` / `u64` call sites stay on std for this knife.

const std = @import("std");

const Allocator = std.mem.Allocator;

fn ListItem(comptime ListPtr: type) type {
    const List = @typeInfo(ListPtr).pointer.child;
    return @typeInfo(@FieldType(List, "items")).pointer.child;
}

/// Same contract as `std.ArrayList(T).append`: grow by one, then store `item`.
pub inline fn append(
    list: anytype,
    gpa: Allocator,
    item: ListItem(@TypeOf(list)),
) Allocator.Error!void {
    const T = ListItem(@TypeOf(list));
    comptime {
        std.debug.assert(@typeInfo(@TypeOf(list)).pointer.size == .one);
        std.debug.assert(@sizeOf(T) > 0);
    }
    const dest = try addOneErased(
        @ptrCast(&list.items.ptr),
        &list.items.len,
        &list.capacity,
        @sizeOf(T),
        .fromByteUnits(@alignOf(T)),
        gpa,
    );
    @as(*T, @ptrCast(@alignCast(dest))).* = item;
}

/// Zig 0.16 `array_list.Aligned(T).growCapacity` with a runtime element size.
pub fn growCapacity(minimum: usize, elem_size: usize) usize {
    std.debug.assert(elem_size != 0);
    const init_capacity = @max(1, std.atomic.cache_line / elem_size);
    return minimum +| (minimum / 2 + init_capacity);
}

noinline fn addOneErased(
    ptr_slot: *[*]u8,
    len_slot: *usize,
    cap_slot: *usize,
    elem_size: usize,
    alignment: std.mem.Alignment,
    gpa: Allocator,
) Allocator.Error![*]u8 {
    // std `addOne`: `items` cannot occupy the whole address space.
    const new_len = len_slot.* + 1;
    if (cap_slot.* < new_len) {
        try ensureTotalCapacityPrecise(
            ptr_slot,
            len_slot.*,
            cap_slot,
            elem_size,
            alignment,
            gpa,
            growCapacity(new_len, elem_size),
        );
    }
    const dest = ptr_slot.* + len_slot.* * elem_size;
    len_slot.* = new_len;
    return dest;
}

fn ensureTotalCapacityPrecise(
    ptr_slot: *[*]u8,
    used_len: usize,
    cap_slot: *usize,
    elem_size: usize,
    alignment: std.mem.Alignment,
    gpa: Allocator,
    new_capacity: usize,
) Allocator.Error!void {
    if (cap_slot.* >= new_capacity) return;

    const old_bytes_len = std.math.mul(usize, cap_slot.*, elem_size) catch return error.OutOfMemory;
    const new_bytes_len = std.math.mul(usize, new_capacity, elem_size) catch return error.OutOfMemory;
    const ret = @returnAddress();

    if (old_bytes_len != 0) {
        const old_memory = ptr_slot.*[0..old_bytes_len];
        if (gpa.rawRemap(old_memory, alignment, new_bytes_len, ret)) |new_ptr| {
            ptr_slot.* = new_ptr;
            cap_slot.* = new_capacity;
            return;
        }
        const new_ptr = gpa.rawAlloc(new_bytes_len, alignment, ret) orelse return error.OutOfMemory;
        @memset(new_ptr[0..new_bytes_len], undefined);
        const used_bytes = used_len * elem_size;
        @memcpy(new_ptr[0..used_bytes], ptr_slot.*[0..used_bytes]);
        @memset(old_memory, undefined);
        gpa.rawFree(old_memory, alignment, ret);
        ptr_slot.* = new_ptr;
        cap_slot.* = new_capacity;
        return;
    }

    const new_ptr = gpa.rawAlloc(new_bytes_len, alignment, ret) orelse return error.OutOfMemory;
    @memset(new_ptr[0..new_bytes_len], undefined);
    ptr_slot.* = new_ptr;
    cap_slot.* = new_capacity;
}
