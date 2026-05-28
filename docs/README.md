# Documentation Index

Welcome to the design documentation for `fun`.

`fun` is a Zig implementation of a Bun-like JavaScript and TypeScript runtime that uses [`zjs`](https://github.com/aneryu/zjs) as its language engine.

## Recommended Reading Order

For new contributors and when onboarding:

1. [README.md](../README.md) — high-level project overview, current commands, and initial runtime shape.
2. [AGENTS.md](../AGENTS.md) — **required reading**. Contributor contract, architecture rules, testing expectations, and implementation style. Read before writing code or changing docs.
3. [docs/runtime-mvp.md](runtime-mvp.md) — the accepted narrow MVP scope, CLI contract, non-goals, data flows, diagnostics, and acceptance criteria. This document deliberately constrains scope.
4. [docs/testing.md](testing.md) — testing philosophy, current inline Zig test practices, fixture and conformance plans, and the rules that must be followed on every handoff. Complements the short expectations in AGENTS.md.
5. [docs/fun_zjs_subtree_architecture.md](fun_zjs_subtree_architecture.md) — **the binding long-term architecture**: Git subtree for `third_party/zjs`, `src/js` facade, `src/runtime/vm` as sole deep-coupling layer, full dependency rules, build graph, and 8-phase migration plan. Read when doing any structural or zjs-embedding work.
6. [docs/architecture.md](architecture.md) — Bun v1.3.14 reference mapping (historical flat scaffold) and the evolution to the subtree layering.
7. [docs/roadmap.md](roadmap.md) — milestones (M0–M7), product direction, major tradeoffs table, decision log, near-term backlog, and open questions.
8. [docs/zjs-integration.md](zjs-integration.md) — the intended embedding contract between `fun` (host/runtime) and `zjs` (language engine). Complemented by the subtree architecture for *how* the boundary is enforced. Read this when starting M2 integration work.

## Document Purposes

- **fun_zjs_subtree_architecture.md**: The authoritative repository structure, Git subtree workflow for `zjs`, layering rules (what may import what), `src/js` + `src/runtime/vm` boundary design, `build.zig` module graph, and phased migration plan. This is the single source of truth for "where does this code live and why?"
- **runtime-mvp.md**: Defines the minimal usable JavaScript runtime surface (`fun` for REPL, `fun <file> [...args]` for execution). Explicitly lists what is excluded from the first tranche.
- **testing.md**: The central reference for test strategy, current scaffold practices (inline Zig tests + explicit placeholder assertions), future fixture/conformance layers, and mandatory handoff rules.
- **architecture.md**: Records the structural mapping from Bun (historical) and notes the 2026-05 move to the subtree layout.
- **roadmap.md**: The living project plan. Records confirmed direction, tradeoffs, and the sequence of implementation. Update on any major decision.
- **zjs-integration.md**: Technical design contract for the stable embedding API surface `fun` needs from `zjs`. The *how* (import boundaries, subtree, facade vs. vm) is governed by the subtree architecture doc.

## Current Implementation Status

See the **Current Implementation Status** table in [roadmap.md](roadmap.md#current-implementation-status). This is the single source of truth for what exists in the scaffold versus what is still design or planned.

## Documentation Maintenance Rules

- **fun_zjs_subtree_architecture.md** (sections 3–4 and 19–20) is the binding source of truth for repository layout, import rules, and code review requirements. Any structural change or new `zjs` embedding code must follow its layering tables and "唯一深耦合层" rule.
- **roadmap.md** is the primary living document for milestones and status. Update its Decision Log, Milestones, and Tradeoffs table when scope, engine, or major architectural decisions change.
- **zjs-integration.md** must be reviewed whenever the `zjs` public embedding surface changes. Prefer portable descriptions over environment-specific paths or exact internal file locations.
- Keep explicit "current scaffold" vs "future design / planned for M3+" language so readers never confuse implemented behavior with aspirational design.
- Cross-reference between documents instead of duplicating long lists (module ownership, pipeline diagrams, TypeScript strategy, etc.).
- Before handing off changes after a milestone or significant feature, run the full test suite, `zig fmt`, and `zig build docs-check`.
- All documentation lives in this repository and is versioned with the code. Do not describe untested behavior as available.

## Quick Links

- Project entry: [../README.md](../README.md)
- Contributor rules: [../AGENTS.md](../AGENTS.md) (now includes subtree layering rules)
- Contributing guide: [../CONTRIBUTING.md](../CONTRIBUTING.md)
- Testing strategy: [docs/testing.md](testing.md)
- Architecture & subtree contract: [docs/fun_zjs_subtree_architecture.md](fun_zjs_subtree_architecture.md)
- Local commands (build, test, fmt, docs-check): see AGENTS.md and CONTRIBUTING.md

## Documentation Handoff Checklist

Before merging any change that touches implementation or design:

- [ ] Run `zig fmt build.zig src`, `zig build test`, and `zig build docs-check`
- [ ] Update `docs/roadmap.md` Current Implementation Status matrix if any module state changed
- [ ] Update Decision Log in `docs/roadmap.md` for material decisions
- [ ] Review `docs/testing.md` and the testing expectations in AGENTS.md when adding new behavior, fixture infrastructure, or advancing test posture for any layer
- [ ] Keep "current scaffold vs planned design" language accurate in all docs
- [ ] Verify `docs/zjs-integration.md` still matches the actual `zjs` public surface (when relevant)
- [ ] Ensure new code has appropriate `//!` module docs pointing to design documents

## Documentation History

- 2026-05 (architecture alignment): Adopted `docs/fun_zjs_subtree_architecture.md` as the binding structure contract. Updated reading order, AGENTS.md, roadmap status matrix, and all cross-references. This change prepared the `src/js` + `src/runtime/vm` + `src/tooling/*` + `third_party/zjs` skeleton (implementation followed in the same tranche).
- 2026-06 (docs optimization): Created `docs/testing.md` as the single source
  of truth for testing strategy, current inline practices, and future fixture/
  conformance plans. Added it to reading order, purposes, quick links, and
  handoff checklist. Standardized several history/decision dates toward
  `YYYY-MM-DD`. Cleaned up stray root-level test artifacts. See Decision Log
  in `roadmap.md` for details.
- 2026-05 (docs optimization pass): Added Documentation Handoff Checklist, introduced
  this index, updated AGENTS.md + root README.md, added the authoritative
  "Current Implementation Status" matrix in `roadmap.md`, added `//!` module
  documentation to every source module, and standardized cross-references.
- 2026-05 (initial design): Created `architecture.md`, `roadmap.md`,
  `runtime-mvp.md`, and `zjs-integration.md` alongside the M0/M1 scaffold.

All documentation is versioned with the source code.