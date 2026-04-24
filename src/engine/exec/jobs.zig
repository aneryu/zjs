const memory = @import("../core/memory.zig");

pub const Job = *const fn () void;

pub const Queue = struct {
    memory: *memory.MemoryAccount,
    jobs: []Job = &.{},

    pub fn init(account: *memory.MemoryAccount) Queue {
        return .{ .memory = account };
    }

    pub fn deinit(self: *Queue) void {
        if (self.jobs.len != 0) self.memory.free(Job, self.jobs);
        self.jobs = &.{};
    }

    pub fn enqueue(self: *Queue, job: Job) !void {
        const next = try self.memory.alloc(Job, self.jobs.len + 1);
        errdefer self.memory.free(Job, next);
        @memcpy(next[0..self.jobs.len], self.jobs);
        next[self.jobs.len] = job;
        if (self.jobs.len != 0) self.memory.free(Job, self.jobs);
        self.jobs = next;
    }

    pub fn runAll(self: *Queue) void {
        while (self.jobs.len != 0) {
            const job = self.jobs[0];
            self.removeFirst();
            job();
        }
    }

    fn removeFirst(self: *Queue) void {
        if (self.jobs.len == 1) {
            self.memory.free(Job, self.jobs);
            self.jobs = &.{};
            return;
        }
        const next = self.memory.alloc(Job, self.jobs.len - 1) catch unreachable;
        @memcpy(next, self.jobs[1..]);
        self.memory.free(Job, self.jobs);
        self.jobs = next;
    }
};
