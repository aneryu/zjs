## Engineering Signoff

- [ ] No fixture-shaped parser, emitter, VM, or builtin shortcut was added.
- [ ] No new broad `anyerror`, empty `catch`, `@ts-ignore`, or test
  weakening was introduced.
- [ ] No public API, validation boundary, skip, or exclude changed without a
  failing scenario and exit criterion.
- [ ] Object/shape/GC/IC ownership rules were preserved, or the owning design
  note was updated.
- [ ] Durable validation evidence is recorded in this PR, the commit message,
  or the owning issue.

## Validation

- [ ] `zig build quick-check --summary all`
- [ ] `zig build checkpoint-check --summary all` for non-trivial code-bearing changes.
- [ ] `git diff --check`
- [ ] Relevant test262 slice:
- [ ] `zig build test262-gate --summary all` for final semantic/bytecode gate evidence.
- [ ] Perf report paths if this change affects performance:

## Rollback Notes
