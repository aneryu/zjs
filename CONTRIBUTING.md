# Contributing

Contributions are GitHub pull requests against this repository.

## Semantics

QuickJS is the semantic reference. When Zig behavior and QuickJS disagree on an
in-scope feature, treat the difference as a bug unless the change records an
intentional, reviewed divergence.

## Tests

Add or update focused tests for the change. Run the cheapest matching
validation tier in [GUIDE.md](GUIDE.md) Part B.6. Do not treat “compiles +
smoke green” as semantic completeness.

## Hard rules

- Do not widen `test262.conf` skips or excludes to manufacture a pass.
- Do not skip, delete, weaken, or rewrite tests to make them pass.

## Style and review

Ownership, errors, and Zig style: [GUIDE.md](GUIDE.md) Part A.
Agent and pre-commit discipline: [AGENTS.md](AGENTS.md).
Current source map: [docs/architecture.md](docs/architecture.md).
