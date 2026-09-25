//! Expected compile failure: a value walk must reject a missing atom method
//! even when this particular fixture never calls that method.
const core = @import("zjs").core;
const Incomplete = struct {
    pub fn visitValue(_: *@This(), _: *core.JSValue) void {}
    pub fn visitObject(_: *@This(), _: *?*core.Object) void {}
    pub fn visitShape(_: *@This(), _: anytype) void {}
    pub fn visitRealm(_: *@This(), _: anytype) void {}
    pub fn visitModule(_: *@This(), _: anytype) void {}
    pub fn storageCell(_: *@This(), _: core.gc_visit.CellSlot) void {}
    pub fn visitWeakCollectionEntry(_: *@This(), _: anytype) void {}
    pub fn visitFinalizationCell(_: *@This(), _: anytype) void {}
};

test "incomplete production visitor is rejected" {
    var visitor = Incomplete{};
    var value = core.JSValue.int32(1);
    try core.gc_visit.value(&visitor, &value);
}
