# obj64 stride ablation

Engine-external line/stride microbenchmark for the 96B → 80B → 64B object-cell
ladder. It does not link the engine. The in-engine pad-only arm
(`-Dzjs_obj64_s1_pad=true`) is a separate isolation of the same 80B→96B
question on the real allocator: live field offsets stay at the S1 packing,
arrays stay on the 56 B / 64 B cell, and only the trailing-property ordinary
object is charged 16 extra bytes.

## What it measures

Packed cells at stride 64, 80, and 96. Each cell holds a payload word plus a
`next` pointer, matching the two header loads `shadeExact` makes. Visit
orders:

| order | models |
|---|---|
| `seq` | linear dense scan (adjacent-line prefetch can cover it) |
| `chase` | random linked-list frontier (S0's engine-faithful arm) |
| `shuf` | shuffled indices into packed cells |

Prefetch is one header ahead. Every arm visits each cell once and XORs the
same payload, so a checksum mismatch is a visit-count bug, not noise.

The table's `vs80` / `vs96` columns are the same order+prefetch at those
strides. S0's kill line is the prefetch arm of 64 vs 96.

## Run

```sh
zig build obj64-stride-ablation-test
zig build obj64-stride-ablation -Doptimize=ReleaseFast
taskset -c 17 zig-out/bin/obj64-stride-ablation --cpu 17 --pmu armv8_pmuv3_1 \
    --cells 1048576 --repeats 8 --json obj64-stride.json
```

`--cpu N` pins via `sched_setaffinity` and **exits nonzero** if the CPU is
outside `cpu_set_t`, offline, outside the cpuset, or the resulting affinity is
not exactly `{N}`. Omit it only for a directional unpinned run; booking runs
must pass it. `--quick` drops to 4096 cells / 3 repeats for a sanity check.

On aarch64 the harness binds
`armv8_pmuv3_1/{instructions,cycles,l2d_cache_refill}` by reading the PMU's
sysfs `type` and `events/*` files (not generic `PERF_COUNT_HW_*`), then opens
those configs with `perf_event_open` on the pinned CPU as one counter group.
`--pmu` must own the pinned CPU (`.../devices/<pmu>/cpus`). That is the default
and is fail-closed; `--no-require-pmu` is wall-time only. An x86 cloud reading
is directional: cache-line size is still 64 B, adjacent-line prefetch policy is
not, and generic `PERF_COUNT_HW_CACHE_MISSES` is not L2D refill.

## In-engine pad-only arm

```sh
zig build zjs -Doptimize=ReleaseFast
zig build zjs -Doptimize=ReleaseFast -Dzjs_obj64_s1_pad=true
taskset -c 0 zig-out/bin/zjs --gc-stats tools/perf/obj64_stride/pad_alloc.js
```

Build the pad-on binary into a separate prefix (or a second worktree) so the
two `zjs` artifacts do not overwrite each other. Default is pad-off: production
size classes do not change.

## Kill line (S0, ARM)

If the prefetch arm of 64 vs 96 (or 64 vs 80) is <1.5% cycles and <8%
refill, the line axis is dead and S2 does not ship.

An x86 directional booking (8 MiB DRAM-bound + in-engine 300k `{a,b}` class
histogram) is in [docs/obj64-ablation-2026-09-03.md](../../../docs/obj64-ablation-2026-09-03.md).
It is not an ARM cycles/L2D verdict.
