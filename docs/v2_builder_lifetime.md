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

---

## 9. Resolution (stage C2-B): release at the consumption point

Every release below is expressed **in the consumer, at the instant it stops
reading**, so it moves with the consumer when builder ownership later relocates
into a `V2Emitter`. No owner "keeps it until deinit".

| id | consumption point the release now sits at | status |
| --- | --- | --- |
| **D4** | `compileFunctionV2` (`src/compiler_v2/root.zig`), immediately after `resolve_variables.run` returns and after dual's two ledger scalars are taken from the input. `releaseConsumedBuilder` makes the producer inert (`Builder.deinit`, asserted capacity 0 on all five backings) and destroys it; `fd.v2_builder` becomes null. `FunctionDef.deinit` stays as the parse-time / error-path backstop only. | **closed** |
| **D1** | same point — the builder is gone before `resolve_labels.run` ever sees the product, so builder and `ResolvedProduct` are never co-resident after S3. | **closed** |
| **D2** | `resolve_labels.run`, on the line after `resolver.walk(layout)`. `Resolver.releaseConsumedProduct` blanks the borrowed views (`code` / `input_atoms` / `input_sources`) and calls `ResolvedProduct.releaseConsumedStreams`, which releases the resolved stream, the owned atom ledger and the source markers. `label_slots` stays live because S4 keeps mutating ref counts in `relaxJumps`. | **closed** |
| **D3** | `Resolver.commit` is now an ownership **transfer**, not a duplication: the growable `output` / `output_atoms` / `output_sources` backings are handed to the carrier through `installCodeWithCapacity` / `installAtomOperandsWithCapacity` / `installSourceLocsNoFail(…, capacity)`, with the resolver's own fields zeroed first. `exactCopy` is deleted. `commit` is now allocation-free **and infallible**, so "no observable half-install can escape" holds by construction rather than by ordering. | **closed** |
| **D5** | not an ownership defect: `cfg.Graph` and the bind index are *derived from* the builder while the pass is still reading it, and both are already released by the `defer`s of the pass that created them. Its tail (the builder outliving the pass) is closed by D4. Measured non-binding below. | **inherent** |

### 9.1 C2 re-measured (Debug, `mc1.js`, every binary run through one fixed path)

| counter | legacy | v2 before | before ratio | v2 after | after ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| `allocated_bytes_peak` | 2,684,108 | 3,273,334 | 1.2195x | **2,886,947** | **1.0756x** |
| peak − bootstrap | 2,558,359 | 3,147,577 | 1.2303x | **2,761,190** | **1.0793x** |
| `allocation_count_peak` | 6,204 | 9,007 | 1.4518x | **7,393** | **1.1917x** |
| peak allocs − bootstrap | 5,405 | 8,199 | 1.5169x | **6,585** | **1.2183x** |
| `alloc_calls` | 34,750 | 47,168 | 1.3573x | 45,434 | 1.3074x |
| `create_calls` | 1,775 | 2,371 | 1.3358x | 2,371 | 1.3358x |
| `allocated_bytes` (end) | 385,464 | 385,464 | 1.0000x | 385,464 | 1.0000x |

Legacy is a control and is byte-identical before and after. No allocation event
count regressed; `alloc_calls` fell by 1,734 (the three per-function exact
copies D3 used to make).

### 9.2 The census now drains, and the peak instant moved to parse end

Scratch probe at `createFunctionBytecode` entry/exit (`ZJS_C2B=1`, reverted
before commit), jQuery compile:

| | v2 after | legacy |
| --- | ---: | ---: |
| live at `T0_parse_end` | 2,882,631 | 2,660,488 |
| live at `T5_finalize_end` | 2,287,611 (**−595,020**) | 2,112,497 (−547,991) |
| whole-run peak | 2,886,830 | 2,683,991 |
| **peak above parse-end live** | **+4,199** | +23,503 |
| live allocations at `T0_parse_end` | 7,374 | 6,151 |
| **peak allocations above parse end** | **+19** | +53 |

Before the fix v2's live bytes *rose* +301,959 across finalize (§4); they now
fall, like legacy's. **The compile phase's own peak contribution is 4,199 B /
+19 allocations for v2 against 23,503 B / +53 for legacy — 0.18x and 0.36x, i.e.
the part of the peak that lowering controls now passes the 0.7x bar with room to
spare.** D1/D2/D3/D5 combined are inside that 4,199 B, which is why D5 needs no
further work.

### 9.3 Verdict: C2 still FAILS, and the residual is structural, not lifetime

`allocated_bytes_peak` is 1.0756x legacy where the gate wants < 0.7x; on the
peak-minus-bootstrap basis 2,761,190 against a 1,790,851 budget, i.e. **970,339 B
too high**. None of it is duplicate ownership:

* v2's peak is now its **parse-end resident set** (+4,199 B). That set is
  established before a single byte is consumed, so no consumption-point release
  can reach it.
* The parse-end delta versus legacy is +222,143 B (2,882,631 vs 2,660,488),
  attributed in §6: +77,568 B because a v2 `FunctionDef` carries a 168 B
  `Builder` plus up to five backings where legacy carries three phase-1 buffers,
  and +144,575 B of parse-arena *geometry* (v2 takes one extra doubling step).
* Even a v2 with literally zero compile-time transient would sit at
  2,882,631 / 2,684,108 = **1.074x**.

The bar is therefore a **phase-structure** requirement, not an ownership one:
the whole-process peak is dominated by holding the entire `FunctionDef` +
emission tree resident at once, which both pipelines do. Reaching < 0.7x means
lowering each function **on pop, during parsing** (QuickJS's `js_create_function`
at the end of each function body), so the emission census is O(depth) rather than
O(tree). That removes ~890 KB from v2's peak — the only remaining lever of that
size — and is a pipeline-topology change, not a lifetime change.

---

## 10. Stage C2-DECOMP: the three questions, separated

The single "peak scratch < 0.7x" bar is retired. C2 is three questions and they
are answered separately below:

| | question | bar |
| --- | --- | --- |
| **C2-A** | transient lowering memory — peak temporary bytes/allocations attributable to the lowering passes | hard, < 0.7x |
| **C2-B** | artifact residency — what the compile leaves behind | report the delta, not bar-gated |
| **C2-C** | peak live set — decomposed as transient + artifact + overlap, answering *where the increase is* | must be explained |

### 10.1 How C2-DECOMP was measured

Same two Debug binaries as §1 (`zig build zjs-dev -Dzjs_compiler=v2|legacy`,
branch tip `95ce9930`), same source (`mc1.js`, the vendored Octane `code-load`
payload: one Closure `base.js` compile, one jQuery 1.7.2 compile of 535
`FunctionDef`s). A second scratch probe (`ZJS_C2D=1`, Debug-only, added,
measured and reverted — it is deliberately **not** part of this commit) added
five instruments that the C2-A probe did not have:

1. **Per-item producer census** over the whole `FunctionDef` tree at
   `createFunctionBytecode` entry, one counter per buffer *role* rather than a
   single builder total.
2. **Artifact census** over the published `FunctionBytecode` tree at
   `createFunctionBytecode` exit, bucketed into the three C2-B groups.
3. **Parser-arena instrumentation**: the arena's *child* allocator is wrapped,
   so every block it takes from the runtime is recorded with address, size and
   pipeline phase; the arena facade handed to the parser is wrapped too, so
   requested bytes/calls are counted per phase (parse / finalize / State
   teardown).
4. **Arena-pointer audit**: every pointer reachable from the `FunctionDef` tree
   at parse end, and every pointer reachable from the published FB tree, tested
   for membership in the recorded arena block ranges.
5. **Lifetime classification** via the existing `-T` allocation trace plus
   `M <tag>` phase markers emitted at each per-function lowering
   enter/exit, replayed offline to compute, for every lowering window, the peak
   live bytes/allocations of allocations *born inside that window*.

Trace replay reconstructs live bytes to within 0.4% of the account's own
`allocated_bytes` (11,492 B of 2,882,631 for v2, 10,818 B of 2,660,488 for
legacy); the gap is the in-place `resize`/`remap` paths, which adjust
`allocated_bytes` without emitting a trace event. Every headline number below
comes from the direct per-resource census, not from the replay; the replay is
used only where an *exhaustive* class total is needed (C2-A's legacy side).

---

## 11. C2-B — artifact residency, three groups

### 11.1 First, a correction: 385,425 is not the artifact

`allocated_bytes` at process exit is **385,425 B / 864 live allocations on both
pipelines** (reproduced this stage on branch tip `95ce9930`; §1 recorded the
same 385,425 and §9.1 recorded 385,464 for this counter on a slightly different
tree state — the identity between pipelines is what matters and it holds in
every measurement). It is identical — but it is **not**
evidence about artifact residency, because the artifact is not in it. The
jQuery tree alone is 535 packed `FunctionBytecode`s plus 535 pc2line buffers
plus 534 source copies = 1,604 allocations, and only 864 allocations are live at
exit. The compiled artifact is released when the eval result is dropped; what
385,425 measures is the **runtime bootstrap residue** (atom table, shapes,
globals), which no compiler change touches.

Artifact residency therefore has to be measured while the artifact is alive.
The census below runs at `createFunctionBytecode` exit, i.e. at the artifact's
birth, walking the published FB tree through the cpool.

### 11.2 The three groups, jQuery tree (535 functions), legacy vs v2

Bytes unless the row says otherwise.

| group | item | legacy | v2 | delta |
| --- | --- | ---: | ---: | ---: |
| **(i) FunctionBytecode** | code bytes | 59,056 | **89,274** | **+30,218** |
| | atom operands (*count* of refs embedded in code; storage is inside the code bytes above) | 5,221 | **5,488** | **+267** |
| | metadata — FB header (96 B x 535) | 51,360 | 51,360 | 0 |
| | metadata — `DebugInfo` (32 B x 535) | 17,120 | 17,120 | 0 |
| | metadata — cpool storage | 12,320 | 12,320 | 0 |
| | metadata — vardefs | 24,240 | 24,240 | 0 |
| | metadata — closure rows | 9,360 | 9,360 | 0 |
| | metadata — hot extension | 4,280 | 4,280 | 0 |
| | **group (i) bytes / allocations** | **177,736 / 535** | **207,954 / 535** | **+30,218 / 0** |
| **(ii) persistent tables** | labels | **0** | **0** | 0 |
| | boundaries | **0** | **0** | 0 |
| | source events (pc2line buffers) | 41,588 / 535 | 41,589 / 535 | **+1 / 0** |
| | runtime metadata (source text copies) | 222,217 / 534 | 222,217 / 534 | 0 |
| | **group (ii) bytes / allocations** | **263,805 / 1,069** | **263,806 / 1,069** | **+1 / 0** |
| **(iii) ownership retained** | atom refs — names (func/file/vardef/closure) | 4,260 | 4,260 | 0 |
| | atom refs — code operands | 5,221 | 5,488 | **+267** |
| | atom refs total | 9,481 | 9,748 | +267 |
| | atom table live entries / capacity | 1,038 / 2,048 | 1,038 / 2,048 | 0 |
| | closures (closure_var rows) | 1,170 | 1,170 | 0 |
| | modules (module records) | 0 | 0 | 0 |
| | cpool values / of which child FBs | 770 / 534 | 770 / 534 | 0 |
| | **artifact total (i)+(ii)** | **441,541 / 1,604** | **471,760 / 1,604** | **+30,219 / 0** |

The `base.js` tree (59 functions) shows the same shape at 1/9 scale: group (i)
14,353 -> 15,687 (code 3,165 -> 4,499), group (ii) 10,034 both, atom refs 609 ->
620.

### 11.3 Verdict: NOT identical — and the difference is not smuggling

The ruling asked for an explicit statement. **`legacy artifact == v2 artifact`
is FALSE, and the group that differs is (i) FunctionBytecode, specifically the
code bytes: +30,218 B, +51.2%.** Groups (ii) and (iii) are equal to within one
byte and 267 atom refs, and those 267 refs are not an independent difference —
they are exactly the atom-operand opcodes that the extra code bytes contain.

The cause is a known and deliberate property of the current v2 pipeline, not a
lifetime defect: `resolve_labels.default_layout` is `.plain`
(`src/compiler_v2/resolve_labels.zig:21`). The short-form relaxation pass
(`LayoutMode.short`, which is what shrinks jumps and selects short opcodes)
exists and is exercised, but is not the production default yet, so v2 publishes
long-form code. Group (i) is the *only* group that can register that, and it
does.

What the ruling wanted to retire is nevertheless retired, by the evidence that
actually bears on it:

* **Allocation counts are identical group by group** — 535 FAM allocations, 535
  pc2line buffers, 534 source copies, on both pipelines. A smuggled temporary
  would be an *extra owner*, and there is none.
* **There is no v2-only persistent table.** Labels = 0 and boundaries = 0 on
  both; the label table, reloc array and source-slot array that v2 builds during
  lowering appear nowhere in the artifact.
* **Nothing v2 retains is arena-backed.** Of the 1,604 pointers reachable from
  the published FB tree, **0** fall inside a parser-arena block, on both
  pipelines.
* **The retained atom refs are accounted for exactly**: names 4,260 identical,
  code operands equal to the number of atom-operand opcodes in the published
  code.

So: **V2 did not smuggle temporary data into long-lived state.** Its artifact is
larger because it emits larger code, and that is a lowering-quality question for
the `.short` layout switch, not an ownership question.

---

## 12. C2-C — the peak live set, itemized

v2's whole-run peak is 2,886,830 and is reached 4,199 B above its parse-end live
set of 2,882,631; legacy's is 2,683,991, 23,503 B above its parse-end live set of
2,660,488. The peak is therefore the parse-end set on both pipelines:

```
peak gap  = parse-end gap − (legacy's lowering headroom − v2's)
+202,839  = +222,143      − (23,503 − 4,199 = 19,304)
```

so the whole peak question is the **+222,143 B parse-end gap**, which decomposes
with no unexplained remainder:

| term | bytes | share |
| --- | ---: | ---: |
| per-`FunctionDef` producer footprint (§12.1) | **+77,568** | 34.9% |
| parser arena (§12.2) | **+144,488** | 65.0% |
| unattributed residual | **+87** | 0.04% |
| **total** | **+222,143** | 100% |

(The same +87 B residual appears on the `base.js` compile: +10,320 producer,
−182 arena, +10,225 measured gap. It is one constant-size allocation, not a
per-function term.)

Shared `FunctionDef` metadata is **byte-identical on both pipelines** and
contributes 0: vars 55,680, args 78,912, scopes 38,528, cpool 28,672, globals
160, child lists 10,816, source text 222,217, in 1,953 allocations — the same on
legacy and v2. "Parsed AST metadata" and "temporary binding state" are therefore
*not* part of the increase, measured rather than assumed.

### 12.1 The +77,568 B producer footprint, per item

Both censuses are taken at `createFunctionBytecode` entry over the whole 535-node
tree. Items are matched by *role*, so the two pipelines' equivalents sit on the
same row.

| item | legacy | v2 | delta | allocations (legacy -> v2) |
| --- | ---: | ---: | ---: | --- |
| temporary code stream | 344,368 | 198,288 | **−146,080** | 535 -> 535 |
| atom ledger | 84,224 | 84,224 | **0** | 527 -> 527 |
| source events (marker slots) | 390,816 | 386,208 | **−4,608** | 535 -> 535 |
| label table | 0 | 79,616 | **+79,616** | 0 -> 343 |
| reloc entries | 0 | 58,752 | **+58,752** | 0 -> 343 |
| `Builder` object (168 B each) | 0 | 89,880 | **+89,880** | 0 -> 535 |
| root-only legacy `byte_code` stub | 0 | 8 | **+8** | 0 -> 1 |
| **total** | **819,408** | **896,976** | **+77,568** | **1,597 -> 2,819** |

The v2 producer is *smaller* on both shared items (−150,688 B: the compact
temporary stream is 0.58x legacy's phase-1 byte_code, and the marker slots are
slightly smaller). The entire +77,568 is three v2-only items totalling
+228,248 B, and the allocation-count increase (+1,222, i.e. 5.27 live
allocations per function against legacy's 2.99) is entirely those three.

Per item — create point, last use, release point:

| item | create point | last use | release point |
| --- | --- | --- | --- |
| **`Builder` object** | `State.v2EnsureBuilderForFd` (`src/parser.zig:7097`) via `fd.memory.create(Builder)`, called from `pushFunction` (`:4505`) per nested function and `beginV2ProgramEmission` (`:7118`) for the root | `resolve_variables.run` holds it as `Resolver.input` for the whole S3 pass; in dual mode the two ledger scalars are read one statement later in `compileFunctionV2` | `releaseConsumedBuilder` in `compileFunctionV2` (`src/compiler_v2/root.zig`), immediately after `resolve_variables.run` returns. `FunctionDef.deinit` (`src/bytecode.zig:3576`) is now the parse-time / error-path backstop only |
| **temporary code stream** (`Builder.code`) | first `emit*` -> `reserve(u8,…)` (`src/compiler_v2/builder.zig:71`), doubling, min 32 | `Resolver.code = input.code[0..code_len]` inside `resolve_variables.run` (`resolve_variables.zig:2017`) | same point (`Builder.deinit` from `releaseConsumedBuilder`) |
| **atom ledger** (`Builder.atom_operands`) | first atom-bearing `emit*`; every appended atom is retained | `Resolver.atom_ledger`; S3 re-retains survivors into `ResolvedProduct.atom_operands` | same point; refs released item-wise |
| **label table** (`Builder.label_slots`) | first `Builder.newLabel` (`builder.zig:168`), 16 B/slot, doubling min 8 | `initializeLabels` copies them into the product (`resolve_variables.zig:2009`); dual re-walks the input array once for `labels_unbound` | same point |
| **reloc entries** (`Builder.relocs`) | first `Builder.emitJump` (`builder.zig:189`), 12 B/entry | `cfg.build` sizes edge storage from `input.reloc_len` (`cfg.zig:641`); `resolve_labels` builds its own chains and never reads this array | same point — provably dead the moment `resolve_variables.run` returns |
| **source events** (`Builder.source_slots`) | first `Builder.addSourceMarker`, 12 B/slot | `Resolver.input_sources`; S3 writes output-offset copies into the product | same point |
| **parsed AST metadata** (`vars`/`args`/`scopes`/`cpool`/`closure_var`/`global_vars`/`child_list`/`source_text`) | `FunctionDef` growable appenders during parse; **identical on both pipelines** | read throughout lowering (`publishLoweredMetadata`, layout sizing, vardef/closure emission) | `FunctionDef.deinit` — unchanged by v2, contributes 0 to the delta |
| **temporary binding state** (`vars_htab`, `jump_slots`) | `FunctionDef` binding-index growth | legacy resolve passes | `FunctionDef.deinit`; both are **0 bytes at parse end on both pipelines** — they are populated and drained inside lowering, so they are not part of the parse-end footprint at all |

### 12.2 The +144,488 B parser arena: geometry, on top of a real boundary error

The ruling posed a specific hypothesis — *"parse finished but the arena is held
until emit"* — and asked whether that is a phase-ownership boundary error. Both
halves have to be answered separately, because **the answer is yes to the
retention and no to the delta.**

#### 12.2.1 The retention is real, and it is a boundary error

`Parser.compile` (`src/parser.zig:22282`) creates
`std.heap.ArenaAllocator.init(rt.memory.persistent_allocator)`, points
`rt.memory.allocator` at it for the parse, and calls `arena.deinit()` only at the
very end of `compile()` — after `createFunctionBytecode` has returned *and* after
`compileQjsProgram`'s `defer state.deinit(rt)` has torn the parser State down.
Measured, jQuery compile:

| | v2 | legacy |
| --- | ---: | ---: |
| arena blocks / bytes at parse end | 11 / **488,548** | 10 / **344,060** |
| high-water instant | during **parse** (phase 1) | during **parse** (phase 1) |
| bytes requested from the arena during **finalize** | **0** (0 calls) | **0** (0 calls) |
| bytes requested from the arena during **State teardown** | **0** (0 calls) | **0** (0 calls) |
| arena bytes still held at `createFunctionBytecode` exit | **488,548** | **344,060** |
| arena bytes after `arena.deinit()` at `compile()` exit | 0 | 0 |
| `FunctionDef`-tree pointers at parse end / of which inside an arena block | 11,234 / **0** | 8,024 / **0** |
| published FB-tree pointers / of which inside an arena block | 1,604 / **0** | 1,604 / **0** |

So the emit phase cannot even reach the arena: its only inputs are the
`FunctionDef` tree and the `CompileContext`, and **no pointer reachable from the
`FunctionDef` tree lands in arena memory**, while `rt.memory.allocator` is
switched to `compile_context.artifactAllocator()` for the duration
(`src/parser.zig:22673`), which is why the requested-bytes counter is 0.

Executable confirmation: with the probe's `ZJS_C2D_POISON=1` mode, every byte of
every arena block is overwritten with `0xDD` at parse end. On **both** pipelines
`createFunctionBytecode` then runs to completion and the artifact census it
produces is **byte-identical to the unpoisoned run** (all three compiles, all
groups). The process does eventually fault — at
`ParseState.deinit -> deinitDeclarationConflictIndices -> HashMapUnmanaged.deinit`
(`src/parser.zig:4272`, `:3578`), i.e. inside `compileQjsProgram`'s
`defer state.deinit(rt)`, which runs *after* finalize and only reads the arena to
free arena-backed containers.

**Conclusion:** from parse end to `compile()` exit, the entire arena — 488,548 B
for v2, 344,060 B for legacy — is retained with **no reader in the emit phase**;
its only remaining reader is the parser State's own destructor, which is pure
bookkeeping over containers whose storage the arena is about to discard anyway.
This is a phase-ownership boundary error, it is worth **16.9% of v2's peak** and
**12.8% of legacy's**, and it is present in both pipelines identically. It is
also, as the ruling suspected, much simpler to fix than lower-on-pop: it needs
the parse-scratch teardown moved ahead of finalize (or made arena-aware) so
`arena.deinit()` can run at parse end. It is *not* v2 work.

#### 12.2.2 The +144,488 delta is allocation geometry, proven

The boundary error explains why the arena is on the peak at all. It does **not**
explain why v2's arena is bigger, and the ruling asked for that to be proven the
other way if it is geometry. It is.

`std.heap.ArenaAllocator` sizes each new node as
`alignForward(1.5 * (prev_node_size + request + sizeof(Node) + alignment + 16), 2)`
(`std/heap/ArenaAllocator.zig`) — a 1.5x geometric ladder on the previous node.
Measured node ladders for the jQuery parse:

```
legacy (10 nodes, 344,060 B):  312  958  1936  3920  8152  15788  30708  57288  89908  135090
v2     (11 nodes, 488,548 B):  312  958  1936  3850  8096  16228  24636  49056  77688  116826  188962
```

What the parser actually asks the arena for:

| | legacy | v2 | delta |
| --- | ---: | ---: | ---: |
| arena allocation calls (cumulative, parse) | 2,374 | 2,547 | +173 (+7.3%) |
| bytes requested (cumulative, parse) | 428,277 | 446,497 | **+18,220 (+4.3%)** |
| resident arena blocks at parse end | 344,060 | 488,548 | **+144,488 (+42.0%)** |

**A 4.3% increase in demand became a 42.0% increase in resident bytes because it
crossed exactly one node boundary.** The proof is in the ladder: v2's first ten
nodes total 299,586 B, which is 44,474 B *less* than legacy's ten-node total of
344,060 B. The entire delta is v2's eleventh node, 188,962 B, which the ladder
sizes at 1.5x its tenth (a ~9.1 KB request against a 116,826 B previous node);
legacy's parse finished on node ten. There is no second owner and no retained
structure behind the +144,488 — it is one extra rung.

Consequences for planning: this term is **not** addressable by ownership work,
and it is fragile in both directions (a 4% swing in parser scratch moves it by
145 KB). Releasing the arena at parse end (§12.2.1) removes it from the peak
entirely on both pipelines, which is the only reason to care about it.

### 12.3 Transient + artifact + overlap, at the peak instant

The ruling asks the peak to be decomposed as transient + artifact + overlap. The
peak instant is the parse-end set, and at that instant two of the three terms are
zero:

| term at parse end (the peak instant) | legacy | v2 | delta |
| --- | ---: | ---: | ---: |
| lowering transient (no pass has run yet) | 0 | 0 | 0 |
| artifact (nothing published yet) | 0 | 0 | 0 |
| transient/artifact overlap | 0 | 0 | 0 |
| producer footprint (§12.1) | 819,408 | 896,976 | +77,568 |
| parser arena (§12.2) | 344,060 | 488,548 | +144,488 |
| shared parse-resident state (FunctionDef metadata, atom table, source text, runtime) | 1,497,020 | 1,497,107 | +87 |
| **parse-end live** | **2,660,488** | **2,882,631** | **+222,143** |
| lowering headroom above parse end | +23,503 | +4,199 | −19,304 |
| **whole-run peak** | **2,683,991** | **2,886,830** | **+202,839** |

The peak terms the ruling expected to trade off against each other are therefore
*both zero where it counts*. The per-function overlaps catalogued as D1-D5 in §5
are all closed (§9) and all fit inside the 4,199 B by which v2's peak exceeds its
parse-end set; their own maxima are 76,196 B (§13.1) and 118,954 B (§13.2), i.e.
they are real but they land in the middle of the walk, hundreds of KB below the
peak. **There is no remaining transient/artifact overlap term at the peak.**

---

## 13. C2-A restated as an attribution

§9.2 reported "peak above parse-end live" — 4,199 B / +19 allocations for v2
against 23,503 B / +53 for legacy, i.e. 0.18x and 0.36x. That is a **delta**: it
nets the producer census draining away against the lowering passes allocating,
and it would report a small number even for a pass that allocated a great deal,
as long as it freed slightly less than the producer drained. It is not an
attribution and C2-A must not rest on it.

The attributed figure is the maximum, over the lowering window, of live bytes
belonging to temporary compiler structures.

### 13.1 Per-resource census (v2, the structures by name)

Worst function of the jQuery tree, from the per-resource census at each pass
boundary:

| instant | `ResolvedProduct` | S3 scratch (`cfg.Graph` + bind index + pending/boundary arrays) | S4 scratch (growable output/atoms/sources + relocs + addr + binds + jump slots) | attributed total |
| --- | ---: | ---: | ---: | ---: |
| end of `resolve_variables.run` | 37,392 | 2,064 | — | 39,456 |
| after `Resolver.walk`, before `releaseConsumedProduct` | 37,392 | 0 | 38,804 | **76,196** |
| after `validateFinalOutput`, before `commit` | 528 | 0 | 38,804 | 39,332 |

**Max attributed transient for the v2 passes = 76,196 B in 11 live allocations**
(product 4 + resolver 7). Composition at that instant: growable output 8,192 +
output atoms 4,096 + output sources 24,576 + relocs 768 + addr 132 + binds 384 +
jump slots 656, against product code 8,192 + atoms 4,096 + labels 528 + sources
24,576. The source table is materialised twice at 24,576 B and dominates both
halves — it is 64.5% of the 76,196 on its own.

### 13.2 Exhaustive per-window classification (both pipelines)

The census above names v2's structures but has no legacy counterpart, so the
symmetric figure is computed by classification instead of enumeration: replay the
allocation trace and, for each per-function lowering window
(`createFunctionBytecodeAfterChildren` entry -> exit), track the live bytes and
live allocation count of allocations *born inside that window*. This catches
every temporary, named or not, on both pipelines.

| | legacy | v2 | ratio | C2-A bar |
| --- | ---: | ---: | ---: | --- |
| peak in-window transient bytes | 208,605 | **118,954** | **0.5702x** | < 0.7x -> **PASS** |
| of which survives the window (the artifact born in it) | 16,860 | 18,301 | — | — |
| peak transient bytes, survivors excluded | 191,745 | **100,653** | **0.5249x** | **PASS** |
| peak in-window transient live allocations | 15 | **24** | **1.60x** | < 0.7x -> **FAIL** |

596 lowering windows on each side (535 jQuery + 59 base.js + 2 roots).

### 13.3 Verdict

**C2-A passes the bar on bytes under attribution (0.57x, and 0.52x once the
artifact born inside the window is excluded), and fails it on allocation count
(1.60x).** The 0.36x allocation figure in §9.2 was the delta artifact described
above; the attributed number is 24 concurrent live temporary allocations per
lowering against legacy's 15, which is the direct consequence of v2's pass
topology — the S3 product carries four independent backings and the S4 resolver
seven, where legacy mutates a moved-in buffer in place.

This is a real and reportable difference, but it is *nine extra live allocations
at one instant for one function*, not a residency or peak term: v2's whole-run
`allocation_count_peak` is 7,394 against legacy's 6,204, and §12 attributes that
gap to the parse-end set (2,819 producer allocations against 1,597), not to these
nine. Whether C2-A "passes" therefore depends on which axis the bar is read
against; the honest statement is **bytes PASS at 0.57x, allocations FAIL at
1.60x, and neither is what makes C2 fail.**

---

## 14. Where this leaves C2

* **C2-A** — attributed transient: 0.5702x bytes (PASS), 1.60x allocations
  (FAIL). Not the binding constraint either way.
* **C2-B** — artifact residency: +30,219 B (+6.8%), **entirely group (i) code
  bytes**, caused by `default_layout = .plain`. Groups (ii) and (iii) match to
  within 1 byte, allocation counts match exactly, and nothing arena-backed or
  producer-shaped escapes into the artifact: **no temporary data was smuggled
  into long-lived state.**
* **C2-C** — peak live set: the peak *is* the parse-end set on both pipelines,
  and the +222,143 B gap is 77,568 producer footprint + 144,488 parser-arena
  geometry + 87 unattributed, with zero transient/artifact overlap at that
  instant.

Two levers are now separated and sized, and neither is an ownership fix:

1. **Release the parser arena at parse end** (a phase-ownership boundary fix;
   measured above as having no reader in the emit phase, and confirmed by the
   poison test): −488,548 B from v2's peak, −344,060 B from legacy's, i.e.
   2,398,282 against 2,339,931, ratio 1.0755x -> **1.0249x**. It applies to both
   pipelines so it barely moves the ratio, but it is the cheapest large absolute
   reduction on the table and it removes the whole §12.2 term — 65% of the
   parse-end gap — from the discussion permanently.
2. **Lower on pop during parsing** (§9.3): removes the O(tree) producer census
   from the peak. Still the only change that can reach < 0.7x.

## 15. Reproduction

```
zig build zjs-dev -Dzjs_compiler=v2
zig build zjs-dev -Dzjs_compiler=legacy

./zjs-dev --perf-json mc1.js          # allocated_bytes / *_peak, both modes
ZJS_C2D=1        ./zjs-dev --perf-json mc1.js 2>census.txt   # §11/§12 censuses
ZJS_C2D=1        ./zjs-dev -T         mc1.js >trace.txt      # §13.2 classification
ZJS_C2D=1 ZJS_C2D_POISON=1 ./zjs-dev  mc1.js                 # §12.2.1 poison test
```

`ZJS_C2D=1` alone is measurement-neutral: the probe only reads state and writes
to stderr, and the `--perf-json` counters are identical with and without it.
`ZJS_C2D_POISON=1` is destructive by design — the run is expected to fault in
`ParseState.deinit` after the last compile; the evidence it produces is the
`C2D-ART` census lines emitted *before* that fault, which must be byte-identical
to the unpoisoned run.

The `ZJS_C2D` probe is scratch-only and is not part of this commit; §10.1 records
what it instruments and where, so it can be reconstructed. The working patch is
archived outside the tree next to the C2-A probe.
