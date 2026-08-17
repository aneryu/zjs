# EB-S1-HYGIENE — 塌 traceChildren 双份 + MemoryAccount 单态

日期：2026-08-17。lane **w1:pS**。  
分支 `grok/eb-s1-hygiene` @ **bc2e9ddb**，基 `main@0f721021`。件 `/tmp/wt-eb-s1`。对照 RF `/tmp/eb-s1/zjs-base`（同 sha，未塌）。  
scoping：[`EB-CAPACITY-SCOPING.md`](/tmp/lanes/EB-CAPACITY-SCOPING.md) §S1。数字 **非裁决用**（FW CPU **16**）。

**不许合 main。** EB 归因测量段未结束；合入时点等 driver 令。

钉：只减副本，不改 RC / 走访语义 / handler 体 / adopt / String。声明吃不满墙。

---

## 0. 判决

**静态卫生落地，正确性全绿，FW 净号不过门。不宣 win，不合 main。**

| | 基 `0f721021` | 本刀 |
|---|---|---|
| `traceChildren` | 2 份 `0x3bac+0x3d34` = **30.2KB** | **1 份 `0x2680` = 9.6KB** |
| `MemoryAccount.free` | **28** anon / 7220B | **0** anon + `freeBytes` 288B |
| `MemoryAccount.allocInternal` | **13** anon / 6140B | **0** anon + `allocInternalBytes` 408B |
| `allocInternalSlow` | **30** anon / 19040B | **1** `allocInternalSlowBytes` 676B |
| 位置 | 全在 `.text` 岛外 | **仍岛外** |
| `.text.zjs.op_handlers` | `0x2d688` 181.6KB | `0x2d708` 181.8KB（**+128B**） |
| RF 体积 | 31377912 | 30869584（−508KB，副本消失） |

FW（CPU16 ABBA n=4，A=base B=刀，生产签名）：

| 尺 | Δ insn | Δ cyc | Δ L1I refill | 门 |
|---|---:|---:|---:|---|
| **EB** refill+cyc | +419.7M | **+72.2M** | **+18.2M**（+22%） | cyc 预期 0–20M，实测反向超带 |
| **TS** insn 哨 | **+248.8M** | +212.4M | — | **回退** |
| **splay** insn 哨 | **+79.0M** | +16.7M | — | **回退** |

scoping 写过风险：`noinline` 把叶子赶到更远页 = L-1.5 反面，L1I 可能涨。活体就是这个：双份没了，工作集跳转变间接，refill 涨、insn 涨。成功 ≠ 分数；本刀连 0–20M cyc 带都没进。

---

## 1. 实施

### 1.1 `traceChildren` 一份走访

`src/core/object.zig`：三个 anytype visitor（Decref / ScanIncref / ScanRestore）的边方法本来就一样，只有 `visitHeader` 不同。收成具体 `CycleVisitor`：

- `ctx: *anyopaque` + `visit_header: *const fn (*anyopaque, *Header)`
- `visitValue` / `visitObject` / `visitShape` / `visitRealm` / `visitModule` / weak / finalization 与旧三型逐字节同形
- 三份 header 语义原封搬进 `decrefVisitHeader` / `scanIncrefVisitHeader` / `scanRestoreVisitHeader`
- `noinline fn traceChildren(..., visitor: CycleVisitor)` —— 非泛型，LLVM 不能再按 visitor 特化出第二份 15KB 走访

`traceChildEdgesFallible` / mark 路径 / `binding.zig` 仍走原来的 `anytype`，未动。

函数指针而不是 phase-`switch`：试过 volatile phase 内联三臂（想省 `blr`），走访缩到 7.5KB 但 TS insn **+1.03G** / EB refill **+39M**，比 vtable 更差，已弃。

### 1.2 `MemoryAccount` alloc/free 一份

`src/core/memory.zig`：

- `allocInternal(T)` 收成薄 typed 包装，跳 `noinline allocInternalBytes`（size/align/`gc_kind` 运行时入参）
- 慢路同理：`allocInternalSlowBytes` 一份
- `free(T)` 跳 `noinline freeBytes`（`free` 本身不 `inline`：compiler_v2 comptime 调用会炸 eval-branch quota）
- `initGcPrefixKind` 把 kind tag 从 comptime `T` 解出来，`initGcPrefix(T)` 仍给 `create*` 用

`create` / `destroy` / `createWithFam` 未并（scoping 只点 free/alloc 28/13）。生产 RF 里 `allocGc*` 被 DCE（`alloc` 热路径几乎全是 raw）。

未改：slab 几何、`creditAlloc`/`debitAlloc` 账、GC prefix 布局、`allocation_gc_trigger_enabled` 生产关。

---

## 2. nm 前后

基 `/tmp/eb-s1/nm-base.txt`，刀 `/tmp/eb-s1/nm-final.txt`。

```
BASE  island 0x1070000 size=0x2d688 (181.6KB)
  traceChildren__anon_108732  0x115f960  0x3d34  outside
  traceChildren__anon_108744  0x1163a40  0x3bac  outside
  free__anon ×28   7220B
  allocInternal__anon ×13   6140B
  allocInternalSlow__anon ×30  19040B

KNIFE island 0x1070000 size=0x2d708 (181.8KB)   +0x80
  Object.traceChildren        0x115a950  0x2680  outside
  MemoryAccount.freeBytes              0x120
  MemoryAccount.allocInternalBytes     0x198
  MemoryAccount.allocInternalSlowBytes 0x2a4
  free__anon = 0
  allocInternal__anon = 0
```

岛内几何几乎不动（+128B，handler 体未改）。塌掉的符号全在岛外，符合「岛外几何」。

---

## 3. 正确性门

| 尺 | 结果 |
|---|---|
| `git diff --check` | PASS |
| test-core | **333 pass / 1 skip** |
| test-exec | **480/480** |
| test262 全量 `run-test262 -t 8 -c test262.conf -d test262/test 0 100000` | **0/49775 errors，44581 passed** |

走访三阶段 / 分配账 / slab class 读写与翻前同语义。

---

## 4. FW（CPU 16，ABBA n=4）

脚本 `/tmp/eb-s1/fw.py`，原始 `/tmp/eb-s1/fw.json`。中位数。生产签名双方一致。

### 4.1 Earley-Boyer（主：refill + cyc）

| | A base | B 刀 | Δ |
|---|---:|---:|---:|
| instructions | 29559.0M | 29978.8M | +419.7M |
| cycles | 6522.8M | 6595.0M | **+72.2M** |
| `l1i_cache_refill` | 83.4M | 101.6M | **+18.2M（+22%）** |

预期 cyc **0–20M**（scoping 按 L-1.5 打折后的卫生上限）。实测反向 +72M，且 refill 涨。不要外推 pp。

### 4.2 Typescript / splay（insn 不回退哨）

| | Δ insn | Δ cyc | 哨 |
|---|---:|---:|---|
| TS `/tmp/census/det/typescript.js` | **+248.8M** | +212.4M | **回退** |
| splay `/tmp/r5/fixed/splay.js` | **+79.0M** | +16.7M | **回退** |

每条边一次 `blr visit_header`，加上 alloc/free 从「特化直达」改成「共享体 + 运行时 classIndex」，insn 账是付出来的，不是噪声（四发 A/B insn 各自咬得很紧）。

### 4.3 读法

- 静态：30KB 双份 + 28/13 分配副本确实没了。RF 小了 508KB。
- 动态：一份走访用间接调用换特化内联；一份 malloc 用运行时分支换 comptime 折叠。L1I refill 涨 = scoping 写过的反面。
- 卫生 ≠ 过线。L-1.5 已证「L1I −8% 分数 0」；本刀 L1I 还涨了。

试过、已弃：phase enum + volatile 防克隆 + 内联 switch。nm 仍 1 份（7.5KB），FW 更差（TS +1027M / EB refill +39M / EB cyc +190M）。保留 vtable 这一版。

---

## 5. 范围 / 未动

- 未合 main，未 push。
- 未动 handler 岛内容、musttail、`align(64)`、L-1.5、adopt/reloc、String、RC 语义。
- 未把 regexp/math mux stamp 进热段（现无 `.hot`，守住）。
- 未动 `test262.conf` / `reports/**` / `docs/**` / `tools/perf/**`。
- 未把本刀写进「EB 过线计划」。

---

## 6. 建议

1. **分支候合，等 EB 归因测量段结束再令。** 现在合会搅基线。
2. **不要当性能胜记合。** 副本塌了，净号是负的。
3. 若还要这份卫生：得先解决「一份走访怎么付 visit 而不加 `blr`/switch」。那是新刀，不是把本 sha 合进去。
4. S3-B 关墙结论不变。S1 吃不满 ×3，本单只是把它做完并量过。
