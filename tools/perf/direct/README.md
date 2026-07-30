# Direct/core benchmark scaffold

This harness bypasses JavaScript parsing, bytecode dispatch, and the VM for the
measured kernel loops. Run the complete pinned comparison with:

```sh
zig build perf-direct --seed 0
```

Driver options are passed after `--`, for example:

```sh
zig build perf-direct --seed 0 -- \
  --cpu 19 --samples 6 --iterations 200000 --warmup 10000 \
  --output .zig-cache/perf/qjs-align/direct/manual.json
```

`perf-direct-build` only builds and installs `zjs-direct-bench`. The driver
compiles its C harnesses from sources in this directory and reads the pinned
QuickJS tree without modifying it. C harnesses are compiled on demand: the
archive-linked harness is skipped for a BigInt-only selection, and the
`quickjs.c`-including BigInt harness is skipped unless BigInt is selected.
Skipped builds are reported as `skipped (case not selected)` with a null
duration and command.

The default is six samples so the ABBA schedule has equal first-position
counts. An odd `--samples` value is allowed but prints a warning; metadata then
records `sampling_first_position_balanced: false` and the observed qjs/zjs
first-position counts. Because balanced sampling is part of provenance,
an odd-sample result is not comparable and the collector exits non-zero after
writing it.

## Caliber and fidelity

| Case | zjs entry | QuickJS entry | Pair fidelity | Comparable |
| --- | --- | --- | --- | --- |
| `dtoa/mixed-free` | `libs/number_format.formatDtoa` | `js_dtoa` | `true-direct` | yes |
| `regexp/exec-latin1` | `libs/regexp.execCaptureSlotsSliceTrustedWithOptions` | `lre_exec` | `true-direct` | yes |
| `property_lookup/own-data` | `core.Object.getProperty` | `JS_GetPropertyInternal` | `true-direct` | yes |
| `typed_array/int32-get` | `core.typed_array.typedArrayGetIndex` | `JS_GetPropertyUint32` | `public-api-proxy` | no |
| `bigint/mul-multilimb` | `libs/bigint.mulAlloc` | static `js_bigint_mul` | `true-direct` | yes |

QuickJS does not export its inline/static TypedArray element fast path.
`JS_GetPropertyUint32` is therefore labelled `public-api-proxy`; its paired
record is excluded from headline ratios even though both sides produce and
cross-check the same values.

The BigInt C harness uses the explicitly isolated translation-unit technique:
it includes pinned `quickjs.c`, calls static `js_bigint_mul`, and links
`dtoa.c`, `libregexp.c`, `libunicode.c`, and `cutils.c` directly instead of
linking `libquickjs.a`. Its compile duration is recorded separately because the
large translation unit is materially more expensive to compile.

The general QuickJS harness links `libquickjs.a`. It deliberately does not
redefine `lre_realloc`, `lre_check_stack_overflow`, or `lre_check_timeout`;
those symbols come from `quickjs.o`, and the RegExp case passes a live
`JSContext` as their opaque allocator/stack-check state.

### Known zjs-only bias in `property_lookup/own-data`

`core.Object.getProperty` and `hasProperty` open with
`profile.recordPropLookup(self.isGlobal())` (`src/core/object.zig:9025` and
`:9035`). That hook has no QuickJS counterpart, so the zjs side of this case
pays a threadlocal load plus a null check on every timed iteration that the
QuickJS side does not.

It is left in place on purpose: `src/**` is out of scope for the measurement
layer, and the bias runs **against** zjs (removing it can only make the zjs
number smaller). Treat the published `property_lookup` ratio as an upper bound
on zjs cost, not a neutral measurement.

`active_profile` is a `threadlocal var ?*OpcodeProfile` defaulting to `null`
(`src/core/profile.zig:132`) and this harness never installs a profile, so the
hook always takes the null branch — the cost is the load and branch, not the
counter update. Removing or comptime-gating it belongs to the Phase 2
global/property work (PRD §7), where it is a genuine fixed tax on the shared
QJS path rather than a harness artifact.

## Timing and anti-DCE

Object/runtime construction, atom creation, TypedArray initialization, RegExp
compile/capture allocation, and BigInt operand parsing happen before
`ns_total` timing. Kernel-required result allocation and release remain inside
the BigInt loop. Property reads time the returned value retain/release on both
sides. RegExp times execution only.

Every warmup checksum seeds the timed checksum, and every timed checksum is
printed. The per-case dependencies are:

- dtoa hashes every output byte and uses the accumulator plus iteration to
  select the next double;
- RegExp hashes the kernel status and capture offsets;
- property lookup uses the accumulator to select an atom and hashes the
  returned integer;
- TypedArray uses the accumulator to select an index and hashes the returned
  integer;
- BigInt uses the accumulator to choose operand order and hashes the result's
  low limb before releasing it.

The same 64-bit FNV-style accumulator runs on both engines. This work is part
of the measured loop, and the exact checksum is compared across engines.

The driver runs each sample as `qjs -> zjs`, then `zjs -> qjs`, repeating that
ABBA order. Each engine position runs the requested main invocation and a
baseline invocation with `iterations=1` and the same warmup. Both use the same
pinned CPU and perf event set:

```text
instructions, cycles, branches, branch-misses, cache-references, cache-misses
```

`perf stat -x, --output <temporary-file>` keeps perf CSV separate from harness
stderr. The driver discovers the one `armv8_pmuv3_*` device whose sysfs `cpus`
list contains the pinned CPU, requests that PMU explicitly, and rejects a run
whose counted rows do not come from exactly that device. For every event the
parser discards `<not counted>` / `<not supported>` rows. Raw selected rows
retain counter runtime and run percentage so PMU multiplexing or scaling is
visible.

`ns_total` covers only the monotonic-clock kernel loop. Counter fields publish
both scopes:

- `process_scope`: main whole-process count divided by `N`, including setup and
  warmup;
- `loop_only`: `(main(N,W) - baseline(1,W)) / (N - 1)`, the marginal
  per-iteration estimate with setup and the same warmup subtracted.

Each event under `performance_counters` stores `main_raw`, `baseline_raw`,
`iterations`, and `baseline_iterations` next to its derived values. The full
baseline invocation also remains under `baseline`. The primary metric is
`instructions_loop_only`, and the headline is the median of per-sample paired
loop-only ratios. It is never computed as two independent medians divided
together. When `N == 1`, loop-only counters and the headline are null with a
denominator reason.

If `main_raw - baseline_raw` is negative, the raw counts remain intact while
`loop_only_per_op` is null and `loop_only_reason` contains
`below_baseline_resolution`. The driver never clamps a negative delta to zero:
that would turn counter noise into a false zero-cost observation. The case
counter summary becomes `partial` or `unavailable`, and carries the same reason.
Only negative deltas receive this treatment; no additional noise threshold is
applied.

## Validation and exit semantics

Every main and baseline invocation records the observed return code, parsed
stdout result, harness stderr byte count/text (truncated at 4000 characters),
and loop-count echo validation. `perf stat` propagates its child status, and
`taskset` propagates that observed status; the per-invocation `exit_code`
therefore comes from the completed command rather than a constant.

`CASE_DEFINITIONS` is the fixed module-level case registry. Every current case
declares `checksum_required: true`. An unknown case defaults to requiring a
checksum but fails source and provenance comparability because it has no
canonical declaration. Only a registry entry with an explicit
`checksum_required: false` can make absent checksums acceptable; if an optional
case does report checksum evidence, that evidence is still validated.

Every case records four explicit boolean components, each with a nullable
reason:

- `source_comparable`: the case is registered, both harnesses explicitly report
  the same comparable workload/layer, and main/baseline case and loop-count
  echoes match;
- `checksum_comparable`: required main and baseline checksums are present,
  non-empty, explicitly marked comparable, and equal across engines and
  samples, or the case explicitly declares that no checksum is required;
- `metric_comparable`: every paired loop-only-instructions sample and its
  statistics are present, with no harness validation failure;
- `provenance_comparable`: pinned QuickJS HEAD/VERSION/tree cleanliness,
  selected binary hashes, taskset affinity, balanced ABBA sampling, metadata,
  timings, and the single-PMU binding are all explicitly proven.

The top-level value is exactly
`source_comparable && checksum_comparable && metric_comparable &&
provenance_comparable`. Missing, null, or unchecked evidence is a failure, not
a pass. A false component nulls `headline_ratio_zjs_over_qjs`;
`headline_excluded_reason` names every failed component, and the collector exits
non-zero after writing the artifact.

The sole exit-code exemption is an explicit `--no-perf`: the artifact still
records `metric_comparable: false`, a null headline, and
`metadata.metric_comparable_exemption`, and stderr reports the exemption. That
metric component alone does not make the process fail. Any other false
component still does. This is not an exit-line/performance-target exemption;
the collector implements no default performance target gate.

If loop-only instructions and wall time fall on opposite sides of 1.0 and both
differ by more than 2%, the case records `direction_conflict: true` and the
summary prints a warning. This is a diagnostic marker for manual cycles/cache
misses attribution; it does not by itself exclude a case. Detection runs
whenever both ratios exist, even when checksums are not comparable, and the
detail records the observed checksum and overall comparability context.

## Memory and nullable fields

Each harness reads its own `/proc/self/status` `VmHWM` immediately before exit,
so `peak_rss_kb` excludes the perf/taskset wrapper. Harnesses with a runtime
snapshot live allocation state immediately before and after the timed loop;
QuickJS uses `JS_ComputeMemoryUsage`, and zjs uses `JSRuntime.memoryUsage`.
These are live before/after deltas, not fabricated allocation-call estimates.
The zjs harness uses the same compile-time predicate as
`src/core/memory.zig:5` (`builtin.is_test or builtin.mode == .Debug`) to
determine whether allocation count is maintained. In the current ReleaseFast
harness it is not, so zjs allocation count is null with a reason and only
allocated bytes is available for cross-engine memory arbitration. zjs also
emits `@sizeOf(core.JSValue)`, which is the source of the representation
metadata.

Nulls are expected and carry explicit reasons when:

- perf is disabled/unavailable or a requested PMU event is unsupported/not
  counted (the baseline harness invocation still runs for source/checksum
  validation);
- `N == 1` makes baseline subtraction undefined;
- a kernel has no runtime allocation-accounting interface (for example, a
  caller-allocator-only direct kernel);
- `/proc/self/status` cannot provide `VmHWM`;
- an unselected C harness was intentionally not compiled.

`--no-perf` still records wall time and validation evidence, but it does not
substitute wall time for the declared loop-only-instructions headline.
