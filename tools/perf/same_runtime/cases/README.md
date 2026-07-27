# Same-runtime case provenance

These sources are callable adaptations for the compile-once/execute-many
harness. A shared case name does not mean that this layer measures the exact
same source shape as the process-level comparison tools.

- `global_write_loop`: adapted from
  `tools/compare/hotpath_cases.js`. The strict 100,000-write loop and
  top-level `var g` remain, but the loop is placed in retained `run()` so one
  compilation can feed repeated calls.
- `prop_read_mono_loop`: adapted from
  `tools/compare/hotpath_cases.js`. Its object and accumulator are top-level
  lexical bindings there; here both are function locals recreated by each
  `run()` call.
- `fib_rec`: adapted from `tools/compare/hotpath_cases.js`. The process case
  declares `fib` at top level and invokes it once; here `fib` is an inner
  closure recreated by each `run()` call.
- `call_body_loop`: adapted from `tools/compare/hotpath_cases.js`. The process
  case has top-level `f` and accumulator bindings; here `f`, its closure, and
  the accumulator are local to each `run()` call.
- `method_call_loop`: adapted from `tools/compare/hotpath_cases.js`. The
  process case creates its receiver and accumulator at top level; here both
  are recreated inside each `run()` call.
- `typed_array_read`: intentionally a different workload from the same-name
  `tools/compare/microbench_cases.js` case. The microbench only constructs a
  16-byte-buffer `Int32Array` and observes its length. This case initializes
  1,024 elements and performs 250,000 indexed reads so repeated VM execution
  is measurable.
- `typed_array_write`: intentionally a different workload from the same-name
  `tools/compare/microbench_cases.js` case. The microbench performs one indexed
  write and prints it. This case performs 250,000 indexed writes and then a
  1,024-element checksum pass.

The callable shapes are necessary because each harness evaluates the source
once, retains global `run`, and invokes that function for warmup and timed
samples without recompiling the source.
