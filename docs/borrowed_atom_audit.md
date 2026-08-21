# Borrowed-Atom Ownership Audit (parser / compiler side)

Scope: all of `src/parser.zig`, plus the downstream sinks that receive atoms
from the parser (`FunctionDef` / module `Record` / atom-operand flow in
`src/bytecode.zig`, and `src/core/module.zig`).

This document is the ownership contract and governance protocol that came out
of the 2026-08 "audit first, then patch" pass: every **borrowed atom** site
was enumerated and classified, class C reachability was proven, and only
class C was fixed. The one-time audit evidence (probe transcripts, per-line
site tables, fix diffs, measurement tables) has been removed from this
document; recover it from git history if the original record is needed. What
remains is everything that current code, the allowlist, and future changes
still depend on: the failure mechanism (§1.1), the classification bar (§2),
the open class-B ledger (§3.2, §6), the audit build (§7), and the static rule
(§8).

Section numbers are load-bearing: `build.zig`, `build/gates.zig`,
`src/tests/core.zig`, `tools/architecture/check_borrowed_atoms.js`, and every
entry in `tools/architecture/borrowed-atoms-allowlist.json` cite them. Do not
renumber.

---

## 1. Background

The lexer once released only a token's string payload and never the atom that
`next()` interned into an `.ident` payload, so every identifier token leaked
one retain and an atom interned from source could never reach refcount 0. In
that world "borrow an atom from the token, then `advance()`, then keep using
it" was safe by accident. The lexer fix that released identifier and
private-name token atoms (mirroring qjs `free_token`) removed the leak, and
every ownership hazard the leak had been hiding became real at once. This
audit finished the remaining ledger.

### 1.1 Failure mechanism (the class C criterion)

In `src/core/atom.zig`:

- `free()` decrements `ref_count`; at zero it calls `finalizeDeadEntry`.
- `finalizeDeadEntry` unlinks the entry from `string_index`
  (`unindexEntry`), frees `entry.bytes` and clears it, and pushes the slot
  index onto the **LIFO** free list `free_slot_head`.
- `internDynamic` **pops the free-list head first** on a hash miss, and
  reuses the slot while keeping the same id
  (`entry.id == idx + first_dynamic_atom`).

Consequence: a just-dead atom id does not become permanently invalid; the
**next new-string intern** rebinds it. Then:

1. If the immediately following intern is the same string (for example,
   re-lexing the same identifier after lookahead), the slot is taken back
   by the same name and the stale id looks "live" again — **the code looks
   correct**.
2. If any other new-string intern happens in between, the stale id now
   points at **another string**, and `dup()` silently retains the wrong
   entry.
3. If the stale id's slot has not been reused yet, `dup()` hits
   `std.debug.assert(entry.hasLiveValue())`: Debug / ReleaseSafe panic
   immediately. In ReleaseFast it pulls a dead entry that is already on the
   free list back to `ref_count` 1, after which the same slot is
   `finalizeDeadEntry`'d a second time and pushed onto the free list again —
   the free list now has a duplicate, and two later interns receive the
   same id.

Case 1 is what this document calls **"luck of slot reuse"**: not a
contract, a coincidence.

---

## 2. Classification

- **A = SAFE**: the code itself `dup`s an owner before the token is
  released; or the atom is already a predefined / tagged-int constant; or
  the read and the use both fall inside the same token lifetime (pure
  compare, pure name read).
- **B = NEEDS EXPLICIT OWNERSHIP**: correct today, but **only by
  accident** — liveness depends on some third-party owner unrelated to
  this site (`var_name` that `defineVar` happened to dup, an outer dup, a
  scope var row…). The code itself does not express that ownership.
  Changing that third party, or swapping statement order, silently
  breaks.
- **C = WRONG**: the borrow crosses the owner's release point; the atom
  can reach refcount 0 before the use site.

The B bar is deliberately stricter than "it runs, so it is correct": the
ruling wants **the contract written in the code**. (A parallel scan
classified most of this document's B sites as A, on the grounds that "there
is in fact an owner". There is no disagreement about the facts, only about
whether incidental ownership counts as B; this document uses the strict
bar.)

---

## 3. Site classification

Line numbers have been dropped from this section; function names are the
anchors. The full six-field per-site tables (source, owner, release point,
use interval, dup, transfer) are in git history.

### 3.1 Class C (fixed)

- **C-1 / C-2 `exportDefaultFunctionName` / `exportDefaultClassName`**:
  both returned a name atom read from a local lookahead token whose
  `defer freeToken` ran before returning, so the id was dead at the moment
  of return; it survived only because the next intern was the identical
  string popping the same LIFO slot. Fixed as `*Owned` functions (§5);
  reachability was proven first (§4).
- **C-3 `parseDeleteSuperReference` (retired)**: the unreachable helper and
  its uncalled predicate were deleted. The live generic delete path parses
  the reference normally and rewrites a trailing `get_super_value` into the
  intended ReferenceError emission.

### 3.2 Class B (correct, but not a contract)

- **B-1 `identifierLikeAtom` (retired)**: the helper now states its
  current-token borrow contract, while `identifierLikeAtomOwned` and
  `labelStartAtomOwned` own names that cross `advance()`.
- **B-2 catch binding (retired)**: the catch clause now owns its binding
  name across `advance()` and the later bytecode emission.
- **B-3 TS `enum` name / B-4 TS `namespace` name (retired)**: declaration
  parsing now owns the token name locally, while `last_declared_atom` and
  `current_namespace_atom` are owned state slots with retain-on-write and
  release-on-overwrite/deinit contracts.
- **B-5 `State.last_class_decl_atom` (retired)**: `parseClass` now returns
  an owned declaration name directly, and the cross-function state field
  was deleted. `classNameAtomOwned` establishes the owner before token
  release for both declaration and expression paths.
- **B-6 `State.last_var_decl_atom` (retired)**: the write-only field that
  stored `parseVar`'s defer-freed atom was deleted; there is no longer a
  dormant state slot that a future reader could turn into class C.
- **B-7 direct assignment name (retired)**: the `name0`-equivalent used for
  anonymous-function naming now has a local owner across `parseCondExpr`,
  independent of the getter operand later transferred into `LValue`.

### 3.3 Class A (safe)

Everything else either establishes an independent owner before the token is
released (`dup` before `advance()` + `defer free`, `dupToken` snapshots,
`*Owned` helpers, list-held retains), keeps the entire use inside the token
lifetime (pure compares, argument-position reads), or receives a
predefined / freshly created owned atom. The sinks
(`FunctionDef.appendVar` / `appendArg` / `appendGlobalVar` /
`addClosureVar` / `appendAtomOperand`, module `Record.add*`) always
`atoms.dup` — which cannot save an already-dead input. The full per-site
table is in git history.

---

## 4. Evidence (retired)

The original section proved class C reachability; the full probe transcripts
live in git history. What was established:

- A temporary refcount probe showed the `exportDefault*Name` return value
  was already `finalizeDeadEntry`'d at the moment of return, then "taken
  back" when the same string was re-interned — on all four export shapes.
- Interning one extra wedge string in between rebound the stale id to the
  wedge string, and a fully legal module was reported as a `SyntaxError` —
  the silent-wrong-value failure of §1.1 case 2.
- A one-slot quarantine detector (the prototype of §7) made
  already-checked-in unit tests hit `dup`'s `hasLiveValue` assert on the
  pre-fix tree, and ran all green after the fix (unified suite plus
  ~14,600 test262 cases across the language subtrees; a full-set Debug run
  was blocked at the time by pre-existing, audit-unrelated asserts — see
  §7.3, where the `allocation_count` one has since been fixed).

---

## 5. The fix (summary)

The live class C sites, `exportDefaultFunctionName` /
`exportDefaultClassName`, became
`*Owned` functions (dup inside the `return` expression, before the `defer`
releases the token), matching the established `moduleImportNameAtomOwned`
convention — the `*Owned` suffix is the "caller frees" contract. The
unreachable C-3 pair was later deleted (§6.5).

No black-box regression test accompanies the fix, because none can exist:
under the current parse order there is no JS-source-controlled insertion
point between the helper releasing the name and `parseFunctionDecl` /
`parseClass` re-interning the same string, so the bug is invisible without
breaking slot-reuse luck. The durable regression shape is the pair of
mechanical guards: the runtime audit build (§7) makes existing tests panic
on a real escape, and the static rule (§8) forbids the source shape
outright.

---

## 6. Follow-ups

Class B was promoted in place only when the change was "small and obviously
correct". The items below were registered as follow-up and are now closed;
the borrowed-atom allowlist is empty. Each open item had a matching allowlist
entry whose `exit_milestone` cited the numbering below: finishing an item
required deleting the matching entry, while a leftover entry went stale and
turned the checker red. The gate still blocks both "fixed it and forgot to
close the ledger" and any newly introduced same-shape site (§8).

### 6.1 B-5: eliminate `last_class_decl_atom`

Closed 2026-08-20: `classNameAtomOwned` retains the current name before
`advance()`, and class declarations transfer that owner through the
`parseClass` return value. All callers free it locally, including the export
path that previously read `State.last_class_decl_atom`; the state field and
both matching allowlist entries were deleted.

### 6.2 B-6: delete `last_var_decl_atom`

Closed 2026-08-20: the write-only field and both writes were deleted together
with their allowlist entry. This was cleanup, not an ownership transfer.

### 6.3 B-1: make the `identifierLikeAtom` contract explicit

Closed 2026-08-20: `identifierLikeAtom` states its current-token borrow,
`identifierLikeAtomOwned` serves parameter paths that retain the name past
`advance()`, and `labelStartAtomOwned` transfers an owner directly to the
label parser. The four matching allowlist entries were removed.

### 6.4 B-2 / B-3 / B-4: localize the owner

Closed 2026-08-20: catch, for-in/of bindings, TS enum, and TS namespace now
hold local owners across token release. `last_declared_atom` and
`current_namespace_atom` retain borrowed inputs, release overwritten values,
and release their final values in `State.deinit`; the phase-ledger census
tracks both owned slots. The five matching allowlist entries were removed.

### 6.5 Dead code `isDeleteSuperReference` / `parseDeleteSuperReference`

Closed 2026-08-20: both uncalled helpers and their two now-orphaned emission
helpers were deleted. The live `parseDelete` path already covers
`delete super.x` and `delete super[key]` through the trailing
`get_super_value` rewrite in `finishDelete`. The focused test262 delete slice
was identical before and after this cleanup (64/69): both detached HEAD and
the candidate retain the same five `super-property*.js`
`SyntaxError: InvalidBytecode` failures. That conformance defect remains
separate from this no-caller cleanup.

### 6.6 B-7: own the direct assignment name

Closed 2026-08-20: the direct identifier name used to recognize QuickJS's
`name0` anonymous-function naming pattern is duplicated before
`parseCondExpr` releases the token and freed at the end of
`parseAssignExpr2`. The final allowlist entry was removed.

(The audit-time quarantine detector itself was the sixth follow-up; it
landed as `-Dzjs_ownership_audit`, §7.)

---

## 7. Audit build `-Dzjs_ownership_audit` (productized detector)

Implementation: `src/core/atom.zig` (`AtomTable.OwnershipAuditState` plus
the reuse arm of `finalizeDeadEntry`); the option is in `build.zig` and uses
the same option distribution as `zjs_force_gc`.

### 7.1 What it does

A slot freed by `finalizeDeadEntry` waits one round in a **one-slot
quarantine** and only joins the free list after the next slot dies. So
"free an atom, then immediately re-intern the same string" can no longer
recover the same id, and §1.1 case 1's "luck of slot reuse" is gone: a
stale id whose borrow crossed its owner either points at an empty slot
(`dup` hits `hasLiveValue`; Debug / ReleaseSafe panic immediately) or,
after one more intern, points at another string (wrong value, exposed by
the caller's own checks).

**Why one slot instead of turning reuse off** (also in the code comment):
reuse is only delayed by one death, so table size, `next_id` growth, and
`deinit` teardown invariants stay the default-build ones. Turning reuse off
entirely would let the table grow monotonically with intern/free churn; the
audit itself could then turn a high-churn test into an OOM under a
different table geometry, and what it found would not be trustworthy.

`src/tests/core.zig` has a liveness self-check (`ownership audit
quarantines the most recently freed atom slot`): `SkipZigTest` when the
audit is off; when on, it asserts the just-dead slot is not taken by the
next intern but is reused after one more slot dies. Flip the quarantine
back to a direct free-list push and this test goes red immediately —
without it, the audit mode could be broken while CI stays green, exactly
the silence this option exists to kill.

### 7.2 Cost tier

The ASAN / leak-checker tier: for CI, fuzzing, and reproduction. **Off by
default, never in ReleaseFast, never on a production path.** When off, the
whole mechanism disappears at comptime: `OwnershipAuditState` collapses to
an empty struct; fields, code, and even the names stay out of the binary.
The default binary's `.text` was measured byte-identical to a control build
and the instruction-count delta was zero; the measurement record is in git
history.

### 7.3 How to run it

```bash
zig build test        --summary all -Dzjs_ownership_audit=true   # unified suite
zig build test-parser               -Dzjs_ownership_audit=true   # one subtree, faster isolation
zig build test-oom    --summary all -Dzjs_ownership_audit=true
zig build zjs-dev                            -Dzjs_ownership_audit=true   # hand corpus
zig build run-test262-dev                    -Dzjs_ownership_audit=true   # test262 subtree
./zig-out/bin/run-test262-dev -c test262.conf -d test262/test/language/module-code
```

Asserts are live only in Debug / ReleaseSafe (`std.debug.assert`). Turning
the option on under ReleaseFast is pointless: `dup`'s assert is compiled
out, and quarantine would only scramble slot assignment for nothing.

**A full-set Debug run is still blocked, but no longer by the leak.** The
`allocation_count` assert in `src/core/runtime.zig` that used to abort the
run after roughly 7,000 cases was four independent leaks (parser builder on
a first-token lex error, the FinalizationRegistry job queue re-grown during
teardown, a `charCodeAt` receiver ref, and a regexp class-escape range); all
four are fixed as of 2026-08-19, and the whole 53,572-file set now executes
without a single hit.

Four *other* pre-existing Debug asserts still abort a whole-set single-process
run. Each reproduces on a clean tree and is unrelated to this audit:

| Assert | Scope |
|---|---|
| `src/core/string.zig:1560` `destroyRope` | 447 files, all `built-ins/RegExp/CharacterClassEscapes/*` |
| `src/core/runtime.zig` `assert(self.context_head == null)` | 52 files in `staging/sm` (a `JSContext` outliving its runtime) |
| `src/exec/builtin_dispatch.zig:49` `nativeIsExc` | 19 files in `built-ins/Iterator/{zip,zipKeyed}`. The OOM route into this assert was fixed on 2026-08-19 (and `zig build test-oom` is green again); these files reach it by a different path — a native Iterator helper returns the exception sentinel without a pending exception — so the seam invariant, not the allocator, is what to look at |
| `src/core/string.zig:686` `releaseFromHeader` | `language/arguments-object/S10.6_A5_T4.js` |

Until those are fixed, run the blocked directories with `-d` per subtree, or
file-by-file within them.

### 7.4 It still catches the original defect (reproducible)

Locally remove the `dup` from the `return` expression of
`exportDefaultFunctionNameOwned` / `exportDefaultClassNameOwned` (i.e.
rebuild the pre-fix borrow) in a scratch worktree. Then:

- `zig build test-parser` (audit **off**) → all green. That is the masking
  §5 described: black-box tests cannot see this use-after-free.
- `zig build test-parser -Dzjs_ownership_audit=true` → SIGABRT in
  `dup`'s `hasLiveValue` assert, reached through `addExport` →
  `addModuleExportName` → `parseExport` from an existing checked-in parser
  test.

Restore the file and the same command is all green. That is the only usable
red → green shape for this bug class: not a black-box regression, but a
**behavior delta of existing tests under the audit mode**.

---

## 8. Static rule `check_borrowed_atoms.js` (forbid the "borrow escapes" source shape)

Landing: `tools/architecture/check_borrowed_atoms.js` +
`tools/architecture/borrowed-atoms-allowlist.json`, run by
`mise run checkpoint-gate` and `zig build engine-production-gate` (same
layer and allowlist shape as `check_deps.js` / `check_oom_panics.js`). Scan
range `src/**.zig` (excluding `src/tests/`).

### 8.1 Why it is needed — it and §7 each cover half

§5 showed a black-box regression cannot be written. The two remaining tools
each cover only half:

| | `-Dzjs_ownership_audit` (§7) | `check_borrowed_atoms.js` (this section) |
|---|---|---|
| When it fires | runtime | review / CI static |
| Criterion | after one-slot quarantine, a stale id hits `dup`'s `hasLiveValue` assert or reads a wrong value | source shape: a borrowed atom escapes the token lifetime |
| Catches | a crossed borrow that actually executed, including paths this document did not think of | every newly written same-shape site, even with no test coverage today |
| Misses | paths with no test coverage; ReleaseFast (asserts compiled out); unreachable code (e.g. C-3) | ownership that only exists at runtime (a third-party sink happens to dup); cross-function / cross-file propagation; see §8.6 |

The original class C was exactly "statically obvious, runtime-invisible
except by luck": `return <token>.payload.ident.atom` plus `defer freeToken`
at function exit. This rule's first-principles goal is **to make that shape
unbuildable at the gate forever**.

### 8.2 The rule itself

Three sources of a **borrowed atom**:

1. `<token>.payload.<field>.atom` in a **value position** — a read in
   **argument position** such as
   `atomNameEquals(s, s.token.payload.ident.atom, "of")` is consumed
   inside the token lifetime and is not a borrow (most token-atom reads
   collapse away under this test; that is the main precision win);
   builtins such as `@as` / `@intCast` are transparent and the scan walks
   through them;
2. the return value of a same-file helper that itself returns a borrowed
   atom — the helper set is computed by fixed-point iteration
   (`identifierLikeAtom` today; run the checker with `--list` for the current
   set);
3. a binding (`const` / `var`) or reassignment (`nm = ...`) of either of
   the above; `const` declarations also do one layer of local contagion
   (`const name = private_atom orelse raw_name;`). Contagion only follows
   **value-preserving expressions**: `const hit = nm == other;` produces a
   bool, not an atom, and a compare / boolean op at the top level breaks
   the chain. Rebinding to an owned value (`nm = atoms.dup(nm);`)
   **closes** that borrow site's window.

Ownership is judged **by position**, not "this statement mentioned `dup`":
`.dup(x)` puts `x` in argument position, so a "duped read" is not a
borrowed read at all. Thus the else arm of
`return if (c) atoms.dup(a) else t.payload.ident.atom;` still fails — a
whole-statement "contains dup, so allow" rule would miss it.

**Four escape rules** (one report per borrow site, highest-priority rule
wins):

| pattern | Forbidden shape |
|---|---|
| `borrowed-return` | `return` a borrowed atom (= the original class-C bug) |
| `borrowed-state-store` | store a borrowed atom into a long-lived `State` atom field (the field outlives the token) |
| `borrowed-use-after-release` | read it in the same function after a non-`defer` `advance()` / `freeToken()` |
| `owned-escape-state-store` | store a local held only by `defer ...free(x)` into a long-lived atom field that this function does not restore (= the B-6 shape) |

"Long-lived atom field" is not a hardcoded list: the checker scans the
struct scope for every `Atom` / `?Atom` field name (skipping function
bodies, so multi-line parameter lists are not treated as fields), then
requires the receiver to be the name bound to `*State` in this function's
signature. A newly added field of the same kind is covered the same day,
and a neighboring struct's own `self.<atom field>` is not mis-fired.

**Three legal shapes** (preferred order):

1. Take ownership in the escaping expression itself: `.dup(` /
   `.internString(` / `.newSymbol(` / call some `*Owned(`;
2. Function name ends in `Owned` (existing convention:
   `moduleImportNameAtomOwned`, `exportDefaultFunctionNameOwned`) —
   **exempts only `borrowed-return`**, and only "forwarding someone
   else's borrow" (a helper result / a contagious local that static
   analysis cannot prove), **never a direct return of a token-payload
   read**, because that is the original bug itself; the body must actually
   have produced an owner, or the suffix is an empty check;
3. Write `// borrowed-atom: <reason>` on the line immediately above. The
   reason cannot be empty — if you cannot write a reason, the contract
   does not exist. Rules A / B only honor a mark above the **escape
   line**; rule C also allows it above the borrow line (that is the
   natural place to say "this borrow is deliberate").

**Allowlist**: fields `source` / `pattern` / `reason` / `exit_milestone`,
plus optional `fn` (containing function) and `contains` (statement
substring) selectors. Each entry must hit exactly one finding; a miss is
stale (red), a multi-hit is non-unique (red), two entries grabbing the same
finding is overlapping (red). Cap 16 entries.

### 8.3 The allowlist is the machine-readable form of this document's class B

Do not maintain a copy of the entries here — it goes stale. Get the current
findings and the borrowed-helper set from the checker itself:

```bash
node tools/architecture/check_borrowed_atoms.js --list
```

Every entry's `reason` names the third-party owner that keeps the site
alive today, and its `exit_milestone` cites the §6 item that retires it.
Some entries land on sites the original §3.3 table had filed as class A
with reasons like "caller dups before advance" — under §2's strict bar
those were already B (the owner is elsewhere), and re-review confirmed each
one; they are registered as follow-ups, not violations. No finding lands on
a genuinely safe class A site (`dupToken` snapshot family, pure compares,
predefineds, helpers that return owned, the `retained_name` shape, and the
`*Owned` functions are all zero hits).

### 8.4 Precision and strength

Properties established by a synthetic red/green matrix at landing time
(full table in git history):

- the pre-fix class-C `return` shape is red; the fixed `return dup(...)`
  form is green;
- mixed branches are judged per-position (`return if (c) dup(a) else
  t.payload...;` is red);
- an `Owned` suffix with only an unrelated dup does not exempt a direct
  token-payload return;
- transparent builtins (`@as(...)`) and rebinding through intermediate
  locals are followed; owned rebind (`nm = atoms.dup(nm)`) closes the
  window;
- compare results are not atoms (no false contagion); comments, string
  literals, and non-`State` receivers do not fire.

For current scale (files / functions scanned, reads, borrows, escapes,
allowlist usage), read the summary line the checker prints on success; two
runs produce byte-identical output.

### 8.5 How to run it

```bash
mise run checkpoint-gate                                 # the gate (includes this rule)
node tools/architecture/check_borrowed_atoms.js          # this rule only
node tools/architecture/check_borrowed_atoms.js --list   # list each finding + the borrowed-helper set
```

### 8.6 What it cannot catch (honest list)

- **Borrows on parameters**: only bindings inside the function body are
  tracked. `fn f(s: *State, name: Atom)` storing a borrowed `name` into a
  long-lived field, or wrapping it into a returned struct, is not caught —
  `definePatternBindingAtom` is exactly that shape (it wraps the borrowed
  name into `PatternTarget.direct_binding.name` and returns it; today it
  is held up by the var row `defineVar` builds). Consequence: after a
  borrow is passed as an **argument** to such a wrapper, the return value
  is no longer treated as borrowed.
- **Cross-file propagation**: the borrowed-helper set is a per-file fixed
  point; it does not cross files or structs. That is enough today (token
  payloads are only read in `src/parser.zig`); a layout change needs a
  re-evaluation.
- **Release points are literals only**: `advance()` / `freeToken()`.
  Helpers such as `expectToken` that **advance internally** are not
  release points (no interprocedural summary), and there is no
  path-sensitive analysis — an `advance()` that runs on only one branch
  counts as a release for every later line in the function.
- **Block-head truncation**: the return expression of a multiline
  `return .{ ... }` / `return switch (...) {` is cut at `{`. A pure
  forwarding wrapper can be missed. That is the precision price: better to
  miss one forwarding layer than to treat a whole switch body as one
  return expression.
- **Limited `Owned` suffix strength**: it can block "the body never
  produced an owner" and "direct return of a token-payload read"; it
  cannot block "dup some other atom, then forward a borrowed helper
  result".
- **Ownership that only exists at runtime**: whether a sink dups, and how
  long a third-party owner lives, is not visible statically. That is why
  every allowlist entry must write `reason` (who is holding it) and
  `exit_milestone` (how to turn it into a local contract).
- **`test` / `comptime` blocks are not function bodies**, so their code is
  not analyzed; the scan range also excludes `src/tests/`.
