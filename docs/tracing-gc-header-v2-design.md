# Tracing GC header v2 / obj64 representation design r2

Status: **APPROVED — owner ruling 2026-08-31（O1-O5 per Owner decision list，O2=Option B）**

Date: 2026-08-31

Lineage:

- r1 lineage: `gc/obj-prereq-20260831@21478dd0`; when that branch is merged,
  this approved r2 is authoritative and the expected path conflict must be resolved
  in favor of r2.
- adversarial review: `.scratch/REVIEW_A1V2.md`
- code baseline for the contracts described here: `main@7c067f01`
- standalone-Object bridge: `gc/obj-prereq-20260831@efd04569`

This is the owner-approved representation contract and supersedes r1 for future
integration. Approval does not itself authorize implementation, a production-default
switch, or revival of rejected P1 or archived S1a work.

## Owner decision list

### Owner rulings (2026-08-31)

| ID | Decision | Owner ruling | What remains blocked |
|---|---|---|---|
| O1 | Approve the per-kind ABI in §2/§6: one 8-byte immutable header for the six tracing kinds; BigInt gets an 8-byte physical alignment prefix whose high four bytes are the payload-minus-four RC word; Shape/Realm retain body RC. | **APPROVED as recommended.** It preserves JSValue's hot RC address, Shape uniqueness and Realm host ownership while removing RC from the common tracing header. | Header/body layout implementation and representation snapshot changes. |
| O2 | Choose the persistent mark-frontier entry contract in §7: **A, 16-byte generation handle**, or **B, 8-byte pointer with a proved marking-epoch exemption**. | **APPROVED: Option B.** Every queue entry is restricted to the four collector-owned kinds and the proof/checkers in §7.3 must land first. | Final mark queue ABI, segment geometry and performance preregistration. |
| O3 | Freeze public `GCStats.heap_live_bytes` as the existing **owned accounted-byte** meaning, including all doomed/parked/current allocations until raw free; do not silently add raw prefix bytes, and expose trace-live bytes only as a separately named diagnostic if needed. | **APPROVED as recommended.** This preserves the pre-P1 byte definition and lifetime boundary while removing the block/non-block pending discrepancy. | P-C/P1 accounting rewrite and public stats tests. |
| O4 | Approve the staged dual-layout migration in §10: semantic state moves in small commits, then A1 + obj64④ switch together by changing one compile-time layout selection; v1 remains a rollback binary until batch and quiet gates close. | **APPROVED as recommended.** “One physical cut” must not mean one unbisectable semantic commit. | Default-layout switch and later v1 deletion. |
| O5 | Approve the post-S1/S2 measurement framework in §9 and reserve the numeric acceptance thresholds until the actual accepted S1/S2 anchor exists. | **APPROVED as recommended.** No historic absolute line/refill endpoint or old marking percentage survives as an S3 gate. | Performance entitlement and final threshold values. |

All five rulings are approved. O1, O2 and O3 remain independently scoped; none
broadens the authorization boundary of another. O4/O5 govern how the approved
representation may be attempted and adjudicated.

### Engineering decisions frozen by this approved design

These are correctness/scope choices, not menus for the implementer. A conforming
implementation does not choose among them again without a new design ruling.

1. Candidate resolution is split into exact-handle, conservative-all-hits and
   diagnostic-single-winner protocols (§3).
2. Non-block generations are runtime-monotonic `u64`; block generations pack a
   runtime-monotonic `u32` block incarnation with a `u32` per-cell reuse sequence.
   Neither counter wraps and no permanent per-address tombstone is kept (§4).
3. The A1v2 horizon keeps the block heap **Object-only**. FunctionBytecode, VarRef,
   Module, Shape and Realm are extent allocations (§2.3).
4. Trace-live and owned-allocation are separate populations with separate iterators;
   candidate validation consults only trace-live, while teardown/accounting/audit
   consult owned-allocation (§5).
5. Every migration fact has old/new/independent comparison directions and deletion
   mutants. A second iterator over the same authority is not independent (§8).
6. Rejected `gc/p1-oldspace-20260831@b340faf3` is not an accepted S1 dependency and
   cannot supply the expected side of an accounting audit (§8.4).

## 1. Target and non-goals

The target remains a single immutable 8-byte header for tracing kinds:

```zig
const HeaderV2 = packed struct(u64) {
    type_tag: u8,
    size_class: u8,
    static_flags: u8,
    trace_class: u8,
    layout_extra: u32,
};
```

All five fields are initialized before publication and never mutated afterward.
`layout_extra` may contain only immutable layout data. Mark, allocation/publication,
young, remembered, generation, sweep, finalization and queue state are side state.
The exact flag-bit assignment remains an engineering census result, but the 8-byte
size, immutability and absence of RC are representation contracts covered by O1.

This revision does not design a different collector, make tracing concurrent with the
mutator, restore the retired RC collector, or move String/Rope into the tracing heap.
It also does not claim that moving bytes off-object makes them free: every side byte
and every additional lookup is measured under §9.

## 2. Per-kind representation and carrier ABI

### 2.1 Representation matrix

| Kind | Object-start representation | Lifetime carrier | Allocation carrier | Conservative tracing candidate | Destroy route |
|---|---|---|---|---|---|
| Object | `HeaderV2` at offset 0 | tracer-owned | Object-only block cell when eligible; otherwise extent | yes, only while `published` | collector condemnation/pass A/B; weak-husk exception |
| FunctionBytecode | `HeaderV2` at offset 0 | tracer-owned | extent only | yes, only while `published` | collector condemnation/pass A/B |
| VarRef | `HeaderV2` at offset 0 | tracer-owned | extent only | yes, only while `published` | collector condemnation/pass A/B |
| Module | `HeaderV2` at offset 0 | tracer-owned | extent only | yes, only while `published` | collector condemnation/pass A/B |
| Shape | `HeaderV2` at offset 0; body RC offset pinned | body `i32` for sharing/uniqueness and eager zero release; tracer may still collect an unreachable cycle with RC > 0 | extent only | yes, only while `published` | body-RC zero path or collector condemnation, both through the same extent state transition |
| Realm | `HeaderV2` at offset 0; body-tail RC offset pinned | body `i32` for host/RealmRef ownership; host provider and traced RealmRef edges supply tracing reachability | extent only | yes, only while `published` | body-RC zero path or collector condemnation, both through the same extent state transition |
| BigInt | no `HeaderV2`; `BigIntBody` is JSValue payload | payload-minus-four `i32` RC in an 8-byte physical prefix | extent descriptor, never tracing-live | no; a raw word is not BigInt ownership | tag-directed zero-RC slow path, then extent teardown |
| String/Rope/Symbol | unchanged by A1v2-r2 | existing independent RC prefix | existing registered descriptor | no | existing RC route |

“Extent only” is frozen for the five non-Object tracing kinds in this horizon. It
prevents candidate validation from reading an in-object tag to discover block kind.
An Object block descriptor carries `.object` as an immutable subspace kind; a future
multi-kind block proposal requires a new owner-reviewed design.

### 2.2 Header trust boundary

The carrier is permission to dereference; `HeaderV2` is a consistency witness:

1. validate runtime, state, exact start/bounds and generation from block/extent state;
2. obtain kind, size class and trace class from that trusted carrier;
3. only then load `HeaderV2` and compare `type_tag`, `size_class` and `trace_class`;
4. only after agreement derive a kind-specific body pointer.

A disagreement sets a representation-corruption latch and aborts the collection
before sweep. Merely retaining the mismatched allocation is insufficient because its
children would remain untraced. No path guesses a body kind or performs a wrong-kind
cast to continue.

### 2.3 Canonical address terms

Every extent record distinguishes:

```text
base          canonical object/payload start used by typed handles
raw_base      address passed to the raw allocator/free routine
payload_bytes logical body plus FAM bytes
raw_bytes     complete physical allocation including alignment/RC prefix
accounted_bytes bytes charged under the existing public heap-space definition
generation    allocation incarnation
```

For a tracing extent, `base == raw_base` and `HeaderV2` is at `base`. For BigInt,
`base == raw_base + 8`. The ownership identity is `(owner_runtime, base,
generation)`; `raw_base/raw_bytes` are the independent free/accounting facts.

## 3. Three candidate-resolution protocols

### 3.1 Exact typed handle: `resolveExact`

Conceptual API:

```zig
const AllocationHandle = extern struct {
    base: usize,
    generation: u64,
};

const ResolvedExact = union(enum) {
    tracing: *HeaderV2,
    big_int: *BigIntBody,
};

fn resolveExact(
    rt: *JSRuntime,
    handle: AllocationHandle,
    expected_kind: ?GcKind,
    allowed_states: StateMask,
) ResolveError!ResolvedExact;
```

Resolution performs no object dereference until carrier validation succeeds.

- Block: use the registered block set to derive `Block*` and an **exact** cell index
  from `handle.base`; require Object subspace, allocated state, allowed lifecycle
  state, and packed generation equality. A pointer into the cell interior is not an
  exact handle.
- Extent: exact-start index lookup by `base`; require owner runtime, generation,
  allowed state, bounds and optional expected kind.
- Tracing kind: compare carrier kind/class with `HeaderV2`, then return it.
- BigInt: exact descriptor lookup is allowed only to the tag-directed RC destroy/
  diagnostic APIs; it returns a `BigIntBody`, not a forged `HeaderV2`.

Queue, weak and teardown APIs each pass a narrow `allowed_states`; there is no generic
“anything allocated” escape hatch.

### 3.2 Conservative raw word: `forEachTraceCandidateAt`

This is the only protocol allowed to turn an untrusted machine word into roots. It
matches the current `gc_address_registry.Table.forEachGcObjectAt` semantics rather
than `resolveAny` semantics.

```zig
fn forEachTraceCandidateAt(
    rt: *JSRuntime,
    addr: usize,
    visitor: fn (ValidatedTraceAllocation) void,
) usize;
```

Rules:

1. Treat `addr` only as an integer. Bounds filters, block membership and page/radix
   records are consulted without dereferencing `addr`.
2. Probe both `addr` and `addr - 1`, including the previous page when `addr` is page
   aligned. Enumerate **every** allocation whose registered logical range contains
   the candidate; do not stop at a greatest-`lo` winner.
3. A tracing range is `[base, base + payload_bytes + 1)`: header/body interior and
   exactly one-past are accepted. Block geometry supplies the equivalent cell range.
4. De-duplicate by `(base, generation)`, not pointer alone.
5. Require owner runtime, `state == published`, a tracing kind and carrier bounds.
   Then validate `HeaderV2` as in §2.2 before calling the visitor.
6. BigInt/String/Rope descriptors may be classified for diagnostics but are never
   emitted as tracing roots.

The required adjacency result is explicit:

```text
A.one_past == B.base == p
forEachTraceCandidateAt(p) => visit(A), visit(B)
```

Visiting B when `p` was meant as A's one-past, or vice versa, is permitted false
retention. Returning only one is unsound. Implementations must preserve the current
multi-hit, `addr`/`addr-1` and cross-page fixtures, plus standalone interior/replay.

If the fast page/radix index is incomplete, collection either rebuilds it from the
complete owned-allocation authority or uses an allocation-free full side-table scan.
Until one of those paths completes, sweep is prohibited. “Index OOM” never degrades
to precise-only tracing.

### 3.3 Diagnostic single winner: `resolveOneForDiagnostics`

This cold API may choose the containing record with greatest `lo`, matching current
`resolveAny`, and returns `{ winner, hit_count }`. It is legal only for logging,
metrics and non-semantic inspection. It may not shade, free, retain/release, resolve a
weak identity, or dispatch a body destructor. Semantic call sites are rejected by an
API census/lint and targeted tests.

## 4. Persistent generation authority

### 4.1 Selected non-block scheme

Each runtime owns `next_extent_generation: u64`, initialized to 1; 0 is permanently
invalid. Before raw allocation, reservation consumes the current value and advances
the counter. Values are never reused, even if allocation or construction later
fails.

- If advancing would wrap, set `extent_generation_exhausted` and fail this and all
  later descriptor-bearing allocations before raw allocation. The existing public
  allocation failure surface remains `OutOfMemory`; debug/diagnostic output names
  identity exhaustion.
- Runtime teardown does not reset a live runtime's counter. Internal queue/weak/
  diagnostic handles must be drained or invalidated before runtime storage is freed.
  No handle may cross runtime lifetime.
- An extent record can be removed after raw free because a later record at the same
  base has a distinct generation. Lookup of a stale handle either finds no record or
  finds a generation mismatch.

### 4.2 Selected block-cell scheme

Each new block receives a runtime-monotonic non-zero `u32 block_incarnation`. Each
cell has a side `u32 reuse_sequence`, initially zero and incremented before every cell
reservation. The 64-bit generation carried by exact handles is:

```text
generation = (u64(block_incarnation) << 32) | reuse_sequence
```

The handle's first word is the exact cell start; the registered block derives
`(Block*, cell_index)` without dereferencing the cell. Thus a generation-carrying
frontier/weak handle remains 16 bytes while logical block identity remains
`(Block*, cell_index, generation)`.

- Neither component wraps. Exhausting a cell sequence permanently seals that cell
  against reuse; exhausting the block-incarnation counter prohibits creation of new
  blocks in that runtime. Existing blocks remain valid. Block incarnations are
  consumed before raw block allocation and remain burned on allocation failure;
  exhaustion maps to the same public allocation-failure surface as §4.1 and is named
  separately in diagnostics.
- Block raw-free discards cell sequences, but a block later created at the same
  address receives a new incarnation. No address tombstone is required.
- The required side cost is four bytes per physical cell plus one incarnation per
  block, before packing/alignment. It is included in the post-anchor footprint and
  committed/live accounting; it is not hidden as “free metadata.”

### 4.3 Tombstone rule and alternatives

**Selected rule: no permanent per-base tombstones.** Strictly monotonic incarnation
values are the persistent authority. A record remains present through every owned
state and is removed only after raw free commits; retired generation values are never
reissued.

Alternatives, not selected:

1. Per-base tombstone map: simple generation increment, but retains an unbounded
   address history or needs a reclamation proof equivalent to the ABA problem.
2. Full `u64` generation per block cell: simpler and gives a single runtime counter,
   but costs eight bytes per cell instead of four.
3. A process-global 128-bit identity: avoids practical exhaustion but widens every
   handle and the frontier beyond the 16-byte option priced in §7.

Changing the selected width/scheme requires design review because it changes side
footprint or handle geometry.

### 4.4 Handle census

| Handle class | Carries generation? | May cross raw reuse? | Rule |
|---|---:|---:|---|
| Exact teardown/deferred handle | yes | potentially | validate state + generation before action |
| Weak identity/ephemeron diagnostic handle | yes | potentially | stale mismatch resolves to dead/absent |
| Address-index record reference | yes or stable record ID | potentially during rebuild | record cannot be removed while referenced |
| Long-lived diagnostic handle | yes | yes | never dereference on mismatch; invalidated at runtime teardown |
| Conservative raw machine word | no | yes | may retain the current occupant; never claims ABA safety |
| Mark frontier entry | no (`O2 = B`) | no under the approved option-B proof | epoch-local 8-byte pointer; option A is retained only as the priced rejected alternative |
| Stack-local typed pointer inside a no-free call | no | no | lifetime proof, never stored |

### 4.5 Extent-record address stability

Extent records live in non-moving paged/slab storage; growing the table never moves a
published record. The exact-start map and page/radix buckets store
`RecordId { slot, generation }`, not an unchecked body pointer. A slot may be reused
only after its prior record reaches absent and every index entry/reference is removed;
the new allocation generation makes a stale `RecordId` fail validation.

The page/radix index can associate one candidate address with multiple record IDs,
which is required by §3.2 one-past overlap. Record storage, exact-start mapping and
candidate fanout capacity are reserved before raw allocation becomes observable.
Block metadata is likewise stable while registered; block raw-free follows removal of
all block/cell handles and index membership.

## 5. Trace-live versus owned-allocation

### 5.1 State matrix

The same logical state is represented by per-cell bitplanes/compact state in an
Object block and by `ExtentRecord.state` for non-block allocations. Exact packing is
an engineering task; the states and transitions are not optional.

| State | Raw storage exists | In owned iterator | In trace-live iterator | Conservative shade | Exact teardown access | Address index record |
|---|---:|---:|---:|---:|---:|---:|
| `constructing` | yes | yes | no | no | construction handle only | present, state-filtered |
| `published` | yes | yes | tracing kinds only | tracing kinds only | ordinary exact handles | present |
| `doomed` | yes | yes | no | no | collector only | present, state-filtered |
| `finalizer_current` | yes | yes | no | no | active callback/resource pass only | present, state-filtered |
| `husk` | yes | yes | no | no | weak-husk logic only | present, state-filtered |
| `parked` | yes | yes | no | no | pass-B only | present, state-filtered |
| `rollback_pending` | yes | yes | no | no | constructor rollback only | present, state-filtered |
| `raw_free_in_progress` | until free commits | yes | no | no | raw-free routine only | no candidate membership; ownership record retained |
| absent/free | no | no | no | no | no | absent |

Capacity reservation before raw allocation is not a state and is not in either
population. `published` BigInt is owned but not trace-live because kind classification
excludes it.

### 5.2 Set equations

At every observable safepoint, collector boundary and ownership-audit boundary:

```text
OwnedAllocation
  = Constructing
  + Published
  + Doomed
  + FinalizerCurrent
  + Husk
  + Parked
  + RollbackPending
  + RawFreeInProgress

TraceLive = { x in Published | x.kind is a tracing kind }
ConservativeResolvable = TraceLive
domain(RawAllocationAuditLedger) = OwnedAllocation
sum(raw_ledger.raw_bytes) = sum(record.raw_bytes for x in OwnedAllocation)
GCStats.heap_live_bytes = sum(accounted_bytes for x in OwnedAllocation)
```

All sums are disjoint. `trace_live_bytes`, if retained as a diagnostic, is separately
named and derived from `TraceLive`; it never replaces `heap_live_bytes` or an
ownership audit. GC pacing remains based on MemoryAccount/doomed-budget contracts,
not the diagnostic trace-live sum.

### 5.3 Required transitions

```text
reserved capacity -> raw allocate -> constructing -> published
constructing -> rollback_pending -> raw_free_in_progress -> absent
published -> doomed -> finalizer_current -> doomed
doomed -> husk                     // resource-stripped, still owned, never trace-live
husk -> raw_free_in_progress -> absent  // after the last weak identity/reference drops
doomed -> parked -> raw_free_in_progress -> absent
published Shape/Realm RC zero -> doomed -> [resource work] -> parked/free
published tracing allocation -> collector condemnation -> doomed
```

Condemnation changes state before callbacks or body mutation, so new conservative
candidates cannot resurrect a corpse. A failed marking cycle aborts before any
`published -> doomed` transition. A weak husk keeps allocation identity and generation
only so weak teardown can name its stripped storage; it never returns to `published`.
Once doomed resource mutation begins, there is no resurrection path.

`raw_free_in_progress` contains no safepoint or reentrant callback. The ownership
record remains until the raw allocator commits free; record/index removal is a
reserved no-fail write immediately afterward. No callback can observe freed storage
through the record.

### 5.4 Block and extent authority

Object blocks own, per cell:

```text
cell state, reuse_sequence, mark epoch/bitmap, young membership,
remembered membership, finalization/husk state
```

Block geometry and immutable `.object` subspace kind provide start, bounds and class.
The owned iterator enumerates every non-free cell state; trace-live enumerates only
`published`. A plain allocation bitmap without publication/lifecycle state is not
sufficient.

Extent authority is one table over all non-block tracing kinds and BigInt. The
current `NonBlockObjectAuthority` vector is only the r1 bridge; its exit criterion is
bidirectional equality with extent `published Object` entries plus independent raw
ledger equality across every non-live state. It is not deleted merely because normal
benchmarks show zero standalone Objects.

Existing registered String/Rope/Symbol descriptors are exposed through an
`OwnedAllocationIterator` adapter for ownership/accounting parity, but are not moved
into the extent table and never enter `TraceLive`. Consequently the set/byte equations
cover the whole existing heap-accounting domain, not just the six A1 tracing kinds.

Index rebuild failure sets `address_index_incomplete`. The complete block/extent
owned authority remains replayable; collection cannot sweep until the published
candidate index has been rebuilt or safely scanned in full.

## 6. BigInt, Shape and Realm ABI/state machines

### 6.1 BigInt

O1 selects this physical layout:

```zig
const BigIntPrefix = extern struct {
    allocator_or_padding: u32, // no lifetime meaning
    rc: i32,                   // exactly payload - 4
}; // size 8, payload remains 8-byte aligned

const BigIntBody = struct {
    limbs_ptr: ?[*]Limb,
    allocator: std.mem.Allocator,
    len: u32,
    capacity: u32,
    flags: Flags,
    // alignment tail; FAM begins at @sizeOf(BigIntBody)
}; // target size 40, alignment 8; exact pins required
```

The JSValue payload remains `*BigIntBody`; generic retain/release continues to load
`payload - 4`. The old body `gc.Header` is removed in the v2 layout. The physical
prefix remains eight bytes because the payload is 8-byte aligned; “four-byte RC” is
not represented or priced as a four-byte total prefix.

The ABI conversion is complete only when all former header-shaped accessors obey this
map:

```text
JSValue payload/tag decode        -> *BigIntBody directly
generic refCountWord              -> payload - 4 (unchanged)
BigInt reads/FAM base             -> body fields / @sizeOf(BigIntBody)
cycleMarkHeader/refHeader         -> BigInt excluded; never fabricate HeaderV2
zero-ref dispatch                 -> Tag.big_int cold tail, exact extent lookup
ordinary/FAM raw free             -> record.raw_base + record.raw_bytes
```

A valid owned JSValue is the precondition of the lookup-free non-zero RC hot path. A
potentially torn/untrusted JSValue never executes that path; it goes through the
integer candidate/diagnostic protocols in §3, which do not emit BigInt as a root.

Allocation protocol:

1. prepare external limbs/dependencies and reserve extent/index/audit capacity;
2. consume a generation; allocate `8 + 40 + fam_bytes` at alignment 8;
3. create a `.big_int` `constructing` record with base/raw base/both byte counts;
4. initialize prefix `rc=1`, body and FAM; publish the descriptor and JSValue;
5. on failure, enter `rollback_pending`, release external limbs/raw storage, then
   remove the record.

Retain/non-zero release remains lookup-free. Zero release is tag-directed, not
`gc.Header`-directed: it performs an exact descriptor lookup at the cold tail,
requires `.big_int/published`, and transitions `published -> doomed ->
finalizer_current`. External limbs are freed with the body allocator and capacity;
the wrapper/inline-FAM raw allocation is freed with the record's `raw_base/raw_bytes`.
The record is removed afterward. BigInt is never placed on trace-live, the mark
frontier or conservative-root output.

### 6.2 Shape

Shape retains `HeaderV2` at offset zero and the existing aligned body `i32`
`ShapeOwnership.trace_ref_count`; its exact offset and `rc == 1` in-place-mutation
rule remain compile-time/snapshot ABI pins.

For this migration, the current Shape list-backlink slot remains reserved zeroed
space even after side topology replaces it. Shape total size, ownership/field/FAM
offsets and alignment therefore do not silently change in the header cut. Reclaiming
that slot is a separate size-class proposal with its own snapshot and price.

- Each strong Shape owner increments/decrements the body count. Every long-lived
  counted owner must independently be visible as a traced heap edge or registered
  root; a stack-local owner is valid only inside the native/conservative root window.
  RC alone is not a root. Count zero outside collector teardown enters the exact
  extent transition `published -> doomed` and performs eager destruction.
- Count greater than zero is **not a root**. An unreachable cycle may be condemned by
  tracing with `rc > 0`; finalization state prevents releases performed by the batch
  from launching a second destroy.
- `rc == 1` means unique among counted owners only while state is `published`.
  Mutation APIs reject constructing/doomed/finalizing states.
- Shape is extent-only, so body recovery is descriptor -> HeaderV2 agreement ->
  pinned body offset. No arbitrary pointer is cast to `Shape` first.

### 6.3 Realm

Realm retains `HeaderV2` at offset zero and the existing body-tail aligned `i32`
count. The count, host root provider and traced RealmRef edges form one contract:

The current tail list-backlink bytes remain reserved so `JSContext` size, alignment,
the count offset and all public/core field offsets stay unchanged in this migration.
They are not reused for unrelated state in the physical cut.

1. Realm construction starts count 1 and registers the host-create-ref root provider
   before publication.
2. `RealmRef.retain/clone` increments the count and the owning heap field is traced as
   a strong Realm edge. Any future externally retained Realm handle must register a
   root provider/persistent root; count alone is not permission to hide a host root.
3. `JSContext.destroy` consumes the host create-ref exactly once, unregisters the
   root provider **before** decrement, and then releases that count.
   `RealmRef.takeOwned` also consumes/unregisters the provider exactly once but
   transfers the same count into the returned `RealmRef` without decrementing it.
   Neither path treats runtime context-list membership as a root.
4. Count zero outside collector teardown enters `published -> doomed` and destroys
   eagerly. Count greater than zero does not save an unreachable Realm cycle: the
   tracer may condemn it, and finalization state suppresses duplicate zero teardown.
5. Once `doomed/finalizer_current`, host retain/destroy and RealmRef creation are
   invalid. Resource teardown and pass-B keep the extent record owned until raw free.

Thus “body RC is not tracing liveness” does not erase the bridge: host ownership is
visible through the root provider, heap ownership through traced RealmRef edges, and
unreachable counted cycles remain collectible.

## 7. Approved mark-frontier contract (`O2 = Option B`)

### 7.1 Rejected alternative A: 16-byte generation handle

Each segment item is `AllocationHandle { base, generation }`. Pop calls
`resolveExact(..., published tracing kinds)` before dereference.

Current S1a geometry is 4096 bytes minus a 24-byte segment header, with 509 8-byte
pointers. A 16-byte item changes capacity to:

```text
floor((4096 - 24) / 16) = 254 entries
```

At the same peak item population, the recorded splay 429 active segments would scale
to about 860 segments: 1,757,184 bytes becomes about 3,522,560 bytes before allocator
effects. Push/pop traffic doubles item bytes and adds carrier lookup, generation
comparison and a branch before every trace. Donation/admission thresholds and all
S1a performance evidence must be discarded and remeasured.

Benefit: queue soundness is local to each entry and remains valid if future designs
allow queued objects to be freed/reused during a marking window.

### 7.2 Approved option B: 8-byte raw pointer with marking-epoch exemption

Keep the 509-entry segment and existing donation geometry. Generation is omitted only
from this queue; all other cross-reuse handles in §4.4 still carry it.

Benefit: no item-width/lookup regression and existing S1a mechanism geometry remains
structurally applicable, although its archived performance verdict still cannot be
reused as an S3 result.

Cost: the no-reuse proof becomes a permanent collector invariant, not a comment.

### 7.3 Required proof/checkers for approved option B

All clauses must hold:

1. The central `frontierEpochSafe(kind)` whitelist is exactly Object,
   FunctionBytecode, VarRef and Module: kinds whose lifetime is collector-owned in
   normal tracing mode.
2. Shape and Realm are expanded synchronously when discovered and never persist in a
   private/shared frontier. BigInt/String/Rope never enter tracing.
3. An entry is queued only after its carrier is `published`, the immutable header has
   passed agreement, and mark claim succeeds. Failed construction cannot enqueue a
   cell that rollback may reuse.
4. While `major_marking_active` and any private/shared frontier entry exists, no
   collector condemnation, raw free or reuse of a whitelisted allocation occurs.
   Incremental mutator windows may allocate, but cannot RC-free these kinds.
5. Runtime deinit/abort first disables marking and drains/resets every private/shared
   segment. Sweep/condemnation starts only after the frontier is empty and final
   remark has completed.
6. Queue APIs accept a distinct `FrontierSafeHeader` produced only by the checked
   shade/publication funnels, not an arbitrary `*HeaderV2`.
7. Mutants that queue Shape/Realm, queue constructing Object, or begin free/reuse with
   a nonempty frontier must fail before dereference/sweep.

Any future change that weakens one clause reopens O2; it may not silently add pop-time
registry lookup to option B.

## 8. Migration parity, independent audit and P1 boundary

### 8.1 Three-corner parity table

During shadow migration, old physical state is authoritative until its named switch
step. New state is updated through carrier APIs but cannot be the expected side of its
own audit.

| Fact | Old source | New source | Independent source/oracle | Required directions |
|---|---|---|---|---|
| Raw ownership/bytes | current MemoryAccount/allocator bookkeeping | block non-free states + extent records | audit-only `RawAllocationAuditLedger`, written at the raw cell/extent allocation and raw-free boundaries | raw -> new; new -> raw; byte exact |
| Published membership | intrusive lists + block alloc/`heap_accounted` + Object vector | `state == published` | raw ledger plus “no unpinned constructing at safepoint” invariant and construction-pin census | old <-> new; raw entries must be in one legal owned state |
| Kind/class/extent | current Metadata and allocator route | block subspace/extent descriptor | compile-time allocation route + raw requested/class/size facts captured by audit ledger | old == new == expected |
| Mark | current header/block mark | new side epoch/bitmap | audit-only successful-shade event set plus fresh precise reachability oracle at collector boundaries | old <-> new; reachable subset must be marked |
| Young/remembered | current header bits + authoritative remembered map | side bitplanes/records | remembered-map/cache bidirectional checker and full-young verifier | both directions; map/cache mismatch fails |
| Candidate resolution | current `forEachGcObjectAt` | new block/page/radix multi-hit lookup | ranges built from raw audit ledger + state filter, including adjacency oracle | old hit set == new hit set == oracle during v1 geometry |
| Generation | no equivalent reuse identity | selected counters/record generation | forced-retire/reuse handle probes and monotonic-counter invariant | stale handle rejected; current handle accepted |
| Teardown | doomed lists/deferred stack/current slots + raw allocator | owned state machine | raw ledger + active callback/deferred handle census | every raw allocation has exactly one owner; no early record removal |
| Public heap bytes | pre-P1 maintained accounted bytes | derived `OwnedAllocation.accounted_bytes` sum | raw ledger captured accounted-byte sum; raw bytes are checked separately | all three accounted sums equal, including pending states; all raw sums equal separately |

`RawAllocationAuditLedger` exists only in tests/ownership-audit configurations and is
updated at the lowest raw cell/extent allocation/free seam, not by
`publishExtent`/`ownedIterator`. It records raw base, raw/accounted bytes, expected
kind, its own audit-module ID and the observed carrier generation. The audit ID is not
allocated by the carrier generation counter and is never used as new-state identity.
A scoped construction/teardown witness in this audit module
also observes outer transaction entry/exit independently of carrier mutation: leaving
a constructor without publication, a construction pin or rollback is an error;
leaving teardown while raw storage/active callbacks disagree is an error. This is why
omitting both old and new membership cannot make the audit entry disappear.

Production may derive reports from side records; the audit's expected population
never does.

Parity mismatch latches an invariant error. During collection it aborts before sweep;
during allocation/publication it fails before exposure where fallibility remains, or
panics in safety/audit builds for a no-fail invariant breach. It is never a warning.

### 8.2 Bidirectional checks

Every safe-boundary checker performs distinct passes:

```text
old -> new        no old allocation/state is absent or different in new
new -> old        no new record/bit is fabricated or stale
raw -> owned      no allocated storage is orphaned
owned -> raw      no record names freed/nonexistent storage
```

Re-instantiating the same iterator does not satisfy a direction. After the v1 reader
is deleted, `raw <-> owned` and the fresh reachability/remembered checks remain as
permanent ownership-audit gates.

### 8.3 Mandatory five mutant classes

1. **Orphan publication:** raw allocate and enter the audit ledger, then omit both old
   and new publication membership and remove the construction pin. The next boundary
   must report an unowned raw allocation.
2. **Wrong kind/extent:** corrupt only the new record kind, base, short bound or long
   bound. Old carrier and raw route/range oracle must disagree; body dereference and
   sweep are forbidden.
3. **Stale generation:** retain a weak/diagnostic handle, retire/free its allocation,
   force the same extent base or block cell to be reused, then resolve the old handle.
   It must reject while the new handle succeeds. A raw conservative word may retain
   the new occupant and is tested separately as the allowed direction.
4. **Missing doomed ownership:** detach a published object and clear its live state,
   but omit the new doomed/parked ownership transition. Raw ledger still names the
   storage; both block and non-block variants must fail the same invariant.
5. **Early record removal:** remove the extent/cell owned record while a finalizer,
   deferred handle or raw allocation remains. Active-handle/raw-ledger audit must fail
   before callback continuation or raw reuse.

Additional mandatory candidate fixtures cover `A.one_past == B.base`, cross-page
`addr-1`, block/extent interiors, duplicate suppression, wrong-kind header mismatch
and incomplete-index replay.

### 8.4 P1 composition boundary

`gc/p1-oldspace-20260831@b340faf3` is REJECTED evidence, not an S1 component. It made
stats and verification walk the same population and therefore lost orphan detection;
it also gave block/non-block doomed storage different pending byte semantics.

An A1v2/P-C rewrite may:

- derive production `heap_live_bytes` from `OwnedAllocation` and eliminate a hot
  per-object space counter if separately approved/measured;
- derive a separately named trace-live diagnostic from `TraceLive`.

It may not:

- use the block/extent iterator as both reported and expected accounting source;
- omit any non-live-but-owned state;
- treat the rejected P1 branch's gates as evidence for this design.

The independent raw ledger/mutants in §8.1-§8.3 are prerequisites for any P1-like
counter removal. P1 and header-v2 may share carrier APIs, but neither is allowed to
weaken the other's audit.

## 9. Post-S1/S2 pricing and measurement registration

### 9.1 Deleted assumptions

This r2 carries forward **no numeric expected benefit, no marking-only upper bound and
no absolute marking-line/refill endpoint** from r1. The current differential's
marking, kernel/minflt and alloc-front buckets prove that those older quantities were
not a closed price model; they do not grant A1v2 the whole current gap either.

S1a is presently NO-GO/archive-only and P1 is REJECT. If either mechanism re-enters as
part of an accepted composition, its actual commit is part of the new anchor and all
frontier/marking/line counters are regenerated.

### 9.2 Anchor registration

Pricing begins only after driver/owner identifies the actually accepted S1 and S2
commit set. Before A1v2 implementation measurement, record:

```text
H_S2       accepted post-S1/S2 anchor commit
H_PRE      immediate predecessor of the physical A1v2/obj64 switch
H_S3       candidate commit
config     production signature, compiler identity and layout selection
binaries   immutable paths + SHA-256 for every build
workloads  source/fixed-work hashes and completed-work/stdout contract
frontier   O2 option and resulting entry/segment geometry
repr_diff  expected snapshot and size/class changes per kind
```

If any identity changes, the registration is stale and must be regenerated; historic
numbers are context only.

### 9.3 Two comparisons, one currency

1. **Incremental attribution:** `H_S3 / H_PRE`, isolating the representation switch
   after all semantic carrier work already passes under v1.
2. **Combined S3 value:** `H_S3 / H_S2`, showing the whole representation/P-C tranche
   against the accepted system anchor without hiding staging costs.

Driver adjudication uses the systemic currency:

- six fixed workloads, balanced paired order and even samples under the active
  performance workflow; a fast parallel screen never substitutes for quiet
  same-core attribution of a boundary decision;
- cycles `(u+k)` geomean plus the registered splay single-item line;
- retired instructions as an independent guard, not a cycles substitute;
- committed/live, max RSS and minor faults;
- marking visits, side-record/block/header demand-line estimates and L1D/L2D refills;
- allocation/publication counts and size-class census;
- exact exit/stdout/completed-work parity and retained raw artifacts.

The structural discriminator is regenerated from `H_PRE`: predicted per-kind header
and side lines, actual frontier topology, and actual rescan behavior. Only the
direction and observed counts from that binary are registered; old absolute endpoints
are not copied.

### 9.4 Threshold ruling

After the anchor probe but before candidate timing, owner/driver freezes:

- the implementer target-load instruction ABBA ceiling required by
  `docs/verification-policy.md`, plus any separately named batch-level instruction
  sentinel; this does not reinstate a per-change full instruction matrix;
- six-load cycles `(u+k)` geomean ceiling;
- splay win/non-regression line;
- committed/live and minflt guards;
- the exact structural line/refill prediction that distinguishes the mechanism.

Correctness and parity gates remain prior. A correct performance-neutral
representation needs an explicit owner merge ruling; a failed preregistered guard is
a stop. No range in this approved design is merge entitlement.

## 10. Nine-step split migration

Each implementation step is a separate reviewable commit or tightly scoped change.
Under `docs/verification-policy.md`, iteration uses `zig build check` and targeted
tests; each owning change closes with one `zig build test`. Batch-only test262,
gate-smoke, arena audit and quiet performance remain driver work.

| Step | Change | Authority after step | Required evidence / rollback |
|---:|---|---|---|
| 1 | Owner ruling 2026-08-31 resolves O1-O5 and freezes the per-kind layout table, state enum, generation types and option-B queue contract in tests/snapshot declarations. No runtime layout change. | v1 only | Approved document diff and compile-time contract review; implementation still requires a separate task. |
| 2 | Add carrier APIs and audit-only `RawAllocationAuditLedger` at raw cell/extent allocation/free seams under current layout. Route no semantic reader yet. | v1 authoritative; raw ledger independent | Raw/owned census and orphan mutant; removing the audit code restores exact v1 behavior. |
| 3 | Add block cell state/reuse arrays, monotonic counters and extent records in **shadow-write** mode. Reserve before raw allocation; cover rollback and teardown. | v1 authoritative; v2 shadow | old/new/raw bidirectional checker; generation exhaustion/reuse and construction-failure tests. Disable shadow tables for rollback. |
| 4 | Implement the three candidate APIs and a v2 page/radix index while current `forEachGcObjectAt` remains authoritative. Compare complete hit sets, not single winners. | old candidate resolver authoritative | adjacency/cross-page/interior/incomplete-index fixtures and wrong-range mutant. Feature flag returns to old resolver. |
| 5 | Introduce per-kind lifetime adapters under v1 physical layout: BigInt tag-directed slow destroy, Shape/Realm exact carrier transition, and body-count/root-edge assertions. No field is removed. | v1 layout; adapter semantics dual-checked | BigInt ordinary/FAM/OOM/zero-RC tests; Shape uniqueness/eager-zero/cycle tests; Realm host/RealmRef/cycle tests. Revert adapters independently. |
| 6 | Move `tmp_obj_list`, doomed buckets, deferred-free/current slots and the standalone vector into collector-owned state/queues keyed by carrier handles. Establish `TraceLiveIterator` and `OwnedAllocationIterator`; apply O3 stats semantics. | new owned/live topology authoritative; old topology shadow | missing-doomed and early-removal mutants; mixed block/non-block pending stats; no `Header.next` borrower remains. Roll back reader authority to old topology while shadow is retained. |
| 7 | Route mark/young/remembered/kind/size/teardown reads through carrier APIs and new side state while the physical v1 prefix/header still exists as shadow. Implement only the selected option-B frontier; option A remains a priced design alternative, not a second implementation. | new dynamic state authoritative; old fields shadow | every §8 parity direction; fresh trace/remembered audits; no direct dynamic-field readers outside compatibility module. Roll back API authority switch. |
| 8 | Add compile-time `header_layout=v1|v2` complete binaries. In the v2 binary remove the metadata prefix/mutable `next`, apply BigInt body/prefix ABI and obj64④ geometry, and update the representation snapshot. No binary may allocate mixed layouts. The O4 protocol permits a production-default switch only after gates and a separate execution/default-switch ruling, in one small commit. | selected per-binary layout; v2 default only after ruling | both binaries pass targeted/full gates; snapshot every line has rationale; exact config signature attests layout. Rollback is selecting the already-built v1 binary, not patching a live heap. |
| 9 | On the accepted post-S1/S2 anchor, execute §9 incremental and combined gates plus batch verification. After rollback evidence and an owner deletion ruling, remove v1 fields/readers and obsolete bridge storage in a cleanup commit. | v2 only after deletion ruling | quiet artifacts, batch gates, all mutants, permanent raw/owned audit. Until deletion ruling, v1 remains buildable and no compatibility field is repurposed. |

Steps 2-7 make the final layout switch small without rewriting Object twice. Step 8
keeps A1 and obj64④ one physical representation cut while preserving per-step
bisectability and a real rollback binary.

## 11. Revision-closure ledger

| Review requirement | Closure in r2 | Status |
|---|---|---|
| 1. Three candidate protocols and multi-hit one-past | §3; adjacency and cross-page rules match current `forEachGcObjectAt` | closed, mandatory |
| 2. Persistent generation, widths/wrap/tombstone | §4; selected `u64` extent and packed `u32+u32` cell scheme, no wrap/no tombstones, alternatives priced | closed, mandatory |
| 3. Trace-live/owned-allocation matrix/equations | §5; states, iterators, transitions and public byte semantics separated | closed; O3 approved |
| 4. old/new/independent parity and five mutants | §8.1-§8.3; four comparison directions and permanent raw audit | closed, mandatory |
| 5. BigInt/Shape/Realm ABI/state machine | §2/§6; allocation/free/FAM/root-edge/zero-vs-cycle behavior | closed; O1 approved |
| 6. Frontier 16B vs pointer+epoch | §7; exact segment pricing and option-B proof/checkers | closed; O2 selected option B |
| 7. P1 composition constraint | §5.2/§8.4; owned-byte semantics and independent expected source | closed; O3 approved |
| 8. Delete stale price, re-anchor post-S1/S2 | §9; no inherited range/endpoints, two registered comparisons | closed; O5 framework approved, numeric thresholds intentionally post-anchor |
| 9. Split physical migration | §10; nine bisectable steps, dual binaries and small default switch | closed; O4 protocol approved |

## 12. Authorization boundary

This approved design resolves O1-O5 but does not itself open an implementation task.
If a separate implementation task is opened, steps 2-7 follow this protocol and the
repository verification policy. Design approval does not by itself authorize step
8's production-default switch, removal of v1, merge or push.

Immediate stop conditions:

- a candidate path cannot preserve all-hit one-past semantics without dereferencing
  untrusted memory;
- generation storage/handle geometry differs from §4 or the selected O2 option;
- any raw allocation can exist outside `OwnedAllocation` at an observable boundary;
- parity expected/actual collapse onto one authority;
- a BigInt/Shape/Realm path requires a public ABI change not listed in O1;
- the accepted S1/S2 anchor is unknown when performance thresholds are requested;
- v1/v2 layouts can coexist inside one runtime or the config signature cannot attest
  the selected layout.
