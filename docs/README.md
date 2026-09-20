# Documentation

Active project documentation, organized by audience. Campaign dumps, dated
accounts, and completed migration specs are not kept as current status;
recover them from git history when needed.

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
- Native functions and native -> JS calls (`zjs.native`, `zjs.CallSite`):
  the cookbook's Native Functions / Typed Leaf / Calling JavaScript From The
  Host / Rooting Rules sections and the contract's Native Functions chapter;
  the mechanism is the
  [native boundary design](perf/native-boundary-design.md) (§3, §7, §9).
- [Limitations — Security Boundary](../LIMITATIONS.md): trusted-code
  assumptions; zjs is not a sandbox for hostile JavaScript.

## Understanding And Changing The Engine (Contributors)

- [Contributing](../CONTRIBUTING.md): pull requests, QuickJS semantics, test rules.
- [Guide](../GUIDE.md): Zig engineering rules and the validation command ladder.
- [Architecture](architecture.md): current source tour, layer map, and the
  Stack Bytecode VM Status chapter. Evolution scope lives in the
  [Engine Evolution Plan](engine-evolution-plan.md).
- [源码逐函数讲解](code-walkthrough/README.md): Chinese function-level
  walkthrough of `src/` and the build/test entry points.
- [GC invariants](gc-invariants.md): rules the production tracing collector
  holds. There is no reference-counting collector in the tree.
- [VM value representation contract](vm-value-representation-contract.md):
  normative `JSValue` / slot / barrier / root protocol.
- [API Boundary](api-boundary.md): layering rules between public API, core,
  runtime, host facade, and CLI.
- [Testing Graph](testing-graph.md): compile-root chain, shell classes, step names.
- [Verification Policy](verification-policy.md): per-change and batch gates.
- [Compiler Contract](compiler-contract.md): normative compiler identity rules.
- [Parser: TypeScript as the grammar](parser-ts-first-class-design.md): one
  grammar for `.js` and `.ts`, the emission-free type parser, the three
  tsc-resolved ambiguities, and the `zjs --bytecode-fingerprint` identity check.
- [Borrowed Atom Audit](borrowed_atom_audit.md): atom-rooting contract and
  the `-Dzjs_ownership_audit` build.

## Performance

- [bench-v8 status](perf/bench-v8-status.md): historical public performance
  snapshot (Octane 2.0, V8 suite v9).
- [Performance Workflow](perf/README.md): local diagnostic benches and
  profiling notes. No merge-time performance gate.
- [Object And Shape Implementation](perf/object-shape-design.md): fixed
  layouts and invariants.
- [Opcode design](perf/opcode-design.md): the single current opcode-space text;
  engines comparison and the per-opcode table sit beside it.
- [Refactor Tax Policy](refactor-policy.md): hot-path splits have a layout
  tax; the merge authority is the ordinary validation ladder.
- [Backlog](backlog.md): the priced work queue.

## Status And Release

- [STATUS](../STATUS.md): the single authoritative status snapshot.
- [Changelog](../CHANGELOG.md): released and development changes.
- [Release Checklist](release-checklist.md): Production v1 release decision.
- [Roadmap](roadmap.md): approved execution baseline; machine-readable
  registry is [roadmap/work-items.yaml](roadmap/work-items.yaml).
- [Retrieval index](../llms.txt): compact project facts for automated
  retrieval tools.

## Planned Work (authority for gated items)

These documents define how gated roadmap items are done when they start.
They are not a description of the shipped engine.

- [Engine Evolution Plan](engine-evolution-plan.md)
- [Type-Directed Optimization Plan](type-directed-optimization-plan.md)
- [Process Model design](process-model-design.md)

## Reports (gate snapshots)

These paths are build-graph inputs or local write-outs, not under `docs/`.

- `reports/test262-latest/`: local test262-check write-out (gitignored).
- `reports/evidence/`: preregistered measurement evidence.

## Agent Workflow

- [Project experience](agents/project-experience.md): domain-context routing,
  cross-session lessons, and the local `.scratch/` issue conventions and
  triage labels (§11).

## Historical (frozen — read for provenance, not current status)

- [QCP-1 Switch Decision](qcp1_switch_decision.md): close-out record — shipped
  compiler configuration, final verdicts, and the layout-sensitivity rulings
  (§9); full evidence lives in this file's git history.
- [qjs-alignment charter transition](qjs_alignment_charter_transition.md):
  the 2026-08-24 succession regime (what retired, what stayed).

Completed GC campaign specs, dated pause/splay accounts, RC-retirement
ledgers, and raw TGC run dumps were removed from the active tree; recover
them from git history.

## Documentation Rules

- Keep durable architecture decisions in the relevant current document.
- If a document conflicts with `test262.conf`, the build graph, or source,
  treat the executable repository state as the authority and fix the document.
- Historical process evidence (measurements, gate ledgers, campaign scorecards)
  lives in git history, commits, and PRs — not in the active tree.
