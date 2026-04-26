# Architecture Optimization Plan Snapshot

Archived: 2026-04-26

This is a historical snapshot of the optimization plan produced during the
architecture repair session. It is not the active source of truth. Current state
and validation evidence live in `../TRACKING.md` and
`../ARCHITECTURE_REPAIR_PLAN.md`.

## Archived Scope

- Calibrate project status so local smoke/test262 baseline success is not treated
  as full QuickJS semantic completeness.
- Start parser-first semantic completion before broad VM or builtin rewrites.
- Keep existing baseline behavior passing while exposing which parser path owns
  each parse result.
- Continue hardening allocator/OOM paths and fixed-capacity limits without
  weakening tests.

## Completed In This Snapshot

- `status.zig` status vocabulary was split into `source_mapped`,
  `fixture_validated`, `baseline_validated`, and `semantic_complete`.
- Known-gap subsystems are blocked from being marked `semantic_complete`.
- `SimpleParser` was isolated behind a transitional compiler boundary.
- `frontend.parser.Result.parse_path` records scanner, transitional compiler, or
  syntax-error guard ownership.
- BigInt helper allocation paths were moved away from hidden global allocator and
  infallible `catch unreachable` behavior.

## Deferred Optimization Tracks

| Track | Next action |
|---|---|
| Parser-first lowering | Add the first token-driven parse/lower slice and migrate one existing `SimpleParser` behavior behind it. |
| VM/domain extraction | Move builtin/domain semantics out of `exec/vm.zig` after parser output is less fixture-shaped. |
| Builtins/support libs | Replace placeholder constructor/prototype/library domains with shared object/property implementations. |
| GC cycle removal | Implement or explicitly scope QuickJS-style cycle handling and weak collection integration. |
| Capacity hardening | Replace fixed-size argument/property/function tables with allocator-backed storage and boundary tests. |

## Validation Snapshot

- `zig build test --summary all`: 133/133
- `zig build test-frontend --summary all`: 21/21
- `zig build smoke --summary all`: 45/45
- BigInt target slice: 77/77
- JSON target slice: 21/21
- `git diff --check`: clean

Before using this archived plan for implementation, copy the relevant item back
into `../TRACKING.md` or `../ARCHITECTURE_REPAIR_PLAN.md` with fresh validation.
