# Documentation

Active project documentation, organized by audience. Completed roadmaps and
campaign dumps are not kept as current status; recover them from git history
when needed.

## New To The Project? Read In This Order

1. [Project README](../README.md): what zjs is, what it is not, build and CLI.
2. [Embedding Cookbook](embedding-cookbook.md): run JavaScript from Zig —
   runtime/context, values, host functions, limits, modules.
3. [Compatibility](../COMPATIBILITY.md) and [Limitations](../LIMITATIONS.md):
   what is validated, what is out of scope.
4. [Architecture](architecture.md): the source tour, when you want to read or
   change engine code.

## Using zjs (Embedders)

- [Embedding Cookbook](embedding-cookbook.md): copy-paste examples, covered by
  the embedding test target.
- [Public API Contract](public-api-contract.md): the supported Zig API surface
  and ownership rules.
- [Runtime Plugin ABI](runtime-plugin-abi.md): dynamic native plugins.
- [Security Boundary](security-boundary.md): trusted-code assumptions; zjs is
  not a sandbox for hostile JavaScript.

## Understanding And Changing The Engine (Contributors)

- [Contributing](../CONTRIBUTING.md): pull requests, QuickJS semantics, test rules.
- [Guide](../GUIDE.md): Zig engineering rules and the validation command ladder.
- [Architecture](architecture.md): current source tour and layer map.
- [API Boundary](api-boundary.md): layering rules between public API, core,
  runtime, bindings, and CLI.
- [Testing Graph](testing-graph.md): compile-root chain, shell classes, step names.
- [Stack Bytecode VM](stack_bytecode_vm_design.md): VM status and evolution boundary.
- [Compiler Contract](compiler-contract.md): normative compiler identity rules.
- [Borrowed Atom Audit](borrowed_atom_audit.md): atom-ownership contract and
  the `-Dzjs_ownership_audit` / lint governance protocol.

## Performance

- [bench-v8 status vs QuickJS](perf/bench-v8-status.md): the public
  performance claim (V8 suite v7 — the suite upstream QuickJS publishes
  with) — the single authoritative score source.
- [Zoo status vs QuickJS](perf/zoo-status.md): internal 15-benchmark
  diagnostic suite (broader coverage; last zoo baseline preserved).
- [Performance Workflow](perf/README.md): measurement contract, diagnostic
  benchmarks, profiling, PMU discipline.
- [Object And Shape Implementation](perf/object-shape-design.md): fixed
  layouts, invariants, and the no-inline-cache rule.
- [Shared VM Decomposition](perf/shared-vm-decomposition.md):
  `call_runtime.zig` split map and move criteria.
- [Refactor Tax Policy](refactor-policy.md): risk zones and identity gates;
  hot-path moves need a bench-v8 A/B.
- [Maintainability Backlog](maintainability-backlog.md): priced HOT-zone
  refactor queue (H1–H12).
- [Implementation Quality Backlog](impl-quality-backlog.md): 2026-08-21
  review queue — GC/parser/object.zig blind-spot findings, spec-bug
  stragglers, and gated structural moves.
- [Code Volume](code-volume.md): line-count composition, the remaining
  reduction queue, and what was ruled unrecoverable (and why).

## Status And Release

- [STATUS](../STATUS.md): the single authoritative status snapshot.
- [Changelog](../CHANGELOG.md): released and development changes.
- [Release Checklist](release-checklist.md): Production v1 release decision.
- [Retrieval index](../llms.txt): compact project facts for automated
  retrieval tools.

## Reports (gate snapshots)

These paths are build-graph inputs or local write-outs.

- `reports/perf/current/scripts/`: source scripts for optional
  `perf-*-profile` steps. Profile JSON is written under `.zig-cache/perf/`.
- `reports/test262-latest/`: local test262-check write-out (gitignored).

## Agent Workflow

- [Project experience](agents/project-experience.md): domain-context routing
  and cross-session lessons.
- [Issue tracker](agents/issue-tracker.md): local `.scratch/` issue
  conventions and triage labels.

## Historical (frozen — read for provenance, not current status)

- [QCP-1 Switch Decision](qcp1_switch_decision.md): close-out record — shipped
  compiler configuration, final verdicts, and the layout-sensitivity rulings
  (§9); full evidence lives in this file's git history.
- [zjs / QuickJS Subsystem Difference Baseline](qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md):
  frozen 2026-07-27 measurement baseline with an errata header for facts that
  later work superseded.

All other campaign reports (QCP-1 scorecards, V2 audits, anchor-split
classification, dated comparisons) were removed from the active tree on
2026-08-18; recover them from git history.

## Documentation Rules

- Keep durable architecture decisions in the relevant current document.
- If a document conflicts with `test262.conf`, the build graph, or source,
  treat the executable repository state as the authority and fix the document.
- Historical process evidence (measurements, gate ledgers, campaign scorecards)
  lives in git history, commits, and PRs — not in the active tree.
