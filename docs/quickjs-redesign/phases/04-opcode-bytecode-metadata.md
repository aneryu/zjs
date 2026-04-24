# Phase 4: Opcode And Bytecode Metadata

Status: completed

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

- [x] Generate or manually port opcode enum in QuickJS order.
- [x] Port opcode names, formats, immediate operands, and stack effects.
- [x] Add tests for representative numeric opcode values and every opcode count.
- [x] Define bytecode buffer ownership and release APIs.
- [x] Define constant pool storage and value lifetime rules.
- [x] Define local variable, closure variable, and lexical scope metadata.
- [x] Define compiled module request/import/export metadata.
- [x] Define source position and debug table ownership.
- [x] Add serialization helpers only if required by later phases; do not implement `qjsc`.

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

- [x] Opcode table matches QuickJS.
- [x] Opcode metadata rows in `../matrices/opcode-execution-matrix.md` are ready for Phase 6 handler tracking.
- [x] Bytecode structures are owned and freed deterministically.
- [x] `status.zig` marks opcode and bytecode metadata as `validated`.
- [x] `TRACKING.md` records validation evidence and any generation strategy.

## Handoff Notes

Opcode metadata is generated at test/build time by parsing the local
`quickjs/quickjs-opcode.h` with `src/engine/bytecode/opcode.zig`; the Zig tree
does not maintain a duplicated opcode table.
