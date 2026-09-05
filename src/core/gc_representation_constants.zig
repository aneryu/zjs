//! Byte-level constants shared by the allocator, GC prefix readers, block
//! heap, and the representation snapshot.  This module deliberately imports
//! nothing: `memory.zig` owns the allocator layer and must not acquire a
//! dependency on `gc.zig` merely to agree on bytes written into the prefix.

pub const metadata_size: usize = 8;
pub const metadata_size_class_offset: usize = 0;
pub const metadata_alloc_info_offset: usize = 2;
pub const metadata_flags_offset: usize = 3;
pub const metadata_lifetime_offset: usize = 4;
pub const metadata_young_mask: u8 = 1 << 4;

/// GC kind tags the allocator layer writes into the prefix by hand. Kept
/// here with the allocator representation rather than making `memory.zig`
/// import the registry enum; `gc.zig` asserts that its public RefKind
/// encoding still agrees.
pub const object_kind_tag: u8 = 0;
pub const string_kind_tag: u8 = 6;
/// TGC S4-a (D-S4-1): rope nodes are their own kind instead of a flat body
/// carrying a borrowed `mark` bit.
pub const rope_kind_tag: u8 = 11;
/// TGC S2-i / S4-b: a bare storage cell holding string code units (the
/// extensible tail buffer a rope's dependent views read). It carries no
/// out-edges and no destructor, so the allocator writes the tag and nothing
/// else ever interprets its body as a header.
pub const string_buffer_kind_tag: u8 = 12;
/// TGC S4-b: an object's external property-entry buffer (`prop_values`) and an
/// array/arguments element buffer as bare storage cells. Same contract as the
/// tail buffer above -- the allocator writes the tag, the owner's `storageCell`
/// edge marks the cell, and the bitmap/extent sweep returns it with no
/// destructor. Nothing ever reads their bodies as a header.
pub const property_storage_kind_tag: u8 = 8;
pub const array_storage_kind_tag: u8 = 9;
/// TGC S4-c: an a-class (pure-memory) object payload, and the variable-length
/// slices such a payload owns (promise reactions, bound arguments, disposable
/// resources, arguments var-refs, bytecode capture arrays). Same contract as
/// the two above: the allocator writes the tag, the owner's `storageCell` edge
/// marks the cell, and the sweep returns it with no destructor.
pub const payload_kind_tag: u8 = 10;

/// The kind occupies the low nibble of the flags byte (TGC S4-a widened it
/// from three bits into the retired `mark` bit). Raw readers of the byte
/// mask with this.
pub const kind_mask: u8 = 0x0f;

pub const alloc_info_class_mask: u8 = 0x1f;
pub const alloc_info_heap_accounted_mask: u8 = 1 << 6;
pub const alloc_info_standalone_mask: u8 = 1 << 7;

/// The saturated five-bit class value is outside the slab's real class
/// domain and therefore uniquely identifies a collector block cell.
pub const block_cell_size_class: u5 = 0x1f;
pub const block_cell_alloc_info: u8 = block_cell_size_class;

/// A freed block cell retains its successor in the low 16 bits.  The entire
/// high half is poison, chosen so reading the word as live metadata yields an
/// unaccounted, non-block prefix whose kind reads `.string` (6).  The kind is
/// not what protects the poison -- `heap_accounted` = 0 is, and it survived S2
/// joining strings to the tracer and S4-a widening the kind into bit 3 (which
/// the poison leaves clear, so the low nibble still reads 6).  Bit 7 is
/// `BlockFlags.reserved` and nothing reads it; it is kept SET only so the
/// poison byte value stays 0x86 and the allocator's free path is
/// byte-identical.  The condemnation guard is not in the free cell at all: it
/// lives in the lifetime word, which the free path never writes.
pub const free_cell_link_mask: u32 = 0x0000_ffff;
pub const free_cell_poison: u32 = 0x8600_0000;

comptime {
    if (metadata_lifetime_offset + @sizeOf(i32) != metadata_size)
        @compileError("GC metadata offsets no longer fill the eight-byte prefix");
    if (block_cell_alloc_info & alloc_info_class_mask != block_cell_size_class)
        @compileError("block-cell discriminator no longer occupies the alloc_info class field");
    if (block_cell_alloc_info & ~alloc_info_class_mask != 0)
        @compileError("block-cell discriminator must not pre-set accounting or allocation bits");
    if (free_cell_poison & free_cell_link_mask != 0)
        @compileError("free-cell poison overlaps the successor link");

    const poison_alloc_info: u8 = @truncate(free_cell_poison >> 16);
    if (poison_alloc_info & alloc_info_class_mask == block_cell_size_class)
        @compileError("free-cell poison impersonates a block-cell header");
    if (poison_alloc_info & alloc_info_heap_accounted_mask != 0)
        @compileError("free-cell poison reads as heap-accounted");
    const poison_flags: u8 = @truncate(free_cell_poison >> 24);
    if (poison_flags & 0x80 == 0)
        @compileError("free-cell poison byte moved off 0x86 (bit 7 is reserved and is kept set only to pin the value)");
    if (poison_flags & kind_mask != string_kind_tag)
        @compileError("free-cell poison kind nibble moved");
    if (metadata_young_mask & kind_mask != 0)
        @compileError("the young bit must stay above the kind nibble");
}
