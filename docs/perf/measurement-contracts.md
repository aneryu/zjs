# Measurement Fields And Contracts

Status: **current**. Owner ruling 2026-09-01. This file defines the local
20-CPU ARM measurement host's field topology and admissible concurrency. The
cross-platform correctness gates remain governed by
[`docs/verification-policy.md`](../verification-policy.md).

The retired 16-clause incident register remains recoverable from git at
`90eb9385^:reports/perf/qjs-align/measurement-contracts.md`. Its general rules
(even ABBA samples, effective-affinity proof, explicit PMU, immutable binary
identity, complete output, and no post-hoc threshold changes) still apply.

## 1. Fixed topology and canonical launcher

The host has two 12 MiB L3 domains. CPUs 0-4 and 10-14 are Cortex-A725 small
cores; CPUs 5-9 and 15-19 are Cortex-X925 big cores.

| field | L3 domain | single layer | topology-real layer | lock |
|---|---|---:|---:|---|
| A | CPUs 0-9 | CPU9 | CPUs 5-8 | `/tmp/zjs-field-a.lock` |
| B | CPUs 10-19 | CPU19 | CPUs 15-18 | `/tmp/zjs-field-b.lock` |
| host | both domains quiet | CPU19 | CPUs 15-18 by default | `/tmp/zjs-host-heavy.lock` |

`tools/perf/measure_fields.py` is the single executable registry. Field B is
the compatibility default; select another field with `--field a|b|host` or
`ZJS_MEASURE_FIELD`. The canonical form is:

```sh
python3 tools/perf/measure_fields.py run --field b --layer single -- COMMAND
```

The launcher pins the command and exports the resolved field, CPU set and lock
identity plus inherited lock descriptors; runners verify those descriptors
before setting `lockAttested=true` or reusing a nested lock. Field A/B jobs
take their field lock exclusively and a **shared**
`/tmp/zjs-host-heavy.lock` token. A host job takes the host token exclusively.
This makes a legacy host window exclude both canonical fields during migration;
using only `flock /tmp/zjs-field-*.lock` is not contract-conforming.

An explicit legacy `--cpu` remains runnable for old scripts, but an artifact
whose `measurementField.fieldConforming` or `lockAttested` is false is
diagnostic-only. `gate_smoke.sh` is a correctness runner: its explicit CPU or
`ZJS_GATE_PARALLEL_CPUS` still overrides the field default and carries no
performance verdict.

## 2. Two layers and metric authority

The **single layer** keeps the old same-core A/B rule. Candidate and baseline
must use the same field and same canonical CPU, with even paired ABBA legs.
Absolute readings from different fields are calibration data, not candidate
ratios.

The **topology-real layer** gives one runtime four big cores in one L3 domain:
A uses 5-8 and B uses 15-18. It exists for parallel-runtime mechanisms and S4
adjudication; GC measurements must retain `--gc-stats` proof of the actual
worker count. A single-core result cannot price parallel marking, because its
affinity creates zero helpers.

The whole-host lock remains the strongest quiet-window layer. It is required
for published absolute snapshots, cross-field calibration, or any run that
intentionally consumes both fields. Parallel absolute scores are not comparable
to serial absolute scores; cluster-swapped simultaneous A/B remains ratio-only.

### 2.1 Dual-resolution ruling

Measurement authority has two precision classes:

- **coarse exploration/screening** may run `instructions@B` concurrently with
  either `cycles@A` or compilation. Every result, table and conclusion from
  such a window must say **`resolution >= 0.5% (coarse/concurrent)`**. An
  effect smaller than 0.5% is unresolved, and the run may only rank candidates
  or decide what deserves a quiet rerun;
- **fine/verdict** measurements remain serialized in a quiet field or host
  window and retain the 0.1% instruction regime. Any pre-registered pass/fail
  line is a verdict, regardless of its numeric threshold, so a concurrent
  result can never satisfy or fail it.

The 0.5% floor rounds the largest observed interference of the screening
currency upward: Splay `instructions@B` moved `+0.475%` under
`cycles@A`. It is not a claim that concurrent cycles have 0.5% accuracy:
cycles collected in that overlap remain attribution diagnostics and require a
serialized rerun before any decision. Lock separation proves scheduling
ownership, not fine-resolution authority.

## 3. Build pool and concurrency matrix

The default build pool is the big cores of both domains, `5-8,15-18`
(`ZJS_BUILD_CPUS` overrides it; 2026-09-06, previously `0-4,10-14`). Every
compile is one single-threaded LLVM job, and on the A725 pool each ran ~2x
slower than on the X925 cores (ReleaseFast zjs 111 s -> 57 s, unified test
45 s -> 23 s) for a concurrency permission that §4 only ever granted at
coarse resolution. The small-core pool `0-4,10-14` remains the
**overlap-safe** pool: the rows below were calibrated on it and only on it,
so a build that must coexist with an instruction-count screen sets
`ZJS_BUILD_CPUS=0-4,10-14` explicitly (the build graph's Run steps -- test
shards, test262, the fixed-work smoke -- follow `ZJS_BUILD_CPUS` when it is
set; otherwise they spread over `0-8,10-18`, never 9 or 19; see
`docs/testing-graph.md` "Run pool vs compile pool"). Stage 0's warm build
holds the host token exclusively, so it uses the default pool too
(2026-09-06; it had been on `0-4,10-14`). Each pool half shares an L3 with its
field, so a cycles job may coexist only with compilation confined to the
**opposite** domain: cycles@A forbids CPUs 0-4 (and 5-8), cycles@B forbids
CPUs 10-14 (and 15-18). A host window forbids all compilation. Because §4 did not admit either tested compile
overlap for fine or verdict work, checked-in mise build tasks currently take
the host token exclusively. §2.1's coarse permission does not change that
default; relaxing a verdict-bearing build workflow requires a new passing
calibration, not only a CPU-list edit.

| concurrent work | coarse exploration/screen | pre-registered verdict | authority / condition |
|---|---|---|---|
| instructions@B + compile on 0-4,10-14 | **yes, >=0.5%** | **no** | §4 measured `+0.369%` Splay and `-0.163%` EB, both outside the `|0.1%|` fine line |
| instructions@B + cycles@A | **yes, >=0.5%** | **no** | §4 failed at least one fine line on each workload; concurrent cycles are diagnostic |
| cycles + compile in the same L3 domain | no | no | invalid cycles; rerun |
| cycles@A + cycles@B | diagnostic only | no | not a verdict protocol |
| split-core cycles inside host-exclusive window | ratio-only | ratio-only | the registered schedule must swap fields |
| two jobs in one field | no | no | field-exclusive lock serialises them |

Wall-clock collected while any admitted concurrent work is active is
diagnostic-only. Instructions are the screen currency, subject to §2.1's
explicit precision label; cycles(u+k) is the single-field or host-window
verdict currency. Footprint-sensitive changes also retain minflt/MaxRSS under
the verification policy.

## 4. 2026-09-01 field calibration

The calibration froze `main@d4bad0b4` as a 29,072,320-byte ReleaseFast
binary with SHA-256
`7ea84dc4bbc718b7c34bd90969a4f75157a77773064f9064d174de6a3ee8fcbd`.
All rows are medians of four paired, order-balanced ratios; `delta` and MAD are
percentage points around ratio 1.0. The fixed-work hashes and every raw leg are
indexed by `.scratch/REPORT_FIELDS.md` in the owning worktree.

During the transition, driver explicitly ruled the acquired host/field locks
to be the arbitration authority and told this lane not to wait for slice2
processes. The process monitor nevertheless recorded slice2 Zig activity in
the equivalence and interference windows; topology-real was clear. These rows
are sufficient to **withhold** concurrency or cross-field equivalence, but do
not prove that the observed offsets are intrinsic hardware differences. A
future clean recalibration may relax the contract; the present data cannot.

### 4.1 Single-field equivalence (B / A)

| workload | instructions delta | instructions MAD | cycles delta | cycles MAD |
|---|---:|---:|---:|---:|
| Splay | +0.799% | 0.270% | -3.305% | 0.147% |
| EarleyBoyer | -0.009% | 0.057% | -1.506% | 0.024% |

The suggested instruction-equivalence line was `|delta| <= 0.1%`. Splay
fails it, and cycles show an offset on both workloads. Therefore this
calibration did not establish equivalence: absolute readings from CPU9 and
CPU19 are **not interchangeable**. Candidate and baseline must stay in one
field; changing field is a new experiment, not another leg of an existing
verdict.

### 4.2 Admitted-concurrency candidates (concurrent / solo)

| overlap | workload | protected metric delta | MAD | preregistered line | result |
|---|---|---:|---:|---:|---|
| cycles@A with instructions@B | Splay cycles@A | -0.141% | 2.432% | `|delta| <= 0.5%` | fail: dispersion |
| cycles@A with instructions@B | Splay instructions@B | +0.475% | 0.045% | `|delta| <= 0.1%` | fail |
| cycles@A with instructions@B | EarleyBoyer cycles@A | -0.752% | 0.525% | `|delta| <= 0.5%` | fail |
| cycles@A with instructions@B | EarleyBoyer instructions@B | +0.007% | 0.082% | `|delta| <= 0.1%` | pass |
| instructions@B with small-core compile | Splay instructions@B | +0.369% | 0.350% | `|delta| <= 0.1%` | fail |
| instructions@B with small-core compile | EarleyBoyer instructions@B | -0.163% | 0.101% | `|delta| <= 0.1%` | fail |

No proposed overlap passed on both fixed workloads; every `fail` in the table
remains a fail. The later owner ruling in §2.1 grants only a separate coarse
exploration/screening class at explicit `resolution >= 0.5%`; it does not
reinterpret this calibration or grant concurrent verdict authority.
Instructions and cycles therefore remain serialized against compilation and
against one another for fine screens and verdicts. A later fine-resolution
relaxation requires a new preregistered calibration.

The common assumption that retired instructions resist contention is valid
only for workloads whose executed work has no GC time feedback. Splay is the
counterexample: its protected instructions moved `+0.475%` (`+0.47%` at two
decimal places). `incrementalMarkStep` samples `profile.nowNanos()` every 64
objects against `incremental_mark_budget_ns`, while runtime polls and
allocation-debt assists schedule later mark and destruction slices. Contention
can therefore change how much collector work fits in each time-bounded slice
and how many collector paths execute during the same fixed JavaScript work.
That mechanism makes Splay instructions a coarse signal in a concurrent
window, not a 0.1%-resolution invariant. Workloads without such feedback must
still prove that boundary; the contract does not infer it from the PMU event
name.

### 4.3 Topology-real first price (15-18 / CPU19)

| workload | cycles delta | cycles MAD | wall delta | wall MAD | helper proof |
|---|---:|---:|---:|---:|---|
| Splay | +14.644% | 0.641% | +15.175% | 0.163% | workers 3, slices 80; owner 2,141,873 / helpers 5,384,504 successful claims |
| EarleyBoyer | +7.209% | 0.647% | +7.371% | 0.708% | workers 3, slices 345; owner 6,788,069 / helpers 1,995,906 successful claims |

This is positive proof that three helpers ran and negative pricing for the
current mechanism: four-core affinity costs cycles and wall time on both
loads. The topology-real layer may adjudicate a parallel-mechanism candidate
only against a same-topology frozen baseline. It is never pooled with the
single layer and the table is not evidence of a single-layer regression.

The S4 named ledger entry is
**`S4-PMARK-TOPOLOGY-NEGATIVE-20260901`**: current parallel marking has a net
cycles cost of `+14.644%` on Splay and `+7.209%` on EarleyBoyer despite three
helpers executing. The owning evidence is
`infra/measure-fields-20260901:.scratch/REPORT_FIELDS.md` §5, SHA-256
`9cb51410197c37344cac9d00bbc3a8c0ea35d3d8d9b6070232b20507efbbd7bf`.
Future S4 work must cite this name and compare against a frozen same-topology
baseline; helper activity alone is not a performance win.

Thresholds and concurrency permissions in this section must be copied from the
raw paired data, not selected from the suggested `0.1%` instruction / `0.5%`
cycles lines after seeing a preferred outcome.

## 5. Reproducibility and invalidation

Every artifact records commit, frozen-binary hash, workload hashes, field,
effective affinity, lock attestation, PMU events, realised order, all legs,
median and MAD. Keep failed or contaminated legs named as invalid; do not delete
them or silently replace them.

This topology contract is host-specific. A different CPU/L3 topology must add
its own checked registry and same three calibrations before reusing the field
names. Any change to kernel, firmware, governor, PMU, core assignment, compiler
pool, fixed-work inputs, or runner scheduling invalidates cross-field absolute
equivalence and interference thresholds until recalibrated.
