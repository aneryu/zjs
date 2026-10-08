//! Object-model tests. Imported from `object.zig` so the engine suite still runs them.

const std = @import("std");

const atom = @import("atom.zig");
const block_heap = @import("gc_block_heap.zig");
const class = @import("class.zig");
const context_mod = @import("context.zig");
const descriptor = @import("descriptor.zig");
const gc = @import("gc.zig");
const gc_visit = @import("gc_visit.zig");
const object_mod = @import("object.zig");
const property = @import("property.zig");
const runtime_mod = @import("../runtime.zig");
const shape = @import("shape.zig");
const string = @import("string.zig");
const typed_array_names = @import("typed_array_names.zig");
const var_ref_mod = @import("var_ref.zig");

const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const FunctionBytecode = @import("../bytecode.zig").function_bytecode.FunctionBytecode;

const ArrayStorageMode = object_mod.ArrayStorageMode;
const ArgumentsPayload = object_mod.ArgumentsPayload;
const BoundFunctionPayload = object_mod.BoundFunctionPayload;
const BufferPayload = object_mod.BufferPayload;
const BytecodeFunctionAux = object_mod.BytecodeFunctionAux;
const CollectionPayload = object_mod.CollectionPayload;
const DisposableStackPayload = object_mod.DisposableStackPayload;
const FunctionRarePayload = object_mod.FunctionRarePayload;
const GeneratorPayload = object_mod.GeneratorPayload;
const IteratorPayload = object_mod.IteratorPayload;
const Object = object_mod.Object;
const ObjectDataPayload = object_mod.ObjectDataPayload;
const OrdinaryPayload = object_mod.OrdinaryPayload;
const PromisePayload = object_mod.PromisePayload;
const ProxyPayload = object_mod.ProxyPayload;
const RegExpPayload = object_mod.RegExpPayload;
const SharedBufferStore = object_mod.SharedBufferStore;
const SuspendedExecutionStorage = object_mod.SuspendedExecutionStorage;
const TypedArrayPayload = object_mod.TypedArrayPayload;
const VarRefPayload = object_mod.VarRefPayload;
const WeakRefPayload = object_mod.WeakRefPayload;

test "object value refs keep nested symbol bodies without external symbol roots" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const object = try Object.create(rt, class.ids.object, null);
    var object_value = object.value();

    const key = try rt.internAtom("external-object-root-symbol-slot");
    const nested_value = try rt.newSymbolValue("external-object-root-nested-symbol");
    const nested_symbol = nested_value.asSymbolAtom().?;
    try object.defineOwnProperty(rt, key, descriptor.Descriptor.data(nested_value, .all));

    // The owner object is held only by this Zig local; the tracing sweep
    // needs it declared for the keep phase. Deactivated before the release
    // phase so the second collection can observe the symbol body dropping.
    var object_slot: ?*Object = object;
    var live_roots = runtime_mod.rootObjects(.{&object_slot});
    live_roots.activate(rt);
    var roots_active = true;
    defer if (roots_active) live_roots.deactivate(rt);

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(nested_symbol) != null);

    live_roots.deactivate(rt);
    roots_active = false;
    object_value = JSValue.undefinedValue();
    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(nested_symbol) == null);
}
test "M-cut Object handle conversion keeps the head at the handle address" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const object = try Object.createPlainObject(rt, null);

    // The Object pointer IS the GC handle and the body start; the metadata
    // prefix sits at handle-8 and no resident successor word exists.
    try std.testing.expectEqual(object, Object.fromHeader(object.gcHeader()));
    try std.testing.expectEqual(
        @intFromPtr(object) - gc.metadata_prefix_size,
        @intFromPtr(object.gcHeader().meta()),
    );
    // TGC S4-e retired the Pass-B park, so nothing borrows the Shape word for
    // a temporary successor any more.
    try std.testing.expectEqual(class.ids.object, object.class_id);
}
test "block Object accounting uses physical cell body capacity" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const objects = [_]*Object{
        try Object.create(rt, class.ids.object, null),
        try Object.createArray(rt, null),
        try Object.createPlainObjectReserved2(rt, null),
    };

    const calculated = comptime [_]usize{
        block_heap.accountedBodyBytesForRequest(
            gc.metadata_prefix_size + Object.objectBodyBytes(class.ids.object, false),
            gc.metadata_prefix_size,
        ).?,
        block_heap.accountedBodyBytesForRequest(
            gc.metadata_prefix_size + Object.objectBodyBytes(class.ids.array, false),
            gc.metadata_prefix_size,
        ).?,
        block_heap.accountedBodyBytesForRequest(
            gc.metadata_prefix_size + Object.objectBodyBytes(class.ids.object, true),
            gc.metadata_prefix_size,
        ).?,
    };
    for (objects, calculated) |object, arithmetic_bytes| {
        const raw_cell_bytes = rt.gc.block_heap.rawBytesForCell(
            @intFromPtr(object),
            gc.metadata_prefix_size,
        ) orelse return error.TestUnexpectedResult;
        const expected = raw_cell_bytes - gc.metadata_prefix_size;
        try std.testing.expectEqual(expected, arithmetic_bytes);
        try std.testing.expectEqual(expected, object.bodyBytes());
        try std.testing.expectEqual(expected, object.allocationSize(rt));
        try std.testing.expectEqual(
            expected,
            gc.Registry.heapByteSizeFromHeader(rt, object.gcHeaderConst()),
        );
    }
}
test "shape-sized trailing property storage grows externally and compacts in place" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    // Put a wider empty root at the head of the same hash chain. Tracing's
    // Reserved2 fast lookup must reject it and repair to an exact-capacity
    // Shape; adopting it would make Shape.prop_size exceed the two-slot tail.
    _ = try rt.shapes.createObjectRootWithPropertyCapacity(rt, null, 4);

    const object = try Object.createPlainObjectReserved2(rt, null);
    const object_address = @intFromPtr(object);
    try std.testing.expectEqual(@as(u32, Object.trailing_property_capacity), object.shape_ref.prop_size);
    try std.testing.expect(object.propertyStorageIsInline());
    try std.testing.expect(object.hasSlots2Layout());
    // TGC S4-e: the layout bit moved out of the retired `weakref_count` word
    // into the flags word; nothing else in the flags may disturb it.
    try std.testing.expect(object.flags.extensible);
    try std.testing.expectEqual(class.PayloadKind.none, object.flags.class_payload_kind);
    try std.testing.expectEqual(
        object_address + Object.slots2_property_storage_offset,
        @intFromPtr(object.propertyStorageBase()),
    );
    try std.testing.expectEqual(
        Object.objectBodyBytes(class.ids.object, true),
        object.allocationSize(rt),
    );

    const names = [_][]const u8{
        "tail_0", "tail_1", "tail_2", "tail_3", "tail_4",
        "tail_5", "tail_6", "tail_7", "tail_8", "tail_9",
    };
    var atoms: [names.len]atom.Atom = undefined;
    for (names, 0..) |name, index| atoms[index] = try rt.internAtom(name);

    for (atoms, 0..) |name, index| {
        try object.defineOwnProperty(
            rt,
            name,
            descriptor.Descriptor.data(JSValue.int32(@intCast(index)), .all),
        );
        try std.testing.expectEqual(object_address, @intFromPtr(object));
    }
    try std.testing.expect(!object.propertyStorageIsInline());
    try std.testing.expect(object.hasSlots2Layout());
    try std.testing.expectEqual(
        Object.objectBodyBytes(class.ids.object, true),
        object.allocationSize(rt),
    );

    // Eight tombstones meet the ordinary compaction trigger. The two live
    // values fit the immutable tail, so compaction frees only the external
    // buffer and retargets the descriptor; the Object never relocates.
    for (atoms[0..8]) |name| try std.testing.expect(try object.deleteProperty(rt, name));
    try std.testing.expectEqual(object_address, @intFromPtr(object));
    try std.testing.expect(object.propertyStorageIsInline());
    try std.testing.expect(object.hasSlots2Layout());
    try std.testing.expectEqual(@as(u32, 2), object.shape_ref.prop_count);
    try std.testing.expectEqual(@as(u32, 2), object.shape_ref.prop_size);
    try std.testing.expectEqual(@as(?i32, 8), (try object.getProperty(atoms[8])).as(.int));
    try std.testing.expectEqual(@as(?i32, 9), (try object.getProperty(atoms[9])).as(.int));

    try rt.gc.verifyObjectPropertyStorageLayouts(rt);
}
test "slots2 spill OOM rollback restores inline representation" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const object = try Object.createPlainObjectReserved2(rt, null);
    const names = [_][]const u8{ "m_oom_0", "m_oom_1", "m_oom_2" };
    var atoms: [names.len]atom.Atom = undefined;
    for (names, 0..) |name, index| atoms[index] = try rt.internAtom(name);
    for (atoms[0..2], 0..) |name, index| {
        try object.defineOwnProperty(
            rt,
            name,
            descriptor.Descriptor.data(JSValue.int32(@intCast(index)), .all),
        );
    }
    try std.testing.expect(object.propertyStorageIsInline());

    const spill_bytes = @sizeOf(property.Entry) * shape.propertyCapacityForNeeded(3);
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes + spill_bytes);
    try std.testing.expectError(
        error.OutOfMemory,
        object.defineOwnProperty(rt, atoms[2], descriptor.Descriptor.data(JSValue.int32(2), .all)),
    );
    rt.setNativeBytesLimitForTest(null);

    try std.testing.expect(object.propertyStorageIsInline());
    try std.testing.expectEqual(@as(u32, 2), object.shape_ref.prop_count);
    try std.testing.expectEqual(@as(?i32, 0), (try object.getProperty(atoms[0])).as(.int));
    try std.testing.expectEqual(@as(?i32, 1), (try object.getProperty(atoms[1])).as(.int));
    try rt.gc.verifyObjectPropertyStorageLayouts(rt);
}
test "deleteProperty reports OOM instead of a non-configurable property" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const list = try Object.createArray(rt, null);
    for (0..3) |index| try std.testing.expect(try list.appendDenseArrayIndex(rt, @intCast(index), atom.Atom.taggedInt(@intCast(index)), JSValue.int32(@intCast(index))));
    try std.testing.expect(list.flags.fast_array);

    // Deleting a dense element first converts the elements to properties.
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, list.deleteProperty(rt, atom.Atom.taggedInt(1)));
    rt.setNativeBytesLimitForTest(null);

    try std.testing.expect(try list.deleteProperty(rt, atom.Atom.taggedInt(1)));
    try std.testing.expect(!list.hasProperty(atom.Atom.taggedInt(1)));
    try std.testing.expectEqual(@as(?i32, 2), (try list.getProperty(atom.Atom.taggedInt(2))).as(.int));
    try std.testing.expectEqual(@as(u32, 3), list.arrayLength());
}
test "plain objects do not allocate class payload storage" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const object = try Object.create(rt, class.ids.object, null);

    try std.testing.expectEqual(null, object.payloadArm().*);
    try std.testing.expectEqual(class.PayloadKind.none, object.flags.class_payload_kind);
    try std.testing.expect(Object.objectBodyBytes(class.ids.object, false) <= Object.post_a_object_size_baseline / 2);
}
test "iterator classes store iterator state in class payload" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const iterator = try Object.create(rt, class.ids.array_iterator, null);

    try std.testing.expect(iterator.payloadArm().* != null);
    iterator.iteratorIndexSlot().* = 7;
    iterator.iteratorKindSlot().* = 3;
    try std.testing.expectEqual(@as(usize, 7), iterator.iteratorIndexSlot().*);
    try std.testing.expectEqual(@as(u8, 3), iterator.iteratorKindSlot().*);
}
test "collection classes store entries in class payload" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const map = try Object.create(rt, class.ids.map, null);

    try std.testing.expect(map.payloadArm().* != null);
    try map.collectionEntriesSlot().append(rt.nativeAllocator(), .{ .key = JSValue.int32(1), .value = JSValue.int32(2), .active = true });
    try std.testing.expectEqual(@as(usize, 1), map.collectionEntries().len);
    try std.testing.expectEqual(@as(i32, 1), map.collectionEntries()[0].key.as(.int).?);
    try std.testing.expectEqual(@as(i32, 2), map.collectionEntries()[0].value.as(.int).?);
}
test "buffer and typed array state use payload storage" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const buffer = try Object.create(rt, class.ids.array_buffer, null);
    try std.testing.expect(buffer.payloadArm().* != null);
    try std.testing.expectEqual(class.PayloadKind.buffer, buffer.flags.class_payload_kind);
    const bytes = try rt.allocNative(u8, 3);
    @memset(bytes, 9);
    try buffer.installByteStorage(rt, bytes);
    buffer.arrayBufferMaxByteLengthSlot().* = 8;
    try std.testing.expectEqual(@as(usize, 3), buffer.byteStorage().len);
    try std.testing.expectEqual(@as(u8, 9), buffer.byteStorage()[0]);
    try std.testing.expectEqual(@as(?usize, 8), buffer.arrayBufferMaxByteLength());

    const view = try Object.create(rt, class.ids.object, null);
    try view.initTypedArrayView(rt, buffer.value(), 1, 2, 1, .int16);
    try std.testing.expect(view.payloadArm().* != null);
    try std.testing.expectEqual(class.PayloadKind.typed_array, view.flags.class_payload_kind);
    try std.testing.expect(view.typedArrayBuffer() != null);
    try std.testing.expectEqual(@as(usize, 1), view.typedArrayByteOffset());
    try std.testing.expectEqual(@as(u32, 2), view.typedArrayElementSize());
    try std.testing.expectEqual(@as(?u32, 1), view.typedArrayFixedLength());
    try std.testing.expectEqual(typed_array_names.Kind.int16, view.typedArrayKind());
}
test "shared buffer store reports external memory for its owner runtime" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const byte_length: usize = 4096;
    const account_before = rt.allocation_diagnostics.allocated_bytes;
    const store = try SharedBufferStore.create(rt, byte_length);
    try std.testing.expectEqual(byte_length, rt.gcStats().external_bytes);
    // Shared bytes use the process page allocator, so unlike ordinary
    // ArrayBuffer backing they are outside the runtime's allocation account
    // and rely on the external-pressure path for major pacing. The token
    // registry's small bookkeeping allocation is still charged there; pin that it is
    // metadata rather than another byte-for-byte backing charge.
    try std.testing.expect(rt.allocation_diagnostics.allocated_bytes < account_before + byte_length);
    const debt_after_alloc = rt.gcStats().allocation_debt;

    store.release();
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_token_count);
    // Debt is cumulative allocation work since the last major, not current
    // live external bytes. The live ledger above is the symmetric one.
    try std.testing.expectEqual(debt_after_alloc, rt.gcStats().allocation_debt);
}
test "regexp internals use inline storage and lastIndex uses first shape slot" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const source = try string.String.createAscii(rt, "a+");

    const regexp = try Object.createWithOwnPropertyCapacity(rt, class.ids.regexp, null, 1);

    try std.testing.expectEqual(class.PayloadKind.regexp, regexp.flags.class_payload_kind);
    try regexp.initializeRegExpLastIndex(rt);
    try regexp.setRegexpSource(rt, source.value());
    try regexp.setRegexpCompiledBytecode(rt, &.{ 1, 2, 3 });
    try regexp.defineOwnProperty(
        rt,
        atom.ids.lastIndex,
        descriptor.Descriptor.data(JSValue.int32(3), .none),
    );

    try std.testing.expect(regexp.regexpSource() != null);
    try std.testing.expectEqual(@as(usize, 3), regexp.regexpCompiledBytecode().len);
    try std.testing.expectEqual(atom.ids.lastIndex, regexp.propAtomAt(0));
    try std.testing.expectEqual(@as(?i32, 3), regexp.regexpLastIndex().?.as(.int));
    try std.testing.expect(!regexp.regexpLastIndexWritable());
}
test "bound function state uses payload storage" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const bound = try Object.create(rt, class.ids.bound_function, null);

    try std.testing.expect(bound.payloadArm().* != null);
    try std.testing.expectEqual(class.PayloadKind.bound_function, bound.flags.class_payload_kind);
    bound.boundTargetSlot().* = JSValue.int32(11);
    bound.boundThisSlot().* = JSValue.int32(22);
    // TGC S4-c: the bound-argument array is a subordinate `.payload` GC cell,
    // so the fixture has to mint one -- a raw buffer installed here would sit
    // behind a `storageCell` edge with no collector prefix.
    const args = try Object.createPayloadSliceCell(rt, JSValue, 2);
    args[0] = JSValue.int32(33);
    args[1] = JSValue.int32(44);
    bound.boundArgsSlot().* = args;

    try std.testing.expectEqual(@as(?i32, 11), bound.boundTarget().?.as(.int));
    try std.testing.expectEqual(@as(?i32, 22), bound.boundThis().?.as(.int));
    try std.testing.expectEqual(@as(usize, 2), bound.boundArgs().len);
    try std.testing.expectEqual(@as(?i32, 33), bound.boundArgs()[0].as(.int));
    try std.testing.expectEqual(@as(?i32, 44), bound.boundArgs()[1].as(.int));
}
test "proxy state uses payload storage" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const proxy = try Object.create(rt, class.ids.proxy, null);
    try proxy.ensureProxyPayload(rt);

    try std.testing.expect(proxy.payloadArm().* != null);
    try std.testing.expectEqual(class.PayloadKind.proxy, proxy.flags.class_payload_kind);
    proxy.proxyTargetSlot().* = JSValue.int32(55);
    proxy.proxyHandlerSlot().* = JSValue.int32(66);

    try std.testing.expectEqual(@as(?i32, 55), proxy.proxyTarget().?.as(.int));
    try std.testing.expectEqual(@as(?i32, 66), proxy.proxyHandler().?.as(.int));
}
test "mapped arguments state uses inline var-ref storage" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const arguments = try Object.create(rt, class.ids.mapped_arguments, null);

    try std.testing.expectEqual(class.PayloadKind.none, arguments.flags.class_payload_kind);
    const refs = try arguments.allocateMappedArgumentsVarRefsAssumingEmpty(rt, 2);
    refs[0] = try var_ref_mod.VarRef.createClosed(rt, JSValue.int32(77));
    refs[1] = try var_ref_mod.VarRef.createClosed(rt, JSValue.int32(88));

    try std.testing.expectEqual(@intFromPtr(refs.ptr), @intFromPtr(arguments.arrayArm().*.values));
    try std.testing.expect(arguments.externalClassPayload() == null);
    try std.testing.expectEqual(@as(usize, 2), arguments.argumentsVarRefs().len);
    try std.testing.expectEqual(@as(?i32, 77), arguments.argumentsVarRefs()[0].?.varRefValue().as(.int));
    try std.testing.expectEqual(@as(?i32, 88), arguments.argumentsVarRefs()[1].?.varRefValue().as(.int));
}
test "object data state uses payload storage" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const object = try Object.create(rt, class.ids.string, null);

    const data = try string.String.createAscii(rt, "wrapped");

    try std.testing.expect(object.payloadArm().* != null);
    try std.testing.expectEqual(class.PayloadKind.object_data, object.flags.class_payload_kind);
    object.objectDataSlot().* = data.value();
    try std.testing.expect(object.objectData() != null);
}
test "array element state uses inline fast-array storage" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const dense = try Object.createArray(rt, null);

    try std.testing.expectEqual(@as(u32, 0), dense.arrayArm().*.count);
    try std.testing.expectEqual(@as(u32, 0), dense.arrayArm().*.capacity);
    try std.testing.expectEqual(class.PayloadKind.none, dense.flags.class_payload_kind);
    try std.testing.expect(dense.flags.fast_array);
    try std.testing.expectEqual(ArrayStorageMode.dense, dense.arrayElementStorageMode());
    try std.testing.expect(try dense.appendDenseArrayIndex(rt, 0, atom.Atom.taggedInt(0), JSValue.int32(7)));
    try std.testing.expectEqual(@as(usize, 1), dense.arrayElements().len);
    try std.testing.expectEqual(@as(?i32, 7), dense.arrayElements()[0].as(.int));
}
test "promise state uses payload storage" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const promise = try Object.create(rt, class.ids.promise, null);

    try std.testing.expect(promise.payloadArm().* != null);
    try std.testing.expectEqual(class.PayloadKind.promise, promise.flags.class_payload_kind);
    try promise.setPromiseResult(rt, JSValue.int32(101));
    promise.promiseIsRejectedSlot().* = true;

    try std.testing.expectEqual(@as(?i32, 101), promise.promiseResult().?.as(.int));
    try std.testing.expect(promise.promiseIsRejected());
}
test "generator state uses payload storage" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const generator = try Object.create(rt, class.ids.generator, null);

    try std.testing.expect(generator.payloadArm().* != null);
    try std.testing.expectEqual(class.PayloadKind.generator, generator.flags.class_payload_kind);
    generator.generatorThisSlot().* = JSValue.int32(404);
    const args = try rt.allocNative(JSValue, 1);
    args[0] = JSValue.int32(505);
    const stack_values = try rt.allocNative(JSValue, 1);
    stack_values[0] = JSValue.int32(606);
    var replacement = SuspendedExecutionStorage{
        .stack = .{ .values = stack_values },
        .frame = .{ .args = args },
    };
    generator.generatorExecutionStateSlot().replaceStorageOwned(12, std.math.maxInt(u32), &replacement, rt);
    try std.testing.expect(replacement.isEmpty());
    generator.generatorDoneSlot().* = true;
    generator.generatorExecutingSlot().* = true;
    generator.generatorStartedSlot().* = true;
    generator.generatorJustYieldedSlot().* = true;

    try std.testing.expectEqual(@as(?i32, 404), generator.generatorThis().?.as(.int));
    try std.testing.expectEqual(@as(usize, 1), generator.generatorArgs().len);
    try std.testing.expectEqual(@as(?i32, 505), generator.generatorArgs()[0].as(.int));
    try std.testing.expectEqual(@as(usize, 12), generator.generatorPc());
    try generator.generatorExecutionStateSlot().storage.stack.ensureAdditionalWithResidentBacking(rt, 8, 1, false);
    try std.testing.expectEqual(@as(?i32, 606), generator.generatorExecutionState().storage.stack.values[0].as(.int));
    var moved: SuspendedExecutionStorage = .{};
    generator.generatorExecutionStateSlot().storage.moveInto(&moved);
    defer moved.deinit(rt);
    try std.testing.expect(generator.generatorExecutionState().storage.isEmpty());
    try std.testing.expectEqual(@as(usize, 12), generator.generatorPc());
    try std.testing.expectEqual(@as(?i32, 606), moved.stack.values[0].as(.int));
    try std.testing.expect(generator.generatorDone());
    try std.testing.expect(generator.generatorExecuting());
    try std.testing.expect(generator.generatorStarted());
    try std.testing.expect(generator.generatorJustYielded());
}
test "generator bound and proxy payloads carry no realm compensation" {
    try std.testing.expect(!@hasField(GeneratorPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(GeneratorPayload, "borrowed_holder_index_lo"));
    try std.testing.expect(!@hasField(GeneratorPayload, "borrowed_holder_index_mid"));
    try std.testing.expect(!@hasField(GeneratorPayload, "borrowed_holder_index_hi"));
    try std.testing.expect(!@hasField(BoundFunctionPayload, "realm_global"));
    try std.testing.expect(!@hasField(BoundFunctionPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(ProxyPayload, "realm_global_ptr"));
}
test "leaf noncarrier payloads carry no borrowed realm compensation" {
    try std.testing.expect(!@hasField(OrdinaryPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(ObjectDataPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(OrdinaryPayload, "typed_array_array_buffer_prototype"));
    try std.testing.expect(!@hasField(FunctionRarePayload, "primitive_prototypes"));
    try std.testing.expect(!@hasField(FunctionRarePayload, "realm_type_error_constructor"));
    try std.testing.expect(!@hasField(BufferPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(ArgumentsPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(VarRefPayload, "realm_global_ptr"));
    try std.testing.expectEqual(class.PayloadKind.none, class.standardPayloadKind(class.ids.module_ns));
    try std.testing.expect(!@hasField(PromisePayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(WeakRefPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(RegExpPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(TypedArrayPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(IteratorPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(CollectionPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(DisposableStackPayload, "realm_global_ptr"));
}
test "object payloads carry no private-name remap side tables" {
    try std.testing.expect(!@hasField(OrdinaryPayload, "private_remap_from"));
    try std.testing.expect(!@hasField(OrdinaryPayload, "private_remap_to"));
    try std.testing.expect(!@hasField(FunctionRarePayload, "private_remap_from"));
    try std.testing.expect(!@hasField(FunctionRarePayload, "private_remap_to"));
    try std.testing.expect(!@hasField(FunctionRarePayload, "super_constructor"));
}
