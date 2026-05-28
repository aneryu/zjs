# Git Subtree + zjs Integration Architecture

This document is a short pointer. The full authoritative contract lives at the
repository root:

**`docs/fun_zjs_subtree_architecture.md`** (2026-05-28)

Read it for:

- Recommended final tree (`third_party/zjs/`, `src/js/`, `src/runtime/vm/`, `src/tooling/*` ...)
- Git subtree add/pull/push/split workflow (with and without `--squash`)
- Layering rules and the "唯一深耦合层" principle
- `build.zig` module graph
- `src/js` facade sketches and `runtime/vm` host hook implementation pattern
- Migration phases (0–8)
- Code review rules and the import guard

All structural work and any change that touches zjs embedding must be consistent
with that document. This file exists only so that `docs/architecture/` can serve
as a convenient index for future deep-dive notes (layering.md, event-loop.md, etc.).
