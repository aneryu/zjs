const atom = @import("atom.zig");
const object = @import("object.zig");
const shape = @import("shape.zig");

pub const poly_entry_limit = 4;

pub const State = enum(u8) {
    empty,
    mono,
    poly,
    mega,
    invalid,
};

pub const LookupResult = union(enum) {
    hit: usize,
    miss,
    invalidated,
};

pub const ProtoLookupResult = union(enum) {
    hit: ProtoHit,
    miss,
    invalidated,
};

pub const ProtoHit = struct {
    holder: *object.Object,
    slot_index: usize,
};

pub const InstallResult = enum(u8) {
    unchanged,
    installed_mono,
    updated,
    promoted_poly,
    promoted_mega,
};

pub const Entry = struct {
    shape_ref: ?*shape.Shape = null,
    holder_shape_ref: ?*shape.Shape = null,
    version: u32 = 0,
    holder_version: u32 = 0,
    atom_id: atom.Atom = atom.null_atom,
    slot_index: usize = 0,

    fn matches(self: Entry, receiver: *object.Object, atom_id: atom.Atom) bool {
        const guard_shape = self.shape_ref orelse return false;
        return guard_shape == receiver.shape_ref and
            self.version == receiver.shape_ref.version and
            self.atom_id == atom_id;
    }
};

pub const Site = struct {
    pc: usize,
    slot_index: usize,
};

pub const Slot = struct {
    state: State = .empty,
    entries: [poly_entry_limit]Entry = [_]Entry{.{}} ** poly_entry_limit,
    entry_count: u8 = 0,

    pub fn lookupOwnData(self: *const Slot, receiver: *object.Object, atom_id: atom.Atom) ?usize {
        return switch (self.lookupOwnDataResult(receiver, atom_id)) {
            .hit => |index| index,
            .miss, .invalidated => null,
        };
    }

    pub fn lookupOwnDataResult(self: *const Slot, receiver: *object.Object, atom_id: atom.Atom) LookupResult {
        return switch (self.state) {
            .empty, .mega => .miss,
            .invalid => .invalidated,
            .mono => blk: {
                const entry = self.entries[0];
                if (entry.holder_shape_ref == null and entry.shape_ref == receiver.shape_ref and entry.atom_id == atom_id) {
                    if (entry.version == receiver.shape_ref.version) break :blk .{ .hit = entry.slot_index };
                    break :blk .invalidated;
                }
                break :blk .miss;
            },
            .poly => blk: {
                var i: usize = 0;
                while (i < self.entry_count) : (i += 1) {
                    const entry = self.entries[i];
                    if (entry.holder_shape_ref == null and entry.shape_ref == receiver.shape_ref and entry.atom_id == atom_id) {
                        if (entry.version == receiver.shape_ref.version) break :blk .{ .hit = entry.slot_index };
                        break :blk .invalidated;
                    }
                }
                break :blk .miss;
            },
        };
    }

    pub fn lookupProtoDataResult(self: *const Slot, receiver: *object.Object, atom_id: atom.Atom) ProtoLookupResult {
        return switch (self.state) {
            .empty, .mega => .miss,
            .invalid => .invalidated,
            .mono => blk: {
                const entry = self.entries[0];
                if (entry.shape_ref == receiver.shape_ref and entry.atom_id == atom_id) {
                    if (entry.version != receiver.shape_ref.version) break :blk .invalidated;
                    const holder_shape = entry.holder_shape_ref orelse break :blk .miss;
                    const holder = receiver.getPrototype() orelse break :blk .invalidated;
                    if (holder.shape_ref == holder_shape and entry.holder_version == holder.shape_ref.version) {
                        break :blk .{ .hit = .{ .holder = holder, .slot_index = entry.slot_index } };
                    }
                    break :blk .invalidated;
                }
                break :blk .miss;
            },
            .poly => blk: {
                var i: usize = 0;
                while (i < self.entry_count) : (i += 1) {
                    const entry = self.entries[i];
                    if (entry.shape_ref == receiver.shape_ref and entry.atom_id == atom_id) {
                        if (entry.version != receiver.shape_ref.version) break :blk .invalidated;
                        const holder_shape = entry.holder_shape_ref orelse continue;
                        const holder = receiver.getPrototype() orelse break :blk .invalidated;
                        if (holder.shape_ref == holder_shape and entry.holder_version == holder.shape_ref.version) {
                            break :blk .{ .hit = .{ .holder = holder, .slot_index = entry.slot_index } };
                        }
                        break :blk .invalidated;
                    }
                }
                break :blk .miss;
            },
        };
    }

    pub fn installOwnData(
        self: *Slot,
        registry: *shape.Registry,
        receiver: *object.Object,
        atom_id: atom.Atom,
        slot_index: usize,
    ) InstallResult {
        if (self.state == .mega) return .unchanged;

        var i: usize = 0;
        while (i < self.entry_count) : (i += 1) {
            const existing = self.entries[i].shape_ref orelse continue;
            if (self.entries[i].holder_shape_ref != null) continue;
            if (existing != receiver.shape_ref or self.entries[i].atom_id != atom_id) continue;
            self.entries[i].version = receiver.shape_ref.version;
            self.entries[i].slot_index = slot_index;
            self.state = if (self.entry_count == 1) .mono else .poly;
            return .updated;
        }

        if (self.entry_count == poly_entry_limit) {
            self.releaseEntries(registry);
            self.state = .mega;
            return .promoted_mega;
        }

        const old_entry_count = self.entry_count;
        receiver.shape_ref.retain();
        self.entries[self.entry_count] = .{
            .shape_ref = receiver.shape_ref,
            .version = receiver.shape_ref.version,
            .atom_id = atom_id,
            .slot_index = slot_index,
        };
        self.entry_count += 1;
        self.state = if (self.entry_count == 1) .mono else .poly;
        return if (old_entry_count == 0) .installed_mono else if (old_entry_count == 1) .promoted_poly else .updated;
    }

    pub fn installProtoData(
        self: *Slot,
        registry: *shape.Registry,
        receiver: *object.Object,
        holder: *object.Object,
        atom_id: atom.Atom,
        slot_index: usize,
    ) InstallResult {
        if (self.state == .mega) return .unchanged;

        var i: usize = 0;
        while (i < self.entry_count) : (i += 1) {
            const existing = self.entries[i].shape_ref orelse continue;
            const existing_holder = self.entries[i].holder_shape_ref orelse continue;
            if (existing != receiver.shape_ref or existing_holder != holder.shape_ref or self.entries[i].atom_id != atom_id) continue;
            self.entries[i].version = receiver.shape_ref.version;
            self.entries[i].holder_version = holder.shape_ref.version;
            self.entries[i].slot_index = slot_index;
            self.state = if (self.entry_count == 1) .mono else .poly;
            return .updated;
        }

        if (self.entry_count == poly_entry_limit) {
            self.releaseEntries(registry);
            self.state = .mega;
            return .promoted_mega;
        }

        const old_entry_count = self.entry_count;
        receiver.shape_ref.retain();
        holder.shape_ref.retain();
        self.entries[self.entry_count] = .{
            .shape_ref = receiver.shape_ref,
            .holder_shape_ref = holder.shape_ref,
            .version = receiver.shape_ref.version,
            .holder_version = holder.shape_ref.version,
            .atom_id = atom_id,
            .slot_index = slot_index,
        };
        self.entry_count += 1;
        self.state = if (self.entry_count == 1) .mono else .poly;
        return if (old_entry_count == 0) .installed_mono else if (old_entry_count == 1) .promoted_poly else .updated;
    }

    pub fn deinit(self: *Slot, registry: *shape.Registry) void {
        self.releaseEntries(registry);
        self.state = .empty;
    }

    fn releaseEntries(self: *Slot, registry: *shape.Registry) void {
        var i: usize = 0;
        while (i < self.entry_count) : (i += 1) {
            if (self.entries[i].shape_ref) |shape_ref| registry.release(shape_ref);
            if (self.entries[i].holder_shape_ref) |holder_shape_ref| registry.release(holder_shape_ref);
            self.entries[i] = .{};
        }
        self.entry_count = 0;
    }
};
