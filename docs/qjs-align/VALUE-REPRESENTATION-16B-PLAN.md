# 64-bit default 16B JSValue alignment and optimization plan

## Decision

On pointer-width >= 64, zjs defaults to the 16-byte QuickJS representation:

```text
payload: u64
tag:     i64
```

On narrower targets it defaults to 8-byte NaN-boxing, matching QuickJS's
`JS_PTR64` / `JS_NAN_BOXING` split. `-Dzjs_nan_boxing` remains an explicit
override. `@alignOf(JSValue)` remains 8 bytes: QuickJS's 16-byte struct has
8-byte C alignment; this work aligns the representation policy, not the
allocation alignment.

The plugin descriptor already fingerprints JSValue size, alignment, encoding
revision, field offsets, and field widths. Plugins compiled for the former
64-bit default fail closed with `JSValueLayoutMismatch` and must be rebuilt.

## Invariants

- QuickJS tag numbers and the 16-byte field layout remain exact.
- The 16-byte short BigInt payload remains the full signed i64 range.
- The 8-byte adapter remains supported and continuously tested.
- Representation knowledge stays inside the `JSValue` module; hot callers use
  semantic operations rather than field access.
- No wall-clock threshold becomes a semantic CI test.
- Performance changes must preserve bytecode results and ownership behavior.

## Baseline and feedback loop

Host: aarch64, fixed CPU 19, ReleaseFast, twenty sequential `perf stat` runs of
`tests/perf/qjs-align/lexical-local-control-5m.js`.

| representation | instructions | cycles | backend stalls | L1D misses |
|---|---:|---:|---:|---:|
| 8B | 1,754,406,662 | 257,524,139 | 54,081,074 | 26,130 |
| 16B | 1,574,452,271 | 286,442,915 | 112,279,410 | 27,126 |

The 16-byte build executes about 10.3% fewer instructions but consumes about
11.2% more cycles, with 2.08x backend stalls and only 3.8% more L1D misses.
Therefore cache capacity is not the first optimization target. The first target
is the store/load dependency chain created by copying 16-byte values between
locals and the operand stack.

Sampling attributes about 38% of 16-byte backend stalls to checked local
get/put handlers, about 23% to the integer binary handlers, then comparison and
branch handlers. Every accepted slice is remeasured with the same binary pair,
script, CPU, events, and repetition count.

## Ranked hypotheses

1. Rewriting an unchanged tag on every int32 update lengthens the store/load
   dependency chain. A representation-owned same-tag update should remove tag
   stores in 16B mode without regressing the 8B adapter.
2. Materializing values by value at the `JSValue` interface causes aggregate
   spill/reload. Slot-shaped decoding is accepted only if disassembly and
   backend-stall counts improve; LLVM already scalarizes several handlers.
3. Full local-to-stack-to-local copies dominate checked lexical loops. A
   semantics-preserving existing peephole or typed fast handler may remove a
   round trip, but a new speculative opcode seam is rejected unless multiple
   workloads justify it.
4. The 280-byte call `Entry` stride hurts call-heavy workloads, but it cannot
   explain the no-call loop regression. It is measured separately and not mixed
   into the value-representation slice.
5. Dense 16-byte element storage raises RSS. Any future compact dense-array
   adapter must be local to the array module; it must not change canonical
   JSValue back to 8 bytes.

## Execution stages

### Stage 0 — establish evidence

- Build explicit 8B and 16B binaries from the same commit.
- Verify deterministic output.
- Record instructions, cycles, backend stalls, L1D misses, binary size, and
  stalled-cycle samples.
- Inspect generated code for checked local, binary, compare, and update ops.

Exit: a reproducible root cause, not a wall-clock-only observation.

### Stage 1 — target policy and contracts

- Make the build default target-aware: 64-bit 16B, narrower 8B.
- Make `test-altrepr` choose the opposite of the target default.
- Update active architecture and contributor documentation.
- Keep the explicit option name stable.
- Verify default plugin fixtures rebuild with the 16B fingerprint and stale
  layouts remain rejected.

Exit: default and alternate builds compile; focused core tests pass in both.

### Stage 2 — deepen the JSValue module

- Add an int32 same-tag mutation operation with an explicit precondition.
- In 16B mode, update only payload; in 8B mode, retain the established packed
  constructor code path.
- Use it only where the handler has already proved the destination is int32 and
  the result cannot change tag: non-overflow integer binary ops, inc/dec, and
  fused local inc/dec.
- Add interface-level tests in the core suite before changing call sites.

Exit: both representations pass; 16B disassembly loses redundant tag stores;
8B disassembly does not regress materially.

### Stage 3 — evaluate slot traffic

- Test slot-shaped pair decoding against the current by-value interface.
- Test same-int local replacement only where ownership and tag stability are
  already proven.
- Compare checked lexical, plain local, mixed-number, and call-heavy controls.
- Revert any experiment that merely moves instructions or regresses the 8B
  adapter without a 16B cycles/stall win.

Exit: keep only falsified-or-measured conclusions and proven improvements.

### Stage 4 — representation parity gates

- `zig build test-core --summary all`
- `zig build test-core -Dzjs_nan_boxing=true --summary all`
- `zig build test-exec --summary all`
- `zig build quick-check --summary all`
- `zig build test-altrepr --summary all`
- relevant test262 smoke/slice in both representations
- `zig build checkpoint-check --summary all`
- one final `zig build test -Doptimize=ReleaseSafe --summary all`
- `git diff --check`

At stage close, refresh the checked zjs self baseline only after semantic gates
pass, because the intentional default representation changed.

## Execution results

Stages 0–3 are complete. The accepted implementation has two deliberately
representation-owned fast paths:

- `setInt32AssumeInt` preserves an already-proven int tag. The 16B adapter
  writes only the payload; the packed adapter keeps its original whole-value
  store.
- `trySetInt32FromSlot` lets the 16B checked-local handler replace int with int
  by moving only the payload. Every other tag pair immediately uses the
  original ownership-aware replacement. The 8B handler remains a separate
  generic instantiation because adding even a dead pointer-shaped branch moved
  its code layout and cost about 2% in the control loop.

Twenty-run medians on the same fixed CPU and workload:

| build | instructions | cycles | backend stalls | cycles vs initial 16B |
|---|---:|---:|---:|---:|
| initial 8B | 1,754,406,662 | 257,524,139 | 54,081,074 | -10.1% |
| initial 16B | 1,574,452,271 | 286,442,915 | 112,279,410 | baseline |
| optimized 16B | 1,494,441,565 | 259,445,009 | 88,162,485 | -9.4% |

The optimized 16B build removes 5.1% instructions, 9.4% cycles, and 21.5%
backend stalls from the initial 16B build. In the final interleaved control it
was effectively at parity with the immediately repeated 8B binary
(259.45M versus 259.62M cycles). Disassembly confirms that `op_update_loc`
lost the redundant tag store and the wide checked-local int leg uses a
payload-only load/store without the generic refcount stack frame.

The checked-local non-int miss control remained stable: the string workload
moved from 337.13M to 335.71M cycles and from 150.20M to 145.94M backend stalls,
despite the required int-pair guard. This protects the ownership fallback from
being optimized only for the benchmark's int case.

The experiments also falsified three tempting explanations:

- L1D misses rose only 3.8% in the initial 16B comparison, so cache capacity
  was not the first-order no-call-loop regression.
- LLVM already scalarized the existing by-value int-pair decoder into general
  registers; a new pointer-shaped public decoder added no useful seam.
- The 280-byte 16B call `Entry` cannot explain a workload with no calls, so call
  layout remains a separately measured future slice.

Stage 4 completed with both representations live:

- focused core tests: 230/230 in default 16B and explicit 8B;
- focused exec tests: 217/217 in both representations;
- `quick-check`: 3/3; `test-altrepr`: 1432/1432 in 8B;
- test262 smoke: 12/12 in both representations;
- full test262 gate: 49,775 prepared tests and zero new errors in each
  representation (44,599 passed, two known failures);
- `checkpoint-check`: 32/32 build steps and 1432/1432 unified Debug tests;
- final ReleaseSafe suite: 1432/1432;
- refreshed 16B self baseline and its repeat check: 75/75 compatible cases,
  zero unsupported, skipped, or validation failures.

## Acceptance

- A default 64-bit build reports `@sizeOf(JSValue) == 16`.
- An explicit NaN-boxed build reports 8 bytes and passes the same semantics.
- `test-altrepr` runs the 8-byte adapter on the 64-bit host.
- Plugin ABI mismatch remains deterministic.
- The accepted hot-path slice removes its targeted redundant 16B stores and
  does not increase cycles/backend stalls outside run-to-run noise.
- Any residual performance gap is reported with evidence; it is not hidden by
  restoring 8B as the canonical representation.

## Non-goals

- Forcing `align(16)` on JSValue.
- Removing NaN-boxing support.
- Compressing every array/property slot in this slice.
- Adding hardware-dependent timing assertions to unit tests.
- Reintroducing retired global opcode-fusion machinery without new evidence.
