# Contributing to fun

Thank you for your interest in `fun`! This document focuses on the practical process for contributing, especially around the strong documentation and testing discipline this project maintains.

## Required Reading (in order)

1. [AGENTS.md](AGENTS.md) — The contributor contract. Read this first.
2. [docs/README.md](docs/README.md) — Documentation index and maintenance rules.
3. [docs/testing.md](docs/testing.md) — How we write and evolve tests.
4. [docs/runtime-mvp.md](docs/runtime-mvp.md) — The narrow MVP scope we are currently implementing.

## Development Workflow

1. Make your change (code, tests, or docs).
2. Add or update focused tests for any new behavior.
3. Update the relevant design document(s) in `docs/`.
4. If you changed module ownership or status, update the **Current Implementation Status** matrix in [docs/roadmap.md](docs/roadmap.md).
5. Add an entry to the Decision Log in `docs/roadmap.md` for any material decision.
6. Run the full gate:
   ```sh
   zig fmt build.zig src
   zig build test
   zig build docs-check
   ```
7. Open a PR with a clear description of what changed and why.

## Documentation Discipline

- All public modules must have `//!` module documentation pointing to the relevant design doc(s).
- The status matrix in `roadmap.md` is the single source of truth. Keep it accurate.
- Never describe unimplemented behavior as available.

## Adding Fixture Tests (Future M3+)

When we begin implementing real file execution and the loader:

- Fixture tests will live under `test/fixtures/`.
- See the "CLI Fixtures" and "Integration Tests" sections in `docs/testing.md` and `docs/runtime-mvp.md` for the expected shape.
- Golden files / snapshot tests for diagnostics and REPL output will be added at that time.

## Questions?

Open an issue or start a discussion. We value clear, small, well-tested changes that respect the existing architecture boundaries.

---

This project aims for a high-quality, sustainable codebase. The documentation and testing gates exist to help us get there together.