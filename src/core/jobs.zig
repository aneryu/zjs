const memory = @import("memory.zig");
const core = @import("root.zig");

pub const MaxArgs = 5;

pub const Func = *const fn (*core.JSContext, []const core.JSValue) core.JSValue;

pub const RunOneStatus = enum {
    empty,
    success,
    exception,
};

pub const GenericPayload = struct {
    func: Func,
    argc: u3 = 0,
    argv: [MaxArgs]core.JSValue = [_]core.JSValue{core.JSValue.undefinedValue()} ** MaxArgs,
    symbol_arg_mask: u5 = 0,
};

pub const PromisePayload = struct {
    value: core.JSValue,
    value_symbol_rooted: bool = false,
};

pub const PromiseReactionPhase = enum {
    invoke,
    resolve,
    reject,
};

pub const PromiseReactionPayload = struct {
    reaction: core.JSValue,
    value: core.JSValue,
    rejected: bool,
    phase: PromiseReactionPhase = .invoke,
    symbol_root_mask: u2 = 0,

    /// Replace the job-owned handler input with an already-owned completion.
    /// Symbol values are refcounted, so the JSValue itself is the new root.
    pub fn replaceValueOwned(self: *PromiseReactionPayload, runtime: *core.JSRuntime, value: core.JSValue) void {
        const old = self.value;
        if ((self.symbol_root_mask & 0b10) != 0) {
            runtime.unregisterExternalValueSymbolRoot(old);
            self.symbol_root_mask &= ~@as(u2, 0b10);
        }
        self.value = value;
        old.free(runtime);
    }
};

pub const PromiseThenablePhase = enum {
    prepare,
    invoke,
    reject,
};

pub const PromiseThenablePayload = struct {
    target: core.JSValue,
    thenable: core.JSValue,
    then_function: core.JSValue,
    resolving_resolve: core.JSValue = core.JSValue.undefinedValue(),
    resolving_reject: core.JSValue = core.JSValue.undefinedValue(),
    completion: core.JSValue = core.JSValue.undefinedValue(),
    phase: PromiseThenablePhase = .prepare,
    symbol_root_mask: u6 = 0,

    /// Store the abrupt completion produced by the one permitted invocation
    /// of the thenable. Retrying the job can now resume at rejection without
    /// invoking user code twice.
    pub fn replaceCompletionOwned(self: *PromiseThenablePayload, runtime: *core.JSRuntime, value: core.JSValue) void {
        const old = self.completion;
        if ((self.symbol_root_mask & 0b100000) != 0) {
            runtime.unregisterExternalValueSymbolRoot(old);
            self.symbol_root_mask &= ~@as(u6, 0b100000);
        }
        self.completion = value;
        old.free(runtime);
    }
};

/// A Promise completion whose resolving function has already won its
/// once-guard, but whose reaction-job preparation ran out of memory.  The
/// Runtime FIFO owns both values until settlement succeeds, so callers do not
/// have to retain (or invoke) the original resolving function to make
/// progress.
pub const PromiseSettlementPayload = struct {
    target: core.JSValue,
    completion: core.JSValue,
    rejected: bool,
};

pub const DynamicImportPayload = struct {
    pub const Runner = *const fn (
        context: *core.JSContext,
        output: ?*std.Io.Writer,
        payload: *const DynamicImportPayload,
    ) core.context.DynamicImportError!core.JSValue;

    runner: Runner,
    resolve: core.JSValue,
    reject: core.JSValue,
    basename: core.JSValue,
    specifier: core.JSValue,
    attributes: core.JSValue,
    symbol_root_mask: u5 = 0,
};

/// A zjs Atomics.waitAsync host completion. The opaque waiter stays owned by
/// this typed entry until the Runtime thread successfully publishes the
/// Promise settlement or drops the queue during teardown.
pub const AtomicsWaiterPayload = struct {
    pub const Runner = *const fn (
        context: *core.JSContext,
        payload: *const AtomicsWaiterPayload,
    ) core.context.DynamicImportError!void;
    pub const Destroyer = *const fn (waiter: *anyopaque) void;

    runner: Runner,
    destroyer: Destroyer,
    waiter: *anyopaque,
    promise: core.JSValue,
};

pub const FinalizationPayload = struct {
    callback: core.JSValue,
    held_value: core.JSValue,
    symbol_root_mask: u2 = 0,
};

pub const Payload = union(enum) {
    generic: GenericPayload,
    promise: PromisePayload,
    promise_reaction: PromiseReactionPayload,
    promise_thenable: PromiseThenablePayload,
    promise_settlement: PromiseSettlementPayload,
    dynamic_import: DynamicImportPayload,
    atomics_waiter: AtomicsWaiterPayload,
    finalization: FinalizationPayload,
};
pub const Kind = std.meta.Tag(Payload);

/// One runtime FIFO entry. The RealmRef is common to every ECMAScript job;
/// the tagged payload is scheduler data and never appears as a fake callable
/// object on the JavaScript surface.
pub const Job = struct {
    runtime: *core.JSRuntime,
    realm: core.RealmRef,
    payload: Payload,

    pub fn init(context: *core.JSContext, func: Func, args: []const core.JSValue) !Job {
        if (args.len > MaxArgs) return error.TooManyJobArgs;
        var job = Job{
            .runtime = context.runtime,
            .realm = core.RealmRef.retain(context),
            .payload = .{ .generic = .{
                .func = func,
                .argc = @intCast(args.len),
            } },
        };
        errdefer job.deinit();
        const payload = &job.payload.generic;
        for (args, 0..) |arg, index| {
            payload.argv[index] = arg.dup();
            if (try context.runtime.registerExternalValueSymbolRoot(arg)) {
                payload.symbol_arg_mask |= @as(u5, 1) << @intCast(index);
            }
        }
        return job;
    }

    pub fn initPromise(context: *core.JSContext, value: core.JSValue) !Job {
        var job = Job{
            .runtime = context.runtime,
            .realm = core.RealmRef.retain(context),
            .payload = .{ .promise = .{ .value = value.dup() } },
        };
        errdefer job.deinit();
        job.payload.promise.value_symbol_rooted = try context.runtime.registerExternalValueSymbolRoot(value);
        return job;
    }

    /// Build a no-fail commit entry from a caller-owned object value after the
    /// queue storage has already been reserved. Ownership of `value` moves into
    /// the returned entry.
    pub fn initOwnedPromiseObject(context: *core.JSContext, value: core.JSValue) Job {
        std.debug.assert(value.isObject());
        return .{
            .runtime = context.runtime,
            .realm = core.RealmRef.retain(context),
            .payload = .{ .promise = .{ .value = value } },
        };
    }

    pub fn initPromiseReaction(
        context: *core.JSContext,
        reaction: core.JSValue,
        value: core.JSValue,
        rejected: bool,
    ) !Job {
        var job = initPromiseReactionNoFail(context, reaction, value, rejected);
        errdefer job.deinit();
        if (try context.runtime.registerExternalValueSymbolRoot(reaction)) job.payload.promise_reaction.symbol_root_mask |= 0b01;
        if (try context.runtime.registerExternalValueSymbolRoot(value)) job.payload.promise_reaction.symbol_root_mask |= 0b10;
        return job;
    }

    /// Allocation-free Promise reaction entry construction after the caller
    /// has reserved both payload storage and a queue slot. S2 JSValues own
    /// their symbol bodies directly, so duplication and RealmRef retain are
    /// the complete root transaction.
    pub fn initPromiseReactionNoFail(
        context: *core.JSContext,
        reaction: core.JSValue,
        value: core.JSValue,
        rejected: bool,
    ) Job {
        return .{
            .runtime = context.runtime,
            .realm = core.RealmRef.retain(context),
            .payload = .{ .promise_reaction = .{
                .reaction = reaction.dup(),
                .value = value.dup(),
                .rejected = rejected,
            } },
        };
    }

    pub fn initPromiseThenable(
        context: *core.JSContext,
        target: core.JSValue,
        thenable: core.JSValue,
        then_function: core.JSValue,
    ) !Job {
        var job = initPromiseThenableNoFail(context, target, thenable, then_function);
        errdefer job.deinit();
        if (try context.runtime.registerExternalValueSymbolRoot(target)) job.payload.promise_thenable.symbol_root_mask |= 0b001;
        if (try context.runtime.registerExternalValueSymbolRoot(thenable)) job.payload.promise_thenable.symbol_root_mask |= 0b010;
        if (try context.runtime.registerExternalValueSymbolRoot(then_function)) job.payload.promise_thenable.symbol_root_mask |= 0b100;
        return job;
    }

    /// Allocation-free thenable entry construction for a pre-reserved FIFO
    /// slot. The execution-time resolving pair remains fallible and is tracked
    /// by PromiseThenablePhase before any user callback runs.
    pub fn initPromiseThenableNoFail(
        context: *core.JSContext,
        target: core.JSValue,
        thenable: core.JSValue,
        then_function: core.JSValue,
    ) Job {
        return .{
            .runtime = context.runtime,
            .realm = core.RealmRef.retain(context),
            .payload = .{ .promise_thenable = .{
                .target = target.dup(),
                .thenable = thenable.dup(),
                .then_function = then_function.dup(),
            } },
        };
    }

    /// Construct an allocation-free continuation after the caller has
    /// reserved a FIFO slot. Object/value duplication and RealmRef retain are
    /// no-fail ownership transfers in both supported JSValue layouts.
    pub fn initPromiseSettlementNoFail(
        context: *core.JSContext,
        target: core.JSValue,
        completion: core.JSValue,
        rejected: bool,
    ) Job {
        std.debug.assert(target.isObject());
        return .{
            .runtime = context.runtime,
            .realm = core.RealmRef.retain(context),
            .payload = .{ .promise_settlement = .{
                .target = target.dup(),
                .completion = completion.dup(),
                .rejected = rejected,
            } },
        };
    }

    pub fn initDynamicImport(
        context: *core.JSContext,
        runner: DynamicImportPayload.Runner,
        resolve: core.JSValue,
        reject: core.JSValue,
        basename: core.JSValue,
        specifier: core.JSValue,
        attributes: core.JSValue,
    ) !Job {
        const values = [_]core.JSValue{ resolve, reject, basename, specifier, attributes };
        var job = Job{
            .runtime = context.runtime,
            .realm = core.RealmRef.retain(context),
            .payload = .{ .dynamic_import = .{
                .runner = runner,
                .resolve = resolve.dup(),
                .reject = reject.dup(),
                .basename = basename.dup(),
                .specifier = specifier.dup(),
                .attributes = attributes.dup(),
            } },
        };
        errdefer job.deinit();
        inline for (values, 0..) |value, index| {
            if (try context.runtime.registerExternalValueSymbolRoot(value)) {
                job.payload.dynamic_import.symbol_root_mask |= @as(u5, 1) << @intCast(index);
            }
        }
        return job;
    }

    pub fn initAtomicsWaiter(
        context: *core.JSContext,
        waiter: *anyopaque,
        promise: core.JSValue,
        runner: AtomicsWaiterPayload.Runner,
        destroyer: AtomicsWaiterPayload.Destroyer,
    ) Job {
        std.debug.assert(promise.isObject());
        return .{
            .runtime = context.runtime,
            .realm = core.RealmRef.retain(context),
            .payload = .{ .atomics_waiter = .{
                .runner = runner,
                .destroyer = destroyer,
                .waiter = waiter,
                .promise = promise.dup(),
            } },
        };
    }

    pub fn initFinalization(
        realm: *core.JSContext,
        callback: core.JSValue,
        held_value: core.JSValue,
    ) !Job {
        var job = Job{
            .runtime = realm.runtime,
            .realm = core.RealmRef.retain(realm),
            .payload = .{ .finalization = .{
                .callback = callback.dup(),
                .held_value = held_value.dup(),
            } },
        };
        errdefer job.deinit();
        if (try realm.runtime.registerExternalValueSymbolRoot(callback)) job.payload.finalization.symbol_root_mask |= 0b01;
        if (try realm.runtime.registerExternalValueSymbolRoot(held_value)) job.payload.finalization.symbol_root_mask |= 0b10;
        return job;
    }

    pub fn deinit(self: *Job) void {
        switch (self.payload) {
            .generic => |*payload| {
                const argc = payload.argc;
                payload.argc = 0;
                var index: usize = 0;
                while (index < argc) : (index += 1) {
                    const value = payload.argv[index];
                    payload.argv[index] = core.JSValue.undefinedValue();
                    if ((payload.symbol_arg_mask & (@as(u5, 1) << @intCast(index))) != 0) {
                        self.runtime.unregisterExternalValueSymbolRoot(value);
                    }
                    value.free(self.runtime);
                }
                payload.symbol_arg_mask = 0;
            },
            .promise => |*payload| {
                if (payload.value_symbol_rooted) self.runtime.unregisterExternalValueSymbolRoot(payload.value);
                payload.value.free(self.runtime);
                payload.value = core.JSValue.undefinedValue();
                payload.value_symbol_rooted = false;
            },
            .promise_reaction => |*payload| {
                if ((payload.symbol_root_mask & 0b01) != 0) self.runtime.unregisterExternalValueSymbolRoot(payload.reaction);
                if ((payload.symbol_root_mask & 0b10) != 0) self.runtime.unregisterExternalValueSymbolRoot(payload.value);
                payload.reaction.free(self.runtime);
                payload.value.free(self.runtime);
                payload.reaction = core.JSValue.undefinedValue();
                payload.value = core.JSValue.undefinedValue();
                payload.symbol_root_mask = 0;
            },
            .promise_thenable => |*payload| {
                const values = [_]core.JSValue{
                    payload.target,
                    payload.thenable,
                    payload.then_function,
                    payload.resolving_resolve,
                    payload.resolving_reject,
                    payload.completion,
                };
                inline for (values, 0..) |value, index| {
                    if ((payload.symbol_root_mask & (@as(u6, 1) << @intCast(index))) != 0) {
                        self.runtime.unregisterExternalValueSymbolRoot(value);
                    }
                    value.free(self.runtime);
                }
                payload.target = core.JSValue.undefinedValue();
                payload.thenable = core.JSValue.undefinedValue();
                payload.then_function = core.JSValue.undefinedValue();
                payload.resolving_resolve = core.JSValue.undefinedValue();
                payload.resolving_reject = core.JSValue.undefinedValue();
                payload.completion = core.JSValue.undefinedValue();
                payload.symbol_root_mask = 0;
            },
            .promise_settlement => |*payload| {
                payload.target.free(self.runtime);
                payload.completion.free(self.runtime);
                payload.target = core.JSValue.undefinedValue();
                payload.completion = core.JSValue.undefinedValue();
            },
            .dynamic_import => |*payload| {
                const values = [_]core.JSValue{ payload.resolve, payload.reject, payload.basename, payload.specifier, payload.attributes };
                inline for (values, 0..) |value, index| {
                    if ((payload.symbol_root_mask & (@as(u5, 1) << @intCast(index))) != 0) {
                        self.runtime.unregisterExternalValueSymbolRoot(value);
                    }
                    value.free(self.runtime);
                }
                payload.resolve = core.JSValue.undefinedValue();
                payload.reject = core.JSValue.undefinedValue();
                payload.basename = core.JSValue.undefinedValue();
                payload.specifier = core.JSValue.undefinedValue();
                payload.attributes = core.JSValue.undefinedValue();
                payload.symbol_root_mask = 0;
            },
            .atomics_waiter => |*payload| {
                payload.promise.free(self.runtime);
                payload.promise = core.JSValue.undefinedValue();
                payload.destroyer(payload.waiter);
            },
            .finalization => |*payload| {
                if ((payload.symbol_root_mask & 0b01) != 0) self.runtime.unregisterExternalValueSymbolRoot(payload.callback);
                if ((payload.symbol_root_mask & 0b10) != 0) self.runtime.unregisterExternalValueSymbolRoot(payload.held_value);
                payload.callback.free(self.runtime);
                payload.held_value.free(self.runtime);
                payload.callback = core.JSValue.undefinedValue();
                payload.held_value = core.JSValue.undefinedValue();
                payload.symbol_root_mask = 0;
            },
        }
        self.realm.deinit();
    }

    pub fn run(self: *Job) core.JSValue {
        const payload = &self.payload.generic;
        return payload.func(self.realm.borrow() orelse unreachable, payload.argv[0..payload.argc]);
    }

    pub fn traceRoots(self: *Job, visitor: anytype) !void {
        switch (self.payload) {
            .generic => |*payload| for (payload.argv[0..payload.argc]) |*arg| try visitor.value(arg),
            .promise => |*payload| try visitor.value(&payload.value),
            .promise_reaction => |*payload| {
                try visitor.value(&payload.reaction);
                try visitor.value(&payload.value);
            },
            .promise_thenable => |*payload| {
                try visitor.value(&payload.target);
                try visitor.value(&payload.thenable);
                try visitor.value(&payload.then_function);
                try visitor.value(&payload.resolving_resolve);
                try visitor.value(&payload.resolving_reject);
                try visitor.value(&payload.completion);
            },
            .promise_settlement => |*payload| {
                try visitor.value(&payload.target);
                try visitor.value(&payload.completion);
            },
            .dynamic_import => |*payload| {
                try visitor.value(&payload.resolve);
                try visitor.value(&payload.reject);
                try visitor.value(&payload.basename);
                try visitor.value(&payload.specifier);
                try visitor.value(&payload.attributes);
            },
            .atomics_waiter => |*payload| try visitor.value(&payload.promise),
            .finalization => |*payload| {
                try visitor.value(&payload.callback);
                try visitor.value(&payload.held_value);
            },
        }
    }
};

pub const Queue = struct {
    memory: *memory.MemoryAccount,
    jobs: []Job = &.{},
    capacity: usize = 0,
    /// Slots promised to prepared transactions that have not committed yet.
    /// Ordinary enqueues must leave these slots available, while still
    /// appending immediately so reentrant enqueue order remains observable.
    reserved_entries: usize = 0,

    pub fn init(account: *memory.MemoryAccount) Queue {
        return .{ .memory = account };
    }

    pub fn deinit(self: *Queue) void {
        std.debug.assert(self.reserved_entries == 0);
        const jobs = self.jobs;
        const capacity = self.capacity;
        self.jobs = &.{};
        self.capacity = 0;
        self.reserved_entries = 0;
        for (jobs) |*job| job.deinit();
        if (capacity != 0) self.memory.free(Job, jobs.ptr[0..capacity]);
    }

    pub fn enqueue(self: *Queue, job: Job) !void {
        try self.ensureAdditionalCapacity(1);
        self.enqueuePrepared(job);
    }

    fn ensureAdditionalCapacity(self: *Queue, additional: usize) !void {
        try self.ensureCapacity(self.jobs.len + self.reserved_entries + additional);
    }

    pub fn ensureCapacity(self: *Queue, min_capacity: usize) !void {
        if (self.capacity >= min_capacity) return;
        var next_capacity = if (self.capacity == 0) @as(usize, 4) else self.capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const next = try self.memory.alloc(Job, next_capacity);
        errdefer self.memory.free(Job, next);
        const old_jobs = self.jobs;
        const old_capacity = self.capacity;
        @memcpy(next[0..old_jobs.len], old_jobs);
        self.jobs = next[0..old_jobs.len];
        self.capacity = next_capacity;
        if (old_capacity != 0) self.memory.free(Job, old_jobs.ptr[0..old_capacity]);
    }

    /// Reserve queue storage for a transaction whose payload ownership is
    /// already being prepared. A reservation does not occupy a FIFO position:
    /// reentrant ordinary jobs append immediately and therefore stay ahead of
    /// the transaction when it eventually commits.
    pub fn reserveEntries(self: *Queue, count: usize) !void {
        if (count == 0) return;
        try self.ensureCapacity(self.jobs.len + self.reserved_entries + count);
        self.reserved_entries += count;
    }

    pub fn releaseReservedEntries(self: *Queue, count: usize) void {
        std.debug.assert(count <= self.reserved_entries);
        self.reserved_entries -= count;
    }

    /// Hold the physical slot just freed by `takeFirst` while a retriable job
    /// runs. This is deliberately no-fail: the unlinked entry proves that one
    /// slot exists even if callbacks enqueue other work during the attempt.
    pub fn reserveUnlinkedEntrySlot(self: *Queue) void {
        std.debug.assert(self.jobs.len + self.reserved_entries < self.capacity);
        self.reserved_entries += 1;
    }

    /// Commit one already-prepared entry without allocation. The caller must
    /// reserve enough queue storage before entering its visible state-change
    /// phase.
    pub fn enqueuePrepared(self: *Queue, job: Job) void {
        std.debug.assert(self.jobs.len + self.reserved_entries < self.capacity);
        self.append(job);
    }

    /// Commit one entry against a prior reservation without allocation.
    pub fn enqueueReserved(self: *Queue, job: Job) void {
        std.debug.assert(self.reserved_entries != 0);
        self.reserved_entries -= 1;
        std.debug.assert(self.jobs.len < self.capacity);
        self.append(job);
    }

    fn append(self: *Queue, job: Job) void {
        const len = self.jobs.len;
        self.jobs = self.jobs.ptr[0 .. len + 1];
        self.jobs[len] = job;
    }

    pub fn enqueueFunc(self: *Queue, context: *core.JSContext, func: Func, args: []const core.JSValue) !void {
        try self.ensureAdditionalCapacity(1);
        var job = try Job.init(context, func, args);
        errdefer job.deinit();
        self.enqueuePrepared(job);
    }

    pub fn enqueuePromise(self: *Queue, context: *core.JSContext, value: core.JSValue) !void {
        try self.ensureAdditionalCapacity(1);
        var job = try Job.initPromise(context, value);
        errdefer job.deinit();
        self.enqueuePrepared(job);
    }

    /// Transfer an owned object payload into an already-reserved Promise job.
    pub fn enqueueOwnedPromiseObjectPrepared(self: *Queue, context: *core.JSContext, value: core.JSValue) void {
        self.enqueueReserved(Job.initOwnedPromiseObject(context, value));
    }

    pub fn preparePromiseReaction(
        self: *Queue,
        context: *core.JSContext,
        reaction: core.JSValue,
        value: core.JSValue,
        rejected: bool,
    ) !Job {
        _ = self;
        return Job.initPromiseReaction(context, reaction, value, rejected);
    }

    pub fn enqueuePromiseReaction(
        self: *Queue,
        context: *core.JSContext,
        reaction: core.JSValue,
        value: core.JSValue,
        rejected: bool,
    ) !void {
        try self.ensureAdditionalCapacity(1);
        var job = try Job.initPromiseReaction(context, reaction, value, rejected);
        errdefer job.deinit();
        self.enqueuePrepared(job);
    }

    pub fn enqueuePromiseThenable(
        self: *Queue,
        context: *core.JSContext,
        target: core.JSValue,
        thenable: core.JSValue,
        then_function: core.JSValue,
    ) !void {
        try self.ensureAdditionalCapacity(1);
        var job = try Job.initPromiseThenable(context, target, thenable, then_function);
        errdefer job.deinit();
        self.enqueuePrepared(job);
    }

    pub fn enqueueDynamicImport(
        self: *Queue,
        context: *core.JSContext,
        runner: DynamicImportPayload.Runner,
        resolve: core.JSValue,
        reject: core.JSValue,
        basename: core.JSValue,
        specifier: core.JSValue,
        attributes: core.JSValue,
    ) !void {
        try self.ensureAdditionalCapacity(1);
        var job = try Job.initDynamicImport(context, runner, resolve, reject, basename, specifier, attributes);
        errdefer job.deinit();
        self.enqueuePrepared(job);
    }

    pub fn enqueueAtomicsWaiter(
        self: *Queue,
        context: *core.JSContext,
        waiter: *anyopaque,
        promise: core.JSValue,
        runner: AtomicsWaiterPayload.Runner,
        destroyer: AtomicsWaiterPayload.Destroyer,
    ) !void {
        try self.ensureAdditionalCapacity(1);
        self.enqueuePrepared(Job.initAtomicsWaiter(context, waiter, promise, runner, destroyer));
    }

    pub fn enqueueFinalization(
        self: *Queue,
        realm: *core.JSContext,
        callback: core.JSValue,
        held_value: core.JSValue,
    ) !void {
        try self.ensureAdditionalCapacity(1);
        var job = try Job.initFinalization(realm, callback, held_value);
        errdefer job.deinit();
        self.enqueuePrepared(job);
    }

    pub fn hasJobs(self: Queue) bool {
        return self.jobs.len != 0;
    }

    /// Unlink exactly one FIFO entry and transfer all of its ownership to the
    /// caller. The caller must eventually invoke `Job.deinit`.
    pub fn takeFirst(self: *Queue) ?Job {
        if (self.jobs.len == 0) return null;
        return self.takeAt(0);
    }

    pub fn takeAt(self: *Queue, index: usize) Job {
        std.debug.assert(index < self.jobs.len);
        const job = self.jobs[index];
        if (index + 1 < self.jobs.len) {
            std.mem.copyForwards(Job, self.jobs[index .. self.jobs.len - 1], self.jobs[index + 1 ..]);
        }
        self.jobs = self.jobs[0 .. self.jobs.len - 1];
        return job;
    }

    /// Reinsert an active entry at the FIFO head after a retriable host
    /// completion failure. The active runner must have reserved this slot
    /// immediately after unlinking the entry.
    pub fn prependReserved(self: *Queue, job: Job) void {
        std.debug.assert(self.reserved_entries != 0);
        self.reserved_entries -= 1;
        std.debug.assert(self.jobs.len < self.capacity);
        const old_len = self.jobs.len;
        self.jobs = self.jobs.ptr[0 .. old_len + 1];
        if (old_len != 0) {
            std.mem.copyBackwards(Job, self.jobs[1 .. old_len + 1], self.jobs[0..old_len]);
        }
        self.jobs[0] = job;
    }

    pub fn firstIndexOfKind(self: Queue, kind: Kind) ?usize {
        for (self.jobs, 0..) |job, index| {
            if (std.meta.activeTag(job.payload) == kind) return index;
        }
        return null;
    }

    pub fn countKind(self: Queue, kind: Kind) usize {
        var count: usize = 0;
        for (self.jobs) |job| {
            if (std.meta.activeTag(job.payload) == kind) count += 1;
        }
        return count;
    }

    pub fn traceRoots(self: *Queue, visitor: anytype) !void {
        for (self.jobs) |*job| {
            try job.traceRoots(visitor);
        }
    }
};

const std = @import("std");

fn runGenericOneForTest(queue: *Queue) RunOneStatus {
    var job = queue.takeFirst() orelse return .empty;
    std.debug.assert(std.meta.activeTag(job.payload) == .generic);
    const context = job.realm.borrow() orelse unreachable;
    const runtime = context.runtime;
    const result = job.run();
    const status: RunOneStatus = if (result.isException()) .exception else .success;
    result.free(runtime);
    job.deinit();
    return status;
}

test "Queue runOne reports three states and preserves FIFO after exception" {
    const runtime = try core.JSRuntime.create(std.testing.allocator);
    defer runtime.destroy();
    const context = try core.JSContext.create(runtime);
    defer context.destroy();

    const TestJob = struct {
        fn fail(ctx: *core.JSContext, _: []const core.JSValue) core.JSValue {
            return ctx.throwValue(core.JSValue.int32(91));
        }

        fn succeed(_: *core.JSContext, _: []const core.JSValue) core.JSValue {
            return core.JSValue.int32(7);
        }
    };

    try std.testing.expectEqual(RunOneStatus.empty, runGenericOneForTest(&runtime.job_queue));
    try runtime.job_queue.enqueueFunc(context, TestJob.fail, &.{});
    try runtime.job_queue.enqueueFunc(context, TestJob.succeed, &.{});

    try std.testing.expectEqual(RunOneStatus.exception, runGenericOneForTest(&runtime.job_queue));
    try std.testing.expectEqual(@as(usize, 1), runtime.job_queue.jobs.len);
    try std.testing.expect(context.hasException());
    const exception = context.takeException();
    defer exception.free(runtime);
    try std.testing.expectEqual(@as(?i32, 91), exception.asInt32());

    try std.testing.expectEqual(RunOneStatus.success, runGenericOneForTest(&runtime.job_queue));
    try std.testing.expectEqual(RunOneStatus.empty, runGenericOneForTest(&runtime.job_queue));
}

test "Promise settlement continuation owns target and direct symbol completion" {
    const runtime = try core.JSRuntime.create(std.testing.allocator);
    defer runtime.destroy();
    const context = try core.JSContext.create(runtime);
    defer context.destroy();

    const target = try core.Object.create(runtime, core.class.ids.promise, null);
    var target_alive = true;
    defer if (target_alive) target.value().free(runtime);
    const symbol_atom = try runtime.atoms.newValueSymbol("promise-settlement-continuation-symbol");
    const completion = try runtime.symbolValue(symbol_atom);
    var completion_alive = true;
    defer if (completion_alive) completion.free(runtime);

    var job = Job.initPromiseSettlementNoFail(context, target.value(), completion, false);
    var job_alive = true;
    defer if (job_alive) job.deinit();
    target.value().free(runtime);
    target_alive = false;
    completion.free(runtime);
    completion_alive = false;

    _ = runtime.runObjectCycleRemoval();
    try std.testing.expect(runtime.atoms.name(symbol_atom) != null);
    try std.testing.expectEqual(symbol_atom, job.payload.promise_settlement.completion.asSymbolAtom().?);

    job.deinit();
    job_alive = false;
    _ = runtime.runObjectCycleRemoval();
    try std.testing.expect(runtime.atoms.name(symbol_atom) == null);
}

test "Queue runOne keeps existing tail ahead of jobs enqueued by the active job" {
    const runtime = try core.JSRuntime.create(std.testing.allocator);
    defer runtime.destroy();
    const context = try core.JSContext.create(runtime);
    defer context.destroy();

    const observed = try core.Object.createArray(runtime, null);
    defer observed.value().free(runtime);

    const TestJob = struct {
        fn append(ctx: *core.JSContext, args: []const core.JSValue) core.JSValue {
            const array = core.Object.expect(args[0]) catch return ctx.throwValue(core.JSValue.int32(-1));
            const index = array.arrayLength();
            const appended = array.appendDenseArrayDefineIndex(
                ctx.runtime,
                index,
                core.atom.atomFromUInt32(index),
                args[1],
            ) catch return ctx.throwValue(core.JSValue.int32(-2));
            if (!appended) return ctx.throwValue(core.JSValue.int32(-3));
            return core.JSValue.undefinedValue();
        }

        fn appendAndEnqueue(ctx: *core.JSContext, args: []const core.JSValue) core.JSValue {
            const result = append(ctx, &.{ args[0], core.JSValue.int32(1) });
            if (result.isException()) return result;
            ctx.runtime.job_queue.enqueueFunc(ctx, append, &.{ args[0], core.JSValue.int32(3) }) catch {
                return ctx.throwValue(core.JSValue.int32(-4));
            };
            return core.JSValue.undefinedValue();
        }
    };

    try runtime.job_queue.enqueueFunc(context, TestJob.appendAndEnqueue, &.{observed.value()});
    try runtime.job_queue.enqueueFunc(context, TestJob.append, &.{ observed.value(), core.JSValue.int32(2) });

    try std.testing.expectEqual(RunOneStatus.success, runGenericOneForTest(&runtime.job_queue));
    try std.testing.expectEqual(@as(usize, 2), runtime.job_queue.jobs.len);
    try std.testing.expectEqual(RunOneStatus.success, runGenericOneForTest(&runtime.job_queue));
    try std.testing.expectEqual(RunOneStatus.success, runGenericOneForTest(&runtime.job_queue));
    try std.testing.expectEqual(RunOneStatus.empty, runGenericOneForTest(&runtime.job_queue));

    try std.testing.expectEqual(@as(u32, 3), observed.arrayLength());
    const first = try observed.getProperty(core.atom.atomFromUInt32(0));
    defer first.free(runtime);
    const second = try observed.getProperty(core.atom.atomFromUInt32(1));
    defer second.free(runtime);
    const third = try observed.getProperty(core.atom.atomFromUInt32(2));
    defer third.free(runtime);
    try std.testing.expectEqual(@as(?i32, 1), first.asInt32());
    try std.testing.expectEqual(@as(?i32, 2), second.asInt32());
    try std.testing.expectEqual(@as(?i32, 3), third.asInt32());
}
