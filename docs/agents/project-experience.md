# Project experience for agents

This field guide condenses recurring lessons from Claude Code, Codex, and Grok
project sessions. It records durable ways of working, not campaign status or
benchmark history. Current source, `AGENTS.md`, `GUIDE.md`, and the contracts
linked below always override a historical session or memory.

Use this guide to avoid repeating expensive mistakes. Keep new task-specific
evidence with the code change, issue, PR, or report that owns it; do not turn
this file into a running ledger.

## 1. Evidence before narrative

Use this order of authority:

1. Current zjs source and the exact checked-out QuickJS source.
2. Current tests, `test262.conf`, build configuration, and generated binary.
3. Reproducible behavior, disassembly, counters, and raw measurement artifacts.
4. Current reviewed project documentation.
5. Historical reports, session summaries, and agent memory.

History is useful for finding symbols, failed ideas, and missing checks. It is
not proof about current `HEAD`. Recheck a historical claim when the source,
binary, compiler, benchmark, hardware, or measurement protocol could have
changed.

Match the evidence to the claim:

| Claim | Minimum useful evidence |
| --- | --- |
| Semantic parity | QuickJS owner, zjs owner, same focused probe, and a regression test |
| Performance cause | Frozen binaries, equal-work output, paired A/B, and an isolated mechanism change |
| Architecture or lifetime rule | Ownership/edge walk, relevant QuickJS mechanism, and stress coverage |
| Validation success | Original command exit status, complete expected output, and artifact coverage |
| Task completion | Intended diff, required gates, deliverables present, and final git topology |
| Blocked work | A minimal environment-independent probe and an explicit list of work not performed |

Do not promote a hypothesis to a result because it sounds plausible or because
several agents repeated it. Repeated claims can share the same bad premise.

## 2. Start every task from a frozen question

Before editing:

1. Read the request literally, including write, commit, merge, and push
   boundaries.
2. Inspect `git status`, branch/worktree identity, and the intended diff. Treat
   pre-existing changes as user-owned.
3. Read the current subsystem entry points from
   [architecture.md](../architecture.md), not a stale session path.
4. Capture the exact failing command, script, benchmark, or test slice.
5. Identify both the QuickJS owner and the zjs owner of the behavior.
6. State one falsifiable mechanism hypothesis and the observation that would
   disprove it.

Keep the question narrow. “Why is this benchmark slow?” is not yet actionable;
“does mapped-arguments indexed access leave the QuickJS class arm and enter the
generic property path?” is.

Respect task verbs:

- **Review** means inspect and report; it does not authorize edits, commits, or
  pushes.
- **Diagnose** means reproduce and explain; do not silently turn it into an
  implementation campaign.
- **Fix/build** includes the smallest responsible edit and proportional
  validation.
- **Commit** means stage only the intended validated scope. It does not mean
  push.
- **Close out** means finish validation, integration, and honest residual
  reporting; do not open unrelated optimization lines.

## 3. QuickJS faithfulness is mechanism-level

QuickJS is not merely an output oracle. Compare the mechanism that produces the
output:

- lookup order and observable property operations;
- coercion and exception timing;
- refcount transfers and ownership of returned values;
- object/shape/prototype mutation rules;
- GC edges, weak edges, finalization, and re-entry;
- frame creation, argument materialization, and callback dispatch;
- parser, emitter, and opcode ordering.

A zjs path being faster in one case is not evidence that a QuickJS-absent path
should exist. Treat it as a warning until it is shown to be either:

- the Zig expression of the same QuickJS mechanism, or
- an explicitly reviewed, general mechanism with unchanged observable
  semantics and no shape-specific cliff.

Never land benchmark-name checks, source-pattern recognition, or a shortcut
that skips user code. A minimized benchmark is a diagnostic instrument, not a
new engine semantic.

When QuickJS and zjs disagree, first check whether pinned QuickJS also fails the
same test under the same runner and configuration. A shared failure is still
compatibility debt, but it is not demonstrated zjs-to-QuickJS regression.

Some stable architecture constraints follow from this project rather than from
any one campaign:

- `src/core/` does not absorb CLI, test262, plugin, or event-loop policy.
- Standard globals are engine bootstrap using QuickJS-style native records;
  they are not a generic descriptor-registry layer.
- VM values are governed by explicit refcount/cycle-GC ownership. Values that
  outlive a call cross the public handle boundary.
- `compiler_v2` is the only compiler and `layout=short` is production. Treat
  `plain` as a diagnostic configuration, not a second product.
- A large file that mirrors a QuickJS monolith is not by itself an architecture
  defect. Find an ownership, dependency, testability, or change-coupling
  problem before proposing a split.

## 4. Diagnose by narrowing the owner

Use a reproduce-minimize-hypothesize-instrument loop:

1. Reproduce on the current tree and retain exact stdout, stderr, and exit code.
2. Reduce to the smallest case that preserves the failure or performance ratio.
3. Check equal work: checksum, result, exception, side effects, and iteration
   count must agree across variants and engines.
4. Separate parser acceptance, emitted bytecode, VM execution, builtin glue,
   runner behavior, and teardown.
5. Instrument only the boundary needed to choose between hypotheses.
6. Remove or disable the instrumentation before judging production cost.

For performance cases, a good reduction retains the parent workload's ratio or
explains exactly where it changes. Deletion steps that change the ratio are
information; do not keep deleting until only a fast but unrelated microbenchmark
remains.

Before declaring a residual “architectural”, “diffuse”, or a “floor”, close the
accounting from several directions:

- equal-work instruction reconciliation;
- dynamic frequency multiplied by per-event cost;
- hot-footprint and reachable-code density, not only section size;
- frontend/backend stall conservation against total cycle excess;
- process-window versus benchmark-inner-window alignment.

Several long investigations were reopened because a residual label was applied
before this accounting closed.

## 5. Performance evidence must fail closed

The active workflow is documented in [Performance Workflow](../perf/README.md)
and the Zoo-specific runner contract in
[the Zoo README](../../tools/perf/zoo/README.md). Read those files before using
a remembered command.

For any decision-relevant result, retain:

- zjs and QuickJS source revisions;
- clean/dirty state and exact production configuration signature;
- immutable binary paths and SHA-256 hashes;
- compiler, target, host, CPU affinity, and serving PMU;
- workload source hash and deterministic output/checksum;
- warmup, sample count, order log, and measurement window;
- every child exit status and complete case/sample coverage;
- the raw machine-readable artifact.

Do not measure a mutable `zig-out/bin/zjs` while another build can replace it.
Zig 0.16 has produced materially different code from independent builds of the
same source in this repository (the 2026-07 build-bistability record, in git
history). Freeze the exact binary first. A historical number tied to another binary is a
snapshot, not a current baseline.

Use balanced paired order with an even sample count. Keep fast parallel macro
screening separate from strict attribution: shared-cache and bandwidth effects
can be acceptable for a calibrated headline protocol while still invalidating
a cycle/cache explanation. Recheck a boundary decision with the protocol that
matches the claim.

Measure instructions and cycles/time together:

- fewer instructions with unchanged time can mean out-of-order execution hid
  the removed work;
- fewer instructions with worse cycles can mean an added dependency, branch,
  call boundary, or code-layout cost;
- equal instructions with different cycles can be a layout or microarchitecture
  effect;
- a high per-event cost is irrelevant when the path is dynamically cold.

When instructions and cycles disagree, collect the smallest useful stall,
branch, cache, or call-chain evidence. Do not infer the answer from one `perf`
percentage. Inlining and shared cold bodies make `file:line` and symbol buckets
leak across mechanisms; use scoped call chains, IP-to-inline-stack mapping, and
both positive and zero controls.

Keep measurement windows comparable. Whole-process counters include startup,
parse/compile, bootstrap, and teardown; many benchmark scores time only an
inner loop. A ratio difference between those windows is not automatically a GC
or warmup effect.

Treat these outcomes as valid results:

- **unresolved**: effect is below noise or changes direction;
- **rejected**: focused case improves but macro workloads regress;
- **diagnostic-only**: a never-merge spike establishes an upper bound;
- **no production change**: code size or cache-set geometry improved without a
  causal cycle/score improvement.

Reducing handler bytes is not sufficient. Moving a hot leaf behind another
call, prologue, or tail hop can shrink the resident island and still slow the
program. Validate reachable hot work, frame size, dispatch discipline, and
macro sentinels.

## 6. Validation is part of the implementation

Follow [GUIDE.md](../../GUIDE.md) Part B.6: focused reproducer first, then the
cheapest covering tier, then the appropriate handoff or phase-close gates. Do
not duplicate the command ladder into task notes.

Recurring traps:

- Debug success can hide ReleaseSafe/ReleaseFast lifetime, layout, or undefined
  behavior failures.
- `zig build zjs` does not prove a separately built runner is fresh. Prefer the
  owning build step over invoking an old artifact from `zig-out/bin`.
- A new worktree may have an uninitialized `test262` submodule. Zero tests,
  missing corpus, or a runner startup failure is not a green gate.
- Piping a build through `grep` can hide the original non-zero exit. Preserve
  the command status with `pipefail` or capture and check it separately.
- Validation can update generated reports. Do not stage them unless they are
  part of the requested deliverable.
- Counters and probes can perturb the path they measure. Use them for frequency
  or classification, then price the uninstrumented build.

Green broad gates do not prove the target behavior if there is no focused
regression, if the relevant feature is excluded by `test262.conf`, or if a
source-shaped shortcut bypasses the real path. Conversely, a failing broad gate
is not automatically caused by the current diff: reproduce it on the baseline
before attributing it as pre-existing.

Use the extra GUIDE gates when their invariant is touched: alternate value
representation, OOM cleanup, forced-GC timing, or ownership audit. New user-
visible throw paths must retain a message through the message-carrying helpers.

Never repair a gate by editing excludes, expected-failure ledgers, reports, or
tests unless the task is specifically a reviewed runner/configuration change.

## 7. Worktrees and multiple agents

Isolation is necessary but incomplete:

- Worktrees isolate checked-out files, but share the Git object database,
  refs, reflogs, and stash stack.
- Build caches, `zig-out`, `/tmp` locks, PMU CPUs, and benchmark corpora can also
  be shared.
- Concurrent edits to the same file need separate worktrees and an explicit
  integration order.
- Concurrent builds must not overwrite a binary that another lane is measuring.

A useful delegated brief names:

- baseline commit and worktree;
- exact objective and non-objectives;
- allowed files and git-write policy;
- QuickJS anchors and current reproducer;
- required output/checksum and measurement protocol;
- focused and final gates;
- stop/reject conditions;
- concrete completion marker, such as a named report plus commit.

Make briefs self-contained. Include known disproved hypotheses so another agent
does not spend hours rediscovering them. For a strict dependency chain, allow at
most one speculative successor and only when its files do not overlap the
unvalidated predecessor.

The integrating agent retains final judgment. Verify the candidate diff,
merge-base, binary identity, raw artifacts, gate output, and report claims
directly. A pane marked done, an agent summary, or a commit existing somewhere
is not completion.

Do not use shared `git stash` as a casual transfer mechanism. Prefer a named
commit or patch and verify the exact files before applying it. Stage only the
intended scope. Merge locally only when requested; push requires separate
authorization.

If every command fails before process creation, use one minimal probe outside
the repository. A command-independent sandbox startup error is infrastructure
evidence, not source, test, or performance evidence. Stop retrying shell
variants and report precisely what was not run.

## 8. Recurring failed approaches

| Temptation | What repeatedly went wrong | Better move |
| --- | --- | --- |
| Add a benchmark-specific fast path | Local score improved while the engine diverged from QuickJS | Map and implement the QuickJS mechanism |
| Trust a historical ratio | Source, binary, protocol, or build state had changed | Remeasure current frozen binaries |
| Trust a symbol or line percentage | Inlining/shared bodies attributed unrelated work | Use scoped call chains and differential builds |
| Optimize the highest per-event cost | The path was dynamically cold | Count exits first; price frequency times cost |
| Accept instruction reduction as speed | Cycles were neutral or worse | Measure cycles/time and dependency/stall effects |
| Shrink or relocate handler code | Extra hop/prologue or reachable footprint erased the win | Measure the uninstrumented macro sentinels |
| Generalize one green microbenchmark | The parent workload did not exercise the same mechanism | Preserve the parent ratio and return to macro A/B |
| Treat broad green gates as proof | Focused semantics were absent or excluded | Add a direct regression and check the config boundary |
| Trust a runner-generated table | Child failure or missing output was silently skipped | Validate exits, stdout, hashes, and coverage independently |
| Let a lane “fix” the ledger | A regression was hidden rather than fixed | Protect configs/reports and rerun the canonical gate |
| Call a residual a permanent floor | Another accounting axis later exposed a fixable mechanism | Close conservation and state the remaining uncertainty |
| Keep failed experimental code | Future agents mistook it for a candidate | Revert product code; retain a clearly labeled report if useful |

## 9. Handoff format

Lead with the actual outcome: `validated`, `partial`, `rejected`, `unresolved`,
or `blocked`. Then record:

1. **Scope:** baseline, changed files, and explicit non-scope.
2. **Mechanism:** QuickJS owner, zjs owner, and why the change is faithful.
3. **Behavior:** reproducer, expected output, and focused regression.
4. **Performance:** immutable binaries, protocol, raw artifact, and whether the
   result is screening or attribution evidence.
5. **Validation:** exact completed gates plus interrupted/not-run gates.
6. **Residual:** what remains, what was disproved, and the next evidence needed.
7. **Repository state:** branch/head, dirty files, local merge state, and whether
   anything was pushed.

Use explicit negative statements: “direct parity was not reached”, “the full
gate was not run”, or “the effect was below the measurement resolution”. Honest
partial evidence is more useful than a polished but unsupported success claim.

## 10. Current references

- Engineering and validation: [GUIDE.md](../../GUIDE.md)
- Source ownership and layering: [architecture.md](../architecture.md)
- Contribution scope: [CONTRIBUTING.md](../../CONTRIBUTING.md)
- Performance contracts: [Performance Workflow](../perf/README.md)
- Current public Zoo snapshot: [Zoo status](../perf/zoo-status.md)
- Historical subsystem baseline and evidence vocabulary:
  [QuickJS subsystem baseline](../qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md)
- Local issue/PRD workflow: [issue tracker](issue-tracker.md)
- Domain vocabulary and ADR routing: [domain docs](domain.md)
