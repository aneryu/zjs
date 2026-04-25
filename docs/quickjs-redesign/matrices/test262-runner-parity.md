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
| Known errors `-e` | `run-test262.c` | known-error loader | Load expected failures, classify new/changed/fixed/known | Known-error fixture | in_progress |
| Error update `-u` | `run-test262.c` | known-error writer | Update known-error file with current results when requested | Update fixture in temp dir | in_progress |
| Verbose `-v` | `run-test262.c` | CLI output | Print per-test progress and failures per QuickJS behavior | JSON slice prints failing file paths and stderr summaries | in_progress |
| Very verbose `-vv` | `run-test262.c` | CLI output | Print command/detail-level diagnostics | Snapshot or structured output test | in_progress |
| Timeout `-T` | `run-test262.c` | worker execution | Apply per-test timeout and classify timeout result | Timeout fixture | in_progress |
| Module mode `-m` | `run-test262.c` | harness/execution adapter | Run module tests and honor module metadata | Module fixture | in_progress |
| Thread count `-t` | `run-test262.c` | worker pool | Run with requested workers, deterministic summaries | `-t 2` direct-file smoke passes deterministically; full gate remains sub-minute at 38.88s | validated |
| Feature exclusions | `test262.conf` | config evaluator | Honor unsupported features and exclude lists before engine execution | Feature-list parse fixture and metadata skipped-feature fixture | validated |
| Positional test root | `run-test262.c` | CLI argument parser | Accept final test directory argument matching QuickJS runner shape | Full final gate command prepared 48205/53168 tests | validated |

## Runner Semantics

| Area | Required behavior | Required validation | Status |
|---|---|---|---|
| Harness loading | Load `sta.js`, `assert.js`, and property helpers in QuickJS-compatible order | Baseline `sta.js` + `assert.js` prepended; metadata `includes` are loaded after baseline harness | validated |
| Metadata parsing | Parse flags, features, includes, negative metadata, module/script markers | Metadata fixture table covers ordered includes, features, flags, and negative records | validated |
| Negative tests | Expected parse/runtime errors pass only when the expected phase/type matches | Negative helper rejects zero exits and wrong stderr error types; broader phase fidelity remains limited by current `zjs` diagnostics | in_progress |
| Exclude order | Apply config excludes before execution and before reporting unexpected failures | Exclude fixture | in_progress |
| Worker isolation | Avoid shared mutable harness state that changes semantics or creates lock contention | In-process per-test engine isolation plus worker-local harness caches; no shared harness lock | validated |
| Summary output | Match useful QuickJS summary fields and preserve exit-code semantics | Full gate reports `Result: 0/48205 errors, passed 42200` and preserves non-zero exits for unexpected failures | validated |
| Exit code | Known failures can exit 0; new/changed/fixed unexpected results fail | Known-error classification fixture | in_progress |
| Interrupted runs | Do not record interrupted sweeps as final validation | Tracking entry and error-record rule | not_started |

## Tooling Dependencies

| Dependency | Required behavior | Current evidence | Status |
|---|---|---|---|
| Host-visible output | `zjs` must expose normal `print` and `console.log` output through global function lookup and calls | Transitional host print opcode covers direct primitive `print(...)` and `console.log(...)` calls; direct integer `+ - * / %` expressions now emit bytecode for smoke validation | in_progress |

## Phase 8 Exit Additions

- Every option row above must be `validated` or explicitly `out_of_scope` with a
  reason tied to the local QuickJS baseline.
- Final test262 evidence must include exact command, exit status, summary, and
  whether failures are known, new, changed, or fixed.
- `TRACKING.md` must keep the latest full-suite command separate from targeted
  fixture validation.
- New, changed, fixed, and interrupted full-suite results must create or update
  an entry in `ERRORS_AND_LEARNINGS.md`.
