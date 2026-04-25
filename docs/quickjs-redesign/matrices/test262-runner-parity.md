# Test262 Runner Parity Matrix

Purpose: make Phase 8 runner work source-aligned with `quickjs/run-test262.c`
and `quickjs/test262.conf`. This runner is future validation infrastructure, so
small semantic drift can hide engine bugs.

## CLI Option Parity

| Behavior | QuickJS owner | Zig owner | Required semantics | Required validation | Status |
|---|---|---|---|---|---|
| Config file `-c` | `run-test262.c`, `test262.conf` | `src/cli/run_test262.zig`, `src/tools/test262_runner.zig` | Load config relative paths, includes, excludes, features, harness roots | Config text fixture and JSON directory prep command | validated |
| Direct directory `-d` | `run-test262.c` | runner config/enumeration | Select tests from directory without double-prefixing config dir | Targeted directory command | validated |
| Direct file `-f` | `run-test262.c` | runner selection | Select one or more exact test files | `./zig-out/bin/run-test262 -f tests/zig-smoke/arith.js` | validated |
| Known errors `-e` | `run-test262.c` | known-error loader | Load expected failures, classify new/changed/fixed/known | Known-error fixture | validated |
| Error update `-u` | `run-test262.c` | known-error writer | Update known-error file with current results when requested | Update fixture in temp dir | validated |
| Verbose `-v` | `run-test262.c` | CLI output | Print per-test progress and failures per QuickJS behavior | JSON slice prints failing file paths and stderr summaries | validated |
| Very verbose `-vv` | `run-test262.c` | CLI output | Print command/detail-level diagnostics | Snapshot or structured output test | validated |
| Timeout `-T` | `run-test262.c` | worker execution | Report tests slower than threshold; do not change failure classification | Timeout fixture | validated |
| Module mode `-m` | `run-test262.c` | harness/execution adapter | Run module tests and honor module metadata | Module fixture | validated |
| Thread count `-t` | `run-test262.c` | worker pool | Run with requested workers, deterministic summaries | `-t 2` direct-file smoke passes deterministically; full gate remains sub-minute at 15.00s | validated |
| Feature exclusions | `test262.conf` | config evaluator | Honor unsupported features and exclude lists before engine execution | Feature-list parse fixture and metadata skipped-feature fixture | validated |
| Positional test root | `run-test262.c` | CLI argument parser | Accept final test directory argument matching QuickJS runner shape | Full final gate command prepared 48205/53168 tests | validated |

## Runner Semantics

| Area | Required behavior | Required validation | Status |
|---|---|---|---|
| Harness loading | Load `sta.js`, `assert.js`, and property helpers in QuickJS-compatible order | Baseline `sta.js` + `assert.js` prepended; metadata `includes` are loaded after baseline harness | validated |
| Metadata parsing | Parse flags, features, includes, negative metadata, module/script markers | Metadata fixture table covers ordered includes, features, flags, and negative records | validated |
| Negative tests | Expected parse/runtime errors pass only when the expected phase/type matches | Negative helper rejects wrong type markers and validates expected runtime/type combinations through unit fixtures | validated |
| Exclude order | Apply config excludes before execution and before reporting unexpected failures | Exclude fixture | validated |
| Worker isolation | Avoid shared mutable harness state that changes semantics or creates lock contention | In-process per-test engine isolation plus worker-local harness caches; no shared harness lock | validated |
| Summary output | Match useful QuickJS summary fields and preserve exit-code semantics | Full gate reports `Result: 0/48205 errors, passed 42200` and preserves non-zero exits for unexpected failures | validated |
| Exit code | Known failures can exit 0; new/changed/fixed unexpected results fail | Known-error classification fixture | validated |
| Interrupted runs | Do not record interrupted sweeps as final validation | Interrupted sweeps are intentionally excluded from final result tracking and recorded separately in tracking/learning artifacts | out_of_scope |

## Tooling Dependencies

| Dependency | Required behavior | Current evidence | Status |
|---|---|---|---|
| Host-visible output | `zjs` must expose normal `print` and `console.log` output through global function lookup and calls | Validated in Phase 9 runtime semantic hardening matrix; runner parity no longer owns this dependency | validated_in_phase_9 |

## Phase 8 Exit Additions

- Every option row above must be `validated` or explicitly `out_of_scope` with a
  reason tied to the local QuickJS baseline.
- Final test262 evidence must include exact command, exit status, summary, and
  whether failures are known, new, changed, or fixed.
- `TRACKING.md` must keep the latest full-suite command separate from targeted
  fixture validation.
- New, changed, fixed, and interrupted full-suite results must create or update
  an entry in `ERRORS_AND_LEARNINGS.md`.
