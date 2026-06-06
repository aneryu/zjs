const memory = @import("memory.zig");
const core = @import("root.zig");

pub const MaxArgs = 5;

pub const Func = *const fn (*core.JSContext, []const core.JSValue) core.JSValue;

pub const Job = struct {
    context: *core.JSContext,
    func: Func,
    argc: u3 = 0,
    argv: [MaxArgs]core.JSValue = [_]core.JSValue{core.JSValue.undefinedValue()} ** MaxArgs,
    symbol_arg_mask: u5 = 0,

    pub fn init(context: *core.JSContext, func: Func, args: []const core.JSValue) !Job {
        if (args.len > MaxArgs) return error.TooManyJobArgs;
        var job = Job{
            .context = context,
            .func = func,
            .argc = @intCast(args.len),
        };
        errdefer job.deinit();
        for (args, 0..) |arg, index| {
            job.argv[index] = arg.dup();
            if (try context.runtime.registerExternalValueSymbolRoot(arg)) {
                job.symbol_arg_mask |= @as(u5, 1) << @intCast(index);
            }
        }
        return job;
    }

    pub fn deinit(self: *Job) void {
        const argc = self.argc;
        self.argc = 0;
        var index: usize = 0;
        while (index < argc) : (index += 1) {
            const value = self.argv[index];
            self.argv[index] = core.JSValue.undefinedValue();
            if ((self.symbol_arg_mask & (@as(u5, 1) << @intCast(index))) != 0) {
                self.context.runtime.unregisterExternalValueSymbolRoot(value);
            }
            value.free(self.context.runtime);
        }
        self.symbol_arg_mask = 0;
    }

    pub fn run(self: *Job) core.JSValue {
        return self.func(self.context, self.argv[0..self.argc]);
    }

    pub fn traceRoots(self: *Job, visitor: anytype) !void {
        for (self.argv[0..self.argc]) |*arg| {
            try visitor.value(arg);
        }
    }
};

pub const Queue = struct {
    memory: *memory.MemoryAccount,
    jobs: []Job = &.{},
    capacity: usize = 0,

    pub fn init(account: *memory.MemoryAccount) Queue {
        return .{ .memory = account };
    }

    pub fn deinit(self: *Queue) void {
        const jobs = self.jobs;
        const capacity = self.capacity;
        self.jobs = &.{};
        self.capacity = 0;
        for (jobs) |*job| job.deinit();
        if (capacity != 0) self.memory.free(Job, jobs.ptr[0..capacity]);
    }

    pub fn enqueue(self: *Queue, job: Job) !void {
        if (self.jobs.len == self.capacity) {
            const next_capacity = if (self.capacity == 0) 4 else self.capacity * 2;
            const next = try self.memory.alloc(Job, next_capacity);
            errdefer self.memory.free(Job, next);
            const old_jobs = self.jobs;
            const old_capacity = self.capacity;
            @memcpy(next[0..old_jobs.len], old_jobs);
            self.jobs = next[0..old_jobs.len];
            self.capacity = next_capacity;
            if (old_capacity != 0) self.memory.free(Job, old_jobs.ptr[0..old_capacity]);
        }
        const len = self.jobs.len;
        self.jobs = self.jobs.ptr[0 .. len + 1];
        self.jobs[len] = job;
    }

    pub fn enqueueFunc(self: *Queue, context: *core.JSContext, func: Func, args: []const core.JSValue) !void {
        var job = try Job.init(context, func, args);
        errdefer job.deinit();
        try self.enqueue(job);
    }

    pub fn runAll(self: *Queue) void {
        while (self.jobs.len != 0) {
            var job = self.jobs[0];
            self.removeFirst();
            const result = job.run();
            result.free(job.context.runtime);
            job.deinit();
        }
    }

    fn removeFirst(self: *Queue) void {
        if (self.jobs.len > 1) {
            std.mem.copyForwards(Job, self.jobs[0 .. self.jobs.len - 1], self.jobs[1..]);
        }
        self.jobs = self.jobs[0 .. self.jobs.len - 1];
    }

    pub fn traceRoots(self: *Queue, visitor: anytype) !void {
        for (self.jobs) |*job| {
            try job.traceRoots(visitor);
        }
    }
};

const std = @import("std");
