# Shape heap accounting balances by coincidence, not by invariant

Found 2026-08-26 by the PERF-T-SPIKE prototype (driver session), which
added 8 bytes to `Shape` and immediately tripped the Debug invariant
`HeapLiveBytesMismatch`. The growth is not the defect — it is the thing
that exposed it.

## The three currencies

A shape's heap footprint is expressed three different ways:

| site | quantity | file |
|---|---|---|
| credit | `@sizeOf(Shape) + fam_bytes` (**requested bytes**) | `shape.zig` `addInitializedShape` call sites |
| debit | `gcSlabAccountedPayload(shape)` (**slab class usable payload**) | `shape.zig` `destroyShape` |
| verify | `sh.allocationSize()` = `@sizeOf(Shape) + famByteSize()` (**requested**) | `gc.zig` `heapByteSizeFromHeader` |

Credit and verify agree by construction. The debit agrees with them only
when the requested size happens to equal the slab class's usable payload,
i.e. when every live shape size lands exactly on a `block_sizes` boundary
(step 8 up to 128, step 16 up to 256, step 32 up to 512).

With `@sizeOf(Shape) == 56` and the current FAM geometry, they do. That is
why main is green. It is a coincidence of two independent constants, not
an enforced invariant, and nothing in the code says the two must line up.

## Reproducing

Add any field to `Shape` that moves its size off the coincidence (the
spike used `+8`), build Debug, and run the unit suite: the accounting
verifier fires. On the spike branch the observed drift was 8 bytes per
live shape (delta +304 over 38 live shapes in one failing case).

## Why it matters beyond the spike

- Any future `Shape` field — including the production `PERF-SHAPE-ID`
  identity/version field, which the roadmap has already ruled will be
  added — walks straight into this.
- The same three-currency pattern may exist for other kinds; only shapes
  were audited here.
- The failure mode is a Debug-only assertion today, so a release build
  would silently carry a drifting `old_space.live_bytes`, which is a GC
  trigger input.

## What the spike branch did (not a proposal for main)

`spike/perf-t` makes `destroyShape` debit the requested-byte currency so
all three agree, which turns the suite green. That is the minimal local
fix for a throwaway prototype; whether main should converge on requested
bytes or on slab payload (and then fix credit + verify instead) is a real
decision for whoever owns the accounting — the slab payload is arguably
the more honest number, since that memory is genuinely committed.

## Status

- Root cause: identified (above).
- Fix on main: **not applied** — owner to route, ideally together with the
  PERF-SHAPE-ID field work, which needs this resolved first.
