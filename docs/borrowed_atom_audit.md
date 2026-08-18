# Borrowed-Atom Ownership Audit (parser / compiler side)

Audit baseline commit: `3d869065` (`main`, immediately after `8c8787cd`
"release identifier and private-name token atoms" and `693c2997`). Scope:
all of `src/parser.zig`, plus the downstream sinks that receive atoms from
the parser (`FunctionDef` / module `Record` / atom-operand flow in
`src/bytecode.zig`, and `src/core/module.zig`).

This document is the written product of "audit first, then patch": first
enumerate and classify every **borrowed atom** site, then prove
reachability for class C sites, and finally fix only class C.

---

## 1. Why this audit had to happen now

Before `8c8787cd`, `Lexer.freeToken` released only the token's string
payload; it never released the atom that `next()` interned into a `.ident`
payload. That means **every identifier token leaked one retain**, and an
atom interned from source could never reach refcount 0. In that world,
"borrow an atom from the token, then `advance()`, then keep using it" was
safe — the borrowed entry could not die.

`8c8787cd` added the `.ident` free arm (qjs `free_token`,
quickjs.c:22190-22208). The leak disappeared, and every ownership hazard
that the leak had been hiding became real at once. That commit already
fixed the batch it had identified (`dupToken` / declaration names / class
names / labels / object property names / parameter names / module
import-export names / TS enum + namespace). This document finishes the
remaining ledger.

### 1.1 Failure mechanism (the class C criterion)

`src/core/atom.zig`:

- `free()` decrements `ref_count`; at zero it calls `finalizeDeadEntry`
  (atom.zig:1519).
- `finalizeDeadEntry` does three things: unlinks the entry from
  `string_index` (`unindexEntry`), frees `entry.bytes` and clears it, and
  pushes the slot index onto the **LIFO** free list `free_slot_head`.
- `internDynamic` (atom.zig:1398) **pops the free-list head first** on a
  hash miss, and reuses the slot while keeping the same id
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
   `std.debug.assert(entry.hasLiveValue())` (atom.zig:1037): Debug /
   ReleaseSafe panic immediately. In ReleaseFast it pulls a dead entry
   that is already on the free list back to `ref_count` 1, after which
   the same slot is `finalizeDeadEntry`'d a second time and pushed onto
   the free list again — the free list now has a duplicate, and two later
   interns receive the same id.

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
ruling wants **the contract written in the code**. (A parallel Codex
scan classified most of this document's B sites as A, on the grounds that
"there is in fact an owner". There is no disagreement about the facts,
only about whether incidental ownership counts as B; this document uses
the strict bar.)

---

## 3. Site list

`fn` locations use line numbers from baseline `3d869065`. Six-field
abbreviations: **src** = atom source, **own** = token owner, **rel** =
owner release point, **use** = use interval, **dup** = whether dup'd,
**xfer** = whether ownership is transferred.

### 3.1 Class C (borrow crosses the owner)

#### C-1 `exportDefaultFunctionName` — src/parser.zig:18011 (`*` arm), 18014 (ordinary arm)

1. **src**: a lookahead token this function itself obtained from
   `s.lex.next()`; `next()` interned the name into the `.ident` payload.
2. **own**: that local lookahead token (`first` / `second`); the parser's
   `s.token` is not involved at all.
3. **rel**: this function's own `defer s.lex.freeToken(&first)` /
   `defer s.lex.freeToken(&second)` — **after the `return` expression is
   evaluated and before control returns to the caller**. So the return
   value is already dangling at the moment of return.
4. **use**: the caller finishes the entire `parseFunctionDecl` (including
   the body) before passing it to `addModuleExportName` →
   `Record.addExport` → `atoms.dup(...)`.
5. **dup**: none.
6. **xfer**: none. `Record.addExport` (bytecode.zig:1150) will dup, but
   it dups an **already-dead id**, which does not save it.

**CLASS: C** (proven; see §4)

#### C-2 `exportDefaultClassName` — src/parser.zig:18035

Same shape as C-1: the same save/restore + `defer freeToken` pattern,
returning `name.payload.ident.atom`; the caller uses it only after
`parseClass(s, true)` returns.

**CLASS: C** (proven; see §4)

C-1 / C-2 have five call sites (all in `parseExport`):

| Call site | Source shape |
|---|---|
| 17796 | `export default class C {}` |
| 17815 | `export default function f() {}` |
| 17828 | `export default async function f() {}` |
| 17961 | `export function f() {}` / `export function* f() {}` |
| 17981 | `export async function f() {}` |

It does not blow up today because the **first** intern inside
`parseFunctionDecl` / `parseClass` is exactly the same name: `advance()`
releases the `function` / `class` keyword token (a predefined atom;
`free` returns immediately and does not enter the free list), then
`lex.next()` interns the name and pops the slot that was just pushed.
One extra new-string intern in between and the free-list head is no
longer that slot.

#### C-3 `parseDeleteSuperReference` — src/parser.zig:8176 — **C-shaped, but unreachable**

1. **src**: `s.token.payload.ident.atom` (the current token).
2. **own**: `s.token`.
3. **rel**: the immediately following `try s.advance()` (`advance` first
   `freeToken(&self.token)`).
4. **use**: after `advance()`,
   `try s.emitOpAtom(opcode.op.push_atom_value, name)` →
   `appendAtomOperand` → `atoms.dup(name)`.
5. **dup**: none (its two live sibling paths `parseMemberChain`:8794 and
   `parseNewCalleeMemberAccess`:8748 both dup; only this one missed it).
6. **xfer**: none.

Worse, there is not even slot-reuse luck here: the next token interned
after `advance()` is `(`, punctuation that interns no string, so the
name's slot stays **empty** and `dup` hits the `hasLiveValue` assert
directly.

**However**: `parseDeleteSuperReference` and `isDeleteSuperReference`
have **no callers** anywhere in the tree (`grep -rn "DeleteSuperReference"
src/` finds only those two definition lines). Zig does not semantically
analyze unreferenced struct methods, so this code is neither reachable
nor type-checked. Under the ruling's evidence rules, an undemonstrable
hazard must be downgraded:

**CLASS: C-shape / UNREACHABLE** (not reachable from any JS source; the
owner was still filled in to match the live sibling paths; see §5.2)

### 3.2 Class B (correct, but not a contract)

#### B-1 `identifierLikeAtom` — src/parser.zig:9982

**src** current token / keyword; **own** `s.token`; **rel** the next
`advance()`; **use** decided by the caller; **dup** the caller's job;
**xfer** none. Neither the function name nor the signature says "this is
borrowed". Every caller today (`parseVar`:13061, `parseFunctionDecl`:13692,
`parseFunctionExpr`:13750, break/continue label:12083, enum
member:11386, and the parameter / pattern paths) **does** dup before
`advance()`, so it is in fact safe; that is twelve call sites each being
careful, not this helper's contract.

#### B-2 catch binding — src/parser.zig:12312

**src** current token; **own** `s.token`; **rel** the `advance()` at
12331; **use** `emitScopePutVar(catch_atom)` at 12332; **dup** none
(local); **xfer** yes — `defineVar(catch_atom, .catch_)` at 12330 leaves
a retain via `FunctionDef.appendVar` (bytecode.zig:3300
`atoms.dup(var_def.var_name)`), **exactly before `advance()`**. It holds
only because of that statement order ("defineVar before advance") plus
the downstream detail that `defineVar` dups; there is no local owner.

#### B-3 TS `enum` name — src/parser.zig:11359; B-4 TS `namespace` name — src/parser.zig:11472

Same shape as B-2, and the source already comments the intent ("Acquire
the declaration owner before advance releases the token's identifier
retain"). The owner is the var row created by `addScopeVar`; there is
still no local retain. Derived `s.last_declared_atom` (11454 / 11513 /
11541) and `s.current_namespace_atom` (11498 / 11529) store this borrowed
id into parser state; the read sites at 11507 / 11515 / 13195 / 14672 /
17342 are kept alive entirely by that one var row.

#### B-5 `State.last_class_decl_atom` — src/parser.zig:17155

**src** the **borrowed** id returned by `classNameAtom(s)`; **own**
`s.token`; **rel** the `advance()` at 17156; **use** 17976 (`export class
C {}` calls `addModuleExportName(s, name_atom, name_atom)` after
`parseClass` has already returned); **dup** none on the field itself
(the sibling `class_name` has a dup, but `parseClass`'s exit `defer`
releases it); **xfer** none. The liveness chain is **two spliced
segments**: inside `parseClass` it rides the local `class_name` dup;
after `parseClass` returns it rides the class-declaration binding's
`var_name` retain. The field itself is a pure borrow. A probe measured
refcount = 5 at the use site (§4.3), so it is live today; that is two
unrelated owners handing off.

#### B-6 `State.last_var_decl_atom` — src/parser.zig:13078

Write-only: the whole tree has only the declaration at 4060, a nulling
at 11708, and the assignment at 13078; there is no read site. It stores
the id of `parseVar`'s owned dup, and that dup is released when the
declaration clause ends. Harmless today (dead field), but it is a trap
that becomes class C the moment someone adds a read.

### 3.3 Class A (safe) summary

The following sites either establish an independent owner before the
token is released, or keep the entire use inside the token lifetime, or
receive a predefined / freshly interned owned atom.

| Site | Location | Why it is safe (six-field gist) |
|---|---|---|
| `keywordAtom` | 191 | returns a predefined constant; `free`/`dup` are no-ops |
| `LexerImpl.dupToken` | 412 | explicitly copies an owner; the comment is the contract |
| `forHeadHasNoTopLevelSemicolon` snapshot | 5509 | `dupToken` independent owner, defer returns it |
| `takeParserSnapshot` / `restoreParserLexerSnapshot` | 15748 / 15775 | same |
| lookahead family (`checkArrowHead` / `checkAsync*ArrowHead` / `nextRegexpAwareLookaheadToken` / `peekNextKind*`) | 5399-5490, 6875-7030 | read-only `token.val`; never touch the atom |
| `peekNextIsOfToken` | 5443 | borrow used only for `atomNameEquals`, before defer |
| `isIdent` / `isParameterModifier` | 5581 / 5590 | `name()` compare inside the current token |
| `labelStartAtom` + 12083 break/continue label | 5269 / 12083 | caller dups before advance (`8c8787cd`) |
| assignment LHS / primary identifier | 7093 / 9304 | dup before advance |
| private-name `in` | 7797 | `dup(private_atom)` + defer free |
| `new.target` / `import.meta` / escaped-reserved-word tests | 8679 / 9206 / 9248-9261 | pure compare inside the current token |
| `parseNewCalleeMemberAccess` / `parseMemberChain` (dot and optional chain) | 8748 / 8794 / 8854 | `retained_name = dup(name)` + defer free |
| `parseObjectPropertyName` | 9810 | `ObjectPropertyName.retained` marks the owner |
| `awaitUsingDeclarationStart` / `usingDeclarationStart` | 11022-11031 | compare inside the scanned token |
| enum member name | 11386 | dup before advance + defer free |
| `using` / for-of binding / for declaration binding | 12421 / 13310 / 13361 | dup before advance |
| `parseVar` simple binding | 13061 | dup before advance + defer free (qjs `js_parse_var`) |
| for-head `async of` test | 13385 | compare inside the current token |
| `parseFunctionDecl` / `parseFunctionExpr` name | 13692 / 13750 | dup before advance + defer free |
| parameters / rest / arrow parameters / pattern bindings | 13913, 14011, 14792, 14823, 14903, 15256 | `appendOwnedParserAtom` or dup before advance |
| `PatternTarget.defaultName` | 15105 | forwards an already-owned binding name |
| class private accessors / private field methods | 16081 / 16129 | `privateNameAtom` returns owned |
| `privateSetterAtom` / `newClassPrivateAtom` / computed-field temp atom | 16319 / 16704 / 16716 | newly created symbol; already owned |
| `classNameAtom` used as `class_name` | 16357→17153 | dup before advance + defer free (qjs `js_parse_class`) |
| `privateNameAtom` / `privateNameDeclarationAtom` / `findClassPrivateBoundName` | 16668 / 16676 / 16684 | returns owned or list-held |
| class private-name prescan | 17037 | `privateNameDeclarationAtom` owned + defer free |
| module default / namespace / named import names | 17527 / 17554 / 17592 | dup before advance; `*_live` flags manage transfer |
| `moduleStringAtom` / `moduleImportNameAtomOwned` | 17732 / 17744 | returns owned (`8c8787cd`) |
| import attribute key | 18073 | dup + defer free |
| `pending_function_name` / `function_expr_name_binding` / `active_with_atom` / label carriers | 4050 / 14157 / 13246 / 11612 | store an outer owned dup; field lifetime is strictly inside that dup |
| `current_parameter_properties` / `class_private_elements` / `class_private_bound_names` | 4008 / 16282 / 16647 | the list holds its own retain; `deinitOwnedParserAtoms` balances it |
| sink: `FunctionDef.appendVar/appendArg/appendGlobalVar/addClosureVar/appendAtomOperand` | bytecode.zig:3300-3370 / 3472 | always `atoms.dup` |
| sink: module `Record.add*` | bytecode.zig:1121-1198 | always `atoms.dup` (but that cannot save an already-dead input) |

---

## 4. Class C reachability evidence

Tool: `zig build zjs-dev` (Debug; `std.debug.assert` is live).

### 4.1 Probe: the return value is already dead at return

Temporary probes at the `parseExport` call sites printed
`atoms.refCount(atom)` and `atoms.name(atom)` (probes were not checked
in):

```
$ ./zig-out/bin/zjs-dev /tmp/expdef.mjs        # export default function zzqqUniqueDefaultFn(){}
[borrow-probe] exportDefaultFunctionName/return:    atom=710 refcount=null name=null
[borrow-probe] exportDefaultFunctionName/afterParse: atom=710 refcount=2    name=zzqqUniqueDefaultFn
```

`refcount=null` / `name=null` means the entry has already been
`finalizeDeadEntry`'d: bytes freed, removed from `string_index`, slot on
the free list. The second line shows it was **taken back** when
`parseFunctionDecl` re-interned the same string. All four call shapes
(`export default function` / `export default class` / `export function` /
`export async function`) have `refcount=null` at the return moment.

### 4.2 Perturbation: one extra intern in between and the luck is gone

In the same probed build, intern one extra string
(`__zjs_borrow_wedge__`, env-gated) after the helper returns and before
`parseFunctionDecl`:

```
$ ZJS_BORROW_WEDGE=1 ./zig-out/bin/zjs-dev /tmp/expdef.mjs
[borrow-probe] exportDefaultFunctionName/return:     atom=710 refcount=null name=null
[borrow-probe] wedge interned atom=710
[borrow-probe] exportDefaultFunctionName/afterParse: atom=710 refcount=1 name=__zjs_borrow_wedge__
SyntaxError: SYNTAX ERROR in /tmp/expdef.mjs:2:1 - UnexpectedToken
```

Atom 710 is stolen by the wedge and **rebound to another string**;
`addModuleExportName` then records `__zjs_borrow_wedge__` as the
`export default` local name, `validateModuleLocalExports` cannot find
that binding, and a fully legal module is reported as a syntax error.
`export default class` / `export function` / `export async function`
behave the same.

### 4.3 Control: the `export class C {}` `last_class_decl_atom` path is unaffected

```
[borrow-probe] lastClassDeclAtom/afterParseClass: atom=710 refcount=5 name=ZzqqUniqueExpCls
[borrow-probe] lastClassDeclAtom/afterWedge:      atom=710 refcount=5 name=ZzqqUniqueExpCls   (wedge received atom=712)
```

Use-site refcount = 5; the wedge cannot take its slot. This is B-5, not
C.

### 4.4 Global detector: delay slot reuse by one death

> The audit-time form was a temporary patch; it is now the
> `-Dzjs_ownership_audit` build option, see §7.

To go beyond known suspects, `AtomTable` gained a **one-slot quarantine**
(audit-time: temporary, not checked in): a just-dead slot enters
quarantine first and only joins the free list after another slot dies.
"Free an atom, then immediately re-intern the same string" can no longer
recover its own id, so any borrowed-atom use-after-free hits `dup`'s
`hasLiveValue` assert. Unlike turning reuse off entirely, this does not
change table size and does not disturb teardown invariants.

Before the fix, the detector hit **already-checked-in unit tests**
directly:

```
src/core/atom.zig: std.debug.assert(entry.hasLiveValue());   in dup
src/bytecode.zig:1151                                        in addExport
src/parser.zig:17651                                         in addModuleExportName
src/parser.zig:17963                                         in parseExport
src/tests/parser.zig:4814  test "W5: generator parameter boundary ..."
    parseModuleStatement(&env, "export function* g(x = 1) { yield x; }")
```

The `export default class` shape is not a panic under the detector but a
**silent wrong value**: the stale id is released from quarantine and
reused for another string, so a legal module reports
`SyntaxError: UnexpectedToken`.

After the fix, the same detector build:

- `zig build test`: **2064 passed / 0 failed**.
- Custom corpus (delete-super, member access, private names, every
  declaration shape, five export shapes, generator/async/arrow/static-
  block): all green.
- test262 subtrees (Debug runner + detector): `language/module-code` 599,
  `language/statements` 9337, `language/expressions/class` 4059,
  `language/import` 127, `language/function-code` 217,
  `language/identifiers` 268, `language/export` 3, total **14,611 cases,
  0 errors**.

### 4.5 A negative conclusion that must be recorded

A full 49,775-case Debug test262 runner hits
`src/core/runtime.zig:1294 assert(self.memory.allocation_count == 1)` at
about 7,000 cases. This is a **pre-existing issue, unrelated to this
audit**: removing the detector patch entirely and rebuilding
`run-test262-dev` from clean `3d869065` crashes at the same place and
the same progress. So §4.4's test262 coverage was run by subtree, not as
one full pass. (The official `test262-gate` uses the ReleaseFast runner,
where asserts are compiled out, and is not evidence for this audit.)

---

## 5. The fix (class C only)

### 5.1 `export default` / `export` name lookahead

`exportDefaultFunctionName` → `exportDefaultFunctionNameOwned`,
`exportDefaultClassName` → `exportDefaultClassNameOwned`:
`s.function.atoms.dup(...)` inside the `return` expression. Zig evaluates
`return expr` before running `defer`, so the dup happens before the token
is released. Each of the five call sites has
`defer s.function.atoms.free(name_atom)`.

The naming matches `moduleImportNameAtomOwned` from `8c8787cd`: the
`*Owned` suffix is the "caller frees" contract.

### 5.2 `parseDeleteSuperReference` (unreachable)

Filled in `const retained_name = s.function.atoms.dup(name); defer
...free(retained_name);` to match its two live sibling paths
(`parseMemberChain`, `parseNewCalleeMemberAccess`), and the emit site
now uses `retained_name`. Because Zig does not analyze unreferenced
functions, this change was compile-checked once with
`comptime { _ = &parseDeleteSuperReference; }` and then that pin was
removed.

These two dead functions were **not** deleted in that commit — deleting
dead code is a different job, not part of the ownership ledger.

### 5.3 Why that commit had no accompanying regression test

Observing this bug requires breaking slot-reuse luck, and §3.1 already
showed that under the current parse order there is **no JS-source-
controlled insertion point** between `exportDefault*Name` releasing the
name and `parseFunctionDecl` / `parseClass` re-interning the same string
(only a predefined keyword token's no-op `free` sits in between). So a
black-box regression that is red before the fix and green after cannot
be written; the atom-table balance asserts of the `8c8787cd` kind also
balance before the fix (the dead atom is taken back by the same-name
re-intern, then `addExport`'s dup and the record's free still pair).

The only durable way to keep this invariant is to productize the §4.4
detector — now landed as `-Dzjs_ownership_audit`, see §7; §7.4 gives the
"revert this fix → the audit build panics immediately" reproduction,
which is this fix's regression-test shape (a black box still cannot be
written). Until then, the fix is backed by the one-shot probe experiments
in §4.1/§4.2 and the all-green detector run in §4.4.

The runtime detector only speaks when a test actually reaches that path.
The half that forbids the source shape itself is §8:
`tools/architecture/check_borrowed_atoms.js`. Both halves together are
the usable stand-in for a "regression test" for this bug class.

---

## 6. Follow-ups (out of that commit's scope)

Per the ruling, class B is promoted in place only when the change is
"small and obviously correct". The items below do not meet that bar, or
would drag in unrelated subsystems, so they are registered as follow-up:

1. **B-5 turn `last_class_decl_atom` into an owned field.** Requires
   releasing the old value on assign and releasing a leftover in
   `State.deinit`, which touches parser-lifetime teardown. Prefer doing
   it together with "have `parseClass` return the class-name owner
   directly and drop this cross-function state field".
2. **B-6 delete `last_var_decl_atom`.** Write-only dead field; deleting
   it is cleanup, not an ownership fix.
3. **B-1 make the `identifierLikeAtom` contract explicit.** Low-risk
   rename to `identifierLikeAtomBorrowed` plus a doc comment, with an
   optional `...Owned` companion. Twelve call-site mechanical renames;
   cleaner as its own cut.
4. **B-2 / B-3 / B-4 localize the owner.** Catch bindings, TS enum, and
   TS namespace all become "dup + defer free first, then `defineVar` /
   `addScopeVar`", so liveness is a local contract instead of "the
   downstream sink happened to dup". The two TS items also involve
   `last_declared_atom` / `current_namespace_atom`; they close only if
   changed together.
5. **Dead code `isDeleteSuperReference` / `parseDeleteSuperReference`**:
   no callers, and Zig does not analyze them. Either wire them into the
   `delete` parse path or delete them.
6. ~~**Consider turning the §4.4 quarantine detector into a build
   option** so "borrow crosses owner" stays detectable in CI instead of
   only as a temporary audit patch.~~ **Landed**:
   `-Dzjs_ownership_audit`, see §7.

Items 1-4 are **no longer only written in this document**: each has an
entry in `tools/architecture/borrowed-atoms-allowlist.json` with a
`reason` and `exit_milestone` (the milestone text cites this section's
numbering). Finish an item, delete the matching entry; if you do not,
the checker goes red because the entry went stale. So both "fixed it and
forgot to close the ledger" and "quietly added another same-shape site"
are blocked by the gate. See §8.

---

## 7. Audit build `-Dzjs_ownership_audit` (productized §4.4 detector)

The landing commit is the commit that added this file; the implementation
is in `src/core/atom.zig` (`AtomTable.OwnershipAuditState` plus the reuse
arm of `finalizeDeadEntry`), the option is in `build.zig`, and it uses
the same option distribution as `zjs_force_gc` / `zjs_nan_boxing`
(`engine_options` / `plugin_fixture_options` / `profile_engine_options` /
`test_options`).

### 7.1 What it does

A slot freed by `finalizeDeadEntry` waits one round in a **one-slot
quarantine** and only joins the free list after the next slot dies. So
"free an atom, then immediately re-intern the same string" can no longer
recover the same id, and §1.1 case 1's "luck of slot reuse" is gone: a
stale id whose borrow crossed its owner either points at an empty slot
(`dup` hits `hasLiveValue`; Debug / ReleaseSafe panic immediately) or,
after one more intern, points at another string (wrong value, exposed by
the caller's own checks).

**Why one slot instead of turning reuse off** (this is also in the code
comment): reuse is only delayed by one death, so the table's steady-state
size grows by that one quarantined slot — `entries` count, `next_id`
growth, and `deinit` teardown invariants stay the default-build ones.
Turning reuse off entirely would let the table grow monotonically with
intern/free churn; the audit itself could then turn a high-churn test
into an OOM or a failure under a different table geometry, and what it
found would not be trustworthy.

`src/tests/core.zig` has a liveness self-check (`ownership audit
quarantines the most recently freed atom slot`): `SkipZigTest` when the
audit is off; when it is on, it asserts "the just-dead slot is not taken
by the next intern, but is reused after one more slot dies". Flip the
quarantine back to a direct free-list push and this test goes red
immediately. Without it, the audit mode can be broken while CI stays
green — exactly the silence this option exists to kill.

### 7.2 Mode: the ASAN / leak-checker tier

For CI, fuzzing, and reproduction. **Off by default, never in
ReleaseFast, never on a production path.** When off, the whole mechanism
disappears at comptime: `OwnershipAuditState` collapses to an empty
struct; fields, code, and even the names stay out of the binary.

Measured zero production cost (2026-08-02, this tree, default
`zig build zjs` ReleaseFast):

- `nm -a zig-out/bin/zjs | grep -i quarantin` and
  `strings -a zig-out/bin/zjs | grep -i quarantin` both 0 hits
  (the binary only keeps the option name itself inside the
  build_options blob, same as `zjs_force_gc`);
- The default binary's `.text` is **byte-for-byte identical** to an
  empty-control build that only adds one comment line to `atom.zig`
  (`44c58c48…`, 3,851,804 B), so this change has zero effect on default-
  build machine code; the whole-binary sha differs only in build_options
  and debug info. (The control is required: any rebuild that touches
  `atom.zig` will shift layout relative to a cold build, and without a
  control that lottery is misread as cost.)
- `tools/perf/codeload/run_codeload_micro.py --a <empty control> --b
  <this change> --samples 8 --cpu 19`: compile-mode instructions median
  **1.00000** MAD 0.00000 (23,102,180,030 → 23,102,190,161); atom mode
  (intern miss + free-slot churn) instructions median **1.00000** MAD
  0.00000 (24,351,531,576 → 24,351,501,514).

### 7.3 How to run it

```bash
zig build test        --summary all -Dzjs_ownership_audit=true   # unified suite
zig build test-parser               -Dzjs_ownership_audit=true   # one subtree, faster isolation
zig build test-oom    --summary all -Dzjs_ownership_audit=true
zig build zjs-dev                            -Dzjs_ownership_audit=true   # hand corpus
zig build run-test262-dev                    -Dzjs_ownership_audit=true   # test262 subtree
./zig-out/bin/run-test262-dev -c test262.conf -d test262/test/language/module-code
```

Asserts are live only in Debug / ReleaseSafe (`std.debug.assert`).
Turning the option on under ReleaseFast is pointless: `dup`'s assert is
compiled out, and quarantine would only scramble slot assignment for
nothing.

**Run test262 by subtree; do not run the full set in one go.** The Debug
runner hits `src/core/runtime.zig:1294`
`std.debug.assert(self.memory.allocation_count == 1)` at about 7,000
cases. That is a **pre-existing issue, unrelated to this audit**: remove
the audit patch entirely, rebuild `run-test262-dev` from clean
`3d869065`, and it crashes at the same place and the same progress
(§4.5). So run with `-d test262/test/language/<subtree>` — that is how
the 14,611 cases in §4.4 were produced.

### 7.4 It still catches the original defect (reproducible)

Temporarily revert the `ada949be` parser hunk in the worktree:

```bash
git show ada949be -- src/parser.zig | git apply -R --3way
# exportDefaultClassName conflicts with 1906d45c (lexer position restore
# before a fallible peek): keep 1906d45c's order, only drop the dup.
```

Then:

- `zig build test-parser --seed 0` (audit **off**) → **474 passed / 0
  failed**. That is the masking §5.3 described: black-box tests cannot
  see this use-after-free.
- `zig build test-parser --seed 0 -Dzjs_ownership_audit=true` → SIGABRT:

```
thread panic: reached unreachable code
src/core/atom.zig:1069:29         in dup    std.debug.assert(entry.hasLiveValue());
src/bytecode.zig:1151:53          in addExport
src/parser.zig:17651:25           in addModuleExportName
src/parser.zig:17963:58           in parseExport
src/tests/parser.zig:4814:42      in test.W5: generator parameter boundary emits
                                     initial_yield in scripts and modules
    var module = try parseModuleStatement(&env, "export function* g(x = 1) { yield x; }");
```

`git checkout -- src/parser.zig` restores current main and the same
command is all green. That is the only usable red → green shape for this
bug class: not a black-box regression, but a **behavior delta of existing
tests under the audit mode**.

---

## 8. Static rule `check_borrowed_atoms.js` (forbid the "borrow escapes" source shape)

Landing: `tools/architecture/check_borrowed_atoms.js` +
`tools/architecture/borrowed-atoms-allowlist.json`, hung on
`checkpoint-check` and `engine-production-gate` (same layer and allowlist
shape as `check_deps.js` / `check_oom_panics.js`). Scan range
`src/**.zig` (excluding `src/tests/`).

### 8.1 Why it is needed — it and §7 each cover half

§5.3 showed a black-box regression cannot be written. The two remaining
tools each cover only half:

| | `-Dzjs_ownership_audit` (§7) | `check_borrowed_atoms.js` (this section) |
|---|---|---|
| When it fires | runtime | review / CI static |
| Criterion | after one-slot quarantine, a stale id hits `dup`'s `hasLiveValue` assert or reads a wrong value | source shape: a borrowed atom escapes the token lifetime |
| Catches | a crossed borrow that actually executed, including paths this document did not think of | every newly written same-shape site, even with no test coverage today |
| Misses | paths with no test coverage; ReleaseFast (asserts compiled out); unreachable code (e.g. C-3) | ownership that only exists at runtime (a third-party sink happens to dup); cross-function / cross-file propagation; see §8.6 |

`ada949be`'s class C is exactly "statically obvious, runtime-invisible
except by luck": `return <token>.payload.ident.atom` plus `defer
freeToken` at function exit. So this rule's first-principles goal is
**to make that shape unbuildable at the gate forever**.

### 8.2 The rule itself

Three sources of a **borrowed atom**:

1. `<token>.payload.<field>.atom` in a **value position** — a read in
   **argument position** such as
   `atomNameEquals(s, s.token.payload.ident.atom, "of")` is consumed
   inside the token lifetime and is not a borrow (34 token-atom reads
   therefore collapse to 10 true borrows; that is the main precision
   win); builtins such as `@as` / `@intCast` are transparent and the
   scan walks through them;
2. the return value of a same-file helper that itself returns a borrowed
   atom — the helper set is computed by fixed-point iteration and is
   currently `identifierLikeAtom` / `classNameAtom` / `labelStartAtom`;
3. a binding (`const` / `var`) or reassignment (`nm = ...`) of either of
   the above; `const` declarations also do one layer of local contagion
   (`const name = private_atom orelse raw_name;`). Contagion only
   follows **value-preserving expressions**: `const hit = nm == other;`
   produces a bool, not an atom, and a compare / boolean op at the top
   level breaks the chain. Rebinding to an owned value
   (`nm = atoms.dup(nm);`) **closes** that borrow site's window.

Ownership is judged **by position**, not "this statement mentioned
`dup`": `.dup(x)` puts `x` in argument position, so a "duped read" is
not a borrowed read at all. Thus the else arm of
`return if (c) atoms.dup(a) else t.payload.ident.atom;` still fails —
a whole-statement "contains dup, so allow" rule would miss it.

**Four escape rules** (one report per borrow site, highest-priority
rule wins):

| pattern | Forbidden shape |
|---|---|
| `borrowed-return` | `return` a borrowed atom (= the `ada949be` bug) |
| `borrowed-state-store` | store a borrowed atom into a long-lived `State` atom field (the field outlives the token) |
| `borrowed-use-after-release` | read it in the same function after a non-`defer` `advance()` / `freeToken()` |
| `owned-escape-state-store` | store a local held only by `defer ...free(x)` into a long-lived atom field that this function does not restore (= the B-6 shape) |

"Long-lived atom field" is not a hardcoded list: the checker scans the
struct scope for every `Atom` / `?Atom` field name (skipping function
bodies, so multi-line parameter lists are not treated as fields), then
requires the receiver to be the name bound to `*State` in this
function's signature. A newly added field of the same kind is covered
the same day, and a neighboring struct's own `self.<atom field>` is not
mis-fired.

**Three legal shapes** (preferred order):

1. Take ownership in the escaping expression itself: `.dup(` /
   `.internString(` / `.newSymbol(` / call some `*Owned(`;
2. Function name ends in `Owned` (existing convention:
   `moduleImportNameAtomOwned`, `exportDefaultFunctionNameOwned`) —
   **exempts only `borrowed-return`**, and only "forwarding someone
   else's borrow" (a helper result / a contagious local that static
   analysis cannot prove), **never a direct return of a token-payload
   read**, because that is `ada949be` itself; the body must actually
   have produced an owner, or the suffix is an empty check (see §8.4);
3. Write `// borrowed-atom: <reason>` on the line immediately above.
   The reason cannot be empty — if you cannot write a reason, the
   contract does not exist. Rules A / B only honor a mark above the
   **escape line**; rule C also allows it above the borrow line (that
   is the natural place to say "this borrow is deliberate").

**Allowlist**: fields `source` / `pattern` / `reason` / `exit_milestone`,
plus optional `fn` (containing function) and `contains` (statement
substring) selectors. Each entry must hit exactly one finding; a miss is
stale (red), a multi-hit is non-unique (red), two entries grabbing the
same finding is overlapping (red). Cap 16 entries; currently 14.

### 8.3 The current 14 entries = the machine-readable form of this document's class B

```
src/parser.zig:5273   borrowed-return             labelStartAtom
src/parser.zig:7093   borrowed-use-after-release  parseAssignExpr2
src/parser.zig:9988   borrowed-return             identifierLikeAtom                 <- B-1
src/parser.zig:11364  borrowed-state-store        parseEnumDeclaration               <- B-3
src/parser.zig:11477  borrowed-state-store        parseNamespaceDeclarationWithIdent <- B-4
src/parser.zig:12316  borrowed-use-after-release  parseStatementOrDeclSlow           <- B-2
src/parser.zig:12426  borrowed-state-store        parseUsingDeclaration
src/parser.zig:13083  owned-escape-state-store    parseVar                           <- B-6
src/parser.zig:13366  borrowed-use-after-release  parseForInOf
src/parser.zig:13699  owned-escape-state-store    parseFunctionDecl
src/parser.zig:13918  borrowed-use-after-release  parseFunctionParameters
src/parser.zig:14828  borrowed-use-after-release  parseArrowFunction
src/parser.zig:16362  borrowed-return             classNameAtom                      <- B-5 root cause
src/parser.zig:17156  borrowed-state-store        parseClass                         <- B-5 field
```

Seven land directly on B-1…B-6 in this document. **The other seven land
in the §3.3 class A table**; that is not a false positive, it is an
inconsistent bar in those rows: their safety reasons say "caller dups
before advance" / "`appendOwnedParserAtom` / `defineVar` will dup" —
i.e. the owner is **elsewhere**, which is exactly §2's definition of
class B ("liveness depends on a third-party owner unrelated to this
site"). Each was re-checked (every allowlist entry's `reason` names that
third-party owner):

- `labelStartAtom` forwards `identifierLikeAtom`'s borrow → same shape
  as B-1;
- `parseAssignExpr2`'s `direct_lhs_atom` is still used to name an
  anonymous function after `parseCondExpr` consumed the token, held up
  by the atom operand `emitScopeGetVar` emitted and by that direct
  lvalue's `LValue.name` (`owns_name = true`);
- `parseUsingDeclaration` / `parseForInOf` / `parseFunctionParameters` /
  `parseArrowFunction` are all "let `defineVar` or
  `appendOwnedParserAtom` build an owner, then `advance()`, then keep
  using the borrowed id" — word-for-word the B-2 catch-binding shape;
- `parseFunctionDecl`'s `s.last_declared_atom = name_atom` is the B-6
  shape (the dup is released by this function's exit defer, but the
  field keeps the id; later owners are the declaration var row and
  `FunctionDef.init`'s `func_name` dup).

Conclusion: under this document's strict bar those seven were already B,
registered as follow-up (§6) rather than violations, matching the
ruling. **No finding lands on a genuinely safe class A site**
(`dupToken` snapshot family, pure compares, predefineds,
`privateNameAtom`-style helpers that return owned,
`parseMemberChain` / `parseNewCalleeMemberAccess`'s `retained_name`
shape, and the three `*Owned` siblings are all zero hits).

### 8.4 Precision and strength measurements

**(1) It catches the original defect.** Temporarily rebuild the pre-
`ada949be` shape in the worktree (`exportDefaultClassNameOwned` renamed
back to `exportDefaultClassName`, `dup` removed from the `return`):

```
Borrowed-atom rule violations:
  src/parser.zig:18063: in exportDefaultClassName: return if (name.val == tok.TOK_IDENT) name.payload.ident.atom else null;
    rule A: a borrowed atom must not be returned (dup it, or name the function ...Owned)
```

`git checkout -- src/parser.zig` is all green again.

**(2) Synthetic precision matrix** (temporary `.zig` under `/tmp`, not
checked in; all 16 cases matched expectation):

| Shape | Expected | Measured |
|---|---|---|
| pre-fix class-C return | red | red |
| `return dup(t.payload.ident.atom)` | green | green |
| argument-position read (`atomNameEquals(...)`) | green | green |
| fake sample inside a Zig multiline `\\` string | green | green (initially a false positive; fixed by dropping the whole line in `stripCode`) |
| commented-out escape | green | green |
| read a borrowed local after `advance()` | red | red |
| `// borrowed-atom:` mark | green | green |
| **mixed branch** `return if (c) dup(a) else t.payload...;` | red | red (whole-statement owned judgment would miss this; fixed by judging by position) |
| **`Owned` suffix + an unrelated dup** | red | red (suffix does not exempt a direct token-payload read) |
| `return @as(Atom, t.payload...)` | red | red (builtin is transparent) |
| `var nm: Atom = undefined; nm = t.payload...; return nm;` | red | red |
| use `hit` after `const hit = nm == other;` | green | green (compare result is not an atom) |
| multiline `defer { freeToken(&t); }` treated as an inline release point | green | green |
| reuse after `nm = atoms.dup(nm);` | green | green (owned rebind closes the borrow window) |
| one-line `fn nothing() void {}` eating the next function's body | green | green |
| a non-State struct's own `self.<atom field> = ...` | green | green |

Scale (current main): 152 Zig files / 9,187 functions scanned, 34
token-atom reads of which 10 are in value position, 26 borrow sites
tracked, 14 escapes, all 14 allowlisted, 0 violations. Two runs produce
byte-identical output.

### 8.5 How to run it

```bash
mise run checkpoint-check                                # the gate (includes this rule)
node tools/architecture/check_borrowed_atoms.js          # this rule only
node tools/architecture/check_borrowed_atoms.js --list   # list each finding + the borrowed-helper set
```

### 8.6 What it cannot catch (honest list)

- **Borrows on parameters**: only bindings inside the function body are
  tracked. `fn f(s: *State, name: Atom)` storing a borrowed `name` into
  a long-lived field, or wrapping it into a returned struct, is not
  caught — `definePatternBindingAtom` is exactly that shape (it wraps
  the borrowed name into `PatternTarget.direct_binding.name` and
  returns it; today it is held up by the var row `defineVar` builds).
  Consequence: after a borrow is passed as an **argument** to such a
  wrapper, the return value is no longer treated as borrowed.
- **Cross-file propagation**: the borrowed-helper set is a per-file
  fixed point; it does not cross files or structs. That is enough today
  (token payloads are only read in `src/parser.zig`); a layout change
  needs a re-evaluation.
- **Release points are literals only**: `advance()` / `freeToken()`.
  Helpers such as `expectToken` that **advance internally** are not
  release points (no interprocedural summary), and there is no
  path-sensitive analysis — an `advance()` that runs on only one branch
  counts as a release for every later line in the function.
- **Block-head truncation**: the return expression of a multiline
  `return .{ ... }` / `return switch (...) {` is cut at `{`. A pure
  forwarding wrapper can be missed. That is the precision price: better
  to miss one forwarding layer than to treat a whole switch body as one
  return expression.
- **Limited `Owned` suffix strength**: it can block "the body never
  produced an owner" and "direct return of a token-payload read"; it
  cannot block "dup some other atom, then forward a borrowed helper
  result".
- **Ownership that only exists at runtime**: whether a sink dups, and
  how long a third-party owner lives, is not visible statically. That
  is why every allowlist entry must write `reason` (who is holding it)
  and `exit_milestone` (how to turn it into a local contract).
- **`test` / `comptime` blocks are not function bodies**, so their code
  is not analyzed; the scan range also excludes `src/tests/`.
