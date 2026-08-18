# Changelog

## Unreleased

Target 0.2.0. Maintainability campaign (2026-08-18): breaking public-API
cleanup is approved for this cycle; hot-path structural refactors are
deferred to `docs/maintainability-backlog.md` and land only under the
refactor-policy gates.

- Architecture `check_deps.js` now enforces compiler_v2 layering and scans
  `tools/` / `tests/` files that import the `zjs` module. The duplicate
  core-does-not-import-runtime Zig test is gone; the JS linter is the authority.
- Renamed `quick-check` → `quick-gate`, `checkpoint-check` → `checkpoint-gate`,
  and `test262-gate` → `test262-check`. Old names remain as deprecated aliases
  until the next release. See `docs/testing-graph.md`.
- Package `build.zig.zon` now ships COMPATIBILITY/LIMITATIONS/CONTRIBUTING/
  STATUS and `test262.conf`. mise pins node 24 and bun 1. Linux CI jobs
  install Node (checkpoint and production-gate invoke it via the build graph).
- Unified tests now compile through `internal_root` and assert they are a
  declared superset of it (Object is the only type fork). The previously
  dormant internal Object-identity test is collected (+2 unified tests).
- Scoped test targets now share one `src/<area>_tests.zig` shell ×
  `tests.<area>.` filter convention. Test names gained a `tests.` prefix
  (e.g. `core.test.foo` → `tests.core.test.foo`); counts are unchanged.
  New `test-embedding` target compiles the public `zjs` module.
- Extracted the shared exec/builtins test harness to `src/tests/helpers.zig`.
  `test-builtins` no longer compiles `src/tests/exec.zig`.
- Split `build.zig` into `build/{config,profiles,artifacts,tests,perf,gates}.zig`.
  Option order, step names, and the shipped `zjs` binary are unchanged.
- Refactor policy updated: maintainability work proceeds by risk zone;
  mechanical identity gates (binary-identical / .text-identical) may
  substitute for the zoo A/B where machine code provably does not change.
- Trimmed remaining local report write-outs: disconnected opcode-profile
  snapshots and `reports/test262-latest/` are gitignored. Dated `qjs-align`
  dumps stay in git history; new dated dirs keep markdown notes.
- Removed the public API symbol snapshot. The declaration surface is not
  frozen yet; `docs/public-api-contract.md` and the embedding tests remain
  the contract. `architecture-update-api-snapshot` and
  `tools/architecture/check_public_api.zig` are gone.
- Dropped the named `architecture-check` step. Checkpoint still runs the
  source lints (deps, OOM-panic, borrowed-atom, compiler-stage
  declarations) inline. The production gate adds the ReleaseFast `nm`
  check that those stage-boundary symbols remain independent.
- Dropped legacy-pipeline eradication (`check_legacy_pipelines_gone.js`).
  The remaining gate is `check_compiler_stage_boundaries.js`.
- Narrowed the OOM-panic lint to OutOfMemory-discard and
  catch-unreachable-on-alloc. The remaining allowlist entry is the
  rope-flatten last resort.
- Dropped redundant CLI `--seed 0` from live build commands and docs.
  `build.zig` already pins `graph.random_seed` to `0`.
- Removed `config-drift-gate`, `test262-smoke`, `final-switch-selftest`,
  and `tools/final-switch/`. Compile-time `attest()` and
  `config-signature-check` remain.
- Split validation docs so ReleaseSafe, `test-oom`, `test-altrepr`,
  force-GC, and ownership-audit are phase-close or change-triggered, not
  checkpoint or per-commit gates.

## 0.1.0 - 2026-08-17

First real release, replacing 0.1.0-alpha.1 and 0.1.0-alpha.2. The checked
test262 profile reports zero failures (44,581 pass). The 15-item javascript-zoo
geomean is 1.0141 vs QuickJS. Trusted-code embedding positioning is unchanged:
`zjs` is not an in-process sandbox for hostile JavaScript.

- Completed QCP-1B: removed the legacy Phase 1/2/3 compiler, dual comparator,
  and `-Dzjs_compiler` option. Deletion bisection traced the former crypto
  regression to shrinking `CompileContext` by one unused pointer, which
  perturbed Zig 0.16 whole-program native layout despite identical bytecode and
  allocation streams. The same-sized reserved word was used only as a control;
  the shipped fix restores explicit non-inlined boundaries around V2 lowering
  and the stack-size walk. The no-padding deletion candidate measures 1.0061x
  on the 15-item Zoo A/B. The diagnosis and amended verdict are in
  `docs/qcp1_switch_decision.md` §9.
- Fixed Array sort writeback when an indexed setter mutates a successor
  element, Error.prototype.stack setter edge cases, and TypedArray
  DefineOwnProperty detach-during-conversion semantics.
- Removed the historical C QuickJS performance comparison workflow and
  `perf-compare`; the checked performance gate is the ZJS self-baseline.
- Added a `run_runtime_profile.js` helper and `zig build perf-uri-profile`
  shortcut for checked single-script `--perf-json` artifacts that stay separate
  from multi-case microbench reports.
- Extended checked runtime-profile artifacts with opcode summary rows and added
  opcode-specific runtime diff metrics such as `opcode_count:get_var_ref0`.
- Added deterministic opcode-count ceilings to checked runtime-profile runs so
  focused hot-path fusions fail loudly when their opcode reductions disappear.
- Added `diff_runtime_profile.js` so single-script runtime profiles can be
  compared with explicit timing/allocation regression and improvement gates.
- Added an empty checked-local int32 for-loop range skip for loops whose body is
  only the induction update, reducing the `empty_loop` profile from 60007
  opcodes to 7 while preserving interrupt fallback.
- Added a dense array indexed append fast path for simple int32 multiply/mask
  element expressions while preserving inherited indexed setter fallback.
- Added a var-local int32 arithmetic-store fast path for microbench-style loop
  bodies without changing loop condition or post-update semantics.
- Added narrow `String.fromCharCode` and `Math.min`/`Math.max` method-call fast
  paths that keep object coercion and monkey-patched methods on the generic
  call path.
- Added local, closure, and global simple-numeric bytecode call add-store fast
  paths for tight `acc += fn(i, c)` loops while preserving non-simple function
  side effects.
- Tightened the URI 4-byte decode comparison fast path to use a borrowed
  native-method guard instead of transient method value dup/free churn.
- Shortened the percent-hex simple string add-store path used by URI decode
  fixtures by avoiding the transient helper result value before global writeback.
- Added a guarded `make_var_ref` assignment fusion for `global = string +
  percentHex(int)` loops so reference setup and `put_ref_value` are skipped when
  all participating bindings are ordinary global data properties.
- Added matching global-string and literal-prefix declaration initializer
  fusions for `var next = prefix + percentHex(int)` and `var next = "%F0%A0" +
  percentHex(int)`, eliminating the URI 4-byte profile's remaining
  `get_var_ref0` executions.
- Added a backward-goto global int32 condition fusion that replays the target
  loop condition directly at the backedge when it is an ordinary global data
  comparison, reducing the URI 4-byte profile's `get_var` executions by 66576.
- Extended the URI strict-equality branch-count fusion to ordinary global data
  `count++`, reducing the URI 4-byte profile's `if_false8` executions from
  65536 to 1 and its `get_var` executions by another 65535.
- Refreshed active documentation to match the current build steps, test262
  boundary, ZJS self-baseline performance gate, and tracked active reports.
- Removed the completed Production v1 roadmap from the active docs; public API,
  compatibility, and release-checklist docs are the current authorities.
- Merged the small Compatibility v1 summary into `COMPATIBILITY.md` so the
  compatibility boundary has one active source of truth.
- Removed old one-off test262 slice and QuickJS comparison report directories
  from `reports/`; the active gate report remains `reports/test262-latest/`.
- Removed the future-oriented Bun/uWS GC design note from the active docs; the
  current GC boundary remains documented in `README.md` and `LIMITATIONS.md`.
- Removed the unused opcode-alignment report snapshot from `reports/`.
- Removed historical phase/ledger documents from the active tree:
  `docs/gc-memory-lifecycle-candidates.md`, `docs/perf/roadmap.md`, and
  `reports/perf/baseline/phase-a-baseline.md`.

## 0.1.0-alpha.2 - 2026-05-22

- Added an explicit `--leak-check` CLI strategy to cleanly execute engine deinitialization (`runtime.deinit()`) and perform GPA memory validation on demand.
- Created `LIMITATIONS.md` providing architectural transparency regarding garbage collection circular references, FFI, CommonJS vs ESM, and standard library support.
- Created `COMPATIBILITY.md` detailing the active test262 test suite configuration, skipped features/categories, and recently added progressive ES2024+ features.
- Refactored `README.md` first-screen positioning text and added references to compatibility and limitation docs.

## 0.1.0-alpha.1 - 2026-05-20

- Reached a clean active local test262 gate: 0 errors and an empty
  `test262_errors.txt`.
- Improved WeakMap, WeakSet, WeakRef, and FinalizationRegistry handling for
  non-registered Symbol weak keys and targets.
- Fixed strict script top-level `this`, bound function `toString`, TypedArray
  descriptor behavior, BigInt typed array 64-bit wrapping, Array species
  creation, Annex B direct eval function behavior, and multiple RegExp
  Unicode/property escape paths.
- Added focused Zig regression coverage for the compatibility fixes above.
- Added public release metadata and package manifest paths.
