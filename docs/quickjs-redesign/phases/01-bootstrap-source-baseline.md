# Phase 1: Bootstrap And Source Baseline

Status: completed

## Goal

Recreate the minimal source tree and build wiring needed to start the rewrite
without depending on deleted engine paths. Establish source baseline metadata,
port status tracking, and the first Zig test gate.

## QuickJS References

- `quickjs/quickjs.c`
- `quickjs/quickjs.h`
- `quickjs/quickjs-opcode.h`
- `quickjs/quickjs-atom.h`
- `quickjs/list.h`
- `quickjs/cutils.h`
- `quickjs/libregexp.c`
- `quickjs/libregexp-opcode.h`
- `quickjs/libunicode.c`
- `quickjs/libunicode-table.h`
- `quickjs/libbf.c`
- `quickjs/libbf.h`
- `quickjs/dtoa.c`
- `quickjs/run-test262.c`
- `quickjs/test262.conf`

## Target Files

- `src/engine/root.zig`
- `src/engine/source.zig`
- `src/engine/status.zig`
- Subsystem `root.zig` files under `core`, `frontend`, `bytecode`, `exec`, `builtins`, and `libs`
- `src/tests/quickjs_port.zig`
- `build.zig`

## Work Breakdown

- [x] Create directory tree from the root plan.
- [x] Add empty subsystem root modules that compile.
- [x] Add `source.zig` with QuickJS commit, included source list, excluded components, and source mapping entries.
- [x] Add `status.zig` with subsystem records and states: `not_started`, `in_progress`, `validated`, `out_of_scope`.
- [x] Add tests that reject `validated` status without source mapping.
- [x] Replace stale `build.zig` references to deleted files with only existing roots.
- [x] Add `test-quickjs-port` build step.
- [x] Ensure the root module exports only stable placeholder API names needed by tests.
- [x] Define bootstrap module names and build-step names before adding implementation modules.

## Bootstrap Export Contract

During Phase 1, `src/engine/root.zig` may export only:

- Source metadata types from `source.zig`.
- Status metadata types from `status.zig`.
- Empty subsystem namespaces needed for import-shape tests.

It must not expose placeholder runtime behavior that looks executable. Public
`Engine`, `Runtime`, `Context`, and `Value` APIs begin in Phase 2 unless tests
only assert type names without execution behavior.

## Validation

```bash
zig fmt .
zig build test-quickjs-port --summary all
git diff --check -- QUICKJS_REDESIGN_PLAN.md docs/quickjs-redesign
```

## Exit Checklist

- [x] `src/engine/` tree exists and contains no `src/engine/vm/`.
- [x] `build.zig` has no stale deleted root references.
- [x] `source.zig` records the QuickJS semantic baseline.
- [x] `status.zig` represents all planned subsystems.
- [x] `zig build test-quickjs-port --summary all` passes.
- [x] `TRACKING.md` phase board and validation log are updated.
- [x] No Phase 1 root export pretends to evaluate JavaScript.

## Handoff Notes

- `zjs`, `run-test262`, smoke, and VM-only build steps are intentionally absent
  until Phase 8 or the required lower layers exist. This avoids stale roots and
  executable placeholders during the bootstrap phase.
