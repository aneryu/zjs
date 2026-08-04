# compiler-v2 emission coverage (QCP-1 L3 gate, L4 migration)

Status: normative for the L4→switch hand-off on `compiler-v2-qjs`.
Line numbers cite the tree that introduced this document; the cited **function
names** are the stable anchors when they drift.

**The allowlist is empty.** `coverage.legacy_allowlist` is `[_]AllowlistEntry{}`
and `coverage.LegacyConstruct` has only `.none`, so *any* legacy emission during
a v2 parse is now an unconditional hard panic naming its stack. §2 records what
was migrated to get there; §7 records the bars that were met.

## 0. Why this gate exists

During a v2 parse (`-Dzjs_compiler=v2` or `dual`) every code append is supposed
to reach `compiler_v2.Builder`. Several parser constructs still appended to the
**legacy** stream while `State.emit_v2` was true. Because the shared emit
helpers those constructs also call (`emitScopeGetVar`, `emitScopePutVar`,
`emitScopeGetVarUndef`, `emitStringLiteralValue`, `parseAssignExpr`) **are**
v2-aware, the result was not "a construct that stayed legacy" — it was one
construct writing two interleaved half-streams, neither of which describes the
program. That miscompiled silently:

| source | legacy build | v2 build (before L3) | v2 build (after L4) |
| --- | --- | --- | --- |
| `enum E{A,B}; console.log(E.A,E.B,E[0])` | `0 1 A` | `TypeError: cannot read property 'A' of undefined` | `0 1 A` |
| `const enum F{A=1,B=2}; console.log(F.A,F.B)` | `1 2` | `TypeError: cannot read property 'A' of undefined` | `1 2` |
| `namespace N{export const x=41}; console.log(N.x)` | `41` | `TypeError: not a function` — reported at line 7 of a 1-line file | `41` |
| `namespace M{export class C{v(){return 7}}}; console.log(new M.C().v())` | `7` | `TypeError: cannot read property 'C' of undefined` | `7` |
| `for (using r of [d1,d2]) …` | `body,1,body,2` | `SyntaxError: StackMismatch` | `body,1,body,2` |

**No pre-L3 gate caught this.** The TypeScript parser tests built a `ParseState`
directly (`parseRawTSProgram`) and never called `beginV2ProgramEmission`, so
`emit_v2` stayed false even in a v2 build; the TypeScript execution tests only
covered type erasure. A v2 switch would have shipped an engine that miscompiles
`enum` and `namespace` with a fully green test262 **and** a fully green Zig
suite.

## 1. The mechanism

`src/compiler_v2/coverage.zig` — Debug/ReleaseSafe only
(`coverage.enabled = builtin.mode == .Debug or .ReleaseSafe`), every call site
`comptime`-folded away in ReleaseFast/ReleaseSmall.

* **Counters.** `v2_construct_emitted` (one per `Builder` emission event, counted
  in the single `Builder.reserveCode` funnel), `legacy_construct_emitted` (one
  per legacy byte-append event), `legacy_in_v2_scope` (legacy emissions that
  happened while `emit_v2` was true), `per_construct[...]`, and the gate value
  `legacy_in_v2_unallowed`.
* **Funnels.** `appendBytesNoSource` and `appendBytesNoSourceAssumeCapacity`
  count byte events; `appendBytesAt`, `emitSourcePosAndLoc`, `truncateCode` and
  `publishParserLabelTarget` perform the gate check without counting (they route
  into the two appenders, or mutate the legacy stream without appending). Every
  pre-L3 `std.debug.assert(!(v2_available and …emit_v2))` was replaced by this
  gate — strictly stronger, and it names the construct. `grep -c
  'std.debug.assert(!(v2_available' src/parser.zig` is 0.
* **Attribution** is exact, not heuristic: `State.legacy_emission_scope` (a
  `coverage.LegacyConstruct`, `void` in ReleaseFast) is set by a narrow
  `pushLegacyEmissionScope` / `popLegacyEmissionScope` pair around each declared
  fallback. **No call sites remain** — the pair is retained as the mechanism a
  future stage would use to declare a temporary fallback (which would also have
  to re-add the `LegacyConstruct` tag and its allowlist entry, since the
  `comptime` check refuses a tag without exactly one entry).
* **THE GATE.** An in-v2-scope legacy emission whose construct is `.none` or is
  not on `coverage.legacy_allowlist` **panics by default**, after dumping a
  symbolized stack trace. With the allowlist empty that is every in-v2-scope
  legacy emission. Setting `ZJS_V2_EMISSION_COLLECT=1` downgrades the panic to
  accumulation so one run reports the whole list instead of dying on the first
  offender; the deduplicated sites and their traces are printed by
  `coverage.dumpReport()` (wired to an `atexit` hook in `src/cli/zjs.zig` and to
  the corpus test).

`src/compiler_v2/test_entry.zig` — `parseAndCompileV2TestProgram()` is the single
parse entry for compiler-migration-relevant tests. It selects the backend from
the **build**, never from a per-test flag, and it is the only place
`beginV2ProgramEmission()` is called on the test side, so a future syntax test
cannot re-open this hole by forgetting a flag. `src/tests/parser.zig`
(`parseRawTSProgram`) and the five TypeScript execution tests in
`src/tests/exec.zig` (via `helpers.evalTypeScriptChecked`) route through it.

## 2. THE LIST — closed

Every construct that emitted through legacy in v2 mode, and what it became. All
five were migrated with the established per-site fork —
`if (v2_available and s.emit_v2) { <v2 veneer> } else { <legacy arm, unchanged
byte-for-byte> }` — with shared v2-aware helpers (`emitScopeGetVar`,
`emitScopePutVar`, `emitScopeGetVarUndef`, `emitStringLiteralValue`,
`parseAssignExpr`, `appendAnonymousTempLocal`) left **outside** the fork and
called exactly once, as before.

Two rules governed the migration:

1. **Jumps are born as `LabelId`s.** The two `X = X || {}` prologues carried an
   `emitForwardJump` / `patchForwardJump` absolute-PC pair; each became
   `v2FNewLabel` → `v2FEmitJump` → `v2FBindLabel`. No v2 arm computes a PC.
2. **Atom ownership is explicit.** Legacy `emitOpAtom` retains internally
   (`appendAtomOperand` / `retainAtomOperand`); the v2 sink `v2FEmitAtomOpOwned`
   *consumes* a retain, so every migrated `put_field` passes
   `s.function.atoms.dup(atom)`.

### 2.1 `ts_enum` — `parseEnumDeclaration` (`src/parser.zig:13574`) — MIGRATED

Reachable from: **TypeScript source.** 11 emission sites plus one absolute-PC
forward-jump pair:

| emission | v2 arm |
| --- | --- |
| `emitOp(dup)` | `v2FEmitOp(dup)` |
| `emitForwardJump(if_true)` | `v2FNewLabel` + `v2FEmitJump(if_true, skip_label)` |
| `emitOp(drop)` | `v2FEmitOp(drop)` |
| `emitOp(object)` | `v2FEmitOp(object)` |
| `patchForwardJump` | `v2FBindLabel(skip_label)` |
| `emitOpAtom(put_field)` — string-initializer member | `v2FEmitAtomOpOwned(put_field, dup(member_atom))` |
| `emitOp(swap)`, `emitOp(dup)`, `emitOp(swap)` | `v2FEmitOp(...)` ×3 |
| `emitOpAtom(put_field)` — `Enum["Member"] = value` | `v2FEmitAtomOpOwned(put_field, dup(member_atom))` |
| `emitOp(put_array_el)` — `Enum[value] = "Member"` | `v2FEmitOp(put_array_el)` |
| `emitOpAtom(put_field)` — re-export into an enclosing namespace | `v2FEmitAtomOpOwned(put_field, dup(enum_atom))` |

The `pushLegacyEmissionScope(.ts_enum)` annotation and the inner
`pushLegacyEmissionScope(.none)` guard around `parseAssignExpr` are both gone.
Before: 17 byte events for `enum E{A,B}`, 36 across the corpus. After: 0.

### 2.2 `ts_namespace` — `parseNamespaceDeclarationWithIdent` (`src/parser.zig:13727`) — MIGRATED

Reachable from: **TypeScript source.** 7 emission sites plus one absolute-PC
forward-jump pair: the `Namespace = Namespace || {}` prologue (identical shape to
§2.1, same `v2FNewLabel`/`v2FEmitJump`/`v2FBindLabel` triple), the nested `A.B`
binding `put_field`, the nested-form re-export `put_field`, and the block-form
re-export `put_field` — all three now
`v2FEmitAtomOpOwned(put_field, s.function.atoms.dup(...))`.

All three `pushLegacyEmissionScope` annotations are gone (the `.ts_namespace`
one plus the two `.none` guards around the recursive
`parseNamespaceDeclarationWithIdent` call and the `parseNamespaceStatement`
loop; those guards existed only to stop the enclosing allowance from absorbing
an unrelated hole, and there is no enclosing allowance any more).

Before: 5 byte events for `namespace N{export const x=41}`, 27 across the
corpus. After: 0.

### 2.3 `ts_namespace_class_export` — `parseClass` (`src/parser.zig:20927`, emission at `21202`) — MIGRATED

Reachable from: **TypeScript source** (`namespace N { export class C {} }`).
1 emission: `emitOpAtom(put_field)` re-exporting the class into the enclosing
namespace.

**This was not an unmigrated construct — it was a migration omission inside an
otherwise fully migrated one.** The byte-identical `if (s.namespace_export)`
re-export block in the variable-declaration path and in the
function-declaration path both already carried the
`if (v2_available and s.emit_v2) v2FEmitAtomOpOwned(...) else s.emitOpAtom(...)`
pair; `parseClass`'s third copy did not. Three near-identical blocks, one
missing its v2 leg — exactly the failure mode that survives review and that no
behaviour-level test notices. It was found by the L3 gate on the first run of
the corpus (default mode: hard panic with `construct=none`; collect mode:
`legacy_in_v2_unallowed=4` from 2 byte events at one site). The fix is a
character-for-character copy of the existing spelling, deliberately not a third
variant.

Before: 2 byte events across the corpus. After: 0.

### 2.4 `using_declaration_in_for_of` — `parseForInOf` (`src/parser.zig:16111`, emission at `16184`) — MIGRATED

Reachable from: **ECMAScript source** (`for (using x of xs) {}`).
1 emission: `emitOpU16(put_loc, value_loc)` storing the iteration value into the
anonymous temp → `v2FEmitOpU16(put_loc, value_loc)`. `appendAnonymousTempLocal`
and the `iteration_using_value_loc` assignment are not emissions and moved out
of the deleted scope block unchanged.

This was the **sole cause of all 9 v2-mode test262 failures**. Measured on this
tree, before → after:

| gate | before | after |
| --- | --- | --- |
| `test262-gate` (legacy) | `0/49775 errors, passed 44541, known 25` | `0/49775 errors, passed 44541, known 25` |
| `test262-gate -Dzjs_compiler=v2` | `9/49775 errors, passed 44532, known 25` | `0/49775 errors, passed 44541, known 25` |

The **passed count matters**: `0 errors, passed 44532` would have meant nine
tests silently changed status rather than starting to pass.

### 2.5 `parseNewExpr` (`src/parser.zig:10120`, emission at `10137`) — MIGRATED (was dead)

```zig
if (s.emit_to_function_def) {
    try s.emitScopeGetVar(atom_new_target);   // v2-aware
} else {
    try s.emitOpU8(opcode.op.special_object, 3);   // was ungated legacy
}
```

The `else` arm had no v2 leg, but `emit_to_function_def` is `true` for **every**
production compile: `compile_entry.compileQjsProgram` is the only production
`ParseState` constructor and it uses `ParseState.initCanonicalRootWithRuntime`,
which passes `emit_root_to_function_def = true`. Only the test-only
`ParseState.init` leaves it false. It could not miscompile anything, but a dead
ungated emitter is a trap for whoever next changes the root-emitter policy, so it
was given its fork anyway, with a comment naming the two constructors.

## 3. Dead code — reported, not migrated

These are **removals for a future cleanup commit**, not migrations. Adding v2
arms to unreachable code would enlarge the audit surface for nothing.

### 3.1 `parseDeleteSuperReference` (`src/parser.zig:9167`) — no callers anywhere

`grep -rn parseDeleteSuperReference src/` returns exactly one hit: its own
definition. Its ~40 lines contain eight ungated legacy emissions
(`get_super`, `push_atom_value`, `get_super_value`, `call`/`apply`, `drop`,
`push_true`, `push_this`, `drop`) and a `parseCallArgs` call. Its sibling
predicate `isDeleteSuperReference` is likewise uncalled. **Recommend deleting
both.** Note that `emitDeleteSuperError`, which it calls, is *not* dead — it has
a live caller in `parseDelete`'s `get_super_value` case — so a deletion must
keep that function.

### 3.2 `BlockEnv.v2_label_finally` and the four `*NoFinallyCapture` emitters

Tracked as F-5 and F-6 in `docs/compiler_v2_contract.md` §6, both still open,
both benign, both removals. The `v2_label_finally` *field* is never assigned
(only the same-named local in the `TOK_TRY` arm is), and each of
`emitLabelledBreakNoFinallyCapture`, `emitLabelledContinueNoFinallyCapture`,
`emitUnlabelledBreakNoFinallyCapture`, `emitUnlabelledContinueNoFinallyCapture`
occurs exactly once in `src/parser.zig` — its own definition.

### 3.3 Legacy-only twins are not findings

41 further functions contain ungated legacy emissions but are unreachable in v2
mode because their only call site sits in the `else` of a
`v2_available and …emit_v2` guard or after an early-return v2 dispatch
(`emitYieldStarDelegation` vs `emitYieldStarDelegationV2`, the legacy halves of
`parseDelete` / `prepareCallReference` / `patchLabelBreaks` /
`patchLabelContinues` / `reattributeReturnTailCallSource`, …). These are the
intended legacy implementations and are correct as they stand.

## 4. What the gate proves, and what it does not

Evidence collected on this tree, after the L4 migration:

* **The 45-snippet production-surface corpus** (`compiler_v2.coverage: production
  constructs never fall back to legacy emission`, `src/compiler_v2/tests.zig`)
  reports, under `ZJS_V2_EMISSION_COLLECT=1 zig build test-compiler-v2
  -Dzjs_compiler=v2`:

  ```
  v2_construct_emitted=1200 legacy_construct_emitted=45 legacy_in_v2_scope=0 legacy_in_v2_unallowed=0 sites_dropped=0
  ```

  with **no** `fallback construct=` lines at all (before: `legacy_in_v2_scope=67`
  with `ts_enum=36 ts_namespace=27 ts_namespace_class_export=2
  using_declaration_in_for_of=2`). 1 of 45 snippets is skipped (`new.target;` at
  program top level — `new_target_allowed` is false for a script root, so it is a
  parse error, not an emission).

  **On the 45 residual `legacy_construct_emitted`:** that counter counts *all*
  legacy byte events, including those outside v2 scope. `ParseState.init` →
  `initRootEmitter` → `beginFunctionBody` → `emitEnterScope` runs *before*
  `beginV2ProgramEmission()` sets `emit_v2` (test_entry.zig; production
  `compile_entry` has the identical ordering), so each of the 45 corpus cases
  contributes one out-of-scope legacy `enter_scope`; `beginV2ProgramEmission`
  then re-emits `enter_scope` into the Builder, which is the byte the v2 product
  actually uses. 45 is unchanged before and after this migration, and
  `112 − 45 = 67` is exactly the pre-migration `legacy_in_v2_scope`, which is a
  self-consistency check on the accounting. **`legacy_in_v2_scope` is the number
  that must be 0**, not `legacy_construct_emitted`.
* **Real-world ECMAScript is clean.** Compiling Closure `base.js` + jQuery 1.7.2
  under a Debug v2 build: `v2_construct_emitted=37556 legacy_construct_emitted=3
  legacy_in_v2_scope=0` — not a single legacy emission in ~37.5k emission events
  (3 program roots × 1 pre-v2 `enter_scope` each). The 240-compile macro
  (`mc.js`) and 240-run macro (`ma.js`) report `CHECKSUM: 240/240` under
  `-Dzjs_compiler=v2` **and** under `-Dzjs_compiler=dual` with **0**
  `ZJS-DUAL-MISMATCH` lines.
* **Density check on the migrated constructs themselves.** A single-root
  generated TypeScript file of 200 `enum`s (implicit, explicit-numeric, string
  and continuation members), 200 `namespace`s (each exporting a `const`, a
  `class` and an `enum`) and 200 dotted `namespace A.B` declarations, then
  reading every one of them back including reverse mappings, under the Debug v2
  build: `v2_construct_emitted=34213 legacy_construct_emitted=1
  legacy_in_v2_scope=0 legacy_in_v2_unallowed=0`, and the same value (`60900`)
  as the legacy build. The residual legacy count is **1** for a one-root file
  and **3** for the three-root `mc1.js` — it scales with program roots, not with
  construct count, which is the accounting claim above tested rather than
  asserted.
* **Static cross-check.** An independent lexical survey of `src/parser.zig`
  (mask strings/comments → brace-match functions → mark
  `v2_available and …emit_v2` true-branches, `else` legs and early-return
  dispatch → fixed point over the emission primitives → reachability from the
  v2 parse roots over ungated edges) found exactly the five constructs in §2
  and nothing else. All five are now migrated.

Limits, stated plainly:

* The gate observes **emission**, not correctness. A construct that emits only
  through v2 can still emit the wrong thing; that is what the dual comparator,
  the L2 legacy-vs-v2 probes and test262 are for.
* Corpus reachability is the corpus's, not the language's. A construct nothing in
  the corpus or the Zig suite parses cannot be reported by the runtime gate — the
  static survey exists to cover that gap, and with the allowlist empty the
  default hard panic means any future run that does reach one fails loudly rather
  than miscompiling.
* `legacy_in_v2_unallowed` is a violation count, not an instruction count: one
  instruction can bump it through several funnels. The only value that ever
  passes is 0.

## 5. Running it

```bash
Z=zig
# hard gate (default): any legacy emission in v2 mode panics — the allowlist is empty
$Z build test-compiler-v2 -Dzjs_compiler=v2

# whole-list mode: accumulate instead of dying on the first offender
ZJS_V2_EMISSION_COLLECT=1 $Z build test-compiler-v2 -Dzjs_compiler=v2

# any script, with an at-exit report
$Z build zjs-dev -Dzjs_compiler=v2
ZJS_V2_EMISSION_COLLECT=1 ./zig-out/bin/zjs-dev file.ts
```

## 6. ReleaseFast erasure

`coverage.enabled` is false in ReleaseFast/ReleaseSmall and every reference is
`comptime`-gated. Verified on the ReleaseFast `-Dzjs_compiler=v2` binary at L3:

* `nm -C` coverage symbols: **0**
* `.rodata` occurrences of `ts_enum|ts_namespace|using_declaration_in_for_of|QCP-1 L3|ZJS_V2_EMISSION`: **0**
* `strings … | grep -c ZJS_V2_EMISSION_COLLECT`: **0**; `QCP-1 L3`: **0**; `legacy_in_v2`: **0**
* The only whole-binary hits for a construct tag were two DWARF entries
  (`.debug_str`, `.debug_pubnames`) — type names, no `.rodata` or `.text` bytes.

L4 strictly shrinks this surface further: the four construct tags and their four
allowlist entries (with their reason strings) no longer exist in any build mode.

Compile-micro (`mc.js`: 240 compiles of Closure `base.js` + jQuery 1.7.2),
ReleaseFast `-Dzjs_compiler=v2`, `taskset -c 10` on the X925 core, all four
builds produced in the **same** worktree so `.text` layout drift is not confounded
with the change:

| build | instructions (mean of 4) | ratio vs base |
| --- | ---: | ---: |
| base (`302d81f0`) | 19,108,203,032 | 1.00000 |
| base − the 9 replaced `assert(!(v2_available and …))` | 19,107,071,656 | 0.99994 |
| L3 (gate landed) | 19,095,657,122 | 0.99934 |
| L3 + comment-only edit of `src/parser.zig` (negative control) | 19,096,425,598 | 0.99938 |

The instrumentation adds **nothing**: the L3 build ran 0.066 % *fewer*
instructions than base. The measured delta is codegen drift, not instrumentation
— the negative control bounds a trivial-rebuild at 0.004 %, and removing the nine
asserts alone accounts for 0.006 % (in ReleaseFast `std.debug.assert` lowers to an
`unreachable`-backed optimizer assumption, so deleting one changes inlining and
branch folding in the hot emission funnels). The residual is a reduction, so it
cannot be an added cost, and the symbol/string evidence above shows there is no
coverage code or data in the binary to execute.

## 7. Definition of done for L4 — MET

The L3 exit criteria, and how each was met:

1. ~~give every listed emission site a v2 leg, including the absolute-PC
   forward-jump pairs in §2.1 and §2.2, which must become `newLabel` /
   `emitJump` / `bindLabel`~~ — done, §2.1-§2.5;
2. ~~delete the `pushLegacyEmissionScope` / `popLegacyEmissionScope`
   annotation~~ — done, all seven call sites removed; the helper pair is
   retained as an unused mechanism (§1);
3. ~~delete the `LegacyConstruct` tag and its allowlist entry~~ — done;
   `LegacyConstruct` is `{ none }` and `legacy_allowlist` is `[_]AllowlistEntry{}`;
4. ~~re-run `ZJS_V2_EMISSION_COLLECT=1 zig build test-compiler-v2
   -Dzjs_compiler=v2` and confirm every construct counter is 0 and
   `legacy_in_v2_unallowed` is 0~~ — done, §4;
5. ~~for `using_declaration_in_for_of`, confirm `test262-gate
   -Dzjs_compiler=v2` goes from 9 errors to 0~~ — done, §2.4;
6. ~~fold in §2.5 (`parseNewExpr`) even though it is dead~~ — done.

Four-layer switch gate status on this tree:

| layer | requirement | result |
| --- | --- | --- |
| L1 test262 | v2 failures == legacy baseline, *including* the passed count: `0/49775 errors, passed 44541, known 25` | v2 `0/49775 errors, passed 44541, known 25` — identical to legacy on the same tree |
| L2 language extensions | `legacy success == v2 success` for TS enum / const enum / namespace / namespace-exported class / `using` | all five probes byte-identical between the legacy and v2 Debug binaries, and under `dual` |
| L3 emission coverage | zero legacy emission in v2 scope, allowlist empty | `legacy_in_v2_scope=0 legacy_in_v2_unallowed=0`, `legacy_allowlist` empty, no `fallback construct=` lines |
| L4 runtime | `mc.js` / `ma.js` 240/240 under v2 and dual, no `ZJS-DUAL-MISMATCH` | 240/240 ×4, 0 mismatch lines |

Supporting gates, all green on this tree: `zig build test`,
`zig build test -Dzjs_compiler=v2`, `zig build test -Dzjs_compiler=dual`,
`zig build test-oom -Dzjs_compiler=v2`,
`zig build test-core -Dzjs_compiler=v2 -Dzjs_force_gc=true`,
`zig build test-compiler-v2` in all three compiler modes, `zig build zjs` in all
three compiler modes, `zig fmt --check src build.zig docs`.

When a future stage needs a temporary fallback it must re-add a
`LegacyConstruct` tag **and** its allowlist entry together (the `comptime` check
enforces the pairing) and wrap the site in `pushLegacyEmissionScope` — and it
must not land without an exit milestone, because the steady state this document
now describes is an empty allowlist.
