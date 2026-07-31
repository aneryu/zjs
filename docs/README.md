# Documentation

This directory contains active project documentation. Completed roadmaps,
snapshot ledgers, one-off audits, and historical phase plans are not kept in
the active tree; recover them from git history when needed.

## Start Here

- [Project README](../README.md): project status, build commands, CLI usage,
  and repository layout.
- [Guide](../GUIDE.md): stable engineering rules and validation workflow.
- [Compatibility](../COMPATIBILITY.md): the active test262 validation boundary.
- [Limitations](../LIMITATIONS.md): runtime and product-scope boundaries.

## Architecture And API

- [Architecture](architecture.md): current source architecture snapshot.
- [zjs / QuickJS Subsystem Difference Baseline](qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md):
  frozen dated source, behavior, test262, and performance comparison. It is
  evidence for the recorded commits, not a mutable current-status ledger.
- [API Boundary](api-boundary.md): layering rules between public API, core,
  runtime, bindings, CLI, and test262 harness code.
- [Public API Contract](public-api-contract.md): current Zig API surface and
  compatibility rules.
- [Stack Bytecode VM](stack_bytecode_vm_design.md): current stack-VM status and
  evolution boundary.

## Embedding And Extension

- [Embedding Cookbook](embedding-cookbook.md): examples for runtime/context
  lifecycle, host functions, handles, byte stores, limits, interrupts, and
  module evaluation.
- [Runtime Plugin ABI](runtime-plugin-abi.md): dynamic runtime plugin ABI.
- [Security Boundary](security-boundary.md): trusted-code embedding assumptions
  and release language.

## Performance And Release

- [Performance Workflow](perf/README.md): self-baseline performance gate,
  runtime profiling, checked artifacts, and functional gates.
- [Object And Shape Implementation](perf/object-shape-design.md): current
  object, shape, property, and non-cached fast-path invariants.
- [Retired Inline Cache Note](perf/inline-cache-design.md): records that the
  former property IC is no longer part of the engine.
- [Shared VM Decomposition](perf/shared-vm-decomposition.md): current
  `exec/call_runtime.zig` decomposition map.
- [CodeLoad Compile Micro](../tools/perf/codeload/README.md): current fixed
  compile/atom workload and multi-build verdict protocol for the code-load
  campaign.
- [Release Checklist](release-checklist.md): Production v1 release checklist.

## Reports

- `reports/api/public-symbols.txt`: checked public API symbol snapshot.
- `reports/test262-latest/`: latest local test262 bucket and failure reports.
- `reports/perf/baseline/`: active zjs self-baseline plus historical
  cross-engine artifacts; the 2026-06-13 QuickJS-ng comparison is not a current
  pinned-QuickJS baseline.
- `reports/perf/current/`: checked historical runtime-profile artifacts. Opcode
  rows must not be refreshed or used for new attribution until the dispatcher
  profiling scope is restored and covered by an end-to-end test.

## Documentation Rules

- Keep durable architecture decisions in the relevant current document, not in
  broad status ledgers.
- Do not add completed phase plans or roadmaps back to the active tree without
  an explicit maintenance reason.
- `docs/qjs-align/` contains only explicitly retained frozen baselines. Completed
  audits, dossiers, blueprints, execution logs, and performance raw data belong
  in git history or `reports/`, not in the active documentation set.
- If a document conflicts with `test262.conf`, build configuration, or source
  code, treat the executable repository state as the authority and fix the
  document.
