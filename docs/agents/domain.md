# Domain docs

This repository uses a single domain-documentation context.

## Before exploring

- Read `CONTEXT.md` at the repository root when it exists.
- Read ADRs under `docs/adr/` that touch the area being changed.

If either location does not exist, proceed silently. Domain documents and ADRs
are created lazily when terminology or architectural decisions are resolved.

## Vocabulary

Use the terms defined in `CONTEXT.md` in issue titles, tests, implementation
notes, and refactoring proposals. If a needed concept is absent, first check
whether the repository already uses a different term; otherwise record the gap
for a future documentation session.

## ADR conflicts

Surface any conflict with an existing ADR explicitly instead of silently
overriding the decision.
