//! QCP-1 configuration signature: one canonical, deterministic string naming
//! the five settings the switch ruling makes load-bearing.
//!
//! WHY THIS EXISTS. The defect class it closes is "a gate reports green about
//! a configuration it never ran". `zig build test-altrepr -Dzjs_compiler=v2`
//! spawned a child `zig build` that started from the *defaults*, so it ran the
//! legacy compiler and reported green for v2. Forwarding the option set fixes
//! that one instance; a signature makes the whole class unexpressible, because
//! every gate can now state which configuration its green belongs to and that
//! statement can be checked against the configuration the build graph asked
//! for.
//!
//! THE DESIGN RULE that makes it worth anything: every component below is read
//! from the declaration the ENGINE ITSELF CONSUMES, never from the `-D` string
//! sitting next to it.
//!
//!   * `layout` is `resolve_labels.default_layout` — the exact comptime
//!     constant `compiler_v2.compileFunctionV2` hands to `resolve_labels.run`
//!     (compiler_v2/root.zig).
//!   * `compiler` is derived from `Parser.dual_compare_enabled` and
//!     `Parser.single_backend_is_v2` — the exact two declarations
//!     `Parser.compile` branches on to pick its backend.
//!   * `repr` is `core.value.nan_boxing`, the constant JSValue is laid out
//!     from; `force_gc` is `core.memory.force_gc_on_allocation_enabled`, the
//!     constant the allocation path is gated on; `ownership_audit` is
//!     `core.atom.ownership_audit_enabled`, the constant the atom table's
//!     quarantine field exists under.
//!
//! A signature recomputed here from `@import("build_options")` would agree
//! with itself even if the compiled code ignored the option, and would attest
//! nothing at all. Because these are the consumed declarations instead, a
//! drift between what build.zig believes and what the compiled code does makes
//! this string differ from the build graph's expectation, and both
//! `zig build config-signature-check` (against the shipped binary) and the
//! in-suite attestation test below fail loudly.
//!
//! ORDER is fixed by `component_order` below, not by any map iteration, so the
//! string is stable across builds, platforms and Zig versions.

const std = @import("std");

const parser = @import("parser.zig");
const resolve_labels = @import("compiler_v2/resolve_labels.zig");
const core_atom = @import("core/atom.zig");
const core_memory = @import("core/memory.zig");
const core_value = @import("core/value.zig");

/// Bumped only when the component set or the encoding changes, so an old
/// expectation can never silently match a new meaning.
pub const version = "zjs-config-v1";

/// The canonical component order. This is the ruling's order (compiler,
/// layout, value representation, force-GC, ownership audit) and is the only
/// thing that decides the string's field order.
pub const component_order = [_][]const u8{
    "compiler",
    "layout",
    "repr",
    "force_gc",
    "ownership_audit",
};

/// Compiler mode, read off the dispatch decision `Parser.compile` makes.
pub const compiler: []const u8 = if (parser.Parser.dual_compare_enabled)
    "dual"
else if (parser.Parser.single_backend_is_v2)
    "v2"
else
    "legacy";

/// Final bytecode layout, read off the constant compiler-v2 lowers with.
pub const layout: []const u8 = @tagName(resolve_labels.default_layout);

/// JSValue representation, read off the constant `core/value.zig` builds from.
pub const repr: []const u8 = if (core_value.nan_boxing) "nan_boxed" else "tagged";

/// Force-GC instrumentation, read off the constant the allocator is gated on.
pub const force_gc: []const u8 = if (core_memory.force_gc_on_allocation_enabled) "on" else "off";

/// Atom-ownership audit tier, read off the constant the atom table carries its
/// quarantine slot under.
pub const ownership_audit: []const u8 = if (core_atom.ownership_audit_enabled) "on" else "off";

/// The component values, in `component_order`.
pub const component_values = [component_order.len][]const u8{
    compiler,
    layout,
    repr,
    force_gc,
    ownership_audit,
};

/// The canonical signature of this binary's configuration, e.g.
/// `zjs-config-v1:compiler=v2,layout=short,repr=tagged,force_gc=off,ownership_audit=off`.
pub const signature: []const u8 = blk: {
    var out: []const u8 = version;
    var sep: []const u8 = ":";
    for (component_order, component_values) |name, value| {
        out = out ++ sep ++ name ++ "=" ++ value;
        sep = ",";
    }
    break :blk out;
};

test "config_signature: attests the configuration the build graph requested" {
    // The one assertion that makes the signature load-bearing inside the test
    // binary itself: the left side is computed from the declarations the
    // engine consumes, the right side is computed by build.zig from its own
    // resolved options. A build.zig that requests v2/short while the compiled
    // code resolves legacy/plain fails here rather than reporting green.
    const expected = @import("build_options").zjs_expected_config_signature;
    if (!std.mem.eql(u8, signature, expected)) {
        std.debug.print(
            "\nconfig signature drift\n  build graph requested: {s}\n  compiled code reports: {s}\n",
            .{ expected, signature },
        );
        return error.ConfigSignatureDrift;
    }
    // Embed the attested configuration in the test artifact so a green run
    // always says which configuration it was green about.
    std.debug.print("\nzjs config signature: {s}\n", .{signature});
}

test "config_signature: is canonical, ordered, and fully populated" {
    try std.testing.expect(std.mem.startsWith(u8, signature, version ++ ":"));
    var it = std.mem.splitScalar(u8, signature[version.len + 1 ..], ',');
    for (component_order) |name| {
        const field = it.next() orelse return error.MissingComponent;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.MalformedComponent;
        try std.testing.expectEqualStrings(name, field[0..eq]);
        try std.testing.expect(field[eq + 1 ..].len != 0);
    }
    try std.testing.expect(it.next() == null);
}
