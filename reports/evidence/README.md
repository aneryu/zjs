# Evidence registry (BASE-G0 layout)

Every **official** number quoted by `roadmap.md`, `STATUS.md`, or a gate
ruling must link to a directory here: `reports/evidence/<WORK-ITEM>/`
containing a `manifest.json` conforming to `manifest.schema.json` in this
directory. A number without an evidence id is a local decision input, not a
project fact (`docs/roadmap.md` §0.2).

Layout:

```
reports/evidence/
  README.md              — this file
  manifest.schema.json   — required manifest shape
  BASE-G0/manifest.json  — the measurement-baseline freeze itself
  <ITEM>/manifest.json   — one per official measurement/gate ruling
  <ITEM>/...             — raw artifacts small enough to check in; larger
                           artifacts stay local and are listed by absolute
                           path + sha256 in the manifest
```

Rules:

- The manifest is written **before** the verdict field is filled; commands,
  binaries, and policies are recorded at run time, not reconstructed.
- Binaries are never checked in; they are pinned by sha256 + build recipe.
  The BASE-G0 frozen set lives outside the repo
  (`/home/aneryu/zjs-frozen/base-g0-2026-08-26/`) and is reproducible from
  the pinned commits + recipe recorded in `BASE-G0/manifest.json`.
- `dirty=false` is mandatory for the measured checkout; the whole-process
  measurement contract's validator refuses dirty-worktree artifacts.
- If a frozen reference moves (e.g. `gc/tracing` advances before `GC-GAP`
  runs), re-freeze first: bump the BASE-G0 manifest version in the same
  commit that records the new fingerprints. Measuring against a stale
  frozen set is not permitted.
