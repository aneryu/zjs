# Frontend Coverage Matrix

Purpose: split Phase 5 into parser and emitter work that can be implemented and
reviewed in small, source-aligned slices. This matrix forbids a standalone AST
execution path; every executable syntax feature must emit bytecode metadata.

## Lexer Matrix

| Area | QuickJS owner | Zig owner | Required coverage | Required fixtures | Status |
|---|---|---|---|---|---|
| Token definitions | `quickjs.c` token enum/parser tables | `frontend/token.zig` | Punctuation, operators, keywords, contextual keywords, private names | Token snapshot tests | validated |
| Numeric literals | lexer numeric scanner | `frontend/lexer.zig` | Decimal, binary, octal, hex, numeric separators, BigInt suffix, legacy octal errors | Literal parse fixtures | validated |
| String literals | lexer string scanner | `frontend/lexer.zig`, `libs/unicode.zig` where needed | Escapes, Unicode escapes, line continuations, strict errors | String fixture table | validated |
| Template literals | template lexer | `frontend/lexer.zig` | No-substitution, head/middle/tail, raw/cooked values, escape errors | Template token fixtures | validated |
| RegExp literals | regexp literal scanner | `frontend/regexp_literal.zig` | Pattern/body scan, flags, division ambiguity hooks | Regex-vs-div fixtures | validated |
| Source positions | parser/lexer source locations | `frontend/source_pos.zig`, `bytecode/debug.zig` | Line/column/offset, filename, syntax error position | Error position fixtures | validated |

## Parser And Emitter Matrix

| Syntax domain | QuickJS owner | Zig owner | Required emitted state | Required fixtures | Status |
|---|---|---|---|---|---|
| Script parse mode | script parse entry | `frontend/parser.zig`, `bytecode/emitter.zig` | Global scope, strict flag, top-level var/lexical records | Script basics | validated |
| Module parse mode | module parser | `frontend/parser.zig`, `bytecode/module.zig` | Module record, requested modules, import/export entries, strict mode | Static import/export fixtures | validated |
| Eval parse mode | eval parser | `frontend/parser.zig`, `bytecode/scope.zig` | Direct/indirect eval metadata, caller scope capture rules | Direct/indirect eval fixtures | validated |
| Expressions | expression parser | `frontend/parser.zig`, `bytecode/emitter.zig` | Operator precedence, short-circuit jumps, optional chaining lowering | Precedence and chain fixtures | validated |
| Statements | statement parser | `frontend/parser.zig`, `bytecode/emitter.zig` | Blocks, labels, loops, switch, try/catch/finally, with | Control-flow bytecode fixtures | validated |
| Functions | function parser | `frontend/parser.zig`, `bytecode/function.zig` | Parameters, defaults, rest, strictness, var scope, closure vars | Function/scope fixtures | validated |
| Arrow functions | arrow parser | `frontend/parser.zig`, `bytecode/function.zig` | Lexical `this`, parameter scope, expression/body forms | Arrow fixtures | validated |
| Async functions | async parser | `frontend/parser.zig`, `bytecode/function.zig` | Async function flags, await emission, promise integration metadata | Async parse/emission fixtures | validated |
| Generators | generator parser | `frontend/parser.zig`, `bytecode/function.zig` | Generator flags, yield/yield-star emission | Generator fixtures | validated |
| Async generators | async generator parser | `frontend/parser.zig`, `bytecode/function.zig` | Async generator flags, await/yield interactions | Async generator fixtures | validated |
| Classes | `js_parse_class` family | `frontend/parser.zig`, `bytecode/emitter.zig` | Constructor, methods, accessors, static elements, computed names, home object | Class accessor/method fixtures | validated |
| Private names | private field parser | `frontend/parser.zig`, `bytecode/scope.zig` | Private name scope, brand checks, private field ops | Private field fixtures | validated |
| Destructuring | destructuring parser/emitter | `frontend/parser.zig`, `bytecode/emitter.zig` | Object/array patterns, defaults, rest, nested targets | Destructuring fixtures | validated |
| Spread/rest | argument and literal emission | `frontend/parser.zig`, `bytecode/emitter.zig` | Spread calls, spread arrays/objects, rest params/properties | Spread/rest fixtures | validated |
| Imports/exports | module parser | `frontend/parser.zig`, `bytecode/module.zig` | Import entries, local/exported names, re-exports, namespace imports | Module metadata fixtures | validated |
| Dynamic import | import expression parser | `frontend/parser.zig`, `bytecode/emitter.zig` | `import` opcode emission and promise handoff metadata | Dynamic import fixture | validated |
| Error recovery boundary | syntax error creation | `frontend/parser.zig`, `core/exception.zig` | QuickJS-compatible parse errors and source locations | Negative syntax fixtures | validated |

## Phase 5 Exit Additions

- Every row must have at least one fixture or an explicit deferral recorded in
  `TRACKING.md`.
- Fixtures should inspect bytecode, metadata, and syntax errors. They should not
  run JavaScript through the VM as proof for this phase.
- Class, eval, module, async/generator, and destructuring rows cannot be marked
  `validated` without source comments pointing to the relevant QuickJS parser
  functions.
