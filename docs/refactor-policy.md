# Refactor Tax Policy

This repository prices file-level reorganization of hot-path code as a real
performance tax. The rules below are the policy.

> **Temporary suspension (owner ruling, 2026-08-19): the rule-2 zoo A/B
> requirement is suspended.** Hot-path changes that cannot pass an identity
> gate may land on the full test ladder alone. The identity gates and the
> baseline registry remain in force as change-classification instruments
> (run them and record whether machine code changed), but a failed identity
> comparison is information, not a merge blocker, while this suspension
> holds. Reinstate rule 2 before the next official zoo measurement campaign
> re-baselines the headline.

1. Maintainability refactors proceed by risk zone. COLD-zone work — docs,
   build graph, test harnesses, tools, dead-asset removal, and files outside
   the hot path — may proceed freely under the normal validation ladder.
   HOT-zone work (the call chain, array/property runtime, the dispatch core,
   `src/parser.zig`, `src/bytecode.zig`, `src/core/object.zig`) is tracked in
   [maintainability-backlog.md](maintainability-backlog.md) and lands only
   item by item under rule 2.
2. Any split, move, or rename that involves a hot-path file must pass a
   15-item zoo A/B before merge: pad 0 only (the default layout), run under
   the parallel-cluster protocol (`run_zoo_compare.py --parallel-clusters`,
   frozen binaries, clean measurement field), median with no regression.
   (Amended 2026-08-18 by owner ruling; previously ≥3 layout pads.)
3. Pure test-harness and build-graph splits have no layout risk and are
   exempt from rule 2.
4. Mechanical identity gates may substitute for the zoo A/B in rule 2,
   because bit-identical machine code is a stronger guarantee than a
   statistical verdict:
   - **Binary-identity gate**: comment-only edits (including section
     banners) in hot files may merge when the ReleaseFast `zjs` rebuilt
     with identical flags matches the pre-change build on the **stripped**
     image and the extracted `.text` section (`strip` + `md5sum`;
     `objcopy -O binary --only-section=.text`). The full-file hash is not
     the criterion: ReleaseFast emits DWARF, so comment lines legitimately
     move `.debug_line` while shipped code stays bit-identical
     (established 2026-08-18, wave-2 G2 batch).
   - **.text-identity gate**: rename-only or dead-export-only edits may
     merge when the extracted `.text` section is byte-identical. Symbol
     tables may differ; machine code may not.
   A change that fails its gate is demoted to the backlog; it does not merge
   on a "probably fine" basis.
   Compare **converged** builds only: the first incremental compile after a
   merge or branch switch can emit a transiently different image that
   converges once the root module is actually recompiled (`touch
   src/internal_root.zig && zig build zjs`, or a clean cache). Observed
   2026-08-18: a post-merge first build differed, the forced recompile was
   bit-identical to the baseline.
   Identity-gate protocol under build bistability (tightened 2026-08-19 after
   the compiler-rename verification):
   - Compare the **stripped whole image**, not `--only-section=.text`. This
     repository's linker script places the opcode handlers in a separate
     `.text.zjs.op_handlers` section, so a `.text`-only extraction silently
     skips the hot island; the stripped image also covers `.rodata` shifts
     from reflected names or embedded paths.
   - One matching build proves only that the change **can** reproduce the
     baseline image, not that it **always** does. The build is bistable
     (known attractors: incremental-converged vs cold-cache). A pass
     requires closing the attractor set: the changed source and the baseline
     source must each produce byte-identical images **per attractor**
     (converged rebuild vs clean-worktree cold build). A first-build
     mismatch is not a failure verdict by itself — rebuild before
     concluding, then close both attractors.
   - **Baseline registry**: `reports/identity/baseline.json` records the
     verified per-attractor image hashes for the current baseline commit.
     A gate check builds the candidate and compares against the registry;
     do not rebuild the baseline each time. Refresh the registry when main
     moves.
   - **Batch tier** (owner-approved 2026-08-19): mechanical rename/alias
     campaigns may accumulate on a branch with per-change test evidence
     only, then pass **one** identity closure for the whole batch before
     merge. On a batch failure, bisect within the batch. Per-change identity
     gating remains required for hot-path **structural** changes (layout,
     linker script, frame/dispatch surgery).

## Why

The 0.1.0 CHANGELOG records QCP-1B: shrinking `CompileContext` by one unused
pointer perturbed Zig 0.16 whole-program native layout and caused a crypto
regression, even though bytecode and allocation streams stayed identical.
Benchmark scores in this repository are sensitive to file-level
reorganization. "Maintainability refactors" carry a real performance tax here
and must be priced — which is what the risk zones, the zoo A/B, and the
identity gates do.
