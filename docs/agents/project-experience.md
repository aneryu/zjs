# Project experience for agents

Read the sections relevant to the task. These are durable investigation
lessons, not a task checklist or status ledger. [AGENTS.md](../../AGENTS.md)
defines execution, [verification policy](../verification-policy.md) defines
gates, and current domain contracts govern implementation.

## 0. Where the domain context lives

Use [architecture.md](../architecture.md) for source owners and layer boundaries,
and [the documentation index](../README.md) for contracts. Reuse established
terms. Surface conflicts with an existing decision instead of silently
changing it; historical sessions and memory cannot override current contracts.

## 1. Evidence before narrative

Separate intended behavior from implementation facts. ECMA-262 governs
JavaScript semantics; TypeScript support is scoped in [LIMITATIONS.md](../../LIMITATIONS.md).
Current source, tests, build configuration, and reproducible results establish
what the checked-out engine actually does. A source implementation can still
violate its specification. QuickJS is a comparison reference.

| Claim | Useful evidence |
| --- | --- |
| Semantic correctness | Spec basis, focused reproducer, regression test; differential result where applicable |
| Performance cause | Fixed binaries, equal work, controlled comparison, isolated mechanism change |
| Lifetime rule | Ownership/root/edge walk and focused lifetime coverage |
| Validation success | Original exit status, complete expected output, actual case coverage |
| Completion | Intended diff, required checks, deliverables, and requested repository actions |
| Blocked work | Minimal probe, concrete blocker, and work not performed |

Recheck old claims when source, compiler, binary, workload, or host changes.
Repeated claims are not independent evidence. Keep raw evidence with the change.

## 2. Start every task from a frozen question

Apply the task boundaries in AGENTS. For an investigation, capture the exact
command and identify the zjs owner before editing. Form a falsifiable
hypothesis and name the observation that would disprove it. Consult the
reference implementation where it helps explain the behavior.

Keep the question narrow enough to test. A review inspects and reports;
a diagnosis reproduces and explains; a fix includes the responsible edit
and validation. Commit, merge, and push are separate authorization boundaries.

## 3. Language semantics and implementation

When engines disagree, compare lookup order, coercion, exceptions, user-code
calls, side effects, and lifetime/re-entry behavior under equivalent runner
conditions. A shared failure still needs a spec verdict; a reference match
alone does not prove correctness.

Use general mechanisms that preserve observable behavior. QuickJS's internal
layout or algorithm is not a requirement. Never land benchmark-name checks,
fixture recognition, or a shortcut that skips required user code.

Preserve project architecture: core contains no host policy; standard globals
use engine bootstrap/native records; values crossing host calls use handles;
`layout=short` is production and `plain` is diagnostic. Split a large module
for an ownership, dependency, or testability problem, not its size alone.

## 4. Diagnose by narrowing the owner

1. Reproduce on the current tree; retain stdout, stderr, and exit status.
2. Minimize while preserving the failure or the parent workload's behavior.
3. Check equal work: result, exceptions, side effects, checksum, iteration count.
4. Separate parsing, emission, VM execution, builtins, runner, and teardown.
5. Instrument the boundary that distinguishes the hypotheses.
6. Remove diagnostic instrumentation before assessing production cost.

A performance reduction that changes the parent's ratio is evidence about the
mechanism, not a replacement benchmark. Before calling a cost architectural,
account for event frequency, per-event cost, reachable code, and the timing
window. State what remains unexplained.

## 5. Performance evidence must fail closed

[Performance workflow](../perf/README.md) describes available diagnostics;
[bench-v8 status](../perf/bench-v8-status.md) is a historical snapshot.
There is no mandatory measurement protocol or performance merge gate.

For a performance claim, retain source revisions and dirty state, build
configuration, immutable binaries and hashes, host/compiler, workload and
output checksum, sample order/window, child exit status, and raw results.
Record affinity and PMU selection if used. Never measure a mutable
`zig-out/bin/zjs` that another build can replace.

Match the experiment to the claim:

- Use controlled paired comparisons to separate a change from drift/noise.
  Shared-cache or bandwidth interference can invalidate causal attribution.
- Fewer instructions or fewer code bytes do not establish a speedup. Check
  time/cycles and whether an extra call, dependency, or layout change explains
  the difference. A costly cold path may not matter to the workload.
- Inline stacks and shared bodies can misattribute symbol/line percentages.
  Use call-chain/address evidence and controls when investigating a mechanism.
- Whole-process and inner-loop measurements include different work. Record
  startup, parse, bootstrap, warmup, and teardown boundaries.

`unresolved`, `rejected`, `diagnostic-only`, and `no production change` are
valid outcomes. A local improvement needs evidence from the workload it is
claimed to improve; a microbenchmark does not establish general benefit.

## 6. Validation is part of the implementation

Use the [verification policy](../verification-policy.md) and
[GUIDE Part B.6](../../GUIDE.md#b6-validation-tiers), without copying their gates
into task notes.

- Debug can hide optimized-build lifetime/layout failures.
- Build the owning runner before using it; building the CLI does not refresh
  test262. Missing corpus, zero tests, and startup failure are not green gates.
- Preserve pipeline exit status. Check complete output and case coverage.
- Generated reports are not automatically part of the requested diff.
- Broad green gates need focused evidence for the behavior being changed.
- Reproduce a broad failure on the baseline before calling it pre-existing.
- Do not repair a gate through excludes, failure ledgers, or weakened tests.
  Legitimate runner/configuration changes still need their own regression.

## 7. Worktrees and multiple agents

Worktrees share Git objects, refs, reflogs, and the stash stack; build outputs,
corpora, and measurement resources may also be shared. Concurrent edits to the
same file need separate worktrees and a planned integration order. Concurrent
builds must not replace a measured binary. Keep scratch in each worktree.

When work is delegated, state the baseline/worktree, objective, allowed files,
Git permissions, reproducer, known disproved hypotheses, required checks, and
completion criteria. Keep dependent work from overlapping an unvalidated
predecessor. The integrating agent verifies the diff, merge-base, artifacts,
and results directly; an agent summary or existing commit is not completion.

Use named commits or patches for transfer, not shared `git stash`. Stage only
intended files. If commands fail before process creation, try one minimal
probe outside the repository, then report the infrastructure blocker and
unrun work instead of repeatedly changing shell syntax.

## 8. Recurring failed approaches

| Temptation | Better move |
| --- | --- |
| Add a benchmark-specific fast path | Implement the general mechanism and preserve language semantics |
| Trust a historical ratio or symbol percentage | Verify binary identity, current evidence, and inline/call context |
| Optimize a large per-event cost | Count its actual frequency first |
| Accept fewer instructions or bytes as a speedup | Check elapsed cost and the parent workload |
| Trust broad green gates or generated tables | Verify focused coverage, child exits, and missing results |
| Keep failed experimental code | Remove the task's failed experiment; preserve useful findings with the task |

## 9. Handoff format

Lead with the outcome, then explain the change/mechanism, relevant completed
checks, and residual work. Include reproducer and performance artifacts when
they support the claim. State interrupted or unrun checks explicitly. Report
commit/merge/push state when those actions are part of the task; do not attach
an unrelated repository inventory to every small edit.

## 10. Current references

[Documentation index](../README.md) routes to engineering, architecture,
contracts, and performance evidence. Local ticket conventions follow below.

## 11. Issue tracker: local Markdown

Issues and PRDs live in gitignored `.scratch/`, scoped to this worktree; they
are not a cross-machine collaboration surface.

- Feature directory: `.scratch/<feature-slug>/`.
- PRD: `PRD.md` within that directory.
- Issues: `issues/<NN>-<slug>.md`, numbered from `01`.
- Put a `Status:` line near the top; append discussion under `## Comments`.
- To publish a local ticket, create the file; to fetch it, read the referenced
  file. No external issue-tracker action is implied.

Use these canonical triage labels (implementation progress is separate,
see GUIDE Part B.3):

| Status | Meaning |
| --- | --- |
| `needs-triage` | Maintainer evaluation needed |
| `needs-info` | Reporter information needed |
| `ready-for-agent` | Fully specified for autonomous implementation |
| `ready-for-human` | Requires human implementation |
| `wontfix` | Will not be actioned |
