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

- `local_arith_loop`: not adapted from anything, and deliberately absent from
  `policy.json`. It is an attribution sentinel for opcode hot/cold
  reclassification work: purely local arithmetic and loop dispatch, so a change
  that perturbs dispatch as a whole shows up here while a change confined to one
  opcode does not. Listing it as a policy sentinel would change the P0 exit-line
  geomean, which is why it is only ever selected explicitly.

- `call_empty_0`, `call_identity_1`, `call_identity_4`, `call_8_locals`,
  `call_arguments`, `call_throw`: Phase 3 ordinary-call probes, none of them
  policy sentinels for the same reason as `local_arith_loop`. They are designed
  to be read as differences rather than in isolation: identity_1 minus empty_0
  is the first argument, identity_4 minus identity_1 is argument passing with
  the callee body held constant, 8_locals minus identity_1 is frame geometry,
  and `call_arguments` / `call_throw` are the semantic shapes that must not
  regress when the plain path gets cheaper. The three remaining shapes the plan
  calls for already exist: `fib_rec` is recursion, `method_call_loop` is
  call-method, and `call_body_loop` is call-closure.

- `bigint_mul_2x2`, `bigint_mul_1x8`, `bigint_mul_8x1`, `bigint_mul_8x8`,
  `bigint_mul_16x16`: P6-02 JS-level BigInt allocation-topology probes, not
  policy sentinels. Shapes are ordered -- `AxB` means the left operand has A
  64-bit limbs and the right has B -- because the basecase loop treats operand
  order asymmetrically. Both operands are built once at module scope so the
  retained `run()` times only multiplication, each iteration overwrites the
  result so operand size never grows, and the checksum is `String(r).length`
  rather than the CLI inspector so it is identical across engines.

- `bigint_mul_28x28`, `bigint_mul_28x29`, `bigint_mul_29x29`: P6-03c
  allocation-boundary probes, not policy sentinels. Once a multiplication
  result is one wrapper plus a trailing limb array, the product's size decides
  its allocator route: a 56-byte wrapper plus 56 limbs is exactly 504 bytes,
  the slab's payload ceiling, so capacity 56 is the last slab-eligible product
  and 57 the first standalone one. These three shapes bracket that step
  (56 / 57 / 58 limbs) to show whether crossing it produces a cliff. They run
  2,000 multiplications per `run()` rather than 20,000 because the operands are
  an order of magnitude wider than the shapes above.

The callable shapes are necessary because each harness evaluates the source
once, retains global `run`, and invokes that function for warmup and timed
samples without recompiling the source.
