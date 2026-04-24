# Test262 Runner Parity Matrix

Purpose: make Phase 8 runner work source-aligned with `quickjs/run-test262.c`
and `quickjs/test262.conf`. This runner is future validation infrastructure, so
small semantic drift can hide engine bugs.

## CLI Option Parity

| Behavior | QuickJS owner | Zig owner | Required semantics | Required validation | Status |
|---|---|---|---|---|---|
| Config file `-c` | `run-test262.c`, `test262.conf` | `src/cli/run_test262.zig`, `src/tools/test262_runner.zig` | Load config relative paths, includes, excludes, features, harness roots | Config fixture test | not_started |
| Direct directory `-d` | `run-test262.c` | runner config/enumeration | Select tests from directory without double-prefixing config dir | Targeted directory command | not_started |
| Direct file `-f` | `run-test262.c` | runner selection | Select one or more exact test files | Targeted file command | not_started |
| Known errors `-e` | `run-test262.c` | known-error loader | Load expected failures, classify new/changed/fixed/known | Known-error fixture | not_started |
| Error update `-u` | `run-test262.c` | known-error writer | Update known-error file with current results when requested | Update fixture in temp dir | not_started |
| Verbose `-v` | `run-test262.c` | CLI output | Print per-test progress and failures per QuickJS behavior | Snapshot or structured output test | not_started |
| Very verbose `-vv` | `run-test262.c` | CLI output | Print command/detail-level diagnostics | Snapshot or structured output test | not_started |
| Timeout `-T` | `run-test262.c` | worker execution | Apply per-test timeout and classify timeout result | Timeout fixture | not_started |
| Module mode `-m` | `run-test262.c` | harness/execution adapter | Run module tests and honor module metadata | Module fixture | not_started |
| Thread count `-t` | `run-test262.c` | worker pool | Run with requested workers, deterministic summaries | `-t 1` and multi-worker smoke | not_started |
| Feature exclusions | `test262.conf` | config evaluator | Honor unsupported features and exclude lists before engine execution | Exclusion fixture | not_started |
| Positional test root | `run-test262.c` | CLI argument parser | Accept final test directory argument matching QuickJS runner shape | Final gate command | not_started |

## Runner Semantics

| Area | Required behavior | Required validation | Status |
|---|---|---|---|
| Harness loading | Load `sta.js`, `assert.js`, and property helpers in QuickJS-compatible order | Harness cache and execution fixture | not_started |
| Metadata parsing | Parse flags, features, includes, negative metadata, module/script markers | Metadata fixture table | not_started |
| Negative tests | Expected parse/runtime errors pass only when the expected phase/type matches | Negative fixture tests | not_started |
| Exclude order | Apply config excludes before execution and before reporting unexpected failures | Exclude fixture | not_started |
| Worker isolation | Avoid shared mutable harness state that changes semantics or creates lock contention | Parallel smoke with deterministic counts | not_started |
| Summary output | Match useful QuickJS summary fields and preserve exit-code semantics | Summary snapshot | not_started |
| Exit code | Known failures can exit 0; new/changed/fixed unexpected results fail | Known-error classification fixture | not_started |
| Interrupted runs | Do not record interrupted sweeps as final validation | Tracking entry and error-record rule | not_started |

## Phase 8 Exit Additions

- Every option row above must be `validated` or explicitly `out_of_scope` with a
  reason tied to the local QuickJS baseline.
- Final test262 evidence must include exact command, exit status, summary, and
  whether failures are known, new, changed, or fixed.
- `TRACKING.md` must keep the latest full-suite command separate from targeted
  fixture validation.
- New, changed, fixed, and interrupted full-suite results must create or update
  an entry in `ERRORS_AND_LEARNINGS.md`.
