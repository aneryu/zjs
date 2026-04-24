const jobs = @import("../exec/jobs.zig");

pub fn enqueueReaction(queue: *jobs.Queue, job: jobs.Job) !void {
    try queue.enqueue(job);
}
