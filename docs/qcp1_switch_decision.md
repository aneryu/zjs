# QCP-1 switch decision packet

Branch `compiler-v2-qjs`, tip `a1eed054` (the switch-trampoline divergence
closure). Measurement and documentation only.

**This document does not recommend switching or not switching.** It states, for
each of the ruling's three groups, which conditions are MET, which are NOT MET,
and which need a ruling rather than another measurement. The decision is
reserved.

> **AMENDED 2026-08-03 — the decision is no longer reserved.** The ruling was
> issued: **V2 + `.short` is the production default; V2 + `.plain` is
> REJECTED.** The absolute `code-load ≥ 0.58` bar that §2 measures against is
> **SUPERSEDED**. Sections 1–7 below are preserved exactly as measured — they
> are the evidence the ruling was made on, and nothing in them is restated —
> but every verdict phrased against the absolute bar must be read through
> **§0.1**, which records the superseded gate, why it was superseded, the gate
> that replaces it, and the two process rules this phase produced.

> **CLOSED 2026-08-04 — read §8 first.** QCP-1 is terminated in **§8. FINAL
> VERDICTS**, as **two** separately adjudicated outcomes:
> **QCP-1A — V2 compiler migration: ACCEPT** (V2 + `.short` is the shipped
> production default), and **QCP-1B — legacy physical removal: NO-GO,
> deferred**. §8 is the release record; §0–§7 are the evidence it was decided
> on. Nothing in §0–§7 is rewritten by §8.

---

## 0. Headline

| group | state |
| --- | --- |
| **Correctness** | every gate MET at this tip, re-run here, nothing carried forward |
| **Architecture** | C2-A/B/C closed; STOP-D not triggered; **STOP-E passes on one ruler and still triggers on the other**; C1 worse; C4 net is **+1 concept** on the reading the ruling's own wording implies |
| **Performance** | code-load **0.558 vs pinned qjs — NOT MET** against the ≥ 0.58 bar, measured directly rather than projected. On the full 15-benchmark zoo the shipped configuration is **16.5% geomean *behind* the branch's own legacy mode**, and that entire deficit is the deferred `.short` item: a scratch `.short` build measures **at legacy parity (+1.7% geomean) while keeping the whole code-load win**. |

The performance section is the one that changed shape during this phase. The
previously reported v2 figure of 0.5571 was a projection (legacy-vs-qjs × the
v2/legacy ratio). Measured directly it is 0.5575–0.5597 — the projection was
accurate — but the full-suite measurement that had never been run under v2
shows the code-load win is paid for everywhere else, and identifies the payer
exactly.

---

## 0.1 RULING (2026-08-03): the superseded gate, the new gate, the process defects

### 0.1.1 SUPERSEDED: the absolute bar `code-load ≥ 0.58`

~~**Switch gate: code-load ≥ 0.58 vs pinned qjs.**~~ **SUPERSEDED.** Kept
visible rather than deleted, because the packet's whole §2 is written against
it and a reader must be able to see what the numbers were being judged by.

The bar was never an absolute physical target. It was set as a **ratio against
the then-current legacy baseline**, and that baseline was later found to be
wrong:

| quantity | value | note |
| --- | ---: | --- |
| legacy baseline the bar was set against | **0.4693** | erroneous — inflated by a real `Lexer.freeToken` atom leak that main still carried |
| the bar as written | 0.58 | |
| **its actual engineering content** | **0.58 / 0.4693 = 1.2359×** | "beat legacy on code-load by ~+23.6%" |
| corrected legacy baseline | **0.4458** | measured here, §2.2, reproduced to 0.2% across four independent rounds |
| **equivalent absolute bar after the correction** | **0.4458 × 1.2359 = 0.5510** | |

Holding the literal 0.58 after the baseline was corrected would have raised the
requirement from **about +23.6% to about +30.1%** (0.58 / 0.4458 = 1.3010×)
without anyone deciding to. That was never the ruling. A gate expressed as an
absolute number against a moving baseline silently re-rates itself every time
the baseline is corrected; this one did, and it is why the gate is now
expressed as a ratio.

### 0.1.2 THE GATE IN FORCE

The switch requires **all three**, jointly:

1. **code-load, v2 / corrected-legacy ≥ 1.2359×** — the original engineering
   content of the bar, restated against the baseline that is actually true.
2. **full-zoo geomean not regressed** versus the same corrected legacy.
3. **no non-code-load benchmark negative beyond noise.**

Current `.short` measurement against those three:

| gate | required | measured (`.short`) | state |
| --- | --- | ---: | --- |
| code-load ratio | ≥ 1.2359× | **1.2510×** (0.5577 / 0.4458, dedicated 12-sample round; the 4-sample suite run gives 1.2536× and the four 12-sample `.plain` pairings 1.2547×) | **MET** |
| full-zoo geomean | not regressed | **0.7147 / 0.7029 = 1.0168×** | **MET** |
| per-benchmark floor | none negative beyond noise | 14 non-code-load benchmarks within 1.3% of legacy; the one outlier is regexp at **+5.1%**, i.e. positive | **MET** |

### 0.1.3 PROCESS DEFECT 1 — the full-zoo blind spot

This is recorded as a defect in its own right, not as a footnote to the
performance section, because the failure was in the measurement design and not
in the compiler.

**Code-load alone passed while the configuration actually on the branch was
16.5% geomean WORSE across 15 benchmarks, with 14 of 15 regressing** (§2.4).
The campaign had optimized, reported and gated on a single benchmark for an
entire phase; the suite that would have exposed the cost had never been run
under v2 at all. The regression was not small, not subtle and not confined to
an edge case — it was almost every benchmark, by up to 43%.

**The rule this produces:**

> A single-benchmark result can never license a compiler, VM-dispatch or
> bytecode-layout default change. Any change whose blast radius is the whole
> emitted-code path must be adjudicated on the full suite, whatever the
> targeted benchmark says.

The reason the rule is stated at the level of *blast radius* rather than
*benchmark*: code-load was a perfectly good instrument for the compile path,
and it stayed honest — it moved by 0.2% between `.plain` and `.short` because
it is compile-bound. It was never wrong. It was simply blind to the axis the
change actually moved, and no amount of extra sampling on it would have
produced the missing information.

### 0.1.4 PROCESS DEFECT 2 — a gate that was green about a configuration it never ran

`zig build test-altrepr` spawned a nested `zig build` that started from the
option **defaults**, so `zig build test-altrepr -Dzjs_compiler=v2` reported
green for a run of the **legacy** suite (§3.2). Forwarding the whole `-D`
option set closed that instance.

**The class is now closed structurally**, not instance by instance: every build
computes a canonical **configuration signature** over the six settings this
ruling makes load-bearing — compiler mode, layout mode, value representation,
**optimize mode**, force-GC, ownership audit — and every artifact states the
signature its green belongs to.

* the signature is derived from the declarations the code **consumes**
  (`resolve_labels.default_layout`, the `Parser` backend-dispatch decision,
  `core.value.nan_boxing`, `builtin.mode`,
  `core.memory.force_gc_on_allocation_enabled`,
  `core.atom.ownership_audit_enabled`), never from the `-D` strings, so a
  signature cannot attest to a decision the code does not make;
* **every engine-bearing artifact proves its own configuration at compile
  time**: `comptime { config_signature.attest("<artifact>"); }` in each root
  compares `actualEffectiveConfig()` against what the build graph requested and
  fails the COMPILATION on a mismatch, naming the artifact, the expected
  string, the actual string and the differing fields. No test artifact borrows
  the `src/all_tests.zig` root's attestation (§0.1.9);
* `zjs --print-config-signature` makes the shipped binary state its own
  configuration, and `zig build config-signature-check` compares that against
  what the build graph requested;
* `-Dzjs_expect_config=<sig>` lets a parent build state what a nested build
  must resolve; `test-altrepr` uses it with the representation inverted, so a
  dropped option is a **hard build failure** instead of a silent green;
* `zig build config-drift-gate` — wired into `checkpoint-check` and
  `engine-production-gate` — requires a wrong `compiler` expectation and a
  wrong `layout` expectation to FAIL and the correct one to SUCCEED, so the
  attestation's ability to fail is itself gated rather than attested once.

Originally verified by forcing the drift by hand: hardcoding `default_layout =
.plain` under a `short` build, and hardcoding the backend-dispatch decision to
legacy under a `v2` build, each failed both `config-signature-check` and the
in-suite attestation. **That evidence decays** — a later refactor can hollow the
check out and nothing goes red — which is why the forced-drift probe was
replaced by the permanent machine-executed gate above.

### 0.1.5 THE TWO MEASUREMENT TIERS

The blind spot above was possible because one kind of measurement was doing two
different jobs. They are now separated and must be labelled:

**INTERMEDIATE — not a switch gate.** Cheap, fast, run per cut: code-load,
insn/score, cyc/score, compiler scratch measurements. Every report at this tier
must carry the literal words **"INTERMEDIATE — not a switch gate"**. It exists
to steer work between decisions. It may not conclude one.

**FINAL SWITCH.** Run on **candidate true production defaults** — the actual
shipping configuration, not a scratch probe or a flipped constant — and must
report, all of them:

* full-suite geomean over all 15 zoo throughput benchmarks;
* per-benchmark paired ratio;
* code-load;
* insn / score;
* cyc / score;
* artifact size;
* the full correctness matrix.

A `.short` number obtained by flipping a constant in a scratch binary (§2.5) is
INTERMEDIATE by construction, however carefully it was measured — which is
precisely why `.short` had to become a real, defaulted build option before the
switch could be gated on it.

### 0.1.6 `.short` IS RELEASE CONFIGURATION, NOT AN OPTIMIZATION

`-Dzjs_v2_layout=short` is part of the release configuration and is defaulted as
such. It is not a tuning knob that may drift: the switch was gated on it, and
the `.plain` configuration is REJECTED for production. `.plain` remains
reachable as the A/B diagnostic instrument — it is how C2-B localised artifact
residency, and that instrument must not be destroyed.

**Follow-up, not a blocker:** C2-B's artifact-residency finding (+31,640 B,
**+6.8%**, §1/§2.2 of the scorecard) was measured under `.plain` and was
attributed *to* `.plain`. It therefore needs **re-accounting under `.short`**,
where most or all of it is expected to disappear. Until that re-measurement is
done, the +6.8% figure describes a configuration that is no longer shipped and
must not be quoted against the shipping one.

### 0.1.7 What landed with the defaults flip

Production default signature, verbatim, as reported by the built binary
(`zig-out/bin/zjs --print-config-signature`):

```
zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

The prefix was `zjs-config-v1` when the defaults flip landed and the string had
no `optimize` field; it was bumped when `optimize` was added (§0.1.9), so a
recorded v1 string cannot be read as complete proof of a six-field
configuration. **Any `zjs-config-v1:...` string in an older report attests to
five settings and says nothing about the optimize mode the binary was built
with.**

| gate | result |
| --- | --- |
| `zig fmt --check build.zig src tools` | PASS |
| `zig build zjs` × {default, `-Dzjs_compiler=legacy`, `-Dzjs_compiler=dual`} | PASS ×3 |
| `zig build config-signature-check` × {default, legacy, dual, `-Dzjs_v2_layout=plain`} | PASS ×4 |
| `zig build test` (default = v2 + short) | 2269 passed, 1 skipped, 0 failed |
| `zig build test -Dzjs_compiler=legacy` | 2121 passed, 149 skipped, 0 failed |
| `zig build test -Dzjs_compiler=dual` | 2269 passed, 1 skipped, 0 failed |
| `zig build test -Dzjs_v2_layout=plain` | 2269 passed, 1 skipped, 0 failed — the diagnostic instrument still works |
| `zig build test-altrepr` (default) | 2269/1/0, child attests `repr=nan_boxed,compiler=v2,layout=short` |
| `zig build test-altrepr -Dzjs_compiler=legacy` | 2121/149/0, child attests `compiler=legacy` |
| `zig build test-altrepr -Dzjs_compiler=dual` | 2269/1/0, child attests `compiler=dual` |

One test was found to have silently depended on the old default and was
corrected rather than pinned: `compiler_v2.s4: installed for loop uses plain
layout` asserted the production path emits no short opcodes. It now asserts the
installed artifact against `resolve_labels.default_layout` and is renamed
accordingly — the same defect class as §0.1.4, one level down.

### 0.1.8 PROCESS DEFECT 3 — test262 results with no recorded backend

**The correction.** Before the defaults flip, `-Dzjs_compiler` defaulted to
`legacy`. `zig build test262-gate` and `zig build test262-smoke` build their
runner from the ordinary engine module, so **both executed the LEGACY compiler
whenever they were invoked without an explicit `-Dzjs_compiler`.** Every
historical test262 result recorded in this repository with no backend flag
beside it is therefore a **legacy** result, and **cannot serve as V2 proof**,
whatever the surrounding text said it was about.

This is the same defect class as §0.1.4 — a result reading as a statement about
a configuration it never ran — reaching the largest correctness gate in the
project. It is disclosed here rather than quietly fixed because the fix
(defaulting to `v2`) silently changes the meaning of every future invocation of
the same command, and the reader has to be able to tell the two eras apart.

**This does NOT overturn the campaign's conclusions.** The decisive V2 and dual
data carried explicit backend flags. P6 recorded the two runs separately:

| run | command | result |
| --- | --- | --- |
| legacy | `zig build test262-gate` | `0/49775 errors, passed 44541, known 25` |
| v2 | `zig build test262-gate -Dzjs_compiler=v2` | `0/49775 errors, passed 44541, known 25` |

The V2 row was obtained under an explicit `-Dzjs_compiler=v2`, so it is a real
V2 measurement and the "identical in both modes" conclusion in §3.2 stands on
its own evidence. What the correction removes is the *implicit* reading — that
an unflagged `test262-gate` line anywhere else in the history was ever a
statement about V2. It was not.

**What changes going forward.** After the defaults flip an unflagged
`test262-gate` runs **v2**, and the runner binary now attests its own
configuration at compile time (`run-test262 / test-runner`, §0.1.9), so a
test262 sweep can name the backend it ran instead of leaving it to be inferred
from the absence of a flag. Historical tables in this packet now carry an
explicit **backend provenance** column (§3) so no row's backend has to be
inferred at all.

### 0.1.9 What the tightening added

Five additions on top of the defaults flip, all additive to §0.1.4's mechanism.

1. **`optimize` is a signature component, and the version was bumped to
   `zjs-config-v2`.** The five-field signature could not detect a nested build
   losing or changing Debug / ReleaseSafe / ReleaseFast / ReleaseSmall: a parent
   asking for ReleaseSafe while the child actually built Debug produced an
   identical `compiler`/`layout`/`repr` triple and read as green. The optimize
   mode is not a performance setting in this context — it decides whether the
   Debug and ReleaseSafe **oracles exist at all** (whether `std.debug.assert` is
   live, whether safety checks trap, whether ReleaseFast genuinely strips the
   validation paths), and therefore whether a release gate measured a production
   binary or a safety build. It is read from `builtin.mode` at the consumption
   point, not from build.zig's resolved `-Doptimize`. The version bump is
   deliberate: a historical `zjs-config-v1` string must not be readable as
   complete proof once the field set has grown, and it now fails on the version
   component instead of matching a v2 build on its first five fields.
2. **Every test artifact proves its own configuration.** `test-core`,
   `test-parser`, `test-bytecode`, `test-exec`, `test-builtins`, `test-runtime`,
   `test-runner`, `test-compiler-v2`, `oom-tests`, `unified-tests` and the
   `zjs` / `zjs-profile` / `zjs-dev` CLI root each run the same shared helper at
   compile time. **Each reports its OWN mode**: the scoped Debug test artifacts
   say `optimize=Debug`, the release candidate says `optimize=ReleaseFast`.
   Nothing borrows the `src/all_tests.zig` root's attestation any more.
3. **A permanent negative drift gate.** `zig build config-drift-gate`
   (`tools/architecture/check_config_drift.js`), wired into `checkpoint-check`
   and `engine-production-gate`. Five halves, each a child build of an
   engine-bearing artifact: wrong `compiler` → must fail; wrong `layout` → must
   fail; correct expectation → must succeed; `-Dzjs_v2_layout=plain` with a
   `layout=plain` expectation → must succeed; wrong `optimize` → must fail.
   Both directions are mandatory — the negative halves alone would be satisfied
   by a check that always fails, the positive halves alone by one that never
   fails. A negative half is only accepted when the child failed **and** its
   output carries the attestation's own diagnostic naming the drifted
   component, so a build that fails for an unrelated reason is reported as
   inconclusive rather than counted as evidence. Each half prints which half it
   is and, for the negative ones, that the build error below it is the expected
   result.

   The `optimize` half has to run against an artifact that FOLLOWS
   `-Doptimize`, because an artifact that PINS its mode legitimately reports
   the pinned mode and cannot express the drift. That distinction is load
   bearing in the build too: an explicit `-Dzjs_expect_config` is handed to
   optimize-following artifacts **verbatim** — which is what makes "parent
   asked for ReleaseSafe, child built Debug" fail — and only has its `optimize`
   field substituted for the pinned ones. Substituting everywhere would have
   rewritten the assertion into whatever the child did and always agreed.

   The half-5 run also proves the attestations are live in files that are not
   compilation roots: it reports **6 artifact attestations firing** in one
   child build (`unified-tests`, `test-core`, `test-parser`, `test-bytecode`,
   `zjs CLI`, `run-test262 / test-runner`).
4. **The `.plain` diagnostic self-proves.** The failure mode being closed is a
   `.plain` switch that exists in name while being ignored in fact, which would
   silently invalidate every A/B diagnostic run with it. Two independent
   proofs: (a) the *same* `layout=plain` expectation must FAIL against a `short`
   build (half 2) and SUCCEED against `-Dzjs_v2_layout=plain` (half 4), which is
   only possible if the value compared is the one the resolver consumes; (b)
   `compiler_v2.s4: installed for loop matches the configured default layout`
   reads short-form opcodes back off the **installed FunctionBytecode** and
   checks `-Dzjs_v2_layout` against that observation — the option string is
   checked against the emitted bytes, not the other way round.
5. **The test262 backend provenance correction** (§0.1.8, §3).

Signatures, verbatim, from the artifacts themselves — the same configuration
seen from three artifacts with three different pinned modes:

```
zjs             zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
zjs-dev         zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=Debug,force_gc=off,ownership_audit=off
unified-tests   zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=Debug,force_gc=off,ownership_audit=off
zjs (plain)     zjs-config-v2:compiler=v2,layout=plain,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

| gate | result |
| --- | --- |
| `zig fmt --check build.zig src tools` | PASS |
| `zig build architecture-check` | PASS |
| `zig build config-drift-gate` | **5/5 halves behaved as required** |
| `zig build config-signature-check` × {default, legacy, dual, `-Dzjs_v2_layout=plain`} | PASS ×4 |
| `zig build test` (default = v2 + short) | 2271 passed, 1 skipped, 0 failed — suite attests `compiler=v2,layout=short,optimize=Debug` |
| `zig build test -Dzjs_compiler=legacy` | 2123 passed, 149 skipped, 0 failed — attests `compiler=legacy` |
| `zig build test -Dzjs_compiler=dual` | 2271 passed, 1 skipped, 0 failed — attests `compiler=dual` |
| `zig build test -Dzjs_v2_layout=plain` | 2271 passed, 1 skipped, 0 failed — attests `layout=plain` |
| `zig build test-altrepr` × {default, legacy, dual} | 2271/1/0, 2123/149/0, 2271/1/0 — children attest `repr=nan_boxed` with `compiler=v2` / `legacy` / `dual` |
| `zig build test-core` / `test-parser` / `test-bytecode` / `test-exec` | 320/1/0, 477/0/0, 211/0/0, 406/0/0 |
| `zig build test-builtins` / `test-runtime` / `test-runner` / `test-compiler-v2` | 195/0/0, 77/0/0, 43/0/0, 197/0/0 |
| `zig build test-compiler-v2 -Dzjs_v2_layout=plain` | 197 passed, 0 skipped, 0 failed |
| `zig build test-oom` | 21 passed, 0 failed |
| `zig build perf-same-runtime perf-direct-build` | PASS — both harnesses now attest the production ReleaseFast signature |

**Artifacts that still cannot self-attest, and why.** Three, all for the same
structural reason: their compilation contains no engine module, so there is no
"actual" side to read.

* `smoke-tests-releasefast` / `smoke-tests-debug` (`src/tests/smoke_test.zig`)
  drive the `zjs` binary through the filesystem and receive only executable
  paths. Covered instead at runtime: `zig build smoke` depends on
  `config-signature-check`, which runs the very binary under test and compares
  its self-reported signature.
* `check-public-api` and the two runtime plugin fixtures root on the PUBLIC
  engine module (`src/root.zig`), which deliberately does not export
  `config_signature`. Attesting there would mean adding an internal symbol to
  the public API surface that the API-snapshot gate exists to police, and the
  API snapshot is backend-independent by construction.

---

## 1. Provenance

| item | identity |
| --- | --- |
| tree | `/home/aneryu/.claude/jobs/9023bf51/tmp/wt-p6`, `compiler-v2-qjs` @ `a1eed05459ce56c77b5ffd8aa3ad379f3e275cf3`, working tree clean |
| pinned qjs | `/home/aneryu/quickjs/qjs`, sha256 `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`, quickjs @ `04be2460` |
| zoo | `/home/aneryu/javascript-zoo` @ `a17d4e0a`, clean |
| host | kernel 6.17.0-1014-nvidia, all benchmarks `flock -x /tmp/zjs-host-heavy.lock taskset -c 19`, effective affinity verified `{19}` by the runner |

### 1.1 The four cold binaries — and the disclosure the protocol requires

Two independent cold builds per side, `rm -rf .zig-cache zig-out` before each,
same tree, same tip:

| binary | mode | sha256 | size |
| --- | --- | --- | ---: |
| legacy-A | `-Dzjs_compiler=legacy` | `9eb25e9d3077117f060aa70b341a60685ad64c33303e0cc236e99ddc7f55bfb5` | 29,803,608 |
| legacy-B | `-Dzjs_compiler=legacy` | `9eb25e9d3077117f060aa70b341a60685ad64c33303e0cc236e99ddc7f55bfb5` | 29,803,608 |
| v2-A | `-Dzjs_compiler=v2` | `7d9a0ff37a69f11b0176acbbff2395c23654e463484eda64382695abc66d8908` | 31,557,416 |
| v2-B | `-Dzjs_compiler=v2` | `7d9a0ff37a69f11b0176acbbff2395c23654e463484eda64382695abc66d8908` | 31,557,416 |

**Both pairs came out byte-identical.** The build is reproducible on this host
at this tip, so the "two independent binaries per side" control has nothing to
control: there is no build lottery to average over. As previous stages did, it
is substituted by **independent sampling rounds** — the four pairings below are
four independent 12-sample rounds of the same two binaries, and the two
same-binary rounds give the measurement noise floor directly.

v2's binary is **+5.9%** larger than legacy's (+1,753,808 B); that is a
whole-binary figure and is not the C2-B artifact number.

---

## 2. PERFORMANCE

### 2.1 zoo code-load, four pairings × 12 ABBA samples

Score is higher-is-better; ratio is `first / second`.

| round | comparison | ratio |
| --- | --- | ---: |
| 1 | v2-A / legacy-A | 1.2558 |
| 2 | v2-B / legacy-A | 1.2550 |
| 3 | v2-A / legacy-B | 1.2541 |
| 4 | v2-B / legacy-B | 1.2539 |
| | **mean** | **1.2547** (spread 0.0018 = 0.14%) |
| noise floor | legacy-A / legacy-B (same bytes) | 0.9990 |
| noise floor | v2-A / v2-B (same bytes) | 1.0000 |

The v2/legacy code-load win is **+25.5%**, and it is 140× the measurement noise.

### 2.2 Direct against pinned qjs — no projection

| binary | code-load median | qjs median | ratio vs qjs |
| --- | ---: | ---: | ---: |
| v2-A | 18,248 | 32,700 | **0.5580** |
| v2-B | 18,271 | 32,642 | **0.5597** |
| legacy-A | 14,548 | 32,698 | 0.4449 |
| legacy-B | 14,572 | 32,705 | 0.4456 |
| v2 in the 15-bench run (4 samples) | 18,275 | 32,779 | 0.5575 |
| legacy in the 15-bench run (4 samples) | 14,560 | 32,658 | 0.4458 |

* **The bar is code-load ≥ 0.58. Measured: 0.5575 – 0.5597. NOT MET**, short by
  0.020–0.022, i.e. 3.5–3.9% of the bar.
* The branch's legacy mode reproduces the corrected campaign baseline: **0.4458
  measured (15-bench run) / 0.4449–0.4456 (12-sample rounds) against the
  campaign's 0.4458 and the 0.4448 recorded in
  `reports/perf/qjs-align/2026-08-02/zoo/zoo-mainfix.json`** — a spread of 0.2%.
  The ruler is calibrated.
* The previously reported v2 figure 0.5571 was a projection through the
  v2/legacy ratio. The direct measurement confirms it to within 0.4%; the
  projection was not the problem.

### 2.3 Score-normalized `perf stat` over the code-load script

Two interleaved rounds per side (round 2 runs the reverse order); 4 samples per
zjs side, 2 for qjs. Normalized by the score the run itself publishes.

| side | insn / score | cyc / score | IPC |
| --- | ---: | ---: | ---: |
| legacy | 1,939,551 | 536,630 | 3.614 |
| **v2** | **1,599,460** | **428,830** | **3.730** |
| qjs | 981,434 | 247,872 | 3.959 |

| ratio | insn/score | cyc/score |
| --- | ---: | ---: |
| v2 / legacy | **0.8247** | **0.7991** |
| v2 / qjs | 1.6297 | 1.7300 |
| legacy / qjs | 1.9762 | 2.1649 |

Per unit of published score v2 retires **17.5% fewer instructions** and burns
**20.1% fewer cycles** than legacy, and closes the gap to qjs from 1.98× to
1.63× instructions and from 2.16× to 1.73× cycles. Within-side spread is
≤ 0.23% on every counter, so these are not noise.

### 2.4 The full 15-benchmark zoo — v2 vs pinned qjs, directly

`--samples 4`, all 15 throughput benchmarks. `v2.short` is a **scratch
attribution probe** (see §2.5) and is not a shipped configuration.

| benchmark | v2 (`.plain`, shipped) | v2 `.short` (probe) | branch legacy | short/legacy | shipped/legacy |
| --- | ---: | ---: | ---: | ---: | ---: |
| code-load | 0.5575 | 0.5589 | 0.4458 | 1.2536 | **1.2505** |
| pdfjs | 0.4096 | 0.4618 | 0.4627 | 0.9979 | 0.8853 |
| raytrace | 0.4507 | 0.5118 | 0.5141 | 0.9954 | 0.8767 |
| earley-boyer | 0.4788 | 0.5692 | 0.5702 | 0.9983 | 0.8398 |
| typescript | 0.5721 | 0.7025 | 0.7036 | 0.9985 | 0.8131 |
| navier-stokes | 0.4154 | 0.7270 | 0.7316 | 0.9938 | **0.5679** |
| crypto | 0.5483 | 0.7357 | 0.7363 | 0.9992 | 0.7447 |
| box2d | 0.6336 | 0.7424 | 0.7396 | 1.0037 | 0.8566 |
| splay | 0.6265 | 0.7368 | 0.7462 | 0.9875 | 0.8397 |
| richards | 0.6463 | 0.7965 | 0.7955 | 1.0012 | 0.8125 |
| deltablue | 0.6697 | 0.7972 | 0.8006 | 0.9958 | 0.8365 |
| mandreel | 0.6851 | 0.8163 | 0.8161 | 1.0003 | 0.8395 |
| zlib | 0.7342 | 0.8303 | 0.8282 | 1.0026 | 0.8865 |
| gbemu | 0.6089 | 0.8394 | 0.8406 | 0.9986 | 0.7244 |
| regexp | 0.9976 | 1.1609 | 1.1046 | 1.0510 | 0.9031 |
| **throughput geomean** | **0.5869** | **0.7147** | **0.7029** | **1.0167** | **0.8349** |
| geomean excluding code-load | 0.5890 | 0.7273 | 0.7262 | 1.0016 | 0.8111 |
| MandreelLatency | 0.6741 | 0.8578 | 0.8824 | 0.9721 | 0.7640 |
| SplayLatency | 0.5779 | 0.6391 | 0.6392 | 0.9998 | 0.9042 |

Stated plainly: **as shipped, switching to v2 buys +25% on code-load and pays
16.5% geomean across the suite.** Fourteen of the fifteen benchmarks regress —
every one except code-load itself — and the worst is navier-stokes at −43%, then
gbemu −28% and crypto −26%.

The branch's legacy geomean 0.7029 reproduces main's corrected baseline 0.6984
within 0.6%, so the suite ruler is calibrated too.

### 2.5 Attribution: the whole deficit is `default_layout = .plain`

`src/compiler_v2/resolve_labels.zig:21` sets `default_layout = .plain`, so v2
publishes long-form bytecode where legacy emits the compact opcodes
(`get_loc0..3`, `push_i8`, `goto8`, …). C2-B already attributed the +6.8%
artifact-byte delta to it. This phase measured what it costs at **run** time.

A scratch binary was built with that one constant flipped to `.short`
(sha256 `1010c26e2241b0de60fe0df4b7428443ca57d4e8f18e6080ebd22bfd736cb39b`); the
source was reverted before any measurement ran and the committed tree still says
`.plain` (`git status` clean). Result:

* on the 14 non-code-load benchmarks, `.short` v2 lands at **1.0016× legacy
  geomean** — every benchmark within 1.3% of legacy except regexp (+5.1%, the
  suite's noisiest and the one zjs already wins);
* code-load is **unchanged** by the layout (0.5589 `.short` vs 0.5575 `.plain`,
  and a dedicated 12-sample round gives 0.5577) — it is compile-bound, so the
  emitted-code form does not move it;
* whole-suite geomean **0.7147 vs legacy 0.7029: +1.7%**.

So the two halves separate cleanly. **The compile-path win is v2's and survives
either layout. The execution-path loss is entirely the `.plain` default and
disappears under `.short`.** `.short` is frozen as the production default and
is not changed by this document; what is now known is its price.

> **AMENDED 2026-08-03.** This probe is INTERMEDIATE by construction (§0.1.5):
> it flips a constant in a scratch binary, which is not a shipped configuration
> and therefore cannot license a switch on its own. That is exactly why the
> ruling required `.short` to become a real, defaulted build option
> (`-Dzjs_v2_layout`, default `short`) and be re-measured as a candidate true
> production default before the FINAL SWITCH tier could be run on it.

### 2.6 Performance conditions

| condition | state |
| --- | --- |
| ~~code-load ≥ 0.58 vs pinned qjs, measured directly~~ | ~~**NOT MET** — 0.5575–0.5597~~ **SUPERSEDED** — the bar's engineering content was 0.58/0.4693 = 1.2359×; against the corrected baseline the equivalent absolute bar is 0.5510. See §0.1.1. |
| **code-load, v2 / corrected-legacy ≥ 1.2359× (the gate in force)** | **MET** — 1.2510× on `.short` (§0.1.2) |
| v2 improves code-load over the branch's own legacy | **MET** — 0.4458 → 0.5575, +25.1% |
| v2 improves instructions and cycles per unit of code-load score | **MET** — insn/score 0.825×, cyc/score 0.799× |
| whole-suite throughput not worse than legacy | **NOT MET as shipped** — 0.5869 vs 0.7029, −16.5% geomean, 14/15 benchmarks regressed. **This is why `.plain` is REJECTED** (§0.1.6). |
| whole-suite throughput not worse than legacy, with the deferred `.short` | MET in the probe — 0.7147 vs 0.7029, +1.7%. **Now the shipped configuration**, so this row is no longer a probe (§0.1.2, §0.1.6). |
| ~~**needs a ruling**~~ | ~~whether the switch is assessed on the shipped `.plain` configuration or on a configuration that also lands `.short`. The two answers differ by 21.8% geomean and by nothing at all on code-load.~~ **RULED (2026-08-03):** on the configuration that lands `.short`. `.plain` is REJECTED for production and kept only as the A/B diagnostic instrument. |

---

## 3. CORRECTNESS ROLL-UP

Every gate below was **re-run at this tip**; none is carried forward.

**Backend provenance column.** Added retroactively (§0.1.8). Before the defaults
flip `-Dzjs_compiler` defaulted to `legacy`, so a command with no backend flag
ran the legacy compiler no matter what the row was labelled. Every row is
therefore marked with how its backend was actually determined, and **every
pre-switch row with no recorded flag is marked `implicit-legacy-default`** —
including the rows whose label already said "legacy", where the label was
right by accident of the default rather than by instruction. Two labels beyond
the three the ruling names were unavoidable: `explicit-legacy` where the flag
was passed explicitly, and `n/a` where the row builds no engine at all.

| gate | command | result | backend provenance |
| --- | --- | --- | --- |
| formatting | `zig fmt --check src build.zig` | PASS | `n/a` — no engine build |
| build ×3 | `zig build zjs` with `legacy` / `v2` / `dual` | PASS / PASS / PASS | `explicit-legacy` / `explicit-v2` / `explicit-dual` |
| S3R+ oracles (legacy) | `zig build test-compiler-v2` | 50 passed, 147 expected skips, 0 failed | `implicit-legacy-default` |
| S3R+ oracles (v2) | `zig build test-compiler-v2 -Dzjs_compiler=v2` | **197 passed, 0 skipped, 0 failed** | `explicit-v2` |
| S3R+ oracles (dual) | `zig build test-compiler-v2 -Dzjs_compiler=dual` | **197 passed, 0 skipped, 0 failed** | `explicit-dual` |
| unified suite (legacy) | `zig build test` | 2119 passed, 149 skipped, 0 failed | `implicit-legacy-default` |
| unified suite (v2) | `zig build test -Dzjs_compiler=v2` | **2267 passed, 1 skipped, 0 failed** | `explicit-v2` |
| unified suite (dual) | `zig build test -Dzjs_compiler=dual` | **2267 passed, 1 skipped, 0 failed** | `explicit-dual` |
| OOM injection | `zig build test-oom -Dzjs_compiler=v2` | 21 passed, 0 failed | `explicit-v2` |
| force-GC | `zig build test-core -Dzjs_compiler=v2 -Dzjs_force_gc=true` | 320 passed, 1 skipped, 0 failed | `explicit-v2` |
| altrepr (v2) | `zig build test -Dzjs_compiler=v2 -Dzjs_nan_boxing=true` | **2267 passed, 1 skipped, 0 failed** | `explicit-v2` |
| altrepr (dual) | `zig build test -Dzjs_compiler=dual -Dzjs_nan_boxing=true` | 2267 passed, 1 skipped, 0 failed | `explicit-dual` |
| altrepr (legacy) | `zig build test-altrepr` | 2119 passed, 149 skipped, 0 failed | `implicit-legacy-default` |
| ownership audit (v2) | `zig build test -Dzjs_compiler=v2 -Dzjs_ownership_audit=true` | **2268 passed, 0 skipped, 0 failed** | `explicit-v2` |
| ownership audit (legacy) | `zig build test -Dzjs_ownership_audit=true` | 2120 passed, 148 skipped, 0 failed | `implicit-legacy-default` |
| borrowed-atom lint + deps + OOM-panic + API | `zig build architecture-check` | PASS — "34 token-atom reads, 10 in value position, 26 borrowed locals tracked, **14 escapes found, 14/16 allowlisted**"; deps ok; OOM-panic ok; API snapshot ok (153 symbols) | `n/a` for the three source-scan lints; `implicit-legacy-default` for the API-snapshot binary (the snapshot is backend-independent) |
| test262 legacy | `zig build test262-gate` | **`0/49775 errors, passed 44541, known 25`** | `implicit-legacy-default` — and this is the row §0.1.8 is about |
| test262 v2 | `zig build test262-gate -Dzjs_compiler=v2` | **`0/49775 errors, passed 44541, known 25`** | `explicit-v2` |
| TS L2 probe — enum | `enum E{A,B}; console.log(E.A,E.B,E[0])` | legacy `0 1 A` / v2 `0 1 A` | `implicit-legacy-default` / `explicit-v2` |
| TS L2 probe — namespace | `namespace N{export const x=41} console.log(N.x)` | legacy `41` / v2 `41` | `implicit-legacy-default` / `explicit-v2` |
| dual corpus | `mc.js`, `ma.js` under v2 and under dual | 240/240 on all four runs; **0 `ZJS-DUAL-MISMATCH` lines** | `explicit-v2` / `explicit-dual` |
| L3 emission (v2) | `ZJS_V2_EMISSION_COLLECT=1 zjs-dev` on `mc.js` / `ma.js` | `v2_construct_emitted=4487085/4487162  legacy_construct_emitted=241  legacy_in_v2_scope=0  legacy_in_v2_unallowed=0  sites_dropped=0` | `explicit-v2` — the `zjs-dev` binary was built with `-Dzjs_compiler=v2`; the counters are meaningless otherwise, which is what makes this row self-checking |
| L3 allowlist | `src/compiler_v2/coverage.zig:25` | `pub const legacy_allowlist = [_]AllowlistEntry{};` — **empty**, and `LegacyConstruct` has only `none` | `n/a` — source inspection |
| escape audit | `docs/v2_escape_audit.md` | 3 EXPLICIT / 2 IMPLICIT-BUT-SOUND / **0 UNCLEAR**; its three pinned tests run inside the suites above | `n/a` — document; the pinned tests inherit the provenance of the suite that runs them |

### 3.1 The divergence closure, and what it proved

The premise that this was one leftover edge case was wrong, and the sweep is
what proved it. Four independent defects were found, not one, sharing a single
mechanism: **legacy resolves jump targets after layout and reasons in
ADDRESSES; v2 reasons in `LabelId`s and cannot patch operands backwards, so it
materialises a dispatch bridge legacy never has.** Every switch defect is that
mismatch surfacing.

In-tree tallies from the sweep artifacts:

| corpus | before | after |
| --- | ---: | ---: |
| 135 constructed `switch` shapes | 65 divergent | **0** |
| 65 constructed sibling control-flow shapes | — | **0** |
| javascript-zoo files compiled under `dual` | 17 of 26 divergent (3 error on missing globals) | **0** |

The packet-level total across both scopes and both corpora is **95 pre-existing
dual divergences over four defects, 17 of 26 real-world benchmark files
affected**. The single largest contributor was not switch-related at all: the
`undefined; return` → `return_undef` fold never skipped its dead tail, so the
loop backedge behind `while (..) { if (..) return; }` survived in v2 — and every
zoo file reaches that shape through the shared Octane `RunStep`. **Any switch
verdict measured on the pre-fix branch would have been measured against a
compiler that diverged on essentially all real code.**

Two method points that generalise past this stage:

* The recorded measurement trap says the reported shape only misbehaves in
  function scope. That is true of that one shape and false of the class: most
  of these mismatch in **both** scopes. Sweeping only function scope would have
  been exactly as wrong as sweeping only top level. Both scopes were run for
  all 200 files.
* One generalisation was tried and **REJECTED**: widening the bridge
  suppression to "is this boundary unreachable" regressed box2d, code-load,
  crypto, earley-boyer, mandreel, typescript, v8-v7 and zlib, because legacy
  keeps plenty of other unreachable goto aliases and inverts against them. The
  committed predicate keeps all three traits of the bridge.

The surviving shapes are pinned as a dual-mode regression corpus in
`src/tests/exec.zig`.

### 3.2 Correctness conditions

| condition | state |
| --- | --- |
| test262 identical in both modes | **MET** — `0/49775 errors, passed 44541, known 25` in both. Provenance (§0.1.8): the legacy row is `implicit-legacy-default` and the v2 row is `explicit-v2`, so both halves of "in both modes" rest on a run that really used the backend it names |
| L3 `legacy_in_v2_scope == 0` with an empty allowlist | **MET** — 0, and the allowlist is literally `{}` |
| dual corpus clean | **MET** — 240/240 ×4, zero mismatches |
| escape audit has no UNCLEAR boundary | **MET** — 3 / 2 / 0 |
| ownership audit and borrowed-atom lint green | **MET** — with **14 allowlisted borrows outstanding**: ownership is machine-*policed*, not machine-*proved* |
| S3R+ oracles, OOM, force-GC, altrepr, TS L2 | **MET** in every mode |
| **not met** | none |
| **needs a ruling** | whether 14 outstanding allowlist entries are acceptable at switch time or must reach zero first — the lint passes either way, so this is a policy question, not a measurement |

One gate-plumbing defect found while running this roll-up, disclosed because it
affects what earlier "altrepr PASS" lines actually proved: **`zig build
test-altrepr` does not forward `-Dzjs_compiler`** (`build.zig:948-959` spawns a
nested `zig build test` with only the representation and seed flags). Running
`zig build test-altrepr -Dzjs_compiler=v2` silently runs the **legacy** suite —
its 2119/149 counts are the legacy counts, not v2's 2267/1. The altrepr rows for
v2 and dual above were therefore obtained explicitly with
`zig build test -Dzjs_compiler=<mode> -Dzjs_nan_boxing=true`, and both pass.

**Fixed after this packet was written.** `test-altrepr` now forwards the outer
invocation's whole `-D` option set plus the resolved optimize mode to the nested
build, so the step is the gate it claimed to be. Re-run at the fix tip:
`zig build test-altrepr` 2119/149 (unchanged), `-Dzjs_compiler=v2` 2267 passed /
1 skipped / 0 failed, `-Dzjs_compiler=dual` 2267/1/0 — the same counts the
explicit form produced, so no verdict in this packet moves. The forwarding is
generic rather than an enumerated list, so a newly added `-D` option cannot
reopen the same hole; `-Doptimize` and `-Dtarget` were dropped by the old code
too, which meant `zig build test-altrepr -Doptimize=ReleaseSafe` silently ran
Debug.

---

## 4. ARCHITECTURE SCORECARD (final)

Same mechanical ruler as `docs/qcp1_architecture_scorecard.md` §0, re-run at
this tip. That ruler reproduces the S6 figures it was calibrated against to
within 0.4%.

### 4.1 C1 — lines, concepts, state, invariants

| | value at `a1eed054` | post-P3 `23f7ed14` |
| --- | ---: | ---: |
| v2 production LOC | **9,212** | 9,156 |
| deletable legacy LOC | **5,889** | 5,868 |
| **C1** | **1.564×** | 1.56× |
| C1 counting migration code | **2.272×** | 2.27× |

Deletable legacy = `pipeline_resolve_variables` 4,359 − curated `v2` reuse
surface 881 (43 decls, 48 exported symbols) + `pipeline_resolve_labels` 1,916 +
parser legacy emission/label machinery 186 + legacy `else`-arm bodies 309.

C1 is **worse** than the 1.11× it was at S6 and P3 is not the cause: the
numerator grew ~2,000 lines of Debug/ReleaseSafe-only identity oracle between S6
and pre-P3. §4.5(b) shows the same oracle dominating the STOP-E sensitivity.

**Runtime concepts** (unchanged since P3 — no new named type landed in the
closure commits):

| | legacy | v2 | delta |
| --- | ---: | ---: | ---: |
| production types | 46 | 40 | −6 |
| production state carriers | 40 | 34 | −6 |
| production mutable fields | 130 | **190** | **+60** |
| Debug/ReleaseSafe-only oracle + test types (no legacy counterpart) | 0 | 18 | +18 |
| …their carriers / fields | 0 / 0 | 15 / 102 | +15 / +102 |

v2 has fewer types and fewer carriers but **46% more simultaneously-live mutable
fields**, concentrated into a few fat pass objects. It is not a
fields-versus-parameters style difference: the parameter load is the same on both
sides (legacy 264 fns / 722 params, mean 2.73, max 11; v2 287 / 772, mean 2.69,
max 10).

**Public invariants** (unchanged since P3): legacy 29 → v2 42. Mechanically
enforced (COMPILE + ASSERT + ORACLE) **13 → 27**; silently violable (NOTHING)
**11 → 2**. v2 has 13 *more* invariants — the "10 concepts replacing 3"
direction the ruling warns about — but nine of legacy's eleven silent
contracts became enforced ones.

Known gap, restated because it is still open: **13 v2 invariants are verified in
code but absent or materially incomplete in the normative contract**
`docs/compiler_v2_contract.md`, which still records the older audited tip
`6d0c69dd`. The contract document is behind the code.

### 4.2 C2 — three dimensions (closed; from `docs/c2_scorecard.md`)

| | question | measurement | verdict |
| --- | --- | --- | --- |
| **C2-A** | transient lowering memory | peak in-window transient bytes 208,605 → **118,954 = 0.5702×** (0.5249× excluding survivors); 0.50×–0.61× across all four measurable syntax families | **PASS** on bytes against the < 0.7× bar. **FAILS on the allocation-count axis**: 15 → 24 live temporaries = 1.60× (1.73×–1.80× per family) — nine extra live temporary allocations at one instant for one function |
| **C2-B** | artifact residency | 467,477 → 499,117 = **+31,640 B, +6.8%** (+4.6% to +9.3% per family). **Entirely group (i) code bytes.** No new persistent table, no extra owner, nothing arena-backed, allocation counts identical family by family (1,785 → 1,785). Root cause `resolve_labels.default_layout = .plain` | `legacy artifact == v2 artifact` is **FALSE**; the delta is explained and localised |
| **C2-C** | peak live set | the peak **is** the parse-end set on both pipelines; **transient/artifact overlap = 0** at that instant; the increase decomposes 34.9% producer footprint + 65.0% parser-arena geometry + 0.04% residual, with residual exactly 0 on all four families; aggregate 1.0756× is the **worst** of five sources — three of four families put v2 *below* legacy (0.81×–0.95×) | **EXPLAINED** — the remainder is parse-end residency, not a lifetime defect |

§2.5 of this document adds the run-time price of the C2-B root cause, which the
memory scorecard could not see: **+16.5% geomean execution loss**, removable by
the same one-line lever.

### 4.3 C3 — comparator special cases

`src/compiler_v2/compare.zig` is untouched since `c7f998b8` (S3R+R), so P3 and
the divergence closure added **zero** comparator special cases. Recount at this
tip:

| view | encoding folds | model normalisations | tolerances | total |
| --- | ---: | ---: | ---: | ---: |
| source-decision count | 35 | 16 | 3 | 54 |
| semantic-family count | 22 | 13 | 3 | 38 |
| distinct semantic targets (closest to the published rule) | **18** | **13** | 3 | **31 + 3** |

`foldOpcode` is verified at this tip as **11 range statements + 11 switch arms =
22 fold statements**, covering 62 compact opcode IDs and collapsing to **18
distinct semantic targets** (`push_i32`, `get_loc`, `put_loc`, `set_loc`,
`get_arg`, `put_arg`, `set_arg`, `get_var_ref`, `put_var_ref`, `set_var_ref`,
`call`, `push_const`, `fclosure`, `push_atom_value`, `get_field`, `if_false`,
`if_true`, `goto`). 13 further decisions exist only to support them
(implicit-operand and implicit-atom materialisation, the operand-less compact
formats, the u8/u16/u32 and i8/i16/i32 width arms, the label8/label16/label
displacement arms, and `CodeAtomCounts.semantic() = explicit + implicit`).

**How many are pure `.plain` encoding folds that would evaporate under
`.short`:** all 22 fold statements / all 35 source-level encoding decisions —
**65% of the source-decision count and 58% of the semantic-family count**. Under
`.short` both sides would select the same compact opcodes, the same implicit
operands and atoms, and the same displacement widths; the decoder arms would
still decode compact bytecode, but their cross-layout normalisation would be a
no-op. The 13 model-level normalisations and the 3 tolerances survive `.short`:
each reconciles a genuine model difference, not an encoding one.

None of the three tolerances papers over a known semantic divergence. One
coverage caveat stands: `FunctionBytecodeImpl.realm` is never compared.

### 4.4 C4 — semantic inventory, including the ownership term

Pipeline-only, rename-normalised, post-P3 and unchanged by the closure commits
(no new named type landed):

```
Legacy concepts removed: 37
V2 concepts added:       33
Net (pipeline only):     -4
```

**The ownership term is now a branch fact, not a projection.** When the P4
scorecard was written, main's ownership work was not on the branch; it is now
(`a78ba28d` merged `f6b68556`). `tools/architecture/check_borrowed_atoms.js`,
`tools/architecture/borrowed-atoms-allowlist.json` (**14 entries**),
`docs/borrowed_atom_audit.md` and `-Dzjs_ownership_audit` with the one-slot atom
quarantine are all present and active.

```
implicit ownership assumptions removed: 3
  - identifier-token atoms are immortal because the lexer leaks their retain
  - borrowed lookahead returns survive helper exit by LIFO slot-reuse luck
  - a member atom may be read after advance() released the token
explicit ownership concepts added:      8
  - the token-payload lifetime boundary
  - the *Owned return contract
  - lint rule A: borrowed-return
  - lint rule B: borrowed-state-store
  - lint rule C: borrowed-use-after-release
  - lint rule D: owned-escape-state-store
  - the allowlist-with-exit-milestone governance protocol
  - the -Dzjs_ownership_audit one-slot quarantine tier

C4 = -4 - 3 + 8 = +1 concept
```

| reading | net |
| --- | ---: |
| pipeline only | −4 |
| + ownership, lint rules A–D counted as **four** named contracts | **+1** |
| + ownership, lint rules A–D counted as **one** contract ("a borrowed atom must not escape its owner's lifetime", four detectors) | **−2** |

**The ownership term flips C4 positive on the reading the ruling's own phrase
"explicit ownership boundaries" implies.** That is the honest arithmetic:
making ownership explicit costs more named concepts than the implicit
assumptions it removes, because one implicit assumption is replaced by four
separately-named escape rules plus a governance protocol plus a runtime tier.
Both readings are stated; this document does not pick.

The 14 allowlist entries are known borrows **not yet removed**, so they earn no
"implicit assumption removed" credit.

### 4.5 STOP-D and STOP-E

**STOP-D — NOT TRIGGERED.** The v2 parser has exactly **one** jump-target
identity, `LabelId`. Legacy has at least twelve still in the tree (phase-1 PC,
phase-2 PC, phase-3 address, `JumpSlot.label` index, `ParserLabelRef`,
`RelocEntry` heap pointer, `JumpSlot`, `SparseRelocation`, the `pc_map`
old→new table, `Phase1CfgNode` index, `TopologyInstruction` index, the in-stream
`op.label` pseudo-op, pc2line PC).

Fan-out and chain depth re-measured on this tip
(`ZJS_V2_IDENTITY_HEALTH=1 zjs-dev mc.js`, 120 iterations, `CHECKSUM: 240/240`):

```
identity kinds=5 instances=367454
fan-out{mean=1.12 p95=2 max=7}
chain{mean=3.04 p95=4 max=4 +final-hop=298450}
final-source{events=2465345 on-identity=232564 between-identities=2232781}
unanchored{source=179883 fold=41406 contested=4082}
```

Identical to the P3 figures. The `5` there is the census taxonomy
(`{label, boundary, block, source_event, fold_region}`), a different quantity
from the STOP-D count of 1 versus ≥ 12.

**STOP-E — both readings, neither picked.**

| reading | numerator / denominator | ratio | verdict |
| --- | ---: | ---: | --- |
| **full**, published ruler | 4,165 / 9,212 | **45.2%** | inside the ~30–50% band — **PASS** |
| **conservative**, published ruler | 3,883 / 9,212 | **42.2%** | inside the band — PASS |
| **sensitivity**: `cfg.zig` audit-oracle lines reclassified as migration-only | 5,430 / 7,947 | **68.3%** | **STILL TRIGGERED** |
| the same sensitivity, conservative | 5,148 / 7,947 | 64.8% | still triggered |

The sensitivity moves 1,265 lines: of `cfg.zig`'s 2,488 pre-test code lines,
**1,376 are `audit_oracles`-gated** (Debug/ReleaseSafe only) and 111 of those are
already booked migration-only. The remaining 1,265 —
`auditBoundaryUniqueness` (586), `classifyAnchorSplits` (158), the fan-out and
anchor censuses, the report formatters — exist to prove the v2 identity model
agrees with **legacy** notions. Booking them as migration diagnostics rather than
v2 production is the reading under which the ratio measures *compiler* rather
than *instrumentation*. It previously read 68.8% and triggered; it reads 68.3%
here and still triggers. **Both readings are presented; this document does not
pick one.**

Why the passing reading is fragile, unchanged from P3 and re-verified here:
the migration-only numerator fell only 4.6% from the S6 tip (4,364 → 4,165), and
**about 86% of the ratio improvement is denominator growth**, most of it that
same Debug/ReleaseSafe-only oracle.

Migration-only inventory at this tip (4,165 lines):

| bucket | LOC |
| --- | ---: |
| `compiler_v2/compare.zig` — comparator core | 1,810 |
| `compiler_v2/tests.zig` — phase1→v2 translator + equivalence harness | 694 |
| `compiler_v2/compare.zig` — comparator self-tests | 361 |
| `compiler_v2/coverage.zig` — L3 emission gate | 276 |
| `parser.zig` — residual gate-arm scaffolding | 248 |
| `parser.zig` — P3 `Emitter` dispatch + `LegacyEmitter` | 235 |
| `compiler_v2/test_entry.zig` — dual test entry | 146 |
| `parser.zig` — dual dispatch in `compile()` | 143 |
| `compiler_v2/cfg.zig` — audit oracle | 111 |
| `compiler_v2/root.zig` — ledger plumbing | 107 |
| `parser.zig` — L3 coverage hooks | 32 |
| `parser.zig` — `v2_ledger` sites | 2 |

Parser dual-arm census at this tip: **62 dual-arm gate blocks and 30 v2-only
blocks** (94 gate openings seen in total; two are not classified by the census's
brace matcher), 118 lines containing `v2_available and `, `parser.zig` 21,845
raw / 18,122 code lines. P3's 414 → 62 collapse holds.

### 4.6 Architecture conditions

| condition | state |
| --- | --- |
| C2-A transient bytes < 0.7× | **MET** — 0.5702× |
| C2-A allocation-count axis < 0.7× | **NOT MET** — 1.60×; whether the bar binds on that axis is a ruling |
| C2-B artifact equality | **NOT MET by construction** — +6.8%, fully attributed to `.plain`, no ownership defect |
| C2-C "answer where the increase is" | **MET** — parse-end residency, overlap 0 |
| C3 no new comparator special cases | **MET** — zero added since S3R+R |
| STOP-D identity kinds | **MET** (not triggered) — 1 vs ≥ 12, fan-out and chain depth unmoved |
| STOP-E within ~30–50% | **PASS on the published ruler (45.2% / 42.2%); STILL TRIGGERED on the oracle-reclassified ruler (68.3% / 64.8%)** — needs a ruling on which denominator the stop condition means |
| C1 ≤ 1× | **NOT MET** — 1.564× (2.272× with migration code), and worse than the 1.11× it was at S6 |
| C4 net concepts ≤ 0 | **NOT MET on the four-rule reading (+1); MET on the collapsed reading (−2); MET pipeline-only (−4)** — needs a ruling on rule granularity |

---

## 5. MIGRATION EFFICIENCY — `performance_gain / net_concept_change`

Stated, with its inputs, and not argued.

**Inputs — numerator** (all versus the branch's own legacy mode, absolute change
in the qjs-normalized ratio):

| numerator | value |
| --- | ---: |
| code-load, as shipped | 0.4458 → 0.5575 = **+0.1117** (+25.1% relative) |
| whole-zoo throughput geomean, as shipped | 0.7029 → 0.5869 = **−0.1160** (−16.5% relative) |
| whole-zoo throughput geomean, with the deferred `.short` | 0.7029 → 0.7147 = **+0.0118** (+1.7% relative) |

**Inputs — denominator** (net concept change, §4.4):

| denominator | value |
| --- | ---: |
| pipeline only | −4 |
| + ownership, lint = four contracts | **+1** |
| + ownership, lint = one contract | −2 |

**The metric:**

| numerator ↓ / denominator → | −4 (pipeline only) | +1 (lint = 4) | −2 (lint = 1) |
| --- | ---: | ---: | ---: |
| code-load +0.1117 | −0.0279 | **+0.1117** | −0.0559 |
| whole-zoo, shipped −0.1160 | +0.0290 | **−0.1160** | +0.0580 |
| whole-zoo, with `.short` +0.0118 | −0.0030 | **+0.0118** | −0.0059 |

The metric's **sign is not stable** across its own admissible inputs: it is
positive, negative, or near-zero depending on which performance axis and which
concept-granularity reading is chosen. That is a property of the inputs, stated
here without a recommendation.

---

## 6. WHAT WOULD STILL HAVE TO HAPPEN AFTER A SWITCH

Plain list. None of this is scheduled by this document.

**Legacy deletion sequencing**

1. Switch the default backend; keep `dual` buildable so the comparator still has
   two compilers to compare.
2. Delete the legacy `else`-arm bodies under the 62 surviving dual-arm gates
   (309 LOC), then the gates themselves (248 LOC of scaffolding), then
   `LegacyEmitter` and the `Emitter` dispatch namespace (235 LOC) — `V2Emitter`
   (80 LOC) survives as the sole emitter.
3. Delete `parser.zig`'s legacy emission / parser-label / fixup machinery
   (186 LOC) and the dual dispatch in `compile()` (143 LOC).
4. Delete `bytecode.zig` `pipeline_resolve_labels` (1,916 LOC) and
   `pipeline_resolve_variables` (4,359 LOC) **minus** the curated
   `pipeline_resolve_variables.v2` reuse surface (881 LOC / 43 decls /
   48 exported symbols), which v2 still calls and which must be re-homed, not
   deleted.
5. Only then delete the comparator, because deleting it first removes the oracle
   that proves steps 2–4 were behaviour-preserving.

**Deletion-scheduled migration-only code** — 4,054 of the 4,165 migration-only
lines die the day legacy dies:

| dies with legacy | LOC |
| --- | ---: |
| comparator core + self-tests | 2,171 |
| phase1→v2 translator + equivalence harness | 694 |
| L3 coverage gate + parser hooks | 308 |
| P3 `Emitter` dispatch + `LegacyEmitter` | 235 |
| dual test entry | 146 |
| dual dispatch in `compile()` | 143 |
| ledger plumbing (`root.zig` + `parser.zig` sites) | 109 |
| residual gate scaffolding | 248 |

The one exception is `cfg.auditInstructionOwnership` (111 LOC), which audits the
v2 builder stream against the v2 block graph and never touches legacy — it
survives and should be reclassified as v2 production at that point.
`compare.zig` at 2,171 lines is 52% of the whole numerator and the single
largest component.

**Deferred items**

| item | measured size / price |
| --- | --- |
| ~~**`resolve_labels.default_layout = .short`**~~ **LANDED 2026-08-03** | removes the +31,640 B (+6.8%) artifact delta **and** the entire −16.5% whole-zoo execution deficit (§2.5), and would make 22 of the comparator's fold statements / 35 of its 54 source-level decisions no-ops (§4.3). ~~Currently frozen.~~ Now a real build option (`-Dzjs_v2_layout`, default `short`) and part of the release configuration (§0.1.6); `plain` survives as the A/B diagnostic instrument. **The +6.8% artifact-residency figure was measured under `.plain` and needs re-accounting under `.short` — follow-up, not a blocker.** |
| **lower-on-pop** (lower each function at the end of its body, so the emission census is O(depth) not O(tree)) | removes the whole per-`FunctionDef` producer census from the peak: 896,976 B / 2,819 allocations aggregate = 31.1% of v2's peak |
| **arena phase-ownership cleanup** (release the parser arena at parse end; compiler-neutral, proven to have no emit-phase reader by the poison test) | removes 488,548 B aggregate (16.9% of peak; 67.0% on the TS family); moves the aggregate peak ratio 1.0756× → 1.0249× |
| **per-`FunctionDef` footprint** (v2-only `Builder` object, label table, reloc array) | +228,248 B aggregate; the reloc array alone (58,752 B / 343 allocations) is provably dead the moment `resolve_variables.run` returns |
| **dead-code removal** | the 30 v2-only gate blocks lose their conditions; `v2_available` becomes a constant and every `v2F*` facade can be inlined into its single call site |

**Also outstanding, not perf and not deletion**

* `docs/compiler_v2_contract.md` is behind the code: 13 v2 invariants are
  verified in code and absent or materially incomplete in the normative
  contract, which still records tip `6d0c69dd`.
* 14 borrowed-atom allowlist entries are outstanding. The lint passes, but
  ownership is machine-*policed*, not machine-*proved*, until they reach zero.
* ~~`zig build test-altrepr` does not forward `-Dzjs_compiler`
  (`build.zig:948`), so the alternate-representation gate silently runs legacy
  whatever backend is requested.~~ **Closed:** the step now forwards the outer
  invocation's whole `-D` option set plus the resolved optimize mode (§3.2);
  `zig build test-altrepr -Dzjs_compiler=v2` reports 2267/1/0.
* C2-A's allocation-count axis (24 vs 15 live temporaries) is unresolved: the
  S3 `ResolvedProduct` carries four independent backings and the S4 resolver
  seven, where legacy mutates a moved-in buffer in place.

---

## 7. Reproduction

```bash
# four cold binaries, sha256 recorded per build
for m in legacy legacy v2 v2; do
  rm -rf .zig-cache zig-out
  flock -x /tmp/zjs-host-heavy.lock zig build zjs -Dzjs_compiler=$m
done

# code-load, 12 ABBA samples, any pairing
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
  python3 tools/perf/zoo/run_zoo_compare.py --zjs <A> --qjs <B> \
    --samples 12 --cpu 19 --benches code-load --output <json>

# full 15-benchmark zoo against pinned qjs
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
  python3 tools/perf/zoo/run_zoo_compare.py --zjs <bin> --qjs /home/aneryu/quickjs/qjs \
    --samples 4 --cpu 19 --output <json>

# score-normalized counters
taskset -c 19 perf stat -x, -e instructions,cycles \
  <bin> /home/aneryu/javascript-zoo/bench/code-load.js

# L3 emission coverage (Debug/ReleaseSafe only)
zig build zjs-dev -Dzjs_compiler=v2
ZJS_V2_EMISSION_COLLECT=1 ./zig-out/bin/zjs-dev mc.js

# STOP-D identity health
ZJS_V2_IDENTITY_HEALTH=1 ./zig-out/bin/zjs-dev mc.js
```

The `.short` attribution probe of §2.5 flips
`src/compiler_v2/resolve_labels.zig:21` to `.short`, cold-builds, copies the
binary out, and reverts the constant **before** measuring. The committed tree
says `.plain`.

> **AMENDED 2026-08-03.** That constant-flipping recipe is obsolete and must not
> be used again: it produces an INTERMEDIATE number by construction (§0.1.5).
> The layout is now a real build option and `short` is the default, so the
> reproduction is `-Dzjs_v2_layout=short` (or nothing) versus
> `-Dzjs_v2_layout=plain`, and both binaries state which one they are:
>
> ```bash
> zig build zjs                                   # default: v2 + short
> zig-out/bin/zjs --print-config-signature
> zig build zjs -Dzjs_v2_layout=plain             # the A/B diagnostic instrument
> zig-out/bin/zjs --print-config-signature
> zig build config-signature-check                # build graph vs shipped binary
> zig build config-drift-gate                     # can the attestation still fail?
> ```
>
> A signature printed by a `zjs` binary always reads `optimize=ReleaseFast`,
> because that artifact pins ReleaseFast regardless of `-Doptimize`; a Debug
> test artifact reads `optimize=Debug`. Two signatures that differ only in that
> field are two different artifacts of the same configuration, not a drift.

---

## 8. FINAL VERDICTS (2026-08-04)

QCP-1 closes here, as **two** verdicts rather than one. They were adjudicated
separately because they are separate questions, and the second one's answer
does not qualify the first one's. Reading §8.2 as a caveat on §8.1 is a
misreading of both.

| | question | verdict |
| --- | --- | --- |
| **QCP-1A** | make V2 the production compiler | **ACCEPT** |
| **QCP-1B** | physically remove the legacy pipelines from the tree | **NO-GO — deferred** |

**Production configuration, shipped:**

```
zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

Legacy is **retained as a fallback only**. `-Dzjs_compiler=legacy` still builds
and still passes its suite; it is not a supported production configuration and
must not be read as one. `-Dzjs_compiler=dual` is retained as the differential
oracle, and `-Dzjs_v2_layout=plain` as the A/B diagnostic instrument.

### 8.1 QCP-1A — V2 compiler migration: **ACCEPT**

**V2 + `.short` is the production default.** The goal was never "delete all the
old code"; it was **make V2 the production compiler**, and that is done.

The gate in force (§0.1.2) is three conditions, jointly. Gate A (`04922a47`)
adjudicated them on **true production defaults** — the actual shipping
configuration, not a scratch probe — with four cold binaries and four pairings
under ABBA sampling. Manifest and per-pairing values: `tools/final-switch/README.md`
§"Gate A manifest".

| gate | required | measured | state |
| --- | --- | ---: | --- |
| code-load vs corrected legacy | ≥ 1.2359× | **1.2517×** (1.2544 / 1.2488 / 1.2546 / 1.2490) | **MET** |
| full-zoo geomean vs corrected legacy | not regressed | **1.0164×** (1.0150 / 1.0189 / 1.0140 / 1.0178) | **MET** |
| per-benchmark floor | none below the 0.975 floor | recorded **MET** (the per-benchmark table is in the branch record, not in main — §8.3) | **MET** |
| candidate runtime noise floor (b1/b2) | — | geomean 1.0010, max per-bench deviation 2.18% | control |
| legacy build-layout lottery (a1/a2) | — | geomean 1.0038, max per-bench deviation 2.05% | control |

Correctness and architecture at the same defaults:

| item | state |
| --- | --- |
| test262 | `0/49775 errors, passed 44541, known 25` — identical to legacy's, and to the dual run at the divergence-closure tip |
| L3 legacy emission inside V2 scope | **0**, with `coverage.legacy_allowlist` literally `[_]AllowlistEntry{}` — the gate cannot be satisfied by an allowance |
| dual comparator | zero mismatch lines at any tier after `a9c13b0a`; the four-defect divergence closure is §3.1 |
| ownership | borrowed-atom lint (rules A–D) + `-Dzjs_ownership_audit` one-slot quarantine, both active; **14 allowlisted borrows outstanding** — machine-*policed*, not machine-*proved* |
| configuration attestation | every engine-bearing artifact asserts its own effective configuration at compile time; `config-drift-gate` proves the assertion can still fail (§0.1.4, §0.1.9) |

The honest debits are **not** withdrawn by the ACCEPT and are stated where they
were measured: C1 is 1.564× and worse than at S6 (§4.1); C4 is +1 concept on
the four-rule reading (§4.4); STOP-E passes on the published ruler and still
triggers on the oracle-reclassified one (§4.5); C2-A's allocation-count axis is
1.60× (§4.2). The verdict is that the migration is accepted **with** those
open, not that they closed.

### 8.2 QCP-1B — legacy physical removal: **NO-GO, deferred**

**This is not a correctness failure and it is not an architecture failure.**
The post-deletion tree was green on correctness — `0/49775 errors, passed
44541, known 25`, the full unit matrix, ReleaseSafe, altrepr, OOM, the
ownership-audit tier — and the deletion did exactly what it was designed to do
structurally. It is blocked on one thing only.

**Reason: a stable runtime benchmark regression appeared after deletion and its
mechanism was never identified.** Against the pre-deletion V2 tip `a9c13b0a`,
measured in one session, directly paired:

| quantity | value |
| --- | ---: |
| crypto | **−3.9%** |
| regexp | −2.8% |
| raytrace | −2.6% |
| code-load | **+1.6%** |
| zlib | +1.3% |
| **full-zoo geomean** | **−0.73%** |

Against the frozen legacy baselines the deletion tree still clears two of the
three switch gates and fails the third: full-zoo geomean worst pairing 1.0103,
code-load worst pairing 1.2683 (both **MET**), per-benchmark floor 0.975 with
crypto at **0.9628** and raytrace at **0.9739** (**NOT MET**). The deletion's
gains were concentrated in code-load while the runtime suite paid.

The regression is **stable**, not a build-layout draw: it reproduces across two
independent candidate builds that agree to 0.00% on the geomean, is consistent
to 0.34% across all four pairings, and is roughly three times the larger
measured noise floor. Its *signature* is a code-placement effect rather than
extra work — the deletion tip retires **1.7% fewer instructions per unit of
score** and still burns **2.2% more cycles per unit of score**, because IPC
falls **3.8%**. That names the shape of the cost, not its mechanism: every
specific placement mechanism proposed for it was tested and refuted (§8.4).

**Why deferral is the right shape, rather than blocking QCP-1A on it:**
retaining the legacy source does not impede the V2 default. Legacy is unreached
by the production path (L3 emission inside V2 scope is 0), and its presence
costs source lines and a build option, not runtime behaviour. The two goals
therefore **decouple**, and coupling them would have held a delivered,
measured, green compiler migration hostage to an unexplained −0.7% on a
deletion whose purpose was structural.

**Re-filed as a separate project: runtime layout stability.** Its question is
not "should legacy be deleted" — it is "why does removing unreached code from
this binary cost 3.9% on crypto". Legacy removal becomes a consequence of
answering that, not a prerequisite for it.

### 8.3 The QCP-1B diagnosis — archived by reference, deliberately not imported

The full layout-diagnosis corpus is **not** copied into main. That is a
decision, not an omission: it is a large body of measurement about one
unshipped tree, and importing it would put a diagnosis of a rejected change
into the record of an accepted one. What main carries is the **verdict, the
reason, and the coordinates**. In six months the question "why is there still
legacy?" has an answer in this file, and the evidence behind it is one
`git show` away.

Branch **`compiler-v2-qjs`** (not merged to main; none of these commits is an
ancestor of main):

| commit | what it is |
| --- | --- |
| `ff530a29` | `refactor(compiler): delete the legacy compiler production path` — **the commit that carries the cost**; the 2×2 factorial's D factor |
| `46362e0e` | `refactor(compiler): eradicate the legacy pipelines from the production binary` |
| `4a32ed74` | `docs(compiler_v2): Gate B2 record against corrected legacy and pre-delete V2` — the full Gate B/B2 dossier, from which §8.2's numbers are taken |
| `cd7ca4f5` | `docs(perf): crypto layout regression diagnosis` |
| `c0a033a0` | `docs(perf): hot-symbol identity classes and non-text geometry for the crypto step` — branch tip |

Diagnostic branches (each a single measurement record, none merged):

| branch | commit | record |
| --- | --- | --- |
| `diag/2x2-deletion-vs-behaviour` | `178ba556` | `docs/perf/DELETION-VS-BEHAVIOUR-2X2-2026-08-04.md` — the 2×2 factorial |
| `diag/native-mechanism-d` | `396c2a63` | `docs/perf/CRYPTO-DELETION-MECHANISM-2026-08-04.md` — line-straddling 16-byte loads |
| `diag/ldalign-locate` | `6c4ee0b2` | `docs/perf/CRYPTO-DELETION-ALLOCATION-SITE-2026-08-04.md` — the allocation site behind the mod-64 data shift |
| `diag/ldalign-control` | `2b28df92` | `docs/perf/CRYPTO-DELETION-ALIGNMENT-CONTROL-2026-08-04.md` — the 64-byte control, **rejected** |

`4e49c9f9` (branch `qcp1-v2-default`) is the same alignment-control record on a
second lineage. That branch name predates this ruling and is **not** the
release; the release is the annotated tag `qcp1-v2-default` on main. The two are
unrelated refs that unfortunately share a name.

### 8.4 What the diagnosis refuted and what it established

Stated as findings, because the value that survives QCP-1B is the eliminated
hypothesis space, not the unshipped deletion.

**REFUTED — each tested and each failed:**

* a simple `.text` layout shift;
* address-restoring padding;
* tail padding;
* heap padding;
* compile-time allocation padding;
* the dispatch-table page split;
* the `ld_align_lat` alignment mechanism **and** its 64-byte control — rejected
  on the mechanism condition, not on effect size: a within-cell test showed
  **44.5M** of its events cost approximately **zero**, so the mechanism could
  not be the carrier however well the correlation read;
* section isolation — **never entered**, and recorded as not-entered rather
  than as untested.

**ESTABLISHED:**

* the cost is **real**, and reproduces on independent layouts and on
  independent build lineages;
* it is carried by **`ff530a29` specifically**, not by the deletion programme
  in general;
* it is **NOT** the declared behavioural change. The 2×2 factorial separates
  them: `effect_H` = **−0.88%** against `effect_D` = **−3.41%**, and only D
  reproduces the backend-stall signature;
* the **executed program is unchanged to 6 parts in 100,000** — this is not
  different work;
* the allocation site and the causal chain are **named**.

**UNEXPLAINED — said plainly rather than left implied:** the residual
**+744M cycles** has no identified mechanism. Nothing above accounts for it.
The absence of an explanation is the finding, and it is the reason QCP-1B is
deferred rather than argued to a pass.

### 8.5 Process corrections carried forward

These outlast QCP-1 and bind future work regardless of subject.

1. **A single benchmark can never license a compiler, VM-dispatch or
   bytecode-layout default change.** Stated at the level of *blast radius*, not
   of benchmark: code-load was never wrong, it was blind to the axis the change
   moved, and no amount of extra sampling on it would have produced the missing
   information (§0.1.3).
2. **A gate must attest the configuration it actually ran.** Green about a
   configuration that was never executed is the defect class, and it is closed
   structurally by the configuration signature plus per-artifact compile-time
   attestation plus the negative drift gate — not instance by instance
   (§0.1.4, §0.1.9).
3. **Performance comparisons must be paired within a session.** Identical
   frozen bytes drifted **0.31%–0.56%** between sessions — the same size as the
   effects being judged. A number quoted across sessions is not a comparison.
4. **A disclosure about the measurement protocol is a statement about a tree,
   not a standing fact.** "Candidate builds are byte-identical, so there is no
   layout lottery to sample" was true at Gate A and **false** at the deletion
   tip, where two cold builds produced two distinct binaries. Protocol
   disclosures must be re-derived per tree and must be retracted by name when
   they stop holding.
5. **Zig codegen bistability is a global mode**, and it aliases with any
   cross-mode comparison. Any A/B that straddles it is measuring the mode.
6. **On a throughput fixture, raw cycles is the honest per-fixed-work
   quantity.** `cycles/score` is proportional to time *squared*, and
   `instructions/score` moves even when the instruction count is identical.
   Both normalized forms mislead on a fixture whose score is itself a rate.

### 8.6 Release verification

Gates at the release tree. The merge-stage rows were run at
`abe8746878517ea8438cfdf0f653310f9a209500`. The release commit touches
documentation plus one `build.zig` comment block and option-description string,
and **no engine source**.

That claim is checked rather than asserted: `zig build zjs` at the release
commit produces sha256
`ad757c33f84e0ce68eec8a5ca40a4d681bc50813dcd0733cfa6fbd2e23db86a1`, **byte-identical
to the binary the merge-stage rows below were measured on**, printing
`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`.
The merge-stage results therefore transfer to the release commit as
measurements of the same bytes, not by inference from "only docs changed".

| gate | result |
| --- | --- |
| `zig build zjs` (defaults) | PASS |
| `zig build config-signature-check` | PASS |
| `zig build config-drift-gate` | PASS |
| `zig build architecture-check` | PASS |
| `zig build smoke` | 3 passed, 0 failed |
| `zig build test` (defaults) | **2274 passed, 1 skipped, 0 failed** |
| `zig build test -Dzjs_ownership_audit=true` | **2275 passed, 0 skipped, 0 failed** |
| `zig build test262-gate` (defaults ⇒ v2) | **`0/49775 errors, passed 44541, known 25`** |
| full zoo vs pinned qjs, core 19, 4 ABBA samples | **throughput geomean 0.7123** (binary sha256 `ad757c33…`, affinity `{19}` verified) |

Re-run on the release tree itself, after the edits this commit makes:
`zig fmt --check build.zig src tools` PASS; `zig build zjs` PASS;
`zig build architecture-check` PASS (34 token-atom reads, 10 in value position,
26 borrowed locals, 14 escapes, 14/16 allowlisted; deps ok; OOM-panic ok; API
snapshot ok, 153 symbols); `zig build test` **2274 passed, 1 skipped, 0
failed**.

The zoo run above is a **standalone** measurement of the release tree against
pinned qjs. Set beside the frozen reference
`reports/perf/qjs-align/2026-08-04/dual-closure/zoo/zoo-c1-qjs.json` (candidate
C1 at `a9c13b0a`, geomean 0.7126) it reads −0.04% on the geomean, with 13 of 15
benchmarks inside ±1.7% and **regexp at −2.79%**. That comparison is
**cross-session** — 2026-08-03T16:16Z against 2026-08-04T14:23Z — so by process
correction 3 (§8.5) it is a sanity check and **not** a paired result, and
regexp's −2.79% is inside the range cross-session drift plus the suite's
noisiest benchmark can produce. It is reported rather than dropped; it is not
evidence of a regression, and it would not be evidence of parity either.
