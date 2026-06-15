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
- [Object And Shape Implementation](perf/object-shape-design.md): object,
  shape, property, and inline-cache invariants.
- [Inline Cache Implementation](perf/inline-cache-design.md): cacheable
  opcodes, slot states, lookup rules, profiling, and validation.
- [Shared VM Decomposition](perf/shared-vm-decomposition.md): current
  `exec/call_runtime.zig` decomposition map.
- [Release Checklist](release-checklist.md): Production v1 release checklist.

## Reports

- `reports/api/public-symbols.txt`: checked public API symbol snapshot.
- `reports/test262-latest/`: latest local test262 bucket and failure reports.
- `reports/perf/baseline/`: checked performance baseline artifacts.
- `reports/perf/current/`: checked runtime-profile artifacts.

## Documentation Rules

- Keep durable architecture decisions in the relevant current document, not in
  broad status ledgers.
- Do not add completed phase plans or roadmaps back to the active tree without
  an explicit maintenance reason.
- If a document conflicts with `test262.conf`, build configuration, or source
  code, treat the executable repository state as the authority and fix the
  document.
