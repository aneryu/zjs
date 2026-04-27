# Parser Rewrite Plan

Last updated: 2026-04-27 (revision 2 — strong-alignment review)

This plan covers the work to remove the fixture-driven `QuickParser` and the
matching fixture-driven bytecode/VM substrate, replacing them with a real
QuickJS-aligned frontend, opcode ABI, and VM dispatcher. It is the durable
reference for the parser-rewrite track and supersedes any incremental parser
fix recorded in `TRACKING.md`.

> **Revision 2 (this update) tightens the alignment with QuickJS.** It adds
> the strong-alignment contract in §1, the QuickJS source-of-truth
> inventory in §1.5 (every QuickJS function/struct we mirror, with line
> numbers), and per-phase QuickJS reference subsections that pin every
> implementation step to a concrete `quickjs.c:<line>` location. Zig
> structs and functions take their QuickJS counterpart names verbatim
> (modulo `JS` prefix and snake-case → camelCase). Deviations require an
> entry in `docs/quickjs-redesign/matrices/parser-deviation-matrix.md`.

> **Pre-flight finding (2026-04-27).** A full audit of every `pub const known.*`
> in `src/engine/bytecode/emitter.zig` against the canonical
> `quickjs/quickjs-opcode.h` index map shows that **only 7 of 95 opcodes
> share the QuickJS index by accident, 27 are mis-indexed (zjs and QuickJS use
> the same name but different ids), and 61 are bespoke high-level opcodes
> that do not exist in QuickJS at all**. Most of the 61 bespoke opcodes
> currently occupy ids that QuickJS reserves for unrelated real opcodes
> (e.g. `zjs.array_method = 169` clashes with QuickJS `instanceof`,
> `zjs.set_prop = 171` clashes with QuickJS `eq`,
> `zjs.new_typed_array = 179` clashes with the temporary scope opcode
> `enter_scope`). See §2.5 for the full audit and the implications for F2/F3.

## 0. Why a Plan This Big

`run-test262` currently reports ~36 698 / 48 205 errors. A focused first-5 000
slice was instrumented and bucketed; the breakdown is:

| Bucket | Count | Share |
|---|---|---|
| `SyntaxError` (parser fallback) | 3 495 | 78% |
| `TypeError` | 682 | 15% |
| `Test262Error` | 296 | 7% |
| `InvalidLength` | 7 | <1% |

So roughly four out of every five failures never even reach execution; they
are emitted by `setFallbackSyntaxError` in `src/engine/frontend/parser.zig`
because `compileQuickProgram` cannot recognise the source. This is consistent
with the recorded redesign state: the existing `QuickParser` is a hand-written
token-driven lowerer with hard-coded recognisers for fixture shapes
(`isHarnessFunctionName`, `peekSetLikeObjectLiteralShape`,
`peekMapPrototypeSetGetterThrowDefinition`, `parseForOfArrayStatement`,
`parseDateTryCatch`, `parseUriTryCatch`, …) plus fixed-size scratch arrays
(`regexp_var_names[16]`, `date_var_names[16]`, `int_var_names[16]`, …).

The bytecode the parser emits is also not a real bytecode. `bytecode/emitter.zig`
exposes a custom set of high-level opcodes — `array_method`, `string_method`,
`math_call`, `regexp_method`, `date_method`, `uri_call`, `parse_int`,
`new_collection`, `new_promise`, `promise_static`, `new_regexp`,
`new_string_object`, `new_typed_array`, `new_dataview`, `new_closure`,
`call_closure`, `object_keys`, `json_stringify`, `factorial`, … — none of
which exist in `quickjs/quickjs-opcode.h`. The VM dispatcher in
`src/engine/exec/vm.zig` matches that custom set and has no real local-variable
indexing (`get_loc/put_loc`), no closure-variable indexing (`get_var_ref`), no
stack manipulation primitives (`dup/swap/perm3/nip`), no proper try/catch/finally
opcodes (`catch/gosub/ret/nip_catch`), no proper iterator protocol opcodes
(`for_of_start/iterator_next/iterator_close`), and no label-resolved
`if_true/if_false/goto`.

A general-purpose parser cannot emit anything useful against this VM, so a
"parser fix" must include an opcode ABI swap and a generic VM dispatcher. The
plan below is the staged programme that gets us there without breaking the
fixture/curated-slice gates we already pass.

## 1. Design Principles

- **QuickJS is the single source of truth.** `quickjs/quickjs-opcode.h` is the
  only legal opcode set. `quickjs/quickjs.c` (`js_parse_*`, `resolve_variables`,
  `resolve_labels`, `js_create_function`, `compute_stack_size`,
  `compute_pc2line_info`) is the algorithm reference. Every emitted byte must
  correspond to a `DEF(...)` entry in `quickjs-opcode.h`. Predefined atoms must
  match `quickjs/quickjs-atom.h` order and spelling (the existing 229-entry
  table in `src/engine/core/atom.zig` already does).
- **Three-phase compilation matches QuickJS exactly.**
  - *Phase 1* (`parse` → `JSFunctionDef.byte_code`): the parser emits
    temporary opcodes only. Allowed Phase-1 ops: `enter_scope / leave_scope /
    label / scope_get_var / scope_put_var / scope_make_ref / scope_get_ref /
    scope_put_var_init / scope_get_var_undef / scope_delete_var /
    scope_get_private_field / scope_get_private_field2 /
    scope_put_private_field / scope_in_private_field / get_field_opt_chain /
    get_array_el_opt_chain / set_class_name / source_loc`. Variable
    references stay symbolic by atom + scope_level.
  - *Phase 2* (`resolve_variables`, `quickjs.c:33622`): one linear scan that
    walks the lexical chain, calls `resolve_scope_var` (`quickjs.c:32377`)
    per reference, replaces `scope_get_var` with
    `get_loc`/`get_arg`/`get_var_ref`/`get_var`/`get_var_undef`/`put_*`,
    builds `closure_var[]` via `get_closure_var` (`quickjs.c:32162`), drops
    `enter_scope / leave_scope`, materialises `OP_check_define_var` for
    eval-global declarations, and emits the first label pass setting
    `LabelSlot.pos2`.
  - *Phase 3a* (`resolve_labels`, `quickjs.c:34197`): inject the function
    prologue (`special_object` for `home_object`, `this`, `arguments`,
    `new.target`; `set_loc_uninitialized` for derived-class `this`),
    rewrite absolute jumps to relative `goto8`/`goto16`, drop `OP_label`,
    coalesce adjacent ops (`get_loc0_loc1`), call `put_short_code`
    (`quickjs.c:34140`) and `push_short_int` (`quickjs.c:34120`) for
    locals/args/var-refs/calls/integer literals.
  - *Phase 3b* (`compute_pc2line_info`, `quickjs.c:33995`): produce the
    `pc2line_buf` line/column table.
  - *Phase 3c* (`compute_stack_size`, `quickjs.c:35167`): BFS the bytecode
    graph, fill `stack_size`. Emission fails if any path exceeds
    `JS_STACK_SIZE_MAX`.
- **Strong-alignment contract.**
  - Every Zig data structure that has a QuickJS counterpart **must use the
    QuickJS struct name** (e.g. `FunctionDef` for `JSFunctionDef`,
    `VarDef` for `JSVarDef`, `VarScope` for `JSVarScope`, `ClosureVar`
    for `JSClosureVar`, `BlockEnv` for `BlockEnv`, `LabelSlot` for
    `LabelSlot`, `Token` for `JSToken`, `ParseState` for `JSParseState`,
    `FunctionBytecode` for `JSFunctionBytecode`).
  - Every parser function that has a QuickJS counterpart **must use the
    QuickJS function name** (e.g. `parseProgram` ↔ `js_parse_program`,
    `parseAssignExpr2` ↔ `js_parse_assign_expr2`, `parseExprBinary` ↔
    `js_parse_expr_binary`, `parseUnary` ↔ `js_parse_unary`,
    `parsePostfixExpr` ↔ `js_parse_postfix_expr`, `parseFunctionDecl2`
    ↔ `js_parse_function_decl2`, `parseDestructuringElement` ↔
    `js_parse_destructuring_element`, `parseClass` ↔ `js_parse_class`).
  - Every algorithm step **must cite the QuickJS source location**
    (`quickjs.c:<line>`) where the same step lives. Deviations from the
    QuickJS algorithm require a recorded justification in
    `docs/quickjs-redesign/matrices/parser-deviation-matrix.md`.
  - Token kinds align with the QuickJS `TOK_*` enum (`quickjs.c:21246`):
    `TOK_NUMBER / TOK_STRING / TOK_TEMPLATE / TOK_IDENT / TOK_REGEXP /
    TOK_MUL_ASSIGN..TOK_DOUBLE_QUESTION_MARK_ASSIGN / TOK_DEC / TOK_INC /
    TOK_SHL / TOK_SAR / TOK_SHR / TOK_LT..TOK_STRICT_NEQ / TOK_LAND /
    TOK_LOR / TOK_POW / TOK_ARROW / TOK_ELLIPSIS /
    TOK_DOUBLE_QUESTION_MARK / TOK_QUESTION_MARK_DOT / TOK_PRIVATE_NAME /
    TOK_EOF`, plus the keyword block `TOK_NULL..TOK_AWAIT` whose order
    matches `quickjs-atom.h` (this match is what makes
    `s->token.u.ident.atom` valid for keyword tokens).
- **No fixture recognisers.** Every `peek*`, `parseSynthetic*`,
  `parseFor*Statement`, `parseHarness*`, `parseDate*`, `parseUri*`,
  `parseClassify*`, `parseClosureVar*`, `parseSimpleCall`, `isHarness*`,
  `isLiteralIdentifier`, `isStrictImmutableGlobalName` and the matching
  fixed-size `*_var_names[16]` scratch buffers must be deleted. As each
  fixture recogniser disappears the matching high-level opcode goes with it.
- **Test262 numbers gate every phase.** Each phase exits on a real
  `language/<dir>` or `built-ins/<dir>` pass-rate target measured by the
  runner, not on fixtures or curated slices. Pass-rate must never go down.
- **No shortcuts.** No new `peek*` / `parseSynthetic*` / fixture recognisers.
  No new high-level opcodes (`*_method` / `*_call` / `*_static` shapes that
  do not exist in `quickjs-opcode.h`). No widening of
  `quickjs/test262_errors.txt`, no new `feature=skip` entries, no new
  `excludefile` entries, no shrinking of `testdir`/`testfile`/`testindex`
  ranges to inflate pass rates.

## 1.5. QuickJS source-of-truth inventory

The locked QuickJS baseline is `64e64ebb1dd61505c256285a699c65c42941c5ed`
(`TRACKING.md`). Every phase below cites concrete QuickJS files and line
numbers; any change in the locked baseline must be reflected by a
`QUICKJS_BASELINE_SHA` bump and a re-audit.

### 1.5.1 Files mirrored bit-for-bit (no semantic deviation allowed)

| QuickJS file | Local sibling | What we mirror |
|---|---|---|
| `quickjs/quickjs-opcode.h` | `src/engine/bytecode/opcode.zig` (ParsedTable + comptime `op` enum) | every `DEF`/`def` row, in order, by index |
| `quickjs/quickjs-atom.h` | `src/engine/core/atom.zig` (`predefined_atoms[229]`) | every `DEF(name, str)` row in order; ids 1..229 reserved for predefined atoms |

### 1.5.2 Algorithms mirrored function-by-function

| QuickJS function | Source location | Local mirror | Phase |
|---|---|---|---|
| `js_parse_program` | `quickjs.c:36401` | `frontend/parser.zig: parseProgram` | F4-F8 |
| `js_parse_source_element` | `quickjs.c:31435` | `frontend/parser.zig: parseSourceElement` | F4-F8 |
| `js_parse_statement_or_decl` | `quickjs.c:28228` | `frontend/parser.zig: parseStatementOrDecl` | F5 |
| `js_parse_statement` | `quickjs.c:27822` | (thin wrapper) | F5 |
| `js_parse_block` | `quickjs.c:27827` | `parseBlock` | F5 |
| `js_parse_var` | `quickjs.c:27847` | `parseVar` | F5 |
| `js_parse_for_in_of` | `quickjs.c:27991` | `parseForInOf` | F5 |
| `js_parse_expr` | `quickjs.c:27645` | `parseExpr` | F4 |
| `js_parse_expr2` | `quickjs.c:27621` | `parseExpr2` | F4 |
| `js_parse_assign_expr` | `quickjs.c:27615` | `parseAssignExpr` | F4 |
| `js_parse_assign_expr2` | `quickjs.c:27311` | `parseAssignExpr2` | F4 |
| `js_parse_cond_expr` | `quickjs.c:27282` | `parseCondExpr` | F4 |
| `js_parse_coalesce_expr` | `quickjs.c:27254` | `parseCoalesceExpr` | F4 |
| `js_parse_logical_and_or` | `quickjs.c:27213` | `parseLogicalAndOr` | F4 |
| `js_parse_expr_binary` | `quickjs.c:27049` | `parseExprBinary` | F4 |
| `js_parse_unary` | `quickjs.c:26922` | `parseUnary` | F4 |
| `js_parse_delete` | `quickjs.c:26829` | `parseDelete` | F4 |
| `js_parse_postfix_expr` | `quickjs.c:26176` | `parsePostfixExpr` | F4 |
| `js_parse_left_hand_side_expr` | `quickjs.c:24487` | `parseLhsExpr` | F4 |
| `js_parse_array_literal` | `quickjs.c:25194` | `parseArrayLiteral` | F4 |
| `js_parse_object_literal` | `quickjs.c:24361` | `parseObjectLiteral` | F4 |
| `js_parse_property_name` | `quickjs.c:24012` | `parsePropertyName` | F4 |
| `js_parse_template` | `quickjs.c:23880` | `parseTemplate` | F4/F12 |
| `js_parse_template_part` | `quickjs.c:21794` | `parseTemplatePart` (lexer-side) | F1 |
| `js_parse_string` | `quickjs.c:21862` | `parseStringLiteral` (lexer-side) | F1 |
| `js_parse_regexp` | `quickjs.c:22005` | `parseRegexpLiteral` (lexer-side) | F1 |
| `js_parse_destructuring_element` | `quickjs.c:25716` | `parseDestructuringElement` | F6 |
| `js_parse_destructuring_var` | `quickjs.c:25692` | `parseDestructuringVar` | F6 |
| `js_parse_function_decl` | `quickjs.c:36388` | `parseFunctionDecl` | F6 |
| `js_parse_function_decl2` | `quickjs.c:35824` | `parseFunctionDecl2` | F6 |
| `js_parse_function_check_names` | `quickjs.c:35747` | `parseFunctionCheckNames` | F6 |
| `js_parse_directives` | `quickjs.c:35642` | `parseDirectives` | F5 |
| `js_parse_class` | `quickjs.c:24667` | `parseClass` | F7 |
| `js_parse_class_default_ctor` | `quickjs.c:24610` | `parseClassDefaultCtor` | F7 |
| `js_parse_function_class_fields_init` | `quickjs.c:35797` | `parseFunctionClassFieldsInit` | F7 |
| `js_parse_import` | `quickjs.c:31312` | `parseImport` | F8 |
| `js_parse_export` | `quickjs.c:31090` | `parseExport` | F8 |
| `js_parse_from_clause` | `quickjs.c:31039` | `parseFromClause` | F8 |
| `js_parse_with_clause` | `quickjs.c:30950` | `parseWithClause` | F8 |
| `find_var` | `quickjs.c:23378` | `FunctionDef.findVar` | F4 |
| `find_var_in_scope` | `quickjs.c:23402` | `FunctionDef.findVarInScope` | F4 |
| `find_var_in_child_scope` | `quickjs.c:23430` | `FunctionDef.findVarInChildScope` | F4 |
| `find_var_htab` | `quickjs.c:23346` | `FunctionDef.findVarHashed` | F4 |
| `add_var` | `quickjs.c:23554` | `FunctionDef.addVar` | F4 |
| `push_scope` | `quickjs.c:23486` | `ParseState.pushScope` | F4 |
| `pop_scope` | `quickjs.c:23532` | `ParseState.popScope` | F4 |
| `new_label_fd` | `quickjs.c:23199` | `FunctionDef.newLabel` | F3 |
| `emit_label` | `quickjs.c:23237` | `Emitter.emitLabel` | F3 |
| `get_closure_var` | `quickjs.c:32162` | `resolveVariables.getClosureVar` | F10 |
| `resolve_scope_var` | `quickjs.c:32377` | `resolveVariables.resolveScopeVar` | F10 |
| `resolve_variables` | `quickjs.c:33622` | `pipeline/resolve_variables.zig: run` | F10 |
| `resolve_labels` | `quickjs.c:34197` | `pipeline/resolve_labels.zig: run` | F10 |
| `compute_pc2line_info` | `quickjs.c:33995` | `pipeline/pc2line.zig: compute` | F10 |
| `compute_stack_size` | `quickjs.c:35167` | `pipeline/stack_size.zig: compute` | F10 |
| `push_short_int` | `quickjs.c:34120` | `Emitter.pushShortInt` | F3/F10 |
| `put_short_code` | `quickjs.c:34140` | `Emitter.putShortCode` | F3/F10 |
| `js_create_function` | `quickjs.c:35401` | `pipeline/finalize.zig: createFunction` | F10 |
| `JS_EvalThis2` | `quickjs.c:36679` | `engine.Engine.evalModeWithOutput` | F0 (already in place) |
| `JS_EvalObject` | `quickjs.c:36648` | (engine entrypoint) | F0 |

### 1.5.3 Data structures mirrored field-by-field

| QuickJS struct | Source location | Local mirror | Phase |
|---|---|---|---|
| `JSToken` | `quickjs.c:21539` | `frontend/token.zig: Token` | F1 |
| `JSParseState` | `quickjs.c:21564` | `frontend/parser.zig: ParseState` | F4 |
| `JSFunctionDef` | `quickjs.c:21420` | `bytecode/function_def.zig: FunctionDef` | F2+F3 |
| `JSVarDef` | `quickjs.c:724` | `bytecode/scope.zig: VarDef` | F2+F3 |
| `JSVarScope` | `quickjs.c:702` | `bytecode/scope.zig: VarScope` | F2+F3 |
| `JSClosureVar` | `quickjs.c:687` | `bytecode/scope.zig: ClosureVar` | F2+F3 |
| `BlockEnv` | `quickjs.c:21352` | `frontend/parser.zig: BlockEnv` | F5 |
| `LabelSlot` | `quickjs.c:21386` | `bytecode/labels.zig: LabelSlot` | F3 |
| `JumpSlot` | `quickjs.c:21380` | `bytecode/labels.zig: JumpSlot` | F3 |
| `RelocEntry` | `quickjs.c:21374` | `bytecode/labels.zig: RelocEntry` | F3 |
| `SourceLocSlot` | `quickjs.c:21395` | `bytecode/debug.zig: SourceLocSlot` | F10 |
| `JSGlobalVar` | `quickjs.c:21364` | `bytecode/function_def.zig: GlobalVar` | F4 |
| `JSFunctionBytecode` | `quickjs.c:768` | `bytecode/function.zig: FunctionBytecode` | F10 |
| `JSStackFrame` (CallInternal frame) | `quickjs.c:~17000` | `exec/frame.zig: Frame` | F3 |
| `JSClosureTypeEnum` (8 values) | `quickjs.c:675` | `bytecode/scope.zig: ClosureType` | F2+F3 |
| `JSVarKindEnum` (10 values) | `quickjs.c:707` | `bytecode/scope.zig: VarKind` | F4/F7 |
| `JSParseFunctionEnum` (10 values) | `quickjs.c:21401` | `frontend/parser.zig: ParseFunctionKind` | F6/F7 |
| `JSFunctionKindEnum` (4 values) | `quickjs.c:761` | `bytecode/function.zig: FunctionKind` | F6/F9 |

### 1.5.4 Locked invariants

- **Predefined atom ordering** (`src/engine/core/atom.zig`) must continue
  to match `quickjs-atom.h` row-for-row, because the parser depends on
  `TOK_FIRST_KEYWORD..TOK_LAST_KEYWORD` mapping to atom ids `1..47` and
  `s->token.u.ident.atom` being a valid atom for any keyword token.
- **Opcode ids** must come from the comptime ParsedTable; no hand-written
  `u8` literals in emitter, VM, or parser (verified by `no_legacy_known_test`).
- **`OP_FMT_*` formats** in `bytecode/opcode.zig: Format` must contain every
  format symbol from `quickjs-opcode.h` (currently 30 entries: `none /
  none_int / none_loc / none_arg / none_var_ref / u8 / i8 / loc8 / const8 /
  label8 / u16 / i16 / label16 / npop / npopx / npop_u16 / loc / arg /
  var_ref / u32 / u32x2 / i32 / const / label / atom / atom_u8 / atom_u16 /
  atom_label_u8 / atom_label_u16 / label_u16`).
- **`OP_SPECIAL_OBJECT_*`** values used by `OP_special_object` in
  `resolve_labels` (HOME_OBJECT, NEW_TARGET, ARGUMENTS, MAPPED_ARGUMENTS,
  THIS_FUNC) must align with `quickjs.c` (search `OP_SPECIAL_OBJECT_`).
- **`PC2LINE_BASE = -1`, `PC2LINE_RANGE = 5`, `PC2LINE_OP_FIRST = 1`,
  `PC2LINE_DIFF_PC_MAX = (255 - 1) / 5 = 50`** — the encoding constants
  for the line table must match `quickjs.c:756`.
- **`JS_STACK_SIZE_MAX`** in `compute_stack_size` mirror must equal
  QuickJS's value (search `JS_STACK_SIZE_MAX` in `quickjs.c`).

## 2. Phase Map

| Phase | Theme | Core deliverables | Test262 exit gate |
|---|---|---|---|
| F0 | Baseline lock + measurement + subset isolation | by-bucket / by-dir reports, runner stderr fragmentation fix, baseline snapshot | reproducible baseline; no behaviour change |
| F1 | Lexer completion | full keywords, punctuators, strings, templates with `${}`, numerics, regex, Unicode IDs, ASI line-terminator flag | lexer fuzz + QuickJS token diff |
| F2+F3 (atomic) | Real QuickJS opcode ABI **and** generic dispatcher landed together | `op` constants generated from `quickjs-opcode.h` (no hand-written ids); every `pub const known.*` deleted; emitter `emitOp*` helpers; VM dispatcher rewritten on QuickJS ids; every bespoke high-level opcode either dropped or expanded to a real op sequence; minimal generic ops (stack, locals/args/var-refs, control flow, fields/array els, calls/construct, arithmetic/compare/typeof, iterator protocol, temp opcodes) implemented | `opcode_alignment_test` green; `zig build test` / `smoke` / `run-test262` curated slices unchanged; **emitter.zig contains no hand-written `u8 =` opcode literals** |
| F4 | Generic expression parser | full Pratt parser for assignment / conditional / coalesce / logical / bitwise / equality / relational / shift / additive / multiplicative / exponent / unary / update / left-hand-side / member / call / optional chain / spread | `language/expressions` ≥ 60% |
| F5 | Generic statement parser | `if/while/do-while/for/for-in/for-of/switch/break/continue/return/throw/try-catch-finally/with/labeled/block/var/let/const`, directive prologue, ASI | `language/statements` ≥ 60% |
| F6 | Functions / arrows / defaults / destructuring / rest | named/anon function decls and exprs, arrow funcs, default params, array+object destructuring (binding & assignment), rest params, spread call | `language/expressions/arrow-function`, `language/expressions/function`, `language/statements/function`, `language/destructuring` ≥ 60% |
| F7 | Classes + private fields + super | class decl/expr, `extends`, `super(...)`, `super.x`, instance and static fields, `#x` private, static blocks | `language/expressions/class`, `language/statements/class` ≥ 50% |
| F8 | Modules + dynamic import | `import` / `export` / `export *` / `export from` / `import.meta` / `import()` | `language/module-code`, `language/import`, `language/export` ≥ 50% |
| F9 | Generators / async / async iter | `function*`, `yield`, `yield*`, `async function`, `await`, `for await`, async generators | `language/statements/async-function`, `language/statements/async-generator` ≥ 40% |
| F10 | Phase 2 / Phase 3 compilation pipeline | `JSFunctionDef`-equivalent, `resolve_variables`, `resolve_labels`, short opcodes, pc2line | bytecode size ↓ ≥ 30%; QuickJS bytecode parity on sampled functions |
| F11 | Fixture recognisers fully deleted | `parser.zig` < 2 000 lines; emitter and VM purged of high-level opcodes | total test262 ≥ 25 000 / 48 205 (~52%) passing |
| F12 | RegExp / template literals / tagged templates | full template parts, RegExp compiled by `libs/regexp/`, tagged templates with `raw` | `built-ins/RegExp` ≥ 50%; `language/expressions/template-literal` ≥ 80% |

`F0` through `F11` is the parser-rewrite trunk. `F12` follows once the trunk
is in place and the remaining failures are dominated by builtin/runtime gaps
already tracked under `WQ-012` / `WQ-013` / `WQ-014`.

## 2.5. Pre-flight: opcode alignment audit (2026-04-27)

Before any phase that depends on the QuickJS opcode set, we audited every
`pub const known.*` in `src/engine/bytecode/emitter.zig` against
`quickjs/quickjs-opcode.h`. The audit script lives at
`tools/compare/opcode_align_check.py` (to be added in F0); the canonical
QuickJS index map was generated by reading the header in DEF/def order
starting at `invalid = 0`.

### 2.5.1 Headline numbers

| Class | Count | Share |
|---|---|---|
| Total `known.*` constants | 95 | 100% |
| index matches QuickJS | 7 | 7.4% |
| same name, different index | 27 | 28.4% |
| bespoke (no QuickJS counterpart, currently squats on a real QuickJS id) | 61 | 64.2% |

### 2.5.2 Aligned by accident (7)

These survive the ABI swap unchanged (they are the lowest-numbered push
constants and `source_loc`):

```
  1  push_i32        ==  push_i32
  2  push_const      ==  push_const
  6  undefined_value ==  undefined
  7  null_value      ==  null
  9  push_false      ==  push_false
 10  push_true       ==  push_true
196  source_loc      ==  source_loc
```

### 2.5.3 Same name, wrong index (27)

Every one of these names exists in QuickJS but at a different id. The id
zjs currently uses is occupied by an unrelated real QuickJS opcode, so
keeping the current value would silently mis-dispatch:

| zjs.name | zjs.idx | QuickJS idx for that name | zjs idx is QuickJS… |
|---|---|---|---|
| `drop` | 11 | 14 | `object` |
| `return_undef` | 45 | 41 | `check_brand` |
| `import` | 59 | 54 | `get_ref_value` |
| `get_var` | 61 | 56 | `define_var` |
| `define_var` | 66 | 61 | `put_field` |
| `define_class` | 91 | 85 | `put_arg` |
| `goto` | 117 | 106 | `with_make_ref` |
| `bit_not` | 151 | 148 (`not`) | `delete` |
| `call` | 170 | 34 | `in` |
| `for_in_next` | 176 | 127 | `private_in` |
| `strict_neq` | 206 | 174 | `push_i8` |
| `typeof_value` | 216 | 150 (`typeof`) | `get_loc1` |
| `gte` | 218 | 168 | `get_loc3` |
| `eq` | 232 | 171 | `put_arg1` |
| `strict_eq` | 233 | 173 | `put_arg2` |
| `mul` | 240 | 153 | `get_var_ref1` |
| `div` | 241 | 154 | `get_var_ref2` |
| `mod` | 242 | 155 | `get_var_ref3` |
| `add` | 243 | 156 | `put_var_ref0` |
| `sub` | 244 | 157 | `put_var_ref1` |
| `shl` | 245 | 158 | `put_var_ref2` |
| `sar` | 246 | 159 | `put_var_ref3` |
| `shr` | 247 | 160 | `set_var_ref0` |
| `bit_and` | 248 | 161 (`and`) | `set_var_ref1` |
| `bit_xor` | 249 | 162 (`xor`) | `set_var_ref2` |
| `bit_or` | 250 | 163 (`or`) | `set_var_ref3` |
| `pow` | 251 | 164 | `get_length` |

Every arithmetic, comparison, control-flow, and variable-access opcode is
off by 80–100 from where QuickJS expects it.

### 2.5.4 Bespoke high-level opcodes (61)

These names do not exist in QuickJS; they were invented to pack whole
runtime operations into one op so the fixture parser had something cheap
to emit. Each one squats on a real QuickJS id used for an unrelated
opcode (the id in parentheses is the QuickJS owner of that id):

- **call/construct shortcuts**: `call_prop` (152 = `delete_var`),
  `array_method` (169 = `instanceof`),
  `construct` (195 = beyond DEFs, used by `set_class_name` temp),
  `new_function` (193 = `get_field_opt_chain`),
  `new_closure` (166 = `lte`),
  `call_closure` (167 = `gt`),
  `new_promise` (194 = `get_array_el_opt_chain`),
  `promise_static` (189 = `scope_get_private_field`),
  `new_regexp` (190 = `scope_get_private_field2`),
  `regexp_method` (191 = `scope_put_private_field`),
  `new_string_object` (153 = `mul`),
  `new_collection` (184 = `scope_put_var`),
  `new_typed_array` (179 = `enter_scope`),
  `new_dataview` (180 = `leave_scope`),
  `new_array_buffer` (177 = `push_bigint_i32`),
  `arraybuffer_slice` (181 = `label`),
  `new_date` (160 = `shr`),
  `date_call` (161 = `and`),
  `date_static` (162 = `xor`),
  `date_method` (163 = `or`).
- **property/data shortcuts**: `get_prop` (222 = `put_loc3`),
  `set_prop` (171 = `eq`),
  `optional_get_prop` (207 = `push_i16`),
  `get_index` (236 = `set_arg1`),
  `new_array` (235 = `set_arg0`),
  `new_object` (239 = `get_var_ref0`),
  `object_keys` (172 = `neq`),
  `object_values` (173 = `strict_eq`),
  `object_entries` (174 = `strict_neq`),
  `array_join` (175 = `is_undefined_or_null`),
  `dataview_get` (182 = `scope_get_var_undef`),
  `dataview_set` (183 = `scope_get_var`),
  `json_stringify` (223 = `set_loc0`),
  `json_parse` (230 = `get_arg3`),
  `object_is` (217 = `get_loc2`),
  `string_char_at` (219 = `put_loc0`),
  `string_from_char_code` (213 = `set_loc8`),
  `value_length` (234 = `put_arg3`),
  `prop_in` (211 = `get_loc8`),
  `instanceof_array` (192 = `scope_in_private_field`),
  `instanceof_object` (212 = `put_loc8`),
  `instanceof_value` (237 = `set_arg2`),
  `factorial` (238 = `set_arg3`),
  `string_method` (214 = `get_loc0_loc1`),
  `math_call` (215 = `get_loc0`),
  `uri_call` (186 = `scope_make_ref`),
  `parse_int` (187 = `scope_get_ref`),
  `parse_float` (188 = `scope_put_var_init`).
- **coercion/logic shortcuts**: `value_to_number` (208 = `push_const8`),
  `value_to_boolean` (209 = `fclosure8`),
  `value_to_string` (210 = `push_empty_string`),
  `logical_and` (220 = `put_loc1`),
  `logical_or` (221 = `put_loc2`),
  `nullish_coalesce` (231 = `put_arg0`),
  `bigint_as_int_n` (155 = `mod`),
  `bigint_as_uint_n` (154 = `div`).
- **direct-throw shortcuts**: `throw_type_error` (168 = `gte`),
  `throw_syntax_error` (156 = `add`),
  `throw_range_error` (157 = `sub`),
  `throw_reference_error` (159 = `sar`),
  `throw_eval_error` (165 = `lt`).

### 2.5.5 Implications for F2 / F3

1. **F2 cannot run a "dual-key" transitional dispatcher.** With 95% of the
   ids overlapping different real opcodes, any `switch` that accepts both
   sets at once is unsound. F2 is therefore an **atomic swap**, not an
   incremental migration. The original "F2 / F3 separation" in the first
   draft is dropped; the phase map now lists `F2+F3 (atomic)` as a single
   merged milestone.
2. **F2 must land paired with F3's minimal generic ops.** As soon as the
   ABI is real, the legacy ranges `case 240..251 => binaryOp(op)` etc.
   stop matching arithmetic; the same PR has to introduce real
   `op.mul/op.div/...` arms or the VM regresses on every fixture. The
   merged phase ships:
   - real arithmetic / comparison / typeof / instanceof / in / strict-eq
     dispatch on QuickJS ids,
   - real `call argc`, `call_method argc`, `call_constructor argc` (with
     short forms `call0..3`),
   - real `get_field / get_field2 / put_field / get_array_el /
     get_array_el2 / put_array_el`,
   - real `get_loc / put_loc / get_arg / put_arg / get_var_ref /
     put_var_ref` plus their `_check` and `_init` variants,
   - real `if_false / if_true / goto / catch / gosub / ret / nip_catch /
     throw / throw_error`,
   - real iterator protocol (`for_in_start / for_of_start / for_in_next /
     for_of_next / iterator_check_object / iterator_get_value_done /
     iterator_close / iterator_next / iterator_call`),
   - the temporary opcodes (`enter_scope / leave_scope / scope_get_var /
     scope_put_var / scope_make_ref / scope_get_ref / scope_put_var_init /
     scope_get_var_undef / scope_delete_var / scope_get_private_field /
     scope_get_private_field2 / scope_put_private_field /
     scope_in_private_field / get_field_opt_chain /
     get_array_el_opt_chain / set_class_name / source_loc / label`)
     emitted by the parser; F10 lowers them away, but they must already
     occupy their canonical ids and be no-ops in the immediate-resolve
     path.
3. **Every bespoke opcode must have a published expansion plan before
   F2 lands.** No bespoke id can survive into F2's dispatcher. Each
   bespoke op falls into exactly one of these three buckets, recorded in
   `docs/quickjs-redesign/matrices/opcode-execution-matrix.md`:
   - **Expand to real op sequence inside the emitter.** Examples:
     - `set_prop name` → `put_field name`
     - `get_prop name` → `get_field name`
     - `optional_get_prop name` → `get_field_opt_chain name` (Phase 1
       temp; F10 lowers)
     - `get_index` → `get_array_el`
     - `call_prop name argc` → `dup ; get_field name ; swap ;
       call_method argc`
     - `new_array n` → `array_from n` (or `object` + `define_array_el`
       loop)
     - `new_object n + atom_list` → `object` + `define_field name` per
       slot
     - `logical_and / logical_or / nullish_coalesce` → conditional
       branch using `if_false` / `if_true` and `dup`
     - `value_length` → `get_field length`
     - `value_to_number / value_to_boolean / value_to_string` → standard
       coercion ops `to_object` / direct calls into builtin coercion
       helpers
   - **Reroute through a real built-in call.** Examples:
     - `math_call(id)` → `get_var Math ; get_field <method> ; call argc`
     - `string_method(id, argc)` → `get_field <method> ; call_method
       argc`
     - `string_from_char_code(argc)` → `get_var String ; get_field
       fromCharCode ; call argc`
     - `array_method / array_join / object_keys / object_values /
       object_entries / json_stringify / json_parse / parse_int /
       parse_float / uri_call / new_date / date_call / date_static /
       date_method / new_collection / new_typed_array / new_dataview /
       new_array_buffer / arraybuffer_slice / dataview_get /
       dataview_set / new_string_object / new_promise / promise_static /
       new_regexp / regexp_method / new_function / new_closure /
       call_closure / object_is / string_char_at / instanceof_array /
       instanceof_object / instanceof_value / bigint_as_int_n /
       bigint_as_uint_n / factorial` → all become ordinary built-in
       method calls. Their behaviour already exists in
       `src/engine/builtins/` (WQ-007 / WQ-008 / WQ-012 inheritance);
       F2 only changes how the parser reaches them.
   - **Drop entirely.** Examples:
     - `throw_type_error / throw_syntax_error / throw_range_error /
       throw_reference_error / throw_eval_error` → emit `throw_error
       <atom>, <ctor_index>` (real opcode, format `atom_u8`) which is
       the QuickJS shape; the string-templated variants disappear.
     - `construct argc` → `call_constructor argc`.
     - `bit_not` → `not`. `typeof_value` → `typeof`.
     - `bit_and / bit_or / bit_xor` → `and / or / xor`.
4. **F2 ships with a strict consistency test.** `tests/zig-bytecode/
   opcode_alignment_test.zig` iterates the comptime `ParsedTable` and
   asserts `op.<entry.name> == entry.index` for every entry, plus an
   `expectEqual` per entry at run time, plus a guard that the QuickJS
   header file's hash has not drifted from the locked
   `QUICKJS_BASELINE_SHA` recorded in `TRACKING.md`.

### 2.5.6 Effort and ordering note

Because F2 and F3 are now a single transactional change touching emitter,
VM dispatcher, and every parser call site that emits a bespoke opcode, the
combined phase is the single largest milestone in the trunk. It must be
landed in one merge (or with a feature flag that keeps both code paths
compiled but only one wired up) — not as a series of half-states.

## 3. Phase Detail

### F0 — Baseline lock and measurement

**Status:** completed 2026-04-27. Reporter, `-R <dir>` runner flag, and
opcode-alignment audit landed; baseline snapshot stored under
`docs/quickjs-redesign/baseline/2026-04-27/`. See parser-rewrite F0 row in
`TRACKING.md` for the recorded numbers and gates.


#### F0.1 Measurement plumbing

- Persist failure reasons in the runner. Add a single-writer log file (e.g.
  `reports/test262-failures.log`) protected by a mutex, written from
  `runOneTest` whenever the result is `.failed`. Format:
  `<test_path>\t<error_name>\n`.
- Aggregate by error bucket: `SyntaxError`, `TypeError`, `Test262Error`,
  `RangeError`, `ReferenceError`, `unhandled promise rejection`. Emit
  `reports/test262-buckets.json`.
- Aggregate by `built-ins/<X>` and `language/<X>` directory. Emit
  `reports/test262-by-dir.json`.

#### F0.2 Baseline snapshot

- Run the full corpus once, commit
  `docs/quickjs-redesign/baseline/2026-04-27/test262-by-dir.json` and
  `test262-buckets.json`. F1+ compares against this snapshot.
- Add a `parser-rewrite` row to `TRACKING.md` with a sub-row per phase ID.

#### F0.3 Stderr fragmentation fix

- The runner's `printFailure` allocates a new `[4096]u8` stack buffer per
  call; in `-t > 1` runs writes interleave and produce fragments such as
  `Error`, `ror`, `r`. Replace with a process-global mutex around
  `std.Io.File.stderr()` writes, or buffer per-worker and drain via the
  main thread.

#### F0.4 Opcode-alignment audit tool

- Add `tools/compare/opcode_align_check.py` that reads
  `quickjs/quickjs-opcode.h` and `src/engine/bytecode/emitter.zig` and
  prints (and emits JSON to `reports/opcode-alignment.json`) the three
  classes from §2.5: aligned, mis-indexed, bespoke.
- The tool must run in CI; any change to either input that increases the
  "bespoke" or "mis-indexed" counts fails the build.

**Exit:** runner can produce by-bucket and by-dir reports deterministically
across single- and multi-thread modes; baseline snapshot is committed;
`reports/opcode-alignment.json` published and reproduces the §2.5 numbers.

### F1 — Lexer completion

**QuickJS reference:** `next_token` (`quickjs.c:~22500`),
`js_parse_template_part` (`quickjs.c:21794`), `js_parse_string`
(`quickjs.c:21862`), `js_parse_regexp` (`quickjs.c:22005`),
`free_token` (`quickjs.c:21634`), token enum (`quickjs.c:21246`).

#### F1.1 Token enum aligned with `TOK_*`

Replace `frontend/token.zig` with a Zig enum whose **integer values match
QuickJS `TOK_*`** (negative for non-keyword variable-length kinds, then
keywords starting at `TOK_NULL`):

- `TOK_NUMBER = -128, TOK_STRING, TOK_TEMPLATE, TOK_IDENT, TOK_REGEXP`
- Assignment ops `TOK_MUL_ASSIGN..TOK_DOUBLE_QUESTION_MARK_ASSIGN`
  (their order matters: `js_parse_assign_expr2` does
  `OP_mul + (op - TOK_MUL_ASSIGN)` to derive the assignment opcode).
- Comparison ops `TOK_DEC, TOK_INC, TOK_SHL, TOK_SAR, TOK_SHR,
  TOK_LT, TOK_LTE, TOK_GT, TOK_GTE, TOK_EQ, TOK_STRICT_EQ, TOK_NEQ,
  TOK_STRICT_NEQ` (used by `js_parse_expr_binary`'s switch over `level`).
- Logical / misc: `TOK_LAND, TOK_LOR, TOK_POW, TOK_ARROW, TOK_ELLIPSIS,
  TOK_DOUBLE_QUESTION_MARK, TOK_QUESTION_MARK_DOT, TOK_ERROR,
  TOK_PRIVATE_NAME, TOK_EOF`.
- Keyword block in QuickJS-atom order: `TOK_NULL, TOK_FALSE, TOK_TRUE,
  TOK_IF, TOK_ELSE, TOK_RETURN, TOK_VAR, TOK_THIS, TOK_DELETE, TOK_VOID,
  TOK_TYPEOF, TOK_NEW, TOK_IN, TOK_INSTANCEOF, TOK_DO, TOK_WHILE, TOK_FOR,
  TOK_BREAK, TOK_CONTINUE, TOK_SWITCH, TOK_CASE, TOK_DEFAULT, TOK_THROW,
  TOK_TRY, TOK_CATCH, TOK_FINALLY, TOK_FUNCTION, TOK_DEBUGGER, TOK_WITH,
  TOK_CLASS, TOK_CONST, TOK_ENUM, TOK_EXPORT, TOK_EXTENDS, TOK_IMPORT,
  TOK_SUPER, TOK_IMPLEMENTS, TOK_INTERFACE, TOK_LET, TOK_PACKAGE,
  TOK_PRIVATE, TOK_PROTECTED, TOK_PUBLIC, TOK_STATIC, TOK_YIELD,
  TOK_AWAIT, TOK_OF`.
- `TOK_FIRST_KEYWORD = TOK_NULL`, `TOK_LAST_KEYWORD = TOK_AWAIT`.
- All single-character punctuators stay as their ASCII value (so `'+'` is
  `0x2B`, `';'` is `0x3B`, etc.) — QuickJS uses the raw byte for those.

`Token` struct mirrors `JSToken` (`quickjs.c:21539`):

```
pub const Token = struct {
    val: i16,
    line_num: u32,
    col_num: u32,
    ptr: [*]const u8,   // start of token in source
    u: union { num, str, regexp, ident, template },
};
```

with `u.ident.atom: Atom` populated for `TOK_IDENT`, `TOK_PRIVATE_NAME`,
and every keyword (`TOK_NULL..TOK_AWAIT`). Because the keyword block's
order matches `quickjs-atom.h:29..76`, `u.ident.atom = (val - TOK_NULL) +
ATOM_null` for keywords, exactly as QuickJS does.

#### F1.2 Strings, templates, numerics, regex

- **String literal parser** (`js_parse_string`, `quickjs.c:21862`): mirror
  the escape table including `\xHH`, `\uHHHH`, `\u{...}`, `\<line
  continuation>`, `\0` (only when not followed by `0..9`), `\<digit>`
  legacy octal (rejected when `s->cur_func->is_strict_mode`). Allow raw
  U+2028/U+2029 inside strings (per spec). Returns either a UTF-8 byte
  slice or a UTF-16 buffer depending on whether non-Latin1 code points
  appear.
- **Templates** (`js_parse_template_part`, `quickjs.c:21794`): on `${`,
  return `TOK_TEMPLATE` with the boundary kind in `token.u.template`
  (`head`, `middle`, `tail`, `no_substitution`). Resumption after `}` is
  driven by the parser calling `js_parse_template_part` again. The
  current zjs lexer that scans straight to the closing backtick is
  removed.
- **Numerics**: `0x[0-9a-fA-F_]+`, `0o[0-7_]+`, `0b[01_]+`, decimal with
  optional `_` separator, `.5`, `1.`, `1e+10`, `BigInt` `n` suffix.
  Numeric-separator rules: no leading/trailing/consecutive `_`. Reject
  legacy octal like `010` outside non-strict via the same `is_strict_mode`
  check QuickJS uses.
- **RegExp literal** (`js_parse_regexp`, `quickjs.c:22005`): a real state
  machine with `in_class` flag, escape handling, and flag scanning.
  Returns `token.u.regexp = { pattern: JSValue, flags: JSValue }` matching
  `JSToken`. Replaces `regexp_literal.scan`.
- **HTML close `-->`**: only after a real LineTerminator (or BOM/start of
  file) and forbidden in module mode (`s->is_module`). QuickJS gates this
  via `s->allow_html_comments`.

#### F1.3 Private names + Unicode identifiers

- `TOK_PRIVATE_NAME` covers `#name` and is emitted with
  `token.u.ident.atom` interned (the leading `#` stays in the atom — that
  is how QuickJS distinguishes private names).
- ID_Start / ID_Continue validation backed by `src/engine/libs/unicode/`
  tables (UCD `ID_Start`, `ID_Continue`, `Other_ID_Start`,
  `Other_ID_Continue`). Match QuickJS `is_ident_first` /
  `is_ident_next` (around `quickjs.c:21300`).
- `\uHHHH` / `\u{...}` escapes inside identifiers are decoded and the
  resulting code point is ID_Start / ID_Continue-validated.

#### F1.4 ASI metadata

- Mirror `JSParseState.got_lf` (`quickjs.c:21572`): the lexer sets a flag
  whenever `next_token` skips at least one LineTerminator before emitting
  the next token. The parser reads this flag for `return`, `throw`,
  `break`, `continue`, postfix `++`/`--`, and arrow-function ASI.
- Source position: `Token.line_num` and `Token.col_num` are 1-based,
  matching QuickJS.

#### F1.5 Predefined-atom alignment guard

Add `tests/zig-frontend/keyword_atom_alignment_test.zig` that asserts at
runtime, for every keyword `TOK_NULL..TOK_AWAIT`, that
`tokenAtom(tok) == ATOM_null + (tok - TOK_NULL)`. This is the invariant
QuickJS relies on at `quickjs.c:21652` (`token->val >= TOK_FIRST_KEYWORD &&
token->val <= TOK_LAST_KEYWORD`).

**Exit:**
- `tests/zig-frontend/lexer_*` cover every escape, every numeric form,
  template head/middle/tail, regex, ASI flag, private name, Unicode ID.
- `tools/compare/dump-quickjs-tokens` vs. our lexer diff = empty on a
  fixed 50-file sample (file list committed at
  `tests/test262-anchors/F1/lex-sample.txt`).
- `keyword_atom_alignment_test` green.
- Existing `zig build test`, `zig build smoke`, curated test262 slices
  unchanged.

### F2+F3 (atomic) — Real QuickJS opcode ABI and generic dispatcher

> §2.5 demonstrated that 88 of the 95 current opcodes either mis-index or
> are bespoke. A "dual-key transitional dispatcher" is therefore unsound:
> any single `switch` would have to accept both indexings, but most ids
> belong to two different opcodes simultaneously. F2 is consequently an
> **atomic swap** that lands together with the minimal generic dispatcher
> from F3 in a single transactional change.

#### F2.1 Compile-time opcode constants (no hand-written ids)

- `bytecode/opcode.zig` already parses `quickjs/quickjs-opcode.h` into a
  `ParsedTable`. Add `pub fn opEnum(comptime table: ParsedTable) type` that
  returns a struct with one `pub const <entry.name>: u8 = entry.index;`
  field per `DEF`/`def` entry, generated entirely at comptime from
  `@embedFile("../../../quickjs/quickjs-opcode.h")`.
- Export the result as `pub const op = opEnum(parsed_table);` from
  `bytecode/opcode.zig`.
- **Delete `pub const known = struct { ... }`** in
  `src/engine/bytecode/emitter.zig`. Every `emitter.known.foo` reference in
  the codebase becomes `op.foo`. After this PR, `grep -nE
  'pub const \w+:\s*u8\s*=\s*[0-9]+' src/engine/bytecode/emitter.zig`
  must return zero hits.

#### F2.2 Emitter primitives

- Replace per-opcode emit helpers with format-aware primitives:
  - `emitOp(comptime O: Op)`
  - `emitOpU8 / emitOpU16 / emitOpU32`
  - `emitOpAtom / emitOpAtomU8 / emitOpAtomU16 / emitOpAtomLabelU8 / emitOpAtomLabelU16`
  - `emitOpLabel / emitOpLabel8 / emitOpLabel16`
  - `emitOpConst / emitOpLoc / emitOpArg / emitOpVarRef`
- Bespoke helpers (`emitArrayMethod`, `emitStringMethod`, `emitMathCall`,
  `emitRegExpMethod`, `emitDateCall`, `emitDateStatic`, `emitDateMethod`,
  `emitNewCollection`, `emitUriCall`, `emitNewTypedArray`,
  `emitNewDataView`, `emitDataViewGet`, `emitDataViewSet`,
  `emitArrayBufferSlice`, `emitStringFromCharCode`, `emitNewStringObject`,
  `emitNewClosure`, `emitCallClosure`, `emitNewPromise`,
  `emitPromiseStatic`, `emitNewRegExp`, `emitObjectKeys/Values/Entries`,
  `emitArrayJoin`, `emitNewFunction`, `emitBigIntAsN`, `emitParseInt`,
  `emitParseFloat`, `emitNewDate`) are removed **in this phase**, not in
  F11. Each call site moves to the expansion specified in §2.5.5.

#### F2.3 Bespoke-opcode expansion

For every entry in §2.5.4, the F2+F3 PR ships the chosen expansion (real
op sequence, built-in call, or drop) defined in §2.5.5. Each expansion is
recorded in `docs/quickjs-redesign/matrices/opcode-execution-matrix.md`
with: bespoke name → strategy → emitted op sequence → example.

#### F2.4 Atomic VM dispatcher rewrite

- The dispatch `switch` in `src/engine/exec/vm.zig` is rewritten in one
  pass: every arm becomes `case op.<canonical_name> => ...`. Numeric
  literal cases (`240..251`, `253..255`, `224..229`, `197..205`, `178`)
  disappear because they relied on legacy ids.
- Implementations land for the minimal generic-op set listed in §2.5.5
  point 2 (stack, locals/args/var-refs, control flow, fields, array els,
  calls/construct, arithmetic/compare/typeof, iterator protocol, temp
  opcodes). See §F3.* below for per-family detail.

#### F2.5 Consistency tests

- `tests/zig-bytecode/opcode_alignment_test.zig`:
  - At comptime: `inline for (parsed_table.all()) |entry| { _ = @field(op, entry.name); }`
    forces every entry name to exist in `op`.
  - At runtime: for every entry, `try expectEqual(@as(u8, entry.index),
    @field(op, entry.name));`.
  - Hash guard: `expectEqualSlices(u8, expected_baseline_sha,
    sha1(@embedFile("../../../quickjs/quickjs-opcode.h")));` where the
    baseline SHA matches `QUICKJS_BASELINE_SHA` in `TRACKING.md`.
- `tests/zig-bytecode/no_legacy_known_test.zig`: a comptime `@compileError`
  guard that fails the build if `pub const known` ever reappears in
  `emitter.zig`.

**Exit:**
- `zig build test`, `zig build smoke`, `zig build run-test262` (curated
  slices: `built-ins/Map`, `Set`, `WeakMap`, `WeakSet`, `Object/is`,
  `built-ins/global`) all green and unchanged.
- `opcode_alignment_test` and `no_legacy_known_test` green.
- `tools/compare/opcode_align_check.py` reports 0 mis-indexed and 0
  bespoke entries.
- `grep -nE 'pub const \w+:\s*u8\s*=\s*[0-9]+' src/engine/bytecode/emitter.zig`
  returns no matches.
- VM dispatcher contains no numeric-range arms (`case 240..251` etc.).

### F3 detail — Generic VM dispatcher (lands inside F2+F3 atomic phase)

Implement the QuickJS opcode families below. Each opcode gets a unit test
in `src/tests/exec/<family>_test.zig`. These sub-sections are ordered by
implementation difficulty within the single F2+F3 PR (or PR series under
a feature flag); they are not separate phases.

#### F3.1 Stack ops

`drop / nip / nip1 / dup / dup1 / dup2 / dup3 / insert2 / insert3 / insert4 /
perm3 / perm4 / perm5 / swap / swap2 / rot3l / rot3r / rot4l / rot5l`

These are the foundation for any compound assignment, `obj.x = v` chained
with usage, or generic call lowering. The stack helper module
`src/engine/exec/stack.zig` gains the matching primitives.

#### F3.2 Locals / arguments / var-refs

`get_loc / put_loc / set_loc / get_arg / put_arg / set_arg / get_var_ref /
put_var_ref / set_var_ref / get_loc_check / put_loc_check /
put_loc_check_init / get_var_ref_check / put_var_ref_check /
put_var_ref_check_init / set_loc_uninitialized / close_loc`

Frames gain `locals: []Value`, `args: []Value`, `var_refs: []*Value`.
Indices are `u16`. TDZ uses an `uninitialized` sentinel and the `*_check`
opcodes raise `ReferenceError` on read.

#### F3.3 Globals

`get_var / get_var_undef / put_var / put_var_init / delete_var / make_var_ref`

`get_var name` raises `ReferenceError` when missing; `get_var_undef` pushes
`undefined` (used for `typeof x`).

#### F3.4 Control flow

`label (temp) / if_false / if_true / goto / catch / gosub / ret / nip_catch /
throw / throw_error`

- Labels managed as in QuickJS `LabelSlot`. `add_label` returns an id;
  `emit_label(id)` stamps a placeholder; phase 3 patches absolute PCs.
- `try { } catch (e) { } finally { }` follows QuickJS exactly:

  ```
  catch L_catch
  ... try body ...
  goto L_after_try
  L_catch:
  // exception is on the stack, bind to e
  ... catch body ...
  L_after_try:
  gosub L_finally
  goto L_end
  L_finally:
  ... finally body ...
  ret
  L_end:
  ```

#### F3.5 Fields and array elements

`get_field / get_field2 / put_field / get_array_el / get_array_el2 /
put_array_el / get_super_value / put_super_value / define_field /
define_array_el / append`

Replace `get_prop` / `set_prop` / `get_index` / the high-level `call_prop`.
Stack contracts must match QuickJS:

- `get_field name`: `obj -> value`
- `get_field2 name`: `obj -> obj value` (used by compound assignment)
- `put_field name`: `obj value ->`
- `get_array_el`: `obj key -> value`
- `get_array_el2`: `obj key -> obj value`
- `put_array_el`: `obj key value ->`

#### F3.6 Calls / construction / return

`call / call_method / call_constructor / tail_call / tail_call_method /
array_from / apply / return / return_undef / return_async / check_ctor /
check_ctor_return / init_ctor`

- `call argc`: stack `func arg0 ... argN-1` → `result`.
- `call_method argc`: stack `obj func arg0 ... argN-1` → `result`. This is
  the standard `obj.method(...)` lowering.
- The high-level `call_prop atom argc` opcode is removed: the parser emits
  `dup; get_field name; swap; (now obj func) call_method`.
- Short forms `call0 / call1 / call2 / call3` map to `call argc=0..3`.

#### F3.7 Arithmetic / comparison / typeof

`neg / plus / dec / inc / post_dec / post_inc / dec_loc / inc_loc / add_loc /
not / lnot / typeof / delete / typeof_is_undefined / typeof_is_function /
mul / div / mod / add / sub / shl / sar / shr / and / xor / or / pow / lt /
lte / gt / gte / instanceof / in / eq / neq / strict_eq / strict_neq /
is_undefined_or_null / is_undefined / is_null`

Some of these already exist in the VM but at the wrong indices and with
wrong contracts. Re-key against the QuickJS table. The custom opcodes
`instanceof_array`, `instanceof_value`, `prop_in`, `factorial`,
`object_is`, `value_length` are removed; their behaviour is recovered via
generic `instanceof` / `in` plus standard built-ins.

#### F3.8 Iterators

`for_in_start / for_of_start / for_await_of_start / for_in_next /
for_of_next / iterator_check_object / iterator_get_value_done /
iterator_close / iterator_next / iterator_call`

The custom `for_in_next atom patch_offset` shortcut is removed. Loops use
the standard QuickJS protocol.

#### F3.9 Temporary opcodes (Phase 1 emit, Phase 2 erase)

`enter_scope / leave_scope / scope_get_var / scope_put_var /
scope_make_ref / scope_get_ref / scope_put_var_init / scope_get_var_undef /
scope_delete_var / scope_get_private_field / scope_get_private_field2 /
scope_put_private_field / scope_in_private_field / get_field_opt_chain /
get_array_el_opt_chain / set_class_name / source_loc / label`

The emitter must produce these. The VM does not execute them — F10 lowers
them away. F3 ships with a temporary "immediate resolve" path so the new
parser can run ahead of phase 2 landing.

**Exit:** every new opcode has a unit test; existing fixtures and curated
slices unchanged; `built-ins/Map`, `Set`, `WeakMap`, `WeakSet`,
`built-ins/global`, `Object/is` pass rates do not regress.

### F4 — Generic expression parser

**QuickJS reference:** `js_parse_expr` (`quickjs.c:27645`),
`js_parse_expr2` (`quickjs.c:27621`), `js_parse_assign_expr`
(`quickjs.c:27615`), `js_parse_assign_expr2` (`quickjs.c:27311`),
`js_parse_cond_expr` (`quickjs.c:27282`), `js_parse_coalesce_expr`
(`quickjs.c:27254`), `js_parse_logical_and_or` (`quickjs.c:27213`),
`js_parse_expr_binary` (`quickjs.c:27049`), `js_parse_unary`
(`quickjs.c:26922`), `js_parse_delete` (`quickjs.c:26829`),
`js_parse_postfix_expr` (`quickjs.c:26176`), `js_parse_left_hand_side_expr`
(`quickjs.c:24487`), `js_parse_array_literal` (`quickjs.c:25194`),
`js_parse_object_literal` (`quickjs.c:24361`), `js_parse_property_name`
(`quickjs.c:24012`), `js_parse_template` (`quickjs.c:23880`),
`js_parse_expr_paren` (`quickjs.c:25584`).

The local file layout is `frontend/parse_expr.zig` (a single file matching
the QuickJS section between lines 23835–27645). One-to-one function
mapping is mandatory; deviations require an entry in
`docs/quickjs-redesign/matrices/parser-deviation-matrix.md`.

#### F4.1 Recursion structure mirrors QuickJS

QuickJS does **not** use a single Pratt loop; it has a hand-rolled tower
of mutually-recursive functions, each at one precedence level. We mirror
that exactly:

```
parseExpr            -> parseExpr2(PF_IN_ACCEPTED)
parseExpr2(flags)    -> parseAssignExpr2(flags); while ',' { drop ; parseAssignExpr2 }
parseAssignExpr2     -> parseCondExpr(flags); if assignment-op { LHS-check ; rhs ; emit assign-op }
parseCondExpr        -> parseCoalesceExpr; if '?' { ... }
parseCoalesceExpr    -> parseLogicalAndOr(OP_or); if '??' { reject mixing && / || ; ... }
parseLogicalAndOr(op)-> parseExprBinary(level=8) ; while op_match { branch + parseExprBinary }
parseExprBinary(L,f) -> if L==0 parseUnary(PF_POW_ALLOWED) ; switch(L) -> token table
parseUnary(flags)    -> handle delete/void/typeof/+/-/~/!/++/--/await ; ** if PF_POW_ALLOWED
parsePostfixExpr     -> parseLhsExpr ; postfix ++/-- (no LineTerminator-before)
parseLhsExpr         -> primary or new ... ; member chain (.,[],?.,call,template tag)
```

`PF_*` flag bits (mirror `quickjs.c` PF\_ macros): `PF_IN_ACCEPTED`,
`PF_POW_ALLOWED`, `PF_ARROW_FUNC`, `PF_TRAILING_COMMA_OK`, etc. Pass
exactly the same flags down the recursion that QuickJS does.

#### F4.2 Binary-op level table

`parseExprBinary` has a switch over `level` from 1 to 9 mirrored from
`quickjs.c:27049-27210`:

| Level | Tokens accepted | Emitted opcode(s) |
|---|---|---|
| 1 | `'*' '/' '%'` | `OP_mul / OP_div / OP_mod` |
| 2 | `'+' '-'` | `OP_add / OP_sub` |
| 3 | `TOK_SHL TOK_SAR TOK_SHR` | `OP_shl / OP_sar / OP_shr` |
| 4 | `'<' TOK_LTE '>' TOK_GTE TOK_INSTANCEOF TOK_IN` (`PF_IN_ACCEPTED`) | `OP_lt / OP_lte / OP_gt / OP_gte / OP_instanceof / OP_in` |
| 5 | `TOK_EQ TOK_NEQ TOK_STRICT_EQ TOK_STRICT_NEQ` | `OP_eq / OP_neq / OP_strict_eq / OP_strict_neq` |
| 6 | `'&'` | `OP_and` |
| 7 | `'^'` | `OP_xor` |
| 8 | `'|'` | `OP_or` |

Level 4 is also where `TOK_PRIVATE_NAME in obj` is handled by emitting
`OP_scope_in_private_field` (mirror `quickjs.c:27074-27075`).

#### F4.3 Assignment-op encoding

`js_parse_assign_expr2` encodes compound assignments with
`opcode = (op - TOK_MUL_ASSIGN) + OP_mul` (mirrored at the local site).
This relies on `TOK_*` ordering matching `OP_*` ordering, which is
enforced by §1.5.4 invariants.

#### F4.4 LHS reference encoding

Mirror QuickJS's reference-on-stack convention. After
`parseLhsExpr`, the stack-shape is one of:
- **VarRef**: just an `OP_scope_get_var` was emitted; assignment is done
  by replacing it with `OP_scope_put_var` (re-emit, drop the original via
  `s->cur_func->byte_code` truncation, exactly as QuickJS does in
  `set_object_name` and friends).
- **DottedRef**: stack has `obj` from `OP_get_field2` (dup-then-get).
  Assignment: `OP_put_field name`.
- **IndexedRef**: stack has `obj key` from `OP_get_array_el2`. Assignment:
  `OP_put_array_el`.
- **SuperRef**: stack has `this obj prop`. Assignment: `OP_put_super_value`.
- **Pattern (object/array)**: parsed via `parseDestructuringElement` (F6).

#### F4.5 Optional chaining and `new` chains

- `OP_get_field_opt_chain` and `OP_get_array_el_opt_chain` are emitted as
  Phase 1 temp ops; F10 lowers them using the exit label set up by
  `js_parse_optional_chain` (mirror lines around `quickjs.c:24530`).
- `new X.Y(args)` reuses `parseLhsExpr` recursively; `new.target` is
  emitted as `OP_special_object OP_SPECIAL_OBJECT_NEW_TARGET` and the
  `s->cur_func->new_target_allowed` flag is checked.

#### F4.6 Context flags carried by `FunctionDef`

The expression parser reads these from `cur_func`:
`is_strict_mode`, `func_kind` (for `await`/`yield`),
`new_target_allowed`, `super_call_allowed`, `super_allowed`,
`arguments_allowed`, `has_eval_call` (set on `eval(...)` calls). All match
`JSFunctionDef` field names in `quickjs.c:21420`.

#### F4.7 Implementation guard

- No global precedence table file. The recursion structure stays as
  separate functions matching `js_parse_*` exactly.
- Forbidden identifiers in this layer (full list in §F4.8); no new
  references allowed.

#### F4.8 Fixture-recogniser deletion (no new references allowed in F4)

`peekMapPrototypeSetGetterThrowDefinition`,
`peekObjectDefinePropertyGetterThrowTarget`, `peekDottedAssignment`,
`peekDottedCall`, `peekPropertyFunctionThrowsTest262`, `peekGetterNamed`,
`peekSymbolIteratorUndefinedProperty`, `peekSymbolIteratorProperty`,
`peekIterReturnTrackerObjectLiteral`, `peekInvalidSetLikeObjectLiteral`,
`peekInvalidSetLikeExpression`, `peekInvalidWeakKeyExpression`,
`peekNonCallableExpression`, `peekSetLikeObjectLiteralShape`,
`peekComputedIteratorUndefinedObjectLiteral`,
`peekThrowingIteratorObjectLiteral`, `peekSimpleObjectIntLiteral`,
`peekSingleIntArrayLiteral`, `peekForOfLiteralArray`, `peekSignedSmallInt`,
`peekNoParamReturnSmallInt`, `peekBodyIncrementsThenThrows`,
`peekNewDateNaNToISOString`, `isHarnessVarName`,
`isHarnessAssignmentBase`, `isHarnessFunctionName`, `isLiteralIdentifier`,
`isStrictImmutableGlobalName`.

#### F4.9 Tests

- `tests/zig-frontend/parse-expressions/<feature>` fixtures, each with at
  least five inputs covering the precedence boundary.
- `tests/zig-frontend/parse-expressions/golden/` stores reference opcode
  disassemblies. Goldens are generated by running the matching script
  through QuickJS `qjs --bytecode-dump` and stripping atom ids. Any drift
  in op sequence vs. goldens is an F4 regression.
- Open up real test262 dirs:
  `language/expressions/{addition,subtraction,multiplication,division,
  modulo,equals,strict-equals,strict-not-equals,less-than,greater-than,
  logical-and,logical-or,conditional,assignment,assignmenttargettype,
  in,instanceof,typeof,delete,void,unary-minus,unary-plus,bitwise-and,
  bitwise-or,bitwise-xor,bitwise-not,left-shift,right-shift,
  unsigned-right-shift,exponentiation,nullish-coalescing,
  optional-chaining,template-literal,member-expression,call,new,
  array,object}`.

**Exit:** `language/expressions` ≥ 60%; existing fixtures and curated
slices do not regress.

### F5 — Generic statement parser

**QuickJS reference:** `js_parse_statement_or_decl`
(`quickjs.c:28228`), `js_parse_statement` (`quickjs.c:27822`),
`js_parse_block` (`quickjs.c:27827`), `js_parse_var` (`quickjs.c:27847`),
`js_parse_for_in_of` (`quickjs.c:27991`), `js_parse_directives`
(`quickjs.c:35642`), `js_parse_source_element` (`quickjs.c:31435`),
`BlockEnv` (`quickjs.c:21352`).

Replace `parseStatement` with `parseStatementOrDecl` matching the QuickJS
top-level switch byte-for-byte. Statement labels and `BlockEnv` push/pop
are mandatory — they are how QuickJS routes `break`/`continue` and
finalises iterators on non-local exit.

#### F5.1 Statement coverage

- Block `{ … }`, ExpressionStatement, EmptyStatement, Var/Let/Const
  declarations, IfStatement (with else), do-while, while, C-style for,
  `for (… in …)`, `for (… of …)`, `for await (… of …)`, break, continue,
  labeled statement, return, throw,
  `try { } catch (e) { } finally { }`, switch, with (non-strict only),
  debugger.
- Directive prologue: leading string-literal statements, recognising
  `"use strict"` and ignoring unknown directives.
- ASI: `return`, `throw`, `break`, `continue`, postfix `++`/`--`.

#### F5.2 BlockEnv stack (mirror `quickjs.c:21352`)

`BlockEnv` is a linked-list pushed on every iteration / switch / try /
labelled-statement. Fields mirror QuickJS exactly:

```
pub const BlockEnv = struct {
    prev: ?*BlockEnv,
    label_name: Atom,    // ATOM_NULL if none
    label_break: i32,    // -1 if none
    label_cont: i32,     // -1 if none
    drop_count: i32,     // stack elements to drop on break/continue
    label_finally: i32,  // -1 if none
    scope_level: i32,
    has_iterator: bool,  // 1 bit
    is_regular_stmt: bool, // 1 bit
};
```

Helpers `push_break_entry` / `pop_break_entry` (mirror `quickjs.c`) push
and pop the stack. `break <label>` walks the chain looking for matching
`label_name`; `continue <label>` walks looking for matching `label_cont`;
either dispatches `OP_iterator_close` `drop_count` times (for `for-of` /
`for-in` loops with `has_iterator`) before the jump.

#### F5.3 Emit protocol

- if/else: `parse cond ; if_false L_else ; parse stmt_true ; goto L_end ;
  L_else: parse stmt_false ; L_end:`.
- while: `L_top: parse cond ; if_false L_end ; push BlockEnv(L_end,L_top) ;
  parse body ; pop ; goto L_top ; L_end:`.
- do-while: `L_top: push BlockEnv(L_end,L_cont) ; parse body ; L_cont:
  parse cond ; if_true L_top ; pop ; L_end:`.
- C-style for: `parse init ; L_top: parse cond ; if_false L_end ; push
  BlockEnv(L_end,L_cont) ; parse body ; L_cont: parse update ; goto
  L_top ; pop ; L_end:`. Mirror `js_parse_iter_block`.
- for-in / for-of: emit `OP_for_in_start` / `OP_for_of_start`, then
  `L_top: OP_for_in_next` / `OP_for_of_next` lhs ; `if_false L_end` ;
  body ; `goto L_top ; L_end: OP_iterator_close`. Mirror
  `js_parse_for_in_of` (`quickjs.c:27991`). `BlockEnv.has_iterator = true`
  so `break` correctly closes the iterator.
- try/catch/finally: mirror `quickjs.c` exactly:

  ```
  catch L_catch
  ... try body ...
  goto L_after_try
  L_catch:
  // exception value is on stack
  enter_scope catch_scope ; bind to e ; ... catch body ...
  leave_scope catch_scope
  L_after_try:
  // optional finally:
  gosub L_finally ; goto L_end
  L_finally: ... finally body ... ret
  L_end:
  ```

  `BlockEnv.label_finally` carries `L_finally` so non-local exits
  (`return`, `break`, `continue`, `throw`) go through `gosub L_finally`
  before leaving.
- switch: classic if-chain. `case` literal emits `dup ; expr ;
  strict_eq ; if_false L_next_case`; `default` is a separate label that
  is patched after all cases. `BlockEnv.label_break` is the switch end.
- labeled: push a `BlockEnv` with `label_name = atom`, `label_break =
  L_end`, `label_cont = L_top` (only for loops). `is_regular_stmt = true`
  for non-loop labelled statements per QuickJS at `quickjs.c:28265`.

#### F5.4 Fixture-recogniser deletion

Remove: `parseForOfArrayStatement`, `parseForOfLiteral`,
`parseForInConcatStatement`, `parseForNumericSumStatement`,
`parseForAccumDelta`, `parseForFunctionCallDelta`, `parseForMathMinDelta`,
`parseWhileIncrementStatement`, `parseIfThrowTest262Statement`,
`parseTryFinallyGlobalRestore`, `parseDateTryCatch`, `parseUriTryCatch`,
`parseUriCall`, `parseForInDontEnumStatement`,
`parseSyntheticSetLikeObjectLiteral`,
`parseSyntheticIterReturnTrackerObjectLiteral`, `parseClassifyCall`,
`parseClosureVarCall`, `parseSimpleCall`, `parseEvalCall`,
`parseHarnessAssignmentIfPresent`, `parseSkippedArrowExpressionIfPresent`,
`parsePatternAssignmentIfPresent`, `parseGenericCallOnStack`,
`parseGenericPropertyCallOnStack`, `parseConstructArguments`,
`parseArrowThrowBody`, `parseObjectStaticCallIfPresent`,
`parseObjectCallAfterDot`, `parseDatePrimary`, `parseDateArguments`.

#### F5.5 Tests

- `tests/zig-frontend/parse-statements/` covers every statement form ×
  strict / non-strict × ASI boundary.
- Open up `language/statements/{block, break, continue, do-while, for,
  for-in, for-of, if, labeled, return, switch, throw, try, variable,
  while}`.

**Exit:** `language/statements` ≥ 60%; F4 numbers do not regress.

### F6 — Functions / arrows / defaults / destructuring / rest

**QuickJS reference:** `js_parse_function_decl` (`quickjs.c:36388`),
`js_parse_function_decl2` (`quickjs.c:35824`),
`js_parse_function_check_names` (`quickjs.c:35747`),
`js_parse_destructuring_element` (`quickjs.c:25716`),
`js_parse_destructuring_var` (`quickjs.c:25692`),
`js_parse_check_duplicate_parameter` (`quickjs.c:25673`),
`add_var` (`quickjs.c:23554`), `push_scope` (`quickjs.c:23486`),
`pop_scope` (`quickjs.c:23532`),
`JSParseFunctionEnum` (`quickjs.c:21401`).

#### F6.1 FunctionDef lifecycle (mirror `js_create_function`)

A new `FunctionDef` is created when entering each function (or arrow,
method, getter, setter, class static block, class constructor); fields
mirror `JSFunctionDef` (`quickjs.c:21420`) one-to-one. Required fields
for the F6 milestone:

- `parent: ?*FunctionDef`, `parent_cpool_idx: i32`,
  `parent_scope_level: i32`.
- `func_kind: FunctionKind` (NORMAL/GENERATOR/ASYNC/ASYNC_GENERATOR).
- `func_type: ParseFunctionKind` (10 values from
  `JSParseFunctionEnum`).
- `is_strict_mode`, `has_simple_parameter_list`,
  `has_parameter_expressions`, `has_use_strict`, `has_eval_call`,
  `has_arguments_binding`, `has_this_binding`, `new_target_allowed`,
  `super_call_allowed`, `super_allowed`, `arguments_allowed`,
  `is_derived_class_constructor`, `in_function_body`,
  `backtrace_barrier`, `need_home_object`.
- `vars: ArrayList(VarDef)`, `args: ArrayList(VarDef)`,
  `var_object_idx`, `arg_var_object_idx`, `arguments_var_idx`,
  `arguments_arg_idx`, `func_var_idx`, `eval_ret_idx`, `this_var_idx`,
  `new_target_var_idx`, `this_active_func_var_idx`, `home_object_var_idx`.
- `scopes: ArrayList(VarScope)`, `scope_level`, `scope_first`,
  `body_scope`.
- `global_vars: ArrayList(GlobalVar)`.
- `byte_code: ArrayList(u8)`, `last_opcode_pos: i32`.
- `label_slots: ArrayList(LabelSlot)`, `top_break: ?*BlockEnv`.
- `cpool: ArrayList(Value)`.
- `closure_var: ArrayList(ClosureVar)`.
- `jump_slots: ArrayList(JumpSlot)`,
  `source_loc_slots: ArrayList(SourceLocSlot)`,
  `line_number_last`, `line_number_last_pc`, `col_number_last`.
- `filename: Atom`, `line_num: i32`, `col_num: i32`.
- `pc2line: ArrayList(u8)`.
- `module: ?*ModuleDef`.

`js_create_function` (`quickjs.c:35401`) walks the `child_list` — every
`FunctionDef` registered as a child runs Phase 2 + Phase 3 in F10.

#### F6.2 Function definitions

- `function name(p1, p2 = 1, ...rest) { body }` is parsed by
  `parseFunctionDecl2`; it pushes a fresh `FunctionDef` and a separate
  argument scope when `has_parameter_expressions` (defaults or
  destructuring trigger this).
- Hoisting: at the parent scope, function declarations register a
  `JSGlobalVar` with `cpool_idx = const_idx_of_inner_function`,
  matching `quickjs.c` `add_func_var`.
- Function name binding: a function expression with a name introduces a
  read-only `JS_VAR_FUNCTION_NAME` binding inside the function body
  (mirror QuickJS).
- Strict-mode propagation: directives `"use strict"` in the body set
  `has_use_strict`. The argument list cannot contain non-simple parameter
  patterns when `has_use_strict` is set without parameters being simple
  (mirror `js_parse_function_check_names`).
- Duplicate parameter check: `js_parse_check_duplicate_parameter`
  rejects duplicates in strict mode or when destructuring/defaults are
  present.

#### F6.3 Arrows and named evaluation

- Arrow head detection follows `js_parse_skip_parens_token`
  (`quickjs.c:24194`): on `(`, peek to find the matching `)` and check
  for `=>`, `async ident =>`, `async (…) =>`. Mirror the bit-flag
  vocabulary `SKIP_*` from QuickJS.
- Arrow `FunctionDef` has `func_type = JS_PARSE_FUNC_ARROW`, no
  `arguments` binding, no `this` binding (`has_this_binding = false`);
  references to `this` / `super` / `new.target` / `arguments` are
  resolved upwards as closure variables.
- Named evaluation: when `parseAssignExpr2` sees `let f = anonymous`, it
  emits a temporary `OP_set_name f` after the right-hand side; F10
  rewrites it during phase 2 (mirror `set_object_name` and friends).

#### F6.4 Destructuring and rest

- Binding: `let { a, b: c, d = 1, ...rest } = obj`,
  `let [x, y, ...z] = arr`, nested forms. Each component delegates to
  `parseDestructuringElement`, which emits `OP_dup`, `OP_get_field`
  (or `OP_get_array_el`), `OP_scope_put_var name` per binding, exactly
  as QuickJS `js_parse_destructuring_element` does.
- Assignment: `({a, b} = obj);` and `[x, y] = arr;` reuse the same
  helper but emit `OP_scope_put_var name` (or property/array-el puts) for
  each component.
- Defaults: a missing slot tests `OP_is_undefined`; if true, parse and
  emit the default expression. Mirror the `OP_undefined` emit pattern
  used by QuickJS.
- Iterator forms (`[x, y, ...z]`): emit `OP_for_of_start`, then
  `OP_for_of_next` per slot, with `OP_iterator_close` on completion or
  abrupt exit.
- Rest parameter: `function f(...rest)` emits the prologue
  `OP_rest <first_rest_arg_index>` (3-byte u16 form). Argument count
  bookkeeping in `arg_count`, `defined_arg_count`, `var_count`.
- Spread in calls: `f(...x)` lowers via `OP_array_from <argc> ; apply`.

#### F6.5 Fixture-recogniser deletion

Remove: `parseFunctionExpressionValue`,
`parseArrowFunctionExpressionValueIfPresent`, `parseArrowDefinition`,
`parseFunctionBodyKind`, the closure-shape state on `QuickParser`
(`functions: [16]QuickFunction`, `closure_var_*`, `last_expression_*`,
`postfix_receiver_*`).

#### F6.6 Tests

Open up `language/expressions/arrow-function`,
`language/expressions/function`, `language/statements/function`,
`language/destructuring`, `language/expressions/assignment`. Async forms
move in F9.

**Exit:** ≥ 60% on the four new dirs; F4–F5 numbers do not regress.

### F7 — Classes and private fields

**QuickJS reference:** `js_parse_class` (`quickjs.c:24667`),
`js_parse_class_default_ctor` (`quickjs.c:24610`),
`js_parse_function_class_fields_init` (`quickjs.c:35797`),
`add_brand` / `check_brand` (search `OP_add_brand` / `OP_check_brand`),
`JS_VAR_PRIVATE_FIELD` / `JS_VAR_PRIVATE_METHOD` /
`JS_VAR_PRIVATE_GETTER` / `JS_VAR_PRIVATE_SETTER` /
`JS_VAR_PRIVATE_GETTER_SETTER` (`quickjs.c:707`),
`JS_PARSE_FUNC_CLASS_CONSTRUCTOR` /
`JS_PARSE_FUNC_DERIVED_CLASS_CONSTRUCTOR` /
`JS_PARSE_FUNC_CLASS_STATIC_INIT` (`quickjs.c:21401`).

#### F7.1 Syntax

`class C extends B {
   constructor(a) { super(a); }
   method() {}
   static smethod() {}
   get x() {} set x(v) {}
   static get y() {}
   #x; static #y;
   #m() {} static #sm() {}
   static { /* class static block */ }
 }`

Reference: `js_parse_class` (`quickjs.c` line 24667),
`js_parse_class_default_ctor` (line 24610).

#### F7.2 Implementation

- ClassBody scope: parent `extends` reference, `super` binding, private
  field brand checks (`add_brand`, `check_brand`).
- Field initialisers: instance fields run at the start of the constructor;
  static fields run after the class object is built. Implement an internal
  field-init function as in `js_parse_function_class_fields_init` (line
  35797).
- `super(args)`: in derived constructors, lower to `OP_get_super` plus
  `OP_call_constructor`.
- `super.foo` / `super[k]`: `OP_get_super_value` / `OP_put_super_value`.
- Private fields `#x`: lexical names; emit `OP_scope_get_private_field` /
  `OP_scope_put_private_field` (Phase 1) and lower in Phase 2 to brand
  checks against the receiver's private slot.

#### F7.3 Tests

Open `language/expressions/class`, `language/statements/class`, and the
class-related `built-ins/` slices.

**Exit:** ≥ 50% on the class dirs; earlier phases' numbers do not regress.

### F8 — Modules

**QuickJS reference:** `js_parse_import` (`quickjs.c:31312`),
`js_parse_export` (`quickjs.c:31090`), `js_parse_from_clause`
(`quickjs.c:31039`), `js_parse_with_clause` (`quickjs.c:30950`),
`JSReqModuleEntry` (`quickjs.c:887`), `JSExportEntry` (`quickjs.c:898`),
`JSStarExportEntry` (`quickjs.c:912`), `JSImportEntry` (`quickjs.c:916`).

#### F8.1 Static syntax

- Imports: `import x from "m"`, `import { a, b as c } from "m"`,
  `import * as ns from "m"`, `import "m"`, `import x, { a } from "m"`,
  `import x, * as ns from "m"`.
- Exports: default, named, re-export, `export *`, `export * as ns from`,
  `export { a as default }`.
- Reference: `js_parse_import`, `js_parse_export`, `js_parse_from_clause`.

#### F8.2 Dynamic forms

- `import.meta`: constant object injected by the host.
- `import("m")`: emit `OP_import` (5, 1, 1, npop_u16); returns a Promise.

#### F8.3 Tests

Open `language/module-code`, `language/import`, `language/export`.

**Exit:** ≥ 50% on the three module dirs; earlier phases unchanged.

### F9 — Generators / async / async iteration

**QuickJS reference:** `JS_FUNC_GENERATOR` / `JS_FUNC_ASYNC` /
`JS_FUNC_ASYNC_GENERATOR` (`quickjs.c:761`), `JSAsyncFunctionState`
(`quickjs.c:879`), `JSAsyncFunctionData` (`quickjs.c:885`), opcodes
`OP_initial_yield` / `OP_yield` / `OP_yield_star` / `OP_async_yield_star`
/ `OP_await` / `OP_return_async` / `OP_for_await_of_start` (in
`quickjs-opcode.h`).

#### F9.1 Syntax + bytecode

- `function* g() { yield 1; yield* arr; }` emits `initial_yield` in the
  prologue and `yield`/`yield_star` at the boundaries.
- `async function f() { await x; }` emits `return_async` and `await`.
- `for await (x of obj)` uses `for_await_of_start` + `for_of_next` with
  the await flag.

#### F9.2 VM state machine

- Suspend/resume frames (QuickJS `JSGeneratorState`). F3's simplified
  dispatcher only needs to surface `yield` as a state-bearing return; the
  full state machine ships in F9b.
- Sub-phases:
  - F9a: syntactic acceptance + non-suspending lowering (immediate-result
    generators throw on first `yield`).
  - F9b: full generator suspend/resume.
  - F9c: async/await + microtask scheduling tied to the existing job
    queue.

#### F9.3 Tests

Open `language/statements/async-function`,
`language/statements/async-generator`,
`built-ins/AsyncIteratorPrototype`.

**Exit:** ≥ 40% on the async dirs; earlier phases unchanged.

### F10 — Phase 2 + Phase 3 compilation pipeline

**QuickJS reference:** `js_create_function` (`quickjs.c:35401`),
`resolve_variables` (`quickjs.c:33622`), `resolve_scope_var`
(`quickjs.c:32377`), `get_closure_var` (`quickjs.c:32162`),
`mark_eval_captured_variables` (`quickjs.c:~32510`),
`add_eval_variables` (`quickjs.c:~32550`), `resolve_labels`
(`quickjs.c:34197`), `compute_pc2line_info` (`quickjs.c:33995`),
`compute_stack_size` (`quickjs.c:35167`), `push_short_int`
(`quickjs.c:34120`), `put_short_code` (`quickjs.c:34140`).

The pipeline lives under `src/engine/bytecode/pipeline/`:

```
pipeline/
  resolve_variables.zig   // Phase 2
  resolve_labels.zig      // Phase 3a
  pc2line.zig             // Phase 3b
  stack_size.zig          // Phase 3c
  finalize.zig            // js_create_function: walk child_list, install
                          // FunctionBytecode into the cpool of the parent
```

#### F10.1 Phase 2 — `resolve_variables` (`quickjs.c:33622`)

- Input: a `FunctionDef` whose `byte_code` contains Phase-1 ops only.
- Pre-pass: walk `global_vars` for eval-global declarations; emit
  `OP_check_define_var atom flags` for each, mirroring
  `quickjs.c:33636-33672`. `flags` packs `DEFINE_GLOBAL_LEX_VAR` and
  `DEFINE_GLOBAL_FUNC_VAR`.
- Main pass: linear scan over `byte_code`. For each opcode:
  - `OP_source_loc`: bump `source_loc_size`, copy through.
  - `OP_eval` / `OP_apply_eval`: convert `scope_idx` operand to
    `s->scopes[scope].first + 1` (variable index), and call
    `mark_eval_captured_variables` to flag every captured local in the
    enclosing chain.
  - `OP_scope_get_var* / OP_scope_put_var* / OP_scope_make_ref`: call
    `resolveScopeVar(name, scope_level)` which walks the lexical chain
    via `findVarInScope` and falls through to `getClosureVar`. Result
    emits one of `get_loc / put_loc / get_arg / put_arg / get_var_ref /
    put_var_ref / get_var / put_var / make_loc_ref / make_arg_ref /
    make_var_ref_ref / make_var_ref` per the `JSClosureTypeEnum`
    classification (`LOCAL / ARG / REF / GLOBAL_REF / GLOBAL_DECL /
    GLOBAL / MODULE_DECL / MODULE_IMPORT`).
  - `OP_scope_get_private_field*` / `OP_scope_put_private_field*` /
    `OP_scope_in_private_field`: lower to
    `OP_get_private_field` / `OP_put_private_field` /
    `OP_private_in` after locating the brand on the receiver.
  - `OP_get_field_opt_chain` / `OP_get_array_el_opt_chain`: thread the
    optional-chain exit label, lower to `OP_get_field` / `OP_get_array_el`
    plus the `is_undefined_or_null` short-circuit.
  - `OP_set_class_name`: rewrite the just-emitted `OP_define_class` /
    `OP_fclosure` constant pool name.
  - `OP_enter_scope` / `OP_leave_scope`: dropped.
  - `OP_label`: passed through unchanged (handled by Phase 3a).
- TDZ: when `resolveScopeVar` resolves to a `let`/`const` binding before
  its lexical declaration point, emit the `_check` variant
  (`get_loc_check`, `put_loc_check`, `put_loc_check_init`,
  `get_var_ref_check`, `put_var_ref_check`, `put_var_ref_check_init`).
- After Phase 2: `byte_code` contains no temp opcodes except `OP_label`.

#### F10.2 Phase 3a — `resolve_labels` (`quickjs.c:34197`)

- Function prologue: emit (in this order, only when the corresponding
  `*_var_idx >= 0`):
  - `OP_special_object OP_SPECIAL_OBJECT_HOME_OBJECT ; OP_put_loc home_object_var_idx`
  - `OP_special_object OP_SPECIAL_OBJECT_THIS_FUNC ; OP_put_loc this_active_func_var_idx`
  - `OP_special_object OP_SPECIAL_OBJECT_NEW_TARGET ; OP_put_loc new_target_var_idx`
  - For `this_var_idx`: `OP_set_loc_uninitialized` if derived ctor;
    else `OP_push_this ; OP_put_loc this_var_idx`.
  - For `arguments_var_idx`: `OP_special_object` with `ARGUMENTS` or
    `MAPPED_ARGUMENTS` (capturing every arg via `capture_var` for the
    mapped form), then `OP_set_loc arguments_arg_idx` if needed, then
    `OP_put_loc arguments_var_idx`.
  - For `func_var_idx`: `OP_special_object OP_SPECIAL_OBJECT_THIS_FUNC ;
    OP_put_loc func_var_idx`.
  - Mirror lines `quickjs.c:34230-34320`.
- Per-op rewrite: walk the `byte_code` once, for every op compute `pos2`
  (byte address after compaction). Replace `OP_label id` with nothing
  but record the resulting address into `LabelSlot.addr`. For each
  jump (`OP_goto / OP_if_true / OP_if_false / OP_catch / OP_gosub`),
  add a `JumpSlot { op, size, pos, label }` so a final pass can patch
  the relative offsets.
- Short-form selection: every emit of `OP_get_loc / OP_put_loc /
  OP_set_loc / OP_get_arg / OP_put_arg / OP_set_arg / OP_get_var_ref /
  OP_put_var_ref / OP_set_var_ref / OP_call` goes through
  `putShortCode` (`quickjs.c:34140`) which selects `*0..*3` or `*8` or
  the full 16-bit form. Integer pushes go through `pushShortInt`
  (`quickjs.c:34120`) selecting `OP_push_minus1` / `OP_push_0..7` /
  `OP_push_i8` / `OP_push_i16` / `OP_push_i32`.
- Local pair coalescing: adjacent `OP_get_loc N ; OP_get_loc N+1` for
  `N ≤ 0` and `N+1 ≤ 1` collapses to `OP_get_loc0_loc1`.
- Final pass: walk the new bytecode, patch jumps with relative offsets
  using `JumpSlot.size` (1, 2, or 4 bytes). Drop unused
  `LabelSlot.first_reloc` entries.

#### F10.3 Phase 3b — `compute_pc2line_info` (`quickjs.c:33995`)

- Encoding: variable-length bytes per source-loc transition. Constants
  (mirror `quickjs.c:756`):
  - `PC2LINE_BASE = -1`, `PC2LINE_RANGE = 5`, `PC2LINE_OP_FIRST = 1`,
    `PC2LINE_DIFF_PC_MAX = (255 - 1) / 5 = 50`.
- For each `OP_source_loc` encountered, compute `(diff_pc, diff_line,
  diff_col)` and emit either the compact opcode form
  (`PC2LINE_OP_FIRST + diff_line * PC2LINE_RANGE + diff_pc` when in
  range) or the long form (a marker byte plus three signed varints).
- Output goes into `FunctionBytecode.pc2line_buf`.

#### F10.4 Phase 3c — `compute_stack_size` (`quickjs.c:35167`)

- BFS the bytecode graph. Per-pc stack-level table starts at
  `0xffff` (unknown). The entry pc is 0 with stack level 0.
- For each visited pc, take `oi = opcode_info[op]`; compute
  `n_pop` taking into account `OP_FMT_npop / OP_FMT_npop_u16 /
  OP_FMT_npopx`. Update `stack_len = stack_len - n_pop + oi->n_push`.
  Track `stack_len_max`.
- Visit successors: fall-through (unless return/throw/goto), and any
  jump targets (`OP_if_true / OP_if_false / OP_goto / OP_catch /
  OP_gosub`).
- `OP_catch` introduces a new entry pc with stack level + 1 (the caught
  exception). `OP_nip_catch` removes it.
- Failure modes (raise InternalError, mirror QuickJS):
  - stack underflow at any pc;
  - stack mismatch when revisiting a pc with a different level;
  - `stack_len_max > JS_STACK_SIZE_MAX`.
- Output `stack_size` into `FunctionBytecode.stack_size`.

#### F10.5 `js_create_function` finalisation

- Walk the parent's `child_list` of `FunctionDef`s. For each child:
  1. Run Phase 2 (`resolve_variables`).
  2. Run Phase 3a (`resolve_labels`) → temporary buffer.
  3. Run Phase 3b (`compute_pc2line_info`).
  4. Run Phase 3c (`compute_stack_size`).
  5. Allocate a `FunctionBytecode` using `JSFunctionBytecode` field
     layout (`quickjs.c:768`):
     - `byte_code_buf`, `byte_code_len`, `func_name`,
     - `vardefs[arg_count + var_count]`,
     - `closure_var[closure_var_count]`,
     - `arg_count`, `var_count`, `defined_arg_count`, `stack_size`,
       `var_ref_count`, `closure_var_count`,
     - `cpool[cpool_count]`,
     - `pc2line_buf`,
     - `filename`, `line_num`, `col_num`, `source`, `source_len`.
  6. Install in the parent's cpool at `parent_cpool_idx`.
- The top-level program produces a single `FunctionBytecode` returned to
  `JS_EvalThis2`.

#### F10.6 Tests

- **QuickJS bytecode parity**: write `tools/compare/dump-zjs-bytecode.zig`
  that prints our final bytecode in QuickJS-`qjs --bytecode-dump`
  format. Drive it on a 50-script sample (committed under
  `tests/test262-anchors/F10/sample.list`); diff op sequences,
  `arg_count`, `var_count`, `stack_size`, `closure_var_count`. Allow
  atom-id and label-id remapping; require **100% op-sequence parity**
  on the sample.
- `pipeline/stack_size_test.zig` per opcode family (try/catch, calls,
  iterators, finally) — verify `stack_size` matches the QuickJS dump.
- `pipeline/pc2line_test.zig` — encode/decode a synthetic table, assert
  decoded `(pc, line, col)` triples match the input.
- `bytecode/short_code_test.zig` — for every `(op, idx)` combination,
  assert `putShortCode` emits the same short form that `qjs` produces.

**Exit:**
- `zig build test`, `zig build smoke`, `zig build run-test262` all
  green.
- 50-script bytecode parity sample: 100% op-sequence match against
  QuickJS dump.
- Bytecode byte size shrinks by ≥ 30% versus Phase-2 output (driven by
  short opcodes and short integers).

### F11 — Fixture recognisers fully deleted

#### F11.1 Deletion checklist

- `src/engine/frontend/parser.zig`: remove every `peek*Object`,
  `peek*Array`, `peek*Statement`, `parseSynthetic*`, `parseHarness*`,
  `parseDate*`, `parseUri*`, `parseFor*Statement` (legacy),
  `parseClassify*`, `parseClosureVar*`, `parseSimpleCall`, `isHarness*`,
  `isLiteralIdentifier`, `isStrictImmutableGlobalName`, plus all
  fixed-size `*_var_names[16]` scratch arrays
  (`closure_var_*`, `regexp_var_*`, `date_var_*`, `int_var_*`,
  `array_first_var_*`, `literal_array_var_*`, `invalid_weak_key_var_*`,
  `invalid_setlike_var_*`, `coercing_setlike_var_*`,
  `set_subclass_var_*`, `setlike_class_var_*`, `iterator_var_*`,
  `entry_getter_throw_var_*`, `throwing_iterator_var_*`,
  `string_var_*`, `last_expression_*`, `postfix_receiver_*`).
  Target: `parser.zig` < 2 000 lines.
- `src/engine/bytecode/emitter.zig`: remove `emitArrayMethod`,
  `emitStringMethod`, `emitMathCall`, `emitParseInt`, `emitParseFloat`,
  `emitNewDate`, `emitDateCall`, `emitDateStatic`, `emitDateMethod`,
  `emitNewCollection`, `emitUriCall`, `emitNewTypedArray`,
  `emitNewDataView`, `emitDataViewGet`, `emitDataViewSet`,
  `emitArrayBufferSlice`, `emitStringFromCharCode`,
  `emitNewStringObject`, `emitNewClosure`, `emitCallClosure`,
  `emitNewPromise`, `emitPromiseStatic`, `emitNewRegExp`,
  `emitRegExpMethod`, `emitObjectKeys/Values/Entries`,
  `emitArrayJoin`, `emitNewFunction`, `emitBigIntAsN`. All callers move
  to generic `emitOpAtom(op.call_method, name)` or built-in lookups.
- `src/engine/exec/vm.zig`: remove the dispatch arms for the high-level
  opcodes and the helpers `arrayMethod`, `stringMethod`, `mathCall`,
  `regExpMethod`, `dateMethod`, `dateCall`, `dateStatic`, `newDate`,
  `parseIntCall`, `parseFloatCall`, `uriCall`, `newTypedArray`,
  `newDataView`, `arrayBufferSlice`, `dataViewGet`, `dataViewSet`,
  `newCollection`, `newStringObject`, `newClosure`, `callClosure`,
  `newPromise`, `promiseStatic`, `newRegExp`, `objectKeys`,
  `arrayJoin`, `newFunction`, `bigIntAsN`. Their behaviour is now
  reachable through generic `call`/`call_method` against built-ins in
  `src/engine/builtins/`.

#### F11.2 Built-in surface

- `Math.min(a, b, c)` — parser emits `get_var Math; get_field min;
  call 3`. `builtins/math.zig` already implements `min`.
- `Array.prototype.map`, `String.prototype.replace`,
  `Date.prototype.getTime`, `RegExp.prototype.exec`, `Object.keys`,
  `JSON.stringify`, `parseInt`, `encodeURIComponent`, `Promise.resolve`,
  etc., already exist in built-ins. F11 simply ensures they are reached
  through the generic call channel.

#### F11.3 Verification

- `parser.zig` < 2 000 lines.
- `grep -c "isHarness\|peek.*Object\|parseSynthetic\|fixture"
  src/engine/frontend/parser.zig` returns 0.
- Emitter and VM contain zero dispatch arms for legacy high-level
  opcodes.
- Total test262 ≥ 25 000 / 48 205 (~52%) passing; remaining failures
  dominated by `built-ins/Promise` / `built-ins/Intl` /
  `built-ins/Atomics` / `built-ins/Date` edges /
  `built-ins/RegExp` / `language/expressions/yield` and similar
  builtin / runtime gaps tracked by `WQ-012` / `WQ-013` / `WQ-014`.

**Exit:** the deletion checklist is satisfied; the test262 number
target is met or exceeded.

### F12 — RegExp / template literals / tagged templates

**QuickJS reference:** `js_parse_template` (`quickjs.c:23880`),
`js_parse_template_part` (`quickjs.c:21794`), `js_parse_regexp`
(`quickjs.c:22005`), `JSRegExp` (`quickjs.c:741`),
`OP_regexp` (`quickjs-opcode.h`).

Done after F11 because it depends on the generic parser already accepting
template and regex literals.

- Wire `libs/regexp/` into the runtime so RegExp literal compilation and
  RegExp method execution share one path.
- Template substitution: `\``a${b}c$\``` emits `template_head + expr +
  template_middle + expr + template_tail`; the VM concatenates via the
  standard built-in (QuickJS `concat_string`).
- Tagged templates: `tag\``…${x}…$\``` calls `tag(stringsArray, ...subs)`
  where `stringsArray` carries the `raw` property.
- Complete the missing String methods (`normalize`, iterators, locale
  variants).

**Exit:** `built-ins/RegExp` ≥ 50%;
`language/expressions/template-literal` ≥ 80%.

## 4. Cross-Phase Discipline

### Anti-regression

- `tools/test262_runner.zig` accepts
  `--regression-baseline reports/test262-by-dir.json`. If any directory's
  pass rate drops, the runner exits non-zero and CI rejects the change.
- `zig build test` and `zig build smoke` must stay green at every phase.
- `quickjs/test262_errors.txt` must not gain entries.

### Forbidden shortcuts

- No new `peek*` / `parseSynthetic*` / `isHarness*` / fixture-shape
  recognisers.
- No new high-level semantic opcodes (`*_method`, `*_call`, `*_static`
  shapes that do not appear in `quickjs/quickjs-opcode.h`).
- No widening of `quickjs/test262_errors.txt`, no new `feature=skip`
  entries, no new `excludefile` rows, no shrinking of `testdir` /
  `testfile` / `testindex` ranges.

### Reporting artefacts

At the end of each phase, update:

- `docs/quickjs-redesign/TRACKING.md`: phase status, current by-dir
  snapshot.
- `docs/quickjs-redesign/matrices/frontend-coverage-matrix.md`: support
  state for each grammar node.
- `docs/quickjs-redesign/matrices/opcode-execution-matrix.md`: dispatch
  state and unit-test coverage for each opcode.
- `reports/test262-by-dir.json` and `reports/test262-buckets.json`,
  committed.

### QuickJS comparison tooling

Built in F0 and used at every exit gate:

- `tools/compare/dump-quickjs-bytecode.sh <file.js>`: drive
  `qjs --bytecode-dump` (or equivalent) and capture ASCII bytecode.
- `tools/compare/dump-zjs-bytecode.zig`: produce the same dump for our
  pipeline.
- `tools/compare/diff-bc.zig`: strip atom ids and diff op sequences.
- `tools/compare/run-pair.sh <file.js>`: run the same test file under
  `qjs` and `zjs`, diff `stdout` / exit code. Run on a 100-file sample at
  every exit gate.

## 5. Work Decomposition

Each phase ships in 5–15 PRs. Each PR:

1. Touches one grammar node or one opcode family.
2. Adds Zig unit tests plus a `tests/test262-anchors/<phase>/` block
   containing a small representative test262 set used for fast regression
   checks.
3. Includes the `before` and `after` by-dir pass-rate snippets generated
   by the comparison tool.
4. Lists in its description: which fixture recognisers were removed, which
   generic opcodes were emitted, and the corresponding `quickjs.c`
   function name and line number used as reference.

## 6. Risk Register

| Risk | Mitigation |
|---|---|
| Index collisions during F2+F3 atomic swap | §2.5 audit confirms 88/95 ids overlap the wrong opcode; a transitional dual-key dispatcher is therefore unsound. F2+F3 lands as a single transactional change; an `opcode_alignment_test` plus a `no_legacy_known_test` (`@compileError` if `pub const known` reappears) plus the CI-enforced `tools/compare/opcode_align_check.py` (fails the build if mis-indexed or bespoke counts grow) guard the swap. |
| Atomic F2+F3 PR is too large to land safely in one merge | Implement behind a comptime feature flag (`use_quickjs_abi`) that builds either the legacy or the new path; flip the flag in the final commit of the series after every sub-PR's incremental work has been merged. |
| Phase 1 emit + Phase 2 resolve cannot reuse the current `Bytecode` struct | Introduce `bytecode/function_def.zig` (mirrors `JSFunctionDef`) holding Phase 1 byte stream, scopes, label slots, and closure vars. Phase 2/3 produce the final `Bytecode`. |
| Removing fixture recognisers regresses fixture-anchored slices | F4–F7 land each subsystem with the generic path first, fixtures rerouted through it; F11 only deletes the dead recognisers. Anti-regression gate guarantees coverage. |
| Destructuring + defaults + assignment-pattern path becomes a long-tail bug factory | F6 splits into F6a (binding destructuring) and F6b (assignment destructuring); both share helpers but have separate emit paths and test surfaces. |
| Generator / async state machine is large and edge-heavy | F9 splits into F9a (syntactic acceptance), F9b (generator suspend/resume), F9c (async/await + microtask scheduling). Each sub-phase has its own exit gate. |
| Effort estimates drift | F0 includes a spike: minimal subset (`var`, expressions, `if`, `while`, `function`, `call`) running through the new pipeline against `language/expressions/addition`. Calibrate later phase budgets against the spike pass rate. |

## 7. Phase / Slice Consistency Matrix

| Phase | `zig build test` | `zig build smoke` | `built-ins/Map` | `built-ins/Set` | `language/expressions` | `language/statements` | `language/destructuring` | `language/expressions/class` | `language/module-code` |
|---|---|---|---|---|---|---|---|---|---|
| F0 | green | green | no regression | no regression | baseline | baseline | baseline | baseline | baseline |
| F1 | green | green | no regression | no regression | baseline | baseline | baseline | baseline | baseline |
| F2+F3 (atomic) | green | green | no regression | no regression | baseline | baseline | baseline | baseline | baseline |
| F4 | green | green | no regression | no regression | **≥60%** | baseline | baseline | baseline | baseline |
| F5 | green | green | no regression | no regression | ≥60% | **≥60%** | baseline | baseline | baseline |
| F6 | green | green | no regression | no regression | ≥60% | ≥60% | **≥60%** | baseline | baseline |
| F7 | green | green | no regression | no regression | ≥60% | ≥60% | ≥60% | **≥50%** | baseline |
| F8 | green | green | no regression | no regression | ≥60% | ≥60% | ≥60% | ≥50% | **≥50%** |
| F9 | green | green | no regression | no regression | ≥60% | ≥60% | ≥60% | ≥50% | ≥50% |
| F10 | green | green | no regression | no regression | no regression | no regression | no regression | no regression | no regression |
| F11 | green | green | no regression | no regression | rising | rising | rising | rising | rising |
| F12 | green | green | no regression | no regression | rising | rising | rising | rising | rising |

## 8. Summary

- "Fix the parser" is in practice a frontend + bytecode-ABI + VM-core
  rewrite.
- **Strong-alignment contract** (§1, §1.5):
  - Opcodes come from `quickjs/quickjs-opcode.h` via comptime
    ParsedTable; no hand-written ids.
  - Predefined atoms come from `quickjs/quickjs-atom.h`; the existing
    229-entry table in `src/engine/core/atom.zig` is locked.
  - Token kinds are the QuickJS `TOK_*` values; the keyword block
    `TOK_NULL..TOK_AWAIT` is positionally aligned with the atom table
    so `token.atom = ATOM_null + (val - TOK_NULL)`.
  - Every Zig data structure with a QuickJS counterpart uses the
    QuickJS struct name (`FunctionDef`, `VarDef`, `VarScope`,
    `ClosureVar`, `BlockEnv`, `LabelSlot`, `JumpSlot`, `RelocEntry`,
    `SourceLocSlot`, `GlobalVar`, `Token`, `ParseState`,
    `FunctionBytecode`).
  - Every parser function with a QuickJS counterpart uses the QuickJS
    function name (`parseAssignExpr2`, `parseExprBinary`, `parseUnary`,
    `parsePostfixExpr`, `parseFunctionDecl2`,
    `parseDestructuringElement`, `parseClass`, `parseImport`,
    `parseExport`, …).
  - Three-phase compilation (`resolve_variables`, `resolve_labels`,
    `compute_pc2line_info`, `compute_stack_size`) mirrors the QuickJS
    pipeline step-for-step; deviations require an entry in
    `parser-deviation-matrix.md`.
- Order: F0 measurement → F1 lexer (TOK_*-aligned) → **F2+F3 atomic**
  (real opcode ABI paired with the generic dispatcher; see §2.5) →
  F4 expressions (mirror `js_parse_*`) → F5 statements (mirror
  `js_parse_statement_or_decl` + `BlockEnv`) → F6 functions
  (mirror `js_parse_function_decl2` + `JSFunctionDef`) → F7 classes
  (mirror `js_parse_class`) → F8 modules → F9 generator/async →
  F10 Phase 2/3 (mirror `resolve_variables` / `resolve_labels` /
  `compute_pc2line_info` / `compute_stack_size`) → F11 fixture
  deletion → F12 RegExp/template.
- Every phase exits on real test262 directory pass rates **and** a
  QuickJS bytecode parity check for sampled scripts. No exclusion, no
  skip widening, no `known_errors` inflation.
- After F11 the trunk target is ≥ 25 000 / 48 205 passing; the residual
  failures should land squarely in builtin / runtime gaps already tracked
  by `WQ-012` / `WQ-013` / `WQ-014`.

If F0 is approved, the first concrete step is to land the measurement
plumbing, the stderr fragmentation fix, the opcode-alignment audit tool,
and the locked-baseline SHA — then commit the baseline snapshot under
`docs/quickjs-redesign/baseline/2026-04-27/`.
