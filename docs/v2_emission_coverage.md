# compiler-v2 emission coverage (QCP-1 L3)

Status: normative for the L3→L4 hand-off on `compiler-v2-qjs`.
Line numbers cite the tree that introduced this document; the cited **function
names** are the stable anchors when they drift.

## 0. Why this gate exists

During a v2 parse (`-Dzjs_compiler=v2` or `dual`) every code append is supposed
to reach `compiler_v2.Builder`. Several parser constructs still append to the
**legacy** stream while `State.emit_v2` is true. Because the shared emit helpers
those constructs also call (`emitScopeGetVar`, `emitScopePutVar`,
`emitScopeGetVarUndef`, `emitStringLiteralValue`, `parseAssignExpr`) **are**
v2-aware, the result is not "a construct that stayed legacy" — it is one
construct writing two interleaved half-streams, neither of which describes the
program. That miscompiles silently:

| source | legacy build | v2 build (before L3) |
| --- | --- | --- |
| `enum E{A,B}; console.log(E.A,E.B,E[0])` | `0 1 A` | `TypeError: cannot read property 'A' of undefined` |
| `namespace N{export const x=41}; console.log(N.x)` | `41` | `TypeError: not a function` — reported at line 7 of a 1-line file |

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
  gate — strictly stronger, and it names the construct.
* **Attribution** is exact, not heuristic: `State.legacy_emission_scope` (a
  `coverage.LegacyConstruct`, `void` in ReleaseFast) is set by a narrow
  `pushLegacyEmissionScope` / `popLegacyEmissionScope` pair around each declared
  fallback. Scopes deliberately drop back to `.none` around calls into shared
  sub-parsers, so an unrelated hole deeper in the parse can never be absorbed by
  a neighbour's allowance.
* **THE GATE.** An in-v2-scope legacy emission whose construct is `.none` or is
  not on `coverage.legacy_allowlist` **panics by default**, after dumping a
  symbolized stack trace. Setting `ZJS_V2_EMISSION_COLLECT=1` downgrades the
  panic to accumulation so one run reports the whole list instead of dying on the
  first offender; the deduplicated sites and their traces are printed by
  `coverage.dumpReport()` (wired to an `atexit` hook in `src/cli/zjs.zig` and to
  the corpus test).

`src/compiler_v2/test_entry.zig` — `parseAndCompileV2TestProgram()` is the single
parse entry for compiler-migration-relevant tests. It selects the backend from
the **build**, never from a per-test flag, and it is the only place
`beginV2ProgramEmission()` is called on the test side, so a future syntax test
cannot re-open this hole by forgetting a flag. `src/tests/parser.zig`
(`parseRawTSProgram`) and the five TypeScript execution tests in
`src/tests/exec.zig` (via `helpers.evalTypeScriptChecked`) route through it.

## 2. THE AUTHORITATIVE LIST

Every construct that still emits through legacy in v2 mode. This list is the
definition of done for L4: **L4 is complete when `coverage.legacy_allowlist` is
empty and the `LegacyConstruct` enum has only `.none`.**

### 2.1 `ts_enum` — `parseEnumDeclaration` (`src/parser.zig:13569`)

Reachable from: **TypeScript source.** 11 ungated legacy emission sites plus one
absolute-PC forward-jump operand write:

| file:line | emission |
| --- | --- |
| `src/parser.zig:13587` | `emitOp(dup)` |
| `src/parser.zig:13588` | `emitForwardJump(if_true)` — legacy absolute-PC jump |
| `src/parser.zig:13589` | `emitOp(drop)` |
| `src/parser.zig:13590` | `emitOp(object)` |
| `src/parser.zig:13591` | `patchForwardJump` — writes the absolute target of 13588 |
| `src/parser.zig:13619` | `emitOpAtom(put_field)` — string-initializer member |
| `src/parser.zig:13664` | `emitOp(swap)` |
| `src/parser.zig:13665` | `emitOp(dup)` |
| `src/parser.zig:13667` | `emitOp(swap)` |
| `src/parser.zig:13668` | `emitOpAtom(put_field)` — `Enum["Member"] = value` |
| `src/parser.zig:13670` | `emitOp(put_array_el)` — `Enum[value] = "Member"` |
| `src/parser.zig:13688` | `emitOpAtom(put_field)` — re-export of the enum into an enclosing namespace |

Observed at runtime: 17 byte events for `enum E{A,B}`; 36 across the corpus
(snippets `enum Direction { Up, Down = 4, Name = 'name' }` and
`const enum Flag { A = 1, B = 2 } …`).

### 2.2 `ts_namespace` — `parseNamespaceDeclarationWithIdent` (`src/parser.zig:13698`)

Reachable from: **TypeScript source.** 7 ungated legacy emission sites plus one
absolute-PC forward-jump operand write:

| file:line | emission |
| --- | --- |
| `src/parser.zig:13715` | `emitOp(dup)` |
| `src/parser.zig:13716` | `emitForwardJump(if_true)` — legacy absolute-PC jump |
| `src/parser.zig:13717` | `emitOp(drop)` |
| `src/parser.zig:13718` | `emitOp(object)` |
| `src/parser.zig:13719` | `patchForwardJump` — writes the absolute target of 13716 |
| `src/parser.zig:13745` | `emitOpAtom(put_field)` — nested `A.B` binding |
| `src/parser.zig:13753` | `emitOpAtom(put_field)` — nested-form re-export into the parent namespace |
| `src/parser.zig:13786` | `emitOpAtom(put_field)` — block-form re-export into the parent namespace |

Observed at runtime: 5 byte events for `namespace N{export const x=41}`; 27
across the corpus (basic, nested `A.B`, exported members, declaration merging).
Note the statement body of a namespace is **not** covered by this allowance —
`parseNamespaceStatement` runs with the scope reset to `.none`, so ordinary JS
inside a namespace is gated normally.

### 2.3 `ts_namespace_class_export` — `parseClass` (`src/parser.zig:20888`, emission at `21165`) — **SURPRISE**

Reachable from: **TypeScript source** (`namespace N { export class C {} }`).
1 ungated legacy emission:

| file:line | emission |
| --- | --- |
| `src/parser.zig:21165` | `emitOpAtom(put_field)` — re-export of the class into the enclosing namespace |

**This is not an unmigrated construct — it is a migration omission inside an
otherwise fully migrated one.** The identical `if (s.namespace_export)`
re-export block in the variable-declaration path (`src/parser.zig:15989`) and in
the function-declaration path (`src/parser.zig:17719`) both carry the
`if (v2_available and s.emit_v2) v2FEmitAtomOpOwned(...) else s.emitOpAtom(...)`
pair. `parseClass`'s copy does not. Three near-identical blocks, one missing its
v2 leg — exactly the failure mode that survives review and that no
behaviour-level test notices. It was found by the L3 gate on the first run of the
corpus (default mode: hard panic with `construct=none`; collect mode:
`legacy_in_v2_unallowed=4` from 2 byte events at one site).

### 2.4 `using_declaration_in_for_of` — `parseForInOf` (`src/parser.zig:16072`, emission at `16147`)

Reachable from: **ECMAScript source** (`for (using x of xs) {}`).
1 ungated legacy emission:

| file:line | emission |
| --- | --- |
| `src/parser.zig:16147` | `emitOpU16(put_loc, value_loc)` — stores the iteration value into the anonymous temp |

This is the **sole cause of all 9 v2-mode test262 failures**. Measured on this
tree: `test262-gate` legacy `0/49775 errors, passed 44541, known 25`;
`test262-gate -Dzjs_compiler=v2` `9/49775 errors, passed 44532, known 25`.

## 3. Dead in v2 mode

### 3.1 `parseNewExpr` (`src/parser.zig:10120`, emission at `10135`) — dead in production

```zig
if (s.emit_to_function_def) {
    try s.emitScopeGetVar(atom_new_target);   // v2-aware
} else {
    try s.emitOpU8(opcode.op.special_object, 3);   // ungated legacy
}
```

The `else` arm is a legacy emission with no v2 leg, but `emit_to_function_def` is
`true` for **every** production compile: `compile_entry.compileQjsProgram` is the
only production `ParseState` constructor and it uses
`ParseState.initCanonicalRootWithRuntime` (`src/parser.zig:4189`), which passes
`emit_root_to_function_def = true`. Only the test-only `ParseState.init` leaves
it false. Verified empirically: `function f(){ return eval("new.target"); }` and
`new f()` under a Debug v2 build report `legacy_in_v2_scope=0`.

L4 should still delete or migrate this arm — a dead ungated emitter is a trap for
whoever next changes the root-emitter policy — but it does not miscompile
anything today.

### 3.2 Legacy-only twins are not findings

41 further functions contain ungated legacy emissions but are unreachable in v2
mode because their only call site sits in the `else` of a
`v2_available and …emit_v2` guard or after an early-return v2 dispatch
(`emitYieldStarDelegation` vs `emitYieldStarDelegationV2`, the legacy halves of
`parseDelete` / `prepareCallReference` / `patchLabelBreaks` /
`patchLabelContinues` / `reattributeReturnTailCallSource`, …). These are the
intended legacy implementations and are correct as they stand.

## 4. What the gate proves, and what it does not

Evidence collected on this tree:

* **Real-world ECMAScript is clean.** Compiling Closure `base.js` + jQuery 1.7.2
  (`mc1.js`) under a Debug v2 build: `v2_construct_emitted=37556`,
  `legacy_in_v2_scope=0`. Not a single legacy emission in ~37.5k emission events.
* **The 45-snippet production-surface corpus** (`compiler_v2.coverage: production
  constructs never fall back to legacy emission`, `src/compiler_v2/tests.zig`)
  reaches only the four allowlisted constructs:
  `v2_construct_emitted=1148 legacy_construct_emitted=112 legacy_in_v2_scope=67
  legacy_in_v2_unallowed=0`, with `ts_enum=36 ts_namespace=27
  ts_namespace_class_export=2 using_declaration_in_for_of=2`.
  1 of 45 snippets is skipped (`new.target;` at program top level —
  `new_target_allowed` is false for a script root, so it is a parse error, not an
  emission).
* **Static cross-check.** An independent lexical survey of `src/parser.zig`
  (mask strings/comments → brace-match functions → mark
  `v2_available and …emit_v2` true-branches, `else` legs and early-return
  dispatch → fixed point over the emission primitives → reachability from the
  v2 parse roots over ungated edges) finds exactly the five constructs in §2/§3.1
  and nothing else. The runtime gate confirmed four of the five; the fifth
  (§3.1) is dead.

Limits, stated plainly:

* The gate observes **emission**, not correctness. A construct that emits only
  through v2 can still emit the wrong thing; that is what the dual comparator and
  test262 are for.
* Corpus reachability is the corpus's, not the language's. A construct nothing in
  the corpus or the Zig suite parses cannot be reported by the runtime gate — the
  static survey exists to cover that gap, and the default hard panic means any
  future run that does reach one fails loudly rather than miscompiling.
* `legacy_in_v2_unallowed` is a violation count, not an instruction count: one
  instruction can bump it through several funnels. The only value that ever
  passes is 0.

## 5. Running it

```bash
Z=zig
# hard gate (default): any undeclared legacy emission in v2 mode panics
$Z build test-compiler-v2 -Dzjs_compiler=v2

# whole-list mode: accumulate instead of dying on the first offender
ZJS_V2_EMISSION_COLLECT=1 $Z build test-compiler-v2 -Dzjs_compiler=v2

# any script, with an at-exit report
$Z build zjs-dev -Dzjs_compiler=v2
ZJS_V2_EMISSION_COLLECT=1 ./zig-out/bin/zjs-dev file.ts
```

## 6. ReleaseFast erasure

`coverage.enabled` is false in ReleaseFast/ReleaseSmall and every reference is
`comptime`-gated. Verified on the ReleaseFast `-Dzjs_compiler=v2` binary:

* `nm -C` coverage symbols: **0**
* `.rodata` occurrences of `ts_enum|ts_namespace|using_declaration_in_for_of|QCP-1 L3|ZJS_V2_EMISSION`: **0**
* `strings … | grep -c ZJS_V2_EMISSION_COLLECT`: **0**; `QCP-1 L3`: **0**; `legacy_in_v2`: **0**
* The only whole-binary hits for a construct tag are two DWARF entries
  (`.debug_str`, `.debug_pubnames`) — type names, no `.rodata` or `.text` bytes.

Compile-micro (`mc.js`: 240 compiles of Closure `base.js` + jQuery 1.7.2),
ReleaseFast `-Dzjs_compiler=v2`, `taskset -c 10` on the X925 core, all four
builds produced in the **same** worktree so `.text` layout drift is not confounded
with the change:

| build | instructions (mean of 4) | ratio vs base |
| --- | ---: | ---: |
| base (`302d81f0`) | 19,108,203,032 | 1.00000 |
| base − the 9 replaced `assert(!(v2_available and …))` | 19,107,071,656 | 0.99994 |
| L3 (this tree) | 19,095,657,122 | 0.99934 |
| L3 + comment-only edit of `src/parser.zig` (negative control) | 19,096,425,598 | 0.99938 |

The instrumentation adds **nothing**: the L3 build runs 0.066 % *fewer*
instructions than base. The measured delta is codegen drift, not instrumentation
— the negative control bounds a trivial-rebuild at 0.004 %, and removing the nine
asserts alone accounts for 0.006 % (in ReleaseFast `std.debug.assert` lowers to an
`unreachable`-backed optimizer assumption, so deleting one changes inlining and
branch folding in the hot emission funnels). The residual is a reduction, so it
cannot be an added cost, and the symbol/string evidence above shows there is no
coverage code or data in the binary to execute.

## 7. Definition of done for L4

For each entry in `coverage.legacy_allowlist`:

1. give every listed emission site a v2 leg (`v2FEmit*` / `Builder` +
   `LabelId`), including the absolute-PC forward-jump pairs in §2.1 and §2.2,
   which must become `newLabel` / `emitJump` / `bindLabel`;
2. delete the `pushLegacyEmissionScope` / `popLegacyEmissionScope` annotation;
3. delete the `LegacyConstruct` tag and its allowlist entry — the comptime check
   in `coverage.zig` refuses a tag without exactly one entry, so the two must move
   together;
4. re-run `ZJS_V2_EMISSION_COLLECT=1 zig build test-compiler-v2 -Dzjs_compiler=v2`
   and confirm the construct's counter is 0 and `legacy_in_v2_unallowed` is 0;
5. for `using_declaration_in_for_of`, additionally confirm
   `test262-gate -Dzjs_compiler=v2` goes from 9 errors to 0.

Also fold in §3.1 (`parseNewExpr`) even though it is dead, and — for `parseClass`
in §2.3 — copy the v2 leg that already exists at `src/parser.zig:15989` and
`src/parser.zig:17719` rather than inventing a third spelling.

When the allowlist is empty, `legacy_construct_emitted` observed during any v2
parse must be 0, and the four-layer switch gate's L3 requirement is met.
