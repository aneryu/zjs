//! Regenerates src/abi/fun_native_abi.h from the FNABI schema.
//! Run from the repo root:  zig run src/abi/gen_header.zig
//! The header text itself is built at comptime in fun_native_abi.zig;
//! src/tests/abi_layout.zig fails if the checked-in file goes stale.

const std = @import("std");
const abi = @import("fun_native_abi.zig");

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "src/abi/fun_native_abi.h",
        .data = abi.c_header_text,
    });
    std.debug.print("wrote src/abi/fun_native_abi.h ({d} bytes)\n", .{abi.c_header_text.len});
}
