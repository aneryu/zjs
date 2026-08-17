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
- [Retired Inline Cache Note](perf/inline-cache-design.md).
- [Shared VM Decomposition](perf/shared-vm-decomposition.md).
- [Release Checklist](release-checklist.md).
- [Refactor Tax Policy](refactor-policy.md): no dedicated split-file campaigns; hot-path moves need a 15-item zoo A/B.

## Reports (gate snapshots)

These paths are build-graph inputs or the latest test262 write-out. Do not
delete them without changing `build.zig`.

- `reports/api/public-symbols.txt`: public API symbol snapshot.
- `reports/test262-latest/`: latest local test262 bucket and failure reports.
- `reports/perf/baseline/microbench-zjs-releasefast.json`: self-baseline gate.
- `reports/perf/current/`: checked runtime-profile scripts and artifacts.

## Historical / campaign notes

Not current status. Read only when you need the original evidence.

- [zjs / QuickJS Subsystem Difference Baseline](qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md)
- [Code-level comparison 2026-08-07](qjs-align/CODE-LEVEL-COMPARISON-2026-08-07.md)
- [QCP-1 architecture scorecard](qcp1_architecture_scorecard.md)
- [QCP-1 dual-divergence closure](qcp1_dual_divergence_closure.md)
- [C2 scorecard](c2_scorecard.md)
- [V2 builder lifetime](v2_builder_lifetime.md)
- [V2 escape audit](v2_escape_audit.md)
- [V2 emission coverage](v2_emission_coverage.md)
- [V2 test262 gap](v2_test262_gap.md)
- [Anchor split classification](anchor_split_classification.md)
- [Zig build bistability 2026-07](perf/ZIG-BUILD-BISTABILITY-2026-07.md)

Dated `reports/perf/qjs-align/` campaign trees were removed from the active
tree. Recover them from git history.

## Documentation Rules

- Keep durable architecture decisions in the relevant current document.
- If a document conflicts with `test262.conf`, the build graph, or source,
  treat the executable repository state as the authority and fix the document.
