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

pub const Engine = struct {
    runtime: *core.Runtime,
    context: *core.Context,
    job_queue: exec.jobs.Queue,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        const rt = try core.Runtime.create(allocator);
        errdefer rt.destroy();
        const ctx = try core.Context.create(rt);
        errdefer ctx.destroy();
        return .{
            .runtime = rt,
            .context = ctx,
            .job_queue = exec.jobs.Queue.init(&rt.memory),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.job_queue.deinit();
        self.context.destroy();
        self.runtime.destroy();
    }

    pub fn eval(self: *Engine, source_text: []const u8) !core.Value {
        var compiled = try frontend.parser.parse(self.runtime, source_text, .{ .mode = .script, .filename = "<eval>" });
        defer compiled.deinit();
        if (compiled.syntax_error != null) return self.context.throwValue(core.Value.undefinedValue());
        var vm_instance = exec.Vm.init(self.context);
        defer vm_instance.deinit();
        return vm_instance.run(&compiled.function);
    }

    pub fn runJobs(self: *Engine) void {
        self.job_queue.runAll();
    }

    pub fn takeException(self: *Engine) core.Value {
        return self.context.takeException();
    }
};

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

const std = @import("std");
