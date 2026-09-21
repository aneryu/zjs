# Performance Workflow

This directory contains performance notes and a historical status snapshot
for `zjs`. Nothing here is a merge gate. Repeatable timing lives outside
this repository. Local `perf stat` remains a host diagnostic;
[verification-policy](../verification-policy.md) is the authority.

Current design notes:

- [bench-v8 status](bench-v8-status.md) — historical snapshot
- [Shipped binary composition](../binary-size.md) — ReleaseFast size by
  section, layer, and function (diagnostic, not a gate)
- [Object and shape implementation](object-shape-design.md)
- [`exec/call_runtime.zig` candidate domains and move criteria](../backlog.md)
- Frozen subsystem baseline (historical):
  `docs/qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md` — removed
  2026-08-25; recover from git history

## bench-v8 (Octane 2.0, v9)

The recorded suite is full Octane 2.0 (since 2026-08-25; all 17 results
since 2026-09-05, when zlib's shell `read` shim landed). The in-tree
runner was removed with `tools/perf`; the snapshot is
[bench-v8-status.md](bench-v8-status.md).

Under the v9 suite there is no owner-ruled *published* metric, and
ratios are only comparable against the same reference-binary fingerprint
(hash + compiler) — see the 2026-08-25 reference-drift adjudication in
[bench-v8-status.md](bench-v8-status.md).

## Checked-In Artifacts

No benchmark result JSON is checked in.

The 2026-06-13 QuickJS-ng `*-vs-quickjs*` snapshots were removed from the
active tree. Do not recover them as a current Bellard-QuickJS comparison.
The historical snapshot is [bench-v8-status.md](bench-v8-status.md). The
former standalone-file zoo runner was retired 2026-08-29. As of 2026-08-25,
no v9-suite number has passed an owner ruling to become a published metric,
and any quoted ratio is only valid against the named reference-binary
fingerprint.

## Runtime Profiling

Per-opcode profiling requires the dedicated profiling build:

```sh
zig build zjs-profile --summary all
./zig-out/bin/zjs-profile --profile-opcodes -e "for(var i=0; i<100000; i++) {}"
```

The profiling build (`-Dzjs_enable_opcode_profile=true`) counts and
delta-times every hot-table dispatch through `vm_profile.noteDispatch`. The
default `zjs` binary does not collect opcode counts and fails closed on
`--profile-opcodes` (exit 2).

The listing is capped at 40 rows to stay readable. Set `ZJS_PROFILE_ALL=1`
to print every opcode — required for a census, since the cap silently
conflates warm-but-not-hot opcodes with cold ones (see
[`opcode-design.md`](opcode-design.md) appendix B.2 for the reading error
that produced).

### Linux sampling and PMU counters

Measured on this host on 2026-08-07 (aarch64 big.LITTLE, Cortex-X925 +
Cortex-A725, Zig 0.16.0, perf 6.17.9). The generic advice found in most Zig
profiling write-ups needs four corrections here; each one below is backed by a
measurement, not by extrapolation.

**Build: use `zig build zjs` as-is. Do not add profiling flags.**

The shipped `zjs` is already `ReleaseFast` with full symbols
(`file` reports `with debug_info, not stripped`; `nm` finds 6199 symbols), so
`-fno-strip` is a no-op here.

`-fno-omit-frame-pointer` is actively harmful. `internal_fast_mod` in
`build.zig` sets `.omit_frame_pointer = true` deliberately, because the
tail-call threaded dispatcher has one handler per opcode and a frame pointer
adds a prologue/epilogue to every one of them. Rebuilding with
`.omit_frame_pointer = false` and comparing interleaved A/B/B/A on pinned CPU
19:

| workload | instructions | cycles |
|---|---|---|
| VM dispatch loop (`s += i`, 60M iters) | 12.173G → 13.614G (**+11.8%**) | 2.272G → 2.831G (**+24.6%**) |
| code-load payload (parse-only) | 12.19M → 12.72M (**+4.4%**) | within noise |

A profile taken on such a build describes a program that is 24.6% slower in the
loop you care about, and the added cost lands *uniformly on every handler*,
which systematically flattens the relative weights you are trying to read.

The premise behind the flag does not hold either: fp unwinding already works
with `omit_frame_pointer = true`, because handlers never touch `x29`, so the
unwinder walks out through the enclosing `runWithCallEnv` frame. A `--call-graph
fp` record against the shipped binary returns complete stacks
(`op_dup;runWithCallEnvAfterInterruptPoll;runWithCallEnv;eval;...`).

**Pin to one CPU cluster — there are two PMUs.**

Unpinned `perf stat` splits every event across both PMUs at roughly half
coverage each and reports two unrelated IPC figures (measured: 3.75 and 5.70);
neither is the program's IPC, and summing them is meaningless because the
clusters differ in frequency and width.

```text
armv8_pmuv3_0 -> CPU 0-4,10-14
armv8_pmuv3_1 -> CPU 5-9,15-19
```

```sh
taskset -c 19 perf stat -e cycles,instructions,branches,branch-misses \
  zig-out/bin/zjs /tmp/case.js
```

Pinned, the counters collapse onto a single PMU and IPC becomes real. The rows
for the other PMU correctly read `<not counted>`.

**Prefer a flat profile; `-g` adds little for the dispatch loop.**

Under tail-call threading the handler-to-handler `musttail` transfer leaves no
stack record, so every opcode appears flat under `runWithCallEnv` and the
op-to-op sequence is unrecoverable. `-g` also double-counts, so prefer a
flat profile for the dispatch loop. Use `-g` when the question is about
the call path *into* the VM, not about the VM loop itself.

```sh
taskset -c 19 perf record -F 4999 -o /tmp/case.data zig-out/bin/zjs /tmp/case.js
perf report -i /tmp/case.data --stdio --no-children -q
```

Raise `-F` for short cases: `-F 999` on a 47ms case yielded 16 samples total.

**Resolve inlining before trusting any symbol row.**

`ReleaseFast` inlines aggressively, so a hot symbol name is usually the
*outermost* frame of an inline stack and attributing cost to it is wrong. A
measured example: `perf report` credits 31.32% to
`parser.lexer.LexerImpl.nextInto`, but the sampled address resolves to

```text
parser.lexer.LexerImpl.bump      src/parser.zig:604
parser.lexer.LexerImpl.lexString src/parser.zig:1141
parser.lexer.LexerImpl.nextInto  src/parser.zig:499
```

Always expand the address before reading the assembly. `perf report --inline`
does *not* expand these in flat mode, so use `addr2line`:

```sh
perf script -i /tmp/case.data -F ip,sym | grep <symbol> | awk '{print $1}' | sort -u
addr2line -f -i -e zig-out/bin/zjs 0x<ip>
```

**Known limits on this host.** `perf_event_paranoid` is `1`, so
`/proc/kallsyms` is unreadable and kernel samples appear as bare
`[unknown] [k] 0x…` addresses — in the code-load profile above that was 43% of
all samples, i.e. the single largest row was unattributable. Account for it
before concluding that the visible user-space rows are the whole picture.

**Before drawing a conclusion from any two builds**, apply the existing
discipline: interleaved A/B on fixed binaries (build layout alone moves results
by up to ±2.8%). Independently produced binaries can alternate between two
distinct code states, which contaminates any cross-build comparison (the
2026-07 Zig build bistability investigation; report in git history).

macOS sampling:

```sh
xcrun xctrace record \
  --template "Time Profiler" \
  --output reports/perf/current/zjs.trace \
  --launch -- zig-out/bin/zjs /tmp/case.js
```

## Functional Gates

Run semantic checks before accepting performance-sensitive changes:

```sh
zig build test --summary all
zig build smoke --summary all
```

Run a relevant test262 subset when the optimization touches observable
JavaScript semantics.
