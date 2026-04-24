# Frontend Coverage Matrix

Purpose: split Phase 5 into parser and emitter work that can be implemented and
reviewed in small, source-aligned slices. This matrix forbids a standalone AST
execution path; every executable syntax feature must emit bytecode metadata.

## Lexer Matrix

| Area | QuickJS owner | Zig owner | Required coverage | Required fixtures | Status |
|---|---|---|---|---|---|
| Token definitions | `quickjs.c` token enum/parser tables | `frontend/token.zig` | Punctuation, operators, keywords, contextual keywords, private names | Token snapshot tests | not_started |
| Numeric literals | lexer numeric scanner | `frontend/lexer.zig` | Decimal, binary, octal, hex, numeric separators, BigInt suffix, legacy octal errors | Literal parse fixtures | not_started |
| String literals | lexer string scanner | `frontend/lexer.zig`, `libs/unicode.zig` where needed | Escapes, Unicode escapes, line continuations, strict errors | String fixture table | not_started |
| Template literals | template lexer | `frontend/lexer.zig` | No-substitution, head/middle/tail, raw/cooked values, escape errors | Template token fixtures | not_started |
| RegExp literals | regexp literal scanner | `frontend/regexp_literal.zig` | Pattern/body scan, flags, division ambiguity hooks | Regex-vs-div fixtures | not_started |
| Source positions | parser/lexer source locations | `frontend/source_pos.zig`, `bytecode/debug.zig` | Line/column/offset, filename, syntax error position | Error position fixtures | not_started |

## Parser And Emitter Matrix

| Syntax domain | QuickJS owner | Zig owner | Required emitted state | Required fixtures | Status |
|---|---|---|---|---|---|
| Script parse mode | script parse entry | `frontend/parser.zig`, `bytecode/emitter.zig` | Global scope, strict flag, top-level var/lexical records | Script basics | not_started |
| Module parse mode | module parser | `frontend/parser.zig`, `bytecode/module.zig` | Module record, requested modules, import/export entries, strict mode | Static import/export fixtures | not_started |
| Eval parse mode | eval parser | `frontend/parser.zig`, `bytecode/scope.zig` | Direct/indirect eval metadata, caller scope capture rules | Direct/indirect eval fixtures | not_started |
| Expressions | expression parser | `frontend/parser.zig`, `bytecode/emitter.zig` | Operator precedence, short-circuit jumps, optional chaining lowering | Precedence and chain fixtures | not_started |
| Statements | statement parser | `frontend/parser.zig`, `bytecode/emitter.zig` | Blocks, labels, loops, switch, try/catch/finally, with | Control-flow bytecode fixtures | not_started |
| Functions | function parser | `frontend/parser.zig`, `bytecode/function.zig` | Parameters, defaults, rest, strictness, var scope, closure vars | Function/scope fixtures | not_started |
| Arrow functions | arrow parser | `frontend/parser.zig`, `bytecode/function.zig` | Lexical `this`, parameter scope, expression/body forms | Arrow fixtures | not_started |
| Async functions | async parser | `frontend/parser.zig`, `bytecode/function.zig` | Async function flags, await emission, promise integration metadata | Async parse/emission fixtures | not_started |
| Generators | generator parser | `frontend/parser.zig`, `bytecode/function.zig` | Generator flags, yield/yield-star emission | Generator fixtures | not_started |
| Async generators | async generator parser | `frontend/parser.zig`, `bytecode/function.zig` | Async generator flags, await/yield interactions | Async generator fixtures | not_started |
| Classes | `js_parse_class` family | `frontend/parser.zig`, `bytecode/emitter.zig` | Constructor, methods, accessors, static elements, computed names, home object | Class accessor/method fixtures | not_started |
| Private names | private field parser | `frontend/parser.zig`, `bytecode/scope.zig` | Private name scope, brand checks, private field ops | Private field fixtures | not_started |
| Destructuring | destructuring parser/emitter | `frontend/parser.zig`, `bytecode/emitter.zig` | Object/array patterns, defaults, rest, nested targets | Destructuring fixtures | not_started |
| Spread/rest | argument and literal emission | `frontend/parser.zig`, `bytecode/emitter.zig` | Spread calls, spread arrays/objects, rest params/properties | Spread/rest fixtures | not_started |
| Imports/exports | module parser | `frontend/parser.zig`, `bytecode/module.zig` | Import entries, local/exported names, re-exports, namespace imports | Module metadata fixtures | not_started |
| Dynamic import | import expression parser | `frontend/parser.zig`, `bytecode/emitter.zig` | `import` opcode emission and promise handoff metadata | Dynamic import fixture | not_started |
| Error recovery boundary | syntax error creation | `frontend/parser.zig`, `core/exception.zig` | QuickJS-compatible parse errors and source locations | Negative syntax fixtures | not_started |

## Phase 5 Exit Additions

- Every row must have at least one fixture or an explicit deferral recorded in
  `TRACKING.md`.
- Fixtures should inspect bytecode, metadata, and syntax errors. They should not
  run JavaScript through the VM as proof for this phase.
- Class, eval, module, async/generator, and destructuring rows cannot be marked
  `validated` without source comments pointing to the relevant QuickJS parser
  functions.

