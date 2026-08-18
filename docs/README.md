# Documentation

Active project documentation. Completed roadmaps and campaign dumps are not
kept as current status; recover them from git history when needed.

## Start Here

- [Project README](../README.md): highlights, three-line build, CLI.
- [Contributing](../CONTRIBUTING.md): pull requests, QuickJS semantics, test rules.
- [Guide](../GUIDE.md): Zig engineering rules and the validation command ladder.
- [Compatibility](../COMPATIBILITY.md): test262 validation boundary.
- [Limitations](../LIMITATIONS.md): runtime and product-scope boundaries.

## Architecture And API

- [Architecture](architecture.md): current source tour.
- [Testing Graph](testing-graph.md): compile-root chain, shell classes, step names.
- [API Boundary](api-boundary.md): public API, core, runtime, bindings, CLI.
- [Public API Contract](public-api-contract.md): Zig API surface.
- [Compiler-v2 Contract](compiler_v2_contract.md): current compiler identity rules.
- [Borrowed Atom Audit](borrowed_atom_audit.md): atom-ownership audit tier.
- [Stack Bytecode VM](stack_bytecode_vm_design.md): stack-VM status and boundary.
- [QCP-1 Switch Decision](qcp1_switch_decision.md): shipped compiler configuration
  and the evidence it rests on.

## Embedding And Extension

- [Embedding Cookbook](embedding-cookbook.md): runtime/context, host functions, handles.
- [Runtime Plugin ABI](runtime-plugin-abi.md): dynamic runtime plugin ABI.
- [Security Boundary](security-boundary.md): trusted-code embedding assumptions.

## Performance And Release

- [Zoo status vs QuickJS](perf/zoo-status.md): public 15-bench geomean claim.
- [Performance Workflow](perf/README.md): self-baseline gate and profiling.
- [Object And Shape Implementation](perf/object-shape-design.md).
- [Shared VM Decomposition](perf/shared-vm-decomposition.md).
- [Release Checklist](release-checklist.md).
- [Refactor Tax Policy](refactor-policy.md): risk zones, identity gates; hot-path moves need a 15-item zoo A/B.
- [Maintainability Backlog](maintainability-backlog.md): priced HOT-zone refactor queue.

## Reports (gate snapshots)

These paths are build-graph inputs or local write-outs.

- `reports/perf/baseline/microbench-zjs-releasefast.json`: self-baseline gate.
- `reports/perf/current/scripts/`: source scripts for optional
  `perf-*-profile` steps. Profile JSON is written under `.zig-cache/perf/`.
- `reports/test262-latest/`: local test262-gate write-out (gitignored).

## Agent workflow

- [Project experience](agents/project-experience.md): cross-session lessons.
- [Domain notes](agents/domain.md), [issue tracker](agents/issue-tracker.md),
  [triage labels](agents/triage-labels.md): agent conventions.

## Historical / campaign notes

Not current status. Read only when you need the original evidence.

- [zjs / QuickJS Subsystem Difference Baseline](qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md)
  (frozen measurement baseline, referenced by the performance workflow).

All other campaign reports (QCP-1 scorecards, V2 audits, anchor-split
classification, dated comparisons) were removed from the active tree on
2026-08-18; recover them from git history.

## Documentation Rules

- Keep durable architecture decisions in the relevant current document.
- If a document conflicts with `test262.conf`, the build graph, or source,
  treat the executable repository state as the authority and fix the document.
