# Codex 独立核实更正账本

> codex（独立 agent）逐文档读真实 qjs/zjs 源码核实的结果。**核心架构 codex 确认成立**；以下是它驳回/存疑的条目。
> Run 1（2026-06-23）覆盖 S2/S3/S4b/KEYSTONE（已完成）；S1/S4/S5/PHASE2/PHASE3 首轮超时，Run 2 重跑中。
> 状态：✅=已 inline 修；⬜=待最终 inline 收口。

## A. 实质更正（改事实/计划）

| # | 更正 | 涉及文档 | 状态 |
|---|---|---|---|
| A1 | **qjs 有 rope**（`JS_TAG_STRING_ROPE`/`JSStringRope`，left/right JSValue，quickjs.c:601）。string+rope **纯 refcount、不上 gc_obj_list**（图无环）。原"qjs 扁平无 rope"错。→ 非"revert rope"。**Run-2 再 refine**：zjs string **本就不是 cycle candidate**（gc.zig:1015-1017 排除 string，已 off cycle list），只是**带 24B 头**——真正 delta = **缩字符串头到 qjs 极小 refcount 头**（去掉 string 用不上的 gc-list 链），**保留 rope**。项名 `string-header-shrink` | S1, KEYSTONE, QJS-FAITHFUL Phase3, PHASE3 | ✅(待按 refine 微调) |
| A2 | **默认 JSValue 是 .standard 16-byte；NaN-boxing 是 opt-in**（`-Dzjs_nan_boxing`，test-altrepr）。某些表述把 NaN 当默认，说反了 | KEYSTONE（+核对全部） | ⬜ |
| A3 | **WeakRef.deref 对死目标返回 undefined**，不是 husk。husk 是内部 keepalive，deref 不暴露它 | S3, S4 | ⬜ |
| A4 | **qjs setPrototype** = `js_shape_prepare_update`（clone-or-unhash 使 shape 私有）后改 `sh->proto`；**非** find/build interned transition。且 qjs shape **非普遍 interned**（只有 hashed shape 是 shared，另有 un-hashed/private） | S4b | ⬜ |
| A5 | **zjs proto = 一个 owning `Object.prototype` 指针 + 一个 non-owning `shape.proto_id` 整数**（重复 proto 状态，但**非两个 owning 指针**） | S4b, KEYSTONE | ⬜ |
| A6 | **force-GC-on-every-alloc 构建当前不存在**（zjs 现为 alloc-threshold/test-hook）。它是**待新增**的 gate（qjs FORCE_GC_AT_MALLOC 类比），非现有 | S3, S5, KEYSTONE | ⬜ |
| A7 | **`finalizing` flag 当前不被读作 free-skip**（只在 Registry.deinit 设）。S3"finalizing 在收集器外承重"应改为只 `is_pinned` 承重 | S3 | ⬜ |
| A8 | **`releaseAndDestroy` 现仅 skip {object, var_ref}**；function_bytecode 仍在 switch 里销毁。加 function_bytecode 是**待做修正**、非现状（措辞需明确这是"改"非"现状"） | S1, KEYSTONE | ⬜ |
| A9 | **atom free-list 现状 = `DynamicAtom.next_free` + `AtomTable.free_slot_head`**（非 `[]usize` masked-on-read）。S1 的 free-list 提法misframed，应据现状改 | S1, KEYSTONE | ⬜ |
| A10 | **DecrefVisitor 的 rc==0 guard 当前是静默 no-op**，无 debug assert/log tripwire。"保留 tripwire"是**新增**该 assert/log、非现状 | S3, KEYSTONE | ⬜ |
| A11 | **两循环要分场景**（Run-2 厘清）：对 **GC 子追溯**，zjs 确是直接两循环 shape.props + Object.properties（**正确**，S4 此处无误）；只有 **Object.keys/values/entries 枚举**不是（ownKeys 先从 shape 收 key、value 由 getOwnProperty/getProperty 后取）。→ S4 的两循环表述限定为"GC 追溯" | S4, KEYSTONE | ⬜ |

## B. 过度断言（软化）

| # | 更正 | 涉及 | 状态 |
|---|---|---|---|
| B1 | **Option A 是"侵入"非"字面不可实现"**：runtime/context dupValue wrapper 已存在（runtime.zig:1516-1519、context.zig:614-616），全仓库签名/路由改动可行但代价大 | S2, KEYSTONE | ⬜ |
| B2 | **5-slice DAG 非整体不可重排**：源码只强制部分依赖（符号 refcount 必先于删 symbol-root scan；S5 删 FrameRootScope 必在 S2 + symbol-root-scan 替换之后）；对象保活已 rc-based，S5 **不必**等 S3 的每个 weakref_count 细节 | KEYSTONE | ⬜ |
| B3 | **active_value_roots 发布点**：runtime 级正确，但精确数是 **~7 个 builtin 文件有直接赋值**（整体发布点更多），非"~20 builtin 文件" | S5, KEYSTONE | ⬜ |

## C. 陈旧 zjs 事实（精度修正）

| # | 更正 | 涉及 | 状态 |
|---|---|---|---|
| C1 | `asSymbolAtom` **~36 个调用者**，非 ~15 | S2 | ⬜ |
| C2 | 从 body 取 atom-id 的方法是 **`String.internAtom`**，无 `ensureAtom`（需新增或改名） | S2 | ⬜ |
| C3 | "其余 newValueSymbol 都在 test block" **false**（closure.zig:428 有非 test helper） | S2 | ⬜ |
| C4 | 那 7 处 atom.zig guard **非**符号-kind 更新的全部面；加 global_symbol 还需审计列表外检查 | S2 | ⬜ |
| C5 | `setOptionalValueSlot`（object.zig:2665）是 **take-owned/free-on-overwrite**；dup 由调用者（object_ops.zig:649、vm_value.zig:637） | S2 | ⬜ |
| C6 | object_ops:3199/3189 = **symbolPrimitiveValue/symbolDescriptionValue**（zjs **无** js_thisSymbolValue） | S2 | ⬜ |
| C7 | JSObject.shape 锚点 `:24` 错 → **quickjs.c:1013**（JSObject 布局 990-1077） | S4b | ⬜ |

## D. 验收数字非源码事实

| # | 更正 | 涉及 | 状态 |
|---|---|---|---|
| D1 | 所有 `0/49775` / force-GC / pass-count / da34bc1 回归数 **不是源码可验证的事实**，是**待跑的验证命令/结果**（或需 git 历史 + test 运行证据）。文档应表述为"门禁要求"而非"已知事实" | 全部 | ⬜ |

## Run-2 新增（S1/S4/S5/PHASE2/PHASE3，2026-06-23）

| # | 更正/发现 | 涉及 | 状态 |
|---|---|---|---|
| R1 | string **已 off cycle list**（见 A1 refine）；delta 是 24B 头 | S1 | ⬜ |
| R2 | 两循环对 GC 追溯正确（见 A11）；S4 限定场景即可 | S4 | ⬜ |
| R3 | **PHASE2 backtrace 非"每调用无条件 dup 2 atom + 函数对象"**：atom/函数值 dup **只在 lazy-name 分支**；另一分支存 borrowed atom。per-call 成本比原稿低 | PHASE2 | ⬜ |
| R4 | active_value_roots 直接赋值 = **7 个 builtin 文件、67 处**（精确 B3） | S5, KEYSTONE | ⬜ |
| R5 | **⚠️ codex 存疑（未能从所引行确认）**：(a) `frame.var_refs` 是 eager 捕获、转换会抹捕获——需读 closure/call setup 才能确认；(b) vm_call.zig:203-225 只见 placeholder-cell 创建，真正"单 cell"在后续 define_var（未读）。**这两条是承重的防回归项，S5 执行前须深查证实** | S5 | ⬜ 待深查 |
| R6 | **PHASE3 全清（0 驳回）**。3 处「待查证」codex 确认：① 双 transition **确是 per-parent cache vs 全局 intern 两件事**（回退须谨慎，审计前提对）② array_count 确实融合 .length+dense ③ global by-name + syncFrameVarRefMirror 确在，**且 zjs 顶层 lexical 已有 qjs 式 VARREF cell**（global-var 稳定 cell 杠杆可能部分已做） | PHASE3 | ✅ 无需改 |

## 未变更的核心（codex 确认）

- qjs symbol = JS_TAG_SYMBOL refcounted JSAtomStruct(=JSString) 指针，hash 复用为 weakref_count（quickjs.c:226/3517/583/51736）。
- zjs 现状符号 = 裸非-refcount atom-id（value.zig:228）；Option B 是忠实设计。
- qjs GC = refcount 保活 + 仅堆环收集，**不** trace 运行 JS 栈（运行 async/gen 帧 cur_sp==NULL）。
- qjs [[Prototype]] 经 JSShape（GC 对象）持有；zjs 重复 proto 状态。
- 最强序依赖成立：S2 符号 ownership **必先于** S3 删 symbol-root scan。
- 非原子拆分 UAF hazard、tag_assertions guard、814 个 .dup() 站点：均确认。
