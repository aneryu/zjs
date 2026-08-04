# D0: opcode profiling functional repair (stabilization phase)

The regression: `vm_profile.zig` implemented compile-time-gated per-opcode
scopes but nothing in the execution root or dispatcher imported it — the
CLI accepted `--profile-opcodes`, mounted a profile, and printed all-zero
counts; every `--expect-opcode-max` gate passed vacuously (0 ≤ max). The
module fell out of the production graph silently because the dependency
checker only validates edges that exist.

## What landed

1. **Counting rewired at the only authoritative point that exists in a
   tail-call threaded dispatcher: the hot dispatch table itself.** A scope
   cannot span an `always_tail` chain, so the pre-threading enter/deinit
   scope API is retired. Profiling builds comptime-wrap all 256 hot-table
   entries (`profiledHandler`); every table dispatch counts the opcode and
   delta-attributes wall time to the previous one; the final open interval
   is closed by `flushPendingDispatch` before any dump. `cold_table` and the
   property tail tables stay unwrapped — they re-dispatch the same pc and
   wrapping them would double-count.
2. **Fail-closed CLI**: `--profile-opcodes` on a non-profiling binary exits
   2 with instructions, instead of emitting an all-zero report. `--perf-json`
   now writes `opcode_profile_enabled` explicitly and omits the opcode
   section when false.
3. **`zjs-profile` artifact**: a separate ReleaseFast binary with the scopes
   compiled in; `perf-runtime-profiles` builds and uses it — no caller has
   to remember `-D` flags.
4. **Gates that cannot pass on a dead profile**: the runner rejects
   `opcode_profile_enabled=false`, enforces `--expect-total-opcodes-min 1`
   everywhere, and supports `--expect-opcode-min`.
5. **Expectations recalibrated to exact pins.** The historical maxima were
   recorded under the pre-threading cold-entry-only counting (e.g.
   `get_field=0` meant "never reaches the cold path") and then went vacuous
   entirely. Under restored total-dispatch counting the real values are e.g.
   uri get_var=988,211, prop-mono get_field=1,000,000. Every listed opcode
   is now pinned exactly (max = min = measured); a future drop or rise must
   be acknowledged by recalibration, never by loosening into a vacuum.
   Slow-path-avoidance shape gates can return later on the separate
   `slow_count[]` channel if wanted.
6. **Production-reachability solver in `architecture-check`**: BFS from the
   production roots (root.zig, internal_root.zig, cli/zjs.zig,
   cli/run_test262.zig) and the test roots (all_tests.zig + the focused
   suite roots build.zig references); modules reachable from neither must
   carry an `orphan-allowlist.json` entry with a reason and exit milestone.
   Current census: 147 production-reachable, 15 test-only, 1 allowlisted
   orphan (`regexp_direct_bench.zig`, driven by a shell harness).

## Null verification

Default-build behavior unchanged: paired micro (compile mode, 4 ABBA pairs)
pre-D0 vs post-D0 default binaries — **instructions ratio 1.00000, MAD
0.00000**. The public API snapshot gained exactly one symbol
(`zjs.opcode_profile_build_enabled`). Functional checks: default binary +
`--profile-opcodes` → exit 2; default `--perf-json` →
`"opcode_profile_enabled": false`; `zjs-profile --profile-opcodes` on a
trivial script → nonzero counts (9 opcodes executed).
