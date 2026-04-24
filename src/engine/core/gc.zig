const string = @import("string.zig");

pub const RefKind = enum {
    string,
};

pub const Header = struct {
    kind: RefKind,
    ref_count: usize = 1,
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
    }
}

const std = @import("std");
