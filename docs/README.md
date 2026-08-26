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
- [Runtime Plugin ABI](runtime-plugin-abi.md): dynamic native plugins
  (**deprecated 2026-08-25** — superseded by the
  [Fun Native Plugin design](fun-native-plugin-design.md)).
- [Fun Dev Hot Reload design](fun-dev-hot-reload-design.md): the fun/zjs
  hot-reload and dev-update system — HostCore/Session split, Sequential
  Session Reload, ESM HMR, and the zjs capability list (v1.3,
  adversarially reviewed 2026-08-26; Shadow Swap deferred to its
  appendix A).
- [Process Model design](process-model-design.md): Erlang-style multithreading
  — Runtime-per-process → lightweight processes, turn-boundary scheduling,
  selective receive, link/monitor/supervision (v0.5 design exploration,
  2026-08-26; §20 records the six-plan reconciliation verdicts and the
  per-document debt ledger).
- [Roadmap](roadmap.md): the unified execution-baseline candidate (v1.7) —
  authority matrix, canonical hard-dependency DAG, gates, WIP limits; the
  machine-readable registry is [roadmap/work-items.yaml](roadmap/work-items.yaml),
  validated on CI by `tools/docs/roadmap_lint.py`. Roadmap verdicts must be
  synchronized to domain-doc bodies in the same commit.
- [Limitations — Security Boundary](../LIMITATIONS.md): trusted-code
  assumptions; zjs is not a sandbox for hostile JavaScript.

## Understanding And Changing The Engine (Contributors)

- [Contributing](../CONTRIBUTING.md): pull requests, QuickJS semantics, test rules.
- [Guide](../GUIDE.md): Zig engineering rules and the validation command ladder.
- [Architecture](architecture.md): current source tour, layer map, and the
  Stack Bytecode VM Status chapter (VM mechanisms, the §8 PMU governance
  gate); evolution scope lives in the
  [Engine Evolution Plan](engine-evolution-plan.md).
- [API Boundary](api-boundary.md): layering rules between public API, core,
  runtime, bindings, and CLI.
- [Testing Graph](testing-graph.md): compile-root chain, shell classes, step names.
- [Compiler Contract](compiler-contract.md): normative compiler identity rules.
- [Borrowed Atom Audit](borrowed_atom_audit.md): atom-ownership contract and
  the `-Dzjs_ownership_audit` / lint governance protocol.

## Performance

- [bench-v8 status](perf/bench-v8-status.md): the public performance claim
  (Octane 2.0, V8 suite v9, vendored since 2026-08-25) — the single
  authoritative score source.
- [Zoo runner](../tools/perf/zoo/README.md): standalone-file attribution
  instrument (bench-v8's Octane coverage now matches or exceeds it; the
  last zoo baseline was removed 2026-08-25 — recover from git history).
- [GC baseline](perf/gc-baseline.md): refcounting-collector behavior
  baseline captured before the GC refactor.
- [Performance Workflow](perf/README.md): measurement contract, diagnostic
  benchmarks, profiling, PMU discipline.
- [Object And Shape Implementation](perf/object-shape-design.md): fixed
  layouts, invariants, and the no-inline-cache-today status.
- [Refactor Tax Policy](refactor-policy.md): risk zones and identity gates;
  hot-path moves need a bench-v8 A/B.
- [Backlog](backlog.md): the single priced work queue — HOT-zone refactors
  (H7/H9/H10/H11), implementation-quality open items (Q11 T3/T4, Q12, Q13),
  `call_runtime.zig` candidate domains, and the code-volume queue with its
  ruled-unrecoverable record. Merged 2026-08-25 from four former queue
  documents; their closed records live in git history.

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

- [Project experience](agents/project-experience.md): domain-context routing,
  cross-session lessons, and the local `.scratch/` issue conventions and
  triage labels (§11).

## Historical (frozen — read for provenance, not current status)

- [QCP-1 Switch Decision](qcp1_switch_decision.md): close-out record — shipped
  compiler configuration, final verdicts, and the layout-sensitivity rulings
  (§9); full evidence lives in this file's git history.

All other campaign reports (QCP-1 scorecards, V2 audits, anchor-split
classification, dated comparisons, the frozen 2026-07-27 zjs/QuickJS
subsystem difference baseline, and the superseded v7-suite score records)
were removed from the active tree on 2026-08-18 and 2026-08-25; recover
them from git history.

## Documentation Rules

- Keep durable architecture decisions in the relevant current document.
- If a document conflicts with `test262.conf`, the build graph, or source,
  treat the executable repository state as the authority and fix the document.
- Historical process evidence (measurements, gate ledgers, campaign scorecards)
  lives in git history, commits, and PRs — not in the active tree.
