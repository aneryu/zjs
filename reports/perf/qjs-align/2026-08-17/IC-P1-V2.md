# IC-P1-V2 — 唯一瘦身迭代 · REJECT-ARCHIVE

日期：2026-08-17。现场 **`/tmp/wt-ic-p1`**。基 **`main@7bab7426`**。**未合 main。** 254/255 空。无第三发。

形：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。

首发见 `/tmp/lanes/IC-P1.md`（命中 44 insn，TS 1.67×）。本文件是批准的**唯一一次**瘦身的终裁证据。

---

## 0. 一句话

目标形（`vm.ic_base` 单载 + shape*/Property 两比）接到了，IC-R3 未破（0 `sub sp` / 0 帧 / 0 `bl`）。TS FW CPU8 n=4 ABBA **B/A = 1.012**，区间不重叠，**不是同号降**。按裁决：**整通道 REJECT-ARCHIVE**。产品 IC（7B 编码、命中/learn、`ic_base`、field2 去克隆、`has_ic`）已从 `grok/ic-p1` 剥掉。

---

## 1. 分支状态

| ref | rev | 内容 |
|---|---|---|
| **`grok/ic-p1`**（遗留 tip） | **`e1a7432f`** | **只留** `3a31115b` IC-R1 测试 + 独立 Proxy `[[Set]]` 修复 |
| `grok/ic-p1-v2-archive` | `12611468` | 瘦身尝试整树（含产品 IC）。不进遗留 tip |
| 首发 checkpoint | `10348c72` | 44 insn 金丝雀 |
| IC-R1 测试资产 | `3a31115b` | `src/tests/{core,exec}.zig` 两条 |

遗留 vs `7bab7426` 仅 3 文件：`object.zig`（+4，Proxy 拒走）+ IC-R1 两条测试 + Proxy 单测。`rg ic_base\|GetFieldIcSlot\|byte18_has_ic` 在 `src/` 产品路径 **0 命中**。

回滚后重编 RF `zjs`：`op_get_field` 回到 **`0x1073b80` / `0x324`**（与 main 同址同长），`if_false8` 仍钉 **`0x1074880`**，nm 无 `get_field_walk` / IC 符号。`-e` 冒烟：Proxy `true/true/false`，IC-R1 `1/true/undefined//2`。Debug：`test-core IC-R1` 1/1、`test-exec IC-` 2/2。

---

## 2. ① Proxy `[[Set]]`（语义，已留）

`setOrDefineOwnDataPropertyForPutFieldOwned` 原型走在 `has_exotic_methods` 上拒慢。**Proxy 不是 `has_exotic_methods`**（陷阱在 class switch）。跳过它会在 receiver 上新建 own data 槽，**从不跑 `[[Set]]`**。

```
if (proto.isProxy()) return .slow;
```

同路径 `defineNewOwnDataPropertyForSimpleSetKnownNoOwn` 本来就有 `proto.proxyTarget() != null`。这是 main 既有洞，不是 P1 引入。

| 尺 | 结果 |
|---|---|
| `tests.exec.test.IC-P1: OrdinarySet forwards to a Proxy proto [[Set]] trap` | 期望 `true/true/false`（trap 调了 / receiver 是 o / 无 own `x`） |
| test262 `built-ins/Proxy/set/call-parameters-prototype.js` | V2 产品上 PASS（修前红） |
| test262 `built-ins/Proxy/set/trap-is-null-receiver.js` | V2 产品上 PASS |
| test262 `staging/sm/Proxy/regress-bug1062349.js` | V2 产品上 PASS |

独立于 IC。回滚时留下，避免再红这 3 条。可单独 cherry-pick 到 main。

---

## 3. ②③ 瘦身形（已从 tip 剥掉；证据在 archive `12611468` + 04:36 RF 件）

- `Vm.ic_base: ?[*]GetFieldIcSlot` + `ic_len`。`publishIcBase()` 跟 `function` 一起在 enter / 三处 leaf-return / reloadTop / reloadAfterPop / `run()` 序言发。learn 成功后覆写。
- 命中臂：`if (vm.ic_base) \|base\|` 一载 + `cbz`；然后 `shape*`、Property 字。**无** state / count / magic / `has_ic` / 热扩三载。mega = `shape* = null`。`site_id` 当 emit 可信。
- IC-R3：**objdump 无 `sub sp` / 无 `stp x30`**。字段留下（没破帧）。墓碑 `.space 0x1c0` 钉 `if_false8`。

源码命中臂（archive）：

```
if (!receiver.isObject()) { ... primitive tail }
if (vm.ic_base) |base| {
    const site = readInt(u16, pc + 5);
    if (site < vm.ic_len) {          // 后加；04:36 测量件 LLVM 未发这条
        const ic = &base[site];
        if (shape == ic.shape) {
            if (live_word == ic.prop_word) { ldp; dup; store; rc? release : cont }
        }
    }
}
return walk tail;
```

---

## 4. ④ RF 几何 — `op_get_field` @ `/tmp/wt-ic-p1/zig-out/bin/zjs` 04:36

配置签名自证：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。

反汇编全文：`/tmp/lanes/ic-p1-v2-get_field.objdump`。nm：`/tmp/lanes/ic-p1-v2-nm.txt`。

| 门 | 结果 |
|---|---|
| nm `op_get_field` | **`0x1073c00` size `0x284` ≤ `0x340`** |
| `if_false8` | **`0x1074880` 钉**（与 main `7bab7426` 同址） |
| `bl` | **0** |
| 帧（`sub sp` / `stp x30`） | **0**（IC-R3 过） |
| field2 | `b 1073c00`，nm **0x4** |
| 命中臂 insn（含 generic 5-insn `cont`） | **33 > 28** |
| 命中臂 insn（不计 `ldrb+adrp+add+ldr+br`） | 28 |
| rc>1 命中跳（从 `ic_base` 载起） | **5 ≤ 6**（`cbz` / `b.ne` shape / `b.ne` word / `b.ls` RC / `b.ne` rc） |

命中路径逐指令（从 `1073c24` `ldr ic_base` 起；`isObject` 三发不算进 28）：

| # | 址 | 指令 | 意 |
|---:|---|---|---|
| 1 | `1073c24` | `ldr x9,[x3,#112]` | `vm.ic_base` |
| 2 | `1073c28` | `cbz x9,walk` | 空表 |
| 3 | `1073c2c` | `ldur x8,[x1,#-16]` | object* |
| 4 | `1073c30` | `ldurh w10,[x0,#5]` | `site_id` |
| 5 | `1073c34` | `add x9,x9,x10,lsl#5` | `ic = base+site*32` |
| 6 | `1073c38` | `ldr x11,[x8,#24]` | `shape*` |
| 7 | `1073c3c` | `ldr x10,[x9]` | `ic.shape` |
| 8 | `1073c40` | `cmp x11,x10` | |
| 9 | `1073c44` | `b.ne walk` | |
| 10 | `1073c48` | `ldrh w10,[x9,#16]` | `ic.slot` |
| 11 | `1073c4c` | `add x11,x11,x10,lsl#3` | |
| 12 | `1073c50` | `ldr x11,[x11,#56]` | live Property 字 |
| 13 | `1073c54` | `ldr x9,[x9,#8]` | `ic.prop_word` |
| 14 | `1073c58` | `cmp x11,x9` | |
| 15 | `1073c5c` | `b.ne walk` | |
| 16 | `1073c60` | `ldr x9,[x8,#32]` | `prop_values` |
| 17 | `1073c64` | `add x10,x9,x10,lsl#4` | |
| 18 | `1073c68` | `ldp x9,x10,[x10]` | 值 |
| 19 | `1073c6c` | `cmn x10,#0xa` | 需 RC？ |
| 20 | `1073c70` | `b.ls skip_dup` | |
| 21–23 | `1073c74–c7c` | rc++ | |
| 24 | `1073c80` | `stp x9,x10,[x1,#-16]` | 覆盖接收者 |
| 25–27 | `1073c84–c8c` | 接收者 rc-- / `b.ne cont` | |
| 28 | `1073cac` | `stur w9,[x8,#-4]` | 写下 rc |
| 29–33 | `1073cb0–cc0` | generic `cont` | pc+7 派发 |

首发 44 → 瘦身后 33（砍掉热扩 11 发）。**含 cont 仍超 28。** 这 5 发 `cont` 与今日岛内 `get_field` 同类，不是 IC 探针独有；即便不计，cyc 终门仍不过。

---

## 5. 终门 — TS FW CPU8 n=4 ABBA

原始日志：`/tmp/lanes/ic-p1-v2-fw.log`。

- A = `/home/aneryu/zjs/zig-out/bin/zjs`（`7bab7426` 引擎，件时 2026-08-17 02:02；main tip 之后只多了 docs `540f6b7b`）
- B = `/tmp/wt-ic-p1/zig-out/bin/zjs`（V2 瘦身 RF，04:36）
- 夹具 `/tmp/r5/fixed/typescript.js`
- `taskset -c 8`，`armv8_pmuv3_1/cycles/u`，顺序 ABBA × 4 = 8/侧

| r | A1 | B1 | B2 | A2 |
|---:|---:|---:|---:|---:|
| 1 | 4.196G | 4.246G | 4.249G | 4.191G |
| 2 | 4.205G | 4.246G | 4.244G | 4.182G |
| 3 | 4.191G | 4.236G | 4.260G | 4.193G |
| 4 | 4.198G | 4.248G | 4.252G | 4.211G |

| 侧 | n | mean | stdev | min | max |
|---|---:|---:|---:|---:|---:|
| A | 8 | **4.196G** | 8.9M (0.21%) | 4.182G | 4.211G |
| B | 8 | **4.248G** | 7.0M (0.16%) | 4.236G | 4.260G |

**B/A = 1.012303。A max 4.211G < B min 4.236G，区间不重叠。不是同号降。终门 FAIL。**

对照首发自测 TS 1.669：瘦身把 miss 税从「热扩三载 + 远 walk」收到 ~1.2pp，**仍是净负**。命中 33 insn 付不起 TS 上大量不稳态 / mega / 首次 miss。

---

## 6. 附加：V2 产品 test262 RF SIGSEGV

全量 RF `Progress: 7000/49775` 后 **EXIT 139**。窗口：

| 索引 | 结果 |
|---|---|
| 0–4000 / 7000–7500 / 7600–7700 / 7750–7775 | PASS |
| **7775–7800** | **SIGSEGV**（`-v` 日志 0 字节，崩在第一个用例前或 harness 内） |

`site < ic_len` 没挡住。未完成单测定位（终门已死，不再挖）。回滚后产品 IC 不在 tip，遗留树无此路径。

夹具七案在 V2 产品上 **7/7 IDENTICAL** vs `/home/aneryu/quickjs/qjs`。test-exec V2 产品 **480/480**。语义夹具绿挡不住 cyc 门。

---

## 7. 回滚做了什么

1. 瘦身工作树收成 `12611468`，旁支 **`grok/ic-p1-v2-archive`**（备查，不合）。
2. `grok/ic-p1` **reset --hard `3a31115b`**（IC-R1 测试资产）。
3. 再提交 `e1a7432f`：只加 Proxy `isProxy()` 拒走 + 对应 exec 单测。

剥掉的产品：5→7 编码、`GetFieldIcSlot`、stamp/ensure/release、`byte18_has_ic`、命中/learn/mega、`vm.ic_base`、field2 表跳、墓碑、`site_id` 操作数。

---

## 8. 为什么目标形仍杀

spike §3.2 的 28-insn 预算不含 generic `cont` 时勉强贴线，含 `cont` 则 33。即便几何「算过」，TS 仍 **+52M cyc / +1.2pp** 且无重叠。

根因不是「再瘦 5 发」：

- TS 的 `get_field` 位点 shape 不稳定（constructor / proto 变 / 多形）。empty→mono 的首次 miss + 第二 shape 进 mega 后永 walk。mega 用 `shape*=null` 表达，命中臂仍要付 `ic_base` 载 + `cbz` + shape 比再出岛。
- walk 在岛尾（`op_get_field_walk` `0x109e790`），相对今日岛内 walk 是远跳。miss 比 main **更贵**。
- 命中省下的哈希查找盖不过 miss/mega 税。P1 范围（own data only，不学缺席/proto/getter）在 TS 上命中率不够。

再开第三发不能改变这个形状。按令关通道。

---

## 9. 请收

| 项 | 状态 |
|---|---|
| 候组包 | **无** |
| 通道 | **REJECT-ARCHIVE**。无第三发 |
| 合 main | **否** |
| 遗留 tip | `grok/ic-p1` @ `e1a7432f` = IC-R1 测试 + Proxy 修复 |
| 尝试树 | `grok/ic-p1-v2-archive` @ `12611468` |
| Proxy 修复 | 可独立 cherry-pick（`object.zig` + exec 单测）。不是 IC |

不建议立刻开 put / get_field2 IC / poly。下一手若还有，需要先有「TS 稳态 own-data 位点占比」的独立证据，而不是再削 5 条 insn。
