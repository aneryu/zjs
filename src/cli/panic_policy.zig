//! Panic policy for the shipped command-line binaries.
//!
//! ReleaseFast is the mode the release tarballs carry, and those artifacts are
//! stripped (see `docs/release-checklist.md`), so the default handler's
//! symbolizer has nothing left to read: it would unwind, fail to name a single
//! frame, and still cost about 209 KB of machine code — an ELF symbol-table
//! reader, a DWARF line-table reader, a flate decompressor for compressed
//! debug sections, and two 30 KB-class `std.sort.block` instantiations that
//! only those readers use. Message-only panics are the honest trade there.
//!
//! Debug and ReleaseSafe keep the full handler, so `zjs-dev`, every test
//! artifact, and every assertion-bearing build still print a resolved trace.
//! That is where a panic is actually diagnosed.

const std = @import("std");
const builtin = @import("builtin");

pub const policy = switch (builtin.mode) {
    .ReleaseFast => std.debug.simple_panic,
    else => std.debug.FullPanic(std.debug.defaultPanic),
};
