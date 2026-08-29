const std = @import("std");
const representation = @import("gc_representation");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.writeAll(representation.snapshot_text);
    try writer.interface.flush();
}
