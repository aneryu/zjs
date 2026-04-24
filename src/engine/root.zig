pub const source = @import("source.zig");
pub const status = @import("status.zig");

pub const core = @import("core/root.zig");
pub const frontend = @import("frontend/root.zig");
pub const bytecode = @import("bytecode/root.zig");
pub const exec = @import("exec/root.zig");
pub const builtins = @import("builtins/root.zig");
pub const libs = @import("libs/root.zig");

pub const SourceMapping = source.SourceMapping;
pub const ReferenceFile = source.ReferenceFile;
pub const ReferenceRole = source.ReferenceRole;
pub const PortState = status.PortState;
pub const Subsystem = status.Subsystem;
pub const SubsystemStatus = status.SubsystemStatus;

test {
    _ = source;
    _ = status;
    _ = core;
    _ = frontend;
    _ = bytecode;
    _ = exec;
    _ = builtins;
    _ = libs;
}
