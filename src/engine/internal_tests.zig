const shared_vm = @import("exec/vm/shared.zig");
const iter_vm = @import("exec/vm/iter.zig");
const property_vm = @import("exec/vm/property.zig");
const value_vm = @import("exec/vm/value.zig");
const gen_async_vm = @import("exec/vm/gen_async.zig");
const construct_mod = @import("exec/construct.zig");
const call_mod = @import("exec/call.zig");

test "exec vm shared internal tests are reachable" {
    _ = shared_vm;
    _ = iter_vm;
    _ = property_vm;
    _ = value_vm;
    _ = gen_async_vm;
    _ = construct_mod;
    _ = call_mod;
}
