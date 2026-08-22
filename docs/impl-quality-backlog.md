# Implementation Quality Backlog

Durable queue from the 2026-08-21 implementation-quality review. That review
did two things: it reconciled the 2026-08-20 audit worklist against `main`
item by item (grep-verified, not changelog-trusted), and it examined for the
first time the three blind spots the audit itself declared — the GC/trace
family, the parser/compiler front end, and `src/core/object.zig` internals.

Line numbers were verified at the review commit; they drift, function names
are the anchor. Gate abbreviations as in
[maintainability-backlog.md](maintainability-backlog.md): **AB** = bench-v8
A/B (hot file); **suite** = test262 + unified suite; **identity** = `.text`
byte-compare.
Gates follow [refactor-policy.md](refactor-policy.md)'s 2026-08-22 tiers.

## What the review verified as healthy (do not re-audit)

- **`object.zig` union discipline is exemplary.** All 20 out-of-line payload
  kinds are read through kind-checking accessors; teardown is kind-switched;
  no unguarded union read was found. The discriminant is *more* explicit than
  QuickJS's (5-bit `class_payload_kind` tag + comptime layout asserts vs bare
  `class_id`).
- **The compiler "same-name copy-drift" suspicion is refuted.** Every
  `bytecode.zig`↔`parser.zig` and `resolve_labels`↔`resolve_variables`
  same-name pair examined is either wrapper→authority delegation, a
  deliberate two-pass mirror (disjoint opcode sets), or cross-phase
  complement. The only true copies are `updateLabel` and `reserve`
  (rl:393/rv:146, rl:39/rv:114), currently drift-free.
- **The cycle collector is a faithful three-phase QuickJS mirror**
  (`destroyRuntimeCyclesWithValueRoots`, qjs line numbers annotated inline).
  Re-entrancy gates, recursion shape, phase doors, and weak-collection
  ordering all check out. Every trace-vs-destroy discrepancy found points in
  the *leak* direction; no over-trace (trial-RC underflow → UAF) direction
  defect exists.
- **`resolve_labels`' four parallel streams** (output bytes, atom ledger,
  source events, label/bind/reloc tables) are still hand-synchronized in
  every special-cased arm, but a missed sync now fails closed:
  `validateFinalOutput` / `validateFinalSources` run in **all** build modes.
  The residual defect is Q5b (the failure wears a SyntaxError mask), not the
  fragility itself.

## Corrections to existing ledgers

- **H8's "six manual `align(16)` pins"** are all *function-entry* alignment
  (`destroyFromHeader`, the three `mark*Hot` arms, `markChildrenCold`,
  `setOrDefineOwnDataPropertyForPutFieldOwned`) with a measurement lineage in
  git (`224a0628`, `0280e278`). None pins a data field. `Object`'s data
  layout is pinned by comptime asserts alone (`@sizeOf == 64`, `u` at offset
  40). Consequence: an H8 method move carries the pins along with the
  functions; the layout risk is `.text` rearrangement, not struct layout.
- **"~15 payload domains"** is actually 20 `PayloadKind`s + 3 inline union
  arms (array / bytecode_function / regexp) + 1 external-opaque convention =
  24 discriminated states.

## Queue

### P0 — correctness

**Q14. `engine-production-gate` is red on main: `check_borrowed_atoms`
reports `parseFunctionDecl` storing a defer-freed `name_atom`
(parser.zig:15246).**
  **Done 2026-08-21**: bisect stopped at 47cf81ef already red —
  audit-tier gap, not a Q5/Q6 regression. Rule-D static false positive
  (defer LIFO ordering); fixed with the contract's borrowed-reason
  annotation (+1 line), checker at 0 escapes / 0 allowlisted, gate
  34/34, emission byte-identical. Process note stands regardless:
  parser items should run `check_borrowed_atoms` in their gate set —
  nightly-only instruments hide regressions for a full cycle.
Found by Q10's gate sweep on an untouched
checkout; the ownership audit is a nightly instrument, so per-item
suites never ran it — attribution (pre-existing vs a Q5/Q6 parser
regression) is the first step. Gate: check_borrowed_atoms green +
full parser suite + emission identity (+ AB if the fix touches
non-error paths).

**Q1. `markFastArrayHot` misses the iterator-next cache edge** *(confirmed;
the one live GC defect found)*
- **Done 2026-08-21**: fix + bare-runtime regression test landed in one
  commit. Gate: rule-2 bench-v8 A/B vs `47cf81ef` — composite Score medians
  2612 / 2592, ratio 1.0081, per-suite deltas mixed in sign (layout-noise
  signature); test-core / test-exec / smoke-dev green.
- `markFastArrayHot` (`object.zig:7756`) marks shape + props + elements only.
  The authority `traceChildEdgesFallible` (`:8461`) and the sibling hot arm
  `markOrdinaryObjectHot` (`:7749`) both visit
  `cachedIteratorNextSlotIfPresent`; the destroy side owns and frees the edge
  (`clearCachedIteratorNext`, `:2965`). The cache attaches to any object used
  as an iterator (`call_runtime.cacheIteratorNextMethod` has no class guard),
  so `[Symbol.iterator]()` returning a fast array hits the gap. All three
  trial-deletion phases go through the same `markOne`, so the miss is
  consistent: not a UAF — a cycle through that edge is never collected.
- Fix: mirror the two-line cache block into `markFastArrayHot`. Repro test
  first (project discipline), then the fix, then prove the hot arm parity —
  the hot arms have now demonstrably drifted from the authority once.
- Gate: repro test + suite + **AB** (GC mark hot arm).

**Q2. ~10 payload families have no cycle-release regression test.**
- **Done 2026-08-21**: eleven guards landed, tests only (+225 lines).
  Deletion probes confirmed each guard turns red when its trace arm is
  removed; production files byte-identical after restore. test-core 341 /
  test-exec 491 green.
Only per-family "cycle is released" tests catch a trace-side miss (the leak
checker catches destroy-side misses only). Template: `src/tests/core.zig`
"prototype cycle is released" (~15 lines each). Missing, in rough order of
exposure: iterator-next cache (with Q1), strong Map/Set entry cycles,
Promise result/reactions, `OrdinaryPayload` error_stack/callsite,
accessor-pair properties, `FunctionRarePayload` (11 of 12 fields),
BoundFunction target/args, DisposableStack resources, ObjectData,
ModuleRecord import_meta/eval_exception.
- Gate: suite (tests only).

**Q3. 2026-08-20 worklist stragglers — reproduced spec bugs still open**
(the worklist itself lives in `.scratch/audit-2026-08-20/`, gitignored;
this entry is its durable residue):
- **Q3a.**
  **Done 2026-08-21**: both sites resolve through `classPrototypeObject`;
  differential probes vs pinned QuickJS byte-equal post-fix
  (replaced / deleted / untouched globals × four combinators + groupBy);
  regression tests pin every case. The remaining
  `constructorPrototypeFromGlobal` consumers stay queued — hot-path blanket
  conversion, separately gated.
  Set combinators + `Map.groupBy` take result prototypes from the
  mutable `globalThis.Set`/`Map` binding: `constructPlainSet`
  (`collection_ops.zig:1966`) still calls
  `object_ops.constructorPrototypeFromGlobal`. Switch to
  `JSContext.classPrototypeObject`, then convert or delete the remaining
  `constructorPrototypeFromGlobal` consumers (probed unobservable in the
  audit). Gate: suite.
- **Q3b.**
  **Done 2026-08-21**: name added to the single predicate, `length` 0 per
  WebIDL, all construction forms covered by tests. Gate: rule-2 A/B —
  composite medians 2536 / 2529, ratio 1.0026, mixed-sign per-suite
  (layout-noise signature); builtins / exec suites green.
  `DOMException` is missing from the (now single) builtin
  constructor name list (`call_runtime.isBuiltinConstructorName`, `:2656`) —
  `new DOMException` works but `Reflect.construct` and
  `class X extends DOMException` throw. Also `DOMException.length` should be
  0 per WebIDL. Gate: **AB** (call_runtime) + suite.
- **Q3c.**
  **Done 2026-08-21**: four tails converged onto one typed-array-aware
  CreateDataPropertyOrThrow helper + unconditional throwing length-Set;
  differential probes byte-equal vs pinned QuickJS; test262 delta 0
  (49,778 / 44,584). Gate: rule-2 A/B — composite medians 2534 / 2528,
  ratio 1.0028, mixed-sign per-suite (layout noise).
  `Array.of`/`Array.from` tails keep the non-spec
  `!isTypedArrayObject` length carve-out and a strictness-dependent
  `setValueProperty` where the spec says `Set(..., true)`
  (`arrayOfCall` tail, `array_ops.zig:4847`; three sibling sites). The
  correct shape exists in the same file (`fromAsyncFinish`). Gate: **AB** +
  suite.

**Q3a tail closed 2026-08-23** (`3f11ec95`, proto-a grok lane): the 2026-08-21
note that the remaining `constructorPrototypeFromGlobal` consumers were
"probed unobservable" **was wrong** — eight families were user-observable and
are fixed: `RegExp()` without `new`, the `RegExpCreate` in String
`match`/`search`/`matchAll` (now via the cached `%RegExp%` slot),
`Uint8Array.fromHex`/`fromBase64` plus the bytes-module ArrayBuffer proto,
the native-error `Reflect.construct` fallback, `Error.prototype.stack`
identity, `DisposableStack`/`AsyncDisposableStack.move`, and dispose-produced
`SuppressedError`. Driver-verified pre/post: with `globalThis.RegExp`
replaced, `RegExp()` returned the fake prototype and `"abc".match("b")`
threw TypeError outright; both correct after. Remaining global walks
(`objectPrototypeFromGlobal`, primitive boxing, `initializeInitialShapes`)
are documented embedder fallbacks for realms with no published class table.
Gates: suite 2339/1/0, test262 delta 0. **A/B: the driver re-measured and ran
the pad lineage** — RegExp read −2.5% twice on pad 0 (stable, and the changed
domain, so not dismissible as dispersion) but **+1.2% on pad 3 and +2.0% on
pad 7 = sign flip = LAYOUT**, consistent with the mechanism (a global property
walk replaced by an O(1) class-table read is strictly less work). Composite
0.9977 / 1.0047 / 0.9979 / 1.0000 across four runs, all in band.

**Q4. The shared-engine test tier (403 of 616 tests) has no leak check.**
`sharedTestEngine` (`src/tests/helpers.zig`) never deinits, so
`JSRuntime.deinit`'s outstanding-allocation assert is unreachable there.

**Status 2026-08-21** — the discovery gate ran and split the item:
- The naive plateau assert is structurally invalid: lazy first-use state
  is legitimate (empty-file pass even shrinks bytes). The real signal is
  same-process repeat non-convergence: 18 tests still grew on pass 1/2.
- Attribution clustered them into three roots, zero definite leaks
  (post-GC snapshots throughout):
  **R1 by-design** — `evalModule`'s unique `<eval>#N` specifiers populate
  `ctx.modules` per eval; accepted, the future gate accounts for it.
  **R2 fixed (this commit)** — `internAutoInit` appended without
  interning; `registerExternalHostFunction` never deduped. Both flat on
  repeat now, with regression guards.
  **R3 fixed 2026-08-21 (Q4b)** — property compaction ported: exact
  reference trigger (deleted ≥ 8 and ≥ prop_count/2, delete-path only),
  transactional stable rebuild via `shape.prepareUpdate`. Bounded-sawtooth
  parity proven on the real hidden-globals object (peak 150/72 → 86/8,
  live 78 intact). Gate: A/B 0.9973 + pad lineage 0.9975/0.9990/1.0008 =
  sign-flip = LAYOUT; test262 delta 0; full suite green. Driver note: the
  original "flat on repeat" criterion was wrong — the reference mechanism
  is lazily bounded, and acceptance criteria for faithful ports must be
  derived from the reference's own steady state.
- **Q4c (the gate itself)** lands after Q4b, as a post-GC plateau with
  module-registry growth explicitly accounted.
  **Q4c landed 2026-08-21 — item closed.** Per-test gate: post-collection
  module-accounted high-water, T=8 over a measured p95=0/max=7
  zero-module floor (n=814); proven live on a scratch leak. Nightly
  `test-leak-census` runs both shared tiers twice in one process; pass 0
  warms lazy state, pass 1 enforces full accounting. No new pub surface.
  Residual accepted risk: single-pass runs ratchet through first-use
  growth, so sub-tolerance drips are caught by the nightly census, not
  per-test.

### P1 — user-visible diagnostics (cheap; downstream pipe already exists)

**Q5. Parse errors report the wrong place and the wrong thing.**
  **Done 2026-08-21 (Q5a + Q5b + the expectToken choke point)**: pending
  diagnostic on `State`, last-writer-wins; 467/468 error paths inherit the
  exact site (sole boundary: deferred module-export validation, where the
  reference also prints no position); internal-error arm separated;
  emission byte-identical on five corpora. Gate: A/B 0.9983 + pad lineage
  sign-flip (RegExp 0.9769/0.9893/1.0276) = LAYOUT; test262 delta 0. The
  377-site message long tail remains open (mechanical, incremental).
  **Q5c batch 1 done 2026-08-22** (`c9bb6278`, diag lane): 100 of 377
  converted (87 found-token, 13 expected/got); 277 remain — deferred
  families: class/module/parameter/destructuring/binding/lowering, plus
  sites whose current token is lookahead rather than the actual found
  token, and internal structural invariants. Verdict drift zero: emission
  byte-identical on the five corpora, parser 500/500, test262 delta 0.
  **Q5c batch 2 done 2026-08-22** (`a2769c63`, diag lane): 101 more
  (binding/for-in-of, function/arrow params, destructuring, class,
  import/export; `let 5` now says "expected binding name, got number").
  Cumulative 201/377. Remainder taxonomy: **140 internal-invariant masks
  (spun off as Q5d below)**, 25 semantic/generic deferred, 10 lookahead
  sites with no reliable found-position, 1 base helper, 2 helper exits.

**Q5c batch 3 done 2026-08-22** (`bb920165`, diag lane): 25/25
semantic/generic + 8/10 lookahead converted; the two holdouts
(parser.zig template-token payload invariants, :8910/:8956 at review
time) are internal invariants and fold into Q5d. Bare direct sites
178 → 145 (= 137 Q5d masks + 2 template sites + 3 helpers + pilot
residue). Q5c's user-facing surface is now **fully converted**.

**Q5d. 140 parser sites return `Error.UnexpectedToken` for internal
invariant failures** (builder tail rewrites, label/control/finally
plumbing, scope/closure state, class child/cpool/init/patch) — an engine
bug would surface as a user syntax error, the same mask Q5b removed at
the reporting boundary. Direction: route them to the internal-error arm
(existing internal set or a dedicated `ParserInvariant` error), which
changes verdicts only on engine-bug paths. Pilot first: mechanism on ~5
representative sites per family, then a driver ruling before mass
conversion. Gate: suite + emission identity (cold error paths).
  **Pilot done 2026-08-22** (`d3dae20d`, diag lane): one site in each of
  five families (builder tail replacement, return-finally frames, scope
  close, class-name patch, using-block frames) routed through the
  existing Q5b internal-compiler-error arm via `error.InvalidBytecode`;
  emission cmp=0, parser 502/502. A dedicated `ParserInvariant` prototype
  was withdrawn only because core/errors.zig was out of the lane's zone.
  **Ruling (driver): mass conversion approved with the dedicated
  `ParserInvariant` member** — one-line addition to `RuntimeError` plus
  the internal-arm predicate (narrow carve-out granted; no lane
  collision), re-pointing the five pilot sites. 137 sites in 3-5
  per-family batches; each batch proves arm routing with a temporary
  fault hook (the @panic-probe discipline applied to error paths), and
  the 71-site `mapBuilderError` fanout gets a static census first.
  **Q15 allowed-domain closure** (`5a0897c0`): the lexer.zig drift was
  re-verified three-way same-lineage byte-identical — ruled a
  non-stable cache basin, header landed under identity after all;
  all 21 allowed-domain files done. Remaining headerless: core + binding
  (implq's rounds).
  **Batch 1 done 2026-08-22** (`bc146436` + `6cb90fb1`, diag lane):
  `ParserInvariant` landed in `RuntimeError` (the single-line carve-out)
  and the Q5b predicate; the `mapBuilderError` census settled the risky
  boundary — of 71 calls, 36 can actually produce the invariant error
  (all controlled label/control/atom-ledger/tail-shape conditions), 35
  only share the wide set for OOM/BytecodeOverflow, and **zero** are
  malformed-source diagnostics, so the whole fanout re-routes safely.
  59 masks removed (five families + map helper + the two template
  sites). Routing proven by 7/7 temporary fault injections printing
  "internal compiler error: ParserInvariant" (not UnexpectedToken, no
  0:0), hooks fully removed after. Emission cmp=0 on five corpora,
  suite 2330/1/0, test262 delta 0. Bare count 145 → 81 (78 Q5d masks
  remain + 3 recorder helpers).
  **Batch 2 done 2026-08-22 (`eb627efe`) — Q5d CLOSED.** 73 of the 78
  converted; four newly-touched families proven by fault injection
  (4/4 "internal compiler error: ParserInvariant", hooks removed).
  The safety boundary caught **five sites that are actually
  malformed-source-reachable** (script top-level `using`, missing
  break/continue label, continue to a non-loop label,
  `const [...[a] = []]`, duplicate module class binding) — each proven
  by CLI rc=1 + breakpoint on the bare exit; they were correctly NOT
  converted and instead return to Q5c as a final message micro-batch.
  End state: 8 bare sites = 3 recorder helpers + those five.
  Side observation for the core zone: `zig fmt --check` fails on
  pre-existing `src/core/gc.zig` formatting (untouched; fix rides the
  next implq core round).
  **Final micro-batch done 2026-08-22 (`1fbb4fe9`) — the Q5 arc
  (Q5a/b/c/d) is CLOSED.** The five reclassified sites got real
  diagnostics ("using declaration is not allowed at the top level of a
  script" — checked against the test262 Early Error, "undefined label
  'x'" with the name, "continue must target a loop label", "rest
  element may not have an initializer", declaration-conflict family
  reuse), each red-first. Terminal state verified: the only bare
  `UnexpectedToken` returns in the tree are the three recorder-helper
  exits themselves. From the 2026-08-21 baseline "every syntax error
  says UnexpectedToken at EOF" to: exact positions everywhere, real
  messages at every user-reachable site, and internal invariants
  reporting as internal compiler errors.
- **Q5a.** Every syntax error's line/column points at **EOF**, not the error
  site (verified by running the shipped binary: error on line 3 of a 4-line
  file reports `5:1`). Cause: `setFallbackSyntaxError` (`parser.zig:20357`)
  recovers the position by re-lexing the whole source; a syntax error re-lexes
  clean to EOF. The downstream pipeline (`diagnostics.SyntaxError` →
  `throwParseSyntaxError`, 5 call sites) already carries line/column/message —
  only upstream capture is missing. Fix: a pending-diagnostic field on
  `State` (position from `s.token.line_num/col_num`), last-writer-wins;
  this alone fixes the position even while the message stays
  "UnexpectedToken".
- **Q5b.** Internal compiler errors (`InvalidBytecode`, `BytecodeOverflow`,
  `InvalidTopology`) reach users as `SyntaxError: <errorName>` at EOF
  (`parser.zig:20372`) — an engine bug wearing a user-error mask. One switch
  arm: report "internal compiler error", distinct from syntax errors.
- **Q5c.** Message quality long tail: `expectToken` (`parser.zig:5613`) is a
  three-line choke point — one change yields "expected X, got Y" for a large
  class. The 377 bare `return Error.UnexpectedToken` sites convert to a
  recording helper incrementally, purely mechanical.
- Gate: suite (parser is CodeLoad-measured: keep emission byte-identical;
  error paths are cold).

### P2 — structure and hardening

**Q6. Parser state-restore hazards** (same family as three historical real
bugs):
  **Done 2026-08-21**: Q6a mutation-after-defer fixed; Q6b folded as an
  explicit `StaticBlockContext` extension (field sites unchanged); Q6c
  census found six entry sites (three more than known), all on one
  comptime `FunctionEntryContext`. Gate: A/B 1.0037, emission
  byte-identical, 20-case qjs corpus exact, test262 delta 0. **New
  pre-existing finding logged during execution**: zjs accepts
  `(arguments) => { 'use strict'; }` where the pinned QuickJS (and the
  spec: the directive strictens the whole function, making `arguments` a
  banned binding name) reject with SyntaxError — queued below as Q6d.
- **Q6a.** `parseFunctionExpr` mutates `pending_function_name` ~40 lines
  before registering its restore defer (`parser.zig:15101` → `:15142`);
  three error returns and one failable `advance()` sit in the window, one of
  which can leave a dangling atom. Unobservable today (no error-recovery
  path re-enters the parser), but it is armed. Move the mutation below the
  defer, matching the declaration-form sibling (`:15076`).
- **Q6b.** Class static block still open-codes a 14-field snapshot
  (documented at `FieldInitContext`); fold onto the collapsed mechanism.
- **Q6c.** ~100 hand-written single-field save/restores over ~45 `State`
  fields remain, with function-entry sites each saving *different* subsets
  and no single oracle type. Introduce `FunctionEntryContext` covering the
  union of the entry-family fields.
- Gate: suite; emission must stay byte-identical (identity on bytecode
  streams for representative sources).

**Q6d. `(arguments) => { 'use strict'; }` is accepted; spec and QuickJS
reject.**
  **Done 2026-08-21**: divergence was exactly the six strict-body arrow
  variants; one shared retroactive validator now covers arrows and
  ordinary functions; 24/24 differential parity, red-first regression,
  emission byte-identical, A/B 1.0017. Position note: zjs reports the
  offending parameter, QuickJS the directive — verdict parity is the
  contract, and the parameter position is the more actionable of the
  two.
Found by Q6's differential corpus run; pre-existing, untouched
by Q6. Fix belongs with the directive-prologue / strict-parameter
validation path. Gate: suite + qjs differential (+ AB, parser).

**Q7. `object.zig` conventions hardening** (no layout changes):
- **Done 2026-08-21** (minimal form; the full `.external` enum kind rides
  the Q11 T1 split): tri-state contract + exclusion-list duty documented
  with Debug proofs, trap default fixed (verified bit-identical), three
  exec-side raw reads asserted, doc rot repaired. Gate: `.text`
  byte-identical; full suite green; no assert fired. Note: the first
  candidate build's `.text` moved and was correctly attributed to
  cache-lineage anonymous-symbol numbering — clean two-sided builds
  converged; identity claims need same-lineage builds.
- **Q7a.** `class_payload_kind == .none` means three things (no payload /
  embedder-external payload / inline-arm class), disambiguated by a manual
  exclusion list in `externalClassPayload` (`:3132`). Add an explicit
  `.external` kind (u5 has 11 free values) or, minimally, document the
  tri-state on `ObjectStorage` and add a debug assert.
- **Q7b.** `u: ObjectStorage = .{ .array = .{} }` (`:1879`) is a trap
  default: an object literal that omits `.u` would yield
  kind==`.none` + word0==dangling-sentinel, which `externalClassPayload`
  would hand out as a payload pointer. All six current literals override it;
  change the default to the null-payload form (bit-identical today).
- **Q7c.** Three out-of-file guard omissions get zero-cost debug asserts:
  `tailcall_dispatch.zig:3545`/`:4085` (raw `u.payload` →
  `*TypedArrayPayload` cast; dispatch-point guard proven but unasserted),
  `small_inline.zig:354` (raw `u.bytecode_function`).
- **Q7d.** Doc rot: the `array_length` invariant comment at `:1880-1887`
  describes a field that moved into `DenseArrayStorage.length`.
- Gate: identity (asserts are Debug-only; defaults bit-identical) + suite.

**Q8. GC switch-surface convergence** (make "add a kind, miss a spot"
compile-visible):
  **Done 2026-08-21**: exhaustive `markChildrenCold` (−312 bytes for the
  function itself), one comptime predicate for the four zero-ref kind
  sets (`.text` byte-identical for that half), symmetric
  `ArgumentsPayload` trace arm with red-first cycle guard,
  `releaseObjectForTest` rename + compile guard. Gate: A/B composite
  1.0000; full suite + leak census green.
- `markChildrenCold`'s `else => {}` (`object.zig:7806`) silently no-traces
  any new GC kind → exhaustive switch.
- `destroyZeroRef`'s four hand-copied kind sets (`gc.zig:1942-1985`) → one
  comptime predicate.
- `ArgumentsPayload` has destroy but no trace arm; production never
  registers the kind (tests only). Delete the kind or add the arm — a
  registered embedder class would silently leak today.
- `Registry.releaseObject` (`gc.zig:1595`) unlinks at rc 0 without
  destroying; single test caller. Rename to a `...ForTest` name or delete.
- Gate: suite; **AB** only if the exhaustive switch changes codegen in the
  mark path (check identity first).

**Q9. Delete the unimplemented "major GC" surface in `gc.zig`** (~500
lines): `MajorPhase.mark_incremental`/`weak_fixpoint`,
`enable_concurrent_mark/sweep/selective_evacuation` (no consumers),
page-geometry derived from `live_bytes`, and pause percentiles that are
synchronous whole-pass durations in costume. A test admits the phases are
unimplemented. Keep the honest parts (registry, thresholds, phase doors).
  **Done 2026-08-21**: 92 decls / 351 lines deleted to a fixed point. The
  review's "no implementation" claim was consumer-side only — the
  producer side was codegen-reachable (identity gate caught it:
  `refreshPageState` 304 B of live code, `pollGC` −216 B), so the item
  escalated from identity to A/B and PASSED at 1.0039 with both GC-heavy
  suites positive. Public removals enumerated in the changelog under the
  approved 0.2.0-dev breaking window.
- Gate: suite + identity (dead surface should be codegen-neutral; if `.text`
  moves, stop and find out why).

**Q10. Gate & tool hygiene stragglers** (from the 08-20 worklist):
  **Done 2026-08-21** in five commits (deps hole / profiler honesty /
  envelope collapse / shim deletion / JSRuntime pin). Residual noted:
  the profiler CLI also leaves value_dups and global_lookups
  uninstrumented — folded into the "not instrumented" labeling.
- `check_deps.js` core disallow list is missing `src/binding/` — core
  transitively reaches exec through one test import
  (`core/string_view.zig` → `binding/root.zig` → `exec`). Move the test,
  close the hole.
- `--profile-opcodes` prints structurally-zero counters
  (`vm_call.zig:307` opens with `if (comptime true) return .{};`; five
  orphaned recorders). Delete the dead recorders; print "not instrumented"
  for what remains uninstrumented.
- 166 hand-rolled print-capture envelopes → one `helpers.expectPrints`
  (~−1,275 lines, provably coverage-neutral; do not move the 48
  deinit-checked tests into the unchecked tier).
- 10 residual `export fn` C-ABI shims in `libs/number_format.zig` (30 → 10
  done); re-verify the survivors have callers, delete the rest (size axis,
  no perf claim).
- Record + pin `JSRuntime`'s public surface (167 pub decls, currently
  unpinned — unlike `JSValue`'s).

### P3 — structural moves (each gated; investigate before acting)

**Q11. `object.zig` split (executes H8), in risk order:**
  **T1 done 2026-08-22**: object.zig 13,251 → 11,774; two new core files
  + two rehomes; 47 aliases, zero call-site churn; field blocks
  byte-identical; A/B 1.0010, all suites within ±0.32%. Note for a later
  tranche: `destroyDetachedClassPayload` stays in object.zig — it
  bridges Object cursor teardown and both extracted modules.
  **T2 done 2026-08-22 (narrow seam)**: object.zig 11,774 → 11,163;
  object_gc.zig 709 lines; five `…ForCycleGc` purpose seams (first cut
  needing 23 pub promotions was stopped by the ceiling and re-ruled —
  edge enumeration stays on Object). All 13 cycle guards green; A/B
  0.9988 in-envelope = pass without lineage under the 2026-08-22 tiers.
  Parked design candidate: move each payload's trace arm beside its
  destroy method (institutionalizes the Q1 trace/destroy pairing
  lesson). T3 (class-family method sections) remains optional; T4
  remains recommended-against.
- **T1**: payload-type prelude → `object_payloads.zig`; `RealmValueSlot` →
  `context.zig`; StdFile/pclose → runtime host layer; generator
  suspend-state (~460 lines) → `generator_state.zig`. ~−2,300 lines, types +
  cold methods.
- **T2**: the cycle-collection engine (`:7577-9934`, ~2,360 lines) →
  `object_gc.zig`. Mostly cold; the four hot mark arms' `align(16)` travel
  with the functions. Side benefit: the audit blind spot becomes one file.
- **T3**: the six class-family method sections (~3,760 lines), aliased back
  (`pub const foo = impl.foo;` keeps call sites unchanged).
- **T4**: create/destroy/define/set property engines — hottest, two hot
  pins. **Recommended stop point: do not do T4.** Residue after T1–T3 is
  ~7,200 cohesive lines.
- Forbidden: converting `ObjectStorage` to a tagged union or reordering
  `Object` fields — that is a representation experiment, and QuickJS-parity
  representation is a load-bearing wall.
- Gate: every tranche **AB** + pad lineage (`--pads 0 3 7`); data layout is
  comptime-pinned but `.text` placement is not, and pure-placement swings of
  ±0.4–2.7% are on record.

**Q12. The exec five-tuple threading — investigate, then decide.**
  **Investigated 2026-08-22 — ruling: keep the threading** (memo:
  `.scratch/q12-five-tuple-memo-2026-08-21.md`). The hot position is
  measured (removing a 9-field env round trip once won −1.31%
  fixed-work cycles), `output` is API policy inside that ABI, `global`
  is cross-realm correctness authority, and the QuickJS
  current-stack-frame alternative is exactly the rejected per-call
  publication pattern. Standing discipline: no output-on-context, no
  global derivation, no runtime current-frame collapse without a new
  requirement. One parked increment: a gated `*const BuiltinCallEnv`
  pilot in the disposable/reflect cold domains (~409 cold sites upper
  bound), sequenced after Q11/Q13.
`output: ?*std.Io.Writer` is threaded through **829** parameter positions in
`src/exec/`, `caller_function` through 414, `global` alongside — while
`JSContext.globalObject()` exists. This is the single largest readability
tax in the tree, *and* it is probably a measured perf position (the Vm
scalar-mirror publication was a diagnosed disease; explicit register
threading was the cure). Do not collapse blindly. The investigation:
document why `output` cannot live on `JSContext`; if a collapse is viable,
it is two-track — cold builtins take a bundled env struct, the hot call
chain keeps explicit args — and every step is **AB**-gated.

**Q13. Parser file split — after the legacy ruling.** Natural seams exist
(`lexer` 3,363 lines, `token`, `compile_entry` are namespace-clean; ~4,300
lines liftable verbatim). But the QCP-1 legacy/v2 dual-emission residue
(user-ruled NO-GO for deletion) interleaves with `parser_core`, and a split
would scatter the 543 preserved lines. Sequence: land Q5/Q6 first, split
only once the legacy path has its Gate-B2 verdict. Largest-function cleanup
(`parseStatementOrDeclSlow`, 936 lines, mechanical case-extraction) can
proceed independently under emission-identity.

Precursor 1 done 2026-08-22: statement-kind bodies extracted to named
functions; emission byte-identical.

Precursor 2 done 2026-08-22: lexer lifted verbatim; parser.zig 20,769 →
17,408. The parser_core file split still waits on the QCP-1 legacy Gate-B2
verdict.

### P2 — Zig-quality hygiene (added 2026-08-22; owner direction: "a more
qualified Zig project", with QuickJS alignment downgraded to reference and
ECMA-262/test262 as the semantic authority)

**Q15. Module documentation: 40 `src/exec/` files (120 tree-wide) have no
`//!` header.** Coverage is 76/196 files.
  **Batch 1 done 2026-08-22** (`8ea6ca69`): the eight priority files below.
  Gate: `.text` byte-identical within lineage (three-way same-HEAD builds,
  cmp=0; the cross-lineage size shift was attributed to anonymous-symbol
  numbering, the known Q7 phenomenon). ~32 exec files + the rest of the
  tree remain.
  **Batch 2 done 2026-08-22** (`829d0232`): eleven more files (ten exec +
  `runtime/event_loop.zig`, which also gained the `_FORTIFY_SOURCE`
  translate-c and capacity-slice teardown point comments). Identity cmp=0
  same-lineage; ~21 exec files + the rest of the tree remain.
  **Batch 3 done 2026-08-22** (`db275749`): twelve more exec files (+108
  lines). Identity cmp=0 same-lineage (first read against a stale cache
  differed 972 B and was re-verified per the Q7 lineage rule). ~10 exec
  files + the rest of the tree remain.
  **Non-exec batch done 2026-08-22** (`233719b6`, diag lane): twelve files
  across libs/cli/runtime/compiler-tests (regexp, unicode data/algorithms,
  number_format, bigint, the test262 runner family, plugin, zjs CLI).
  Identity cmp=0 same-lineage for both the main `.text` and the
  op_handlers section.
  **Batch 5 done 2026-08-22** (`f7d2f3f2` pre-rebase): twelve more exec
  files; identity cmp=0, and the recurring first-read −972 B was proven
  to be a same-source cache-basin switch. exec is at 76/81; the last
  five (collection_adapter, error_ops, exceptions, property_ops,
  vm_regexp) ride the Q16 Stage 3 round.
  **Batch 6 done 2026-08-22** (`abb6fbfc` pre-rebase): the last five —
  **exec is 81/81**. Also fixed en route: `compile_entry`'s
  internal-error `bufPrint(...) catch unreachable` (UB on an
  over-long `anyerror` name) now falls back to a fixed literal.
  **Core batch 1 done 2026-08-22** (`487ab3c6`): twelve largest core
  files documented (ownership, GC/layout pins, layer boundaries).
  Identity closed under bistable-basin set membership: base and
  candidate both produce the same two-member `.text` set, each pair
  cmp=0 — the gates-audit "set membership, not single comparison"
  rule applied. 13 core + 5 binding files remain tree-wide.
  **Tree-wide closure 2026-08-22 (`0adf2b9b` post-rebase) — Q15 CLOSED
  at 196/196** (semantic census; `libs/number_format.zig` keeps its
  license block first with `//!` at line 23). Started 2026-08-22 at
  76/196. The standard is `src/lexer.zig`:
state what the module owns, the ownership/lifetime contracts a reader cannot
infer from signatures, and reference coordinates where they exist. The worst
offender is `promise_ops.zig` (4,755 lines, zero header, name undersells the
content — see Q18). Priority order: promise_ops, call_runtime, object_ops,
array_ops, string_ops, iterator_ops, call, collection_ops, then the rest.
Headers only — no code motion. Gate: identity (comment-only).

**Q16. `HostError` folds ~47 std I/O errors into the engine's error
surface.** `core/errors.zig` makes `CallbackError = HostError =
RuntimeError || {... AntivirusInterference, DiskQuota, ...}`, so every
dispatch-boundary function is typed as able to return filesystem errors,
exhaustive switching over the set is impractical, and
`builtin_dispatch.zig` carries 14 `@errorCast` narrowings to hold the line.
Idiomatic target: host callbacks return a small transport set; the boundary
converts std errors into a thrown JS exception (helper on `JSContext`)
before returning. Staged: (1) inventory which std errors actually flow
today (probe: exhaustive switch at the adapter), (2) add the conversion
helper, (3) shrink `CallbackError` under the approved 0.2.0-dev breaking
window, (4) delete the `@errorCast` adapters. Gate: suite + test262;
**AB** (`builtin_dispatch` is on the call chain).
  **Inventory done 2026-08-22** (lane report
  `.scratch/q16-hosterror-inventory-2026-08-22.md`, gitignored; this
  summary is the durable record): the union adds **48** members. 33 have
  producer edges — all 31 non-OOM members of `ReadFileAllocError` via the
  module file loader, `WriteFailed` from the output writer, and the
  engine's `OperationUnsupported` sentinel; 26 are ordinary-host
  reachable; 15 have no producer at all. Current JS-facing behavior:
  `FileNotFound` maps to a useful ReferenceError; everything else
  collapses to an empty-message `Error`; two seams leak raw Zig errors to
  the embedder (the legacy `hostCallOutput` arm, and module/TLA stall
  `OperationUnsupported`). Confirmed hazard: `nativeFromHostError` returns
  the exception sentinel without installing a pending exception for the 48
  unmapped members — Debug asserts, Release carries a sentinel with no
  exception. The `DynamicImportError` name has also contaminated unrelated
  public signatures (`Object.getOwnProperty`/`getProperty`,
  `installStandardGlobals`, `AppendStringError`, `binding.PropNameID`).
  **Ruling (driver, 2026-08-22): proceed as a staged correctness change**
  in the report's order — (1) exec-owned exhaustive conversion helpers,
  convert the writer and module-I/O seams, and make `nativeFromHostError`
  fail closed; (2) drop std members from `HostError`/`DynamicImportError`
  and repair the contaminated signatures; (3) thread realm context through
  the collection callback seam and shrink `CallbackError` to the
  seven-member hard/control transport (no runtime-derived current-context
  — Q12's rejection stands); (4) delete the 14 `@errorCast` adapters.
  Invariant throughout: every exception sentinel has a pending JS
  exception, and no std/backend error name crosses an engine boundary
  unconverted. Gates: stages 1-2 suite + test262; stages 3-4 add **AB**.
  **Stage 1 done 2026-08-22** (`f1c3c655`): exhaustive `HostIoError`
  conversion authority in exception_ops (concrete producer sets, so a
  stdlib change fails to compile); both output arms and all four module
  read sites convert at the seam; stalls become
  `InternalError: module host made no progress`; `nativeFromHostError`
  fails closed with a terminal assert that the sentinel has a pending
  exception. Red-first evidence: the legacy WriteFailed arm and an
  arbitrary host error previously **panicked with 'invalid error code'**
  — worse than the inventory's predicted inconsistency. Suite 2325/1/0,
  test262 delta 0; driver re-probed import mappings on the shipped
  binary (missing file keeps the pathful ReferenceError, a directory now
  yields `Error: IsDir` instead of an empty message).
  **Stage 2 done 2026-08-22** (`2279e4e3` pre-rebase, landed via rebase):
  `HostError` = `RuntimeError` (48 std/backend members deleted);
  `DynamicImportError` = runtime set + AccessDenied/PermissionDenied/
  Unexpected; the four contaminated signatures repaired; fixed-capacity
  formatters discharge capacity errors locally. Red type-test first
  (HostError equality), then green. Gates: suite 2326/1/0, test262 delta
  0, checkpoint 26/26, borrowed atoms 0. `.text` moved −1,052 B so the
  lane escalated to rule-2 A/B on its own: composite **1.0033** = PASS
  (in the [0.995,1.005] band); Crypto +1.78% exceeded the generic ±1.5%
  per-suite envelope in the positive direction with a co-tenant-loaded
  field (zig + fun builds) — accepted as a positive-direction anomaly,
  clean-field measurement requested for the Stage 3/4 A/B. Driver ran
  the combined-tree batch gate (both lanes' work together) after rebase:
  suite + test262 green. CallbackError and the 14 casts intentionally
  untouched (Stages 3-4).
  **Stages 3+4 done 2026-08-22 (`8660029b` pre-rebase) — Q16 CLOSED.**
  `CallbackCallFn` takes an explicit `*JSContext` (doc comment forbids
  runtime-global current-context recovery, honoring Q12); ordinary
  failures materialize as a realm-correct pending exception inside
  `collection_adapter` before crossing the seam; `CallbackError` is
  exactly the seven hard/control members; `Native*Fn` narrowed from
  `anyerror` to `HostError`; **builtin_dispatch `@errorCast` 14 → 0**.
  Red-first: the cross-realm test failed on
  `callback_realm.hasException()` pre-fix, and post-fix the thrown
  TypeError carries the callback realm's prototype, not the caller's.
  Gates: suite 2328/1/0, test262 delta 0, checkpoint 26/26, rule-2 A/B
  **1.0012** (in band; Crypto +1.57% positive excursion — second
  consecutive positive Crypto outlier across the Stage 2 and Stage 3/4
  measurements, possibly a real error-path win; field had immovable
  co-tenant fun processes pinned 0-19, noted). Residual out of scope:
  ~21 pre-existing `@errorCast` in other files (string_builtin_ops 13,
  object.zig 3, ...) — a separate, older population.
  The invariant now holds by type: no std/backend error name can cross
  the callback boundary, and a sentinel always has a pending exception.

**Q17. Unreachability without evidence.**
  **Done 2026-08-22** (`7ff86866`): all three site families got invariant
  comments after the lane read the code to confirm each claim — realm
  bootstrap fills the cached slots from constructor prototypes; cfg oracle
  diagnostics write to caller-sized fixed buffers (comment records the
  extend-on-growth duty); the `NoFail` trace wrappers are instantiated only
  with void-returning visitors. Comments only, no asserts needed; identity
  cmp=0 within lineage; test-core 345 / test-exec 492 green.
  Original item: Debug-assert plus a one-line
invariant comment at: `runtime.zig`
`invalidateContextStandardArrayPrototype` (two `Object.expect(...) catch
unreachable` on `cached_values` slots — the realm-init invariant is real
but unstated); `compiler/cfg.zig`'s 32 `writer.print(...) catch
unreachable` dump sites (one comment at the dump entry stating the writer
contract, or convert the dump family to `try`); the
`traceChildEdgesNoFail` → `traceChildEdgesFallible(...) catch unreachable`
pair (`shape.zig`, `core/object.zig` — state why the fallible authority
cannot fail on that path). Gate: identity (asserts Debug-only; use the Q7
pattern).

**Q18 — done 2026-08-22** (`040f2c43`, post-rebase): promise_ops
4,766 → 4,103. Atomics waitAsync (214 lines) joined `atomics_ops`;
sync/async explicit-resource-management (458 lines) joined
`disposable_ops`; Reflect turned out to be already fully extracted —
only a stale private back-reference remained, deleted. 32 compat
aliases, zero external call-site churn, moved bodies md5-verified
verbatim. Headers updated to match reality on both ends. `.text`
+608 B ruled the known anonymous-symbol bistable basin by follow-up
same-source sampling. Original item:
**Q18. `promise_ops.zig` is four modules wearing one name.** Promise
combinators + Atomics + Reflect glue + Disposable share the file plus a
68-line re-export alias wall. Cold split candidate (same shape as Q11 T1:
lift verbatim, alias back, zero call-site churn) — or at minimum the Q15
header must say what actually lives there. Needs an owner ruling on split
vs document. Gate if split: suite (cold file) per the 2026-08-22 tiers.

**Q19 (STATUS defect #1) — done 2026-08-22** (`a1ead092`), driver-executed
after two lane sessions hit vendor refusals and a context limit on the same
item. Root: all three simple-teardown arms in `inline_calls.zig` read
`frame.function.openVarRefCount()` *after* `frame.current_function.free(rt)`;
when the function object holds the bytecode's last reference (dynamic
`Function(...)`), the read is a use-after-free. Method worth reusing:
  1. the historical abort reproduces on `47cf81ef` (restore the collection
     constructors test to `sharedTestEngine`, run `test-builtins`) — the
     shared engine matters only for allocation history, not generators;
  2. **making an `inline` accessor `noinline` is how you name a reader whose
     frames the optimizer erased** — three probe rounds guessing at call sites
     (fusion builder, apply-forward analyzer, publish path) all missed; one
     `noinline` gave the answer immediately;
  3. on a tree where the UAF no longer faults, a destroy witness compared
     against the pointer proves the defect is latent rather than fixed — and
     that same witness is **not** a durable guard (address reuse makes it fire
     after the fix), so the guard shipped is the ordering comment plus a
     JS-level regression test.
Gates: suite 2332/1/0, test262 delta 0, rule-2 A/B 0.9994 / 1.0004 over two
samplings.

**Q20 (STATUS defect #2) — closed 2026-08-23** (`9c341306` + `17808d50`,
realm-b grok lane). Not an engine defect: `JSContext.destroy` is one
`gc.release` of the caller's host reference (verified at `context.zig:833`),
matching `JS_FreeContext`, while property-slot realm edges
(`AutoInitSlot.realm_and_id`) carry their own `gc.retain`. The recorded
reproduction — walking the children `$262.createRealm()` left behind and
destroying them — is a *second* host release of a reference the realm record
already owns, i.e. the double-free shape; that undercount is what made cycle
mark hit `rc == 0`. Regression tests pin the correct shapes (cross-realm
stolen `Array.prototype`, newest-first and oldest-first teardown, createRealm
leftovers without a child destroy).
Driver additions beyond the lane's own finding, because "the caller used it
wrong" only counts if the next caller can't:
  * **the ownership rule is now in `docs/public-api-contract.md`** (who owns
    the create-ref, that `destroy` is not "tear down this realm", the
    `contextForGlobal` / `context_head` prohibition and its consequence, and
    `RealmRef.retain` as the supported way to take another reference) —
    it was documented nowhere, while both `JSContext.destroy` and
    `contextForGlobal` are public;
  * **a Debug/ReleaseSafe `host_api_release_consumed` flag** makes a second
    host release assert *at the call site* instead of surfacing as a distant
    GC assert later. One bool, present in all modes so layout matches;
  * **the shared test tier now tears down at process exit** (atexit: restore
    the baseline, release the snapshot's extra retains — VARREF snapshot slots
    alias the live cell, so drop the extra retain without `slot.destroy` —
    then destroy only the host-owned main context). ~400 tests thereby enter
    the `context_head` and `allocation_count` asserts. **Driver live-fire
    verified the guard has teeth**: a deliberate 64-byte allocator imbalance
    in a shared-engine test panics on `allocation_count` at teardown; the lane
    had only reported "no leaks found", which is not the same claim.
Gates: suite 2337/1/0, test262 delta 0, leak census 1524 (two passes).

### G — GC refactor preparation (opened 2026-08-23)

Groundwork so the coming GC refactor has a safety net, honest instruments,
and a code shape where a missed edge is visible. Nothing here changes GC
policy; that is the refactor itself.

**G1. Three defects in the GC instrument panel.** (First pass at this item
reported the panel as mostly dead; that was a bad grep — the writes use
saturating `+|=`. Corrected findings, each verified at the write site:)
  * **`cycles_collected` is a lie**: `recordSuccess` (`gc.zig:1509`) assigns
    it `result.freed_objects`, the same value as `freed_objects` on the line
    above. "Cycles collected" and "objects freed" are different quantities;
    `CollectionResult` carries no cycle count to assign. Nothing reads the
    field. Either count real cycles in the collector or delete it — do not
    ship a metric whose name misdescribes its value into a GC refactor.
  * **`rc_inc` / `rc_dec` are dead** — zero references anywhere. They cannot
    be implemented as-is either: refcount traffic is the hottest path in the
    engine and a counter there is not cost-neutral (2026-08-11 ruling).
    Delete, or gate behind an explicit diagnostic build.
  * **`collections`** (`:532`) has no write and no read; only the unrelated
    `failed_collections` does.
The live counters are `cycle_gc_count`, `cycle_gc_time_ns`,
`last_collection_time_ns`, `freed_objects`, `failed_collections`,
`last_failure` and `zero_ref_drains`.
  **Done 2026-08-23** (`a6dc84fb`): the four dead/misdescribed fields
  deleted; survivors document their write sites. Two grep lessons on the
  way, both worth carrying into the refactor: the writes use saturating
  `+|=` (a `+=`-only scan reported the whole panel as dead), and
  `collections` is written from `object_gc.zig`, not `gc.zig` — **a
  dead-field claim needs a tree-wide scan and every assignment spelling**.
  The identity gate did *not* hold (the deleted assignment was live code and
  the struct shrink moves `Registry` offsets), so the item escalated to
  rule-2 A/B: composite **1.0043**, every suite inside its envelope.

**G2. GC state is observable from an embedding, but not from a real
workload.** (Two corrections to this item's first draft, both mine: the
embedding accessor *does* exist — `JSRuntime.gcStats()`
(`runtime.zig:2711`), public and re-exported as `zjs.JSRuntime`; and the
panel it returns is *complete* — the nine fields `Registry.statsSnapshot`
leaves at their defaults are all filled by `gcStats` afterwards, which is
why core-suite tests can assert `weak_ref_count == 8`. Judging a field dead
from one producer is how both errors happened.)
What is genuinely missing is a way to read those numbers from a real script
run: the CLI has no flag, so tuning the collector against an actual workload
means writing a Zig test instead of running the shipped binary. Direction:
a `--gc-stats` flag that prints the honest subset (collections, completed
rounds, elapsed, freed objects, failures, live/peak bytes) after execution.
Gate: suite; CLI smoke; no new pub API surface expected.

**G3. Hot mark arms and the authority trace have no consistency guard.**
`markOrdinaryObjectHot` / `markFastArrayHot` (`object_gc.zig`) hand-enumerate
their child edges; the authority is `Object.traceChildEdgesFallible`. Q1 was
exactly this drift (fast-array arm missed the iterator-next cache edge → an
uncollectable cycle, invisible to test262 and to the leak checker, which
only catches destroy-side misses). The fix added two lines and left no
mechanism. In flight on the proto-a lane: a deterministic edge-coverage
guard comparing the arms against the authority, proven by deletion probes.

**G4 (parked from Q11 T2). Move each payload's trace arm beside its destroy
method** so a missing pair is visible while writing the code rather than
after a leak report. Hot file, so it lands under **AB** + pad lineage; it
should follow G3's guard, not precede it.

## Standing discipline (carried from prior campaigns, applies to every item)

- Deletion-only changes: A/B ratio alone cannot judge them; pair with the
  pad lineage (0.9956-was-LAYOUT case).
- Fast-path guard changes need a QuickJS differential run, not just the
  suite (two collection defects shipped green under test262).
- After narrowing a guard, prove the fast path still fires
  (`if (len > 0) @panic(...)` probe form).
- Hot-arm bodies are never shared with cold paths; merging call layers has
  fattened frames three times.
