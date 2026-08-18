const std = @import("std");

// Unique exception: this shell does not attest. It is rooted on the public
// `zjs` module (`src/root.zig`), which intentionally does not export
// `config_signature` — the same choice as the runtime plugin fixtures.
// The public surface is what embedders see; the signature belongs on
// engine-bearing internal artifacts, not on the embedding facade.

test {
    std.testing.refAllDecls(@import("tests/embedding_examples.zig"));
}
