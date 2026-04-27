const memory = @import("../core/memory.zig");

pub const Job = *const fn () void;

pub const Queue = struct {
    memory: *memory.MemoryAccount,
    jobs: []Job = &.{},
    capacity: usize = 0,

    pub fn init(account: *memory.MemoryAccount) Queue {
        return .{ .memory = account };
    }

    pub fn deinit(self: *Queue) void {
        if (self.capacity != 0) self.memory.free(Job, self.jobs.ptr[0..self.capacity]);
        self.jobs = &.{};
        self.capacity = 0;
    }

    pub fn enqueue(self: *Queue, job: Job) !void {
        if (self.jobs.len == self.capacity) {
            const next_capacity = if (self.capacity == 0) 4 else self.capacity * 2;
            const next = try self.memory.alloc(Job, next_capacity);
            errdefer self.memory.free(Job, next);
            @memcpy(next[0..self.jobs.len], self.jobs);
            if (self.capacity != 0) self.memory.free(Job, self.jobs.ptr[0..self.capacity]);
            self.jobs = next[0..self.jobs.len];
            self.capacity = next_capacity;
        }
        const len = self.jobs.len;
        self.jobs = self.jobs.ptr[0 .. len + 1];
        self.jobs[len] = job;
    }

    pub fn runAll(self: *Queue) void {
        while (self.jobs.len != 0) {
            const job = self.jobs[0];
            self.removeFirst();
            job();
        }
    }

    fn removeFirst(self: *Queue) void {
        if (self.jobs.len > 1) {
            std.mem.copyForwards(Job, self.jobs[0 .. self.jobs.len - 1], self.jobs[1..]);
        }
        self.jobs = self.jobs[0 .. self.jobs.len - 1];
    }
};

const std = @import("std");
