# Architecture Repair Plan

Last updated: 2026-04-26

This document tracks the repair work opened after the whole-project architecture
review. It is the active handoff point for semantic-completion work that is
larger than Phase 9 hardening.

## Current Truth

- The local `run-test262` gate can pass the selected `quickjs/test262.conf`
  baseline, but that is not the same as QuickJS semantic completeness.
- `frontend/parser.zig` still contains a transitional `SimpleParser` path and
  source-pattern compilers for selected fixture/test262 shapes.
- `exec/vm.zig` still owns too many semantic domains and can return
  `UnsupportedOpcode` from public execution paths.
- `builtins/*` and `libs/*` contain useful focused fixtures, but several modules
  are still scaffolds or narrow helpers rather than full constructor/prototype
  and library ports.
- `core/gc.zig` records cycle-removal scaffolding only; full JS cycle handling
  remains open.

## Repair Tracks

| Track | Status | Required next action |
|---|---|---|
| Status calibration | in_progress | Keep `status.zig` states aligned with actual maturity and prevent `semantic_complete` on known-gap subsystems. |
| Parser-first architecture | in_progress | `SimpleParser` now sits behind an explicit transitional compiler boundary; next introduce token-driven parser/lowering slices. |
| VM/domain extraction | queued | Move builtin/domain semantics out of the VM once parser output is less fixture-shaped. |
| Builtins and support libs | queued | Replace placeholder constructor/prototype/library domains with real shared object/property behavior. |
| GC cycle removal | queued | Implement or explicitly scope QuickJS-style cycle removal and weak collection integration. |
| Capacity/OOM hardening | in_progress | Replace hidden fixed limits and infallible allocation helpers with allocator-backed, fallible paths. |

## Parser-First Boundary

- Treat `SimpleParser` as transitional compatibility infrastructure, not the
  target parser.
- `frontend.parser.Result.parse_path` records whether a parse used the token
  metadata scanner, transitional fixture compiler, or syntax-error guard.
- New syntax work should add source-aligned parse/lower behavior before adding
  VM shortcuts or source-string recognizers.
- Existing fixtures may continue to pass through `SimpleParser` until the
  replacement path covers them, but new repair work must record which path owns
  the behavior.

## Acceptance Gates

- `zig build test --summary all`
- `zig build smoke --summary all`
- `git diff --check`
- Targeted test262 slices for any changed syntax, VM, builtin, or library domain.
- Full local test262 gate before declaring a repair track complete.
