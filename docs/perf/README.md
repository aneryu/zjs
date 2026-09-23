# Performance Workflow

Local diagnostics for the Zig JavaScript / TypeScript engine. There is no
performance or size merge gate; [verification policy](../verification-policy.md)
defines required correctness checks. The in-tree benchmark runner is retired.

## References

- [bench-v8 status](bench-v8-status.md): historical Octane 2.0 / V8 suite v9
  results, machine details, and QuickJS reference fingerprints.
- [Binary composition](../binary-size.md): dated stripped ReleaseFast breakdown.
- [Object/shape design](object-shape-design.md), [opcode design](opcode-design.md),
  and [backlog](../backlog.md): mechanisms and scoped work.

Compare ratios only within the same suite and reference-binary identity.
Earlier QuickJS-ng, zoo, and V8-v7 results are historical and do not establish
current Bellard-QuickJS performance.

## Build and freeze the measured binary

Default builds are Debug. For production profiling, build ReleaseFast and
freeze the executable before another build can replace it:

```sh
zig build zjs -Doptimize=ReleaseFast
mkdir -p .scratch/profile
cp zig-out/bin/zjs .scratch/profile/zjs
sha256sum .scratch/profile/zjs
```

Keep symbols for attribution; stripping is for release artifacts. Record the
revision/dirty state, compiler, configuration, binary hash, host, workload,
expected output, measurement window, sample order, and command exit status.
Controlled paired comparisons help separate a change from drift or layout
noise; this is evidence guidance, not a mandatory measurement gate.

Do not change frame-pointer settings as a routine profiling step. They can
alter every handler's prologue/epilogue in the tail-call dispatcher. Historical
A/B measurements found substantial overhead; confirm the unwinding needed for
the current question before perturbing the build.

## Runtime profiling

Per-opcode counts require the dedicated profiling binary:

```sh
zig build zjs-profile -Doptimize=ReleaseFast --summary all
./zig-out/bin/zjs-profile --profile-opcodes -e "for(var i=0; i<100000; i++) {}"
```

It enables `vm_profile.noteDispatch` counts and delta timing. The default
`zjs` rejects `--profile-opcodes` (exit 2). Profiling instrumentation changes
execution cost; measure production cost with the uninstrumented binary.

The listing defaults to 40 rows. Set `ZJS_PROFILE_ALL=1` for a complete census;
a truncated table cannot distinguish warm paths from unused ones.

## Linux sampling and PMU counters

Choose a CPU appropriate to the host. On heterogeneous systems, pin to one
cluster/PMU; combining different cores' IPC does not describe one execution.
The following assumes the reproducer is `.scratch/profile/case.js` and CPU 19
has been selected for this host:

```sh
zjs_profile_cpu=19
taskset -c "$zjs_profile_cpu" perf stat -e cycles,instructions,branches,branch-misses \
  .scratch/profile/zjs .scratch/profile/case.js
taskset -c "$zjs_profile_cpu" perf record -F 4999 -o .scratch/profile/case.data \
  .scratch/profile/zjs .scratch/profile/case.js
perf report -i .scratch/profile/case.data --stdio --no-children -q
```

- Check sample coverage on short workloads and record inaccessible kernel work.
- Tail-call dispatch does not retain handler-to-handler call stacks. A flat
  profile answers opcode-cost questions; call graphs help locate VM entry paths.
- Inline functions and shared cold bodies can mislead symbol percentages.
  Resolve sampled addresses with `addr2line -f -i -e .scratch/profile/zjs <ip>`
  before attributing a mechanism.
- Fewer instructions or bytes do not prove lower elapsed cost. Compare
  time/cycles and account for event frequency, dependencies, and layout.
- Keep whole-process and benchmark-inner-loop windows separate. Startup,
  parsing, bootstrap, and teardown can explain a different ratio.

## macOS sampling

Using the frozen executable and reproducer above:

```sh
xcrun xctrace record \
  --template "Time Profiler" \
  --output .scratch/profile/zjs.trace \
  --launch -- .scratch/profile/zjs .scratch/profile/case.js
```

## Functional validation

Performance changes follow the same [verification policy](../verification-policy.md)
and [GUIDE Part B.6](../../GUIDE.md#b6-validation-tiers) as other implementation
work. Preserve focused semantic coverage; do not add per-edit full-suite or
historical measurement gates.
