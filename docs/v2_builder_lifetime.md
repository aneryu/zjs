# compiler-v2 resource lifetime timeline (QCP-1 Stabilization-2, stage C2-A)

Diagnosis only. Nothing in this stage changes lowering, ownership, or release
order; this document records **when each compile-time resource is created,
consumed, transferred, and released**, and names every interval in which two
owners hold the same logical bytes at the same time.

The model this document is written against:

> a producer creates temporary ownership; a consumer consumes the result;
> commit transfers ownership; after the transfer the old owner is inert.
> **One owner at every point in the lifetime.**

Every deviation below is stated as *"the old owner does not become inert at
T4"*, never as *"X should own it forever"*. The release point named at the end
is therefore a **consumption point**, so it survives a later Emitter-interface
stage that relocates builder ownership into a `V2Emitter`.

---

## 1. How this was measured

Diagnostic accounting (`allocated_bytes`, `allocation_count`,
`peak_allocated_bytes`, `peak_allocation_count`, `alloc_calls`, `create_calls`)
is comptime-gated on `builtin.is_test or builtin.mode == .Debug`
(`src/core/memory.zig:5`). A ReleaseFast `--perf-json` run reports these as 0,
which is why every number here comes from a **Debug** build.

Two Debug binaries were built from this worktree at branch tip `c7f998b8`:

```
zig build zjs-dev -Dzjs_compiler=v2        # v2 pipeline
zig build zjs-dev -Dzjs_compiler=legacy    # legacy Phase 1/2/3 pipeline
```

A scratch probe (added, measured, then reverted — it is deliberately **not**
part of this commit) printed, at fixed pipeline boundaries and gated on
`ZJS_LIFETIME=1`:

* `MemoryAccount` live bytes / live allocations / running peaks, and
* a **census of the whole `FunctionDef` tree**: for every node, the bytes and
  allocation count held by (a) its `v2_builder` backings, (b) its legacy
  phase-1 buffers, (c) its shared metadata buffers, split by whether that node
  has already been lowered (`finalization_state == .resolved`).

Probe points, in pipeline order:

| tag | site |
| --- | --- |
| `T0_parse_end` | entry of `pipeline_finalize.createFunctionBytecode` (`src/bytecode.zig:12551`), i.e. parse complete, nothing lowered |
| `T2_lower_enter` | entry of `createFunctionBytecodeAfterChildren` (`src/bytecode.zig:12712`) |
| `T2a_s3_done` | after `resolve_variables.run` returns (`src/compiler_v2/root.zig:59`) |
| `s4_peak` | after `Resolver.commit()`, before `defer resolver.deinit()` (`src/compiler_v2/resolve_labels.zig:2736` / `:2730`) |
| `T3a_s4_done` | after `resolve_labels.run` returns (`src/compiler_v2/root.zig:64`) |
| `T3b_product_freed` | after `compileFunctionV2` returns, i.e. after `defer product.deinitUncommitted()` (`src/compiler_v2/root.zig:60`) |
| `T4_lower_exit` | after `createFunctionBytecodeAfterChildren` returns, i.e. after `defer lowered.deinit(rt)` |
| `T5_finalize_end` | whole tree finalized |

Sources compiled:

* `c2a-nested.js` — a 3-deep nested-function tree (root + `outer` + `middle` +
  `inner`), used for the readable per-function timeline.
* `mc1.js` — the vendored Octane `code-load` payload (Closure `base.js` +
  jQuery 1.7.2, evaluated once each). The jQuery eval is a **535-FunctionDef
  tree** and is the case S6 measured for gate C2.

The probe is measurement-neutral: a clean (unpatched) v2 Debug binary produces
byte-identical `--perf-json` counters to the instrumented one.

### C2 headline, reproduced

`--perf-json`, `mc1.js`, Debug, same tree, same source:

| counter | legacy | v2 | ratio | C2 requirement |
| --- | --- | --- | --- | --- |
| `allocated_bytes_peak` | 2,683,991 | 3,273,217 | **1.2196x** | < 0.7x |
| `allocation_count_peak` | 6,204 | 9,007 | **1.4518x** | < 0.7x |
| `alloc_calls` | 34,750 | 47,168 | 1.3573x | — |
| `create_calls` | 1,775 | 2,371 | 1.3358x | — |
| `free_calls` | 34,325 | 46,743 | — | — |
| `allocated_bytes` (end) | 385,425 | 385,425 | 1.0000x | — |

Peak bytes and peak live allocations match S6's C2 measurement exactly
(1.22x / 1.45x). `alloc_calls` here is 47,168 rather than the 42,665 S6
recorded; S6's worktree no longer exists, so that one counter could not be
re-derived from the same tree state. It does not affect the C2 verdict, which
is driven by the two peak counters.

The end-of-run resident bytes are **identical** (385,425 on both). This is not
a leak. It is a *peak* and *lifetime* problem.

---

## 2. Resource inventory: T0 → T4 per resource

`fd` = the `FunctionDef` being lowered. "does not become inert" is marked
**NOT INERT**.

### 2.1 The `Builder` object itself

| row | value |
| --- | --- |
| T0 created by / owner | `State.v2EnsureBuilderForFd` (`src/parser.zig:7097`) does `fd.memory.create(compiler_v2.Builder)` and stores it in `fd.v2_builder`. Called from `pushFunction` (`src/parser.zig:4505`) for every nested function and from `beginV2ProgramEmission` (`:7118`) for the root. Owner: **`fd`**. |
| T1 buffers acquired | see 2.2–2.6; all five backings hang off this object. |
| T2 consumed by | `resolve_variables.run` (`src/compiler_v2/resolve_variables.zig:1987`), which reads it via `fd.v2_builder orelse …` (`:1991`) and keeps it as `Resolver.input` for the whole pass. In **dual** mode there is one later read: the ledger block in `compileFunctionV2` (`src/compiler_v2/root.zig:66-81`) walks `input.label_slots[0..input.label_len]` and reads `input.source_len`. Nothing after that reads it. |
| T3 ownership transferred to | nothing. The consumer builds a *fresh* `ResolvedProduct`; no buffer is moved out of the Builder. |
| T4 old owner becomes inert | **NOT INERT.** `fd.v2_builder` is still non-null and fully populated. It is released only in `FunctionDef.deinit` (`src/bytecode.zig:3576-3581`), which runs after the *entire* compile — after every sibling, every ancestor, and the packed root `FunctionBytecode` are done. |

Measured `@sizeOf(Builder)` = 168 B; 535 of them = 89,880 B of object headers
alone on the jQuery tree.

### 2.2 Temporary code stream — `Builder.code` / `code_capacity`

| row | value |
| --- | --- |
| T0 | `Builder.init` (`src/compiler_v2/builder.zig:135`), empty. |
| T1 | grown by `reserve(u8, …)` (`src/compiler_v2/builder.zig:71`) on every `emit*`; doubling, min 32. Slice length always spans the full allocation. |
| T2 | read-only input to `resolve_variables.run`; last read is the resolver walk inside that pass (`Resolver.code = input.code[0..input.code_len]`, `resolve_variables.zig:2017`). |
| T3 | **no transfer.** `ResolvedProduct.code` is a separately allocated, dead-stripped copy. |
| T4 | **NOT INERT** — freed only by `Builder.deinit` (`builder.zig:141-146`) from `FunctionDef.deinit`. |

jQuery tree: 535 streams, worst single `code_capacity` = 16,384 B.

### 2.3 Atom ledger — `Builder.atom_operands` / `atom_capacity`

| row | value |
| --- | --- |
| T0 | `Builder.init`, empty. |
| T1 | grown by `reserve(Atom, …)`; every appended atom is **retained** (owned) by the ledger. |
| T2 | read by `resolve_variables.run` (`Resolver.atom_ledger`, `resolve_variables.zig:2018`), which **re-retains** each surviving atom into `ResolvedProduct.atom_operands`. Refs are duplicated, not moved. |
| T3 | **no transfer** — the product holds its own independent refs. |
| T4 | **NOT INERT** — item-wise released only in `Builder.deinit` (`builder.zig:142`). Every atom used by a v2-compiled function therefore carries one extra refcount for the whole compile. |

Worst single `atom_capacity` on the jQuery tree = 8,192 B (2,048 atoms).

### 2.4 Label slots — `Builder.label_slots` / `label_capacity`

| row | value |
| --- | --- |
| T0 | first `Builder.newLabel` (`builder.zig:168`). |
| T1 | `reserve(LabelSlot, …)`, doubling, min 8. `@sizeOf(LabelSlot)` = 16 B. |
| T2 | `resolve_variables.run` copies them into `ResolvedProduct.label_slots` via `initializeLabels` (`resolve_variables.zig:2009`); the product then owns the authoritative bound offsets/ref counts. In dual mode the *input* array is re-walked once more for `labels_unbound` (`root.zig:70`). |
| T3 | **no transfer** — the product array is a fresh allocation. |
| T4 | **NOT INERT** — freed in `Builder.deinit`. |

### 2.5 Reloc entries — `Builder.relocs` / `reloc_capacity`

| row | value |
| --- | --- |
| T0 | first `Builder.emitJump` (`builder.zig:189`). |
| T1 | `reserve(RelocEntry, …)`, doubling, min 8. `@sizeOf(RelocEntry)` = 12 B. |
| T2 | `cfg.build` (`src/compiler_v2/cfg.zig:641`) sizes the edge storage from `input.reloc_len` and the resolver reads the chain during the walk. **`resolve_labels_v2` builds its own chains and never reads this array** (`ResolvedProduct` has no reloc field — see `resolve_variables.zig:51-52`). |
| T3 | **no transfer.** |
| T4 | **NOT INERT** — freed in `Builder.deinit`. This is the one Builder backing that is provably dead the moment `resolve_variables.run` returns, and it is still held for the whole compile. Worst single `reloc_capacity` on the jQuery tree = 768 B. |

### 2.6 Source slots — `Builder.source_slots` / `source_capacity`

| row | value |
| --- | --- |
| T0 | first `Builder.addSourceMarker`. |
| T1 | `reserve(SourceSlot, …)`; `@sizeOf(SourceSlot)` = 12 B (`builder.zig:37-42`). |
| T2 | read by `resolve_variables.run` (`Resolver.input_sources`), which writes output-offset copies into `ResolvedProduct.source_slots`. Dual mode re-reads `input.source_len` (`root.zig:78`). |
| T3 | **no transfer.** |
| T4 | **NOT INERT** — freed in `Builder.deinit`. This is the **largest** Builder backing in practice: on the jQuery tree the worst single `source_capacity` is 24,576 B, larger than that function's code stream (16,384 B) and 3.1x its final executable code (7,945 B). |

### 2.7 `ResolvedProduct` (the S3 output)

| row | value |
| --- | --- |
| T0 | constructed in `resolve_variables.run` (`resolve_variables.zig:2007`), owner = the local `product` in `compileFunctionV2` (`root.zig:59`). |
| T1 | `code` / `atom_operands` / `label_slots` / `source_slots`, each with its own doubling `reserve`. |
| T2 | consumed by `resolve_labels.run` (`resolve_labels.zig:2706`), whose `Resolver` reads `product.code`, `product.atom_operands`, `product.source_slots` and mutates `product.label_slots` in place. Last read is `Resolver.walk`/`relaxJumps`/`validateFinalOutput`. |
| T3 | **no transfer.** `Resolver.commit` (`resolve_labels.zig:2664`) installs *newly allocated exact copies* on the lowering carrier. |
| T4 | **INERT, correctly.** `defer product.deinitUncommitted()` (`root.zig:60`) releases it at the end of `compileFunctionV2`. Measured exactly: live bytes drop by the product's full size at `T3b_product_freed`. |

This is the model the Builder should follow — a bounded producer/consumer
lifetime with a release at the consumption point.

### 2.8 `resolve_labels` output + scratch

| row | value |
| --- | --- |
| T0 | `Resolver` literal in `resolve_labels.run` (`:2720`); `initScratch` (`:462`) allocates `addr` (4 B/label), `binds` (sorted `BindEntry`), `jump_slots`. `output` / `output_atoms` / `output_sources` / `relocs` grow during `walk`. |
| T1 | growable, doubling. |
| T2 | consumed by `Resolver.commit` (`:2664`), which makes exact-size copies of `output`, `output_atoms`, `output_sources`. |
| T3 | ownership of the *exact copies* transfers to the lowering carrier via `installCode` (`src/bytecode.zig:13769`), `installAtomOperands` (`:13802`) and `installSourceLocsNoFail`. Atom refs are moved (the growable ledger is freed without releasing them, `:2687-2691`). |
| T4 | **INERT, correctly.** `defer resolver.deinit()` (`:2730`) frees the growable backings and all scratch. Measured exactly: live bytes drop by the scratch total between `s4_peak` and `T3a_s4_done`. |

### 2.9 `resolve_variables` scratch topology (not in the ruling's list, but real)

`buildBindIndex` (`resolve_variables.zig:1997`) and `cfg.build`
(`:2000` → `cfg.zig:641`, allocating `block_starts`, `blocks`, `edge_storage`,
`reachable_words`) plus `Resolver.pending_tail_rewrites` / `opt_boundaries`
are all created inside `resolve_variables.run` and released by its own `defer`s
before it returns. **Correctly inert**, but they are alive *simultaneously with
the Builder and the growing product* — see interval D5.

### 2.10 `FunctionBytecode` buffers

| row | value |
| --- | --- |
| T0 | the exact copies produced by `Resolver.commit`, installed on the `lowered` carrier (`bytecode_function.Bytecode`) created in `createFunctionBytecodeAfterChildren` (`src/bytecode.zig:12712`). |
| T1 | `publishLoweredMetadata` additionally generates the pc2line buffer. |
| T2 | consumed by the packed-FB build: `FunctionLayout.init` + `FunctionBytecode.createProductionShell` (`src/bytecode.zig:2225`) copy code into FAM storage; source/pc2line move as independent owners. |
| T3 | ownership transferred to the packed `FunctionBytecode`, installed into the parent's cpool (`installChildFunctionBytecodes`, `src/bytecode.zig:13170`). |
| T4 | **INERT, correctly.** `defer lowered.deinit(rt)` frees whatever the carrier still owns. |

### 2.11 Legacy comparison: the same rows for phase-1 buffers

`lowerLegacyPhase1` (`src/bytecode.zig:12683`) **moves** `fd.byte_code`,
`fd.atom_operands`, `fd.source_loc_slots` into the `lowered` carrier and nulls
the FunctionDef's fields. Legacy's T3 is a real transfer, and its T4 is real
inertness: the phase-1 buffers of a function are gone the moment that function
finishes lowering. That is the entire structural difference measured in §4.

---

## 3. One function, with numbers

### 3.1 Readable case — `c2a-nested.js` (root + `outer` + `middle` + `inner`)

Post-order lowering: `inner`, `middle`, `outer`, root. Bytes are backing
capacities, i.e. what the allocator actually holds.

| function | Builder total (2.1–2.6) | ResolvedProduct | resolve_labels scratch | final committed (code+atoms+src) |
| --- | ---: | ---: | ---: | ---: |
| `inner` | 1,096 | 640 | 436 | 243 |
| `middle` | 328 | 128 | 128 | 81 |
| `outer` | 328 | 128 | 128 | 81 |
| root | 456 | 256 | 160 | 105 |
| **total** | **2,208** | 1,152 | 852 | **510** |

At `T0_parse_end`: `fds=4/0`, builder census 2,208 B / 18 allocations.
At `T5_finalize_end`: `fds=4/4`, builder census **still 2,208 B / 18
allocations**, and the census's "already lowered" split is **2,208 / 2,208
(100%)**.

Same fixture, legacy: phase-1 census 1,440 B / 12 allocations at
`T0_parse_end`, **0 B / 0 allocations** at `T5_finalize_end`.

### 3.2 Worst real function — the jQuery body (`mc1.js`, the 532nd of 535 functions lowered)

Its final executable code is **7,945 bytes**. Measured live-byte deltas across
its lowering (all figures exact, from consecutive probe points):

| instant | live bytes | what is alive for *this* function |
| --- | ---: | --- |
| `T2_lower_enter` | 3,165,758 | Builder 51,112 (code 16,384 + atoms 8,192 + labels 1,024 + relocs 768 + sources 24,576 + object 168) |
| `T2a_s3_done` | 3,203,150 | **+ ResolvedProduct 37,392** (code 8,192, atoms 4,096, labels 528, sources 24,576) |
| in-pass peak of `resolve_variables.run` | 3,222,188 | + CFG graph / bind index / resolver pending arrays ≈ **19,038** (peak minus end-of-pass live) |
| `s4_peak` (after `commit`, before `resolver.deinit`) | 3,263,227 | **+ resolve_labels scratch 34,708** (output 8,192, output sources 24,576, relocs 768, addr 132, binds 384, jump slots 656) **+ committed exact buffers 25,369** (code 7,945, atoms 3,324, source locs 14,100) |
| `T3a_s4_done` | 3,228,519 | scratch released (−34,708 exactly) |
| `T3b_product_freed` | 3,191,127 | product released (−37,392 exactly) |
| `T4_lower_exit` | 3,184,059 | carrier released; **Builder 51,112 still alive** |

At `s4_peak` **four full materializations of the same instruction stream are
alive simultaneously**: 51,112 + 37,392 + 34,708 + 25,369 = **148,581 bytes**
for a function whose published code is 7,945 bytes — **18.7x**.

The global peak, `allocated_bytes_peak = 3,273,217`, is reached in the window
between `T3b_product_freed` and `T4_lower_exit` for this same function (pc2line
generation + `createProductionShell` + metadata validation, a transient of
**+89,158 B** above the post-state).

---

## 4. Whole-tree behaviour: the census drains in legacy, never in v2

jQuery eval, 535 `FunctionDef`s, sampled at `T4_lower_exit`:

| functions lowered | v2 Builder census (B) | of which already published | legacy phase-1 census (B) | v2 live | legacy live |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 (`T0_parse_end`) | 896,968 | 0 | 819,408 | 2,882,631 | 2,660,488 |
| 1 | 896,968 | 968 | 818,704 | 2,883,168 | 2,660,293 |
| 134 | 896,968 | 211,072 | 624,816 | 2,954,242 | 2,530,255 |
| 268 | 896,968 | 434,000 | 418,256 | 3,029,971 | 2,391,635 |
| 401 | 896,968 | 601,576 | 272,304 | 3,090,139 | 2,299,907 |
| 534 | 896,968 | 896,224 | 704 | 3,184,518 | 2,113,146 |
| 535 (`T5_finalize_end`) | **896,968** | **896,968 (100%)** | **0** | 3,184,590 | 2,112,497 |

Allocation counts follow the same shape: v2 holds **2,818** live Builder
allocations at every point from `T0_parse_end` to `T5_finalize_end`; legacy
drains 1,597 phase-1 allocations to 0.

Consequences, both measured:

* **Live bytes move in opposite directions during finalize.** v2 *rises*
  +301,959 B from `T0_parse_end` to `T5_finalize_end`; legacy *falls*
  −547,991 B.
* **The peak instant moves to the wrong end of the walk.** Legacy's peak
  (2,683,991) is hit at function **9 of 535**, where the pending census is
  still 806,672 B but the in-flight function is a small leaf. v2's peak
  (3,273,217) is hit at the **532nd function of 535**, because the census never
  shrinks, so the largest function's transients (§3.2) land on top of a census
  that still holds **844,376 B belonging to functions that were already
  published**.

At the exact global-peak instant, **844,376 of 3,273,217 live bytes (25.8%)
and 2,801 of 9,005 live allocations (31.1%) are temporary compiler input for
functions whose executable `FunctionBytecode` is already installed in its
parent's cpool.**

Retained Builder bytes are **2.60x** the total final artifact they produced
(896,968 retained vs 344,674 B of committed code + atom operands + source-loc
slots across all 535 functions).

---

## 5. Duplicate-ownership intervals

Every interval where two owners hold the same logical bytes at once. Spans are
"from which call to which call". Bytes are the measured worst case on `mc1.js`.

| id | the two owners | span: from | span: to | peak bytes held redundantly |
| --- | --- | --- | --- | ---: |
| **D1** | `Builder` (§2.2–2.6) ⟷ `ResolvedProduct` (§2.7) — same instruction stream, atoms retained twice | `resolve_variables.run` returns (`root.zig:59`) | `defer product.deinitUncommitted()` at `compileFunctionV2` exit (`root.zig:60`) | **37,392** (product), against a 51,112 B Builder. Sum over the tree if it were tree-wide: 615,952 — but only one product is alive at a time, so D1 is per-function. |
| **D2** | `ResolvedProduct` ⟷ `resolve_labels` growable output + scratch (§2.8) | `Resolver.initScratch` (`resolve_labels.zig:2731`) / first `ensureOutput` | `defer resolver.deinit()` (`resolve_labels.zig:2730`) | **34,708** |
| **D3** | `resolve_labels` growable `output`/`output_sources` ⟷ the exact committed copies installed on the carrier | `Resolver.commit` first `exactCopy` (`resolve_labels.zig:2665`) | `resolver.deinit()` frees `self.output` (`:437`) | **25,369** committed alongside 32,768 B of growable backing |
| **D4** | **`Builder` ⟷ the published `FunctionBytecode`** — the temporary input that produced a function is still fully alive after that function is executable | `Resolver.commit` installs final code/atoms/sources (`resolve_labels.zig:2695-2699`) — the ownership-transfer point | `FunctionDef.deinit` (`src/bytecode.zig:3576`), i.e. **the end of the whole compile** | **844,376 B / 2,801 allocations** at the global-peak instant; **896,968 B / 2,818 allocations** at `T5_finalize_end` (100% of the census) |
| **D5** | `Builder` ⟷ `cfg.Graph` + bind index + the partially built `ResolvedProduct` (§2.9) | `buildBindIndex` (`resolve_variables.zig:1997`) | the `defer`s at the end of `resolve_variables.run` | ≈**19,038** (in-pass peak minus end-of-pass live, worst function) |

D1, D2, D3, D5 are all **bounded per-function pipeline overlap**: each is
released by a `defer` at the end of the pass that created it, and each is
alive for exactly one function at a time.

D4 is **unbounded**: it is alive for *every* function simultaneously and its
span is the whole compile. It is the only interval whose cost is O(tree), not
O(largest function).

---

## 6. The ruling's explicit question

> Is `fd.v2_builder` the whole story, or only part?

**It is the dominant term but not the whole story, and the ResolvedProduct and
the resolve_labels output are demonstrably alive at the same time as the
builder.** Both halves of that answer are measured:

1. **`fd.v2_builder` is the O(tree) term.** 896,968 B / 2,818 allocations —
   27.4% of peak bytes and 31.3% of peak live allocations — are retained
   Builder state, 100% of it belonging to already-published functions by the
   end of the walk and 94.1% of it (844,376 B) at the peak instant. Legacy's
   equivalent census is 0 at both instants. This alone explains why v2's peak
   is worse on the allocation-count axis (1.45x) more than on the byte axis
   (1.22x): the Builder contributes 5.27 live allocations per function
   (object + up to five backings) where legacy's phase-1 buffers contribute
   2.99.

2. **The product and the resolve_labels output are simultaneously alive with
   the builder, with measured overlap.** At `s4_peak` for the worst function:
   Builder 51,112 + ResolvedProduct 37,392 + resolve_labels scratch 34,708 +
   committed exact buffers 25,369 = 148,581 B alive at one instant for one
   7,945-byte function. The instruction stream is fully materialized **four
   times**, and the source-position table **three** times (24,576 input slots +
   24,576 product slots + 24,576 growable output + 14,100 committed).
   D1 (37,392) and D2 (34,708) are each ~70-90% of the size of the Builder
   they overlap; they are not rounding error.

3. **Fixing only D4 does not by itself satisfy C2.** Removing the O(tree) term
   would remove 844,376 B from the peak instant, which is larger than the whole
   589,226 B peak gap versus legacy — but it would also move the peak instant
   back toward the middle of the walk, where the per-function stack (up to
   97,469 B above the Builder at one instant for the worst function, plus the
   still-pending census) becomes the binding constraint. The C2 requirement is
   *< 0.7x*, not *parity*; the per-function duplication in D1/D2/D3 is what
   stands between "no longer worse" and "0.7x".

4. **One contributor is not an ownership problem at all.** At `T0_parse_end`
   for the jQuery tree, v2 live exceeds legacy by 222,143 B, of which only
   77,568 B is the census difference. The residual 144,575 B is **not**
   FunctionDef metadata (identical on both: 206,224 B / 1,419 allocations) and
   **not** the atom table (identical on both: 1,038 live atoms / 2,048 slots).
   Replaying an allocation trace (`zjs -T`) and reconstructing the live set at
   that instant shows the difference is concentrated in the **parse arena**
   (`std.heap.ArenaAllocator` at `src/parser.zig:22282`, whose blocks are
   accounted): v2 takes one extra growth step — three blocks of 188,962 +
   116,826 + 73,812 = 379,600 B, versus legacy's two blocks of 135,090 +
   86,208 = 221,298 B, a +158,302 B difference against 144,575 B of residual.
   The number of non-census live allocations is the same on both (4,555 vs
   4,554). This is arena *geometry* driven by more arena-backed parser
   scratch, not a second owner; it should be tracked separately from the
   ownership work.

---

## 7. Where the release belongs (stated as a consumption point)

The last reader of `fd.v2_builder`:

* **plain v2** (`ledger == null`): inside `resolve_variables.run`
  (`src/compiler_v2/resolve_variables.zig:1987-2037`). Nothing downstream
  touches it — `resolve_labels.run` takes `fd` as `?*const FunctionDef` and
  never reads `v2_builder`; `publishLoweredMetadata` never reads it.
* **dual** (`ledger != null`): the ledger block in `compileFunctionV2`
  (`src/compiler_v2/root.zig:66-81`), which walks `input.label_slots` and reads
  `input.source_len`.

So the single point at which the Builder is provably dead in **both** modes is
the end of `compileFunctionV2` — exactly where `product.deinitUncommitted()`
already runs. The correct shape is therefore symmetric with the product:
**the consumer releases its input at the end of consumption**, expressed in
`compileFunctionV2`, not as a responsibility of `FunctionDef`. When a later
Emitter-interface stage moves builder ownership into a `V2Emitter`, the release
moves with the consumer and the timeline is unchanged.

Constraints any such change must respect (recorded here, not acted on):

* `fd.v2_builder != null` is the **backend dispatch predicate** at
  `src/bytecode.zig:12730` and (negated) at `:12465`. Release must not make a
  later phase of the *same* `fd` take the legacy path. Because
  `installChildFunctionBytecodes` prepares a node before its children and
  lowers on pop, a sibling's `prepareCurrentBeforeChildren` can run after an
  earlier sibling was lowered — but it only inspects its **own**
  `v2_builder`, so per-`fd` release at the consumption point is safe.
* `FunctionDef.deinit`'s release (`src/bytecode.zig:3576-3581`) must stay as
  the error-path backstop; it is already null-tolerant and idempotent.
* The dual-mode ledger reads (`root.zig:70`, `:78`) must be satisfied before
  the release, either by ordering or by capturing the two scalars.
* `src/tests/parser.zig:11840` / `:11863` assert on `v2_builder` being
  null/non-null after a parse; `src/compiler_v2/tests.zig:41-49` reach into
  `fd.v2_builder` for harness access. These encode the current lifetime and
  will need to move with it.

---

## 8. Reproduction

```
# Debug binaries (diagnostic accounting is Debug-only)
zig build zjs-dev -Dzjs_compiler=v2
zig build zjs-dev -Dzjs_compiler=legacy

# C2 counters on the same source
./zjs-dev --perf-json mc1.js       # allocated_bytes_peak / allocation_count_peak

# live-set reconstruction used for §6.4
./zjs-dev -T mc1.js                # replay "A <bytes> -> <addr>.<bytes>" / "F <addr>"
```

`mc1.js` is the vendored Octane `code-load` payload used by S6 for gate C2
(one Closure `base.js` compile + one jQuery 1.7.2 compile, `CHECKSUM: 2/2`).
The per-phase probe described in §1 was scratch-only and is not part of this
commit; §1 records its exact probe points so it can be reconstructed.
