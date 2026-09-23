# Documentation

zjs is a JavaScript / TypeScript engine written in Zig. Start with the
[project README](../README.md); use the table below to read only what the task
needs. Historical measurements and plans are labeled separately from contracts.

## Use and contribute

| Need | Document |
| --- | --- |
| Build, CLI, minimal embedding | [README](../README.md) |
| Host functions, handles, strings/bytes, limits, modules | [Embedding cookbook](embedding-cookbook.md) |
| Supported public Zig API and lifetimes | [Public API contract](public-api-contract.md) |
| ECMAScript validation profile | [Compatibility](../COMPATIBILITY.md) |
| TS, host, security, and debugger boundaries | [Limitations](../LIMITATIONS.md) |
| Contribution workflow | [Contributing](../CONTRIBUTING.md) |
| Agent task execution and reading triggers | [AGENTS](../AGENTS.md) |
| Zig engineering and command reference | [GUIDE](../GUIDE.md) |
| Verification obligations | [Verification policy](verification-policy.md) |
| Diagnosis, worktrees, local `.scratch/` tickets (§11) | [Project experience](agents/project-experience.md) |

## Source and contracts

| Area | References |
| --- | --- |
| Source ownership and layers | [Architecture](architecture.md), [API boundary](api-boundary.md) |
| Function-level source tour (Chinese) | [Code walkthrough](code-walkthrough/README.md) |
| Exec calls and import hubs | [Exec dependency graph](exec-dependency-graph.md) |
| Test roots and build steps | [Testing graph](testing-graph.md) |
| Runtime ownership and lifecycle | [Runtime design and implementation record](runtime-target-design.md) |
| GC and values | [GC invariants](gc-invariants.md), [VM value representation](vm-value-representation-contract.md), [borrowed atoms](borrowed_atom_audit.md) |
| Compiler and TS parser | [Compiler contract](compiler-contract.md), [TypeScript parser](parser-ts-first-class-design.md) |
| Native calls and host boundary | [Native boundary design](perf/native-boundary-design.md), public API contract above |
| Object/shape layouts | [Object and shape implementation](perf/object-shape-design.md) |
| Opcode design | [Opcode design](perf/opcode-design.md), [engine comparison](perf/opcode-engines.md), [opcode table](perf/opcode-audit-table.md) |

## Evidence and release

- [STATUS](../STATUS.md): dated validation and milestone records.
- [Changelog](../CHANGELOG.md): release history.
- [Release checklist](release-checklist.md): API, lifecycle, and artifact checks.
- [Performance workflow](perf/README.md): diagnostic tools and evidence guidance.
- [bench-v8 snapshot](perf/bench-v8-status.md): historical performance results.
- [Runtime allocator comparison](runtime-allocator-todo.md): default allocator decision and remaining experiments.
- [Binary composition](binary-size.md): dated ReleaseFast size breakdown.
- [Refactor policy](refactor-policy.md): hot-path layout risk and validation.
- [Retrieval index](../llms.txt): compact project facts for retrieval tools.

`reports/test262-latest/` contains gitignored local output. Existing
`reports/evidence/` artifacts are historical evidence, not new gate requirements.

## Planned work

Plans describe work to evaluate or implement, not shipped capabilities:

- [Roadmap](roadmap.md) and [work-item registry](roadmap/work-items.yaml): scope,
  dependencies, and recorded decisions.
- [Backlog](backlog.md): dated implementation/refactoring queue; recheck open items against source.
- [Nursery evaluation](runtime-nursery-todo.md): current correctness blockers and evaluation sequence; disabled by default.
- [Engine evolution](engine-evolution-plan.md),
  [type-directed optimization](type-directed-optimization-plan.md), and
  [process model](process-model-design.md): design proposals and contracts
  for the corresponding planned work.

## Historical decisions

- [GC target review](gc-target-design-review.md): target constraints and migration rationale; current nursery blockers live in the evaluation above.
- [QCP-1 switch](qcp1_switch_decision.md): compiler switch and layout lessons (§9).
- [QuickJS charter transition](qjs_alignment_charter_transition.md): retirement
  of implementation-faithfulness constraints.

Recover completed campaign logs and older revisions from Git history when
investigating those versions. Do not apply retired procedures as current gates.

## Maintaining documentation

Give each fact or rule one owning document and link to it elsewhere. Record
new evidence with the change that owns it; add design documents for durable
contracts, not routine progress reports.

Source, tests, and the build graph establish implementation facts. ECMA-262
and current contracts define intended behavior; an implementation mismatch
may be a bug. Verification obligations come only from verification policy.
Mark snapshots and plans explicitly, and check local links when editing.
