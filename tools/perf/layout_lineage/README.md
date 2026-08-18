# Layout-lineage A/B

Separates a candidate's **mechanism effect** from this host's **code-placement lottery**.

## The problem it solves

`instructions` down while `cycles` up is not an anomaly. Since

    cycles = instructions / IPC

a candidate that retires fewer instructions still loses whenever it costs more IPC than
it saves work. The trap is that IPC can fall for two completely different reasons:

| | cause | what it means for the candidate |
|---|---|---|
| **semantic** | new dependency chain, new cache miss, new mispredict caused by the new control flow | the mechanism really is worse |
| **layout** | the new code merely sits at different addresses; I-cache / BTB / uop-cache aliasing shifts | the mechanism is untested |

This host has a documented **±2.5% code-placement lottery**, and has produced at least
one reading of *instructions bit-identical, cycles +2.76%* — pure placement, zero
mechanism.

## Why "two cold builds" does not settle it

The standing measurement contract (clause 4) requires two cold builds per side. That
clause samples **compiler non-determinism** — and Zig is deterministic for a fixed
source, so on this project the two builds are frequently byte-identical. Building each
side twice therefore does **not** vary layout; it only proves the noise floor.

To vary layout you must hold the source fixed and move the code. That is what
`-Dzjs_dossier_layout_pad=N` does (`src/dossier_pad.zig`): it emits N non-foldable
exported bodies. On aarch64 ELF they land in `.text.zjs.layout_pad`, KEEP'd at
the start of the handler island after its page-aligned origin, so pad N shifts
handler VAs by a non-page multiple and the island tail pushes `.text`. A
section before the island is absorbed by `ALIGN(MAXPAGESIZE)` and pad=3/7
collapse. Other targets keep default `.text` placement. At `N=0` the
binary is bit-for-bit what it would be without the file.

Rigid translation of one binary is the cheap axis (P4-01c ≤0.24%). The lineages
exist to sample the A/B × placement interaction: the same source delta can flip
sign across pads (D10). They do not eliminate the candidate's own size delta.

## Usage

```bash
python3 tools/perf/layout_lineage/run_lineage.py \
    --base-worktree /tmp/wt-baseline \
    --cand-worktree /home/aneryu/zjs \
    --pads 0 3 7 \
    --benches regexp \
    --samples 4 --cpu 6 \
    --output /tmp/<name>-lineage.json
```

Dated json dumps are gitignored; markdown notes stay trackable. Older dumps
through 2026-08-15 remain in git history.

Each pad value gets its own build cache and prefix, so lineages never share objects.
Both sides are built at every pad, and each lineage is measured as its own paired A/B
(candidate vs base at the *same* pad) — layout is a blocking factor, not a covariate.

## Verdict rule

Applied independently to instructions and to cycles:

| verdict | condition |
|---|---|
| **SEMANTIC** | every lineage agrees in sign **and** \|median effect\| > lineage spread |
| **LAYOUT** | sign flips across lineages |
| **UNRESOLVED** | signs agree but \|median\| ≤ spread |

Read the two metrics together:

- stable instruction delta + stable cycle delta, same sign → real mechanism effect
- near-zero instruction delta + moving cycle delta → placement artifact
- stable instruction delta + cycle delta that flips across lineages → the mechanism
  does change the work, but the cycle reading is not attributable yet; go collect
  `stall_frontend` / `stall_backend` / `branch-misses` before concluding

## When to run it

Whenever `instructions` and `cycles` disagree in direction. Measurement contract clause
8 already forbids concluding from that state without stall data; this runner is the
step after the stall breakdown, and it is what turns "the frontend got worse" into
"the frontend got worse **because of this mechanism**" rather than "…because the code
moved".

Three pads is the practical minimum — two lineages cannot distinguish a sign flip from
a noisy pair.

## What it does not do

- It does not run the canonical gate and issues no merge verdict.
- It does not eliminate every layout confound: A/B still differ in code size, so the
  candidate's own functions sit at different addresses in every lineage. What the pads
  buy is that *the rest of the binary* has been displaced several different ways, so an
  effect that survives all of them is unlikely to be an aliasing accident.
- Padding is never enabled in a shipped configuration; `src/dossier_pad.zig` exists to
  average the lottery out, not to shape one favourable hot layout.
