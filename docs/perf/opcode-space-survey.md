# Opcode space: what four engines actually do, and where zjs stands

Input for **PERF-OPCODE-SPACE** (roadmap decision slot). Facts are read from
local source checkouts, not recollection: V8 15.4 (`/home/aneryu/v8`),
JSC (`/home/aneryu/WebKit`), Hermes (`/home/aneryu/hermes`), QuickJS
2026-06-04 (`/home/aneryu/quickjs`). Date: 2026-08-27.

## 0. zjs's position, measured

| | ids used | free | note |
|---|---|---|---|
| **zjs** | **254** | **2** | 255 is the byte the invalid-opcode test feeds; 254 was taken by the T-spike prototype |
| QuickJS | 244 | 12 | our upstream shape |
| V8 Ignition | 215 | 41 | |
| Hermes | 220 | 36 | |
| JSC | 194 bytecodes (+85 LLInt helper ids = 279 OpcodeIDs) | 60 | `static_assert(NUMBER_OF_BYTECODE_IDS < 255)` |

zjs is the most crowded of the five, and it is crowded for a reason we chose:
we added fusion opcodes QuickJS does not have (`get_field_field2`,
`get_var_field`, `get_loc0_field`, `get_loc2_field`, `cmp_if_false8`, …).
The wall is real and already blocking: the T-spike prototype needed two ids
and could only get one, so property WRITES stayed on the generic path.

## 1. The correction that matters most

The roadmap describes PERF-OPCODE-SPACE as "wide/prefix planes". **In V8 and
JSC, the prefix mechanisms do not extend the opcode numbering at all — they
extend operand width.**

- V8 `Wide` / `ExtraWide` (ids 0 and 1): the following instruction's
  *scalable operands* become 2 or 4 bytes. The opcode byte after the prefix
  is the same number it always was. Dispatch is one contiguous 768-entry
  table indexed `256 * scale + opcode`
  (`interpreter-assembler.cc:1433-1461`, `interpreter.h:105-114`).
- JSC `op_wide16` / `op_wide32` (ids 129 and 131): same idea, three
  independent 279-entry dispatch tables (`LLIntData.h:52-62`).

So "add a prefix plane" does **not** by itself buy a single new opcode
number. That has to be designed separately.

## 2. The four mechanisms that do extend or reclaim numbering

### (a) Second-level namespace behind one id — used by everyone

| engine | carrier | payload | sub-dispatch cost |
|---|---|---|---|
| QuickJS | `OP_special_object` (u8) | 7 special objects | second-level `switch`, loses direct threading |
| QuickJS | `OP_define_method` (atom+u8 flags) | 6 combinations | flag test |
| Hermes | `CallBuiltin` (UInt8) | **82 builtins**, own `static_assert(_count <= 256)` | array index + indirect call — absorbed into a call it was making anyway |
| V8 | `InvokeIntrinsic` (u8) / `CallRuntime` (u16) | second 256- / 65536-entry namespace | one extra indirection |
| **zjs (already!)** | `using` (id 244, u8 sub-operand) | **11 cold ops reclaimed** | second-level switch |

V8 names this explicitly as its escape valve, in a source comment
(`interpreter-generator.cc:2679`):

> `// TODO(neis): Turn this into an intrinsic when we're running out of bytecodes.`

The cost profile is the design lesson: Hermes pays almost nothing because
the sub-dispatch lands on a call it had to make regardless; QuickJS and zjs
pay a real second-level branch. **So this mechanism is right for cold
opcodes and wrong for hot ones.**

### (b) Retire or merge cold opcodes — V8 does this repeatedly

Verified from V8 git history:

| commit | what |
|---|---|
| `3b6773ba3d1` | removed `ToBoolean`, merged into `JumpIfToBoolean*` |
| `e06d57b05de` | removed `TestNotEqualsStrict` (parser emits `TestEqualsStrict` + not) |
| `f633218b624` | removed **all** `Ldr*` opcodes, replaced by Star lookahead — *"we get some small wins … probably due to reduced icache pressure since there are less bytecode handlers"* |
| `a8176a530c3` | removed `Nop` |

Zero runtime cost, and it can *improve* I-cache behaviour. This is the
cheapest source of ids and nobody in our codebase has ever swept for it.

### (c) Phase-scoped id reuse — QuickJS's trick, which zjs already inherits

QuickJS includes `quickjs-opcode.h` twice with complementary macro
definitions, so 19 temporary opcodes and the first 19 short opcodes occupy
the **same numbers** (178-196); which meaning applies is decided by
compilation phase, and the only runtime artifact is an index shift in
`short_opcode_info(op)` (`quickjs.c:22176-22186`). zjs has the same
structure (`op_temp_start = 178`, `op_temp_count = 19`).

This is already fully exploited in zjs. Extending it would require finding
another pair of phases with provably disjoint opcode sets.

### (d) Two-byte opcode ids in the wide plane — scaffolded in JSC, never enabled

JSC's generator already parameterizes the opcode-id width per plane
(`OpcodeSize.h:76-97`): a `Traits` may declare `maxOpcodeIDWidth = Wide16`,
and then wide16/wide32 instructions carry a **2-byte** opcode id while
narrow keeps 1 byte. The emit-side `Fits` check already permits ids up to
65535 for the wide planes (`generator/Opcode.rb:226-250`). Today
`JSOpcodeTraits::maxOpcodeIDWidth = Narrow`, so it is dormant.

This is the only production-grade design for genuinely extending the
*numbering*, and even JSC has not turned it on.

## 3. What the prefix planes actually cost

Worth knowing before adopting one for any reason:

- **V8**: a prefixed instruction takes **two indirect jumps** instead of one
  (the prefix handler does a full second dispatch). Handlers are tripled
  (522 handler builtins for 215 opcodes); the dispatch table is 768 × 8 B =
  6 KB. Frame-stored bytecode offsets need a ±1 correction on every
  save/reload in wide handlers (`interpreter-assembler.cc:100-116`).
- **JSC**: measured from the generated assembly — narrow dispatch is 5
  instructions; the wide16 prefix handler is 7 and wide32 is 9, **plus an
  extra indirect branch**, and every wide16 instruction shares one indirect
  jump site, which is bad for the branch predictor. Every handler exists in
  three copies: `LLIntAssembly.h` is 7.67 MB with 582 opcode labels.

For zjs, whose whole dispatch design is built around a 20.7 cyc/iter
indirect-jump floor and a hand-tuned handler island, tripling handlers is a
large, well-understood risk.

## 4. What everyone spends ids ON (for calibration)

| engine | biggest consumers |
|---|---|
| V8 | 16 `Star0..Star15` (justified by **8-9% bytecode size reduction on real websites**, 16 ids share **one** handler), 12 Smi arithmetic specializations, 12 constant-pool jump variants |
| Hermes | width variants: `Long`/`Short` suffixes are **50 / 220 = 22.7%** of the space; jumps alone are 40 ids (20 logical jumps × 2). Their design doc concedes the tradeoff: *"we are trading off with an increasing number of opcodes to handle different operand widths … We believe that we are able to avoid opcode explosion by generating the code smartly."* |
| JSC | **no** burned-in-operand short forms at all. Instead `Fits<VirtualRegister, Narrow>` remaps locals/args/constants into −128..127 so most instructions fit narrow naturally (`Fits.h:117-155`). Ids are spent on fused compare+jump groups (14 `BinaryJmp` ops). |
| QuickJS / zjs | 66 short opcodes (`push_0`, `get_loc0`…) + our added fusions |

JSC's approach is the interesting outlier: **it buys narrow encoding by
remapping operand values, not by minting opcodes.**

## 5. zjs cold/hot census

Superseded by the precise census in §7.1 below. (An earlier pass used the
profiler's default 40-row cap as a proxy and reported "152 outside every
top-40"; that number conflated warm-but-not-hot opcodes with cold ones and
also mis-sorted the 19 temp opcodes. §7.1 lifts the cap and separates them.)

## 6. Reading

For zjs specifically:

1. The prefix planes in the roadmap's description solve a problem we do not
   have (operand width) at a price we can least afford (tripled handlers on
   a hand-tuned dispatch island).
2. Our real problem — numbering — is best solved the way V8 solves it and
   the way we already solved it once with `using`: **push cold opcodes into
   a sub-opcode plane and hand the freed real ids to the hot typed family.**
   Cold ops pay a second-level branch they will not notice; hot ops keep a
   first-class id and single dispatch.
3. A cold-opcode retirement sweep (V8's `Ldr*`/`Nop`/`ToBoolean` pattern) is
   the free tier and should be priced first — it may even help I-cache.
4. JSC's dormant two-byte-id-in-wide-plane design is the only genuine
   numbering extension anyone has built. It is the right reference if we
   ever need thousands of opcodes; it is over-engineering for needing forty.

---

# 7. Decision and reclaim plan (owner-approved 2026-08-27)

**Ruling: reclaim, following V8's pattern. No prefix plane.**

## 7.1 Measured census

Profiling build (`ZJS_PROFILE_ALL=1 zjs-profile --profile-opcodes`, the row
cap is now lifted by that env var) over 15 zoo benchmarks — richards,
deltablue, crypto, raytrace, navier-stokes, earley-boyer, regexp, splay,
pdfjs, typescript, box2d, code-load, gbemu, mandreel, zlib:

```
opcode executions observed:              41,888,384,774
final-stream opcodes:                    254   (all 256 ids claimed)
temp opcodes sharing ids with short ops:  19   (never in a final stream)
executed at least once:                  156
NEVER executed:                           79
executed but < 0.0001% of all opcodes:    23
=> cold pool at &lt;= 0.0001%:              102
```

The typed family needs 20-40 ids. The pool is 2-3x that.

## 7.2 Our own fusion opcodes, priced

Every zjs-added fusion earns its keep except one:

| fusion | executions | share |
|---|---|---|
| push_0_or | 3,768,876,208 | 9.00% |
| get_loc8_push_2 | 816,208,860 | 1.95% |
| put_loc8_get_loc8 | 600,756,243 | 1.43% |
| get_loc8_push_1 | 599,826,174 | 1.43% |
| push_2_sar | 470,159,471 | 1.12% |
| sar_get_array_el | 456,529,784 | 1.09% |
| push_0_shr | 395,847,723 | 0.95% |
| eq_if_false8 | 280,044,525 | 0.67% |
| cmp_if_false8 | 277,096,862 | 0.66% |
| get_loc0_field | 216,054,046 | 0.52% |
| push_this_put_loc0 | 108,967,999 | 0.26% |
| get_loc2_field | 74,268,031 | 0.18% |
| get_field2_call_method | 63,527,185 | 0.15% |
| get_var_field | 24,552,997 | 0.06% |
| get_loc2_field2 | 21,890,348 | 0.05% |
| get_field_field2 | 21,334,593 | 0.05% |
| **put_loc0_get_loc0** | **8** | **0.000%** |

`put_loc0_get_loc0` is our `Ldr*`: an id, a handler, and I-cache footprint
buying eight executions out of forty-two billion.

## 7.3 Tiers

Static check of every candidate (does the compiler still emit it?) matters:
most cold opcodes ARE still emitted — `swap` 27 emit sites, `nip` 10,
`gosub` 10, `to_propkey` 7 — benchmarks simply do not reach them. Those can
be demoted but not deleted.

**Tier A — retire (delete/merge). Zero runtime cost; V8 reports this can
help I-cache.**
- `put_loc0_get_loc0` — fusion with 8 executions in 42 billion.
- `nip1` — zero emit sites in the compiler, 3 references total.
- Further candidates require the same static check before they qualify.

**Tier B — demote to a sub-opcode plane (cold but live).** Second-level
dispatch is acceptable precisely because these are per-class-definition or
per-with-block, never per-loop-iteration:
- with/eval/ref machinery: `with_*`, `make_*_ref`, `*_ref_check`,
  `get_ref_value`/`put_ref_value`, `apply_eval`, `eval`
- class/private: `add_brand`, `check_brand`, `private_*`, `*_private_field`,
  `define_class*`, `init_ctor`, `check_ctor*`, `set_home_object`,
  `set_name_computed`
- super: `get_super`, `get_super_value`, `put_super_value`
- rare stack shuffles: `perm4`, `rot3l`, `nip`, `swap` (verify each against
  its emit-site count first)

zjs has already run this play once: `using` (id 244) carries a u8
sub-operand and absorbed 11 cold opcodes.

**Tier C — do NOT demote despite benchmark coldness.** The census corpus is
sync, CPU-bound, old-style JS; fun is a runtime.
- async/generator: `await`, `yield`, `yield_star`, `async_yield_star`,
  `for_await_of_*`, `return_async`, `initial_yield` — zero in benchmarks,
  everywhere in a real runtime.
- iterator/for-of: `for_of_*`, `iterator_*` — benchmarks predate for-of.
- `throw`, `catch`.

Demoting a Tier C opcode would tax exactly the workloads the product cares
about, on evidence drawn from workloads that do not represent it.

## 7.4 What this does not settle

- The exact Tier A list needs a per-opcode emit-site audit, not just
  frequency (the `swap`/`nip`/`gosub` result above shows why).
- Sub-opcode dispatch cost in zjs is a second-level branch (QuickJS shape),
  not Hermes's absorbed-into-a-call shape. Cost should be A/B'd on the
  demoted set before the plane is widened.
- Encoding-version policy and the shared generator for the four consumers
  (compiler / disassembler / serializer / future JIT) remain open and are
  unaffected by this ruling.

## 7.5 How much can we reclaim? (family analysis, 2026-08-27)

Asked after the ruling: is the pool bigger than the 20-40 the typed family
needs? Yes — but only after one correction that the group-level numbers hid.

**Family view of the whole 256-id space** shows the read/write asymmetry in
closure variables: `get_var_ref*` (5 ids) is 4.46% of all executions, while
`put_var_ref*` (5 ids) is 0.000%. Reads of captured variables dominate
writes by four orders of magnitude.

**The correction**: the `class/private/super` group looked like 0.063% of
executions, which would have been too warm to demote. Per-opcode it is one
opcode:

```
call_constructor         26,593,289   0.06349%
define_method                    39   0.00000%
private_symbol / check_ctor / init_ctor / check_brand / add_brand /
get_super / define_class / set_home_object / set_proto / ...   ALL ZERO
```

`call_constructor` is 26,593,289 of the group's 26,593,328. Demoting it
would put a second-level branch on every `new X()` — exactly the shape
typed OO workloads are made of. It is excluded; the other 20 are free.

**Wide-vs-short variants** are a second seam. Some wide forms are cold while
their short twin is hot, and only the cold one is a candidate:

| cold (demotable) | hot (keep) |
|---|---|
| `push_const` 25,524 | `push_const8` 9,550,185 |
| `fclosure` 10,557 | `fclosure8` 2,642,022 |
| `call` 1,144,018 | `call1` 48,048,859 |

But not all wide forms are cold — `get_loc` (266M), `put_loc` (180M),
`get_arg` (128M), `get_var_ref` (242M) are alive and stay.

**Safe demotable pool, after the corrections:**

| family group | ids | executions | share |
|---|---|---|---|
| with / eval / ref machinery | 20 | 560 | 0.0000000% |
| class / private / super (minus `call_constructor`) | 20 | 39 | 0.0000000% |
| var_ref write side | 8 | 1,151,868 | 0.0027% |
| stack shuffles + cold wide variants + misc | 36 | 102,925 | 0.0002% |
| **total** | **84** | | **all <= 0.003%** |

Plus Tier A retirements (`put_loc0_get_loc0`, `nip1`).

**One plane id carries 256 sub-slots**, so demoting 84 opcodes behind a
single id nets **83 free ids**. There is no mechanism reason to be timid
about the count; the cost is engineering effort per demoted opcode plus a
second-level branch those opcodes will never notice.

## 7.6 Staged plan

| phase | scope | ids freed | why |
|---|---|---|---|
| 1 | Tier A retirements + `with/eval/ref` family + `class/private/super` family | ~42 | Unblocks the typed family (needs 20-40) on its own. Both families are whole-family moves, which is far less error-prone than per-opcode surgery, and both are at 0.0000000% |
| 2 | var_ref write side + stack shuffles + cold wide variants | ~44 | Reserve for FNABI `CALL_NATIVE_*`, SER-ARTIFACT versioning, and whatever the backends need |

Do the families whole. Per-opcode cherry-picking is where a demotion of
something warm would slip in — the `call_constructor` finding above is the
proof that group-level numbers are not enough on their own.
