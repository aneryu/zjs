# Async optimization integration, 2026-09-09

The owner requested: “现在优化合入太慢了，你应该先合再修”. The validated
engine at `046413829ec15a6e0d06e04ca20c394491c022ce` was therefore fast-forwarded
into local main from `fc05a08a6f82ec8e8265d2b445f775269780b056`. Existing main
changes remain in the ancestry. No push was performed.

This decision accepts performance follow-up on main. It does **not** relabel
failed measurements as passes or waive correctness checks.

## Integrated changes

The payload combines nine original optimization commits, together with GC
ownership annotations and the ordinary continuation-tag correction. The IDs
below identify the history before squashing; they remain reachable through
`archive/async-before-squash-20260909`:

| Commit | Change |
|---|---|
| `ac7fca35` | Compact internal async handlers/reactions and direct async result settlement |
| `7a8fe83b` | Omit the unreachable rejection handler for already fulfilled awaits |
| `b12491ee` | Run non-suspending async functions in the calling Machine |
| `a041cbdc` | Keep intrinsic Promise capabilities in traced reaction records |
| `0b0496ec` | Trace adopted Shapes without requeueing their owners |
| `2d3d3c22` | Cache two own-property layouts at field access sites |
| `0079d773` | Queue fulfilled await continuations directly |
| `4ab35ac4` | Use exact targets for initialized dense-array write barriers |
| `0e778060` | Allocate intrinsic Promise objects and state together |
| `9f297892` | Document async job and Promise reaction GC slot ownership |
| `04641382` | Preserve the ordinary continuation tag when adding async completion |

The lazy array-storage, morgue-estimate and leaf-completion experiments remain
outside this payload. Original research branches and pre-existing worktree
changes are preserved.

## Whole-batch review and squash

The review covered async entry/completion and error unwinding, Promise species
and resolution ordering, job retry ownership, callback classification, both
property-cache arms, Shape/dense-array barriers, and Promise allocation/tracing.
No additional correctness defect was identified. Existing regression tests
include route counters, declared-only GC, allocation failure, custom/foreign
species and realm checks; these guard the optimized paths directly.

A fresh `zig build test -j32 --summary all` passed **19/19** build steps with
all **16/16** test shards executed. The existing **66/66** batch gate below
applies to identical engine and validation sources; this review changed only
this integration note. The known RegExp performance failure remains open.

At the owner's request, `fc05a08a..aa63bdd2` is squashed into one local commit,
including the two corrective/annotation commits and the integration note.
The preceding benchmark-tooling commit `fc05a08a` remains independent. The
backup branch retains `aa63bdd27459ed3a650f4c05c9dafdf45441f22d` for review or
bisect. Local review evidence is under
`.scratch/review-async-squash-20260909/`; no push is included.

## Correctness and artifact identity

The integrated engine tree is
`973e2152763e9dbc43242abb0a16525d610a3197`. Its batch gate passed **66/66** steps,
including the full unified tests, GC stress, architecture checks, test262 and
smoke/arena checks. test262 reports **44,584 passed, 0 failed, 0 known failures**.

Production configuration:

```
zjs-config-v3:compiler=v2,layout=short,repr=tagged,gc_layout=obj64_m,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

The validated stripped CLI SHA-256 is
`24ac0206c69b16309a2268a1877055bbd3048a66420245ee824621b70be6fa0a`.
The root worktree's default production CLI is rebuilt after integration and
checked against this artifact identity.

## Performance follow-up

The original performance contract remains the reference for measuring repairs.
The complete final matrix was stopped at a clear RegExp failure; integration
does not assert a complete performance gate pass.

| Control | Instructions vs previous main | Cycles vs previous main | Measurement result |
|---|---:|---:|---|
| Air | +0.149% | +0.760% | Passed the prescribed combined two-block check |
| Fixed RegExp | +0.291% | +2.122% | Failed the +1% cycles guard in a quiet window |

RegExp is the first performance issue to repair on main. Preserve all eight
original legs and distinguish additional executed work from instruction-layout
or cache effects before changing its hot path. Reproduce and measure repairs
against the integrated engine, retaining the pre-integration main as a control.

The smaller await-only candidate (`17298352`, with comment-only successor
`ad6c1878`) was not selected: it passed its correctness gate and reduced
doxbee-async elapsed time by 52.216%, but ordinary doxbee-promise failed with
instructions +4.076% and cycles +3.824%. Those measurements describe that smaller
candidate, not the integrated tree. Its callable-class experiment is also held
separately.

Local evidence root:
`/home/aneryu/worktrees/zjs-workloads-20260909/.scratch/workloads-20260909/merge-main`.
The integrated tree's evidence is `return-tag/gate-evidence.json`,
`return-tag/formal-stop.md`, `cold-5/identity.json`, `cold-6/identity.json` and
`verdict-cold-5-cold-6.json`, with raw legs in the corresponding `formal-*`
directories. Smaller-candidate evidence remains under `await-class/` and
`cold-8/`; it is not substituted for integrated-tree validation.
