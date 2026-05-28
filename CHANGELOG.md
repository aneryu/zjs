# Changelog

## Unreleased

- Refreshed active documentation to match the current build steps, test262
  boundary, comparison tools, and tracked performance report.
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
