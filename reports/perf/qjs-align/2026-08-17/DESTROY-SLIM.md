# DESTROY-SLIM — 普通对象 destroy 瘦尾（K1）

日期：2026-08-17。lane w1:pW。候 **w46**。  
枝 **`grok/destroy-slim`** @ **`88a45d8e`**，基 `main@553840ab`。  
配置：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
数字 **非裁决用**。CPU **15** FW；编/test262 `taskset -c 0-4,8-14`。

| | |
|---|---|
| 对照 A | `/home/aneryu/zjs/zig-out/bin/zjs` @ `553840ab` sha `a61d0f77…` |
| 刀 B | worktree `zig-out/bin/zjs` sha `28adfceb…` |
| 票 | SCPAIR-LIFECYCLE K1 APPROVED |

⑦ RC teardown / `destroyRuntimeCycles*` / Pass B / weak husk：**一字未改**。P6 adopt / 8b bypass / ctor 2048：**未碰**。

---

## 0. 一句话

`destroyFromHeader` 最前 likely 臂走 qjs `free_object` 6340–6391 的普通对象五步；冷路径 `noinline destroyFromHeaderSlow`。热符号仍是 `destroyFromHeader`（无新热符号）。帧 **0xf0 → 0x80**，静态 **2755 → 237**。门全绿。FW Boyer **−22.1M cyc / −156M insn**，P6 **−44.3M**，splay **−23.8M**，合凳 insn **−150M**（cyc 近零）。候 w46。

---

## 1. 形

优先「最前 likely 臂」做成了：热工作 **inline** 在 `destroyFromHeader`，一般拆除 **outlined**。若把一般路径留在同函数，0xf0 序言会继续打在每一发 sc_Pair 上。

```
destroyFromHeader                    # 0x80 / 237 insn / 0x3b4
  if class==object
     and payload==.none
     and weakref_count==0
     and !has_weak_id
     and !borrowed
     and phase ∉ {remove_cycles, deinit}:
        @branchHint(.likely)
        mark + finalizing
        free data slots（非 data → destroyPropertySlot）
        free prop[]
        never_inline shapes.release
        unlink + slab destroy
        return
  restore; b destroyFromHeaderSlow   # 0xf0 / 2755 / 0x2b0c
```

守卫失败（含 cycle-phase / 函数对象 / WeakRef / 有 payload）**立刻回落**，语义与改前同一条慢路径。

多出来的 `has_weak_id` / `is_borrowed` 是保守回落：K1 四门之外，避免瘦臂漏掉弱 id 表 / borrowed 表。

五步对 `free_object` 6340–6391：

| # | qjs | z 瘦臂 |
|---|---|---|
| 1 | `free_mark = 1` | `mark` + `finalizing` |
| 2 | `free_property` × prop_count | data 槽 `JSValue.free`；其它 outlined |
| 3 | `js_free_rt(p->prop)` | `memory.free(Entry[prop_size])` |
| 4 | `js_free_shape` | `shapes.release`（`never_inline`，避免 `destroyShape` 灌进热帧） |
| 5 | `remove_gc_object` + `js_free_rt(p)` | `unregisterObjectWithBytes` + `memory.destroy` |

普通 `JS_CLASS_OBJECT` 无 finalizer；`releaseObjectDefinition` 对 standard id 本就是空返回，瘦臂不叫。

---

## 2. objdump（RF）

| 符号 | 帧 | 静态 insn | 大小 |
|---|---|---:|---|
| **`destroyFromHeader`**（热） | **0x80** | **237** | `0x3b4` |
| `destroyFromHeaderSlow`（冷） | 0xf0 | 2755 | `0x2b0c` |
| 改前 `destroyFromHeader` | 0xf0 | 2755 | `0x2b0c` |

门「帧 ≪ 0xf0」：热臂 **0x80**（−0x70）。未再拆新热叶——再瘦要 outlined 热符号，和「免新符号外部性」相冲。miss 臂拆完 0x80 后 `b Slow`。

---

## 3. 门

| 门 | 结果 |
|---|---|
| `test-core` 对象/GC/弱引用 | **334 pass / 1 skip**。新增 `plain object destroy slim frees two data slots…` |
| `test-exec` | **481 / 481** |
| objdump 帧 ≪ 0xf0 | **0x80**（见 §2） |
| test262 全量 | `prepared 49775/53293`，`Result: **0/49775 errors, passed 44581**`（与 w44/P2 纸面同，不扩） |
| ⑦ / P6 adopt / bypass / 2048 | diff 只有 `object.zig` + `tests/core.zig` |

`test262.conf` / `test262_errors.txt` / `reports/` **未改**。命令：

```
taskset -c 0-4,8-14 ./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test 0 100000
```

---

## 4. FW（CPU15，ABBA n=4，中位，非裁决）

A = official `553840ab`。B = 本刀。

| 尺 | 角色 | Δcyc | Δinsn | 回退？ |
|---|---|---:|---:|---|
| **boyer-only d16** | **主尺** | **−22.1M** | **−156.1M** | 否 |
| 合凳 d16 | 合 | −1.3M | **−150.5M** | 否 |
| splay det | 哨 | **−23.8M** | **−299.2M** | 否 |
| P6 官方 5e6 | 哨 | **−44.3M** | **−222.9M** | 否 |

预报 Boyer 30–50M cyc，实测 **−22M**（insn 先掉）。合凳 cyc 近零：Earley 大头是闭包 `destroyRuntimeCycles`，不进本臂。P6 5e6×{} 更吃瘦尾，−44M。四凳同号，无回退。

原始 `/tmp/lanes/destroy-slim/fw.json`。

---

## 5. 文件

- `src/core/object.zig` — likely 臂 + `destroyPlainObjectFast` inline + `destroyFromHeaderSlow` noinline
- `src/tests/core.zig` — 两槽 data 对象销毁金丝雀

⑦ 全家、`shape.zig` `destroyShape` 体、`gc.zig` cycle 路径未改（只从瘦臂 `never_inline` 调已有 `Registry.release`）。

---

## 6. 请收

- 产物：`/tmp/lanes/DESTROY-SLIM.md`
- 枝：`grok/destroy-slim` @ **`88a45d8e`**
- 合 main：未推，候 w46
- 建议：Boyer/P6/splay 同号正，帧 0x80，test262 0 error。合凳 cyc 不是付款面。
