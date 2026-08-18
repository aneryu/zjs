# Refactor Tax Policy

This repository prices file-level reorganization of hot-path code as a real
performance tax. The rules below are the policy.

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

## Why

The 0.1.0 CHANGELOG records QCP-1B: shrinking `CompileContext` by one unused
pointer perturbed Zig 0.16 whole-program native layout and caused a crypto
regression, even though bytecode and allocation streams stayed identical.
Benchmark scores in this repository are sensitive to file-level
reorganization. "Maintainability refactors" carry a real performance tax here
and must be priced — which is what the risk zones, the zoo A/B, and the
identity gates do.
