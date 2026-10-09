//! Shared object-property wrappers, property-key conversion, and object checks.
//!
//! Object/value inputs are borrowed; values surviving allocation need traced
//! slots, and property writes follow the core Object barrier contract.
//! Property-key conversion roots materialized strings and owns its temporary
//! byte buffer locally. Observable VM/proxy dispatch remains in the
//! higher property modules; these helpers map to QuickJS's generic property
//! operations around quickjs.c.

const builtin = @import("builtin");
const std = @import("std");
const core = @import("../core/root.zig");
const value_ops = @import("value_ops.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("exception_ops.zig");
const ensureVarRefsCapacity = frame_mod.ensureVarRefsCapacity;
const globalLexicalValueForGlobal = call_runtime.globalLexicalValueForGlobal;
const handleCatchableRuntimeError = call_runtime.handleCatchableRuntimeError;
const throwTdzReferenceError = exception_ops.throwTdzReferenceError;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const op = bytecode.opcode.op;

pub fn defineDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, .all));
}

pub fn getPropertyValue(value: core.JSValue, atom_id: core.Atom) !core.JSValue {
    const object_value = try expectObject(value);
    return try object_value.getProperty(atom_id);
}

pub fn propertyIn(rt: *core.JSRuntime, object_value: core.JSValue, key_value: core.JSValue) !core.JSValue {
    var values = [_]core.JSValue{ object_value, key_value };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    _ = try expectObject(values[0]);
    const key = try propertyKeyAtom(rt, values[1]);
    const object = try expectObject(values[0]);
    return core.JSValue.boolean(object.hasProperty(key));
}

/// Allocation-free prefix of `propertyKeyAtom`: the atom when `value` is
/// already a property key that needs no interning work (a symbol, a string
/// whose atom is bound, or a non-negative int32 index); null otherwise so the
/// caller takes `propertyKeyAtom`. Keep the arms in lockstep with it.
pub fn propertyKeyAtomIfReady(value: core.JSValue) ?core.Atom {
    if (value.asSymbolAtom()) |atom_id| return atom_id;
    const flat = core.string.asFlat(value) orelse if (value.ropeBody()) |rope| rope.flatString() else null;
    if (flat) |string_value| {
        if (string_value.atom_id != core.string.String.no_atom_id) return string_value.atom_id;
        return null;
    }
    if (value.as(.int)) |index| {
        if (index >= 0) return core.Atom.taggedInt(@intCast(index));
    }
    return null;
}

pub fn propertyKeyAtom(rt: *core.JSRuntime, value: core.JSValue) !core.Atom {
    if (propertyKeyAtomIfReady(value)) |atom_id| return atom_id;
    if (value.isString()) {
        return stringPropertyKeyAtom(rt, value) catch |err| switch (err) {
            error.RootGenerationExhausted => error.OutOfMemory,
            error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex, error.ExpectedString => std.debug.panic("property key root contract: {s}", .{@errorName(err)}),
            else => |other| other,
        };
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try value_ops.appendValueString(rt, &bytes, value);
    return rt.internAtom(bytes.items);
}

fn stringPropertyKeyAtom(rt: *core.JSRuntime, value: core.JSValue) !core.Atom {
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    try source.set(rt, value);
    try core.string.ensureFlat(rt, source.readOnly(), source);
    // Flat string carriers have stable addresses. Keep the owning value live
    // across interning and publication of its cached atom.
    return core.string.asFlat(try source.get(rt)).?.internAtom(rt);
}

pub const expectObject = core.value_semantics.expectObject;

// ----- Guarded property and global fast probes -----
// Guarded property and global fast probes that cannot invoke user code.
//
// Result types state whether a returned JSValue is borrowed; helpers named
// `Owned` consume their input only after the guarded slot write commits. The
// probes validate class, shape, flags, atom kind, and exotic/proxy exclusions
// before raw storage access. Observable getters, proxies, coercion, and generic
// property semantics remain in `vm_property.zig` and `object_ops.zig`.
const bytecode = @import("../bytecode.zig");
const objectFromValue = core.value_semantics.objectFromValueTrustedExpression;
const FastOwnDataLookup = union(enum) {
    value: BorrowedOwnDataLookup,
    missing,
    slow,
};
const BorrowedOwnDataLookup = struct {
    index: usize,
    value: core.JSValue,
};
const BorrowedProtoDataLookup = struct {
    holder: *core.Object,
    index: usize,
    value: core.JSValue,
};
const BorrowedGlobalDataLookup = struct {
    index: usize,
    value: core.JSValue,
};
const FastProtoDataLookup = union(enum) {
    value: BorrowedProtoDataLookup,
    missing,
    slow,
};
const OrdinaryComputedPropertyLookup = union(enum) {
    value: core.JSValue,
    getter: core.JSValue,
    proxy: *core.Object,
    undefined,
    slow,
};
const DataSlot = struct {
    entry: *core.property.Entry,
    value: *core.JSValue,
};
pub inline fn dataPropertyValueForFastPath(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    const object = objectFromValue(receiver) orelse return null;
    if (!cacheableNamedDataObject(rt, object, atom_id)) return null;

    if (rt.atoms.kind(atom_id) == .private) return null;

    switch (fastOwnOrdinaryDataPropertyLookupForObject(object, atom_id)) {
        .value => |lookup| return lookup.value,
        .missing, .slow => {},
    }
    switch (fastImmediatePrototypeDataPropertyLookupForObject(rt, object, atom_id)) {
        .value => |lookup| return lookup.value,
        .missing, .slow => {},
    }
    return null;
}

pub fn functionOwnDataPropertyValueForFastPath(value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = functionOwnDataPropertyObject(value, atom_id) orelse return null;
    return object.getOwnDataPropertyValue(atom_id);
}

fn functionOwnDataPropertyObject(value: core.JSValue, atom_id: core.Atom) ?*core.Object {
    const object = objectFromValue(value) orelse return null;
    if (!core.class.isFunctionClass(object.class_id)) return null;
    if (atom_id == core.atom.ids.arguments or atom_id == core.atom.ids.caller) return null;
    return object;
}

test "function-like class predicate recognizes every bytecode function class" {
    const class_ids = [_]core.ClassId{
        core.class.ids.bytecode_function,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
    };
    for (class_ids) |class_id| {
        try std.testing.expect(core.class.isFunctionClass(class_id));
    }
    try std.testing.expect(!core.class.isFunctionClass(core.class.ids.object));
}

inline fn cacheableNamedDataObject(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    if (object.class_id == core.class.ids.object and
        !object.isArray() and
        !object.isGlobal() and
        !object.isProxy())
    {
        return !object.hasExoticMethods();
    }
    if (object.isProxy() or object.hasExoticMethods()) return false;
    if (object.isArray()) {
        if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(rt.atoms, atom_id) != null) return false;
    } else if (object.class_id != core.class.ids.object and !object.isGlobal() and object.class_id < core.class.ids.init_count) return false;
    return true;
}

fn fastImmediatePrototypeDataPropertyLookupForObject(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) align(32) FastProtoDataLookup {
    switch (fastOwnOrdinaryDataPropertyLookupForObject(object, atom_id)) {
        .value, .slow => return .slow,
        .missing => {},
    }
    const holder = object.getPrototype() orelse return .missing;
    if (!cacheableNamedDataObject(rt, holder, atom_id)) return .slow;
    return switch (fastOwnOrdinaryDataPropertyLookupForObject(holder, atom_id)) {
        .value => |lookup| .{ .value = .{ .holder = holder, .index = lookup.index, .value = lookup.value } },
        .missing => .missing,
        .slow => .slow,
    };
}

fn fastOwnOrdinaryDataPropertyLookupForObject(object: *core.Object, atom_id: core.Atom) FastOwnDataLookup {
    const index = object.findProperty(atom_id) orelse return .missing;
    return switch (object.propKindAt(index)) {
        .data => .{ .value = .{ .index = index, .value = object.propertyEntry(index).*.slot.data } },
        .var_ref, .auto_init, .accessor => .slow,
    };
}

pub fn ordinaryDataPropertyLookup(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) OrdinaryComputedPropertyLookup {
    if (rt.atoms.kind(atom_id) == .private) return .slow;
    var cursor = objectFromValue(value) orelse return .slow;
    while (true) {
        if (cursor.proxyTarget() != null) return .{ .proxy = cursor };
        if (cursor.hasExoticMethods()) return .slow;
        if (cursor.isArray()) {
            if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(rt.atoms, atom_id) != null) return .slow;
        } else if (cursor.class_id != core.class.ids.object and !cursor.isGlobal() and !cursor.flags.is_native_object) return .slow;
        if (cursor.findProperty(atom_id)) |index| {
            return switch (cursor.propKindAt(index)) {
                .data => .{ .value = cursor.propertyEntry(index).*.slot.data },
                .accessor => .{ .getter = cursor.propertyEntry(index).*.slot.accessor.getterValue() },
                .var_ref, .auto_init => .slow,
            };
        } else {
            cursor = cursor.getPrototype() orelse {
                if (cursor.isArray()) return .slow;
                return .undefined;
            };
        }
    }
}

pub fn ordinaryDataPropertyValueOrUndefinedForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    return switch (ordinaryDataPropertyLookup(rt, value, atom_id)) {
        .value => |property_value| property_value,
        .undefined => core.JSValue.undefinedValue(),
        .getter, .proxy, .slow => null,
    };
}

fn globalOwnDataPropertyBorrowedLookup(global: *core.Object, atom_id: core.Atom) ?BorrowedGlobalDataLookup {
    if (global.hasExoticMethods()) return null;
    for (global.shapeProps(), 0..) |prop, index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.kind != .data) return null;
        return .{ .index = index, .value = global.propertyEntry(index).*.slot.data };
    }
    return null;
}

/// get_var fast path: the global's own data property value, if it has one.
pub fn globalOwnDataPropertyValue(global: *core.Object, atom_id: core.Atom) ?core.JSValue {
    const lookup = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    return lookup.value;
}

/// put_var fast path: store into the global's own writable data property
/// unless a global lexical binding shadows it. False leaves the slow path.
pub fn setGlobalWritableDataProperty(
    rt: *core.JSRuntime,
    lexicals: ?*core.Object,
    global: *core.Object,
    atom_id: core.Atom,
    new_value: core.JSValue,
) bool {
    if (lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return false;
    }
    const lookup = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return false;
    return setGlobalOwnWritableDataPropertyAt(rt, global, lookup.index, atom_id, new_value);
}

fn setGlobalOwnWritableDataPropertyAt(rt: *core.JSRuntime, global: *core.Object, index: usize, atom_id: core.Atom, new_value: core.JSValue) bool {
    const slot = writableDataSlotAt(global, index, atom_id) orelse return false;
    slot.entry.slot = .{ .data = new_value };
    // Updating an existing global var is a heap store like any other: the
    // global object is long-lived, so a fresh value stored into it is an
    // old-to-young edge the minor cannot see without the remembered set.
    rt.gc.generationalBarrier(global.gcHeader(), new_value.cycleMarkHeader());
    return true;
}

fn writableDataSlotAt(object: *core.Object, index: usize, atom_id: core.Atom) ?DataSlot {
    const slot = dataSlotAt(object, index, atom_id) orelse return null;
    if (!object.propFlagsAt(index).writable) return null;
    return slot;
}

fn dataSlotAt(object: *core.Object, index: usize, atom_id: core.Atom) ?DataSlot {
    if (object.hasExoticMethods() or index >= object.shapeProps().len) return null;
    const prop = object.shapeProps()[index];
    const prop_flags = core.property.Flags.fromBits(prop.flags);
    if (prop.atom_id != atom_id or prop_flags.deleted or prop_flags.kind != .data) return null;
    const entry = object.propertyEntry(index);
    return .{ .entry = entry, .value = &entry.slot.data };
}

test "global own data slot helpers read and write through the global's own data property" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);

    const key = try rt.internAtom("globalSlotAdapter");
    const other_key = try rt.internAtom("globalSlotOther");

    const initial = try core.string.String.createAscii(rt, "initial");
    try global.defineOwnProperty(rt, key, core.Descriptor.data(initial.value(), .all));

    try std.testing.expectEqual(initial.header(), globalOwnDataPropertyValue(global, key).?.stringHeader().?);
    try std.testing.expect(globalOwnDataPropertyValue(global, other_key) == null);
    try std.testing.expect(!setGlobalWritableDataProperty(rt, null, global, other_key, core.JSValue.int32(1)));

    // A global lexical binding of the same name shadows the property.
    const lexicals = try core.Object.create(rt, core.class.ids.object, null);
    try lexicals.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(7), .all));
    const shadowed = try core.string.String.createAscii(rt, "shadowed");
    try std.testing.expect(!setGlobalWritableDataProperty(rt, lexicals, global, key, shadowed.value()));
    try std.testing.expectEqual(initial.header(), globalOwnDataPropertyValue(global, key).?.stringHeader().?);

    const stored = try core.string.String.createAscii(rt, "stored");
    try std.testing.expect(setGlobalWritableDataProperty(rt, null, global, key, stored.value()));
    try std.testing.expectEqual(stored.header(), globalOwnDataPropertyValue(global, key).?.stringHeader().?);
}

test "global own data slot helpers reject readonly and accessor writes" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);

    const readonly_key = try rt.internAtom("readonlyGlobalSlot");
    const accessor_key = try rt.internAtom("accessorGlobalSlot");

    try global.defineOwnProperty(rt, readonly_key, core.Descriptor.data(core.JSValue.int32(1), .{ .enumerable = true, .configurable = true }));
    try std.testing.expect(!setGlobalWritableDataProperty(rt, null, global, readonly_key, core.JSValue.int32(2)));
    try std.testing.expectEqual(@as(?i32, 1), globalOwnDataPropertyValue(global, readonly_key).?.as(.int));

    const getter = try core.Object.create(rt, core.class.ids.object, null);
    const setter = try core.Object.create(rt, core.class.ids.object, null);
    try global.defineOwnProperty(rt, accessor_key, core.Descriptor.accessor(getter.value(), setter.value(), .{ .enumerable = true, .configurable = true }));
    try std.testing.expect(globalOwnDataPropertyValue(global, accessor_key) == null);
    try std.testing.expect(!setGlobalWritableDataProperty(rt, null, global, accessor_key, core.JSValue.int32(3)));
}

// ----- Local, argument, var-ref and global-lexical slots -----
// Local, argument, var-ref and global-lexical slot operations shared between the VM and call runtime.
pub fn execGetLoc(
    _: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    // No runtime bounds check: `resolve_variables` only emits get_loc with
    // idx < var_count, and `frame.locals` is sized to exactly var_count
    // (vm_opcodes.initFrameLocals). idx < var_count == frame.locals.len holds for
    // every dispatched frame — the same trusted-compiler model as QuickJS's
    // bare `var_buf[idx]`. The stack is pre-sized (reserveEntryFrameCapacity),
    // so the push skips reserveAdditional, mirroring qjs's `*sp++`.
    stack.pushAssumeCapacity(frame.locals[idx]);
}

pub noinline fn execPutLoc(
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    // idx < var_count == frame.locals.len by construction (see execGetLoc).
    const value = try stack.pop();
    frame.locals[idx] = value;
}

pub fn execSetLoc(
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    // idx < var_count == frame.locals.len by construction (see execGetLoc).
    // set_loc leaves the operand on the stack; borrow it and let the
    // ValueSlot take exactly one retained reference.
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    frame.locals[idx] = value;
}

pub fn execGetArg(
    _: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.args.len) {
        try stack.pushOwned(core.JSValue.undefinedValue());
        return;
    }
    const owned = frame.args[idx];
    try stack.pushOwned(owned);
}

pub fn execPutArg(
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.args.len) return error.InvalidBytecode;
    const value = try stack.pop();
    frame.args[idx] = value;
}

pub fn execSetArg(
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.args.len) return error.InvalidBytecode;
    // set_arg has the same non-consuming ownership contract as set_loc.
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    frame.args[idx] = value;
}

pub fn execGetVarRefMaybeTdz(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    catch_target: *?usize,
    global: *core.Object,
) !bool {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    if (idx < function.varRefNamesLen()) {
        const atom_id = function.varRefName(idx);
        // Only a genuine top-level global_decl var-ref (qjs JS_CLOSURE_GLOBAL_DECL)
        // reads through the global lexical cell by name. A captured block/loop
        // lexical (.ref/.local) that merely shares a name must fall through to the
        // real frame.var_refs cell below so its TDZ check is honored — otherwise a
        // same-named outer top-level `let` shadows the captured per-iteration TDZ slot.
        const is_global_decl_ref = function.varRefIsGlobalDeclAt(idx);
        if (is_global_decl_ref) {
            if (globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| {
                if (lexical_value.is(.uninitialized)) {
                    const err = throwTdzReferenceError(ctx, atom_id);
                    if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
                        return true;
                    }
                    return err;
                }
                try stack.pushOwned(lexical_value);
                return false;
            }
        }
        if (call_runtime.closureVarIsNonLexicalGlobalSentinel(function, idx)) {
            const value = try global.getProperty(atom_id);
            try stack.pushOwned(value);
            return false;
        }
    }
    // Slot is a cell by type (qjs OP_get_var_ref_check, quickjs.c);
    // the pre-typed raw-slot arm is gone with the type flip.
    const cell = varRefSlotCell(frame, idx);
    const value = cell.varRefValue();
    if (value.is(.uninitialized)) {
        // A deletable cell parked at UNINITIALIZED is a deleted
        // eval-created binding (qjs remove_global_object_property):
        // plain ReferenceError, not the TDZ message.
        if (cell.varRefIsDeletableSlot().*) {
            const name = if (idx < function.varRefNamesLen()) function.varRefName(idx) else core.atom.null_atom;
            const err = if (exception_ops.throwReferenceErrorNotDefined(ctx, global, name)) |_| unreachable else |e| e;
            if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
                return true;
            }
            return err;
        }
        // Captured derived `this` uses ordinary get_var_ref_check in QuickJS,
        // so it remains catchable in the current (callee) realm while keeping
        // the constructor-specific message.
        const err = if (idx < function.varRefNamesLen() and function.varRefName(idx) == core.atom.ids.this_) blk: {
            _ = exception_ops.throwReferenceErrorMessage(ctx, global, exception_ops.msg_derived_this_uninitialized) catch |err| break :blk err;
            unreachable;
        } else throwTdzReferenceError(ctx, if (idx < function.varRefNamesLen()) function.varRefName(idx) else core.atom.null_atom);
        if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
            return true;
        }
        return err;
    }
    try stack.push(value);
    return false;
}

pub fn execPutVarRef(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    const value = try stack.pop();
    // Slot is a cell by type (qjs OP_put_var_ref set_value into
    // var_refs[idx]->pvalue, quickjs.c); the raw-slot arm — including
    // its global-lexical/sentinel fallbacks, which post phase-B could never
    // execute (every slot was already a cell) — is deleted with the type.
    const cell = varRefSlotCell(frame, idx);
    if (opc == op.put_var_ref_check_init) {
        const current = cell.varRefValue();
        if (!current.is(.uninitialized)) {
            // Derived `this` captured by an arrow: a second super() call.
            const name = if (idx < function.varRefNamesLen()) function.varRefName(idx) else core.atom.null_atom;
            const message = if (name == core.atom.ids.this_) "'this' can be initialized only once" else "binding is already initialized";
            _ = try exception_ops.throwReferenceErrorMessage(ctx, global, message);
            unreachable;
        }
    }
    if (opc == op.put_var_ref_check) {
        const current = cell.varRefValue();
        if (current.is(.uninitialized)) {
            return throwTdzReferenceError(ctx, if (idx < function.varRefNamesLen()) function.varRefName(idx) else core.atom.null_atom);
        }
    }
    const capture_is_function_name = idx < function.closureVar().len and
        function.closureVar()[idx].varKind() == .function_name;
    const capture_is_const = idx < function.closureVar().len and
        function.closureVar()[idx].isConst();
    if (cell.varRefIsFunctionNameSlot().* or capture_is_function_name) {
        if (function.isStrictMode()) {
            _ = try throwTypeErrorMessage(ctx, global, "invalid assignment to function name");
            unreachable;
        }
        return;
    }
    if ((cell.varRefIsConstSlot().* or capture_is_const) and !isVarRefInitOpcode(opc)) {
        return exception_ops.throwInvalidConstVariable(ctx, global);
    }
    const assigned = adapterValueBorrow(value);
    cell.setVarRefValue(ctx.runtime, assigned);
}

fn isVarRefInitOpcode(opc: u8) bool {
    return opc == op.put_var_ref or
        opc == op.put_var_ref_check_init or
        opc == op.put_var_ref0 or
        opc == op.put_var_ref1 or
        opc == op.put_var_ref2 or
        opc == op.put_var_ref3;
}

pub fn execSetVarRef(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    _ = opc;
    const value = stack.peek() orelse return error.StackUnderflow;
    replaceVarRefValueOwned(ctx, frame, idx, value);
}

pub fn adapterValueBorrow(slot: core.JSValue) callconv(.c) core.JSValue {
    // Terminal-state invariant: a cell's VALUE is never itself a cell — the
    // last nesting producer (the direct-eval const view) now pvalue-aliases
    // its target (eval_entry.directEvalOuterVarRefView) — so ONE unwrap reaches
    // the plain value (qjs bare `*var_ref->pvalue`, quickjs.c).
    const cell = varRefCellFromValue(slot) orelse return slot;
    const value = cell.varRefValue();
    if (comptime builtin.mode == .Debug) {
        std.debug.assert(varRefCellFromValue(value) == null);
    }
    return value;
}

pub fn adapterValueIsUninitialized(slot: core.JSValue) bool {
    return adapterValueBorrow(slot).is(.uninitialized);
}

/// Replace an owned JSValue Adapter slot. This cold boundary accepts a VarRef
/// handle on either side and preserves its
/// write-through semantics. It must not be used for frame locals or arguments.
pub inline fn replaceAdapterOwned(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) void {
    if (!slot.isTracerOwned() and !value.isTracerOwned()) {
        slot.* = value;
        return;
    }
    replaceAdapterHeapValue(ctx, slot, value);
}

noinline fn replaceAdapterHeapValue(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) void {
    const assigned = adapterValueBorrow(value);
    if (varRefCellFromValue(slot.*)) |cell| {
        cell.setVarRefValue(ctx.runtime, assigned);
        return;
    }
    slot.* = assigned;
}

pub fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef {
    return core.VarRef.fromValue(value);
}

/// `frame.var_refs[idx]`: every slot is a live closure cell.
pub inline fn varRefSlotCell(frame: *const frame_mod.Frame, idx: usize) *core.VarRef {
    return frame.var_refs[idx];
}

/// Write-through store into the slot's cell (qjs OP_put_var_ref
/// `set_value(ctx, var_refs[idx]->pvalue,...)`, quickjs.c). Preserves
/// the Adapter replacement unwrap: an incoming cell VALUE is dereferenced
/// before the store so cell values never nest through writes.
inline fn replaceVarRefValueOwned(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize, value: core.JSValue) void {
    const assigned = adapterValueBorrow(value);
    frame.var_refs[idx].setVarRefValue(ctx.runtime, assigned);
}
