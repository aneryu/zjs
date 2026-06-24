# Phase 1 Keystone 设计（qjs 内存/GC 地基忠实转写）

> Phase 0 产出（2026-06-22，13-agent workflow + skeptic 复核）。Phase 1 的施工蓝图。
> 上位文档 `QJS-FAITHFUL-ALIGN.md`。

## 落地顺序：5 个大 commit slice（严格依赖序，不可重排）

```
S1  value-refcount + atom-string   （地基，行为完全不变）
S2  symbol-model                    （依赖 S1；Option B = symbol 值是指向 refcounted body 的指针）
S3  gc-cycle-collector              （依赖 S1,S2；canonical header + weakref_count + 删 symbol-scan/value-roots resurrection）
S4  object-shape-header             （依赖 S1,S3；忠实 @fieldParentPtr punning）
S4b shape-owns-proto                （依赖 S1,S3,S4；SHAPE 入 gc_obj_list + proto 移到 shape + 删 Object 重复 proto 边）
S5  frame-slab                      （依赖 S1,S2,S3；最后删 FrameRootScope/active_value_roots）
```

**强制依赖（codex 更正：是部分强制、非整序不可重排）**：**符号 ownership refcount 化（S2）+ 删除/替换 symbol-root
scanning** 必须先于删 `FrameRootScope`/`active_value_roots`（S5）。对象保活**已是 rc-based**，故 S5 **不必**等 S3 的每个
object weakref_count 细节——active_value_roots 在此主要喂 SymbolRootSet 和 weak/finalization 的符号处理。`active_value_roots`
是 runtime 级 root 机制，直接赋值约 **7 个 builtin 文件、67 处**（codex 更正，非 ~20 文件）。

**JSValue 布局（codex 更正）**：默认是 **`.standard` 16-byte**；**NaN-boxing 是 opt-in**（`-Dzjs_nan_boxing`，test-altrepr 跑）。
门禁"default + nan_boxing"即"默认 16-byte + 该变体"，勿误读为 NaN 默认。

## GC 模型的精确形态（修正"零发布"的简化说法）

qjs（quickjs.c:6646-6654, 17803）：
- **同步调用帧**：栈值靠 **refcount 保活**（push 时 dup、pop 时 free）；运行中帧 `cur_sp==NULL`，GC 不扫它；
  环收集器只处理 `gc_obj_list`（堆）。
- **挂起 async/generator 帧**：本身是堆 GC 对象，保存的栈 `[arg_buf, cur_sp)` 在 GC 时被 mark。

所以 S5 不是"删掉所有 rooting"，而是：**用 refcount-on-push（同步帧）+ 仅对挂起帧保留扫描，替换 zjs 的重
`FrameRootScope`**。zjs 对象 liveness 已是 refcount-based（object.zig:5383 rc>0），所以普通对象不卡这一步；
**符号和 weak 结构卡**——故 S2/S3 必须先行。

## 逐 slice

### S1 — value-refcount + atom-string（行为完全不变）
- dup()/free() 非 NaN 热路径塌成单 `gc.retain/gc.release(*gc.Header)`，经 `ptrFromPayload(gc.Header, payloadOf()).?`
  ——机械移植已发货的 NaN 分支（gc.Header==GCObjectHeader==ObjectHeader 同 24B extern，一次覆盖全 6 个 refcounted tag）。
- **【缺陷修正·编译阻断】** 把 `function_bytecode` 加进 `gc.releaseAndDestroy` 的 deinit skip，成 **kind-keyed
  {object, var_ref, function_bytecode}**（gc.zig:1423）——**不是** {object,module,...}：`RefKind` **无 .module 变体**，
  写了编译报错。然后才删 value.zig:485-489 的 tag-keyed deinit switch。权威 skip 只留一处。
- atom-string：保留 zjs 内联前置 gc.Header（**已披露可接受的偏离**，非 qjs 的 before-pointer 块头）；latin1 加 +1 NUL；
  30-bit atom_type-seeded masked hash + 侵入 hash_next；free-list 用 `[]usize` masked-on-read（**非** `[]?*String`+奇 @ptrFromInt，
  Zig 0.16 ReleaseSafe 对齐下不 sound）；保 `first_dynamic_atom=657`。
- **DEFER**：rope-tree-revert、.slice-removal（保 zjs 现状，避 OOM/RSS/dangling 回归）。
- 引入 `setSlot`（snapshot-old/store-new/free-old，照抄 slot_ops.zig:557-559），**暂不接任何调用**。
- 符号**不动**，仍在 refcount 前缀之外，heap-scan 仍是符号唯一 keepalive。
- **门**：0/49775 default + nan_boxing。

### S2 — symbol-model（Option B，单大 commit）
- `Tag.symbol` 变成**指向 refcounted String body** 的指针（rc 在内在 gc.Header）——**唯一**同时匹配 qjs
  （`JS_MKPTR(JS_TAG_SYMBOL, JSString*)`）和 zjs `dup()` 无 rt 参数不变量（814 个 .dup() 站点不改）的模型。
  **Option A 不可实现**（`AtomTable.dup(atom_id)` 要 rt）。
- 符号移入 refcount 前缀band，**lockstep 改** comptime tag_assertions（value.zig:80-99）。
- `asSymbolAtom()`(value.zig:369) + ~15 调用者改为从 body 指针解 atom-id；加 `AtomKind.global_symbol`（第4变体）改 ~7 处
  非穷尽 guard；`Symbol.for→internSymbol(global_symbol)`、`keyFor` iff kind==global_symbol；`canBeHeldWeakly` 相应改。
- **【weakref_count stopgap·强制】** 加 weakref_count（或 pin slot），rc==0 && weakref_count==0 才释放 body（镜像 js_weakref_free）。
- **绿桥**：符号 refcount 化 + 重写 ~30 注册站点 + 加 weakref_count **必须同一 commit、绝不拆分**（非原子拆分 = 每个仅作为
  value 可达的符号瞬间可回收 → ===/UAF）。heap-scan **此处不删**，作冗余 belt-and-suspenders 留到 S3。
- **门**：built-ins/Symbol 98/98、WeakRef 29/29、WeakSet 85/85、FinalizationRegistry 47/47、Symbol/for 9/9、keyFor 8/8 + 全 0/49775 + nan_boxing。

### S3 — gc-cycle-collector（单大 commit，内部 A/B/C）
- canonical `GCObjectHeader`：**保留 zjs 的 flags 字节**（mark/in_cycle_list/finalizing/is_pinned/cycle_*）——
  `is_pinned`/`finalizing` 在收集器外承重，**不要**塌成 gc_obj_type:u7+mark:u1。保留可空 prev/next 侵入链。
- **A（删 symbol-scan）**：S2 已 refcount 化符号 → 删 seedSymbolRootsFromRuntimeHeldValues/SymbolRootSet/
  sweepUnrootedUniqueSymbols（object.zig:5427/5690/6307）。
- **B（weak 机制忠实）**：加 `JSObject.weakref_count`（object.zig:1137 现无），js_weakref_new/free 增减；
  husk 保活（weakref_count!=0）；用 qjs **单次 pre-GC `gc_remove_weak_objects` sweep** 替 zjs 的 fixpoint
  scanPreservedWeakAndFinalizationEdges（object.zig:6563-6575 while(true)）；held_value 靠普通 refcount，不另起 resurrection。
- **C（删 value-roots resurrection）**：保 object→prototype 直接边、shape 留非-GC interned（**接受的偏离**）；
  open var_ref **不**在 trial-deletion 里 trace 活槽（匹配 qjs mark_children VAR_REF 6630-6636）；保 DecrefVisitor
  `if(h.rc==0) return` 作迁移 tripwire（debug 下 assert/log）。**FrameRootScope 本身不在此删**（S5）。
- **门**：0/49775 + nan_boxing + **force-GC-on-every-alloc** 构建（见下）。

### S4 — object-shape-header（单大 commit，仅 header punning）
- 忠实 header punning **只用 `@fieldParentPtr("header", h)`**——**不**直接 `@ptrCast *Shape<->*GCObjectHeader`
  （非 extern struct 是 UB，Zig 自动排字段、header-first 不保证 offset 0）。Shape 设 extern 或限定只用 @fieldParentPtr。
- free_object 走 qjs 忠实 header 路径，同时**复制 zjs weak-identity 语义**（peekWeakObjectIdentity 作 husk-keep 源、
  保 takeWeak/clearWeak 通知、保 sweepDeadWeakEntries 二遍）。
- 保 zjs **两循环属性枚举**（shape.props 取 atom + Object.properties 取 value），保 arm dispatch，不塌成假单循环。
- **门**：WeakRef.deref、FinalizationRegistry、prototype-cycle GC、全 0/49775 + nan_boxing。

### S4b — shape-owns-proto（忠实对齐，非偏离；单大 commit，深 refactor）
qjs（已查证 quickjs.c:974-985）：`struct JSShape{ JSGCObjectHeader header; ...; JSObject *proto; }`，shape 在
`gc_obj_list`（add_gc_object JS_GC_OBJ_TYPE_SHAPE:5224/5283/5366/5429）；`struct JSObject` **只有 `JSShape *shape`、无
独立 proto 字段**；proto 经 object→shape→proto 在 mark_children 标**一次**。zjs 现状是 proto **重复**（object 上 `*Object`
+ shape 上 proto_id int，即早先审计的「duplicate-prototype-pointer 赢」）。
- **SHAPE 入 `gc_obj_list`**：Shape 带 gc header、由环收集器扫。
- **proto 移到 shape** 成 owning `*Object`（qjs `JSObject *proto`），**删 Object 的重复 proto 边**——这一步本身**消除
  double-decref**（不存在两条边各 decref）。同时回退早先审计的「duplicate-prototype-pointer」。
- **reroute**：所有 proto 读 / 链遍历 / instanceof / `__proto__` → `object.shape.proto`；`setPrototype` → 走 shape
  transition（找/建带新 proto 的 shape，qjs 语义）。
- **GC 标记**：object 标 shape，shape 标 proto（删 object 直接标 proto）。
- 独立于 S5（frame-slab），二者次序可换；依赖 S1+S3+S4。
- **门**：proto 链遍历、instanceof、`__proto__` get/set、Object.getPrototypeOf/setPrototypeOf、跨 realm proto、
  prototype-cycle GC、全 0/49775 + nan_boxing + force-GC。

### S5 — frame-slab（单大 commit，最后删 FrameRootScope）
- 删 FrameRootScope/active_value_roots（frame.zig:46-131），**审计每个发布者**（~20 builtin），确认其 root 的瞬时值
  现已被 refcount/symbol-refcount 保活（S2+S3 已成立）。
- **TDZ 哨兵**：删平行 locals_uninit bool 数组；每个 bool-array 站点改 **through-cell** 测
  `varRefSlotIsUninitialized/slotValueBorrow(slot).isUninitialized()`（slot_ops.zig:528）——**不是**裸
  `frame.locals[idx].isUninitialized()`（会漏掉值在 cell 里的捕获局部）。迁移期留 cross-check assert。
- **slab carve**：一块连续 VmStackArena 切 [args|vars|stack|var_refs]，保现有单 mark/restore。
- **【缺陷修正】** **不要**把 `frame.var_refs`（eager 继承闭包捕获 = qjs `p->u.func.var_refs`，frame.zig:99/197）
  转成 NULL-init lazy slab——会**抹掉闭包捕获**。只把 `open_var_refs`（frame.zig:199，懒自槽 = qjs `sf->var_refs`）
  折成 `[*]?*VarRef` 尾。
- **保 byte-for-byte**：top-level-let 单 VarRef-cell 别名（vm_call.zig:203-225）——重拆 = da34bc1 跨 realm 写穿回归。
  generator/async 堆存储 gate（use_inline_frame_storage zjs_vm.zig:366）。
- original_args 退役**单独后续 commit**（非本 slice），采 qjs eager unmapped-arguments。
- **门**：da34bc1 集（6 for-of/for-in TDZ + 1 eval-delete + 1 跨 realm）+ 闭包-over-loop + generator-suspend +
  深递归 + 异常展开 + WeakRef/FinRec/Symbol 子集 + 全 0/49775 + nan_boxing + force-GC。

## 验收门补强：force-GC-on-every-alloc 构建

S3/S5 的 weak/borrow desync **可被时序掩盖**——确定性 test262 很难强制"回收后 deref"，可能**不报错却是真 soundness 回归**。
唯一确定性捕获 = **每次分配前强制 GC** 的构建（qjs `FORCE_GC_AT_MALLOC` 类比）跑全套。S3/S5 必须过此构建。
→ 这是对 `QJS-FAITHFUL-ALIGN.md §2` 验收门的补充：GC 相不能只靠 test262 0/49775。

## 风险登记（幸存高危，均有 da34bc1 8-回归先例）

| # | 风险 | 解决 slice |
|---|---|---|
| 1 | FunctionBytecode deinit 双重释放（spec 自带 mitigation 编译错） | S1（kind 集 {object,var_ref,function_bytecode}）|
| 2 | 符号非原子拆分 → ===/UAF（tag_assertions 会 @compileError 挡） | S2（同 commit 翻 refcount + 留 scan）|
| 3 | weakref_count 保活缺失（时序可掩盖，仅 force-GC 抓） | S2 符号 / S3 对象，各与 scan 删除原子 |
| 4 | 跨 realm 写穿（da34bc1 先例） | S2（registry kind）+ S5（单 cell byte-for-byte）|
| 5 | 逐迭代 TDZ（da34bc1 先例） | S5（through-cell 测 + cross-check assert）|
| 6 | active_value_roots 是 runtime 级非 frame-local | 序 S2→S3→S5 不可重排 |
| 7 | frame.var_refs 是错目标（会抹闭包捕获） | S5（只折 open_var_refs）|
| 8 | SHAPE-as-gc-object | **改为忠实对齐 S4b**（深 refactor：shape 入 gc_obj_list + proto 移 shape + 删 Object 重复边 → 自动消 double-decref；非偏离）|
| 9 | atom free-list / Shape punning sound 性 | S1（[]usize masked）+ S4（@fieldParentPtr-only）|
| 10 | S3 保 flags 字节 + DecrefVisitor tripwire | S3 |
| 11 | rope / .slice / original_args 退役 | DEFER，各自独立 commit |

## 与"全量忠实"原则的偏离清单（keystone 内）

全量忠实下，凡偏离都要**经查证的真实理由**（非 agent 断言、非成本、非"局部赢"），否则一律对齐。当前清单：
- ~~SHAPE 非 gc_obj_list~~ **已撤**：查证 qjs proto 只在 shape、object 无 proto 边，"double-decref/等价"非真实理由 →
  改为忠实对齐 S4b。
- ~~atom-string 24B header~~ **codex 更正 2026-06-23**：原"qjs 无 rope/扁平"是**错的**。qjs **有** rope
  （`JS_TAG_STRING_ROPE`/`JSStringRope` left/right JSValue，quickjs.c:601），且 string+rope **纯 refcount、不上
  `gc_obj_list`**（图无环）。zjs 把 string 放上了环收集 gc list（24B 头）。真正对齐 = **string/rope/.slice 移出环收集器、
  refcount-only、极小头**，**保留 rope**——延后项 `string-off-cycle-list`（见 Phase 3）。S1 期不动。
- **.slice / original_args**：延后的对齐项，各自独立 commit；「reverting 风险」（dangling）落实时查证。
  （rope **不** revert——qjs 有 rope。）
