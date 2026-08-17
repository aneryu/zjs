# IC-P1 — get_field 金丝雀（续做收口）

**后继：唯一瘦身已跑，终门 FAIL，整通道 REJECT-ARCHIVE。见 `/tmp/lanes/IC-P1-V2.md`。**

日期：2026-08-17。现场 **`/tmp/wt-ic-p1`**，分支 **`grok/ic-p1`**，基 **`main@7bab7426`**。首发 HEAD **`10348c72`**。**未合 main。** 254/255 空。

形：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。

canonical 3-pad 由执行官跑。§5 FW **非裁决**。

---

## 0. 一句话

P1 编码 + own-data mono/mega + walk 出岛已接线。IC-R1（单测+夹具① difftest）绿。IC-R2 nm **0x4**（`b op_get_field`）。几何：`op_get_field` **0x330≤0x340**，`if_false8` **钉 0x1074880**，**0 bl / 0 帧**。七案夹具 **z≡q**。test-exec **479/479**。

**命中臂 44 insn > 硬顶 28。** 自测 FW TS/box2d cyc 同号差。按原文杀门 **金丝雀未过**，候裁。

锚到时产品已在树上（不是「5→7 未提交」）：见 §1。仅 `test262` symlink typechange 未收。

---

## 1. 改动清单 + checkpoint

| rev | 信息 |
|---|---|
| `3a31115b` | **IC-R1** `test(ic):` core 单测 + exec 观测 |
| `eba3274d` | **P1 编码 5→7 + 命中/learn/mega + IC-R2 field2 表跳**（同文件，见下） |
| `ac4bc34c` | `wip(ic):` `byte18_has_ic` 空表 `tbnz`；去掉 state/prop_count 冗余比 |
| `10348c72` | **checkpoint**（`--allow-empty`）：锚到时无未提交产品 diff |

`eba3274d` 文件：

- `src/bytecode.zig` — size 7、`GetFieldIcSlot` 32B、pad+24/+32/+36、stamp/ensure/release
- `src/compiler_v2/{builder,cfg,resolve_labels,resolve_variables,tests}.zig`
- `src/parser.zig` + `src/tests/parser.zig`
- `src/exec/tailcall_dispatch.zig` — 命中臂、learn、mega、walk 表跳、**field2 去克隆**
- `src/exec/{vm_property_field,vm_property,vm_literal,small_inline}.zig` — 冷宽 / apply-fwd 7B
- `src/core/object.zig` — IC shape 不 visit（弱引用）

**IC-R2 独立 commit：** 去克隆与探针同改 `tailcall_dispatch.zig`，无法在不改写 `eba3274d` 的前提下再拆一发空 commit。证据是该 commit 里 `op_get_field_field2` 从整段 walk 换成 `dispatch_table[get_field]`，RF nm **0x20c→0x4**（`b 1073b80`）。未 rebase 改写。

---

## 2. IC-R1 delete 语义证成

| 尺 | 结果 |
|---|---|
| `core.test.IC-R1: in-place delete mutates the shape Property word` | **PASS**。unique shape：`shape*` 不变，`@bitCast(Property)` 变，atom→null |
| `tests.exec.test.IC-R1` | **PASS**。`1 / delete / typeof undefined / 2` |
| 夹具① `01-inplace-delete.js` vs qjs | **IDENTICAL**（见 §5）。delete 后 undefined；`Object.prototype.x=99` 看见 99（未学缺席）；槽复用后 `site(o)` 仍不是 77 |

---

## 3. 命中 / learn / mega 接线

- **学：** `qjsGetFieldFastSlotOrAbsent` 成功且 slot 在 receiver.prop_values、kind=data → `learnGetFieldOwn`。empty→mono（写 shape*/word/slot）；不同 `shape*`→mega（shape=null，永 walk）。不学 proto/getter/proxy/exotic/缺席/auto_init。
- **命中：** `flag_byte18` bit7 → 热扩+24 表 → site 下标 → `shape*` + Property 字 → `ldp` 槽、dup、覆盖接收者；rc==1 表跳 release tail。
- **miss：** `property_tail_tbl[.get_field_walk]`（禁止同文件 `always_tail`）。
- **`shape*` 弱引用。** IC-R3：无 `vm.ic_base`。

---

## 4. RF 反汇编 — `op_get_field` 命中臂逐指令

二进制 `/tmp/wt-ic-p1/zig-out/bin/zjs` @ `10348c72`。`objdump -d --disassemble=exec.tailcall_dispatch.op_get_field`。

**0 bl。0 `sub sp` / `stp x30`。** 墓碑 `.space 0x240` 在 primitive 臂后，不进 I$ 工作集。

### 4.1 入口 / 非对象（不计命中 28）

| # | 址 | 指令 | 意 |
|---|---|---|---|
| — | `1073b80` | `ldur x8,[x1,#-8]` | tag |
| — | `1073b84` | `cmn x8,#1` | isObject？ |
| — | `1073b88` | `b.eq 1073ba4` | 是 → 探针 |
| — | `1073b8c–ba0` | tombstone 开关 + `br` primitive | 非对象 |

### 4.2 命中路径（object + has_ic + mono + 字等 + rc>1 + cont）

按**实际执行**编号（未采取的 miss 跳仍计入，与 spike「含未采取」同口径）：

| # | 址 | 指令 | 意 |
|---:|---|---|---|
| 1 | `1073ba4` | `ldr x8,[x3,#8]` | `vm.function` |
| 2 | `1073ba8` | `ldrsb w9,[x8,#18]` | `flag_byte18` |
| 3 | `1073bac` | `tbnz w9,#31,1073bbc` | bit7 has_ic（采取） |
| 4 | `1073bbc` | `ldr w8,[x8,#32]` | `byte_code_len` |
| 5 | `1073bc0` | `cmp w8,#1` | |
| 6 | `1073bc4` | `b.lt walk` | 未采取 |
| 7 | `1073bc8` | `ldr x9,[x3,#56]` | `vm.code_base` |
| 8 | `1073bcc` | `add x8,x9,x8` | hot = code+len |
| 9 | `1073bd0` | `ldr x9,[x8,#24]` | IC 指针 pad+24 |
| 10 | `1073bd4` | `cbz x9,walk` | 未采取 |
| 11 | `1073bd8` | `ldr w8,[x8,#32]` | count pad+32 |
| 12 | `1073bdc` | `ldurh w10,[x0,#5]` | `site_id` |
| 13 | `1073be0` | `cmp w8,w10` | |
| 14 | `1073be4` | `b.ls walk` | 未采取 |
| 15 | `1073be8` | `ldur x8,[x1,#-16]` | object* |
| 16 | `1073bec` | `add x9,x9,x10,lsl#5` | ic = base+site*32 |
| 17 | `1073bf0` | `ldr x11,[x8,#24]` | `shape*` |
| 18 | `1073bf4` | `ldr x10,[x9]` | `ic.shape` |
| 19 | `1073bf8` | `cmp x11,x10` | |
| 20 | `1073bfc` | `b.ne walk` | 未采取 |
| 21 | `1073c00` | `ldrh w10,[x9,#16]` | `ic.slot` |
| 22 | `1073c04` | `add x11,x11,x10,lsl#3` | props[slot] |
| 23 | `1073c08` | `ldr x11,[x11,#56]` | live Property 字 |
| 24 | `1073c0c` | `ldr x9,[x9,#8]` | `ic.prop_word` |
| 25 | `1073c10` | `cmp x11,x9` | |
| 26 | `1073c14` | `b.ne walk` | 未采取 |
| 27 | `1073c18` | `ldr x9,[x8,#32]` | `prop_values` |
| 28 | `1073c1c` | `add x10,x9,x10,lsl#4` | &slot.data |
| 29 | `1073c20` | `ldp x9,x10,[x10]` | 值 |
| 30 | `1073c24` | `cmn x10,#0xa` | 需 RC？ |
| 31 | `1073c28` | `b.ls 1073c38` | 未采取（要 dup） |
| 32 | `1073c2c` | `ldur w11,[x9,#-4]` | rc |
| 33 | `1073c30` | `add w11,w11,#1` | |
| 34 | `1073c34` | `stur w11,[x9,#-4]` | |
| 35 | `1073c38` | `stp x9,x10,[x1,#-16]` | 覆盖接收者 |
| 36 | `1073c3c` | `ldur w9,[x8,#-4]` | 接收者 rc |
| 37 | `1073c40` | `subs w9,w9,#1` | |
| 38 | `1073c44` | `b.ne 1073c58` | rc>1 采取 |
| 39 | `1073c58` | `stur w9,[x8,#-4]` | 写下 rc |
| 40 | `1073c5c` | `ldrb w8,[x0,#7]!` | **cont** pc+7 |
| 41 | `1073c60` | `adrp x9,…` | |
| 42 | `1073c64` | `add x9,x9,#0x520` | |
| 43 | `1073c68` | `ldr x4,[x9,x8,lsl#3]` | |
| 44 | `1073c6c` | `br x4` | 下一 op |

**合计 44 insn（含 cont、含未采取的 miss 比）。硬顶 28。不过。**

空表 miss（bit7=0）：#1–3 后 `1073bb0–bb8` 三发 `br walk`，共 6 insn 出岛。

### 4.3 IC-R2 `op_get_field_field2`（整符号）

```
109c700:  b  1073b80   ; op_get_field
```

nm size **0x4**。leftover B 仍是 7B `get_field2`。

---

## 5. nm 几何

| 符号 | main `7bab7426` | P1 `10348c72` |
|---|---|---|
| `op_get_field` | `1073b80` **0x324** | `1073b80` **0x330** ≤0x340 |
| `op_if_false8` | **`1074880` 0x140** | **`1074880` 0x140** 钉址 |
| `op_get_field_field2` | 0x20c | **0x4** |
| `op_get_field_walk` | （岛内旧体） | `109d4d0` **0x610** 岛尾 |

---

## 6. Gate

| 项 | 结果 |
|---|---|
| `test-core -- IC-R1` | PASS |
| `test-exec` | **479 passed / 0 failed**（比基线 478 多 1 条 IC-R1 exec） |
| `test-parser` | 493/493（`eba3274d`） |
| `/tmp/lanes/ic-fixtures/run-difftest.sh` | **7/7 IDENTICAL** z≡q（`ZJS=/tmp/wt-ic-p1/zig-out/bin/zjs` `QJS=/home/aneryu/quickjs/qjs`） |

七案：

```
01-inplace-delete            z=0 q=0  IDENTICAL
02-define-data-to-getter     z=0 q=0  IDENTICAL
03-proto-replace-own         z=0 q=0  IDENTICAL
04-proxy-through-learned-site z=0 q=0  IDENTICAL
05-delete-redefine-storm     z=0 q=0  IDENTICAL
06-oom-in-learn              z=0 q=0  IDENTICAL
07-get-field2-keep-receiver  z=0 q=0  IDENTICAL
```

test262 全量 3 条 Proxy `[[Set]]` 红：**main@7bab7426 新编 runner 同样红**（8/15 旧 runner 曾误报 PASS）。不记 P1 名下。

---

## 7. 自测 FW（非裁决）

CPU **8**，`armv8_pmuv3_1/cycles/u`，n=4。A=main `7bab7426` `zig-out/bin/zjs`，B=P1。夹具 `/tmp/r5/fixed/{typescript,box2d,earley-boyer}.js`。**不是 3-pad，不是裁决。**

| 案 | A | B | B/A |
|---|---:|---:|---:|
| typescript | 4.200G ±0.20% | 7.011G ±0.10% | **1.669** |
| box2d | 1.213G ±0.13% | 1.682G ±0.30% | **1.387** |
| earley-boyer | 6.462G ±0.15% | 6.575G ±0.12% | **1.018** |

命中 44 insn 并不比今日岛内 walk（~47）便宜到能付 miss 远跳。spike：「P1 cyc 不降 → 杀」。

---

## 8. 请裁

| 选项 | 含义 |
|---|---|
| **P1 REJECT-ARCHIVE** | insn 44>28 且自测 cyc 同号负 |
| 只收 R1+R2+7B，回滚命中探针 | 宽度与 field2 0x4 可留 |
| 另单瘦身 | `vm.ic_base` 去 #4–11 热扩算术；**不保证**进 28 |

不建议立刻开 put / get_field2 IC / poly。
