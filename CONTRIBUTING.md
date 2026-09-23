# Contributing

Submit GitHub pull requests against this repository. zjs is a JavaScript /
TypeScript engine written in Zig; contributions follow the declared product
scope in [LIMITATIONS.md](LIMITATIONS.md).

## Semantics and implementation

ECMA-262 governs JavaScript behavior; test262 validates the configured profile.
Use pinned QuickJS for differential evidence and performance comparisons.
Follow the spec when the reference differs, and document the divergence.
Zig engineering rules are in [GUIDE.md](GUIDE.md) Part A.

## Before submitting

- Keep the change focused and preserve pre-existing work.
- Add regression coverage for changed behavior or invariants. Never weaken
  tests or widen excludes to manufacture a pass.
- Follow [verification policy](docs/verification-policy.md); command details
  are in GUIDE Part B.6. Report the checks actually completed.
- Update the owning contract or documentation when behavior changes.

[AGENTS.md](AGENTS.md) covers execution discipline;
[architecture](docs/architecture.md) maps source owners;
[the documentation index](docs/README.md) routes to other contracts.
