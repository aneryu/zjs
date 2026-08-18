# QCP-1 dual-comparator divergence: closure record

Branch `compiler-v2-qjs`, tip `a9c13b0a`. Measurement and documentation only —
this record changes no code.

Gate A passed and the legacy production path was authorised for deletion.
Deletion was then **blocked** by a divergence that the first-ever *full* dual
test262 run surfaced. This document records that the divergence is closed, that
closing it moved nothing on the path we are actually shipping, and what the fix
did and did not cost on the zoo.

The defect and its root cause are not restated here; they are in the fix
commit's own message (`a9c13b0a`, "fold the empty taken branch in a switch
default clause"). This is the **evidence** record.

---

## 0. Headline

| gate | required | measured at `a9c13b0a` | state |
| --- | --- | --- | --- |
| **(1) FULL DUAL test262** | `0 errors, 44541 passed, 25 known` | `0/49775 errors, passed 44541, known 25`, zero `ZJS-DUAL-MISMATCH` lines | **MET** |
| **(2) FULL DEFAULT test262** | same counts, shipping build | `0/49775 errors, passed 44541, known 25` | **MET** |
| **(3a) switch gate — code-load v2/legacy** | ≥ 1.2359× | **1.2533×** mean of four 12-sample ABBA pairings (1.2498 – 1.2567) | **MET** |
| **(3b) full-zoo geomean not below legacy** | ≥ 0.7030 | **0.7126** (+1.37% over legacy), both rounds | **MET** |
| **(3c) fix costs nothing beyond noise** | within the noise floor | **−0.09% geomean**, paired, versus a **0.79% runtime** and **1.74% build-layout** per-benchmark floor | **MET, with one named caveat — §4** |

The caveat is `zlib`: **−0.99%**, repeatable. It is the only benchmark outside
the same-run control band. §4 shows it is a layout draw and not extra work —
the fixed binary retires the **same instruction count to within 4 parts per
million** and spends **1.00% more cycles** — but with a deterministic build
there is only one draw at this tip, so it is reported as a cost that could not
be averaged away rather than as a cost that was proven absent.

---

## 1. Provenance

| item | value |
| --- | --- |
| tip under test | `a9c13b0aabd88ea0de5fa5a60fa2c26ace3bb80a`, worktree clean |
| candidate binaries | `rg-zjs-c1`, `rg-zjs-c2` — two independent cold builds (`rm -rf .zig-cache zig-out`), **true production defaults, no `-D` flags at all** |
| candidate config signature | `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off` |
| candidate sha256 | `02fd657dc1f89f5456ce5f6aa31c64039a3b688fc5f16cd521e2b10004b099bd` — **c1 and c2 are byte-identical**; the candidate build is deterministic |
| frozen Gate A candidate | `zjs-cand-b1` / `zjs-cand-b2`, sha `84bfdfa22154…`, also byte-identical to each other |
| frozen Gate A legacy | `zjs-legacy-a1` sha `cc0612a35452…`, `zjs-legacy-a2` sha `86fde89e550b…` — genuinely different builds of identical source |
| pinned reference | `/home/aneryu/quickjs/qjs` |
| `.text` | candidate `4,057,692` B vs frozen candidate `4,057,944` B — **252 B smaller**, the removed trampoline |

**Legacy was deliberately not rebuilt.** The fix's entire parser change sits
inside `if (v2_available and s.emit_v2)`; the `resolve_labels.zig` change is
doc comment only. The legacy backend cannot observe it, so the frozen Gate A
legacy baselines remain ground truth and re-deriving them would only have
resampled the build lottery.

Raw artifacts, every run in this record (git history):
`reports/perf/qjs-align/2026-08-04/dual-closure/` — `zoo/` (6 full-15 runs),
`code-load/` (10 dedicated 12-sample runs), `test262.log`,
`zlib-attribution.log`. Each JSON carries both binaries' sha256, the effective
affinity, the kernel, and the actual execution order.

Measurement discipline, unchanged from Gate A: exclusive host lock
(`flock -x /tmp/zjs-host-heavy.lock`) held across every run; `taskset -c 19`
supplied **by the caller**, because `run_zoo_compare.py` attests effective
affinity and refuses with rc=2 rather than emitting unpinned numbers; even
sample counts only. All runs returned rc=0.

---

## 2. Correctness — gates (1) and (2)

```
dual     zig build test262-gate -Dzjs_compiler=dual
         Result: 0/49775 errors, passed 44541, known 25
default  zig build test262-gate           (no flags — the shipping path)
         Result: 0/49775 errors, passed 44541, known 25
```

Both are exactly the counts each backend produces alone. The dual log contains
**zero** `ZJS-DUAL-MISMATCH` lines.

The differential against the run that blocked deletion is the whole point:

| run | tip | result |
| --- | --- | --- |
| first full dual run | `04922a47` | `5/49775 errors, passed 44536, known 25`, five `CFG_MISMATCH tier=1.5 field=block_count` |
| this run | `a9c13b0a` | `0/49775 errors, passed 44541, known 25`, no mismatch of any tier |

`44536 + 5 = 44541`. Every case the divergence cost is back, and nothing else
moved: the default-path run is byte-for-byte the same summary line as Gate A's.
**The fix did not move a single test on the path we are shipping.**

---

## 3. Performance — gate (3)

### 3.1 The switch gate: dedicated code-load, 12 ABBA samples

Ratio is `first / second`, higher-is-better scores.

| round | comparison | this tip | Gate A |
| --- | --- | ---: | ---: |
| 1 | c1 / legacy-a1 | 1.2567 | 1.2558 |
| 2 | c1 / legacy-a2 | 1.2498 | 1.2550 |
| 3 | c2 / legacy-a1 | 1.2556 | 1.2541 |
| 4 | c2 / legacy-a2 | 1.2510 | 1.2539 |
| | **mean** | **1.2533** | 1.2547 |
| noise floor | c1 / c2 (byte-identical) | 1.0002 | — |
| noise floor | legacy-a1 / legacy-a2 (build lottery) | 0.9964 | — |

**Required ≥ 1.2359×. Measured 1.2533× — MET**, and every individual pairing
clears the bar. The 0.11% shortfall against Gate A's 1.2547 is a third of the
spread the legacy build lottery alone produces (0.9964, i.e. 0.36%).

Against pinned qjs, code-load is **0.5594 / 0.5592** (12-sample) and **0.5623 /
0.5592** (4-sample suite), versus Gate A's 0.5604.

### 3.2 Absolute position, full 15 benchmarks, 4 ABBA samples

| binary | geomean vs qjs | code-load vs qjs |
| --- | ---: | ---: |
| candidate c1, this tip | **0.7126** | 0.5623 |
| candidate c2, this tip | **0.7126** | 0.5592 |
| frozen Gate A candidate b1 | 0.7149 | 0.5604 |
| frozen Gate A candidate b2 | 0.7142 | 0.5604 |
| frozen Gate A legacy a1 | 0.7043 | 0.4467 |
| frozen Gate A legacy a2 | 0.7017 | 0.4487 |

Geomean **0.7126 versus legacy's 0.7030 — not below legacy, +1.37%. MET.**

Against the frozen candidate the unpaired figure is **0.7126 vs 0.71455, i.e.
−0.27%** — and that number is *not* the cost of the fix. It is measured across
two sessions, and the ruler moved between them. §3.3 separates the two.

### 3.3 The cost of the fix, measured paired in one session

Comparing the fixed binary against the frozen Gate A candidate **directly**,
in the same run, on the same core, alternating first position:

| pairing | geomean | code-load |
| --- | ---: | ---: |
| c1 / b1 | **0.9990** | 0.9980 |
| c2 / b2 | **0.9993** | 1.0014 |

**The fix costs −0.09% of geomean.** The remainder of the unpaired −0.27% is
session drift of the ruler: from `c1/qjs = 0.7126` and `c1/b1 = 0.9990` the
frozen b1 binary would itself measure `0.7133` in this session against the
`0.7149` it measured in the Gate A session, so about **−0.19% is the machine,
−0.09% is the fix**. Directly visible on `richards`: the *frozen* b1 binary
scored 1304/1305 in the Gate A session and 1285 in this one, while the fixed
binary scored 1284 alongside it — a 1.5% session shift that the unpaired view
would have charged to the fix, and the paired view charges to nobody.

Two noise floors were re-measured in this same session rather than carried
forward:

| control | what it isolates | geomean | worst single-benchmark deviation |
| --- | --- | ---: | ---: |
| b1 / b2, byte-identical binaries | pure runtime variance | 0.9997 | 0.79% |
| legacy-a1 / legacy-a2, same source, two builds | **build-layout lottery** | 1.0015 | 1.74% |

Gate A's 0.378% build-layout floor is the *unpaired* geomean gap between those
same two legacy builds (0.7043 / 0.7017). Measured **paired**, in one session,
the same lottery is 0.15% at the geomean — tighter, because pairing removes the
session drift that §3.3 quantified. Either way the fix's −0.09% is inside it.
Per benchmark the lottery is far wider (1.74%), and that is the number that
matters when judging a single benchmark's move.

---

## 4. The one unfavourable result: `zlib` −0.99%

`zlib` is the only benchmark outside the control band, and it is repeatable:
**0.990 (c1/b1) and 0.989 (c2/b2)**. It is reported rather than absorbed.

**It is not runtime noise.** The byte-identical control puts `zlib` at 0.999.

**It is not extra work.** Counting instructions and cycles over `zlib.js`, ABBA,
4 samples each, same lock and pin:

| binary | score | instructions | cycles | IPC |
| --- | ---: | ---: | ---: | ---: |
| b1 (frozen) | 3,279 | 966,042,328,587 | 181,826,615,578 | 5.313 |
| c1 (fix) | 3,246 | 966,046,025,950 | 183,648,017,092 | 5.260 |
| **c1 / b1** | **0.9901** | **1.000004** | **1.0100** | — |

The fixed binary retires the **same instruction count to within 4 parts per
million** and spends **1.00% more cycles**. The engine does not do more work;
the same work runs at 1% lower IPC. That is the campaign's well-documented
build-layout signature, and `zlib` is the benchmark that carries it most: the
same-source / different-build control moves `zlib` by **+1.74%**, the largest
layout sensitivity in the whole set and larger than the effect being judged.

**A stronger control than statistics.** The fix changes emission *only* where a
`switch` has a `default` clause; a `switch` without one takes the unchanged
`else` arm, so those programs compile to identical bytecode. Splitting the 15
benchmarks on that predicate gives a control group whose bytecode provably
cannot have changed:

| group | n | c1/b1 range | c2/b2 range | worst deviation |
| --- | ---: | --- | --- | ---: |
| **control** — no `default:` clause anywhere (code-load, crypto, deltablue, navier-stokes, raytrace, regexp, richards, splay) | 8 | [0.994, 1.005] | [0.995, 1.009] | **0.88%** |
| **affected** — has `default:` (box2d, earley-boyer, gbemu, mandreel, pdfjs, typescript, zlib) | 7 | [0.990, 1.004] | [0.989, 1.004] | 1.13% |

Benchmarks that **cannot** have changed still move by up to 0.88% in these very
pairings — `deltablue` +0.9%, `regexp` −0.6%. The two groups are not
distinguishable except for `zlib` itself, and the six other affected
benchmarks, including the three with far more `default:` clauses than `zlib`
(`pdfjs` 38, `typescript` 44, `mandreel` 11), sit at 0.996–1.004.

**Honest verdict.** Everything measurable says `zlib`'s −0.99% is a layout draw:
same instructions, lower IPC, on the most layout-sensitive benchmark in the set,
with a same-source control that swings it further than this. But the candidate
build is deterministic — c1 and c2 came out byte-identical — so there is **no
build lottery to average over at this tip**, and a single draw cannot be
separated from a real 1% effect by measurement alone. It is recorded as a cost
that could not be averaged away, not as a cost proven absent.

---

## 5. Full per-benchmark table

Paired, this session. Ratio `first / second`; 1.000 = no change.

| benchmark | c1/b1 | c2/b2 | build-layout floor (a1/a2) | runtime floor (b1/b2) |
| --- | ---: | ---: | ---: | ---: |
| box2d | 0.996 | 0.995 | 0.997 | 1.003 |
| code-load | 0.998 | 1.001 | 0.996 | 1.002 |
| crypto | 1.001 | 1.001 | 0.996 | 1.004 |
| deltablue | 1.004 | 1.009 | 0.996 | 0.992 |
| earley-boyer | 1.004 | 1.004 | 1.007 | 0.998 |
| gbemu | 0.996 | 0.997 | 1.002 | 0.998 |
| mandreel | 0.999 | 1.004 | 1.006 | 1.002 |
| navier-stokes | 1.005 | 1.001 | 0.996 | 0.999 |
| pdfjs | 0.999 | 0.999 | 1.000 | 0.999 |
| raytrace | 0.999 | 0.995 | 1.008 | 0.998 |
| regexp | 0.994 | 1.000 | 0.995 | 1.000 |
| richards | 0.999 | 0.999 | 1.000 | 0.998 |
| splay | 1.002 | 1.000 | 1.008 | 1.001 |
| typescript | 0.999 | 0.996 | 0.999 | 1.000 |
| **zlib** | **0.990** | **0.989** | **1.017** | 0.999 |
| **geomean** | **0.9990** | **0.9993** | 1.0015 | 0.9997 |

No benchmark other than `zlib` is negative beyond the 0.88% the control group
reaches on its own.

---

## 6. What this record does not claim

* It does not re-derive the legacy baselines. They are Gate A's, frozen, and
  §1 gives the reason they are still valid.
* It does not claim the candidate build got faster. It did not; it is flat.
* It does not claim `zlib` is unaffected. §4 gives the number and its limits.
* It does not authorise the deletion. It records that the blocker named at
  Gate A — the dual-comparator divergence — is closed, and what closing it
  cost.
