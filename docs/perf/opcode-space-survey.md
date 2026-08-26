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

## 5. zjs cold/hot census (measured 2026-08-27)

Using the existing profiling build (`zig build zjs-profile
--profile-opcodes`) over 12 zoo benchmarks (richards, deltablue, crypto,
raytrace, navier-stokes, earley-boyer, regexp, splay, pdfjs, typescript,
box2d, code-load):

```
final-stream opcodes:                    254
appear in some benchmark's top-40:       102
never in any benchmark's top-40:         152
```

**152 of 254 ids are held by opcodes that never enter any benchmark's hot
40.** The typed family needs 20-40. The room exists; it is just occupied by
cold code.

Caveat, stated plainly: "not in a top-40" is not "never executed" — the
profiler's output is capped at 40 rows per run, so warm-but-not-hot opcodes
(`apply`, `call`, `catch`, `delete`) are inside this 152. A precise census
needs that cap lifted; the number above is an upper bound on what is
reclaimable, not a committed budget.

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
