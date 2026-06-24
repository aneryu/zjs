# S3 — gc-cycle-collector（canonical header + weakref_count + 删 symbol-scan/value-roots resurrection）

> Phase 1 第三个 commit。依赖 S1、S2。**设计/实现规格，非代码。** 单大 commit，内部 A→B→C。

## 目标与边界

- 把 zjs 的 trace-from-roots GC 收口到 qjs 模型：**refcount 保活 + 仅扫堆的环收集器**（扫 `gc_obj_list`）。
- 删掉 zjs-专有的 symbol-root seeding 和 weak-edge fixpoint resurrection（这两套消费 `active_value_roots`）。
- **FrameRootScope 本身不在此删**（那是 S5）；S3 删的是消费 active_value_roots 的两个 resurrection pass，保留对象-cycle-root
  发布到 S5 的 refcount-纪律审计完成。

## GC 模型精确形态（已查证，修正"零发布"）

qjs（quickjs.c:6646-6654, 17803, 20697）：同步帧栈值靠 **refcount-on-push 保活**（运行帧 `cur_sp==NULL`，GC 不扫）；
仅挂起 async/gen 帧（堆 GC 对象）的保存栈 `[arg_buf, cur_sp)` 被 mark。zjs 对象 liveness **已**是 refcount-based
（object.zig:5383 rc>0 gc_scan 路径）→ 普通对象不卡；**符号和 weak 结构卡** → 故 S2/S3 先行。

## 改动清单（内部 A/B/C，单 commit）

### canonical GCObjectHeader
- **保留 zjs 的 flags 字节**（mark/in_cycle_list/finalizing/is_pinned/cycle_visited/cycle_preserved）——`is_pinned`（pinning API
  gc.zig:1046）在收集器**外**承重，**不要**塌成 `gc_obj_type:u7 + mark:u1`。只有 `mark` 概念上属于 type 字节。
  （codex 更正：`finalizing` 当前**并不**被读作 free-skip，只在 Registry.deinit 设——别把它当 free-skip 承重项。）
- 保留既有可空 prev/next 侵入链（**不**半迁到 sentinel 节点——list_del 空检查 + 循环终止条件不同）。

### Phase A — 删 symbol-scan
- S2 已让符号 refcount 化 → **删** `seedSymbolRootsFromRuntimeHeldValues`/`scanSymbolRoot*`/`SymbolRootSet`/
  `external_symbol_roots`/`sweepUnrootedUniqueSymbols`（object.zig:5427/5690/6307）。
- 一个仅在栈上的符号现经 refcounted body 自带 ref。

### Phase B — weak 机制忠实
- 加 `JSObject.weakref_count`（object.zig:1137 现无），`js_weakref_new` 增 / `js_weakref_free` 减；free_object/gc_free_cycles
  在 weakref_count!=0 时**保 husk**；保 `mark==0` 双重释放 guard。
- 用 qjs 的**单次 pre-GC `gc_remove_weak_objects` sweep**（在 JS_RunGCInternal 最前跑、按那一刻 `ref_count!=0` 判 liveness、
  `JS_EnqueueJob2` 入队不递归回 GC）**替换** zjs 的 fixpoint `scanPreservedWeakAndFinalizationEdges`（object.zig:6563-6575 while(true)）。
- held_value liveness 靠普通 refcount（held value 是仍存活 registry 的 STRONG child，经 `js_finrec_mark`）——**不**从 held value 另起 resurrection pass。
- `WeakRootSlot`（runtime.zig:282）簿记迁到 weakref_count。

### Phase C — 删 value-roots resurrection
- 保 object→prototype 直接边、shape 留非-GC interned **到 S4b**（S4b 才做 shape-owns-proto；S3 不动 proto 结构）。
- open（未 detach）var_ref 进同步帧：trial-deletion 里**不** trace 活槽（匹配 qjs mark_children VAR_REF 6630-6636 只走 async 路径），
  靠 frame 自有 refs。
- 保 zjs DecrefVisitor `if(h.rc==0) return` guard（object.zig:5260）作迁移 **tripwire**（debug 下 assert/log，让被掩盖的 refcount desync 浮现）。

## 绿桥

- A 安全：S2 已让符号自带 ref，scan 是冗余。
- B 安全：weakref_count husk-keepalive 精确镜像 qjs（weakref_count!=0 保 husk，`rc==0 && weakref_count==0 && mark==0` 才释放）；
  **WeakRef.deref 对死目标返回 `undefined`**（codex 更正：husk 是内部 keepalive，deref **不**暴露它）、FinalizationRegistry 按
  refcount-snapshot 顺序触发；单次 pre-GC sweep 匹配 qjs，fixpoint 是 husk 模型下不需要的 zjs 偏离。
- bridge：DecrefVisitor rc==0 guard 留作 tripwire——残留 borrow-on-stack desync 退化成 no-op-decref（debug 记录）而非崩溃，S5 做完整审计。

## 验收（结构对照 + 门）

- **结构对照**：环收集器 vs gc_decref/gc_scan/gc_free_cycles（quickjs.c:6568-6752）；weak sweep vs gc_remove_weak_objects；
  husk vs js_weakref_free。
- **门**：`0/49775` default + nan_boxing + **force-GC-on-every-alloc 构建**（weak/borrow desync 时序可掩盖、唯一确定性捕获），
  FinalizationRegistry/register+cleanupSome、WeakRef/deref、WeakMap-with-symbol-key、prototype-cycle GC 全绿。
