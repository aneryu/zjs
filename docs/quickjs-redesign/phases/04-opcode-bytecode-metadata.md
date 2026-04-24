# Phase 4: Opcode And Bytecode Metadata

Status: not_started

## Goal

Port QuickJS opcode definitions and bytecode metadata before building the frontend
or VM. This phase locks opcode order, formats, stack metadata, bytecode ownership,
constant pools, scope records, module bytecode records, and debug/source tables.

## QuickJS References

- `quickjs/quickjs-opcode.h`
- `quickjs/quickjs.c` bytecode, function bytecode, closure variable, scope, and debug metadata sections.

## Target Files

- `src/engine/bytecode/opcode.zig`
- `src/engine/bytecode/format.zig`
- `src/engine/bytecode/function.zig`
- `src/engine/bytecode/constant.zig`
- `src/engine/bytecode/scope.zig`
- `src/engine/bytecode/module.zig`
- `src/engine/bytecode/debug.zig`
- `src/tests/bytecode/all.zig`

## Coverage Matrix

Opcode metadata and later execution tracking share
`../matrices/opcode-execution-matrix.md`. Phase 4 owns metadata columns and
Phase 6 owns execution-handler columns.

## Work Breakdown

- [ ] Generate or manually port opcode enum in QuickJS order.
- [ ] Port opcode names, formats, immediate operands, and stack effects.
- [ ] Add tests for representative numeric opcode values and every opcode count.
- [ ] Define bytecode buffer ownership and release APIs.
- [ ] Define constant pool storage and value lifetime rules.
- [ ] Define local variable, closure variable, and lexical scope metadata.
- [ ] Define compiled module request/import/export metadata.
- [ ] Define source position and debug table ownership.
- [ ] Add serialization helpers only if required by later phases; do not implement `qjsc`.

## Validation

```bash
zig fmt .
zig build test --summary all
```

Focused tests should cover:

- Opcode order and count against `quickjs/quickjs-opcode.h`.
- Format metadata and immediate operand decoding.
- Stack effect metadata for representative opcodes.
- Function bytecode allocation and teardown.
- Module and debug metadata ownership.

## Exit Checklist

- [ ] Opcode table matches QuickJS.
- [ ] Opcode metadata rows in `../matrices/opcode-execution-matrix.md` are ready for Phase 6 handler tracking.
- [ ] Bytecode structures are owned and freed deterministically.
- [ ] `status.zig` marks opcode and bytecode metadata as `validated`.
- [ ] `TRACKING.md` records validation evidence and any generation strategy.

## Handoff Notes

Record whether opcode metadata is generated or hand-maintained.
