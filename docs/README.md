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

## Source and contracts

| Area | References |
| --- | --- |
| Source ownership and layers | [Architecture](architecture.md), [API boundary](api-boundary.md) |
| Exec calls and import hubs | [Exec dependency graph](exec-dependency-graph.md) |
| Test roots and build steps | [Testing graph](testing-graph.md) |
| Runtime ownership and lifecycle | [Runtime contract](runtime-target-design.md) |
| GC and values | [GC invariants](gc-invariants.md), [VM value representation](vm-value-representation-contract.md), [Atom rooting](atom-rooting.md) |
| Compiler and TS parser | [Compiler contract](compiler-contract.md), [TypeScript parser](parser-ts-first-class-design.md) |
| Native calls and host boundary | [API boundary](api-boundary.md), [public API contract](public-api-contract.md) |
| Object/shape layouts | [Architecture](architecture.md), [VM value representation](vm-value-representation-contract.md) |
| Bytecode and opcode contracts | [Compiler contract](compiler-contract.md), [opcode declarations](../src/bytecode/opcode.zig) |

## Evidence and release

- [STATUS](../STATUS.md): dated validation and milestone records.
- [Changelog](../CHANGELOG.md): release history.
- [Release checklist](release-checklist.md): API, lifecycle, and artifact checks.
- [Performance investigation](../GUIDE.md#b8-performance-investigation): diagnostic evidence guidance; historical bench-v8 snapshots are available in Git history.
- [Runtime allocator comparison](runtime-allocator-todo.md): explicit host allocator contract, historical comparison, and remaining experiments.
- [Binary composition](binary-size.md): dated ReleaseFast size breakdown.
- [Retrieval index](../llms.txt): compact project facts for retrieval tools.

`reports/test262-latest/` contains gitignored local output. Removed measurement
archives are available in Git history, not required checkout inputs.

## Remaining investigations

- [JSValue and GC boundary design](value-gc-boundary-design.md): proposed value, root, borrow, and slot contracts with ordered migration checks; not implemented.
- [Host boundary design](host-boundary-design.md): proposed engine/host ownership, public API choice, and ordered migration checks.
- [Nursery evaluation](runtime-nursery-todo.md): recorded correctness blockers and evaluation sequence; disabled by default.
- [Runtime follow-ups](runtime-target-design.md#后续范围): retained capability boundaries and allocator experiments.

Older roadmaps, task registries, and engine/type/process proposals are available
in Git history. Their removal from this index does not cancel product directions;
a new implementation task must establish its scope against current source.

## GC direction

- [GC design boundaries](gc-target-design-review.md): retained target constraints and diagnostic methods; current nursery blockers live in the evaluation above.

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
