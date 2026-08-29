//! Deterministic, reviewable snapshot of the GC/object representation.
//!
//! This is a tooling/test module, not an engine dependency.  The production
//! compile-time guards remain next to their owning structs; this module turns
//! the same facts into text so representation work has an explicit diff.

const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;
const gc = core.gc;

fn boolText(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn kindContract(comptime kind: gc.GcKind) []const u8 {
    const heap_descriptor = gc.refKindDescriptor(kind);
    const descriptor = gc.representationKindDescriptor(kind);
    return std.fmt.comptimePrint(
        "kind.{s} tag={d} prefix={s} allocation={s} registry={s} rc={s}\n",
        .{
            @tagName(kind),
            @intFromEnum(kind),
            @tagName(descriptor.prefix),
            @tagName(descriptor.allocation),
            boolText(heap_descriptor.cycle_candidate),
            @tagName(descriptor.ref_count),
        },
    );
}

fn objectLayout() []const u8 {
    return std.fmt.comptimePrint(
        "object size={d} align={d} header={d} weakref_count={d} class_id={d} flags={d} shape_ref={d} prop_values={d} u={d}\n",
        .{ @sizeOf(core.Object), @alignOf(core.Object), @offsetOf(core.Object, "header"), @offsetOf(core.Object, "weakref_count"), @offsetOf(core.Object, "class_id"), @offsetOf(core.Object, "flags"), @offsetOf(core.Object, "shape_ref"), @offsetOf(core.Object, "prop_values"), @offsetOf(core.Object, "u") },
    );
}

fn functionBytecodeLayout() []const u8 {
    return std.fmt.comptimePrint(
        "function_bytecode size={d} align={d} header={d} js_mode={d} byte_code={d} byte_code_len={d} vardefs={d} closure_var={d} realm={d} cpool={d}\n",
        .{ @sizeOf(core.FunctionBytecode), @alignOf(core.FunctionBytecode), @offsetOf(core.FunctionBytecode, "header"), @offsetOf(core.FunctionBytecode, "js_mode"), @offsetOf(core.FunctionBytecode, "byte_code"), @offsetOf(core.FunctionBytecode, "byte_code_len"), @offsetOf(core.FunctionBytecode, "vardefs"), @offsetOf(core.FunctionBytecode, "closure_var"), @offsetOf(core.FunctionBytecode, "realm"), @offsetOf(core.FunctionBytecode, "cpool") },
    );
}

fn varRefLayout() []const u8 {
    return std.fmt.comptimePrint(
        "var_ref size={d} align={d} header={d} value={d} pvalue={d} is_const={d} is_open={d}\n",
        .{ @sizeOf(core.VarRef), @alignOf(core.VarRef), @offsetOf(core.VarRef, "header"), @offsetOf(core.VarRef, "value"), @offsetOf(core.VarRef, "pvalue"), @offsetOf(core.VarRef, "is_const"), @offsetOf(core.VarRef, "is_open") },
    );
}

fn realmLayout() []const u8 {
    return std.fmt.comptimePrint(
        "realm_context size={d} align={d} header={d} runtime={d} publication_state={d} modules={d} global={d} trace_rc=2164 list_prev=2168\n",
        .{ @sizeOf(core.JSContext), @alignOf(core.JSContext), @offsetOf(core.JSContext, "header"), @offsetOf(core.JSContext, "runtime"), @offsetOf(core.JSContext, "publication_state"), @offsetOf(core.JSContext, "modules"), @offsetOf(core.JSContext, "global") },
    );
}

fn moduleLayout() []const u8 {
    return std.fmt.comptimePrint(
        "module size={d} align={d} header={d} registry_prev={d} registry={d} memory={d} module_name={d} requests={d} func_obj={d} module_ns={d}\n",
        .{ @sizeOf(core.ModuleRecord), @alignOf(core.ModuleRecord), @offsetOf(core.ModuleRecord, "header"), @offsetOf(core.ModuleRecord, "registry_prev"), @offsetOf(core.ModuleRecord, "registry"), @offsetOf(core.ModuleRecord, "memory"), @offsetOf(core.ModuleRecord, "module_name"), @offsetOf(core.ModuleRecord, "requests"), @offsetOf(core.ModuleRecord, "func_obj"), @offsetOf(core.ModuleRecord, "module_ns") },
    );
}

fn shapeLayout() []const u8 {
    return std.fmt.comptimePrint(
        "shape size={d} align={d} header={d} list_prev={d} ownership={d} hash={d} prop_hash_mask={d} prop_size={d} prop_count={d} registry_hash_next={d} proto={d} fam={d}\n",
        .{ @sizeOf(core.Shape), @alignOf(core.Shape), @offsetOf(core.Shape, "header"), @offsetOf(core.Shape, "trace_list_previous"), @offsetOf(core.Shape, "ownership"), @offsetOf(core.Shape, "hash"), @offsetOf(core.Shape, "prop_hash_mask"), @offsetOf(core.Shape, "prop_size"), @offsetOf(core.Shape, "prop_count"), @offsetOf(core.Shape, "registry_hash_next"), @offsetOf(core.Shape, "proto"), @sizeOf(core.Shape) },
    );
}

fn stringLayouts() []const u8 {
    return std.fmt.comptimePrint(
        "string_flat size={d} align={d} rc_prefix={d} len_meta={d} hash_meta={d} atom_id={d} fam={d}\n" ++
            "string_rope size={d} align={d} rc_prefix={d} left={d} right={d} rt={d} len={d} depth={d} wide={d} flags={d}\n",
        .{
            @sizeOf(core.string.String),                @alignOf(core.string.String),              core.gc.string_rc_prefix_size,              @offsetOf(core.string.String, "len_meta"), @offsetOf(core.string.String, "hash_meta"), @offsetOf(core.string.String, "atom_id"), @sizeOf(core.string.String),
            @sizeOf(core.string.StringRope),            @alignOf(core.string.StringRope),          core.string.StringRope.rc_prefix_size,      @offsetOf(core.string.StringRope, "left"), @offsetOf(core.string.StringRope, "right"), @offsetOf(core.string.StringRope, "rt"),  @offsetOf(core.string.StringRope, "len"),
            @offsetOf(core.string.StringRope, "depth"), @offsetOf(core.string.StringRope, "wide"), @offsetOf(core.string.StringRope, "flags"),
        },
    );
}

fn bigIntLayout() []const u8 {
    return std.fmt.comptimePrint(
        "big_int size={d} align={d} header={d} limbs_ptr={d} allocator={d} len={d} capacity={d} flags={d} fam={d}\n",
        .{ @sizeOf(core.bigint.BigInt), @alignOf(core.bigint.BigInt), @offsetOf(core.bigint.BigInt, "header"), @offsetOf(core.bigint.BigInt, "limbs_ptr"), @offsetOf(core.bigint.BigInt, "allocator"), @offsetOf(core.bigint.BigInt, "len"), @offsetOf(core.bigint.BigInt, "capacity"), @offsetOf(core.bigint.BigInt, "flags"), @sizeOf(core.bigint.BigInt) },
    );
}

fn metadataLayout() []const u8 {
    return std.fmt.comptimePrint(
        "Metadata size={d} align={d} size_class={d} alloc_info={d} flags={d} lifetime={d}\n",
        .{
            @sizeOf(gc.Metadata),
            @alignOf(gc.Metadata),
            @offsetOf(gc.Metadata, "size_class"),
            @offsetOf(gc.Metadata, "alloc_info"),
            @offsetOf(gc.Metadata, "flags"),
            @offsetOf(gc.Metadata, "lifetime"),
        },
    );
}

fn activeHeaderLayout() []const u8 {
    return std.fmt.comptimePrint(
        "TraceHeader size={d} align={d} next={d}\n",
        .{ @sizeOf(gc.TraceHeader), @alignOf(gc.TraceHeader), @offsetOf(gc.TraceHeader, "next") },
    );
}

fn lifetimeSemantics() []const u8 {
    return "lifetime offset4=mark_epoch:u16+object_shape_summary:u7+remembered:u1+husk/reserved:u8 for trace carriers; Shape/Realm RC lives in body; BigInt keeps i32 rc\n";
}

pub const snapshot_text =
    "# zjs GC representation snapshot v1\n" ++
    "# generated: zig build gc-representation-snapshot\n" ++
    "# rule: update this baseline only with an owning rationale for every representation diff\n" ++
    "\n[prefix]\n" ++
    metadataLayout() ++
    activeHeaderLayout() ++
    std.fmt.comptimePrint(
        "StringHeader size={d} rc_payload_delta=-{d}\n" ++
            "AllocInfo class_mask=0x{x:0>2} large=0x{x:0>2} accounted=0x{x:0>2} standalone=0x{x:0>2}\n" ++
            "BlockFlags kind_mask=0x07 mark=0x08 young=0x10 finalizing=0x20 pinned=0x40 cycle_visited=0x80\n" ++
            "carrier block_cell_class=0x{x:0>2} slab_class_range=0..{d} standalone_class=0\n" ++
            "free_cell link_mask=0x{x:0>8} poison=0x{x:0>8} encoded_word=poison|(next&link_mask)\n",
        .{
            @sizeOf(gc.StringHeader),
            gc.ref_count_offset_from_payload,
            gc.representation.alloc_info_class_mask,
            gc.representation.alloc_info_large_mask,
            gc.representation.alloc_info_heap_accounted_mask,
            gc.representation.alloc_info_standalone_mask,
            gc.representation.block_cell_size_class,
            core.memory.SmallObjectSlab.class_count - 1,
            gc.representation.free_cell_link_mask,
            gc.representation.free_cell_poison,
        },
    ) ++
    "\n[field-semantics]\n" ++
    "size_class block-cell=cell-index; slab=allocator-block-index; standalone=encoded-heap-bytes-after-publication\n" ++
    "alloc_info.block_size_idx block-cell=0x1f; slab=0..30; standalone=0\n" ++
    "alloc_info.large valid-only-when heap_accounted; logical space class independent of physical carrier\n" ++
    "alloc_info.heap_accounted registry-publication-bit; false for string/big_int and construction shell\n" ++
    "flags.kind valid for Metadata kinds; string uses JSValue tag plus refcount-only prefix\n" ++
    "flags.mark/young/finalizing/pinned/cycle_visited valid for registry kinds only\n" ++
    lifetimeSemantics() ++
    "\n[kind-contracts]\n" ++
    kindContract(.object) ++
    kindContract(.function_bytecode) ++
    kindContract(.var_ref) ++
    kindContract(.realm_context) ++
    kindContract(.module) ++
    kindContract(.shape) ++
    kindContract(.string) ++
    kindContract(.big_int) ++
    "\n[body-layouts]\n" ++
    objectLayout() ++
    functionBytecodeLayout() ++
    varRefLayout() ++
    realmLayout() ++
    moduleLayout() ++
    shapeLayout() ++
    stringLayouts() ++
    bigIntLayout();

pub fn matchesBaseline(baseline: []const u8) bool {
    return std.mem.eql(u8, baseline, snapshot_text);
}
