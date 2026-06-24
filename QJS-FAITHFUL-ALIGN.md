# zjs → QuickJS 忠实对齐计划（keystone-first）

> 决策已锁（2026-06-22，grill-me 收口）。本文件是逐项对齐 checklist 的正典。

## 0. 操作原则（不可违背）

1. **忠实对齐 qjs = 全局性能最优的目标基线**，不是可被局部 microbench「赢」二次质疑的步骤。
   先对齐到 qjs，建立干净、均匀、可对照的基线，**再**在其上、用严谨方法谈「超过 qjs」。
2. **不信任 agent 声称的局部「赢」**。历史背书：fusion 作弊层曾把 geomean 刷到 0.716，不泛化，已被
   `06e4389`/`764d823` 物理删除。凡 zjs 偏离 qjs 之处，默认一律回退到 qjs 结构——包括那些
   被审计标为「赢」的（符号 atom-id、双 transition、dup proto、小 shape 线性扫）。
3. **Zig 不构成墙**。qjs 地基的 4 处 C 机制全有忠实 Zig 等价物（见 §1）。现存偏离是**选择**，不是
   Zig 所迫。转写用 `extern struct/union` + `@ptrCast` + `@fieldParentPtr` + intrusive list + arena slab。
4. **唯一硬门是正确性**。`test262 0/49775` 是红线。若 qjs 的结构会让某 test262 用例回归（参见
   codex parser-align 的 7 回归：TDZ / eval-delete / 跨 realm），则保留**最小**必要偏离并记录；
   忠实让位于正确性，仅此一处。

## 1. Zig 等价物已证（Zig-墙消解）

| qjs 机制 | qjs 源 | Zig 忠实转写 |
|---|---|---|
| `JSAtomStruct == JSString`（同类型别名，非 punning） | quickjs.c:225-226 | `const JSAtomStruct = String;` |
| `JSRefCountHeader`（首字段，`(u32*)ptr-1` 访问） | quickjs.h:99-101,684 | `@ptrCast` / `@fieldParentPtr` |
| 侵入式 `gc_obj_list`（`list_head link` 内嵌） | quickjs.c:284,337 | intrusive `{prev,next}` + `@fieldParentPtr` |
| frame slab（arg/var/stack/var_refs 紧随 frame） | quickjs.c:793 | 从 `VmStackArena` 切一块连续 slab（zjs 不用 C 栈递归） |

字面不可达且**无需**：C `alloca`（zjs 无 C 栈递归）、computed-goto（dispatch 已用 `switch`+`continue :sw` 对齐反超）。

## 2. 验收门（每一项、反作弊）

- **每项硬门**：`test262 0/49775` + `zig build test` + ReleaseSafe + test-altrepr，不过不合入。
- **每项忠实检查**：对照它所镜像的具体 `quickjs.c:N` 做结构 code-review（「是否真的和 qjs 结构一致」）。
- **性能**：只在**相边界**对 qjs 测一次 sanity（不得回退于前相基线）；**永不**作为保留某单项偏离的理由。
- **GC 相补强**：S3/S5 的 weak/borrow desync 可被时序掩盖、test262 0/49775 抓不到 → 必须额外过
  **force-GC-on-every-alloc** 构建（每次分配前强制 GC，qjs `FORCE_GC_AT_MALLOC` 类比）。
- **风格**：每相一个（或一组紧致）大 commit，门禁后置。

## 3. 相结构（keystone-first）

```
Phase 0  Keystone 规划（不出货代码）
Phase 1  Keystone：GC / value-refcount / frame 地基，忠实转写 qjs
Phase 2  下游：调用机制 / dispatch / 对象-属性 refcount 纪律（落在 qjs 地基上，6-7× 在此解开）
Phase 3  叶子：GC-无关忠实对齐 + 余下赢回退 + global-var 稳定 cell + builtin 上 prototype
```

### 文档地图（审查入口）

- `QJS-FAITHFUL-ALIGN.md`（本文件）— 原则 + 验收门 + 相结构总图。
- `KEYSTONE-DESIGN.md` — Phase 1 总览：5 slice 落地序 + 依赖 DAG + 风险登记 + 偏离清单。
- `docs/qjs-align/` — 逐 slice / 逐相**可执行级**规格：
  - `S1-value-refcount-atom-string.md`、`S2-symbol-model.md`、`S3-gc-cycle-collector.md`、
    `S4-object-shape-header.md`、`S4b-shape-owns-proto.md`、`S5-frame-slab.md`
  - `PHASE2-downstream-call-machinery.md`（调用税 6-7×）、`PHASE3-leaves-and-levers.md`（叶子 + 赢回退 + 大杠杆）

---

### Phase 0 — Keystone 规划（交付：一份 keystone 设计文档）

- [ ] 画 qjs 内存管理子系统的**转写依赖图**：value/refcount header → atom/string → object/shape header
      → `gc_obj_list`/环收集器 → frame slab，标出耦合点与落地顺序。
- [ ] 逐结构定 Zig 转写写法（§1 已给骨架），确认 ReleaseSafe 下的安全检查处理方式。
- [ ] 定 Phase 1 的 commit 切分（单次大 commit 还是紧致序列），确保切分点都能过 test262。

### Phase 1 — Keystone（地基，qjs-faithful）

**Phase 0 蓝图已出**：详见 `KEYSTONE-DESIGN.md`。落地为 **5 个严格有序大 commit slice**：

- [ ] **S1 value-refcount + atom-string**（行为完全不变）：dup/free 非 NaN 热路径塌成单 `gc.retain/release(*gc.Header)`；
      **先**把 `function_bytecode` 加进 `releaseAndDestroy` deinit skip = kind-keyed `{object,var_ref,function_bytecode}`
      （`RefKind` 无 .module，否则编译错 + FunctionBytecode 双重释放），**再**删 value.zig tag-keyed deinit switch；
      `JSAtomStruct=String` 别名 + 30-bit seeded hash + `[]usize` masked free-list；rope/.slice **DEFER**。
- [ ] **S2 symbol-model**（Option B）：`Tag.symbol` 变成**指向 refcounted String body 的指针**（唯一兼容 `dup()` 无 rt
      + 814 站点；Option A 不可实现）；lockstep 改 tag_assertions；加 weakref_count stopgap；heap-scan 暂留作冗余。
- [ ] **S3 gc-cycle-collector**：canonical header（保 zjs flags 字节）；删 symbol-scan（A）；加 `weakref_count` + 单次
      pre-GC weak sweep 替 fixpoint（B）；删 value-roots resurrection（C）。**过 force-GC 构建**。
- [ ] **S4 object-shape-header**：忠实 header punning 只用 `@fieldParentPtr`。
- [ ] **S4b shape-owns-proto**（深 refactor，**忠实对齐非偏离**）：查证 qjs proto 只在 shape（quickjs.c:985）、object 无
      proto 边、shape 在 gc_obj_list。故 SHAPE 入 `gc_obj_list` + proto 移到 shape（owning `*Object`）+ **删 Object 重复
      proto 边**（自动消 double-decref，回退「duplicate prototype pointer」赢）+ reroute 所有 proto 读/`setPrototype`/GC 标记。
- [ ] **S5 frame-slab**（最后）：删 `FrameRootScope`/`active_value_roots`（runtime 级、~20 builtin 发布）；TDZ 哨兵用
      **through-cell** 测（非裸 locals）；**不动 `frame.var_refs`**（eager 闭包捕获），只折 `open_var_refs`；
      top-level-let 单 cell **byte-for-byte 保留**（防 da34bc1 跨 realm 写穿）；original_args 退役另起 commit。**过 force-GC**。

**GC 模型精确形态**（修正"零发布"）：qjs 同步帧栈值靠 **refcount-on-push 保活**（运行帧 cur_sp=NULL 不扫），仅扫挂起
async/gen 帧 `[arg_buf,cur_sp)`（quickjs.c:6646-6654）。S5 是**用 refcount-on-push 替换** zjs 重 `FrameRootScope`，
不是简单"删 rooting"——且必须 S2（符号 refcount）+ S3（对象 refcount/weakref_count husk）之后才安全。

锚点：`JS_CallInternal` 帧建立、`JSStackFrame`（quickjs.c:410,793）、`JSRefCountHeader`、`gc_obj_list`/环收集器。

### Phase 2 — 下游（落在 qjs 地基上）

- [ ] **调用机制（6-7×）**：`OP_call` 忠实 `JS_CallInternal` 入口；Bytecode view **按指针**而非每调用
      按值拷 43 字段（审计 rank 1，inline_calls.zig:246）。
- [ ] **回溯懒构造**（审计 rank 2，inline_calls.zig:665-704）——无 per-call rooting 后自然成立。
- [ ] **put_field 转移所有权**省 dup/free（审计 rank 9，vm_property_field.zig:351-354）。
- [ ] 对象-属性 fast path 的 refcount 纪律按新 value 模型对齐。

### Phase 3 — 叶子（GC-无关忠实对齐 + 赢回退 + 大杠杆）

GC-无关忠实对齐：
- [~] 属性槽 40B tagged-union → **16B untagged**（**DEFERRED**：侵入性大，shape-flags 派生 kind 引发深度 test-infra 级联，codex 未收敛；messy 态在 git stash） qjs `JSProperty`（rank 4，property.zig:125-134 vs quickjs.c:947-963）。
- [x] create 路径删冗余第二次 `findProperty`（rank 5，object.zig:8880/9240）—— prop_create 1.95×。
- [x] fast-array 增长改 realloc/remap（rank 6，object.zig:3382）；`Array.push` 多参快路径（rank 12）。
- [x] 算术臂接上 `tryInt32BinaryWindow`（rank 7，vm_arith.zig:175 零调用者）；`bothInt` 单测试（rank 10）。
- [x] string content-hash 懒算（rank 8）。
- [x] JS→C 分发线性探测 → kind-tag switch（rank 11，call_runtime.zig:478）。
- [x] parser peephole：jump-threading + 常量折叠（rank 13，resolve_labels.zig；编译期，修 69-70 过期注释）。

赢回退（回退到 qjs 结构）：
- [x] 小 shape 线性扫 → qjs always-hash。
- [x] 双 shape-transition → qjs 单 `find_hashed_shape_prop`（codex 验证全局 hash 覆盖 per-parent 语义）。
- [x] **string-off-cycle-list**（codex 更正 2026-06-23：qjs **有** rope `JS_TAG_STRING_ROPE`/`JSStringRope`，且
      string+rope **纯 refcount、不上 `gc_obj_list`**——字符串图无环 refcount 足够）：把 zjs string/rope/.slice **移出
      环收集器 gc list** → refcount-only、极小头，对齐 qjs；**保留 rope**（qjs 也有，**不** revert）。解开 S1 延后的 24B-header 耦合。
  （注：dup proto 指针回退已并入 keystone **S4b**；array count/length 拆分见下「大杠杆」。）

大杠杆（高侵入，flag-gated，test262 0/49775 把关）：
- [ ] **global-var 稳定 cell**：撤 global-var-by-name + `global_lexical_sync` 镜像 → qjs var_ref 稳定 cell。
      global_destruct_strict 1.85×。**风险**：da34bc1 在此用镜像修过 8 回归，须保 TDZ/eval/with/跨 realm 绿。
- [ ] **builtin 方法上 prototype**：每个 builtin 方法物化为各 prototype 的真 own-property（qjs 结构）。
      method_call_loop 7.06×。须解 null-proto 内部数组的方法解析。
- [ ] array `count`/`length` 拆分 → qjs 尾部虚 hole 表示（撤 zjs 的 count==length 融合）；审计每个 reader。
- [ ] 热属性/数组 opcode 臂寄存器驻留（rank 14，依赖 1/4/5/9 先落）。

## 4. do_not_align（全量忠实后近乎清空）

全量忠实 = 一切转写 qjs，连「正确性-故意」项也采用 qjs 的实现（weakref/finalization resurrection、arguments
语义、cross-realm 都对齐 qjs 的做法）。**唯一保留偏离的触发器**：该处 qjs 结构会让某 test262 用例回归——
此时保留最小偏离 + 记录（§0.4）。
