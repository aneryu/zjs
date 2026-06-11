# zjs vs QuickJS reference baseline environment

- Generated: 2026-06-11 (Phase 0 of architecture roadmap)
- Zig version: 0.16.0
- OS: macOS (darwin 24.6.0, Apple Silicon)
- ZJS: `zig-out/bin/zjs` (ReleaseFast)
- QJS: `../quickjs/build/qjs` (QuickJS-ng 0.15.0, CMake Release)
- Benchmark iters: 15, warmup: 3
- Reports:
  - `microbench-vs-quickjs.json` (suite: microbench, 73/73 compatible, 0 failures)
  - `hotpath-vs-quickjs.json` (suite: hotpath, 12/12 compatible, 0 failures)

## Key findings (pre Phase 1)

Whole-process timing includes ~7 ms startup for both binaries, so loop-dominated
cases must be read as marginal cost over the startup baseline.

- Fusion-covered or IC-covered loops (`prop_read_mono_loop`, `vm_int_sum_large`,
  `call2_loop`) are at parity or faster than qjs. Note `call2_loop`-style
  bodies are short-circuited by `cacheSimpleNumericBytecode`, so they do NOT
  measure real call machinery.
- Real call machinery (cases added to the hotpath suite that fusion cannot
  recognize) is the dominant gap:
  - `fib_rec` zjs/qjs = 7.91
  - `call_body_loop` zjs/qjs = 10.40
  - `method_call_loop` zjs/qjs = 9.52
  - `alloc_call_loop` zjs/qjs = 5.63
- Other known losses: `prop_create` 1.49, `weak_map_delete` 1.88,
  `string_slice3` 1.56, `float_toExponential` 1.37, `map_delete` 1.24.

These four call-machinery cases are the Phase 1 acceptance metrics: the goal is
to bring them from ~8-10x down toward low single digits by replacing the
recursive interpreter + per-call heap operand stack with a single interpreter
loop over a contiguous VM stack.
