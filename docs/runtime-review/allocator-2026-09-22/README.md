# Runtime allocator comparison — 2026-09-22

This is a local Linux/aarch64 ReleaseFast comparison of the host backing allocator, not a whole-engine allocator replacement. Raw inputs and identity are in [environment.json](environment.json); all samples are retained in [samples.csv](samples.csv) and [long-samples.csv](long-samples.csv).

Build: `zig build runtime-allocator-bench -Doptimize=ReleaseFast`. Run: `./zig-out/bin/runtime-allocator-bench <c|smp> <recreate|persistent|parallel> <rounds>`. Source: [allocator_bench.zig](../../../tools/runtime/allocator_bench.zig).

## Before A9 (historical baseline)

The short screen took 17–39 ms and showed substantial timing variance, so it was retained but not used for selection. The longer runs use four repetitions with alternating candidate order: 3000 Runtime lifecycles, 8000 evals in one Runtime, and four concurrent Runtimes with 1500 evals each. Every evaluation checks the same result. Thread failures fail the process.

| Scenario | Allocator | Median seconds | Range seconds | Median sampled peak MiB | Median RSS after destroy MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| recreate | c | 1.6522 | 1.5909–1.7326 | 4.74 | 4.39 |
| recreate | smp | 1.6377 | 1.6147–1.7078 | 4.78 | 4.39 |
| persistent | c | 2.2786 | 2.2019–2.4542 | 125.40 | 4.71 |
| persistent | smp | 2.2811 | 2.2383–2.3181 | 128.96 | 8.23 |
| parallel | c | 0.4759 | 0.4580–0.4846 | 98.47 | 5.48 |
| parallel | smp | 0.4886 | 0.4877–0.4953 | 103.89 | 12.22 |

Initial decision: c_allocator was the candidate based on retained RSS; this baseline preceded A9 and the final F1 API. The final decision and new samples are below.

Scope and limitations:

- GC slab/nursery use their existing independent backing, block/extent storage keeps its page allocator, and audit metadata keeps its existing route. These are not candidates in this comparison.
- This historical baseline still used transitional MemoryAccount facades. The post-A9 measurement below uses the final direct production-native path.
- Peak RSS is sampled after each eval, not a kernel high-water mark. After-destroy RSS is immediate, not a long idle/decay measurement. RSS includes process, GC and allocator state.
- The parallel case has four worker threads, each owning its Runtime. Its shorter duration makes small timing differences less conclusive.
- This is one allocation-heavy JS corpus, one machine and one libc; no claim is made for Windows/macOS or other workloads.
- The optional ordinary-allocation slab A/B and nursery strategy study are still separate TODOs; neither was silently mixed into this experiment.


## After A9 — final default selection (2026-09-23 local)

Raw samples: [post-a9-samples.csv](post-a9-samples.csv). Source/binary identity, Zig, libc and protocol: [post-a9-environment.json](post-a9-environment.json).
The final source passed the full unit suite and batch-gate-profile before measurement. Four repetitions per allocator/scenario ran as serial processes after builds and gates finished, alternating c/smp order. Every result checksum was checked. Same workloads and round counts as the baseline; this is a fresh within-version allocator comparison, not a controlled before/after speedup claim.

| Scenario | Allocator | Median seconds | Range seconds | Median sampled peak MiB | Median RSS after destroy MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| recreate | c | 1.6571 | 1.5144–1.6892 | 4.73 | 4.37 |
| recreate | smp | 1.6775 | 1.5182–1.7148 | 4.78 | 4.39 |
| persistent | c | 2.2307 | 2.1989–2.2456 | 121.46 | 4.64 |
| persistent | smp | 2.2494 | 2.1701–2.3331 | 129.54 | 7.34 |
| parallel | c | 0.4774 | 0.4679–0.4815 | 96.77 | 5.48 |
| parallel | smp | 0.4800 | 0.4760–0.5020 | 101.54 | 9.49 |

Final decision: `Runtime.create(.{})` uses `std.heap.c_allocator`; `.allocator` overrides it in the same options object. The measured long-lived and parallel workloads retain less RSS after destruction with c_allocator. Timing ranges overlap, so these samples do not establish a general throughput winner. No cross-platform claim is made.

Production native allocations now go directly to the selected allocator, without a MemoryAccount facade or full native-allocation ledger. GC slab/nursery/block/extent backing remains unchanged and outside the candidate switch. Sampling limitations above still apply. Extra native-slab, nursery-strategy, long-idle and cross-platform studies remain separate TODOs.

The identity files freeze the A9 delivery snapshot. Subsequent adversarial-review
fixes to checkpoint boundaries and budget retry are recorded in
[the runtime plan](../../runtime-target-design.md#13-交付后对抗性审查2026-09-23).
Those fixes did not rerun this benchmark; the table is not a measurement of
any later source tree.
