# S1 — value-refcount + atom-string（keystone 地基，行为完全不变）

> Phase 1 第一个 commit。上位：`KEYSTONE-DESIGN.md`、`QJS-FAITHFUL-ALIGN.md`。
> **本文件是设计/实现规格，非代码**（docs-first：全部 slice 文档完成 → 一起审 → 最后执行）。

## 目标与边界

- **行为完全不变**：S1 只做 dup/free 热路径塌缩 + atom-string 布局对齐 + deinit-skip 修正 + 引入（不接线的）`setSlot`。
- **不碰**符号（仍在 refcount 前缀外）、不碰 GC 模型、不碰 frame。符号 heap-scan 仍是符号唯一 keepalive（留到 S3 删）。
- **门**：`test262 0/49775`（default + `-Dzjs_nan_boxing=true`）+ `zig build test` + ReleaseSafe。
  S1 不涉及 weak/borrow 时序，**不需要** force-GC 构建（那是 S3/S5）。

## 改动清单（带 file:line 锚点）

### 1. dup()/free() 非 NaN 热路径塌成单 switch ✅ 已执行（2026-06-23）
- **现状**：默认 16-byte 路径 `dup()`/`free()` 跑 `refHeader`(5 tag) + `objectHeader`(1 tag) 两次 switch；NaN 路径**已**塌成单
  `gc.retain/gc.release(*gc.Header)`（value.zig:453-481，commit 0d467a3）。
- **已做**：加 `refCountHeader()`（value.zig，一次 switch 覆盖全 6 个 refcounted tag → 一次 `ptrFromPayload(gc.Header,…)`，
  `gc.Header==GCObjectHeader==BlockHeader` 同 24B），把默认 `dup`/`free` 的两次 lookup 合并成一次。**保留** `refHeader`/
  `objectHeader` 作 typed accessor。**行为完全一致**（`gc.retain(h)`==`h.retain()` gc.zig:1407-1409；`requiresRefCount`
  覆盖那 6 tag value.zig:340-343）。
- **qjs 对照**：单一 `JS_VALUE_HAS_REF_COUNT` 测试（`__js_rc`，quickjs.h:682-720）。
- **门禁绿**：`zig build`(默认+nan_boxing)、smoke、`zig build test` 1219/1219、**test262-gate 0/49775 errors**。

### 2. ~~deinit-skip 集移到 releaseAndDestroy~~ **❌ 已否决（执行时以 qjs 为准）**
- **否决理由**：读真实 qjs，`JS_FreeValueRT`/`__JS_FreeValueRT`（quickjs.h:688-705 / quickjs.c:6448+）**根本没有 deinit-phase
  skip**——那是 zjs 自有的 teardown 机制（`Registry.deinit` 的 gc_object_tail 遍历 + value.zig free() 的 deinit skip 配合）、
  **不是 qjs 结构**。S1 是"忠实 + 行为不变"，不该动它。
- 而文档原方案"把 function_bytecode 加进 releaseAndDestroy + 删 value.zig deinit switch"**恰恰会引入** codex 警告的
  function_bytecode 双重释放（deinit walker + releaseAndDestroy 各销毁一次）。
- **实际做法（item 1）**：只合并热路径的两次 header lookup，**value.zig 的 deinit-skip（`{object,module,function_bytecode}`）
  一字不动** → 双重释放风险**根本不产生**，且 0/49775 验证零回归。`releaseAndDestroy` 的 `{object,var_ref}` skip 也不动。

### 3. atom-string 布局对齐（内部，内容相等仍 memcmp）
- **latin1 +1 NUL** ✅ 已执行（codex 驱动 + 我对照 qjs 审核，2026-06-23）：qjs `js_alloc_string_rt`（quickjs.c:2358）
  对 str8 加 `+1` NUL、`str8[len]=0`（3934/3986/4346）；StringBuffer 累加器无 NUL。zjs 在所有 **final** latin1 buffer
  （`.compact` via inlineAllocationLayout +1、rope `node.flat`）加 +1 与 `writeLatin1Terminator`，rope `node.tail`（StringBuffer
  类比累加器）不加；alloc/free 经 `inlineAllocationLayout`/`finalLatin1Allocation` 尺寸一致。门禁：1219/1219 + **0/49775**。
- **JSString atom hash / `hash_next`（Run-3 audit, 2026-06-23）**：**ZIG-FORCED，不改代码**。qjs 的机制是
  `JSAtomStruct == JSString`（quickjs.c:225-226），`struct JSString` 直接带 `hash:30`、`atom_type:2`、`hash_next`
  （quickjs.c:583-591）；`__JS_NewAtom` 对 string/global-symbol 用 `hash_string(str, atom_type) & JS_ATOM_HASH_MASK`
  查 `rt->atom_hash` 链（quickjs.c:3188-3215），并把新 atom 的 `p->hash`/`p->hash_next` 写回同一个
  `JSString` 结构（quickjs.c:3273-3318）。zjs 的真实结构是 **独立 atom table**：`String.hash` 是普通字符串内容 hash cache
  （collection/string concat 调用者依赖），`String.atom_id` 是弱回指；atom bytes/refcount/cache/free-list 在 `DynamicAtom` +
  `AtomTable` 中。把 qjs 的 `hash_next` 侵入链照搬进 zjs 意味着 atom table 必须改成拥有 `*String` entry，且 free slots 要复刻
  qjs 的 `atom_set_free` 指针位标记（quickjs.c:2339-2351）。这在内存安全 Zig 中不能作为 `*String` 数组表达；安全等价物就是
  当前的 `DynamicAtom.next_free`/`free_slot_head` 整数链。
- **`JSAtomStruct = String` alias（Run-3 audit, 2026-06-23）**：**ZIG-FORCED，不新增 Zig 类型别名**。qjs typedef 见
  quickjs.c:225-226，且 alias 被 `__JS_NewAtom` 依赖：非 atom string 可原地变 atom（quickjs.c:3273-3277），已是 atom 时
  通过 `js_get_atom_index` 从同一 `JSString` 找回 id（quickjs.c:3160-3174）。zjs 的 atom/string 分离是为了避免上述
  pointer-punning + 侵入链；语义上仍按 kind+内容唯一化，内容相等仍走字节/码元比较。
- **atom free-list（codex 更正）**：现状**已是**整数链 `DynamicAtom.next_free` + `AtomTable.free_slot_head`
  （atom.zig:767-779/832-837/992-995/1129-1135），本就 qjs 式（qjs `atom_set_free` 整数位标记 quickjs.c:2349）——**无需改**。
  原稿"改 []usize masked"是 misframed（针对一个并不存在的 `[]?*String` 方案），**删除该项**。
- **保 `first_dynamic_atom=657 / predefined_count=656`**，不重编号到 `JS_ATOM_END`。
- **comptime 断言** ✅ 已执行（2026-06-23）：在 `atom.zig` pin 真实 zjs 不变量：`Atom` 仍是 32-bit、tagged-int bit 仍是
  bit 31、`predefined_count == 656`、`first_dynamic_atom == predefined_count + 1`。qjs bitfield offset 断言
  （`len:31/is_wide_char:1`、`hash:30/atom_type:2`、body 12B）只适用于 qjs 的 `struct JSString`
  （quickjs.c:583-591）；zjs `String` 有 `gc.Header` + Zig `Data` union，不存在可真实断言的同构 bitfield layout。

### 4. `set_value` slot-setter primitive ✅ 已查证（2026-06-23）
- **结论：ALREADY-ALIGNED，不新增 duplicate `setSlot`。** qjs 的真实 primitive 是 `set_value`
  （quickjs.c:2662-2670）：先 `old_val = *pval`，再 `*pval = new_val`，最后 `JS_FreeValue(ctx, old_val)`；
  注释明确要求 free 放在 store 之后，因为 freeing the value can reallocate the object data。
- zjs 已有共享 slot primitive：`slot_ops.zig:542-560` 的 `setSlotValue`。普通 owned slot 分支就是
  **snapshot-old / store-new / free-old**：`const old_value = slot.*` → `slot.* = assigned` → `old_value.free(ctx.runtime)`
  （slot_ops.zig:557-559）。非 refcount fast path直接 store（free 为 no-op），var-ref slot 分支写穿到 cell。
- var-ref cell setter也已对齐：`var_ref.zig:81-85` 的 `setVarRefValue` 先 snapshot `self.pvalue.*`，再写
  `next_value`，最后 free old。对象 var-ref / property / dense-array 等 owned JSValue slot setter也保持同一顺序；因此再加一个
  “unrouted” `setSlot` 只会制造重复 primitive，而不是更忠实。

### 5. DEFER rope-tree / .slice（**耦合已查证**）
- **保留** zjs 的 tail-append rope 缓冲 + `.slice` 变体不动。
- **查证结论（codex 更正，2026-06-23）**：原稿"qjs 字符串扁平、无 rope"是**错的**。qjs 这棵树**有** rope
  （`JS_TAG_STRING_ROPE`/`JSStringRope`，`left/right: JSValue`，quickjs.c:601-609），且 **string + rope 都是纯 refcount、
  不上 `gc_obj_list`、不被环收集**（无 `JS_GC_OBJ_TYPE_*ROPE`/`add_gc_object`）——因为字符串/rope 图**无环**（DAG），
  refcount 就够。zjs 现在却把 string 放上了环收集 gc list（24B `gc.Header`，string.zig:98-99）。
- **所以**（Run-2 再 refine）：zjs string **本就不是 cycle candidate**（gc.zig:1015-1017 排除 string，**已 off cycle
  list**），只是仍**带 24B `gc.Header`**（含 string 用不上的 gc-list 链）。真正 delta = **缩字符串头到 qjs 极小 refcount
  头**，**保留 rope**（qjs 也有）。延后项 `string-header-shrink`（见 `PHASE3`）。S1 期 string 结构不动、不 revert rope。

## 绿桥（为何 S1 行为不变）

- dup/free 塌缩是已发货 NaN 分支的机械移植 → refcount 语义不变。
- **唯一**语义变动 = deinit-skip 重整，且若**先**把 function_bytecode 加进 `releaseAndDestroy` 再删 value.zig tag-skip，
  则严格 no-op（否则 function_bytecode 双重释放）。
- 符号**不动** → comptime tag_assertions 仍过、dup/free 对符号仍 no-op、heap-scan 仍是符号唯一 keepalive → 符号 identity 不变。
- atom-string 改动（NUL、atom-numbering comptime guards、free-list/alias/hash 的 qjs evidence documentation）纯内部/布局，
  内容相等仍 memcmp → 无可观测变化。
- rope/.slice 延后 → 无 OOM/RSS/borrow 回归。
- bridge：`refHeader`/`objectHeader` 留作 accessor → 冷 typed 调用者照常编译；`setSlot` 存在但不接线 → 无 ad-hoc free+assign 被反转。

## 验收（结构对照 + 门）

- **结构对照 code-review**：dup/free vs `JS_DupValue`/`__JS_FreeValueRT`（quickjs.h:682-720）；deinit-skip vs `__JS_FreeValueRT`
  的单点释放；atom 布局 vs `struct JSString`（quickjs.c:583-591 + hash:30/atom_type:2）、
  `__JS_NewAtom`（quickjs.c:3188-3318）+ `atom_set_free`（quickjs.c:2339-2351）。
- **门**：`0/49775` default + `-Dzjs_nan_boxing=true`，`zig build test`，ReleaseSafe。
- **回归哨**：deinit 期 function_bytecode free 不双重释放（加针对性单测）；符号 identity 套件（built-ins/Symbol）仍绿。
