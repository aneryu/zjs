# GC Stage 0 fast screen

Stage 0 is a fail-first filter for committed GC changes. It exists to expose a
large counter or lifecycle regression before the candidate spends the much more
expensive correctness and formal performance budget. A PASS only means “proceed
to Stage 1”; it is not a formal performance verdict and cannot waive any line in
[`docs/verification-policy.md`](../verification-policy.md).

The screen always uses measurement field A on CPU9. Both the GC snapshot and
PMU phases acquire the canonical field and host-token locks through
`measure_fields.py`; `gc_stats_snapshot.py --allow-field-cpu` accepts CPU9 only
under that exact affinity and attestation, while its default reserved-CPU refusal
is unchanged. Evidence is labelled `resolution >=0.5% (coarse)`, and no command
runs on CPU19. Instructions and cycles come from the minimum legal two-sample
paired ABBA run per workload; minflt and maxrss come from `/usr/bin/time` around
those same executions. Cycles use the existing
fixed-work runner's user+kernel event. A STOP attribution uses user-only sampled
cycles because it is a symbol diagnostic, not a counter ratio.

## Freeze a baseline once

```sh
mise run stage0-freeze -- --commit <h-pre0-sha> --out .scratch/h_pre0
```

The command creates a detached worktree, takes the exclusive host build lock,
pins the cold ReleaseFast build to CPUs `0-4,10-14`, and writes exactly the four
required artifacts:

- `zjs`: the frozen ReleaseFast executable;
- `gc-stats.snapshot.json`: one structural snapshot of the GC-heavy six;
- `pmu.json`: the two-sample paired-ABBA field-A self-check captured at freeze time;
- `identity.txt`: commit, binary SHA-256, config signature, placement, and time.

An existing output directory is never overwritten. The detached worktree and
cold build caches are temporary; only the four artifacts remain.

## Screen a candidate

```sh
mise run stage0 -- --base .scratch/h_pre0
mise run stage0 -- --base .scratch/h_pre0 --candidate /path/to/zjs
mise run stage0 -- --base .scratch/h_pre0 --candidate /path/to/zjs --cross-layout
mise run stage0 -- --base .scratch/h_pre0 --benches splay earley-boyer
```

Without `--candidate`, Stage 0 first performs a warm ReleaseFast build of the
current tree under the host build lock and the same small-core pool. Results are
saved under `.scratch/stage0/<UTC>-<pid>/` as a JSON artifact, a Markdown table,
the candidate stats snapshot, and the paired PMU/time artifact.

For every selected workload the table reports candidate/baseline instructions,
cycles, minflt, maxrss, committed bytes, and the fixed lifecycle-drift flag. The
reported lifecycle fields are hot-reuse publications, reopened blocks, deferred
block runs, major and minor collection counts, minor STW total, committed bytes,
and Pass-A settled cells. Minor count, deferred runs, and Pass-A settled cells
are deterministic hard guards at ±10% (a zero baseline may only stay zero).
Major count, minor STW total, hot reuse, reopened, and committed are
phase-sensitive: their direction and magnitude remain visible but do not cause
STOP. Other >10% snapshot movements are retained in a diagnostic appendix.

The screen stops when any instruction ratio exceeds `1.005`, any cycle ratio
exceeds `1.020`, or a deterministic lifecycle field moves by more than 10%.
Cycle ratios from `1.005` through `1.020` are marked `待正式` and proceed to
Stage 1; the formal gate must resolve them. An intentional
representation/layout comparison must pass
`--cross-layout`; without it a mismatch is rejected before measurement. The
cross-layout artifact preserves both signatures and ignores only that identity
field during stats comparison—it never edits the raw snapshots. On STOP, the
tool profiles the worst PMU workload when one exists (otherwise the worst
lifecycle workload), records both arms with `cycles:u`, and emits the top 15
symbol deltas by candidate minus baseline samples.

Exit status is `0` for PASS, `3` for STOP, and `2` for an invalid or incomplete
run. `--benches` is useful for iterative attribution, but the mandatory Stage 0
gate uses all six workloads. Keep the frozen directory: rebuilding its baseline
arm defeats the purpose of this stage.
