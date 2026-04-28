# Parser Deviation Matrix

This matrix tracks all deviations from the strong-alignment contract in §1.5 of
PARSER_REWRITE_PLAN.md. Every deviation must have an expiry date and a clear
retirement plan.

## Format

| ID | Component | Deviation Description | QuickJS Reference | Expiry Date | Retirement Plan |
|---|---|---|---|---|---|
| D1 | Value.payload | Added `ptr: ?*anyopaque` variant for temporary FunctionBytecode storage before GC integration | N/A - QuickJS does not have this variant | 2026-05-29 (30 days) | Integrate FunctionBytecode into GC system with proper ref counting; remove ptr variant |
| D2 | FunctionBytecode allocation strategy | Uses flat per-field MemoryAccount.alloc layout instead of single contiguous allocation. **Field order has been corrected** in 2026-04-29 to match `quickjs.c:768-804` exactly (M0.1 sub-task complete). The flat allocation strategy itself remains as a deviation pending evaluation of whether contiguous allocation is required for GC-walking or whether the flat layout is acceptable post-GC integration. | `quickjs.c:768-804`, `js_create_function:35499-35550` | 2026-05-29 (30 days) | After D1 retires (FunctionBytecode in GC), profile both layouts; switch to single contiguous allocation only if walker-throughput regresses. Otherwise document the flat layout as a permanent decision and retire D2. |

## Statistics

- Active deviations: 2 (D1 fully active; D2 partially mitigated — field order matches QuickJS, allocation strategy still differs)
- Expired deviations: 0
- Retired deviations: 0

## Last Updated

2026-04-29 — Matrix created for M0.1 (initial). D2 field order verified to match `quickjs.c:768-804` field-by-field after the FunctionBytecode header layout was rewritten in `src/engine/bytecode/function.zig:120-185`. Flat per-field MemoryAccount.alloc layout remains pending the D1 GC integration decision.