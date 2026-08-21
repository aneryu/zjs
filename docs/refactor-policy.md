# Refactor Tax Policy

This repository prices file-level reorganization of hot-path code as a real
performance tax. The rules below are the policy.

> **Rule 2 is back in force (owner ruling, 2026-08-19).** The suspension was
> granted for the maintainability campaign, which has closed. The measuring
> instrument changed with it: rule 2 is now a **bench-v8** A/B, not the
> 15-benchmark zoo. bench-v8 is the published metric, so the gate protects the
> number the project actually claims, and its serial protocol costs about an
> hour per item instead of the zoo's half day — the cost that drove the gate
> into suspension in the first place. The zoo stays as the broader attribution
> instrument; it is not a merge gate.

1. Maintainability refactors proceed by risk zone. COLD-zone work — docs,
   build graph, test harnesses, tools, dead-asset removal, and files outside
   the hot path — may proceed freely under the normal validation ladder.
   HOT-zone work (the call chain, array/property runtime, the dispatch core,
   `src/parser.zig`, `src/bytecode.zig`, `src/core/object.zig`) is tracked in
   [maintainability-backlog.md](maintainability-backlog.md) and lands only
   item by item under rule 2.
2. Any split, move, or rename that involves a hot-path file must pass a
   bench-v8 A/B before merge: the candidate `zjs` against a frozen build of
   the merge base, medians, no regression on the composite Score.

   ```sh
   flock -x /tmp/zjs-host-heavy.lock taskset -c 5-9,15-19 \
     python3 tools/perf/bench_v8/run_benchv8_compare.py \
       --zjs <candidate> --baseline <merge-base build> \
       --parallel-clusters 5-9 15-19 \
       --samples 8 --output /tmp/refactor-ab.json
   ```

   `--baseline` (rather than `--qjs`) is what puts the tool in A/B mode; the
   printed table and the JSON artifact then name the reference as `baseline`,
   so the result cannot later be misread as a QuickJS comparison. Both
   binaries must be frozen before the first sample and the measurement field
   must be clean (no orphan builds, affinity pinned as the script enforces).

   The A/B runs the two-cluster parallel protocol: each lane starts both
   engines at the same instant, one per cluster, and the engine-to-cluster
   assignment swaps every batch so per-cluster bias cancels. Rule 2 consumes
   only the ratio, which is what makes this legal — and simultaneous execution
   cancels host drift more directly than serial ABBA can. It costs about two
   minutes instead of thirteen. The published `--qjs` metric is an absolute
   score and stays serial; the tool refuses `--parallel-clusters` there.
   (Amended 2026-08-20: the A/B adopted the two-cluster protocol the zoo has
   run since the 2026-08-19 owner ruling — the bench-v8 runner was written
   without it when the instrument moved, and rule 2 had inherited the serial
   command. Amended 2026-08-19 by owner ruling: the instrument moved from the
   15-item zoo to bench-v8 when bench-v8 became the published metric. Amended
   2026-08-18: pad 0 only; previously ≥3 layout pads.)
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
   Identity-gate protocol under build bistability (tightened 2026-08-19 after
   the gates-audit verification):
   - Compare the **stripped whole image**, not `--only-section=.text`. This
     repository's linker script places the opcode handlers in a separate
     `.text.zjs.op_handlers` section, so a `.text`-only extraction silently
     skips the hot island; the stripped image also covers `.rodata` shifts
     from reflected names or embedded paths.
   - **The build reaches more than one image from one source, and the build
     protocol does not decide which.** Measured 2026-08-19 on 711cbfc6: three
     incremental rebuilds of the *unmodified* tree produced two different
     images, in a different order than three rebuilds of the changed tree
     produced the same two. So a single build — matching or not — is not a
     verdict in either direction.
   - A pass is therefore a **set** comparison, not a hash comparison: sample
     at least 3 incremental rebuilds per source plus one cold-cache build,
     and require that the candidate lands only inside the set of images the
     baseline source produces. A candidate image outside that set is a
     failure; a candidate that reproduces the set is machine-code-identical.
   - **Baseline registry**: `reports/identity/baseline.json` records that
     admissible set for the current baseline commit. A gate check samples the
     candidate and compares against the registry; do not re-sample the
     baseline each time. Refresh the registry when main moves.
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
and must be priced — which is what the risk zones, the bench-v8 A/B, and the
identity gates do.
