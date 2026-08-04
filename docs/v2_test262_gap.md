# compiler-v2 v2-mode test262 gap taxonomy

QCP-1 stage T262-CLASS. **Analysis only** — nothing in the identity model, the
frozen `Builder` / `SourceSlot` API, the resolver, or any test262 expectation
file changes here. The ruling is *classify first, decide later*: this document
names what diverges and how big each fix is; it applies none of them.

Audited at branch tip `278df5c2` (`compiler-v2-qjs`), Zig 0.16.0. Line numbers
cite that tip; function names are the stable anchors.

---

## 0. The answer first

The v2-mode full gate is **9 errors out of 49775**, re-run here from scratch —
not inherited. The legacy-mode full gate on the same tip, same corpus, same
known-error file is **0 out of 49775**.

```
v2      Result: 9/49775 errors, passed 44532, known 25
legacy  Result: 0/49775 errors, passed 44541, known 25
```

Set-differencing the two failure logs is exact: the v2 log is the legacy log
plus nine lines, and the 25 shared lines are **byte-identical** in both modes.
`44541 − 44532 = 9`. No test passes in v2 that fails in legacy, and no test
fails in v2 for a different reason than in legacy.

**All nine v2-attributable failures are one defect at one line.**

```
src/parser.zig:16086   fn parseForInOf, the `parse_using_decl` arm
    try s.emitOpU16(opcode.op.put_loc, value_loc);
```

It is a legacy-backend emission with no `emit_v2` gate, on a path a v2 parse
reaches. Every one of the nine tests contains a `using` / `await using`
ForDeclaration in a for-of head, and all nine stop at that exact line — proven
by execution, not by reading (§3.3). The fix is a five-line mechanical guard
identical in shape to the correctly-gated sibling 208 lines below it in the
same function. It is **not** applied in this stage.

The 25 remaining failures in the v2 log are the pre-existing engine baseline
carried identically by both backends. They are **not** v2 gaps and are **not**
part of the switch bar (§7, §9).

---

## 1. Method and provenance

Everything below comes from binaries built in one worktree off `278df5c2`,
with `test262/test` and `test262/harness` symlinked from the primary checkout.

| artifact | build | purpose |
| --- | --- | --- |
| `zig-out/bin/run-test262` | `-Dzjs_compiler=v2` | the authoritative v2 gate |
| `zig-out-legacy/bin/run-test262` | `-Dzjs_compiler=legacy` | the baseline gate |
| `zig-out-v2/bin/zjs` | `-Dzjs_compiler=v2`, ReleaseFast | v2 behaviour probes |
| `zig-out-legacy/bin/zjs` | `-Dzjs_compiler=legacy` | legacy behaviour probes |
| `zig-out-v2dev/bin/zjs-dev` | `-Dzjs_compiler=v2`, Debug | fail-loud site attribution |

Both gate runs used the same invocation shape:

```bash
./<prefix>/bin/run-test262 -t 16 -c test262.conf -d test262/test 0 100000 -R <report-dir>
```

Both selected `49775/53293` tests, `3518` excluded, `5209` skipped by feature
(`Temporal` 4602, `source-phase-imports` 230, `import-defer` 229,
`ShadowRealm` 64, `tail-call-optimization` 35, `decorators` 24,
`host-gc-required` 15, `Intl.Era-monthcode` 10). Identical selection, so the
comparison is apples to apples.

Bucket totals:

| bucket | legacy | v2 |
| --- | --- | --- |
| SyntaxError | 7 | 16 |
| TypeError | 2 | 2 |
| Test262Error | 15 | 15 |
| Empty | 1 | 1 |
| **total failed** | **25** | **34** |

The nine extra SyntaxErrors are the entire delta.

Neither summary line carries a `fixed` field. The runner prints it only when
non-zero (src/cli/run_test262.zig:113), so `fixed` is zero in both modes: no
test listed in `test262_errors.txt` started passing under v2. Together with the
empty legacy-only side of the set difference, that pins the relation exactly —
the v2 result is the legacy result plus nine failures and nothing else.
(`regressed` is likewise absent because `--regression-baseline` was not passed;
it is not evidence either way.)

---

## 2. The authoritative v2-attributable list

All nine, with the source construct and the diverging v2 code path. Every row
was re-derived by running the test itself; none is inherited from a prior
stage's report.

| # | test path (under `test262/`) | reported error | test flags | head construct | diverging v2 path |
| --- | --- | --- | --- | --- | --- |
| 1 | `test/language/statements/for-of/head-using-fresh-binding-per-iteration.js` | `SyntaxError: StackMismatch` | — | `for (using x of …)` | `parser.zig:16086` |
| 2 | `test/language/statements/for-of/head-using-bound-names-fordecl-tdz.js` | `SyntaxError: StackMismatch` | — | `for (using x of …)` | `parser.zig:16086` |
| 3 | `test/language/statements/using/syntax/using-invalid-assignment-statement-body-for-of.js` | `SyntaxError: StackMismatch` | — | `for (using x of …)` | `parser.zig:16086` |
| 4 | `test/language/statements/for-of/head-await-using-bound-names-fordecl-tdz.js` | `SyntaxError: StackMismatch` | `async` | `for (await using x of …)` | `parser.zig:16086` |
| 5 | `test/language/statements/await-using/syntax/await-using-invalid-assignment-statement-body-for-of.js` | `SyntaxError: StackMismatch` | `async` | `for (await using x of …)` | `parser.zig:16086` |
| 6 | `test/language/statements/await-using/syntax/await-using-valid-for-await-using-of-of.js` | `SyntaxError: StackMismatch` | — | `for (await using of of …)` | `parser.zig:16086` |
| 7 | `test/language/statements/await-using/initializer-Symbol.dispose-called-at-end-of-each-iteration-of-forofstatement.js` | `SyntaxError: StackMismatch` | `async` | `for (await using _ of …)` | `parser.zig:16086` |
| 8 | `test/language/statements/await-using/initializer-Symbol.asyncDispose-called-at-end-of-each-iteration-of-forofstatement.js` | `SyntaxError: StackMismatch` | `async` | `for (await using _ of …)` | `parser.zig:16086` |
| 9 | `test/language/statements/for-of/head-await-using-fresh-binding-per-iteration.js` | `SyntaxError: StackMismatch` | `module` | `for (await using x of …)` | `parser.zig:16086` |

The reported error text for #9 carries a position (`…:241:1`) only because the
runner prepends the harness before compiling; the site is the same.

Minimal reproduction — two lines, no harness:

```js
const obj = { [Symbol.dispose]() {} };
for (using x of [obj]) { }
```

```
v2      SyntaxError: StackMismatch    (exit 1)
legacy  <no output>                   (exit 0)
```

Every other `using` form is sound under v2 — block-scoped `using`, C-style
`for (using b = …; …; …)`, and `await using` in an async function all compile
and dispose correctly. The defect is confined to the for-of head.

---

## 3. Root cause: one unguarded legacy emission

### 3.1 The site

`parseForInOf` (parser.zig:16014-16417) parses a `using` / `await using`
ForDeclaration in its `parse_using_decl` arm and stores the iteration value in
an anonymous temp:

```zig
            const value_loc = try appendAnonymousTempLocal(s);
            iteration_using_value_loc = value_loc;
            try s.emitOpU16(opcode.op.put_loc, value_loc);   // parser.zig:16086
```

This is the **only** raw-emitter call in the whole 400-line function that is
not the `else` half of a `v2_available and s.emit_v2` gate: a guard check over
`parseForInOf` finds 17 raw emissions, of which 16 sit inside a `} else {`
opened by a v2 gate and one — line 16086 — sits directly inside
`if (parse_using_decl) {`.

The *same* pattern 208 lines later in the same function, for the resource
temp, is gated correctly:

```zig
            const resource_loc = try appendAnonymousTempLocal(s);        // 16294
            if (v2_available and s.emit_v2) {
                // zjs-only `for (using ... of ...)` lowering: retain the
                // resource in the same anonymous local as legacy.
                try v2FEmitOpU16(s, opcode.op.put_loc, resource_loc);    // 16298
            } else {
                try s.emitOpU16(opcode.op.put_loc, resource_loc);        // 16300
            }
```

Anonymous temp, then a store into it — the identical shape, one gated and one
not.

`v2EmitOpU16` (parser.zig:7004) is the exact analogue of `emitOpU16`
(parser.zig:5860): both take the source position from
`currentSourcePosition()`, emit the marker, then the opcode. The omission at
16086 is a missed gate, not a design decision — there is no comment, no
`zjs-only` note, and no assert claiming the path is legacy-only, unlike every
neighbouring arm in the same function.

### 3.2 What the omission does

`emitOpU16` (5860) → `appendBytes` (6788) → `appendBytesAt` (6958), whose
first statement is the fail-loud funnel guard:

```zig
        fn appendBytesAt(self: *State, bytes: []const u8, line_num: u32, col_num: u32) Error!void {
            std.debug.assert(!(v2_available and self.emit_v2));   // parser.zig:6959
```

- **Debug / ReleaseSafe**: the assert fires. The engine stops at the defect.
- **ReleaseFast** (the gate binary): the assert is a no-op. The three bytes go
  into the legacy `FunctionDef.byte_code` stream, which in a v2 parse is
  *not* the lowering input — `prepareCurrentBeforeChildren`
  (bytecode.zig:12467) skips `validatePhase1View` when `fd.v2_builder != null`,
  and finalization consumes the Builder instead (bytecode.zig:12731-12744).
  The bytes are therefore discarded, and the v2 instruction stream is missing
  its `put_loc`.

The missing `put_loc` is a pop. The for-of assign block leaves the iteration
value on the operand stack, so the `goto` into the loop body arrives one slot
deeper than the loop's other predecessor. `compute_stack_size`'s `seed()`
detects the disagreement at the merge point and returns
`error.StackMismatch` (bytecode.zig:11829).

The error surfaces as a *SyntaxError* because v2 mode has no legacy fallback:
`compile()` calls `compileQjsProgram(.v2, …)` and converts every non-OOM error
into a syntax error via `setFallbackSyntaxError` (parser.zig:22330-22344,
22691). A stack-verifier failure is therefore reported to test262 as
`SyntaxError: StackMismatch`. The error class in the log is an artifact of that
funnel, not evidence of a parser-grammar problem.

### 3.3 Evidence

The Debug v2 CLI attributes all nine tests to the same line. Representative
trace (identical frames for all nine; #9 run with `-m`):

```
thread … panic: reached unreachable code
  src/parser.zig:6959   in appendBytesAt   std.debug.assert(!(v2_available and self.emit_v2));
  src/parser.zig:6790   in appendBytes
  src/parser.zig:5864   in emitOpU16
  src/parser.zig:16086  in parseForInOf    try s.emitOpU16(opcode.op.put_loc, value_loc);
  src/parser.zig:14191  in parseStatementOrDeclSlow
  …
```

The pre-existing funnel assert is doing exactly the job it was designed for.
This defect was never invisible; it was invisible *to the ReleaseFast gate*.

---

## 4. Classification into the ruling's five kinds

Operational definitions used, so each assignment is falsifiable:

| kind | test |
| --- | --- |
| semantic mismatch | v2 produces different observable program behaviour from legacy, including refusing to compile a program legacy compiles |
| source mismatch | same behaviour, different pc2line / reported source position |
| module mismatch | divergence in module linking, namespace, or eval semantics |
| async-generator mismatch | divergence in the generator / async resume machinery |
| error-message mismatch | same error class at the same site, different message text |

### Counts — v2-attributable (the gate's 9 errors)

| kind | count | members |
| --- | --- | --- |
| **semantic mismatch** | **9** | all of §2 |
| source mismatch | 0 | — |
| module mismatch | 0 | — |
| async-generator mismatch | 0 | — |
| error-message mismatch | 0 | — |

Two assignments need defending, because the surface shape invites a different
answer:

- **Not async-generator mismatch**, though five of the nine are `await using`
  or `async`-flagged: the two purely synchronous `for (using x of …)` tests
  (#1, #2) fail at the same line with the same error, and `await using` used
  *anywhere else* — block scope, async function body — compiles and disposes
  correctly under v2 (verified). No async or generator mechanism is implicated;
  the async spelling merely routes the same head through the same missing gate.
- **Not module mismatch**, though #9 is `flags: [module]`: the identical
  construct fails in plain script mode (the two-line repro in §2 is a script).
  Module linking is not implicated.

### Counts — the 25 known-error baseline

| kind | count |
| --- | --- |
| semantic mismatch | 0 |
| source mismatch | 0 |
| module mismatch | 0 |
| async-generator mismatch | 0 |
| error-message mismatch | 0 |

Zero in every kind, because the five kinds measure **v2-against-legacy**
divergence and these 25 have none: identical path, identical bucket, identical
message text in both modes. They are engine-against-spec conformance gaps on a
different axis, itemised in §7 for completeness.

---

## 5. Ordering by the ruling's switch priority

The S6 switch gate is a runtime gate, so the ruling's order is (1) runtime
observable behaviour, (2) module/eval, (3) async/generator, and last message
formatting / source location.

| priority band | count | content |
| --- | --- | --- |
| **(1) runtime observable behaviour** | **9** | all nine. Programs that must run do not run at all: v2 rejects them at compile time with a SyntaxError. This is the most runtime-observable failure a compiler can produce — nothing executes. |
| (2) module / eval | 0 | — |
| (3) async / generator | 0 | — |
| (last) message formatting / source location | 0 | — |

The whole v2-attributable set sits in the top band. Structurally that is clean
— there is no long tail of cosmetic divergence hiding behind the real work —
but it also means **nothing here can be deferred past the switch gate**. There
is no item in this set that a switch could reasonably carry as a known cosmetic
delta.

---

## 6. Per-item mechanism, fix size, and gap-versus-artifact

All nine share one row, because they share one line.

| field | value |
| --- | --- |
| **items** | §2 #1-#9 (9 tests) |
| **v2 mechanism that is missing** | the v2 emission arm for the for-of `using` iteration-value store. `parseForInOf`'s `parse_using_decl` arm (parser.zig:16057-16087) never routes `put_loc value_loc` through the v2 veneer; `v2FEmitOpU16` / `v2EmitOpU16` exist and are used for the *resource* temp 208 lines later (16298). |
| **why it is wrong, not merely absent** | the call reaches `appendBytesAt`'s funnel assert (6959). Under ReleaseFast the instruction is written into the legacy stream, which v2 finalization discards (bytecode.zig:12467, 12731). The v2 stream loses one pop; `compute_stack_size` reports the merge-point disagreement as `StackMismatch` (bytecode.zig:11829). |
| **fix size** | **one call site, five lines.** Wrap 16086 in the standard veneer gate, mirroring 16295-16301 verbatim. No identity-model change, no `Builder`/`SourceSlot` API change, no resolver change, no new label, no new source-marker policy — `v2EmitOpU16` already emits marker-then-opcode in the same order as `emitOpU16`. |
| **one-liner?** | Yes, in the ruling's sense: mechanical and obviously correct by direct comparison with its own sibling. **Not applied in this stage.** Worth an explicit re-run of the full v2 gate afterwards rather than the nine tests alone, since the arm also feeds `emitUsingAddResource` and `emitCloseLoc` downstream. |
| **genuine v2 gap or legacy-parity artifact** | **genuine v2 gap.** Legacy compiles and runs all nine correctly; v2 does not. |

---

## 7. The 25 known-error baseline (legacy-parity artifacts)

Listed in `test262_errors.txt`, failing identically in both backends, and the
reason the legacy gate reports `0/49775` rather than `25/49775`. Recorded here
so no later stage mistakes them for v2 regressions.

| family | count | bucket | shared (backend-independent) cause |
| --- | --- | --- | --- |
| `annexB/language/expressions/assignmenttargettype/*` | 7 | `SyntaxError: InvalidAssignmentTarget` | the AnnexB *Runtime Errors for Function Call Assignment Targets* web-compat extension is not implemented. `getLValue`'s catch-all (parser.zig:7857) and its v2 twin `v2GetLValue`'s catch-all (8007) are the same `else => return Error.InvalidAssignmentTarget`: both reject a CallExpression target at parse time instead of deferring to a runtime `ReferenceError`. Identical classification on both sides. |
| `language/expressions/assignment/S11.13.1_A6_T{1,2}` + `language/expressions/compound-assignment/S11.13.2_A6.*_T1` | 13 | `Test262Error` | `PutValue` must use the Reference created *before* a direct `eval` introduces a shadowing binding in an inner declarative environment. The observed values (`innerX` is `1` where the test demands `undefined`, `5` where it demands `2`, …) show the store landing on the binding the `eval` created, i.e. the target is resolved after the eval rather than captured before it. Identical numbers in both modes, so this is an engine-level reference-model gap, not a backend property. |
| `language/expressions/dynamic-import/import-attributes/2nd-param-with-type-text.js` | 1 | `TypeError: $DONE() not called` | `import(…, { with: { type: 'text' } })` — the `import-text` module type is not supported by the module loader. |
| `language/identifier-resolution/assign-to-global-undefined.js` | 1 | `Empty` | strict-mode `PutValue` on an unresolvable reference must throw `ReferenceError`; the negative-runtime expectation is not met. |
| `staging/sm/*` | 3 | 1 `TypeError`, 2 `Test262Error` | SpiderMonkey staging: `var arguments` shadowing inside parameter-expression scope; AnnexB B.3.3 block-scoped function hoisting out of `if` clauses; AnnexB B.3.5 var-introduced-by-direct-eval inside a catch body. |

Verification that these carry zero v2 attribution: sorting the legacy failure
log and the v2 log minus the nine `using` lines produces **no diff at all** —
same paths, same buckets, same message strings.

---

## 8. What the test262 gate does not cover (verified, outside the 9)

The gate is necessary but not sufficient as a switch gate. Two runtime
observable v2 divergences exist today that no test262 test can reach, because
test262 contains no TypeScript.

### 8.1 TypeScript `enum` — genuine v2 gap, invisible to every current gate

`parseEnumDeclaration` (parser.zig:13528-13644) is **half migrated**: two
`push_i32` emissions carry a proper v2 gate (13591, 13606), while **all 12
raw emitter calls in the function are unguarded**, together with an
absolute-PC jump pair (`emitForwardJump` 13544 / `patchForwardJump` 13547).
The jump helpers are the legacy absolute-PC machinery the v2 byte-PC rule
forbids (`compiler_v2_contract.md` §1). The two partial gates make this the
more dangerous shape of the §3 defect: a v2 parse gets far enough to write
into the Builder before hitting the ungated emission.

```
Debug v2:   panic at parser.zig:13543 (funnel assert), in parseEnumDeclaration

enum E { A, B }; console.log(E.A, E.B, E[0]);
  legacy → 0 1 A
  v2     → TypeError: cannot read property 'A' of undefined
```

### 8.2 TypeScript `namespace` — same family

`parseNamespaceDeclarationWithIdent` (parser.zig:13650-13731): **6 unguarded
raw emitter calls**, an absolute-PC jump pair (13665 / 13668), and zero
mention of `emit_v2` anywhere in the function.

```
Debug v2:   panic at parser.zig:13664 (funnel assert)

namespace N { export const x = 41; } console.log(N.x);
  legacy → 41
  v2     → TypeError: not a function
```

A third static candidate in the same family — `parseClass`'s
`s.namespace_export` arm (parser.zig:21095-21102) — is currently masked by
8.2 and could not be exercised independently.

### 8.3 Why no existing gate catches 8.1 / 8.2

- The TypeScript **parser** tests construct a `ParseState` directly
  (`parseRawTSProgram`, src/tests/parser.zig:5917) and never call
  `beginV2ProgramEmission`, so `emit_v2` stays `false` even in a
  `-Dzjs_compiler=v2` build.
- The TypeScript **execution** tests (src/tests/exec.zig:9173-9239) do go
  through production `eval` (and therefore v2 in a v2 build), but cover only
  type erasure, method annotations, `as`/`satisfies`, parameter properties and
  `.ts` filename detection. None of them emits an `enum` or a `namespace`.
- `zig build test -Dzjs_compiler=v2` is green at this tip: **2257 passed, 0
  skipped, 0 failed**. (An earlier F3-stage run showed 2 failures; both were
  `FileNotFound` from an uninitialised `test262/` submodule in that worktree,
  not code failures.)

### 8.4 Not gaps

- `parseDeleteSuperReference` (parser.zig:9126) and `emitDeleteSuperError`
  (9166) hold 10 unguarded raw emitter calls between them, but
  `parseDeleteSuperReference` has **no callers anywhere in `src/`**, and
  `emitDeleteSuperError`'s only two call sites are inside it. Dead legacy code;
  removing it would shrink the audit surface without touching behaviour.
- The `emitForwardJump` / `emitBackwardJump` / `emitParserLabelJump` families
  (12124-12250) are unguarded by design: they are the legacy absolute-PC
  helpers, and v2 arms use `v2FEmitJump` against a `LabelId`. They are a gap
  only where a v2-reachable path calls them — which today is exactly §8.1 and
  §8.2.
- `docs/compiler_v2_contract.md` §F (F-1 … F-8, lines 520-576, written at tip
  `6d0c69dd`)
  lists F-1 generator/async resume, F-2 logical assignment, F-4 `with`, F-7
  optional calls, and F-8 identifier/field for-in-of lvalues as un-migrated
  seams. **All five now run correctly under v2 at `278df5c2`**, verified by
  execution under the Debug v2 CLI with the funnel assert live:
  `function* g(){ yield 1; yield* [2,3] }`, `await`, `with(o){…}`, `f?.()`,
  `q ||= 7`, `for (x of …)`, `for (o.p of …)`, `for (y in …)` all produce
  correct results with no assert. Those entries are **stale, not open**; §F
  should be re-audited at the current tip rather than trusted as an
  outstanding-gap list.

---

## 9. How many must be zero before a switch can be evaluated

Stated plainly, against the ruling's standard that the S6 switch gate is a
**runtime** gate and that the switch bar is **backend equivalence**, not spec
perfection:

1. **All 9 v2-attributable test262 failures must be zero.** Not "most", not
   "all but the cosmetic ones" — §5 puts every one of them in priority band
   (1), so no member of this set is deferrable. The concrete target is the
   legacy line reproduced exactly:

   ```
   v2 mode:  Result: 0/49775 errors, passed 44541, known 25
   ```

   Both the error count *and* the passed count must match; a v2 run at
   `0 errors, passed 44532` would mean nine tests silently changed status.

2. **The 25 known errors must NOT be required to be zero.** They are the
   shared engine baseline that legacy carries identically (§7). Requiring them
   would be asking a backend switch to also close pre-existing engine-versus-
   spec conformance gaps — a different project, on a different axis, with no
   bearing on whether v2 and legacy agree.

3. **The test262 gate alone is not a sufficient switch gate.** At least two
   further runtime-observable v2 divergences exist outside its reach (§8.1,
   §8.2), plus one masked static candidate (§8.2). Either those reach zero as
   well, or the switch decision needs an explicit written ruling that
   TypeScript lowering is out of switch scope. Silence is not an option: today
   a v2 switch would ship an engine that miscompiles `enum` and `namespace`
   with a fully green test262 gate and a fully green Zig suite.

So: **9 to clear the test262 gate; 9 plus the TypeScript lowering family
(2 verified constructs, 1 masked candidate) before a switch can be honestly
evaluated.**

---

## 10. Reproduction

```bash
# authoritative gates (both from the same tip, same corpus)
zig build run-test262 -Dzjs_compiler=v2     --seed 0
zig build run-test262 -Dzjs_compiler=legacy --seed 0 -p zig-out-legacy
./zig-out/bin/run-test262        -t 16 -c test262.conf -d test262/test 0 100000 -R /tmp/v2-report
./zig-out-legacy/bin/run-test262 -t 16 -c test262.conf -d test262/test 0 100000 -R /tmp/legacy-report

# the delta is exactly the nine `using`-in-for-of tests
comm -13 <(cut -f1 /tmp/legacy-report/test262-failures.log | sort) \
         <(cut -f1 /tmp/v2-report/test262-failures.log     | sort)

# minimal repro
printf 'const o = { [Symbol.dispose]() {} };\nfor (using x of [o]) { }\n' > /tmp/u.js
./zig-out-v2/bin/zjs     /tmp/u.js   # SyntaxError: StackMismatch
./zig-out-legacy/bin/zjs /tmp/u.js   # clean exit

# site attribution (Debug build, funnel assert live)
zig build zjs-dev -Dzjs_compiler=v2 --seed 0 -p zig-out-v2dev
./zig-out-v2dev/bin/zjs-dev /tmp/u.js   # panic at src/parser.zig:16086

# the TypeScript exposure outside test262
printf 'enum E { A, B }\nconsole.log(E.A, E.B, E[0]);\n' > /tmp/e.ts
./zig-out-v2dev/bin/zjs-dev /tmp/e.ts   # panic at src/parser.zig:13543
./zig-out-v2/bin/zjs        /tmp/e.ts   # TypeError (legacy prints "0 1 A")
```

A fresh worktree has an uninitialised `test262/` submodule; symlink
`test262/test` and `test262/harness` from the primary checkout before running
the gate, and remove the symlinks before committing.
