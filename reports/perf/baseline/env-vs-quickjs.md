# zjs vs QuickJS reference baseline environment

- Generated: 2026-06-13 (architecture review round 5 refresh: string rope tail)
- Zig version: 0.16.0
- OS: Linux 6.17 (aarch64, Cortex-X925)
- ZJS: `zig-out/bin/zjs` (ReleaseFast, default options at capture time; that
  2026-06-13 build used the then-default `zjs_nan_boxing=true` 8-byte
  representation. Current 64-bit defaults use the 16-byte representation.)
- QJS: `../quickjs/build/qjs` (QuickJS-ng 0.15.0, v0.15.0-4-g967aa0b, CMake
  Release with mimalloc)
- Benchmark iters: 30, warmup: 3
- Reports:
  - `microbench-vs-quickjs.json` (suite: microbench, 73/73 compatible, 0 failures)
  - `hotpath-vs-quickjs.json` (suite: hotpath, 12/12 compatible, 0 failures)
- Key engine changes since the previous baseline (2026-06-11): string rope tail
  buffer (`s += part` chains now extend an unmaterialized rope in place instead
  of allocating one ~150-byte node per concatenation; 1M-iteration `+=` loop
  MaxRSS 161 MB -> 21 MB), `tryFuseGlobalStringAppend` fusion for top-level
  accumulators, single-loop VM/scope-lowering work from the interleaving phases.

Geomean vs previous baseline (2026-06-11, macOS Apple Silicon, iters 15 — note
the host changed, so cross-version deltas mix machine and engine effects):
microbench 0.7933 -> 0.7160, hotpath 1.1352 -> 0.9291 (zjs/qjs, lower is
better).

## Key findings (current round)

Whole-process timing includes ~1 ms startup for both binaries on this host, so
loop-dominated cases must be read as marginal cost over the startup baseline.

- Fusion-covered or IC-covered loops (`prop_read_mono_loop` 0.04,
  `vm_int_sum_large` 0.05, `call2_loop` 0.05) remain far ahead of qjs. Note
  `call2_loop`-style bodies are short-circuited by
  `cacheSimpleNumericBytecode`, so they do NOT measure real call machinery.
- String accumulation is now a win: `string_concat_loop` 0.40 and
  `map_string_keys` 0.53 (rope tail append keeps `+=` loops O(1) per step and
  flatten-free until first read).
- Real call machinery is still the dominant gap (hotpath suite):
  - `fib_rec` zjs/qjs = 7.11
  - `call_body_loop` zjs/qjs = 5.92
  - `method_call_loop` zjs/qjs = 7.06
  - `alloc_call_loop` zjs/qjs = 6.22
- Other known losses (microbench): `prop_create` 1.95, `string_concat1` 1.88
  (single short-string `+`, allocation-bound, not the `+=` chain case),
  `global_destruct_strict` 1.85, `sort_bench` 1.81, `float_toString` 1.76,
  `regexp_ascii` 1.72; hotpath `array_sparse_length_loop` 2.82 and
  `regexp_test_cached_loop` 1.14.

The four call-machinery cases remain the acceptance metrics for the call-path
work: the goal is low single digits via the single interpreter loop over a
contiguous VM stack and leaner call frames.
