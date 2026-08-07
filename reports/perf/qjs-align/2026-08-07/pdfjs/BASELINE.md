# pdfjs gap baseline — zjs b15ae407 vs qjs 04be2460, 2026-08-07

Zoo score: zjs 4623 vs qjs 9956 = **0.464** (worst of the 15 zoo benchmarks).

## Why the zoo wall-clock is misleading

Zoo wall medians are nearly equal (zjs 1.199s, qjs 1.130s) because Octane is
**time-boxed**: `RunSingleBenchmark` loops until `elapsed >= 1000ms`. The engines
run for the same second and complete different iteration counts, so the score
ratio (2.153x) — not the wall ratio — is the real per-iteration gap.

## Deterministic workload

`runN.js` = the full pdfjs benchmark body with the time-boxed harness replaced by

```js
setupPdfJS(); for (i < N) runPdfJS(); tearDownPdfJS();
```

`tearDownPdfJS()` verifies an output hash (36788 / 939524096) and **both engines
pass it**, so both provably do identical work. All figures below are
`(N=8 total − N=0 total) / 8`, pinned `taskset -c 19` under the exclusive host lock.

## Per-run counters

| metric | zjs | qjs | ratio |
|---|---|---|---|
| cycles | 795.5M | 407.2M | 1.954 |
| instructions | 3869.2M | 2248.5M | 1.721 |
| branches | 754.8M | 379.0M | 1.992 |
| branch-misses | 2.0M | 0.7M | 2.954 |
| cache-refs | 1676.2M | 858.4M | 1.953 |
| cache-misses | 1.9M | 1.2M | 1.628 |
| IPC | 4.864 | 5.522 | 0.881 |

**cycles gap 1.954x = instruction count 1.721x × IPC penalty 1.135x.**

Parse+setup (N=0) is *not* the problem: zjs uses **0.917x** the instructions of
qjs there. Octane only times `runPdfJS()`, so the entire gap is execution.

## The opcode stream is the same — cost per opcode is not

Indirect branches (= dispatch count, one per opcode under both computed-goto and
tail-call threading):

| | zjs | qjs | ratio |
|---|---|---|---|
| indirect branches / run | 51.4M | 53.2M | **0.966** |
| instructions / opcode | **79.6** | **42.3** | **1.88x** |

zjs executes *fewer* opcodes (0.91x). Independently confirmed exactly by the
attribution workflow: gdb counted qjs's eq-family opcodes at 1,342,664/run
against zjs's opcode profile 1,342,664.5/run.

## Structural signature: fast paths that qjs inlines, zjs outlines

`br_return_retired` per opcode: **zjs 0.98, qjs 0.46**. Tail-call threading emits
no return of its own, so these are helper calls.

Absolute Mcycles (N=8), strict classification:

| category | zjs | qjs | ratio | excess | % of gap |
|---|---|---|---|---|---|
| dispatch-inline (op handlers) | 2357.2M | 1727.6M | 1.36 | 629.6M | 20.1% |
| **out-of-line helpers** | **3659.8M** | **948.4M** | **3.86** | **2711.4M** | **86.4%** |
| memory/GC/bulk | 614.6M | 819.3M | **0.75** | −204.6M | **−6.5%** |

zjs's memory path is *faster*. qjs's largest helper (`JS_GetPropertyInternal`) is
a genuine slow path; zjs's largest are `getDenseArrayElementValue`,
`existsOwnProperty`, `setOwnWritableDataProperty` — all nominal *fast* paths.

Disassembly corroborates: `existsOwnProperty` opens `sub sp,sp,#0xd0` (208-byte
frame) + 5 prologue stores; `compareStringValues` opens `sub sp,sp,#0x550`
(1360-byte frame) *before its length test*.

## The IPC penalty closes exactly against memory-access density

| | zjs | qjs | ratio |
|---|---|---|---|
| cache-refs per instruction | 0.4332 | 0.3818 | **1.1348** |
| IPC penalty (qjs/zjs) | | | **1.1353** |

**0.05% apart** — the IPC loss is spill/restore traffic from the outlined calls,
not cache capacity. Branch mispredicts explain only 5.0% of the gap (19.5M of
388.3M cycles at 15 cyc/miss).

## Independent confirmation of the headline mechanism

`Array.prototype.splice` has no fast-array arm (`array_ops.zig:2796-2813` does
per-element `propertyAtomFromLengthIndex` ×2 → `hasValueProperty` →
`getValueProperty` → `setValuePropertyOrThrow`); qjs gates on `fast_array` at
`quickjs.c:43042-43046` and issues one `memmove` at `quickjs.c:43064/43072`.

Head-insert vs tail-insert differential (`splice-micro2.js`, same call count and
same del=0/ins=1 shape, so allocation and representation paths match; only the
shifted-element count differs — 3.999M elements):

| | pure-shift instructions | per shifted element |
|---|---|---|
| zjs | 4702.5M | **1175.91** |
| qjs | 9.1M | **2.27** |

**518x per shifted element.** The qjs figure matches the workflow's independently
derived 2.15 to within 5%, confirming the memmove arm is live. (zjs measures
higher here than the workflow's in-situ 631 because head-insertion also triggers
the de-densification described in ATTRIBUTION.md §2.)

## Files

- `ATTRIBUTION.md` — full mechanism-level attribution and refutations (29-agent
  workflow, adversarially verified)
- `profile-absolute.json` — both engines' flat profiles in absolute Mcycles
- `opcode-N2.txt` — zjs opcode counts (COUNT is trustworthy; AVG_NS has a ~25ns
  probe floor that swamps cheap opcodes)
- `splice-micro2.js` — the length-differential microbenchmark
