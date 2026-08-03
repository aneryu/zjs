# QCP-1 switch decision packet

Branch `compiler-v2-qjs`, tip `a1eed054` (the switch-trampoline divergence
closure). Measurement and documentation only.

**This document does not recommend switching or not switching.** It states, for
each of the ruling's three groups, which conditions are MET, which are NOT MET,
and which need a ruling rather than another measurement. The decision is
reserved.

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

### 2.6 Performance conditions

| condition | state |
| --- | --- |
| code-load ≥ 0.58 vs pinned qjs, measured directly | **NOT MET** — 0.5575–0.5597 |
| v2 improves code-load over the branch's own legacy | **MET** — 0.4458 → 0.5575, +25.1% |
| v2 improves instructions and cycles per unit of code-load score | **MET** — insn/score 0.825×, cyc/score 0.799× |
| whole-suite throughput not worse than legacy | **NOT MET as shipped** — 0.5869 vs 0.7029, −16.5% geomean, 14/15 benchmarks regressed |
| whole-suite throughput not worse than legacy, with the deferred `.short` | MET in the probe — 0.7147 vs 0.7029, +1.7% |
| **needs a ruling** | whether the switch is assessed on the shipped `.plain` configuration or on a configuration that also lands `.short`. The two answers differ by 21.8% geomean and by nothing at all on code-load. |

---

## 3. CORRECTNESS ROLL-UP

Every gate below was **re-run at this tip**; none is carried forward.

| gate | command | result |
| --- | --- | --- |
| formatting | `zig fmt --check src build.zig` | PASS |
| build ×3 | `zig build zjs` with `legacy` / `v2` / `dual` | PASS / PASS / PASS |
| S3R+ oracles (legacy) | `zig build test-compiler-v2` | 50 passed, 147 expected skips, 0 failed |
| S3R+ oracles (v2) | `zig build test-compiler-v2 -Dzjs_compiler=v2` | **197 passed, 0 skipped, 0 failed** |
| S3R+ oracles (dual) | `zig build test-compiler-v2 -Dzjs_compiler=dual` | **197 passed, 0 skipped, 0 failed** |
| unified suite (legacy) | `zig build test` | 2119 passed, 149 skipped, 0 failed |
| unified suite (v2) | `zig build test -Dzjs_compiler=v2` | **2267 passed, 1 skipped, 0 failed** |
| unified suite (dual) | `zig build test -Dzjs_compiler=dual` | **2267 passed, 1 skipped, 0 failed** |
| OOM injection | `zig build test-oom -Dzjs_compiler=v2` | 21 passed, 0 failed |
| force-GC | `zig build test-core -Dzjs_compiler=v2 -Dzjs_force_gc=true` | 320 passed, 1 skipped, 0 failed |
| altrepr (v2) | `zig build test -Dzjs_compiler=v2 -Dzjs_nan_boxing=true` | **2267 passed, 1 skipped, 0 failed** |
| altrepr (dual) | `zig build test -Dzjs_compiler=dual -Dzjs_nan_boxing=true` | 2267 passed, 1 skipped, 0 failed |
| altrepr (legacy) | `zig build test-altrepr` | 2119 passed, 149 skipped, 0 failed |
| ownership audit (v2) | `zig build test -Dzjs_compiler=v2 -Dzjs_ownership_audit=true` | **2268 passed, 0 skipped, 0 failed** |
| ownership audit (legacy) | `zig build test -Dzjs_ownership_audit=true` | 2120 passed, 148 skipped, 0 failed |
| borrowed-atom lint + deps + OOM-panic + API | `zig build architecture-check` | PASS — "34 token-atom reads, 10 in value position, 26 borrowed locals tracked, **14 escapes found, 14/16 allowlisted**"; deps ok; OOM-panic ok; API snapshot ok (153 symbols) |
| test262 legacy | `zig build test262-gate` | **`0/49775 errors, passed 44541, known 25`** |
| test262 v2 | `zig build test262-gate -Dzjs_compiler=v2` | **`0/49775 errors, passed 44541, known 25`** |
| TS L2 probe — enum | `enum E{A,B}; console.log(E.A,E.B,E[0])` | legacy `0 1 A` / v2 `0 1 A` |
| TS L2 probe — namespace | `namespace N{export const x=41} console.log(N.x)` | legacy `41` / v2 `41` |
| dual corpus | `mc.js`, `ma.js` under v2 and under dual | 240/240 on all four runs; **0 `ZJS-DUAL-MISMATCH` lines** |
| L3 emission (v2) | `ZJS_V2_EMISSION_COLLECT=1 zjs-dev` on `mc.js` / `ma.js` | `v2_construct_emitted=4487085/4487162  legacy_construct_emitted=241  legacy_in_v2_scope=0  legacy_in_v2_unallowed=0  sites_dropped=0` |
| L3 allowlist | `src/compiler_v2/coverage.zig:25` | `pub const legacy_allowlist = [_]AllowlistEntry{};` — **empty**, and `LegacyConstruct` has only `none` |
| escape audit | `docs/v2_escape_audit.md` | 3 EXPLICIT / 2 IMPLICIT-BUT-SOUND / **0 UNCLEAR**; its three pinned tests run inside the suites above |

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
| test262 identical in both modes | **MET** — `0/49775 errors, passed 44541, known 25` in both |
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
| **`resolve_labels.default_layout = .short`** | removes the +31,640 B (+6.8%) artifact delta **and** the entire −16.5% whole-zoo execution deficit (§2.5), and would make 22 of the comparator's fold statements / 35 of its 54 source-level decisions no-ops (§4.3). Currently frozen. |
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
* `zig build test-altrepr` does not forward `-Dzjs_compiler` (`build.zig:948`),
  so the alternate-representation gate silently runs legacy whatever backend is
  requested. Either forward the option or document the explicit
  `zig build test -Dzjs_compiler=<mode> -Dzjs_nan_boxing=true` form as the gate.
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
