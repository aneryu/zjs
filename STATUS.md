# STATUS

Dated validation and milestone records for zjs. These snapshots do not certify
an untested checkout. Product scope lives in [LIMITATIONS.md](LIMITATIONS.md),
selection in [COMPATIBILITY.md](COMPATIBILITY.md), and current gate obligations
in [verification policy](docs/verification-policy.md).

## Tracing-GC migration

The 2026-09-06 snapshot records the completed tracing-GC
migration (`e972c4b5` → `f005aee7`): tracing is the only collector; heap reference
counting and the `gc/tracing` branch are retired.

The former G2-GC-MERGE statistical protocol was superseded without a verdict.
The snapshot listed VM-CONTRACT-GC and conservative-root residue R1 as follow-up
work; consult current contracts/source before treating an old item as open.
Measurement policies and performance merge gates were retired on 2026-09-18.

## test262

Recorded 2026-09-06 on `ca537eca`, with the same counts on `ef24c0bb` and under
the tracing-GC stress close-out:

| Prepared | Passed | Known failures | Unexpected failures | Feature-skipped |
| ---: | ---: | ---: | ---: | ---: |
| 49,778 | 44,584 | 0 | 0 | 5,194 |

Inputs: `test262.conf` and submodule pin
`4249661388e5d3f92a85186213da140a6481490f`. Selected skips include Intl,
Temporal, ShadowRealm, decorators, source-phase imports, and PTC.
See [Compatibility](COMPATIBILITY.md) for the selection rules.

## Performance

Historical bench-v8 measurements and reference fingerprints are available
in Git history. The recorded suite is Octane 2.0 / V8 suite v9;
its GCC-16 QuickJS yardstick was selected on 2026-08-26. Ratios cannot be
compared across suite versions, reference compilers, or binary fingerprints.
The measurements are maintainer single-machine snapshots, not an independent
reproduction or a current performance gate.

## Binary size

The 2026-09-21 snapshot on `9e915ba0` records stripped aarch64 ReleaseFast
`zjs` at 3.16 MiB, including 2.60 MiB of machine code. Composition and
provenance: [binary-size.md](docs/binary-size.md). Size is diagnostic.

## Gates

These are completed historical runs, not commands to repeat. Use
[GUIDE Part B.6](GUIDE.md#b6-validation-tiers) for current commands.

| Date / revision | Recorded result |
| --- | --- |
| 2026-09-06 / `ca537eca` | Retired `merge-gate` aggregate passed in 91 s; test262 counts above |
| 2026-09-06 / `ef24c0bb` | Same aggregate passed 70/70 steps after Q21 and diagnostic fixes |
| 2026-09-06 / `ca537eca` | Local ReleaseSafe and ownership-audit suites passed 24/24 steps each; OOM 22 passed; leak census 1,570 passed; retired `test-stress` 9/9 steps |

Nightly history: the 2026-08-26 through 2026-09-05 runs failed in an OOM-cap
ReleaseSafe test on older revisions; subsequent fail-fast tiers did not run.
The failure did not reproduce on `ca537eca`. Local success does not establish
that a later CI run passed. Earlier full gate logs remain in this file's Git
history.

## Known defects

This is a historical disposition list, not an exhaustive current bug inventory.

| Recorded disposition | Finding / evidence |
| --- | --- |
| Fixed 2026-09-06, Q21 | Dense-array storage-cell tracing now follows the storage-owning arm rather than `flags.fast_array`; regression in `tests/core.zig`, historical analysis available in Git history |
| Closed 2026-09-06, Q22 | Per-corpse accounting does not debit the byte ledger twice; invariant regression in `tests/core.zig`, analysis in backlog |
| Fixed 2026-08-22 | Frame teardown read bytecode after releasing its function; the regression records the dynamic-function case |

The former August realm teardown notes describe the retired reference-counted
collector. Recover them from Git history for old-revision diagnosis; current
lifetime rules are in [GC invariants](docs/gc-invariants.md) and the
[public API contract](docs/public-api-contract.md).

## CI

[CI workflow](.github/workflows/ci.yml) defines Linux arm64/x86_64 checkpoints
and macOS/Windows build/smoke jobs; none is marked `continue-on-error`.
[Nightly](.github/workflows/nightly.yml) adds production, ReleaseSafe, OOM,
leak-census, and ownership-audit coverage. Remote branch protection and run
status must be checked live when needed; this document does not certify them.
