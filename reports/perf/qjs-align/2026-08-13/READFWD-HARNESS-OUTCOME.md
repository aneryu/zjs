# READFWD-HARNESS outcome: NO-GO at the assembly gate

> **STATUS: CLOSED — NO-GO before PMU.**
>
> With the production-shaped AArch64 C ABI, A2 does remove the authoritative
> operand-stack payload load from the adjacent consumer. It does **not** retain
> the dependent float in an FP register: the producer adds `fmov x4, d0`, and
> the consumer uses `fmov dN, x4/x6`. The dependent value therefore crosses
> FP→GP→FP instead of only GP→FP after the memory load. This is the registered
> hard stop **“GP↔FP dependency chain longer”**. No PMU run is authorized.

This is an honest structural NO-GO, not a measured cycle regression. There are
no ABBA cycles/instructions numbers in this report because the experiment was
required to stop first. No Zoo value is estimated; this round explicitly
forbids Zoo pricing.

## 1. Unique answer

**No, not in the tested aggregate-`JSValue` handler ABI.**

- A1 has low register pressure, but the `mul -> load b -> add` shape evicts the
  dependent result. The following add still reloads the lhs from authoritative
  memory, so A1 does not remove the important two-pop edge.
- A2 preserves that result across the intervening load and avoids the consumer
  memory load. However, a 16-byte `JSValue` is carried in GP lanes. The emitted
  producer/consumer chain adds a serialized FP→GP move before the existing
  GP→FP move. Both isolated cold builds emit this shape.
- A2 has no stack argument, hot spill, frame growth, or broken tail dispatch.
  Those risks are clean; the forwarding carrier's register-domain chain is the
  fatal result.

The disassembly gate, not a source inference, makes this decision.

## 2. Provenance

```
task base zjs SHA    0710394f58ea123a3d8ff54b389aadb45065c6dc
worktree HEAD        673f3d41bf1961a38db12d2fbac3c914255aa246
engine source drift  none: src/ and build.zig* match task base
QuickJS SHA          04be246001599f5995fa2f2d8c91a0f198d3f34c
compiler             zig 0.16.0
CPU                  5, MIDR 0x410fd851, Cortex-X925, max 3900 MHz
PMU                  armv8_pmuv3_1
build mode           ReleaseFast
harness flags         -fomit-frame-pointer -fno-strip
parallelism          1 process, no flock
provided zjs hash    c0ad7c3e1650bbab33cc8e4022dddf1813630e9b55ad40528cde580aeac65f96
provided qjs hash    b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d
preflight zjs hash   bb4ad984f6726cd4ca8ba37431062d1e1b3cbc4c0aa8c283538fdf7b5f266d54
```

The worktree HEAD is a report-only descendant of the assigned base; the engine
and build sources are identical. The required production build was run before
any possible perf work and printed:

```
zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

Its cold-build hash differs from the provided archived zjs hash, so it is
recorded separately and was not substituted for that reference binary. The
standalone harness does not execute either engine binary for unit-cost claims.

### Isolated harness builds

| variant | build a SHA-256 | build b SHA-256 | byte-identical |
|---|---|---|---|
| baseline | `4a858eb5da2aa80c6cda52862d420d05e419a0781542639412932f76b6036c16` | `7964458cde5ee1b5d7c1084cbf4b1b1764cc8c922ad58fc13706a67a0f0c9f45` | no |
| A1 | `168f23cd2d87648dff472d21e5a851b2b27bf4d2b1ab599b2223338cac2da910` | `154828d81deac469e54877fc7af99c2028c619504a8a45daeca08d6c0ee00c92` | no |
| A2 | `568793e544c6ffa6192902493cfada55576c39bc2ea3a8e966d11b95e2ba707f` | `bef75623340cacbfc67034490f04fcefd32282f5741d8e593b1c424e34a5c158` | no |

Zig 0.16 cold-build bistability is present. The fatal lane/fmov result, ABI
placement, zero-frame hot shape, and 48-byte helper frames agree in both builds.

## 3. Harness contract and coverage

The standalone code uses the production four-argument handler base:

```
(pc, sp, locals, vm) callconv(.c)
```

A1 adds one 16-byte tagged `JSValue`; A2 adds two. Cache state is selected by
generic stack-depth dispatch tables. It is not selected by an opcode pair.
Covered traces have logical depth at most two, which is sufficient for the
approved two-pop experiment.

Every producer first writes the operand stack. Forwarding is only an additional
copy. The cold helper deliberately ignores carriers and reloads the
authoritative stack slot. There is no write-back, ownership/RC change, live
stack publication change, new opcode, fusion, profile specialization, or
production execution path.

All eight required workload classes execute in baseline/A1/A2 and match on
checksum and helper count in both cold builds:

```
fp_dep             fp_indep
int_dep            int_indep
empty_dispatch     two_pop
call_heavy         cold_helper
```

The smoke is functional evidence only. It is not used as performance evidence.

## 4. Assembly audit

### 4.1 ABI placement

| argument | register(s) |
|---|---|
| `pc`, `sp`, `locals`, `vm` | `x0`, `x1`, `x2`, `x3` |
| A1 `forward0` payload/tag | `x4`, `x5` |
| A2 `forward0` payload/tag | `x4`, `x5` |
| A2 `forward1` payload/tag | `x6`, `x7` |

A2 **does eat all `x0–x7`**. It does **not** put an argument on the native
stack. In the second load, the old top is explicitly shifted with:

```asm
mov x7, x5
mov x6, x4
ldp x4, x5, [x2, #64]
stp x4, x5, [x1], #16    // authoritative producer store
...
br  x8
```

This also proves the A2 dependent live range crosses the intervening load in
`x6/x7`; it is longer than A1's, but it does not spill.

### 4.2 Spill, frame, helper seam, musttail

| check | baseline | A1 | A2 |
|---|---:|---:|---:|
| hot-handler frame | 0 B | 0 B | 0 B |
| hot spill / native-stack reference | none | none | none |
| call-heavy frame | 48 B | 48 B | 48 B |
| cold/helper frame | 48 B | 48 B | 48 B |
| hot non-tail `bl` | 0 | 0 | 0 |
| terminal dispatch | `br` | `br` | `br` |

The helper workloads contain their intentional `bl helper*`; after restoring
the same 48-byte frame in every variant, they tail-dispatch with `br`. Thus
musttail lowering, spill, and frame-size gates all pass.

### 4.3 Fatal FP dependent edge

Both cold builds count the same `fmov` instructions in the float handler:

| variant | `fadd` `fmov` count |
|---|---:|
| baseline | 2 |
| A1 | 3 |
| A2 | 3 |

Relevant baseline chain:

```asm
fmov d0, x11              // lhs payload from authoritative memory
fmov d1, x9               // rhs payload from authoritative memory
fadd d0, d0, d1
stur d0, [x8, #-32]       // producer publishes authoritative payload
...
br   x4
// dependent consumer: GP payload load -> fmov dN, xN
```

Relevant A2 chain:

```asm
fmov d0, x6               // forwarded lhs
fmov d1, x4               // forwarded rhs
fadd d0, d0, d1
stur d0, [x1, #-32]       // authoritative store remains
fmov x4, d0               // new serialized FP -> GP carrier move
...
br   x8
// optional intervening load: mov x6, x4
// dependent consumer: fmov dN, x6
```

So A2 changes the dependent result edge from:

```
FP result -> store -> GP load -> GP-to-FP fmov -> FP consumer
```

to:

```
FP result -> FP-to-GP fmov -> GP-to-FP fmov -> FP consumer
```

The memory edge is gone, but the serialized cross-domain chain gains one move.
The task declares that exact shape a hard NO-GO; it is not permissible to run
independent throughput and use a possible win there to offset this failure.

### 4.4 Code size and layout

Relative to the same cold-build baseline:

| variant | full `.text` | `.rodata` | variant handler-symbol bytes |
|---|---:|---:|---:|
| A1 | +0.016% / +0.071% | +2,032 B (+4.05%) | +3.99% |
| A2 | +0.122% / +0.169% | +4,080 B (+8.14%) | +32.23% / +34.55% |

The full standalone binary's `.text` movement is small, but A2's local handler
island growth is substantial and the extra two state tables visibly move
layout. This is diagnostic only; it is not used to rescue or strengthen the
NO-GO.

## 5. Why PMU stopped

The preregistered order was machine-code hard gate first, then at least eight
even ABBA samples on CPU 5. The machine-code gate failed on both cold builds:

```
A2 stack argument                 false
hot handler spill/frame           false
handler frame growth              false
musttail dispatch failure         false
GP<->FP dependency chain longer   true   <- HARD STOP
```

Therefore:

- no cycles/instructions/stall counters were collected;
- no dependent/independent or empty-dispatch performance claim is made;
- no four-way cold-binary PMU combination exists to report;
- no Zoo traces are completed or estimated.

Stopping here follows the contract; continuing would repeat the historical
mistake of letting throughput evidence compensate for a structurally worse
dependent chain.

## 6. Difference from the frozen lean-monolithic experiment

The 2026-07-14 lean-monolithic direction changed dispatch/layout and made many
semantic arms green, but did not establish a new cross-handler value carrier;
its PMU result was a broad 4/4 regression. This experiment is narrower and
mechanistically different:

- memory stack remains authoritative and every producer still writes it;
- only an adjacent consumer receives an extra physical copy through the ABI;
- RC, publication, teardown, and production handlers remain unchanged;
- the failure is specifically the AArch64 aggregate carrier's FP→GP→FP chain,
  not semantic coverage or removal of the C/musttail boundary.

Likewise, this is not d12's complete operand pre-load. d12 moved memory reads
within the existing handler and empirically traded fewer instructions for a
longer dependent latency. READFWD instead removes the consumer memory load, but
the disassembly shows a new cross-domain dependency before PMU is even allowed.

## 7. Deliverables and change boundary

- harness: `tools/perf/readfwd_codegen/`
- full provenance and smoke results:
  `READFWD-HARNESS-artifacts/MANIFEST.json`
- machine audit: `READFWD-HARNESS-artifacts/MACHINE-AUDIT.json`
- both cold builds' targeted handler disassembly, symbol maps, and section maps:
  `READFWD-HARNESS-artifacts/{baseline,a1,a2}-{a,b}.*`

No existing report, doc, test262 ledger, test configuration, or production
engine source was modified. No git write operation was performed.
