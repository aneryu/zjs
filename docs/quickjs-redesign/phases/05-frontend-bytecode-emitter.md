# Phase 5: Frontend And Bytecode Emitter

Status: not_started

## Goal

Port QuickJS frontend behavior and emit bytecode directly. This phase must not
recreate the old AST interpreter or any standalone execution path.

## QuickJS References

- `quickjs/quickjs.c` lexer, parser, scope, function parsing, class parsing, destructuring, eval, module, and bytecode emission sections.
- `quickjs/quickjs-opcode.h` for emitted opcode validation.

## Target Files

- `src/engine/frontend/token.zig`
- `src/engine/frontend/lexer.zig`
- `src/engine/frontend/parser.zig`
- `src/engine/frontend/regexp_literal.zig`
- `src/engine/frontend/source_pos.zig`
- `src/engine/bytecode/emitter.zig`
- `src/engine/bytecode/scope.zig`
- `src/engine/bytecode/function.zig`
- `src/engine/bytecode/module.zig`
- `src/tests/frontend/all.zig`
- `src/tests/bytecode/all.zig`

## Coverage Matrix

Detailed syntax-domain tracking lives in
`../matrices/frontend-coverage-matrix.md`. Update matrix rows with fixture paths
and emitted metadata/opcode evidence as features land.

## Work Breakdown

- [ ] Port token definitions, keyword handling, private names, and strict/module context flags.
- [ ] Port numeric, string, template, and regexp literal lexing.
- [ ] Port script, module, function, eval, async, and generator parse entrypoints.
- [ ] Port lexical scope and variable binding rules.
- [ ] Port closure capture metadata and eval-specific binding metadata.
- [ ] Port class parsing, method/accessor parsing, private fields, `super`, and home-object metadata.
- [ ] Port destructuring, default/rest/spread, and short-circuit expression emission.
- [ ] Port import/export parsing and compiled module metadata emission.
- [ ] Emit QuickJS-aligned bytecode through `bytecode/emitter.zig`.
- [ ] Add parser/emitter fixtures that inspect bytecode and metadata without running the VM.

## Validation

```bash
zig fmt .
zig build test --summary all
```

Focused fixtures should cover:

- Script vs module parse mode.
- Direct vs indirect eval metadata.
- Function and closure capture metadata.
- Class methods, accessors, private names, static elements, and computed names.
- Destructuring and spread/rest/default emission.
- Import/export records.
- Syntax error reporting with source positions.

## Exit Checklist

- [ ] Parser/emitter tests pass without AST execution.
- [ ] All non-deferred rows in `../matrices/frontend-coverage-matrix.md` are `validated`.
- [ ] Bytecode output uses opcode metadata from Phase 4.
- [ ] Source position and syntax error metadata are tested.
- [ ] `status.zig` marks frontend and emitter subsystems as `validated`.
- [ ] `TRACKING.md` records validation evidence and known unexecuted bytecode coverage gaps.

## Handoff Notes

Record any syntax forms that parse but still need VM execution coverage in Phase 6.
