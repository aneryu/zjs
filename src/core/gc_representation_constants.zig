//! Byte-level constants shared by the allocator, GC prefix readers, block
//! heap, and the representation snapshot.  This module deliberately imports
//! nothing: `memory.zig` owns the allocator layer and must not acquire a
//! dependency on `gc.zig` merely to agree on bytes written into the prefix.

pub const metadata_size: usize = 8;
pub const metadata_size_class_offset: usize = 0;
pub const metadata_alloc_info_offset: usize = 2;
pub const metadata_flags_offset: usize = 3;
pub const metadata_rc_offset: usize = 4;

/// The only GC kind admitted to the block heap. Kept here with the allocator
/// representation rather than making `memory.zig` import the registry enum.
/// `gc.zig` asserts that its public RefKind encoding still agrees.
pub const object_kind_tag: u8 = 0;

pub const alloc_info_class_mask: u8 = 0x1f;
pub const alloc_info_large_mask: u8 = 1 << 5;
pub const alloc_info_heap_accounted_mask: u8 = 1 << 6;
pub const alloc_info_standalone_mask: u8 = 1 << 7;

/// The saturated five-bit class value is outside the slab's real class
/// domain and therefore uniquely identifies a collector block cell.
pub const block_cell_size_class: u5 = 0x1f;
pub const block_cell_alloc_info: u8 = block_cell_size_class;

/// A freed block cell retains its successor in the low 16 bits.  The entire
/// high half is poison, chosen so reading the word as live metadata yields an
/// unaccounted, non-block, cycle-visited prefix.
pub const free_cell_link_mask: u32 = 0x0000_ffff;
pub const free_cell_poison: u32 = 0x8700_0000;

comptime {
    if (metadata_rc_offset + @sizeOf(i32) != metadata_size)
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
        @compileError("free-cell poison must read as cycle-visited");
}
