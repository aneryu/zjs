# C2 scorecard — three dimensions, with a per-syntax-family breakdown

Companion to `docs/v2_builder_lifetime.md`. That document derives the C2
decomposition on one source (`mc1.js`); this one states the verdict for each of
the three dimensions and then re-measures all three **per syntax family**, so
the aggregate cannot hide a family that retains differently.

The single "peak scratch < 0.7x" bar is retired. C2 is three separate
questions:

| | question | bar |
| --- | --- | --- |
| **C2-A** | transient lowering memory — peak temporary bytes/allocations attributable to the lowering passes | hard, **< 0.7x** |
| **C2-B** | artifact residency — what the compile leaves behind | report the delta, **not bar-gated** |
| **C2-C** | peak live set, decomposed as transient + artifact + overlap | must **answer where the increase is** |

---

## 0. How this was measured

Diagnostic accounting (`allocated_bytes`, `*_peak`, `alloc_calls`, …) is
comptime-gated on `builtin.is_test or builtin.mode == .Debug`
(`src/core/memory.zig:5`), so every number here comes from a **Debug** build.
Two binaries from this worktree at branch tip `17012ebd`:

```
zig build zjs-dev -Dzjs_compiler=v2
zig build zjs-dev -Dzjs_compiler=legacy
```

The `ZJS_C2D=1` scratch probe of `docs/v2_builder_lifetime.md` §10.1 was
re-applied (per-item producer census at `createFunctionBytecode` entry,
artifact census at its exit, parser-arena block/phase instrumentation,
arena-pointer audit, and `M <tag>` phase markers in the `-T` allocation
trace), with **one addition**: the same probe points were also placed on
`createModuleFunctionBytecode` (`src/bytecode.zig`), which module roots take
instead of `createFunctionBytecode` — without it the module family reports zero
compiles. The probe is scratch-only and is **not** part of this commit.

Probe neutrality was re-verified per family: `--perf-json` memory counters are
byte-identical with and without `ZJS_C2D=1`, on both pipelines, for all four
measurable families.

### Sources

| family | source | FunctionDefs | compiles |
| --- | --- | ---: | ---: |
| JS core | `fam-jscore.js` — closures, loops, `switch`, `try/catch/finally`, object/array literals, accessors, destructuring + rest/spread, template literals, arrows, generators, `async` | 781 | 1 |
| class | `fam-class.js` — base + derived classes, `super`, ctors, accessors, static fields/methods/getters, private fields **and** private methods, instance fields, computed keys, generator + async methods | 670 | 1 |
| TS extension | `fam-ts.ts` — annotations, `interface`, `type` aliases, generics with constraints, optional/default/rest params, `as`, `??`, parameter properties, `implements`, `readonly`, `private`/`protected`, index signatures, overload signatures | 601 | 1 |
| TS enum/namespace | `fam-ts-decl.ts` — `enum`, `const enum`, `namespace` only | 61 | 1 (**legacy only**, see §3) |
| module | `fam-module.mjs` + `fam-mod-dep.mjs` — `import` default/named/namespace, `export` decl/const/class/default, `export … from`, `export *` | 313 | 2 |
| aggregate | `mc1.js` — the vendored Octane `code-load` payload (Closure `base.js` + jQuery 1.7.2) | 596 | 3 |

Every family figure below was produced by the same scripts that reproduce the
aggregate row, and the aggregate row reproduces `docs/v2_builder_lifetime.md`
§11–§13 exactly (peak 2,683,991 / 2,886,830; parse-end 2,660,488 / 2,882,631;
producer 819,408 → 896,976; arena 344,060 → 488,548; transient 208,605 /
118,954 at 15 / 24 allocations). That identity is the calibration for the
family rows.

---

## 1. The three-dimension verdict

### C2-A — transient lowering memory · **PASS on bytes, FAIL on allocations**

Attributed figure: replay the `-T` allocation trace and, for each per-function
lowering window (`createFunctionBytecodeAfterChildren` entry → exit), track the
live bytes and live allocation count of allocations *born inside that window*.
Windows were verified **non-overlapping** (post-order lowering; maximum nesting
depth 1 on every source measured), so the flat classification is exact.

| | legacy | v2 | ratio | bar | verdict |
| --- | ---: | ---: | ---: | --- | --- |
| peak in-window transient bytes | 208,605 | **118,954** | **0.5702x** | < 0.7x | **PASS** |
| the same, survivors excluded | 191,745 | **100,653** | **0.5249x** | < 0.7x | **PASS** |
| peak in-window transient live allocations | 15 | **24** | **1.6000x** | < 0.7x | **FAIL** |

The allocation-count failure is structural and small in absolute terms: the S3
`ResolvedProduct` carries four independent backings and the S4 resolver seven,
where legacy mutates a moved-in buffer in place. It is *nine extra live
temporary allocations at one instant for one function* — it is not a residency
or a peak term (§C2-C attributes the whole-run `allocation_count_peak` gap to
the parse-end set, 2,819 producer allocations against 1,597, not to these nine).

### C2-B — artifact residency · `legacy artifact == v2 artifact` is **FALSE**

Measured at the artifact's birth (`createFunctionBytecode` exit, walking the
published FB tree through the cpool), because `allocated_bytes` at process exit
is **not** the artifact: only 864 allocations are live at exit while the jQuery
artifact alone is 1,604, so that counter measures runtime bootstrap residue.

| group | legacy | v2 | delta | allocations |
| --- | ---: | ---: | ---: | --- |
| **(i) FunctionBytecode** — code bytes | 62,433 | **94,072** | **+31,639 (+50.7%)** | 596 → 596 |
| (i) — header / DebugInfo / cpool / vardefs / closure rows / hot ext | 130,328 | 130,328 | 0 | — |
| **(ii) persistent tables** — labels | 0 | 0 | 0 | — |
| (ii) — boundaries | 0 | 0 | 0 | — |
| (ii) — source events (pc2line) | 44,108 | 44,109 | **+1** | 596 → 596 |
| (ii) — runtime metadata (source copies) | 230,608 | 230,608 | 0 | 593 → 593 |
| **(iii) ownership retained** — atom refs (names) | 4,605 | 4,605 | 0 | — |
| (iii) — atom refs (code operands) | 5,520 | 5,798 | **+278** | — |
| (iii) — closures / modules / cpool values | 1,257 / 0 / 834 | 1,257 / 0 / 834 | 0 | — |
| **artifact total** | **467,477** | **499,117** | **+31,640 (1.0677x)** | 1,785 → 1,785 |

**The difference is entirely group (i) code bytes.** Root cause named and
located: `resolve_labels.default_layout = .plain`
(`src/compiler_v2/resolve_labels.zig:21`) — the short-form relaxation pass
(`LayoutMode.short`) exists and is exercised by unit tests but is not the
production default, so v2 publishes long-form code. The +278 atom refs and the
+1 B of pc2line are *derived from* that: the extra refs are exactly the
atom-operand opcodes inside the extra code, and the extra pc2line byte is one
longer varint caused by the larger pc deltas.

Nothing was smuggled: allocation counts match group by group, labels and
boundaries are 0 on both (no v2-only persistent table), and **0 of the 1,785
pointers reachable from the published FB tree fall inside a parser-arena
block**, on both pipelines.

(Scope note: this table is all three `mc1.js` compiles. `docs/v2_builder_lifetime.md`
§11.2 reports the jQuery compile alone — 441,541 → 471,760, +30,219, code
59,056 → 89,274. Same measurement, narrower scope.)

### C2-C — peak live set · the increase is **parse-end residency, not lowering**

At the peak instant (parse end, on both pipelines) the three terms the ruling
expected to trade off are two-thirds zero:

| term at the peak instant | legacy | v2 | delta |
| --- | ---: | ---: | ---: |
| lowering transient (no pass has run yet) | 0 | 0 | 0 |
| artifact (nothing published yet) | 0 | 0 | 0 |
| transient/artifact overlap | 0 | 0 | 0 |
| per-`FunctionDef` producer footprint | 819,408 | 896,976 | **+77,568** |
| parser arena | 344,060 | 488,548 | **+144,488** |
| shared parse-resident state (identical on both) | 1,497,020 | 1,497,107 | +87 |
| **parse-end live** | **2,660,488** | **2,882,631** | **+222,143** |
| lowering headroom above parse end | +23,503 | +4,199 | −19,304 |
| **whole-run peak** | **2,683,991** | **2,886,830** | **+202,839 (1.0756x)** |

**Where the increase is**, in one line: 34.9% is the per-`FunctionDef` producer
footprint (v2 carries a 168 B `Builder` + a label table + a reloc array that
legacy does not; +228,248 B of v2-only items against −150,680 B of *smaller*
shared items), 65.0% is parser-arena allocation geometry (a 4.3% increase in
requested bytes crossed exactly one rung of `ArenaAllocator`'s 1.5x ladder and
became a 42.0% increase in resident bytes), 0.04% is unattributed. There is no
remaining transient/artifact overlap term at the peak.

The arena is retained across a **phase-ownership boundary error present in both
pipelines**: it is at high-water during parse, finalize requests 0 bytes from
it, no pointer reachable from the finalize input lands in it, and the poison
test (overwrite every arena byte with `0xDD` at parse end) lets finalize run to
completion and produce a byte-identical artifact census on both pipelines. Its
only post-parse reader is the parser `State`'s own destructor
(`ParseState.deinit` → `deinitDeclarationConflictIndices` →
`HashMapUnmanaged.deinit`, `src/parser.zig:4272`, `:3578`).

---

## 2. Per-family breakdown

### 2.1 C2-A per family — transient lowering memory

| family | legacy B | v2 B | **ratio** | survivors-excluded ratio | legacy allocs | v2 allocs | alloc ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| JS core | 541,641 | 292,215 | **0.5395x** | 0.4966x | 10 | 18 | 1.8000x |
| class | 506,068 | 253,555 | **0.5010x** | 0.4573x | 11 | 19 | 1.7273x |
| TS extension | 350,793 | 213,101 | **0.6075x** | 0.5627x | 11 | 19 | 1.7273x |
| module | 189,897 | 102,463 | **0.5396x** | 0.4865x | 11 | 19 | 1.7273x |
| TS enum/namespace | 413,987 | *unmeasurable* | — | — | 10 | — | — |
| **aggregate** | **208,605** | **118,954** | **0.5702x** | 0.5249x | **15** | **24** | **1.6000x** |

**Every measurable family passes the < 0.7x bytes bar, and every family fails
the allocation bar in the same way.** The spread on bytes is 0.50x–0.61x
against an aggregate of 0.57x — the aggregate is representative, not an
average that hides an outlier. TS extension is the closest to the bar (0.6075x)
and is the only family where the margin is under 0.1.

Cross-check against the v2 *named* transient census (S3/S4 structures by name,
which has no legacy counterpart and so cannot produce a ratio): peak
`S4 scratch + ResolvedProduct` is 239,616 B (JS core), 165,888 (class), 135,168
(TS), 55,552 (module), 76,196 (aggregate) — same ordering, same magnitude as
the classification, and the aggregate value reproduces
`docs/v2_builder_lifetime.md` §13.1 exactly.

### 2.2 C2-B per family — artifact residency

| family | FBs | group (i) code lg → v2 | **code delta** | group (ii) delta | group (iii) atom-ref delta | artifact total ratio | artifact allocations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| JS core | 781 | 38,252 → 63,824 | **+25,572 (+66.9%)** | 0 | +240 | 1.0934x | 781 → 781 (identical) |
| class | 670 | 29,118 → 39,744 | **+10,626 (+36.5%)** | +21 | 0 | 1.0472x | 670 → 670 (identical) |
| TS extension | 601 | 24,582 → 34,596 | **+10,014 (+40.7%)** | 0 | +180 | 1.0458x | 601 → 601 (identical) |
| module | 313 | 10,959 → 15,247 | **+4,288 (+39.1%)** | 0 | 0 | 1.0458x | 313 → 313 (identical) |
| TS enum/namespace | 61 | 11,411 → *unmeasurable* | — | — | — | — | — |
| **aggregate** | **596** | **62,433 → 94,072** | **+31,639 (+50.7%)** | **+1** | **+278** | **1.0677x** | **596 → 596 (identical)** |

Uniform across families, with no exceptions:

* **the only group that grows is (i), and inside it only code bytes** — every
  other group (i) item (FB header, `DebugInfo`, cpool storage, vardefs,
  closure rows, hot extension) is byte-identical in all five families;
* **labels = 0 and boundaries = 0 on both pipelines in every family** — v2
  publishes no persistent table of its own anywhere;
* **artifact allocation counts are identical family by family** — 781/670/601/
  313/596 FAM allocations, and the same equality on pc2line buffers and source
  copies. A smuggled temporary would be an extra owner and there is none;
* **arena-backed artifact pointers are 0 in every family, on both pipelines**
  (2,342 / 1,887 / 1,742 / 937 / 1,785 pointers audited).

The `+21 B` in group (ii) on the class family and the `+1 B` on the aggregate
are pc2line varints that got one byte longer because the pc deltas they encode
got larger — a consequence of group (i), not an independent term. The
group (iii) atom-ref delta is not proportional to the code delta: class and
module show **zero** extra atom refs despite +10,626 B and +4,288 B of extra
code, because the long-form opcodes they gain (jumps) carry no atom operand.

**Independent confirmation from a counter the probe does not touch.** For the
module family the whole artifact stays reachable at process exit, so
`allocated_bytes` at exit is an unbiased second measurement of artifact
residency: 890,968 (legacy) → 895,264 (v2) = **+4,296**, against an artifact
census delta of +4,288 plus the 8 B root legacy `byte_code` stub v2 still
allocates. Exact to the byte. On families where only part of the artifact stays
reachable the end-resident delta is correspondingly smaller (JS core +19,061 of
+25,572; class +7,187 of +10,647; TS +6,436 of +10,014), and on the aggregate,
where the artifact is dropped, it is **0 of +31,640** — which is exactly why
end-of-run resident bytes could never have been evidence about artifact
equality.

### 2.3 C2-C per family — peak live set

Parse-end terms are for the family's dominant compile; `peak` is the whole run.

| family | peak lg | peak v2 | **peak ratio** | parse-end lg | parse-end v2 | parse-end delta | = producer | + arena | + residual | headroom lg | headroom v2 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| JS core | 2,430,931 | 2,249,232 | **0.9253x** | 2,088,424 | 2,241,310 | +152,886 | +138,512 | +14,374 | **0** | 342,507 | 7,922 |
| class | 1,844,900 | 1,493,917 | **0.8098x** | 1,314,148 | 1,416,380 | +102,232 | +95,500 | +6,732 | **0** | 530,752 | 77,537 |
| TS extension | 3,905,499 | 3,713,470 | **0.9508x** | 3,582,894 | 3,707,326 | +124,432 | +124,432 | **0** | **0** | 322,605 | 6,144 |
| module | 904,137 | 908,433 | **1.0048x** | 603,911 | 654,859 | +50,948 | +50,576 | +372 | **0** | 300,226 | 253,574 |
| TS enum/ns | 1,221,728 | *unmeasurable* | — | 804,993 | — | — | — | — | — | 416,735 | — |
| **aggregate** | **2,683,991** | **2,886,830** | **1.0756x** | **2,660,488** | **2,882,631** | **+222,143** | **+77,568** | **+144,488** | **+87** | **23,503** | **4,199** |

The parse-end decomposition is **exact (residual 0)** on all four measurable
families; the aggregate's +87 B residual is one constant-size allocation and is
the largest residual anywhere.

Three per-family observations that the aggregate does hide, all of them
favourable or neutral to v2 and none of them a retention finding:

1. **On three of four families v2's whole-run peak is BELOW legacy's** — 0.93x
   (JS core), 0.81x (class), 0.95x (TS). The mechanism is visible in the
   headroom columns: these sources are single scripts with one very large root
   function, legacy's own per-window lowering transient is roughly 2x v2's
   (§2.1), and legacy's peak therefore sits 322–531 KB *above* its parse-end
   set while v2's sits 6–78 KB above. v2's larger parse-end set is more than
   repaid by its smaller lowering transient. **The aggregate's 1.0756x is the
   worst of the five sources measured, not the typical one.**
2. **The arena term is a step function and it does not fire per family.** Its
   delta is +0 (TS — the two ladders are byte-identical, 8 nodes / 2,487,750 B),
   +372 (module), +6,732 (class), +14,374 (JS core), against +144,488 on the
   aggregate. The aggregate's term is one extra rung of the 1.5x ladder on the
   jQuery parse, and **no family reproduces it**. The ladder shape is not even
   monotone in demand: on JS core v2 takes 11 arena nodes to legacy's 7 yet
   ends only +14,374 B resident, because legacy makes one 8,176 B request early
   (v2's largest is 160 B) that lifts its whole ladder.
3. **The TS family's peak is 67% parser arena** (2,487,750 of 3,713,470)
   against 17% on the aggregate, and that arena is *byte-identical between
   pipelines* — it is the type-erasure scratch, with a single 655,128 B request
   on both. For the TS family the entire parse-end gap is producer footprint
   and the compiler-independent term dominates the peak.

Normalised, so families of different sizes compare:

| family | producer B/FunctionDef lg → v2 | delta | producer allocs/fd lg → v2 | artifact code B/FB lg → v2 | arena % of peak (v2) | parse-end % of peak (v2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| JS core | 773.4 → 950.8 | +177.4 | 3.00 → 4.62 | 49.0 → 81.7 | 21.7% | 99.6% |
| class | 496.5 → 639.1 | +142.5 | 2.91 → 4.46 | 43.5 → 59.3 | 13.2% | 94.8% |
| TS extension | 474.6 → 681.6 | **+207.0** | 3.00 → 5.00 | 40.9 → 57.6 | **67.0%** | 99.8% |
| module | 404.8 → 572.9 | +168.0 | 3.00 → 4.40 | 35.0 → 48.7 | 6.0% | **72.1%** |
| aggregate | 1,531.6 → 1,676.6 | +145.0 | 2.99 → 5.27 | 104.8 → 157.8 | 16.9% | 99.9% |

Producer and arena columns are per the dominant compile (module: the 301-fd
main module; aggregate: the 535-fd jQuery tree); the artifact column is over
all compiles (module 313 FBs, aggregate 596).

The per-`FunctionDef` producer delta is a narrow band, +142 to +207 B/fd
around the aggregate's +145, and it decomposes the same way everywhere: three
v2-only items (`Builder` object 168 B, label table, reloc array) totalling
234,632 / 164,592 / 168,168 / 64,008 / 228,248 B, against v2's *smaller* shared
items (compact code stream + source markers) returning −96,120 / −69,092 /
−43,736 / −13,432 / −150,680 B.

### 2.4 Families flagged as materially different

| family | how its profile differs from the aggregate | is it a retention finding? |
| --- | --- | --- |
| **module** | Its peak is **not** a compile-time peak: v2's parse-end set is only 72.1% of the whole-run peak (every other family is 95–100%), because the module graph keeps its exports — and therefore its whole artifact — reachable to the end of the run. The peak delta is consequently **+4,296 B, which is exactly the artifact delta** (+4,288 code bytes + the 8 B root stub), not a producer or arena term. | **No.** It is the same C2-B delta measured at a different instant; it is the cleanest confirmation of C2-B in the whole set. |
| **TS extension** | Peak is 67% parser arena (aggregate: 17%), and the arena is byte-identical between pipelines, so the arena term is **+0** and the entire parse-end gap is producer footprint. Also the highest per-fd producer delta (+207 B/fd) and the tightest C2-A margin (0.6075x). | **No.** Higher producer density per function (more, smaller functions with more label/reloc traffic), zero arena divergence, artifact behaviour identical in kind to every other family. |
| **JS core**, **class** | v2's whole-run peak is **below** legacy's (0.93x, 0.81x); legacy's lowering headroom is 342 KB / 531 KB against v2's 8 KB / 78 KB. | **No** — and it is the direction the aggregate hides. |
| **TS enum/namespace** | Cannot be measured under v2 at all (§3). | Unknown; see §3. |

**No family shows retention that the aggregate hides.** In every measurable
family: shared `FunctionDef` metadata delta is exactly 0, the v2 producer
census drains to 0 by `T5_finalize_end` (only the 8 B root legacy `byte_code`
stub remains), artifact allocation counts are identical, group (ii) and (iii)
are identical up to bytes derived from group (i), and 0 artifact pointers are
arena-backed.

---

## 3. The TS family is measured on a construct whose lowering is known-broken

TS lowering has been ruled inside the v2 switch scope, and `enum` / `const enum`
/ `namespace` currently miscompile under v2 through unguarded legacy emissions.
Under a Debug build that is not a wrong-output condition, it is a **hard stop at
parse time**: `parseEnumDeclaration` → `emitOp` → `appendBytes` →
`appendBytesAt` trips `std.debug.assert(!(v2_available and self.emit_v2))`
(`src/parser.zig:6959`), with the same path reached from
`parseNamespaceDeclaration`. The process aborts before `createFunctionBytecode`
is ever entered, so **no v2 census of any kind can be taken** on those three
constructs — not producer, not artifact, not arena, not transient.

Consequences for this scorecard, stated explicitly:

* The **TS extension** family row (`fam-ts.ts`) deliberately excludes `enum`,
  `const enum` and `namespace`. Everything it does contain — annotations,
  interfaces, type aliases, generics with constraints, `as`, parameter
  properties, optional/default/rest params, `implements`, `readonly`,
  visibility modifiers, index signatures, overload signatures — is erased or
  lowered on both pipelines and is fully measured.
* The **TS enum/namespace** family row is **legacy-only**, and is reported so
  the size of the unmeasured hole is on the record: 61 FunctionDefs, parse-end
  804,993 B, whole-run peak 1,221,728 B (of which arena 438,890 B = 35.9%),
  artifact 32,515 B (code 11,411 B), peak in-window transient 413,987 B / 10
  allocations.
* Because those constructs currently reach *legacy* emission code from inside a
  v2 parse, **their memory profile is expected to move once TS lowering is
  migrated to v2**, in the direction of the other families (a `Builder` + label
  table + reloc array per emitted function, and long-form code until
  `.short` is the default). No figure in this document should be read as a
  prediction for post-migration TS enum/namespace.
* This document does not change TS lowering.

---

## 4. Scorecard: what passes, what needs a ruling, what the levers are

### 4.1 Dimension status

| dimension | status | evidence |
| --- | --- | --- |
| **C2-A** transient lowering memory | **PASS on bytes** — 0.5702x aggregate, 0.50x–0.61x across all four measurable families, every one under the 0.7x bar, with 0.4573x–0.5627x once the artifact born in the window is excluded. **FAILS on allocation count** — 1.60x aggregate, 1.73x–1.80x per family. | §1 C2-A, §2.1 |
| **C2-B** artifact residency | **EXPLAINED, needs a ruling only on whether the delta is acceptable.** `legacy artifact == v2 artifact` is FALSE; the delta is +6.8% aggregate (+4.6% to +9.3% per family) and it is **entirely group (i) code bytes**, caused by `resolve_labels.default_layout = .plain`. No new persistent table, no extra owner, nothing arena-backed, allocation counts identical family by family, and confirmed independently by end-of-run resident bytes on the module family (exact to the byte). | §1 C2-B, §2.2 |
| **C2-C** peak live set | **EXPLAINED.** The peak *is* the parse-end set on both pipelines (except the module family, where it is a runtime peak). The increase is 34.9% producer footprint + 65.0% parser-arena geometry + 0.04% residual on the aggregate, with a residual of exactly 0 on all four families. Zero transient/artifact overlap at the peak instant. The aggregate's 1.0756x is the **worst** of five sources; three of four families put v2 *below* legacy (0.81x–0.95x). | §1 C2-C, §2.3 |

The two items that need a ruling rather than more measurement:

1. **C2-A's allocation-count axis.** Bytes pass everywhere; concurrent live
   temporary allocations per lowering are 24 against legacy's 15 (aggregate),
   19 against 11 (three families), 18 against 10 (JS core). Whether "< 0.7x"
   binds on that axis at all is a ruling, not a measurement — the whole-run
   `allocation_count_peak` gap is attributed to the parse-end producer census
   (2,819 vs 1,597 live producer allocations), not to these nine.
2. **C2-B's +6.8% code-byte delta.** It is a lowering-quality property of the
   `.plain` default layout, fully localised, and not an ownership defect.

### 4.2 Remaining levers, with their measured sizes

Stated as sizes only. The ruling deferred lower-on-pop and the switch condition
is "C2-A PASS and C2-B/C explained and acceptable"; none of the following is
recommended here.

| lever | what it would remove | measured size |
| --- | --- | --- |
| **lower-on-pop** (lower each function at the end of its body during parsing, so the emission census is O(depth) rather than O(tree)) | the whole per-`FunctionDef` producer census from the peak | v2 producer footprint at parse end: **896,976 B / 2,819 allocations** (aggregate), 742,544 / 3,607 (JS core), 428,168 / 2,987 (class), 409,648 / 3,005 (TS), 172,432 / 1,325 (module). It is 31.1% of v2's aggregate peak. |
| **per-`FunctionDef` footprint** (the three v2-only producer items: 168 B `Builder` object, label table, reloc array) | the v2-only half of the producer delta, without changing pipeline topology | **+228,248 B** aggregate (`Builder` 89,880 / labels 79,616 / relocs 58,752, in 535 + 343 + 343 allocations); 234,632 (JS core), 168,168 (TS), 164,592 (class), 64,008 (module). Note the net producer delta is smaller than this everywhere because v2's shared items are already 43,736–150,680 B *smaller* than legacy's. The reloc array specifically is provably dead the moment `resolve_variables.run` returns: 58,752 B / 343 allocations aggregate. |
| **arena geometry / releasing the parser arena at parse end** (a phase-ownership boundary fix in the parser, present identically in both pipelines; proven to have no reader in the emit phase by the poison test) | the entire parser-arena term from both pipelines' peaks | v2 arena resident at parse end: **488,548 B** aggregate (16.9% of peak), 2,487,750 (TS — 67.0% of peak), 487,518 (JS core), 197,342 (class), 54,334 (module). Legacy: 344,060 / 2,487,750 / 473,144 / 190,610 / 53,962. On the aggregate it moves the peak ratio 1.0756x → 1.0249x; it is compiler-neutral, so it barely moves the ratio while removing the largest single absolute term. |
| **`resolve_labels.default_layout = .short`** (the C2-B lever) | the group (i) code-byte delta and the atom refs and pc2line bytes derived from it | **+31,640 B** aggregate artifact (+6.8%); +25,572 (JS core, +66.9% on code), +10,647 (class), +10,014 (TS), +4,288 (module). Not a lifetime or ownership change. |

---

## 5. Reproduction

```
# Debug binaries (diagnostic accounting is Debug-only)
zig build zjs-dev -Dzjs_compiler=v2
zig build zjs-dev -Dzjs_compiler=legacy

# whole-run counters (peak bytes / peak allocations / end resident)
./zjs-dev --perf-json <source>

# §11/§12-style censuses: producer, artifact, arena, arena-pointer audit
ZJS_C2D=1 ./zjs-dev <source> 2>census.txt        # NOT with --perf-json:
                                                 # both write to stderr and interleave
# C2-A classification input
ZJS_C2D=1 ./zjs-dev -T <source> >trace.txt
```

`<source>` is one of the six sources in §0. `ZJS_C2D=1` is measurement-neutral
(verified per family, both pipelines: `--perf-json` counters are identical with
and without it). The probe is scratch-only and is not part of this commit;
`docs/v2_builder_lifetime.md` §10.1 records what it instruments and where, and
this document records the one addition needed for the module family (the same
probe points on `createModuleFunctionBytecode`, which module roots take instead
of `createFunctionBytecode`).
